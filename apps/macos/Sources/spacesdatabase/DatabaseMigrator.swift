import Foundation

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// Runs a multi-statement SQL batch on the raw connection handed to a migration step's `apply`
/// closure. Migration steps operate on the bare `OpaquePointer` (the migrator owns the surrounding
/// transaction), so they cannot reach `SpacesSQLiteDatabase.execute`; this mirrors its `sqlite3_exec`
/// error surfacing.
func migrationExecuteBatch(_ handle: OpaquePointer, sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(handle, sql, nil, nil, &errorMessage) != SQLITE_OK {
        let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
        if let errorMessage { sqlite3_free(errorMessage) }
        throw SpacesDatabaseError.migrationFailed(message: message)
    }
}

/// Whether `table` exists in the database a migration step is running against.
///
/// Steps normally name tables unconditionally, because a database at version N provably has whatever the
/// fresh schema and the earlier steps created. A step that has to touch a table it did not create itself
/// uses this to stay a no-op on a database that legitimately never had it, instead of aborting the whole
/// upgrade on a table its own work does not depend on.
func migrationTableExists(_ handle: OpaquePointer, table: String) throws -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", -1, &statement, nil) == SQLITE_OK else {
        throw SpacesDatabaseError.migrationFailed(message: String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    return sqlite3_step(statement) == SQLITE_ROW
}

public struct DatabaseMigrationStep: Sendable {
    public let fromVersion: Int
    public let toVersion: Int
    public let description: String
    public let requiresBackup: Bool
    public let apply: @Sendable (OpaquePointer) throws -> Void

    public init(
        fromVersion: Int, toVersion: Int, description: String, requiresBackup: Bool, apply: @escaping @Sendable (OpaquePointer) throws -> Void
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.description = description
        self.requiresBackup = requiresBackup
        self.apply = apply
    }
}

public struct DatabaseMigrator: Sendable {
    public let currentSchemaVersion: Int
    public let steps: [DatabaseMigrationStep]
    public let backupManager: DatabaseBackupManager

    public init(currentSchemaVersion: Int, steps: [DatabaseMigrationStep], backupManager: DatabaseBackupManager) {
        self.currentSchemaVersion = currentSchemaVersion
        self.steps = steps
        self.backupManager = backupManager
    }

    public func migrateIfNeeded(
        databasePath: String, databaseHandle: OpaquePointer, readExistingTables: @escaping () throws -> [String],
        readSchemaVersion: @escaping () throws -> Int?, createFreshSchema: @escaping () throws -> Void,
        setSchemaVersion: @escaping (Int) throws -> Void, withTransaction: @escaping (() throws -> Void) throws -> Void,
        validateIntegrity: @escaping () throws -> Void, withMigrationAuthorization: (() throws -> Void) throws -> Void = { try $0() }
    ) throws {
        let initialTables = try readExistingTables()
        let initialVersion = try readSchemaVersion()
        guard initialTables.isEmpty || initialVersion != currentSchemaVersion else { return }
        if !initialTables.isEmpty, let initialVersion, initialVersion > currentSchemaVersion {
            throw SpacesDatabaseError.migrationFailed(message: "Unsupported database schema version \(initialVersion) at \(databasePath).")
        }

        try withMigrationAuthorization {
            // Authorization may wait for another helper to finish creating or upgrading this
            // database. Re-read both values under the lock so this connection adopts that work
            // instead of replaying a stale schema decision.
            let existingTables = try readExistingTables()
            let schemaVersion = try readSchemaVersion()

            if existingTables.isEmpty {
                try withTransaction {
                    try createFreshSchema()
                    try setSchemaVersion(currentSchemaVersion)
                }
                try validateIntegrity()
                return
            }

            guard var version = schemaVersion else {
                throw SpacesDatabaseError.migrationFailed(message: "Unsupported database schema at \(databasePath): missing migration_state marker.")
            }
            guard version <= currentSchemaVersion else {
                throw SpacesDatabaseError.migrationFailed(message: "Unsupported database schema version \(version) at \(databasePath).")
            }
            guard version < currentSchemaVersion else { return }

            var backupURL: URL?
            while version < currentSchemaVersion {
                // Upgrades run serially: every intermediate version's step applies in order, so a
                // missing step means the database cannot reach the current version at all.
                guard let step = steps.first(where: { $0.fromVersion == version }) else {
                    throw SpacesDatabaseError.migrationFailed(
                        message: "No migration step exists from schema version \(version); cannot reach version \(currentSchemaVersion).")
                }

                do {
                    if backupURL == nil, step.requiresBackup {
                        backupURL = try backupManager.createMigrationBackup(
                            sourceHandle: databaseHandle, fromVersion: step.fromVersion, toVersion: currentSchemaVersion)
                    }
                    try withTransaction {
                        try step.apply(databaseHandle)
                        try setSchemaVersion(step.toVersion)
                    }
                } catch { throw migrationError(for: step, underlying: error, backupURL: backupURL) }
                version = step.toVersion
            }

            do { try validateIntegrity() } catch {
                let backupMessage = backupURL.map { " A pre-migration backup was saved to \($0.path)." } ?? ""
                throw SpacesDatabaseError.migrationFailed(message: "Database migration integrity check failed for \(databasePath).\(backupMessage)")
            }
        }
    }

    private func migrationError(for step: DatabaseMigrationStep, underlying: Error, backupURL: URL?) -> SpacesDatabaseError {
        let backupMessage = backupURL.map { " A pre-migration backup was saved to \($0.path)." } ?? ""
        return .databaseMigrationFailed(
            message:
                "Database migration \(step.fromVersion)->\(step.toVersion) failed (\(step.description)): \(underlying.localizedDescription).\(backupMessage)"
        )
    }
}

public enum SpacesDatabaseError: LocalizedError, Sendable {
    case migrationFailed(message: String)
    case databaseMigrationFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .migrationFailed(let message), .databaseMigrationFailed(let message): message
        }
    }
}
