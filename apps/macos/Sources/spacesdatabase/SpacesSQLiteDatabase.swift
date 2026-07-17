import Foundation

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

public final class SpacesSQLiteDatabase {
    private let db: OpaquePointer
    private let databasePath: String
    private let busyTimeoutMS: Int32 = 5000
    private let busyRetryAttempts = 10
    private let busyRetryDelaySeconds: TimeInterval = 0.02

    public init(path: String, withMigrationAuthorization: (() throws -> Void) throws -> Void = { try $0() }) throws {
        databasePath = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let openFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, openFlags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed opening sqlite db at \(path)"
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "spaces.database", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let handle else { throw NSError(domain: "spaces.database", code: 1, userInfo: [NSLocalizedDescriptionKey: "DB handle is nil"]) }
        db = handle
        guard sqlite3_busy_timeout(db, busyTimeoutMS) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(
                domain: "spaces.database", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed configuring sqlite busy timeout: \(message)"])
        }
        try configureConnectionPragmas()
        try initializeSchema(withMigrationAuthorization: withMigrationAuthorization)
    }

    deinit { sqlite3_close(db) }

    public func withImmediateTransaction<T>(_ body: () throws -> T) throws -> T {
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

    public func execute(sql: String, bindings: [Any] = []) throws {
        let statement = try prepareStatement(sql: sql, errorCode: 3)
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        if try stepWithRetry(statement: statement) != SQLITE_DONE {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.database", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    public func queryRow(sql: String, bindings: [Any] = []) throws -> [String]? {
        let statement = try prepareStatement(sql: sql, errorCode: 5)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = try stepWithRetry(statement: statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "spaces.database", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return extractRow(statement: statement)
    }

    public func queryRows(sql: String, bindings: [Any] = []) throws -> [[String]] {
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
            throw NSError(domain: "spaces.database", code: 8, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return rows
    }

    private func createSchema() throws { try executeBatch(sql: DatabaseSchema.latestSchemaSQL) }

    private func initializeSchema(withMigrationAuthorization: (() throws -> Void) throws -> Void) throws {
        let migrator = DatabaseMigrator(
            currentSchemaVersion: DatabaseSchema.currentVersion, steps: DatabaseSchema.migrationSteps,
            backupManager: DatabaseBackupManager(databaseURL: URL(fileURLWithPath: databasePath)))
        try migrator.migrateIfNeeded(
            databasePath: databasePath, databaseHandle: db, readExistingTables: { try self.userTableNames() },
            readSchemaVersion: { try self.schemaVersionValue() }, createFreshSchema: { try self.createSchema() },
            setSchemaVersion: { try self.setSchemaVersion($0) }, withTransaction: { try self.withImmediateTransaction($0) },
            validateIntegrity: { try self.validateIntegrity() }, withMigrationAuthorization: withMigrationAuthorization)
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
        try execute(sql: "INSERT INTO migration_state(current_version) VALUES (?)", bindings: [version])
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
            throw NSError(domain: "spaces.database", code: 45, userInfo: [NSLocalizedDescriptionKey: "PRAGMA integrity_check failed"])
        }
    }

    private func configureConnectionPragmas() throws {
        try executeBatch(sql: "PRAGMA journal_mode=WAL;")
        try executeBatch(sql: "PRAGMA synchronous=NORMAL;")
        try executeBatch(sql: "PRAGMA foreign_keys=ON;")
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
            throw NSError(domain: "spaces.database", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
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
            throw NSError(domain: "spaces.database", code: errorCode, userInfo: [NSLocalizedDescriptionKey: message])
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
            case let integer as Int: sqlite3_bind_int64(statement, slot, sqlite3_int64(integer))
            case let integer as Int32: sqlite3_bind_int64(statement, slot, sqlite3_int64(integer))
            case let integer as Int64: sqlite3_bind_int64(statement, slot, sqlite3_int64(integer))
            case let double as Double: sqlite3_bind_double(statement, slot, double)
            case let bool as Bool: sqlite3_bind_int(statement, slot, bool ? 1 : 0)
            case _ as NSNull: sqlite3_bind_null(statement, slot)
            default:
                throw NSError(
                    domain: "spaces.database", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unsupported sqlite binding type \(type(of: value))"])
            }
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
