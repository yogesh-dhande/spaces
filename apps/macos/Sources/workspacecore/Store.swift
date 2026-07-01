import Foundation
import spacesdatabase
import spacesterminalcore
import systembridge

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

public final class SQLiteStore {
    private let db: OpaquePointer
    private let databasePath: String
    private let busyTimeoutMS: Int32 = 5000
    private let busyRetryAttempts = 10
    private let busyRetryDelaySeconds: TimeInterval = 0.02
    /// Depth of open explicit transactions. Autocommit writes (`execute` at depth
    /// zero) post a change signal immediately; statements inside a transaction
    /// defer to the single post after `COMMIT`, so a reload never observes
    /// uncommitted state. One connection serializes its own writes, so a plain
    /// counter is sufficient.
    private var openTransactionCount = 0

    /// Desktop (yabai) window IDs live outside the daemon database. The GUI injects a
    /// client-database-backed store so window-ID reads/writes are correlated to daemon-owned
    /// runtime targets without persisting any desktop state in `spaces.db`. The daemon and CLI
    /// leave this nil — they have no desktop session and never focus windows.
    public let desktopWindowIDStore: DesktopWindowIDStore?

    public init(path: String, desktopWindowIDStore: DesktopWindowIDStore? = nil) throws {
        databasePath = path
        self.desktopWindowIDStore = desktopWindowIDStore
        var handle: OpaquePointer?
        let openFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, openFlags, nil) != SQLITE_OK {
            throw NSError(domain: "spaces.store", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed opening sqlite db at \(path)"])
        }
        guard let handle else { throw NSError(domain: "spaces.store", code: 1, userInfo: [NSLocalizedDescriptionKey: "DB handle is nil"]) }
        db = handle
        guard sqlite3_busy_timeout(db, busyTimeoutMS) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(
                domain: "spaces.store", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed configuring sqlite busy timeout: \(message)"])
        }
        try configureConnectionPragmas()
        try initializeSchema()
    }

    deinit { sqlite3_close(db) }

    func withImmediateTransaction<T>(_ body: () throws -> T) throws -> T {
        try executeBatch(sql: "BEGIN IMMEDIATE;")
        openTransactionCount += 1
        do {
            let value = try body()
            try executeBatch(sql: "COMMIT;")
            openTransactionCount -= 1
            Self.postDatabaseDidChange()
            return value
        } catch {
            try? executeBatch(sql: "ROLLBACK;")
            openTransactionCount -= 1
            throw error
        }
    }

    /// Announces a committed write so the app reloads sidebar metadata, and so the
    /// daemon's Device API can push a fresh overview to paired clients, in response
    /// to the writer rather than by watching database files. Posted synchronously so
    /// a short-lived CLI delivers the signal before it exits. Suppressed under tests
    /// to avoid cross-process noise.
    private static func postDatabaseDidChange() {
        guard NSClassFromString("XCTest") == nil else { return }
        DatabaseChangeSignal.post()
    }

    public func setting(key: String) throws -> String? {
        let rows = try queryRows(sql: "SELECT value FROM settings WHERE key = ?", bindings: [key])
        guard let value = rows.first?.first else { return nil }
        return value
    }

    public func setSetting(key: String, value: String?) throws {
        if let value {
            try execute(
                sql: "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", bindings: [key, value])
        } else {
            try execute(sql: "DELETE FROM settings WHERE key = ?", bindings: [key])
        }
    }

    public func appConfig() throws -> AppConfig {
        let start = try setting(key: SettingsKey.appPortRangeStart).flatMap(Int.init) ?? 20000
        let end = try setting(key: SettingsKey.appPortRangeEnd).flatMap(Int.init) ?? 30000
        let portRange = (start <= 0 || end <= 0 || end <= start) ? PortRange.default : PortRange(start: start, end: end)
        return AppConfig(portRange: portRange)
    }

    public func setAppConfig(_ config: AppConfig) throws {
        try setSetting(key: SettingsKey.appPortRangeStart, value: String(config.portRange.start))
        try setSetting(key: SettingsKey.appPortRangeEnd, value: String(config.portRange.end))
    }

    private func createSchema() throws { try executeBatch(sql: DatabaseSchema.latestSchemaSQL) }

    private func initializeSchema() throws {
        let migrator = DatabaseMigrator(
            currentSchemaVersion: DatabaseSchema.currentVersion, steps: DatabaseSchema.migrationSteps,
            backupManager: DatabaseBackupManager(databaseURL: URL(fileURLWithPath: databasePath)))
        try migrator.migrateIfNeeded(
            existingTables: try userTableNames(), schemaVersion: try schemaVersionValue(), databasePath: databasePath, databaseHandle: db,
            createFreshSchema: { try self.createSchema() }, setSchemaVersion: { try self.setSchemaVersion($0) },
            withTransaction: { try self.withImmediateTransaction($0) }, validateIntegrity: { try self.validateIntegrity() })
    }

    private func schemaVersionValue() throws -> Int? {
        do {
            let rows = try queryRows(sql: "SELECT current_version FROM migration_state")
            guard let raw = rows.first?.first, let value = Int(raw) else { return nil }
            return value
        } catch { return nil }
    }

    private func setSchemaVersion(_ version: Int) throws {
        try execute(sql: "DELETE FROM migration_state", bindings: [])
        try execute(sql: "INSERT INTO migration_state(current_version) VALUES (?)", bindings: [String(version)])
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

    private func validateIntegrity() throws {
        guard let row = try queryRow(sql: "PRAGMA integrity_check"), row.first == "ok" else {
            throw NSError(domain: "spaces.store", code: 45, userInfo: [NSLocalizedDescriptionKey: "PRAGMA integrity_check failed"])
        }
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    func decodeTerminalTarget(runtimeTargetID: String, app: String, name: String, detail: String, windowID: Int?, trackingID: String)
        -> TerminalTargetRecord?
    {
        guard !runtimeTargetID.isEmpty || !app.isEmpty || !trackingID.isEmpty || windowID != nil else { return nil }
        return TerminalTargetRecord(
            runtimeTargetID: runtimeTargetID.isEmpty ? nil : runtimeTargetID, windowID: windowID, trackingID: trackingID.isEmpty ? nil : trackingID)
    }

    // MARK: - Desktop window-ID correlation

    /// Reads the captured desktop window ID for a runtime target, if a client store is injected.
    /// Best-effort: a lookup failure yields nil so focus can fall back to session/IPC paths.
    func overlaidWindowID(workspaceID: String, runtimeTargetID: String?) -> Int? {
        guard let desktopWindowIDStore, let runtimeTargetID, !runtimeTargetID.isEmpty else { return nil }
        return try? desktopWindowIDStore.desktopWindowID(workspaceID: workspaceID, runtimeTargetID: runtimeTargetID)
    }

    /// Persists (or clears) the captured desktop window ID for a runtime target.
    func persistDesktopWindowID(workspaceID: String, runtimeTargetID: String, windowID: Int?) throws {
        guard let desktopWindowIDStore else { return }
        if let windowID {
            try desktopWindowIDStore.setDesktopWindowID(workspaceID: workspaceID, runtimeTargetID: runtimeTargetID, windowID: windowID)
        } else {
            try desktopWindowIDStore.clearDesktopWindowID(workspaceID: workspaceID, runtimeTargetID: runtimeTargetID)
        }
    }

    func nextRuntimeTargetOrderIndex(existing: [WindowRecord], role: String, orderOffset: Int) -> Int {
        let roleWindows = existing.filter { $0.role == role }
        let maxIndex = roleWindows.map(\.orderIndex).max() ?? (orderOffset - 1)
        return maxIndex + 1
    }

    func matchingRuntimeTargetID(workspaceID: String, trackingID: String?) throws -> String? {
        guard let trackingID, !trackingID.isEmpty else { return nil }
        let rows = try queryRows(
            sql: """
                SELECT
                  rt.id,
                  COALESCE(rt.tracking_id, '')
                FROM runtime_targets rt
                WHERE rt.workspace_id = ?
                  AND rt.type = 'terminal'
                ORDER BY rt.updated_at DESC
                """, bindings: [workspaceID])
        return rows.first(where: { $0[1] == trackingID })?.first
    }

    private func executeBatch(sql: String) throws {
        var attempts = 0
        while true {
            let result = sqlite3_exec(db, sql, nil, nil, nil)
            if result == SQLITE_OK { return }
            if isBusyOrLocked(result), attempts < busyRetryAttempts {
                attempts += 1
                Thread.sleep(forTimeInterval: busyRetryDelaySeconds)
                continue
            }
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.store", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func execute(sql: String, bindings: [Any]) throws {
        let statement = try prepareStatement(sql: sql, errorCode: 3)
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        if try stepWithRetry(statement: statement) != SQLITE_DONE {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.store", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
        // `execute` only runs mutating statements; reads use `queryRow(s)`. An
        // autocommit write (no open transaction) is durable now, so signal it.
        if openTransactionCount == 0 { Self.postDatabaseDidChange() }
    }

    func queryRow(sql: String, bindings: [Any] = []) throws -> [String]? {
        let statement = try prepareStatement(sql: sql, errorCode: 5)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = try stepWithRetry(statement: statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.store", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return extractRow(statement: statement)
    }

    func queryRows(sql: String, bindings: [Any] = []) throws -> [[String]] {
        let statement = try prepareStatement(sql: sql, errorCode: 7)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [[String]] = []
        while true {
            let result = try stepWithRetry(statement: statement)
            if result == SQLITE_ROW {
                rows.append(extractRow(statement: statement))
                continue
            }
            if result == SQLITE_DONE { break }
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.store", code: 8, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return rows
    }

    private func configureConnectionPragmas() throws {
        try executeBatch(sql: "PRAGMA journal_mode=WAL;")
        try executeBatch(sql: "PRAGMA synchronous=NORMAL;")
        try executeBatch(sql: "PRAGMA foreign_keys=ON;")
    }

    private func prepareStatement(sql: String, errorCode: Int) throws -> OpaquePointer {
        var attempts = 0
        while true {
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            if result == SQLITE_OK, let statement { return statement }
            if isBusyOrLocked(result), attempts < busyRetryAttempts {
                attempts += 1
                Thread.sleep(forTimeInterval: busyRetryDelaySeconds)
                continue
            }
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.store", code: errorCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func stepWithRetry(statement: OpaquePointer) throws -> Int32 {
        var attempts = 0
        while true {
            let result = sqlite3_step(statement)
            if isBusyOrLocked(result), attempts < busyRetryAttempts {
                attempts += 1
                Thread.sleep(forTimeInterval: busyRetryDelaySeconds)
                continue
            }
            return result
        }
    }

    private func isBusyOrLocked(_ code: Int32) -> Bool { code == SQLITE_BUSY || code == SQLITE_LOCKED }

    private func extractRow(statement: OpaquePointer) -> [String] {
        let columnCount = Int(sqlite3_column_count(statement))
        var row: [String] = []
        row.reserveCapacity(columnCount)
        for idx in 0..<columnCount {
            let text = sqlite3_column_text(statement, Int32(idx))
            row.append(text.map { String(cString: $0) } ?? "")
        }
        return row
    }

    private func bind(_ bindings: [Any], to statement: OpaquePointer) throws {
        for (index, value) in bindings.enumerated() {
            let slot = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, slot, text, -1, sqliteTransient)
            default: throw NSError(domain: "spaces.store", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unsupported binding type"])
            }
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension Array { fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
