import Foundation
import SQLite3

struct DatabaseMigrationStep {
    let fromVersion: Int
    let toVersion: Int
    let description: String
    let requiresBackup: Bool
    let apply: @Sendable (OpaquePointer) throws -> Void
}

struct DatabaseMigrator {
    let currentSchemaVersion: Int
    let steps: [DatabaseMigrationStep]
    let backupManager: DatabaseBackupManager

    func migrateIfNeeded(
        existingTables: [String], schemaVersion: Int?, databasePath: String, databaseHandle: OpaquePointer,
        createFreshSchema: @escaping () throws -> Void, setSchemaVersion: @escaping (Int) throws -> Void,
        withTransaction: (() throws -> Void) throws -> Void, validateIntegrity: @escaping () throws -> Void
    ) throws {
        if existingTables.isEmpty {
            try withTransaction {
                try createFreshSchema()
                try setSchemaVersion(currentSchemaVersion)
            }
            try validateIntegrity()
            return
        }

        guard var version = schemaVersion else {
            throw WorkspaceError.databaseMigrationFailed(message: "Unsupported database schema at \(databasePath): missing migration_state marker.")
        }
        guard version <= currentSchemaVersion else {
            throw WorkspaceError.databaseMigrationFailed(message: "Unsupported database schema version \(version) at \(databasePath).")
        }
        guard version < currentSchemaVersion else { return }

        var backupURL: URL?
        while version < currentSchemaVersion {
            guard let step = steps.first(where: { $0.fromVersion == version }) else {
                throw WorkspaceError.databaseMigrationFailed(
                    message: "No migration path exists from schema version \(version) to \(currentSchemaVersion).")
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
            throw WorkspaceError.databaseMigrationFailed(message: "Database migration integrity check failed for \(databasePath).\(backupMessage)")
        }
    }

    private func migrationError(for step: DatabaseMigrationStep, underlying: Error, backupURL: URL?) -> WorkspaceError {
        let backupMessage = backupURL.map { " A pre-migration backup was saved to \($0.path)." } ?? ""
        return .databaseMigrationFailed(
            message:
                "Database migration \(step.fromVersion)->\(step.toVersion) failed (\(step.description)): \(underlying.localizedDescription).\(backupMessage)"
        )
    }
}
