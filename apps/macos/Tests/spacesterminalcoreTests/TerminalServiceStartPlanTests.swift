import Foundation
import XCTest

@testable import spacesterminalcore

#if os(macOS)
    /// Pins which spawner starts a given profile's daemon on macOS.
    ///
    /// The installed profile is supervised by a `KeepAlive` LaunchAgent, so a client that spawned that daemon
    /// itself would win the profile's instance lock and leave launchd respawning a loser every few seconds
    /// forever. These tests cover the decision that keeps launchd the single spawner there, and keeps direct
    /// spawn for the cases launchd cannot serve: a pinned `SPACESD_EXECUTABLE`, a development profile, and an
    /// installed profile whose agent plist was never written.
    ///
    /// The decision is a pure function of its injected inputs, so nothing here runs launchctl or touches the
    /// real home directory.
    final class TerminalServiceStartPlanTests: XCTestCase {
        /// The E2E scripts pin which daemon build runs with `SPACESD_EXECUTABLE`. launchd would start whatever
        /// the plist names instead, so the pin has to beat the agent even for the installed profile.
        func testPinnedExecutableWinsOverTheInstalledLaunchAgent() throws {
            let agent = try makeExistingLaunchAgentPlist()

            let plan = TerminalService.resolveStartPlan(
                environment: ["SPACESD_EXECUTABLE": "/tmp/pinned/spacesd"], profile: makeProfile(isInstalled: true), launchAgentURL: agent)

            XCTAssertEqual(plan, .directSpawn)
        }

        /// The headline case: an installed profile with an installed agent is started through launchd.
        func testInstalledProfileWithAgentPlistKickstartsTheLaunchAgent() throws {
            let agent = try makeExistingLaunchAgentPlist()

            let plan = TerminalService.resolveStartPlan(environment: [:], profile: makeProfile(isInstalled: true), launchAgentURL: agent)

            XCTAssertEqual(plan, .launchAgentKickstart(label: "dev.usespaces.spacesd"))
            XCTAssertEqual(plan, .launchAgentKickstart(label: SpacesBinaryLayout.launchAgentLabel))
        }

        /// A partial install has the daemon but no agent to kickstart. Asking launchd for a job that was never
        /// bootstrapped would strand the user with no daemon, so the client starts one itself.
        func testInstalledProfileWithoutAgentPlistSpawnsDirectly() throws {
            let missingAgent = try makeTemporaryDirectory().appendingPathComponent("dev.usespaces.spacesd.plist", isDirectory: false)

            let plan = TerminalService.resolveStartPlan(environment: [:], profile: makeProfile(isInstalled: true), launchAgentURL: missingAgent)

            XCTAssertEqual(plan, .directSpawn)
        }

        /// The agent supervises the installed profile's daemon only. A development profile on the same machine
        /// sees that same plist and must still start its own daemon, or every dev client would be handed the
        /// installed build.
        func testDevelopmentProfileSpawnsDirectlyEvenWhenTheAgentPlistExists() throws {
            let agent = try makeExistingLaunchAgentPlist()

            let plan = TerminalService.resolveStartPlan(environment: [:], profile: makeProfile(isInstalled: false), launchAgentURL: agent)

            XCTAssertEqual(plan, .directSpawn)
        }

        /// `SPACES_RUNTIME_DIR` moves the runtime root, and with it the socket path the caller polls, while the
        /// profile stays installed because its root is still the real `~/.spaces`. launchd starts the job with
        /// its own clean environment, so a kickstarted daemon would bind the default socket and leave the
        /// caller waiting out its startup timeout on one nothing is listening on.
        func testOverriddenRuntimeDirectoryWinsOverTheInstalledLaunchAgent() throws {
            let agent = try makeExistingLaunchAgentPlist()

            let plan = TerminalService.resolveStartPlan(
                environment: [SpacesProfile.runtimeDirectoryEnvironmentVariable: "/tmp/spaces-runtime-override"],
                profile: makeProfile(isInstalled: true), launchAgentURL: agent)

            XCTAssertEqual(plan, .directSpawn)
        }

        /// An empty or whitespace-only binding binds nothing, so it must not push the installed profile off
        /// launchd. Profile resolution and `resolveExecutableURL` both ignore such a value, and treating it as
        /// a binding here would leave this decision disagreeing with the paths it exists to serve.
        func testBlankEnvironmentBindingsDoNotDisableTheLaunchAgent() throws {
            let agent = try makeExistingLaunchAgentPlist()

            for variable in [TerminalService.pinnedExecutableEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable] {
                for blank in ["", "   "] {
                    let plan = TerminalService.resolveStartPlan(
                        environment: [variable: blank], profile: makeProfile(isInstalled: true), launchAgentURL: agent)

                    XCTAssertEqual(plan, .launchAgentKickstart(label: SpacesBinaryLayout.launchAgentLabel), "\(variable) = \"\(blank)\"")
                }
            }
        }

        /// The agent plist is read under the same home the profile resolved from. These two tests use the
        /// resolved default rather than injecting a URL, because the alignment itself is what is under test:
        /// `SpacesBinaryLayout.launchAgentURL()` defaults to `NSHomeDirectory()`, which ignores an overridden
        /// `HOME`, so a process running with an isolated home (routine in this repo's tests) would otherwise
        /// find the real user's plist and kickstart the production daemon while polling an isolated socket.
        func testAgentPlistIsFoundUnderTheOverriddenHome() throws {
            let home = try makeTemporaryDirectory()
            let agentDirectory = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
            try Data().write(to: agentDirectory.appendingPathComponent("dev.usespaces.spacesd.plist", isDirectory: false))

            let plan = TerminalService.resolveStartPlan(environment: ["HOME": home.path], profile: makeProfile(isInstalled: true))

            XCTAssertEqual(plan, .launchAgentKickstart(label: SpacesBinaryLayout.launchAgentLabel))
        }

        /// The counterpart, and the one that would fail against `NSHomeDirectory()`: an isolated home with no
        /// agent of its own spawns directly even though this machine's real user very likely does have an
        /// installed agent plist.
        func testOverriddenHomeWithoutAnAgentPlistSpawnsDirectly() throws {
            let home = try makeTemporaryDirectory()

            let plan = TerminalService.resolveStartPlan(environment: ["HOME": home.path], profile: makeProfile(isInstalled: true))

            XCTAssertEqual(plan, .directSpawn)
        }

        private func makeProfile(isInstalled: Bool) -> SpacesProfile {
            let root = "/tmp/spaces-profile-\(UUID().uuidString)"
            return SpacesProfile(
                source: isInstalled ? .installedFallback : .developmentWorktree, databasePath: "\(root)/spaces.db", rootDirectory: root,
                isInstalledProfile: isInstalled, runtimeDirectory: "\(root)/runtime", ipcNotificationObject: "spaces.profile.start-plan-tests",
                developmentContext: nil, branchSlug: nil, worktreeHash: nil)
        }

        private func makeTemporaryDirectory() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            return root
        }

        private func makeExistingLaunchAgentPlist() throws -> URL {
            let plistURL = try makeTemporaryDirectory().appendingPathComponent("dev.usespaces.spacesd.plist", isDirectory: false)
            try Data().write(to: plistURL)
            return plistURL
        }
    }
#endif
