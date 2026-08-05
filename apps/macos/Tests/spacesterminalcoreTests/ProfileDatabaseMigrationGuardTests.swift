import Foundation
import XCTest

@testable import spacesterminalcore

/// Schema work belongs to the build that OWNS a profile. `spacese2e --installed-profile` binds itself to a
/// profile it does not own, and a repo-local helper is normally ahead of the installed release, so letting it
/// upgrade `~/.spaces/spaces.db` would leave the installed build unable to open its own database.
final class ProfileDatabaseMigrationGuardTests: XCTestCase {
    func testProcessBoundToTheInstalledProfileIsRefusedTheSchemaUpgrade() throws {
        let profile = makeProfile(source: .explicitInstalledProfile, rootDirectory: "/Users/tester/.spaces")

        let refusal = try XCTUnwrap(ProfileDatabaseMigrationGuard.boundProfileMigrationRefusal(profile: profile, databasePath: profile.databasePath))

        XCTAssertTrue(refusal.localizedDescription.contains(profile.databasePath), refusal.localizedDescription)
        XCTAssertTrue(
            refusal.localizedDescription.contains("bound to the installed profile"),
            "The refusal must name why this process may not do the work: \(refusal.localizedDescription)")
    }

    /// The refusal is what an operator acts on, so it is pinned rather than left to drift.
    ///
    /// It must name the profile — the whole point of a bound run is that the operator is acting on one their
    /// checkout does not imply — and it must not tell them to start the installed app or daemon. In the case
    /// that brings anyone here, that build is older than this one and cannot produce this schema, so the
    /// advice would loop forever; the guard cannot see the installed build's schema target to distinguish the
    /// narrow case where it would help, so it states the requirement instead.
    func testTheSchemaRefusalNamesTheProfileAndAnAttainableRemedy() throws {
        let profile = makeProfile(source: .explicitInstalledProfile, rootDirectory: "/Users/tester/.spaces")

        let message = try XCTUnwrap(
            ProfileDatabaseMigrationGuard.boundProfileMigrationRefusal(profile: profile, databasePath: profile.databasePath)
        ).localizedDescription

        XCTAssertTrue(message.contains(profile.rootDirectory), "The refusal must name the profile it is talking about: \(message)")
        XCTAssertTrue(message.contains("schema version"), "The refusal must name the schema version this build needs: \(message)")
        XCTAssertTrue(
            message.contains("does not resolve this on its own"),
            "The refusal must say that starting the installed build is not the remedy: \(message)")
        XCTAssertTrue(
            message.contains("--installed-profile"), "The refusal must offer the remedy that always works — run against this checkout: \(message)")
    }

    /// The companion direction, so the refusal cannot quietly grow to cover ordinary processes: every profile
    /// a process reached by belonging to it — installed, worktree, deployed, or an ephemeral scratch root —
    /// still does its own schema work, gated only by the daemon-ownership rules below it.
    func testProfilesTheProcessOwnsAreNotRefused() {
        for source: SpacesProfileSource in [.installedFallback, .developmentWorktree, .deployedDevelopmentProfile, .explicitDatabasePath] {
            XCTAssertNil(
                ProfileDatabaseMigrationGuard.boundProfileMigrationRefusal(
                    profile: makeProfile(source: source, rootDirectory: "/tmp/profile"), databasePath: "/tmp/profile/spaces.db"),
                "A process that owns its \(source.rawValue) profile does its own schema work.")
        }
    }

    private func makeProfile(source: SpacesProfileSource, rootDirectory: String) -> SpacesProfile {
        SpacesProfile(
            source: source, databasePath: "\(rootDirectory)/spaces.db", rootDirectory: rootDirectory,
            isInstalledProfile: rootDirectory.hasSuffix("/.spaces"), runtimeDirectory: "\(rootDirectory)/runtime",
            ipcNotificationObject: "spaces.profile.test", developmentContext: nil, branchSlug: nil, worktreeHash: nil)
    }
}
