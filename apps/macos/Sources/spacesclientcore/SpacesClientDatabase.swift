import Foundation
import spacesdatabase
import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

public struct SpacesPairedDeviceRecord: Codable, Sendable, Equatable, Identifiable {
    public static let localDeviceID = "local"

    public let id: String
    public var name: String
    public var platform: String
    public var host: String
    public var port: Int
    public var certificateFingerprint: String
    public var sshHost: String?
    public var sshUser: String?
    public var sshPort: Int?
    public var createdAt: String
    public var updatedAt: String
    public var lastSelectedAt: String?

    public init(
        id: String, name: String, platform: String, host: String, port: Int, certificateFingerprint: String, sshHost: String? = nil,
        sshUser: String? = nil, sshPort: Int? = nil, createdAt: String, updatedAt: String, lastSelectedAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.host = host
        self.port = port
        self.certificateFingerprint = certificateFingerprint
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSelectedAt = lastSelectedAt
    }
}

public struct SpacesClientMigrationStep: Sendable {
    public let fromVersion: Int
    public let toVersion: Int
    public let description: String
    public let apply: @Sendable (OpaquePointer) throws -> Void

    public init(fromVersion: Int, toVersion: Int, description: String, apply: @escaping @Sendable (OpaquePointer) throws -> Void) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.description = description
        self.apply = apply
    }
}

public final class SpacesClientDatabase {
    public static let databasePathEnvironmentVariable = "SPACES_CLIENT_DB_PATH"
    public static let currentVersion = 7
    private static let defaultDatabaseStorage = DefaultDatabaseStorage()
    private static let timestampFormatter = TimestampFormatterStorage()

    private let db: OpaquePointer
    private let databasePath: String
    private let schemaVersion: Int
    private let migrationSteps: [SpacesClientMigrationStep]
    private let backupManager: DatabaseBackupManager
    private let connectionLock = NSRecursiveLock()

    public init(
        path: String? = nil, currentVersion: Int = SpacesClientDatabase.currentVersion,
        migrationSteps: [SpacesClientMigrationStep] = SpacesClientDatabase.defaultMigrationSteps
    ) throws {
        let path = try path ?? SpacesClientDatabase.defaultPath()
        databasePath = path
        schemaVersion = currentVersion
        self.migrationSteps = migrationSteps
        let databaseURL = URL(fileURLWithPath: path)
        backupManager = DatabaseBackupManager(
            databaseURL: databaseURL, backupDirectory: databaseURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true))
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let openFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, openFlags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed opening client database at \(path)"
            if let handle { sqlite3_close(handle) }
            throw SpacesClientError.invalidArgument(message)
        }
        guard let handle else { throw SpacesClientError.invalidArgument("Client database handle is nil.") }
        db = handle
        try configureConnectionPragmas()
        try initializeSchema()
    }

    deinit { sqlite3_close(db) }

    public static func defaultPath(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        if let override = ProcessInfo.processInfo.environment[databasePathEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            let expanded = (override as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return expanded }
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).path
        }
        let environment = currentProfileEnvironment()
        let currentDirectoryPath = FileManager.default.currentDirectoryPath
        let profile = try SpacesProfile.resolve(
            environment: environment, homeDirectoryURL: profileHomeDirectoryURL(environment: environment, fallback: homeDirectoryURL),
            currentDirectoryPath: currentDirectoryPath,
            executablePath: SpacesProfile.currentExecutablePath(currentDirectoryPath: currentDirectoryPath))
        return URL(fileURLWithPath: profile.rootDirectory, isDirectory: true).appendingPathComponent("Client", isDirectory: true)
            .appendingPathComponent("spaces-client.db", isDirectory: false).path
    }

    public static func defaultDatabase() throws -> SpacesClientDatabase { try defaultDatabaseStorage.database() }

    public static func withDefaultDatabase<T>(_ body: (SpacesClientDatabase) throws -> T) throws -> T {
        let database = try defaultDatabase()
        return try database.withConnectionLock { try body(database) }
    }

    public static func setDefaultSetting(key: String, value: String?) throws {
        try withDefaultDatabase { database in try database.setSetting(key: key, value: value) }
    }

    private static func currentProfileEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in [SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable, "HOME"] {
            if let value = getenv(key) { environment[key] = String(cString: value) } else { environment.removeValue(forKey: key) }
        }
        return environment
    }

    private static func profileHomeDirectoryURL(environment: [String: String], fallback: URL) -> URL {
        if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return fallback
    }

    public func upsert(device: SpacesPairedDeviceRecord) throws {
        try execute(
            sql: """
                INSERT INTO paired_devices(
                  id, name, platform, host, port, certificate_fingerprint, ssh_host, ssh_user, ssh_port, created_at, updated_at, last_selected_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  platform = excluded.platform,
                  host = excluded.host,
                  port = excluded.port,
                  certificate_fingerprint = excluded.certificate_fingerprint,
                  ssh_host = excluded.ssh_host,
                  ssh_user = excluded.ssh_user,
                  ssh_port = excluded.ssh_port,
                  updated_at = excluded.updated_at,
                  last_selected_at = excluded.last_selected_at
                """,
            bindings: [
                device.id, device.name, device.platform, device.host, device.port, device.certificateFingerprint, device.sshHost ?? "",
                device.sshUser ?? "", device.sshPort.map(String.init) ?? "", device.createdAt, device.updatedAt, device.lastSelectedAt ?? "",
            ])
    }

    public func pairedDevices() throws -> [SpacesPairedDeviceRecord] {
        try queryRows(
            sql: """
                SELECT id, name, platform, host, port, certificate_fingerprint, ssh_host, ssh_user, ssh_port, created_at, updated_at, last_selected_at
                FROM paired_devices
                ORDER BY COALESCE(NULLIF(last_selected_at, ''), updated_at) DESC, name
                """
        ).compactMap(decodeDevice)
    }

    public func pairedDevice(id: String) throws -> SpacesPairedDeviceRecord? {
        try queryRow(
            sql: """
                SELECT id, name, platform, host, port, certificate_fingerprint, ssh_host, ssh_user, ssh_port, created_at, updated_at, last_selected_at
                FROM paired_devices
                WHERE id = ?
                """, bindings: [id]
        ).flatMap(decodeDevice)
    }

    public func deletePairedDevice(id: String) throws {
        try withImmediateTransaction { try execute(sql: "DELETE FROM paired_devices WHERE id = ?", bindings: [id]) }
    }

    public func setting(key: String) throws -> String? {
        try queryRow(sql: "SELECT value FROM client_settings WHERE key = ?", bindings: [key])?.first.flatMap(normalized)
    }

    public func setSetting(key: String, value: String?) throws {
        if let value {
            try execute(
                sql: """
                    INSERT INTO client_settings(key, value, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                      value = excluded.value,
                      updated_at = excluded.updated_at
                    """, bindings: [key, value, Self.timestamp()])
        } else {
            try execute(sql: "DELETE FROM client_settings WHERE key = ?", bindings: [key])
        }
    }

    public func isProjectCollapsed(deviceID: String, projectID: String) throws -> Bool {
        guard
            let raw = try queryRow(
                sql: "SELECT is_collapsed FROM project_sidebar_state WHERE device_id = ? AND project_id = ?", bindings: [deviceID, projectID])?.first
        else { return false }
        return raw == "1"
    }

    public func setProjectCollapsed(deviceID: String, projectID: String, isCollapsed: Bool) throws {
        try execute(
            sql: """
                INSERT INTO project_sidebar_state(device_id, project_id, is_collapsed, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(device_id, project_id) DO UPDATE SET
                  is_collapsed = excluded.is_collapsed,
                  updated_at = excluded.updated_at
                """, bindings: [deviceID, projectID, isCollapsed ? "1" : "0", Self.timestamp()])
    }

    public func projectCollapseStates(deviceID: String) throws -> [String: Bool] {
        let rows = try queryRows(sql: "SELECT project_id, is_collapsed FROM project_sidebar_state WHERE device_id = ?", bindings: [deviceID])
        return Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                guard row.count >= 2 else { return nil }
                return (row[0], row[1] == "1")
            })
    }

    /// Records the dedicated Chrome window opened for a workspace browser session on the local
    /// desktop. A browser "window" is client/desktop-local state (not daemon state), keyed by
    /// the session's resolved target URL so re-focus returns to the same window.
    public func setBrowserSessionWindowID(deviceID: String, workspaceID: String, targetURL: String, windowID: Int) throws {
        try execute(
            sql: """
                INSERT INTO browser_session_window_ids(device_id, workspace_id, target_url, window_id, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(device_id, workspace_id, target_url) DO UPDATE SET
                  window_id = excluded.window_id,
                  updated_at = excluded.updated_at
                """, bindings: [deviceID, workspaceID, targetURL, windowID, Self.timestamp()])
    }

    public func browserSessionWindowID(deviceID: String, workspaceID: String, targetURL: String) throws -> Int? {
        try queryRow(
            sql: "SELECT window_id FROM browser_session_window_ids WHERE device_id = ? AND workspace_id = ? AND target_url = ?",
            bindings: [deviceID, workspaceID, targetURL])?.first.flatMap(Int.init)
    }

    public func clearBrowserSessionWindowID(deviceID: String, workspaceID: String, targetURL: String) throws {
        try execute(
            sql: "DELETE FROM browser_session_window_ids WHERE device_id = ? AND workspace_id = ? AND target_url = ?",
            bindings: [deviceID, workspaceID, targetURL])
    }

    /// Every dedicated Chrome window tracked for a workspace's browser sessions, so the GUI can
    /// close them all when the workspace stops.
    public func browserSessionWindowIDs(deviceID: String, workspaceID: String) throws -> [(targetURL: String, windowID: Int)] {
        try queryRows(
            sql: "SELECT target_url, window_id FROM browser_session_window_ids WHERE device_id = ? AND workspace_id = ?",
            bindings: [deviceID, workspaceID]
        ).compactMap { row in
            guard row.count >= 2, let windowID = Int(row[1]) else { return nil }
            return (row[0], windowID)
        }
    }

    public func clearBrowserSessionWindowIDs(deviceID: String, workspaceID: String) throws {
        try execute(sql: "DELETE FROM browser_session_window_ids WHERE device_id = ? AND workspace_id = ?", bindings: [deviceID, workspaceID])
    }

    // MARK: - Panel layouts

    public func writeWorkspacePanelLayout(deviceID: String, workspaceID: String, layoutJSON: String) throws {
        try execute(
            sql: """
                INSERT INTO workspace_panel_layouts(device_id, workspace_id, layout_json, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(device_id, workspace_id) DO UPDATE SET
                  layout_json = excluded.layout_json,
                  updated_at = excluded.updated_at
                """, bindings: [deviceID, workspaceID, layoutJSON, Self.timestamp()])
    }

    public func workspacePanelLayout(deviceID: String, workspaceID: String) throws -> String? {
        try queryRow(
            sql: "SELECT layout_json FROM workspace_panel_layouts WHERE device_id = ? AND workspace_id = ?", bindings: [deviceID, workspaceID])?.first
    }

    public func deleteWorkspacePanelLayout(deviceID: String, workspaceID: String) throws {
        try execute(sql: "DELETE FROM workspace_panel_layouts WHERE device_id = ? AND workspace_id = ?", bindings: [deviceID, workspaceID])
    }

    public struct PanelWindowRecord: Sendable, Equatable {
        public let id: String
        public let layoutJSON: String
        public let frame: (x: Double, y: Double, width: Double, height: Double)?

        public init(id: String, layoutJSON: String, frame: (x: Double, y: Double, width: Double, height: Double)?) {
            self.id = id
            self.layoutJSON = layoutJSON
            self.frame = frame
        }

        public static func == (lhs: PanelWindowRecord, rhs: PanelWindowRecord) -> Bool {
            lhs.id == rhs.id && lhs.layoutJSON == rhs.layoutJSON && lhs.frame?.x == rhs.frame?.x && lhs.frame?.y == rhs.frame?.y
                && lhs.frame?.width == rhs.frame?.width && lhs.frame?.height == rhs.frame?.height
        }
    }

    public func upsertPanelWindow(_ record: PanelWindowRecord) throws {
        try execute(
            sql: """
                INSERT INTO panel_windows(id, layout_json, x, y, width, height, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  layout_json = excluded.layout_json,
                  x = excluded.x, y = excluded.y, width = excluded.width, height = excluded.height,
                  updated_at = excluded.updated_at
                """,
            bindings: [
                record.id, record.layoutJSON, record.frame.map { "\($0.x)" } ?? "", record.frame.map { "\($0.y)" } ?? "",
                record.frame.map { "\($0.width)" } ?? "", record.frame.map { "\($0.height)" } ?? "", Self.timestamp(),
            ])
    }

    public func panelWindows() throws -> [PanelWindowRecord] {
        try queryRows(sql: "SELECT id, layout_json, x, y, width, height FROM panel_windows ORDER BY updated_at, id").compactMap { row in
            guard row.count >= 6 else { return nil }
            let frame: (x: Double, y: Double, width: Double, height: Double)?
            if let x = Double(row[2]), let y = Double(row[3]), let width = Double(row[4]), let height = Double(row[5]) {
                frame = (x, y, width, height)
            } else {
                frame = nil
            }
            return PanelWindowRecord(id: row[0], layoutJSON: row[1], frame: frame)
        }
    }

    public func deletePanelWindow(id: String) throws { try execute(sql: "DELETE FROM panel_windows WHERE id = ?", bindings: [id]) }

    public func backupURLs() throws -> [URL] { try backupManager.existingBackups() }

    private func initializeSchema() throws {
        let tables = try userTableNames()
        if tables.isEmpty {
            try withImmediateTransaction {
                try createSchema()
                try setSchemaVersion(schemaVersion)
            }
            return
        }

        guard var version = try schemaVersionValue() else {
            try resetUnsupportedSchemaWithBackup(fromVersion: 0)
            return
        }
        guard version <= schemaVersion else {
            throw SpacesClientError.invalidArgument("Unsupported client database schema version \(version) at \(databasePath).")
        }
        guard version < schemaVersion else { return }

        let backupURL = try backupManager.createMigrationBackup(sourceHandle: db, fromVersion: version, toVersion: schemaVersion)
        do {
            while version < schemaVersion {
                // Upgrades run serially: every intermediate version's step applies in order, so a
                // missing step means the database cannot reach the current version at all.
                guard let step = migrationSteps.first(where: { $0.fromVersion == version }) else {
                    throw SpacesClientError.invalidArgument(
                        "No client database migration step exists from version \(version); cannot reach version \(schemaVersion).")
                }
                try withImmediateTransaction {
                    try step.apply(db)
                    try setSchemaVersion(step.toVersion)
                }
                version = step.toVersion
            }
        } catch {
            try restoreBackup(from: backupURL)
            throw error
        }
    }

    private func resetUnsupportedSchemaWithBackup(fromVersion: Int) throws {
        let backupURL = try backupManager.createMigrationBackup(sourceHandle: db, fromVersion: fromVersion, toVersion: schemaVersion)
        do {
            try withImmediateTransaction {
                try executeBatch(sql: Self.dropSchemaSQL)
                try createSchema()
                try setSchemaVersion(schemaVersion)
            }
        } catch {
            try restoreBackup(from: backupURL)
            throw error
        }
    }

    private func createSchema() throws { try executeBatch(sql: Self.schemaSQL) }

    private func setSchemaVersion(_ version: Int) throws {
        try execute(sql: "DELETE FROM migration_state")
        try execute(sql: "INSERT INTO migration_state(current_version) VALUES (?)", bindings: [version])
    }

    private func schemaVersionValue() throws -> Int? {
        do {
            let rows = try queryRows(sql: "SELECT current_version FROM migration_state")
            guard let raw = rows.first?.first, let value = Int(raw) else { return nil }
            return value
        } catch { return nil }
    }

    private func userTableNames() throws -> [String] {
        try queryRows(
            sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """
        ).compactMap(\.first)
    }

    private func restoreBackup(from backupURL: URL) throws {
        try withConnectionLock {
            var sourceHandle: OpaquePointer?
            guard sqlite3_open_v2(backupURL.path, &sourceHandle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let sourceHandle
            else { throw SpacesClientError.invalidArgument("Failed opening client database backup at \(backupURL.path).") }
            defer { sqlite3_close(sourceHandle) }

            guard let backup = sqlite3_backup_init(db, "main", sourceHandle, "main") else {
                throw SpacesClientError.invalidArgument(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_backup_finish(backup) }

            while true {
                let result = sqlite3_backup_step(backup, -1)
                if result == SQLITE_DONE { break }
                if result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED {
                    sqlite3_sleep(20)
                    continue
                }
                throw SpacesClientError.invalidArgument(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func configureConnectionPragmas() throws {
        try executeBatch(sql: "PRAGMA journal_mode=WAL;")
        try executeBatch(sql: "PRAGMA synchronous=NORMAL;")
        try executeBatch(sql: "PRAGMA foreign_keys=ON;")
        // The GUI app, spaces CLI, and MCP server write this database from separate processes
        // (pairing records); WAL alone still surfaces SQLITE_BUSY on write contention.
        try executeBatch(sql: "PRAGMA busy_timeout=5000;")
    }

    private func withImmediateTransaction<T>(_ body: () throws -> T) throws -> T {
        try withConnectionLock {
            try executeBatch(sql: "BEGIN IMMEDIATE;")
            do {
                let value = try body()
                try executeBatch(sql: "COMMIT;")
                return value
            } catch {
                try? executeBatch(sql: "ROLLBACK;")
                throw error
            }
        }
    }

    private func execute(sql: String, bindings: [Any] = []) throws {
        try withConnectionLock {
            let statement = try prepareStatement(sql: sql)
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw SpacesClientError.invalidArgument(String(cString: sqlite3_errmsg(db))) }
        }
    }

    private func queryRow(sql: String, bindings: [Any] = []) throws -> [String]? {
        try withConnectionLock {
            let statement = try prepareStatement(sql: sql)
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw SpacesClientError.invalidArgument(String(cString: sqlite3_errmsg(db))) }
            return extractRow(statement: statement)
        }
    }

    private func queryRows(sql: String, bindings: [Any] = []) throws -> [[String]] {
        try withConnectionLock {
            let statement = try prepareStatement(sql: sql)
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            var rows: [[String]] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW {
                    rows.append(extractRow(statement: statement))
                } else if result == SQLITE_DONE {
                    return rows
                } else {
                    throw SpacesClientError.invalidArgument(String(cString: sqlite3_errmsg(db)))
                }
            }
        }
    }

    private func prepareStatement(sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SpacesClientError.invalidArgument(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func executeBatch(sql: String) throws {
        try withConnectionLock {
            var errorMessage: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
                let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
                if let errorMessage { sqlite3_free(errorMessage) }
                throw SpacesClientError.invalidArgument(message)
            }
        }
    }

    private func withConnectionLock<T>(_ body: () throws -> T) throws -> T {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return try body()
    }

    private func bind(_ bindings: [Any], to statement: OpaquePointer) throws {
        for (index, value) in bindings.enumerated() {
            let slot = Int32(index + 1)
            switch value {
            case let value as String: sqlite3_bind_text(statement, slot, value, -1, sqliteTransient)
            case let value as Int: sqlite3_bind_int64(statement, slot, sqlite3_int64(value))
            case let value as Double: sqlite3_bind_double(statement, slot, value)
            case _ as NSNull: sqlite3_bind_null(statement, slot)
            default: throw SpacesClientError.invalidArgument("Unsupported client database binding type \(type(of: value)).")
            }
        }
    }

    private func extractRow(statement: OpaquePointer) -> [String] {
        (0..<sqlite3_column_count(statement)).map { index in sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
    }

    private func decodeDevice(row: [String]) -> SpacesPairedDeviceRecord? {
        guard row.count >= 12, let port = Int(row[4]) else { return nil }
        return SpacesPairedDeviceRecord(
            id: row[0], name: row[1], platform: row[2], host: row[3], port: port, certificateFingerprint: row[5], sshHost: normalized(row[6]),
            sshUser: normalized(row[7]), sshPort: Int(row[8]), createdAt: row[9], updatedAt: row[10], lastSelectedAt: normalized(row[11]))
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let schemaSQL = """
            CREATE TABLE IF NOT EXISTS paired_devices (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              platform TEXT NOT NULL,
              host TEXT NOT NULL,
              port INTEGER NOT NULL,
              certificate_fingerprint TEXT NOT NULL,
              ssh_host TEXT,
              ssh_user TEXT,
              ssh_port INTEGER,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              last_selected_at TEXT
            );

            \(clientStateSchemaSQL)

            \(browserSessionWindowIDsSchemaSQL)

            \(panelLayoutsSchemaSQL)

            CREATE TABLE IF NOT EXISTS migration_state (
              current_version INTEGER NOT NULL
            );
        """

    private static let dropSchemaSQL = """
            DROP TABLE IF EXISTS panel_windows;
            DROP TABLE IF EXISTS workspace_panel_layouts;
            DROP TABLE IF EXISTS browser_session_window_ids;
            DROP TABLE IF EXISTS desktop_window_ids;
            DROP TABLE IF EXISTS local_window_focus_state;
            DROP TABLE IF EXISTS runtime_target_events;
            DROP TABLE IF EXISTS browser_targets;
            DROP TABLE IF EXISTS runtime_targets;
            DROP TABLE IF EXISTS terminal_window_frames;
            DROP TABLE IF EXISTS project_sidebar_state;
            DROP TABLE IF EXISTS client_settings;
            DROP TABLE IF EXISTS paired_devices;
            DROP TABLE IF EXISTS migration_state;
        """

    private static let clientStateSchemaSQL = """
            CREATE TABLE IF NOT EXISTS client_settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS project_sidebar_state (
              device_id TEXT NOT NULL,
              project_id TEXT NOT NULL,
              is_collapsed INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (device_id, project_id)
            );

        """

    // Browser session windows are client/desktop-local: the dedicated Chrome window opened for
    // a workspace browser session exists only on this desktop and is keyed by the session's
    // resolved target URL. Keeping it client-side replaces the daemon's former
    // `extracted_window_id` so the daemon persists no desktop overlay.
    private static let browserSessionWindowIDsSchemaSQL = """
            CREATE TABLE IF NOT EXISTS browser_session_window_ids (
              device_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              target_url TEXT NOT NULL,
              window_id INTEGER NOT NULL,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (device_id, workspace_id, target_url)
            );
        """

    // Panel layouts are client-local UI state: which sessions are open in which
    // tabs/panes per workspace, plus extra panel windows, as a versioned JSON document
    // per panel (see `PanelLayout` in spacesui).
    private static let panelLayoutsSchemaSQL = """
            CREATE TABLE IF NOT EXISTS workspace_panel_layouts (
              device_id TEXT NOT NULL,
              workspace_id TEXT NOT NULL,
              layout_json TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (device_id, workspace_id)
            );

            CREATE TABLE IF NOT EXISTS panel_windows (
              id TEXT PRIMARY KEY,
              layout_json TEXT NOT NULL,
              x REAL,
              y REAL,
              width REAL,
              height REAL,
              updated_at TEXT NOT NULL
            );
        """

    public static let defaultMigrationSteps: [SpacesClientMigrationStep] = [
        SpacesClientMigrationStep(fromVersion: 1, toVersion: 2, description: "Add Mac client UI state") { database in
            try executeClientBatch(database: database, sql: clientStateSchemaSQL)
        }, SpacesClientMigrationStep(fromVersion: 2, toVersion: 3, description: "Reserve dropped desktop window IDs version") { _ in },
        SpacesClientMigrationStep(fromVersion: 3, toVersion: 4, description: "Add client-owned browser session window IDs") { database in
            try executeClientBatch(database: database, sql: browserSessionWindowIDsSchemaSQL)
        }, SpacesClientMigrationStep(fromVersion: 4, toVersion: 5, description: "Reserve merged client schema version") { _ in },
        SpacesClientMigrationStep(fromVersion: 5, toVersion: 6, description: "Add panel layouts") { database in
            try executeClientBatch(database: database, sql: panelLayoutsSchemaSQL)
        },
        // Drops tables nothing reads or writes: terminal_window_frames is from the
        // one-window-per-terminal era (panes in panel layouts replaced it), and the rest were
        // scaffolded for the thin-client split before panes removed desktop window identity.
        SpacesClientMigrationStep(fromVersion: 6, toVersion: 7, description: "Drop unused window tracking tables") { database in
            try executeClientBatch(
                database: database,
                sql: """
                    DROP TABLE IF EXISTS terminal_window_frames;
                    DROP TABLE IF EXISTS runtime_target_events;
                    DROP TABLE IF EXISTS browser_targets;
                    DROP TABLE IF EXISTS runtime_targets;
                    DROP TABLE IF EXISTS local_window_focus_state;
                    DROP TABLE IF EXISTS desktop_window_ids;
                    """)
        },
    ]

    private static func timestamp() -> String { timestampFormatter.string(from: Date()) }
}

private final class DefaultDatabaseStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var path: String?
    private var cachedDatabase: SpacesClientDatabase?

    func database() throws -> SpacesClientDatabase {
        let resolvedPath = try SpacesClientDatabase.defaultPath()
        lock.lock()
        defer { lock.unlock() }
        if let cachedDatabase, path == resolvedPath { return cachedDatabase }
        let database = try SpacesClientDatabase(path: resolvedPath)
        path = resolvedPath
        cachedDatabase = database
        return database
    }
}

private final class TimestampFormatterStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func executeClientBatch(database: OpaquePointer, sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(database, sql, nil, nil, &errorMessage) != SQLITE_OK {
        let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
        if let errorMessage { sqlite3_free(errorMessage) }
        throw SpacesClientError.invalidArgument(message)
    }
}
