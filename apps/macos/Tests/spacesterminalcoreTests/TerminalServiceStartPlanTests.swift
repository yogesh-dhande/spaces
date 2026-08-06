import Foundation
import XCTest

@testable import spacesterminalcore

#if os(macOS)
    /// Pins which spawner starts a given profile's daemon on macOS.
    ///
    /// The installed profile is supervised by a `KeepAlive` LaunchAgent, so a client that spawned that daemon
    /// itself would win the profile's instance lock and leave launchd respawning a loser every few seconds
    /// forever. These tests cover the decision that keeps launchd the single spawner there, and keeps direct
    /// spawn for every case launchd cannot serve: an environment binding its clean environment would drop, a
    /// development profile, a partial install with no agent plist, and a process whose home is not the account
    /// home the registered job belongs to.
    ///
    /// The decision is a pure function of its injected inputs, so nothing here runs launchctl, and every test
    /// supplies its own home rather than reading the machine's.
    final class TerminalServiceStartPlanTests: XCTestCase {
        /// The E2E scripts pin which daemon build runs with `SPACESD_EXECUTABLE`. launchd would start whatever
        /// the plist names instead, so the pin has to beat the agent even for the installed profile.
        func testPinnedExecutableWinsOverTheInstalledLaunchAgent() throws {
            let home = try makeHome(withAgentPlist: true)

            let plan = TerminalService.resolveStartPlan(
                environment: home.environment(adding: [TerminalService.pinnedExecutableEnvironmentVariable: "/tmp/pinned/spacesd"]),
                profile: makeProfile(isInstalled: true), accountHomeDirectoryPath: home.path)

            XCTAssertEqual(plan, .directSpawn)
        }

        /// `SPACES_RUNTIME_DIR` moves the runtime root, and with it the socket path the caller polls, while the
        /// profile stays installed because its root is still the real `~/.spaces`. launchd starts the job with
        /// its own clean environment, so a kickstarted daemon would bind the default socket and leave the
        /// caller waiting out its startup timeout on one nothing is listening on.
        func testOverriddenRuntimeDirectoryWinsOverTheInstalledLaunchAgent() throws {
            let home = try makeHome(withAgentPlist: true)

            let plan = TerminalService.resolveStartPlan(
                environment: home.environment(adding: [SpacesProfile.runtimeDirectoryEnvironmentVariable: "/tmp/spaces-runtime-override"]),
                profile: makeProfile(isInstalled: true), accountHomeDirectoryPath: home.path)

            XCTAssertEqual(plan, .directSpawn)
        }

        /// A Device API binding changes how the daemon serves this client rather than which build runs, and
        /// launchd drops it exactly the same way. One variable stands for the whole list, which is uniform.
        func testDeviceAPIBindingWinsOverTheInstalledLaunchAgent() throws {
            let home = try makeHome(withAgentPlist: true)

            let plan = TerminalService.resolveStartPlan(
                environment: home.environment(adding: ["SPACES_DEVICE_API_DISABLED": "1"]), profile: makeProfile(isInstalled: true),
                accountHomeDirectoryPath: home.path)

            XCTAssertEqual(plan, .directSpawn)
        }

        /// The headline case: an installed profile, an agent plist, and a process whose home is the account
        /// home the registered job belongs to.
        func testInstalledProfileWithAgentPlistKickstartsTheLaunchAgent() throws {
            let home = try makeHome(withAgentPlist: true)

            let plan = TerminalService.resolveStartPlan(
                environment: home.environment(), profile: makeProfile(isInstalled: true), accountHomeDirectoryPath: home.path)

            XCTAssertEqual(plan, .launchAgentKickstart(label: "dev.usespaces.spacesd"))
            XCTAssertEqual(plan, .launchAgentKickstart(label: SpacesBinaryLayout.launchAgentLabel))
        }

        /// A partial install has the daemon but no agent to kickstart. Asking launchd for a job that was never
        /// registered would strand the user with no daemon, so the client starts one itself.
        func testInstalledProfileWithoutAgentPlistSpawnsDirectly() throws {
            let home = try makeHome(withAgentPlist: false)

            let plan = TerminalService.resolveStartPlan(
                environment: home.environment(), profile: makeProfile(isInstalled: true), accountHomeDirectoryPath: home.path)

            XCTAssertEqual(plan, .directSpawn)
        }

        /// The agent supervises the installed profile's daemon only. A development profile on the same machine
        /// sees that same plist and must still start its own daemon, or every dev client would be handed the
        /// installed build.
        func testDevelopmentProfileSpawnsDirectlyEvenWhenTheAgentPlistExists() throws {
            let home = try makeHome(withAgentPlist: true)

            let plan = TerminalService.resolveStartPlan(
                environment: home.environment(), profile: makeProfile(isInstalled: false), accountHomeDirectoryPath: home.path)

            XCTAssertEqual(plan, .directSpawn)
        }

        /// The case that makes home identity load-bearing rather than cosmetic. `launchctl kickstart` addresses
        /// the job registered in the user's GUI domain under this label; it never reads the plist path checked
        /// here. So an isolated-home process that writes its own same-named plist (what a test fixture does)
        /// would still start the REAL account's production daemon, against a profile resolved under a home that
        /// daemon knows nothing about, and then poll a socket it will never bind. The account home comes from
        /// the password database, which an overridden `HOME` cannot move, so the two homes disagree and the
        /// client spawns its own daemon.
        ///
        /// This test deliberately uses the real default account home rather than an injected one, so it fails
        /// if the gate is ever removed on a real machine.
        func testIsolatedHomeWithItsOwnAgentPlistNeverKickstartsTheAccountJob() throws {
            let home = try makeHome(withAgentPlist: true)

            let plan = TerminalService.resolveStartPlan(environment: home.environment(), profile: makeProfile(isInstalled: true))

            XCTAssertEqual(plan, .directSpawn)
        }

        /// The same conclusion by the shorter route, with the homes stated explicitly rather than left to the
        /// machine: a home that is not the account home never kickstarts, plist or not.
        func testEnvironmentHomeDifferingFromTheAccountHomeSpawnsDirectly() throws {
            let home = try makeHome(withAgentPlist: true)
            let otherAccountHome = try makeTemporaryDirectory()

            let plan = TerminalService.resolveStartPlan(
                environment: home.environment(), profile: makeProfile(isInstalled: true), accountHomeDirectoryPath: otherAccountHome.path)

            XCTAssertEqual(plan, .directSpawn)
        }

        /// An unreadable password database leaves the account identity unestablished. There is nothing to
        /// compare the process's home against, so the answer is the one that cannot activate another home's
        /// daemon.
        func testUnknownAccountHomeSpawnsDirectly() throws {
            let home = try makeHome(withAgentPlist: true)

            let plan = TerminalService.resolveStartPlan(
                environment: home.environment(), profile: makeProfile(isInstalled: true), accountHomeDirectoryPath: nil)

            XCTAssertEqual(plan, .directSpawn)
        }

        /// The plist is looked up under the home in play rather than `NSHomeDirectory()`, which ignores `HOME`.
        /// Past the identity gate the two are the same path, so this pins that the lookup follows the resolved
        /// home instead of quietly reading a fixed one.
        func testAgentPlistIsReadUnderTheHomeInPlay() throws {
            let home = try makeHome(withAgentPlist: true)

            let plan = TerminalService.resolveStartPlan(
                environment: home.environment(), profile: makeProfile(isInstalled: true), accountHomeDirectoryPath: home.path,
                launchAgentURL: home.agentPlistURL)

            XCTAssertEqual(plan, .launchAgentKickstart(label: SpacesBinaryLayout.launchAgentLabel))
        }

        /// An empty or whitespace-only binding binds nothing, so it must not push the installed profile off
        /// launchd. Profile resolution and `resolveExecutableURL` both ignore such a value, and treating it as
        /// a binding here would leave this decision disagreeing with the paths it exists to serve.
        func testBlankEnvironmentBindingsDoNotDisableTheLaunchAgent() throws {
            let home = try makeHome(withAgentPlist: true)

            for variable in TerminalService.kickstartForbiddingEnvironmentVariables {
                for blank in ["", "   "] {
                    let plan = TerminalService.resolveStartPlan(
                        environment: home.environment(adding: [variable: blank]), profile: makeProfile(isInstalled: true),
                        accountHomeDirectoryPath: home.path)

                    XCTAssertEqual(plan, .launchAgentKickstart(label: SpacesBinaryLayout.launchAgentLabel), "\(variable) = \"\(blank)\"")
                }
            }
        }

        /// A home directory this suite owns. Tests pass its path as both `HOME` and the account home to model an
        /// ordinary process, and break the two apart when the identity gate itself is what is under test.
        private struct HomeFixture {
            let url: URL
            let agentPlistURL: URL

            var path: String { url.path }

            func environment(adding extraValues: [String: String] = [:]) -> [String: String] {
                var environment = ["HOME": url.path]
                for (key, value) in extraValues { environment[key] = value }
                return environment
            }
        }

        private func makeHome(withAgentPlist: Bool) throws -> HomeFixture {
            let root = try makeTemporaryDirectory()
            let agentDirectory = root.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            let plistURL = agentDirectory.appendingPathComponent("dev.usespaces.spacesd.plist", isDirectory: false)
            if withAgentPlist {
                try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
                try Data().write(to: plistURL)
            }
            return HomeFixture(url: root, agentPlistURL: plistURL)
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
    }
#endif
