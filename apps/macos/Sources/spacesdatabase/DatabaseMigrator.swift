import Foundation
import SQLite3

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
            throw SpacesDatabaseError.migrationFailed(message: "Unsupported database schema at \(databasePath): missing migration_state marker.")
        }
        guard version <= currentSchemaVersion else {
            throw SpacesDatabaseError.migrationFailed(message: "Unsupported database schema version \(version) at \(databasePath).")
        }
        guard version < currentSchemaVersion else { return }

        var backupURL: URL?
        while version < currentSchemaVersion {
            guard let step = steps.first(where: { $0.fromVersion == version }) else {
                throw SpacesDatabaseError.migrationFailed(
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
            throw SpacesDatabaseError.migrationFailed(message: "Database migration integrity check failed for \(databasePath).\(backupMessage)")
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
