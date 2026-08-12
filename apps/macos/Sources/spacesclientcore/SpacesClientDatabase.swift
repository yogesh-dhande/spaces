import Foundation
import spacesdatabase
import spacesdevicecore
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
    /// Upper bound on the candidate addresses stored for one device. The shared policy, so a record, a
    /// merge, and a redeemed pairing link are all bounded by one number; matched by the iOS client's
    /// `SpacesMobileDeviceStore.maxAdvertisedHostCandidates`.
    public static let maxHostCandidates = SpacesDeviceHostCandidates.maxCount

    public let id: String
    public var name: String
    public var platform: String
    /// Ordered Device API candidate addresses, most-preferred first: a pairing link's LAN address ahead
    /// of its tailnet address, and after a merge the daemon's own current addresses ahead of anything
    /// only this client still remembers. Never empty for a stored record.
    public var hosts: [String]
    /// The candidate a connection last actually succeeded on, or nil until one is proven. Always a
    /// member of `hosts`.
    public var activeHost: String?
    public var port: Int
    public var certificateFingerprint: String
    public var sshHost: String?
    public var sshUser: String?
    public var sshPort: Int?
    public var createdAt: String
    public var updatedAt: String
    public var lastSelectedAt: String?

    /// The address to dial right now: the proven one when there is one, otherwise the most-preferred
    /// candidate.
    public var dialHost: String? { activeHost ?? hosts.first }

    public init(
        id: String, name: String, platform: String, hosts: [String], activeHost: String? = nil, port: Int, certificateFingerprint: String,
        sshHost: String? = nil, sshUser: String? = nil, sshPort: Int? = nil, createdAt: String, updatedAt: String, lastSelectedAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.hosts = hosts
        self.activeHost = activeHost
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
    public static let currentVersion = 3
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

    public static func defaultPath(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser, executablePath: String? = nil,
        gitProbe: SpacesGitProfileProbe = LiveSpacesGitProfileProbe()
    ) throws -> String {
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
            executablePath: executablePath ?? SpacesProfile.currentExecutablePath(currentDirectoryPath: currentDirectoryPath), gitProbe: gitProbe)
        return URL(fileURLWithPath: profile.rootDirectory, isDirectory: true).appendingPathComponent("Client", isDirectory: true)
            .appendingPathComponent("spaces-client.db", isDirectory: false).path
    }

    /// Cheap fingerprint of everything that decides what `defaultPath()` resolves to, read directly via
    /// `getenv`/`getcwd` instead of by calling `defaultPath()` itself, so `DefaultDatabaseStorage` can tell
    /// whether a previously resolved path is still valid WITHOUT re-running resolution — in particular,
    /// without re-spawning the git probe a repo-local dev build's `SpacesProfile.resolveDevelopmentContext`
    /// runs on every resolution (see `LiveSpacesGitProfileProbe`). Mirrors the inputs `SpacesProfile.resolve`
    /// itself consults (its two profile environment overrides, `HOME`, the working directory, and the
    /// resolved executable path), plus this type's own `SPACES_CLIENT_DB_PATH` override that `defaultPath()`
    /// checks first. `executablePathOverride` mirrors `defaultPath(executablePath:)`'s test-only override so
    /// the key and the resolution it guards never disagree about which executable path they used.
    fileprivate static func defaultPathCacheKey(executablePathOverride: String? = nil) -> String {
        let currentDirectoryPath = FileManager.default.currentDirectoryPath
        let executablePath = executablePathOverride ?? SpacesProfile.currentExecutablePath(currentDirectoryPath: currentDirectoryPath)
        let environmentValues = [
            databasePathEnvironmentVariable, SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable, "HOME",
        ].map { currentEnvironmentValue(for: $0) ?? "" }
        return (environmentValues + [currentDirectoryPath, executablePath ?? ""]).joined(separator: "\u{1f}")
    }

    private static func currentEnvironmentValue(for key: String) -> String? {
        guard let rawValue = getenv(key) else { return nil }
        return String(cString: rawValue)
    }

    public static func defaultDatabase() throws -> SpacesClientDatabase { try defaultDatabaseStorage.database() }

    /// Test-only seam: rewires the process-wide default-database cache to a stub git probe (and,
    /// optionally, a fixed executable path — `swift test` runs under the system `xctest` agent rather
    /// than this repo's own test binary, so `SpacesProfile.currentExecutablePath()`'s real answer never
    /// lands inside a checkout and can't exercise the repo-local dev-build path a test wants to drive) and
    /// drops its cached path/database. Lets a test count profile-resolution git spawns via
    /// `defaultDatabase()` without touching real git. Never called from product code.
    static func resetDefaultDatabaseStorageForTesting(gitProbe: SpacesGitProfileProbe = LiveSpacesGitProfileProbe(), executablePath: String? = nil) {
        defaultDatabaseStorage.resetForTesting(gitProbe: gitProbe, executablePathOverride: executablePath)
    }

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
                  id, name, platform, hosts, active_host, port, certificate_fingerprint, ssh_host, ssh_user, ssh_port, created_at, updated_at,
                  last_selected_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  platform = excluded.platform,
                  hosts = excluded.hosts,
                  active_host = excluded.active_host,
                  port = excluded.port,
                  certificate_fingerprint = excluded.certificate_fingerprint,
                  ssh_host = excluded.ssh_host,
                  ssh_user = excluded.ssh_user,
                  ssh_port = excluded.ssh_port,
                  updated_at = excluded.updated_at,
                  last_selected_at = excluded.last_selected_at
                """,
            bindings: [
                device.id, device.name, device.platform, Self.encodeHosts(device.hosts), device.activeHost ?? "", device.port,
                device.certificateFingerprint, device.sshHost ?? "", device.sshUser ?? "", device.sshPort.map(String.init) ?? "", device.createdAt,
                device.updatedAt, device.lastSelectedAt ?? "",
            ])
    }

    public func pairedDevices() throws -> [SpacesPairedDeviceRecord] {
        try queryRows(
            sql: """
                SELECT id, name, platform, hosts, active_host, port, certificate_fingerprint, ssh_host, ssh_user, ssh_port, created_at, updated_at,
                  last_selected_at
                FROM paired_devices
                ORDER BY COALESCE(NULLIF(last_selected_at, ''), updated_at) DESC, name
                """
        ).compactMap(decodeDevice)
    }

    public func pairedDevice(id: String) throws -> SpacesPairedDeviceRecord? {
        try queryRow(
            sql: """
                SELECT id, name, platform, hosts, active_host, port, certificate_fingerprint, ssh_host, ssh_user, ssh_port, created_at, updated_at,
                  last_selected_at
                FROM paired_devices
                WHERE id = ?
                """, bindings: [id]
        ).flatMap(decodeDevice)
    }

    /// Records the candidate a connection just succeeded on, so the next connect dials it first (see
    /// `SpacesPairedDeviceRecord.dialHost`). Deliberately does not touch `last_selected_at`: proving an
    /// address is not the user selecting the device, and that column orders the device list.
    public func setActiveHost(deviceID: String, host: String) throws {
        try execute(sql: "UPDATE paired_devices SET active_host = ?, updated_at = ? WHERE id = ?", bindings: [host, Self.timestamp(), deviceID])
    }

    /// Folds the addresses a daemon reports for itself into a device's stored candidates, so an address
    /// this client has never seen becomes reachable without re-pairing. Returns the device's record after
    /// the merge, or nil when no device with that id is stored.
    ///
    /// An empty `advertised` list means the daemon reported nothing (the contract of
    /// `TerminalServiceDaemonStatus.deviceAPIAddresses`), not that it has no addresses, so it leaves the
    /// stored candidates untouched.
    @discardableResult public func mergeAdvertisedHosts(deviceID: String, advertised: [String]) throws -> SpacesPairedDeviceRecord? {
        try withImmediateTransaction {
            guard var record = try pairedDevice(id: deviceID) else { return nil }
            let merged = Self.mergedHostCandidates(stored: record.hosts, advertised: advertised)
            guard merged != record.hosts else { return record }
            record.hosts = merged
            // `activeHost` must stay a member of `hosts`. A proven address the daemon no longer reports
            // is a stored leftover, so the cap can trim it away; when it does, the next connect
            // re-evaluates from the top of the list instead of dialing an address no longer stored.
            if let activeHost = record.activeHost, !merged.contains(activeHost) { record.activeHost = nil }
            record.updatedAt = Self.timestamp()
            try upsert(device: record)
            return record
        }
    }

    /// The union `mergeAdvertisedHosts` persists: the daemon's own advertised addresses first, in its
    /// order (it reports LAN before tailnet, which is the dial preference we want), then whichever
    /// previously-stored addresses it did not report, in their own order, bounded from the tail.
    ///
    /// Leading with the daemon's list is what makes the merge self-healing: its current view is the fresh
    /// truth, so a stale stored address is demoted instead of sitting in front of one that works today,
    /// and the tail trim can only ever drop stored leftovers, never one of the daemon's current
    /// addresses. Keeping the leftovers at all still protects an address that arrived some other way and
    /// is absent from the daemon's own interface list, notably the SSH-resolved host a Mac proves and
    /// puts first when pairing a remote device (see `SpacesDevicePairingClient.relayedPairingHosts`).
    /// Mirrors the iOS client's `SpacesMobileDeviceStore.mergeAdvertisedHosts`, so both clients store the
    /// same order for the same device.
    static func mergedHostCandidates(stored: [String], advertised: [String]) -> [String] {
        let advertised = normalizedHostCandidates(advertised)
        guard !advertised.isEmpty else { return stored }
        var seen = Set<String>()
        var merged: [String] = []
        for host in advertised where seen.insert(host).inserted { merged.append(host) }
        for host in normalizedHostCandidates(stored) where seen.insert(host).inserted { merged.append(host) }
        if merged.count > SpacesPairedDeviceRecord.maxHostCandidates { merged.removeLast(merged.count - SpacesPairedDeviceRecord.maxHostCandidates) }
        return merged
    }

    private static func normalizedHostCandidates(_ hosts: [String]) -> [String] {
        hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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

    /// Records the Chrome window containing a workspace browser-session tab on the local
    /// desktop. A browser "window" is client/desktop-local state (not daemon state), keyed by
    /// the session's resolved target URL so re-focus returns to the same tab location.
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

    /// Every tracked Chrome window/tab mapping for a workspace's browser sessions, so the GUI can
    /// close the session tabs when the workspace stops.
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

    // MARK: - Terminal owner client ids

    /// Records the `TerminalClient` id this device used to attach to a terminal session as OWNER, so a
    /// relaunch of this Mac reuses the same id and the daemon's still-live `localWindow` owner
    /// attachment matches — letting the pane silently reclaim ownership instead of attaching as a
    /// viewer. Keyed by (device id, session id); session ids are globally unique.
    public func setTerminalOwnerClientID(deviceID: String, sessionID: String, clientID: String) throws {
        try execute(
            sql: """
                INSERT INTO terminal_owner_client_ids(device_id, session_id, client_id, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(device_id, session_id) DO UPDATE SET
                  client_id = excluded.client_id,
                  updated_at = excluded.updated_at
                """, bindings: [deviceID, sessionID, clientID, Self.timestamp()])
    }

    public func terminalOwnerClientID(deviceID: String, sessionID: String) throws -> String? {
        try queryRow(sql: "SELECT client_id FROM terminal_owner_client_ids WHERE device_id = ? AND session_id = ?", bindings: [deviceID, sessionID])?
            .first.flatMap(normalized)
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
            throw SpacesClientError.invalidArgument("Unsupported client database schema at \(databasePath): missing migration_state marker.")
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
        guard row.count >= 13, let port = Int(row[5]) else { return nil }
        // A record with no usable candidate address cannot be dialed at all, so it is dropped the same
        // way a row with an unreadable port is.
        guard let hosts = Self.decodeHosts(row[3]), !hosts.isEmpty else { return nil }
        let activeHost = normalized(row[4]).flatMap { hosts.contains($0) ? $0 : nil }
        return SpacesPairedDeviceRecord(
            id: row[0], name: row[1], platform: row[2], hosts: hosts, activeHost: activeHost, port: port, certificateFingerprint: row[6],
            sshHost: normalized(row[7]), sshUser: normalized(row[8]), sshPort: Int(row[9]), createdAt: row[10], updatedAt: row[11],
            lastSelectedAt: normalized(row[12]))
    }

    /// Candidate addresses are stored as one JSON array of strings, so their order (which decides dial
    /// preference) is part of the stored value rather than something a join has to reconstruct.
    static func encodeHosts(_ hosts: [String]) -> String {
        let normalized = normalizedHostCandidates(hosts)
        guard let data = try? JSONEncoder().encode(normalized), let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static func decodeHosts(_ value: String) -> [String]? {
        guard let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        var seen = Set<String>()
        return normalizedHostCandidates(decoded).filter { seen.insert($0).inserted }
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let schemaSQL = """
            \(pairedDevicesSchemaSQL)

            \(clientStateSchemaSQL)

            \(browserSessionWindowIDsSchemaSQL)

            \(terminalOwnerClientIDsSchemaSQL)

            \(panelLayoutsSchemaSQL)

            CREATE TABLE IF NOT EXISTS migration_state (
              current_version INTEGER NOT NULL
            );
        """

    // `hosts` holds the ordered candidate Device API addresses as a JSON array of strings (see
    // `encodeHosts`); `active_host` holds whichever of them a connection last succeeded on.
    private static let pairedDevicesSchemaSQL = """
            CREATE TABLE IF NOT EXISTS paired_devices (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              platform TEXT NOT NULL,
              hosts TEXT NOT NULL,
              active_host TEXT,
              port INTEGER NOT NULL,
              certificate_fingerprint TEXT NOT NULL,
              ssh_host TEXT,
              ssh_user TEXT,
              ssh_port INTEGER,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              last_selected_at TEXT
            );
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

    // Browser session windows are client/desktop-local: the Chrome window containing a workspace
    // browser-session tab exists only on this desktop and is keyed by the session's resolved
    // target URL. Keeping it client-side replaces the daemon's former
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

    // Terminal owner client ids are client/device-local: the `TerminalClient` id this Mac last used
    // to attach to a session as OWNER. Reusing it across app relaunches lets the pane reclaim the
    // daemon's orphaned, never-expiring `localWindow` owner attachment silently (see
    // `setTerminalOwnerClientID`). The stored UUID exists only on this Mac, so it can only ever match
    // THIS device's own prior attachment.
    private static let terminalOwnerClientIDsSchemaSQL = """
            CREATE TABLE IF NOT EXISTS terminal_owner_client_ids (
              device_id TEXT NOT NULL,
              session_id TEXT NOT NULL,
              client_id TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (device_id, session_id)
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

    // A database without a current `migration_state` marker fails closed instead of migrating or
    // resetting (see `initializeSchema`). Databases already carrying a marker upgrade serially: each
    // step moves exactly one version forward and carries existing data forward untouched.
    public static let defaultMigrationSteps: [SpacesClientMigrationStep] = [
        SpacesClientMigrationStep(
            fromVersion: 1, toVersion: 2, description: "Add terminal_owner_client_ids for stable per-device terminal owner client ids"
        ) { db in try executeClientBatch(database: db, sql: terminalOwnerClientIDsSchemaSQL) },
        SpacesClientMigrationStep(fromVersion: 2, toVersion: 3, description: "Replace the paired device's single host with an ordered candidate list")
        { db in
            try executeClientBatch(
                database: db,
                sql: """
                    CREATE TABLE paired_devices_v3 (
                      id TEXT PRIMARY KEY,
                      name TEXT NOT NULL,
                      platform TEXT NOT NULL,
                      hosts TEXT NOT NULL,
                      active_host TEXT,
                      port INTEGER NOT NULL,
                      certificate_fingerprint TEXT NOT NULL,
                      ssh_host TEXT,
                      ssh_user TEXT,
                      ssh_port INTEGER,
                      created_at TEXT NOT NULL,
                      updated_at TEXT NOT NULL,
                      last_selected_at TEXT
                    );

                    INSERT INTO paired_devices_v3(
                      id, name, platform, hosts, active_host, port, certificate_fingerprint, ssh_host, ssh_user, ssh_port, created_at, updated_at,
                      last_selected_at
                    )
                    SELECT id, name, platform, '', NULL, port, certificate_fingerprint, ssh_host, ssh_user, ssh_port, created_at, updated_at,
                      last_selected_at
                    FROM paired_devices;
                    """)
            // The single stored host becomes the list's only candidate, JSON-encoded through the same
            // encoder every write uses rather than assembled in SQL, so an address carrying JSON
            // metacharacters cannot produce an unreadable value.
            for row in try queryClientRows(database: db, sql: "SELECT id, host FROM paired_devices") where row.count >= 2 {
                try executeClientStatement(
                    database: db, sql: "UPDATE paired_devices_v3 SET hosts = ? WHERE id = ?", bindings: [encodeHosts([row[1]]), row[0]])
            }
            try executeClientBatch(
                database: db,
                sql: """
                    DROP TABLE paired_devices;
                    ALTER TABLE paired_devices_v3 RENAME TO paired_devices;
                    """)
        },
    ]

    private static func timestamp() -> String { timestampFormatter.string(from: Date()) }
}

private final class DefaultDatabaseStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var gitProbe: SpacesGitProfileProbe
    private var executablePathOverride: String?
    private var cachedKey: String?
    private var cachedDatabase: SpacesClientDatabase?

    init(gitProbe: SpacesGitProfileProbe = LiveSpacesGitProfileProbe()) { self.gitProbe = gitProbe }

    /// Test-only: rewires this storage to a stub git probe (and optional fixed executable path) and
    /// forgets its cached resolution, so the next `database()` call re-resolves through the stub instead
    /// of returning an already-cached database from a previous probe/environment.
    func resetForTesting(gitProbe: SpacesGitProfileProbe, executablePathOverride: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.gitProbe = gitProbe
        self.executablePathOverride = executablePathOverride
        cachedKey = nil
        cachedDatabase = nil
    }

    /// Every read through `SpacesClientDatabase.defaultDatabase()` — including every shortcut-setting
    /// lookup the sidebar re-issues while it reloads — used to call `defaultPath()` first, which reruns
    /// full profile resolution (including a repo-local dev build's synchronous git probe) before this
    /// cache ever got a chance to compare paths. Checking `defaultPathCacheKey()` first skips resolution
    /// entirely when none of its cheap inputs changed, so the probe runs once per process per distinct
    /// key rather than once per call.
    ///
    /// The key intentionally excludes anything about the resolved profile's git state (branch, HEAD):
    /// a dev build that switches its worktree's branch while the app keeps running keeps resolving to the
    /// profile it launched with until relaunch, matching the paired daemon, which also resolves its
    /// profile once at launch.
    func database() throws -> SpacesClientDatabase {
        lock.lock()
        let gitProbe = self.gitProbe
        let executablePathOverride = self.executablePathOverride
        let key = SpacesClientDatabase.defaultPathCacheKey(executablePathOverride: executablePathOverride)
        if let cachedDatabase, cachedKey == key {
            defer { lock.unlock() }
            return cachedDatabase
        }
        lock.unlock()

        // Resolution (and the git probe it can run) happens outside the lock, matching this cache's
        // original shape, so a slow resolution never blocks an unrelated read of the already-cached
        // database on another thread.
        let resolvedPath = try SpacesClientDatabase.defaultPath(executablePath: executablePathOverride, gitProbe: gitProbe)

        lock.lock()
        defer { lock.unlock() }
        if let cachedDatabase, cachedKey == key { return cachedDatabase }
        let database = try SpacesClientDatabase(path: resolvedPath)
        cachedKey = key
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

/// Row reader for migration steps, which are `@Sendable` closures handed the raw connection and so
/// cannot reach `SpacesClientDatabase`'s own instance query helpers.
private func queryClientRows(database: OpaquePointer, sql: String) throws -> [[String]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw SpacesClientError.invalidArgument(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    var rows: [[String]] = []
    while true {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            rows.append(
                (0..<sqlite3_column_count(statement)).map { index in sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" })
        } else if result == SQLITE_DONE {
            return rows
        } else {
            throw SpacesClientError.invalidArgument(String(cString: sqlite3_errmsg(database)))
        }
    }
}

private func executeClientStatement(database: OpaquePointer, sql: String, bindings: [String]) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw SpacesClientError.invalidArgument(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    for (index, value) in bindings.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw SpacesClientError.invalidArgument(String(cString: sqlite3_errmsg(database))) }
}

private func executeClientBatch(database: OpaquePointer, sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(database, sql, nil, nil, &errorMessage) != SQLITE_OK {
        let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
        if let errorMessage { sqlite3_free(errorMessage) }
        throw SpacesClientError.invalidArgument(message)
    }
}
