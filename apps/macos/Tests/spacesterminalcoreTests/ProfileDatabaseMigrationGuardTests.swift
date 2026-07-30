import Foundation
import XCTest

@testable import spacesterminalcore

/// Schema work belongs to the build that OWNS a profile. `spacese2e --installed-profile` binds itself to a
/// profile it does not own, and a repo-local helper is normally ahead of the installed release, so letting it
/// upgrade `~/.spaces/spaces.db` would leave the installed build unable to open its own database.
final class ProfileDatabaseMigrationGuardTests: XCTestCase {
    func testProcessBoundToTheInstalledProfileIsRefusedTheSchemaUpgrade() throws {
        let databasePath = "/Users/tester/.spaces/spaces.db"

        let refusal = try XCTUnwrap(
            ProfileDatabaseMigrationGuard.boundProfileMigrationRefusal(profileSource: .explicitInstalledProfile, databasePath: databasePath))

        XCTAssertTrue(refusal.localizedDescription.contains(databasePath), refusal.localizedDescription)
        XCTAssertTrue(
            refusal.localizedDescription.contains("bound to the installed profile"),
            "The refusal must name why this process may not do the work: \(refusal.localizedDescription)")
    }

    /// The companion direction, so the refusal cannot quietly grow to cover ordinary processes: every profile
    /// a process reached by belonging to it — installed, worktree, deployed, or an ephemeral scratch root —
    /// still does its own schema work, gated only by the daemon-ownership rules below it.
    func testProfilesTheProcessOwnsAreNotRefused() {
        for source: SpacesProfileSource in [.installedFallback, .developmentWorktree, .deployedDevelopmentProfile, .explicitDatabasePath] {
            XCTAssertNil(
                ProfileDatabaseMigrationGuard.boundProfileMigrationRefusal(profileSource: source, databasePath: "/tmp/profile/spaces.db"),
                "A process that owns its \(source.rawValue) profile does its own schema work.")
        }
    }
}
