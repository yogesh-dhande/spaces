import Foundation
import spacesdatabase

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Keeps schema upgrades owned by the daemon that already owns the profile. A direct helper may open
/// a current database, but it cannot move an older daemon's database to a schema that daemon cannot
/// read. The existing daemon instance lock is intentionally the authority: older daemons already
/// write it, so this protection works across the exact version boundary where it is needed.
///
/// A live owner is not on its own a version boundary. A daemon that has just taken the instance lock
/// is doing that profile's schema work right then — creating a fresh profile's schema, or upgrading
/// an existing one after an update — and a helper that opens the database in that window sees what an
/// older daemon would also present: a schema behind this build's. The owner's lock record separates
/// the two, because it names the schema version that owner's build maintains:
///
/// - Absent or lower than this build's: the older daemon this guard exists for. The helper fails
///   immediately with the session-preserving handoff remedy; nothing it could wait for would change.
/// - Equal or higher: a build that is going to finish the schema work it started. The helper waits
///   for the owner's *declared* version to be recorded — not merely for one this build could open,
///   because a newer owner passes through this build's version mid-upgrade, committing each
///   intermediate step as it goes. The wait is bounded by the owner staying alive rather than by a
///   fixed duration, because the work being waited on is proportional to database and session size —
///   a migration backs the database up first, and a daemon resuming a handoff replays its retained
///   sessions before it opens the store at all. A newer owner's finished schema is then rejected by
///   the caller, which is the accurate report.
///
/// An owner that exits before recording its target returns the helper to the ordinary acquisition
/// path, where it takes the lock and does the schema work itself.
public enum ProfileDatabaseMigrationGuard {
    private static let processMigrationLock = NSLock()

    /// Ceiling on waiting for an owner that stays alive without ever recording its schema version.
    /// Liveness is the real bound; this only keeps a wedged owner from stalling a helper forever, so
    /// it is set well past any legitimate backup, migration, or session replay rather than sized to
    /// one of them.
    private static let ownerSchemaWaitCeiling: TimeInterval = 120
    private static let ownerSchemaPollInterval: TimeInterval = 0.05

    public static func withMigrationAuthorization<T>(databasePath: String, _ migration: () throws -> T) throws -> T {
        try withMigrationAuthorization(databasePath: databasePath, ownerWaitCeiling: ownerSchemaWaitCeiling, migration)
    }

    /// The ceiling is a parameter only so a test can reach the expiry branch without stalling for the
    /// product value; every caller outside tests goes through the overload above.
    static func withMigrationAuthorization<T>(databasePath: String, ownerWaitCeiling: TimeInterval, _ migration: () throws -> T) throws -> T {
        // The instance lock records only a pid. Serialize locally before interpreting our own pid
        // as daemon ownership so a second helper thread cannot mistake the first helper's temporary
        // migration lock for a daemon lock and bypass the critical section.
        processMigrationLock.lock()
        defer { processMigrationLock.unlock() }

        let profile = try SpacesProfile.current()
        guard SpacesProfile.canonicalPath(databasePath) == SpacesProfile.canonicalPath(profile.databasePath) else { return try migration() }

        let lockPath = try TerminalServicePaths.instanceLockPath()
        if try TerminalServiceInstanceLock.activeOwnerProcessID(path: lockPath) == ProcessInfo.processInfo.processIdentifier {
            return try migration()
        }

        let deadline = Date().addingTimeInterval(ownerWaitCeiling)
        repeat {
            if case .reserved(let value) = try attemptReservedMigration(lockPath: lockPath, migration) { return value }

            // Read the record rather than trusting the pid the failed reservation carried: the owner's
            // declared schema target is what separates the older daemon this guard protects from a
            // daemon doing this build's schema work. An owner already gone leaves nothing to read, so
            // the reservation simply runs again.
            guard let owner = try TerminalServiceInstanceLock.activeOwner(path: lockPath) else { continue }
            guard let target = owner.schemaTarget, target >= DatabaseSchema.currentVersion else {
                throw versionBoundaryError(databasePath: databasePath, owner: owner)
            }

            // Waiting happens with neither lock held: the owner is already running, and holding the
            // launch lock through the wait would stall an unrelated `ensureRunning` behind it. The
            // caller's closure re-reads the schema before acting, so running it after the wait finds the
            // owner's work already done.
            let recorded = try waitForOwnerRecordedSchema(
                databasePath: databasePath, lockPath: lockPath, owner: owner, target: target, deadline: deadline, ceiling: ownerWaitCeiling)
            guard recorded else { continue }
            return try migration()
        } while Date() < deadline

        // Reached only when ownership keeps changing hands faster than this helper can either take the
        // lock or settle on one owner to wait for.
        throw ownerStillWorkingError(
            databasePath: databasePath, owner: try TerminalServiceInstanceLock.activeOwner(path: lockPath), ceiling: ownerWaitCeiling)
    }

    private enum ReservationOutcome<T> {
        case reserved(T)
        case ownedByAnotherProcess
    }

    /// Runs the caller's work with the profile reserved, or reports that a daemon holds the profile.
    private static func attemptReservedMigration<T>(lockPath: String, _ migration: () throws -> T) throws -> ReservationOutcome<T> {
        do {
            return .reserved(try withDaemonLaunchLock { try withInstanceLock(lockPath: lockPath, migration) })
        } catch TerminalServiceInstanceLockError.alreadyRunning { return .ownedByAnotherProcess }
    }

    private static func withInstanceLock<T>(lockPath: String, _ migration: () throws -> T) throws -> T {
        let migrationLock = try TerminalServiceInstanceLock.acquire(path: lockPath)
        defer { migrationLock.release() }
        return try migration()
    }

    /// Waits for the profile's owner to record the schema version it declared, not merely one this
    /// build could open. A newer owner commits every intermediate step of its upgrade in its own
    /// transaction, so this build's version appears mid-migration on the way past it; stopping there
    /// would hand the caller a database still being rewritten toward a schema it cannot read. Waiting
    /// for the declared target instead means the caller's closure sees the finished version and rejects
    /// it with the unsupported-schema error, which is the accurate report for a newer daemon.
    ///
    /// Returns `false` when the owner exits, or hands the profile to another process, before recording
    /// its target — the caller then returns to the acquisition path and does the schema work itself.
    private static func waitForOwnerRecordedSchema(
        databasePath: String, lockPath: String, owner: TerminalServiceInstanceLock.ActiveOwner, target: Int, deadline: Date, ceiling: TimeInterval
    ) throws -> Bool {
        while true {
            if let version = DatabaseSchemaVersionReader.recordedVersion(atPath: databasePath), version >= target { return true }
            // Liveness is checked after the recorded version so an owner that finished its schema work
            // and then exited is still adopted rather than treated as having abandoned it.
            guard try TerminalServiceInstanceLock.activeOwner(path: lockPath)?.processID == owner.processID else { return false }
            guard Date() < deadline else { throw ownerStillWorkingError(databasePath: databasePath, owner: owner, ceiling: ceiling) }
            Thread.sleep(forTimeInterval: ownerSchemaPollInterval)
        }
    }

    /// The refusal this guard exists for: the owner's build maintains a schema this one would move out
    /// from under it, so the remedy is to load the staged daemon rather than to wait.
    private static func versionBoundaryError(databasePath: String, owner: TerminalServiceInstanceLock.ActiveOwner) -> SpacesDatabaseError {
        let ownerSchema = owner.schemaTarget.map { "schema version \($0)" } ?? "an earlier schema"
        return .migrationFailed(
            message: "Cannot upgrade the Spaces database at \(databasePath) while spacesd (pid \(owner.processID)) owns this profile. "
                + "That daemon maintains \(ownerSchema) and this build needs schema version \(DatabaseSchema.currentVersion). "
                + "Run `spaces daemon apply-update` to load the staged daemon without stopping its sessions, then retry.")
    }

    /// A same-or-newer owner that is alive but has not finished. The handoff remedy would be wrong
    /// here — the daemon this helper is waiting on is already the one that should be doing the work —
    /// so the only useful instruction is to let it finish. The version named is the one that was
    /// actually waited for: the owner's declared target, which for a newer owner is past this build's.
    private static func ownerStillWorkingError(databasePath: String, owner: TerminalServiceInstanceLock.ActiveOwner?, ceiling: TimeInterval)
        -> SpacesDatabaseError
    {
        let ownerDescription = owner.map { " (pid \($0.processID))" } ?? ""
        let awaitedVersion = owner?.schemaTarget ?? DatabaseSchema.currentVersion
        return .migrationFailed(
            message: "The Spaces database at \(databasePath) is still being prepared by spacesd\(ownerDescription), which owns this profile. "
                + "It has not recorded schema version \(awaitedVersion) after \(String(format: "%g", ceiling))s of schema work; "
                + "retry once it finishes.")
    }

    /// Uses the same profile launch lock as `TerminalService.ensureRunning`. A concurrent startup
    /// waits here and launches after migration instead of spawning a daemon that immediately loses
    /// the instance-lock race and exits.
    private static func withDaemonLaunchLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(try TerminalServicePaths.launchLockPath(), O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 { guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) } }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
