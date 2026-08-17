import Foundation
import Testing

@testable import spacesterminalcore

/// Covers the one branch `withMigrationAuthorization` decides before touching the daemon-ownership
/// handshake at all: whether `databasePath` is this process's own profile database. A test process
/// cannot resolve a profile (`SpacesProfile.current()` refuses it), so an explicit throwaway path must
/// still open and migrate, and an explicit path that names a live profile must still be refused: the
/// live-root check runs independently of profile resolution so folding a refusal into "no profile"
/// never drops that protection.
@Suite struct ProfileDatabaseMigrationGuardTests {
    /// Before the fix, resolving the profile unconditionally meant this call threw the test-host
    /// refusal even though `databasePath` never depended on the profile at all, forcing tests to
    /// rebind the process-wide SPACES_* environment instead of naming their own throwaway database.
    @Test func anExplicitThrowawayDatabaseOpensAndMigratesWithoutProfileResolution() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let databasePath = tempDirectory.appendingPathComponent("spaces.db", isDirectory: false).path

        let migrationRan = try ProfileDatabaseMigrationGuard.withMigrationAuthorization(databasePath: databasePath) { true }

        #expect(migrationRan)
    }

    /// A test process is refused a live profile database even when it names the path explicitly,
    /// rather than through resolution: the live-root check has to run before profile resolution is
    /// even attempted, or collapsing a resolution refusal into "no profile" would silently let this
    /// through. The refusal must land before any file is created or lock acquired.
    @Test func aTestProcessIsRefusedALiveProfileDatabaseEvenWhenNamedExplicitly() {
        let installedDatabasePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".spaces/spaces.db").path

        do {
            try ProfileDatabaseMigrationGuard.withMigrationAuthorization(databasePath: installedDatabasePath) {
                Issue.record("migration closure must not run against a live profile database")
            }
            Issue.record("expected withMigrationAuthorization to throw for a live profile database path")
        } catch let error as SpacesProfileResolutionError {
            guard case .testHostRefusedLiveUserProfile = error else {
                Issue.record("expected testHostRefusedLiveUserProfile, got \(error)")
                return
            }
        } catch {
            Issue.record("expected SpacesProfileResolutionError, got \(error)")
        }
    }
}
