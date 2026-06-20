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
    public static let currentVersion = 1

    private let db: OpaquePointer
    private let databasePath: String
    private let schemaVersion: Int
    private let migrationSteps: [SpacesClientMigrationStep]
    private let backupManager: DatabaseBackupManager

    public init(path: String? = nil, currentVersion: Int = SpacesClientDatabase.currentVersion, migrationSteps: [SpacesClientMigrationStep] = [])
        throws
    {
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
        try withImmediateTransaction {
            try execute(sql: "DELETE FROM paired_devices WHERE id = ?", bindings: [id])
            if try activeDeviceID() == id { try setActiveDeviceID(nil) }
        }
    }

    public func activeDeviceID() throws -> String? {
        guard let row = try queryRow(sql: "SELECT value FROM client_settings WHERE key = 'active_device_id'"), let value = row.first else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func setActiveDeviceID(_ id: String?) throws {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            try execute(sql: "DELETE FROM client_settings WHERE key = 'active_device_id'")
        } else {
            try execute(
                sql: """
                    INSERT INTO client_settings(key, value)
                    VALUES ('active_device_id', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """, bindings: [trimmed])
        }
    }

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
                guard let step = migrationSteps.first(where: { $0.fromVersion == version }) else {
                    throw SpacesClientError.invalidArgument("No client database migration path from \(version) to \(schemaVersion).")
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
        var sourceHandle: OpaquePointer?
        guard sqlite3_open_v2(backupURL.path, &sourceHandle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let sourceHandle else {
            throw SpacesClientError.invalidArgument("Failed opening client database backup at \(backupURL.path).")
        }
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

    private func configureConnectionPragmas() throws {
        try executeBatch(sql: "PRAGMA journal_mode=WAL;")
        try executeBatch(sql: "PRAGMA synchronous=NORMAL;")
        try executeBatch(sql: "PRAGMA foreign_keys=ON;")
    }

    private func withImmediateTransaction<T>(_ body: () throws -> T) throws -> T {
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

    private func execute(sql: String, bindings: [Any] = []) throws {
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SpacesClientError.invalidArgument(String(cString: sqlite3_errmsg(db))) }
    }

    private func queryRow(sql: String, bindings: [Any] = []) throws -> [String]? {
        let statement = try prepareStatement(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw SpacesClientError.invalidArgument(String(cString: sqlite3_errmsg(db))) }
        return extractRow(statement: statement)
    }

    private func queryRows(sql: String, bindings: [Any] = []) throws -> [[String]] {
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

    private func prepareStatement(sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SpacesClientError.invalidArgument(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func executeBatch(sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let errorMessage { sqlite3_free(errorMessage) }
            throw SpacesClientError.invalidArgument(message)
        }
    }

    private func bind(_ bindings: [Any], to statement: OpaquePointer) throws {
        for (index, value) in bindings.enumerated() {
            let slot = Int32(index + 1)
            switch value {
            case let value as String: sqlite3_bind_text(statement, slot, value, -1, sqliteTransient)
            case let value as Int: sqlite3_bind_int64(statement, slot, sqlite3_int64(value))
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

            CREATE TABLE IF NOT EXISTS client_settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS migration_state (
              current_version INTEGER NOT NULL
            );
        """

    private static let dropSchemaSQL = """
            DROP TABLE IF EXISTS paired_devices;
            DROP TABLE IF EXISTS client_settings;
            DROP TABLE IF EXISTS migration_state;
        """
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
