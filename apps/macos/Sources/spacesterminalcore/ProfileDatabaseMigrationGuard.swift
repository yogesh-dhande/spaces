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
public enum ProfileDatabaseMigrationGuard {
    private static let processMigrationLock = NSLock()

    public static func withMigrationAuthorization<T>(databasePath: String, _ migration: () throws -> T) throws -> T {
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

        return try withDaemonLaunchLock { try withInstanceLock(databasePath: databasePath, lockPath: lockPath, migration) }
    }

    private static func withInstanceLock<T>(databasePath: String, lockPath: String, _ migration: () throws -> T) throws -> T {
        let migrationLock: TerminalServiceInstanceLock
        do { migrationLock = try TerminalServiceInstanceLock.acquire(path: lockPath) } catch TerminalServiceInstanceLockError.alreadyRunning(
            let ownerPID, _)
        {
            let ownerDescription = ownerPID.map { " (pid \($0))" } ?? ""
            throw SpacesDatabaseError.migrationFailed(
                message: "Cannot upgrade the Spaces database at \(databasePath) while spacesd\(ownerDescription) owns this profile. "
                    + "Run `spaces daemon apply-update` to load the staged daemon without stopping its sessions, then retry.")
        }
        defer { migrationLock.release() }
        return try migration()
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
