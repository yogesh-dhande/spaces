import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// A Spaces terminal inherits its daemon's profile environment and nothing more. Both real profiles are
/// discoverable from a binary's own location, so an unbound terminal is the correct state for both: a
/// `spaces` binary run inside one resolves the profile it belongs to. Only an ephemeral throwaway profile
/// has to be named explicitly, and that is exactly the case where the daemon itself carries the variable.
final class TerminalProfileBindingTests: XCTestCase {

    /// The daemon serving the installed profile runs under launchd with no `SPACES_*` set, and a repo-built
    /// daemon derives its worktree profile from its own path. Neither may hand a `SPACES_DB_PATH` to the
    /// terminals it launches: it leaked into every process started inside — agent hooks fire on every tool
    /// call — and a `spaces` invocation that autostarts a daemon passes the whole parent environment on,
    /// which is how a daemon serving `~/.spaces` came to be classified as a development profile and took a
    /// development-range Device API port.
    func testTerminalLaunchEnvironmentLeavesTheSessionUnboundWhenTheDaemonCarriesNoDatabasePath() throws {
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore())

        let env = try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: nil, SpacesProfile.runtimeDirectoryEnvironmentVariable: nil,
        ]) { orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: true) }

        XCTAssertNil(env[SpacesProfile.databasePathEnvironmentVariable])
        XCTAssertNil(env[SpacesProfile.runtimeDirectoryEnvironmentVariable])
    }

    /// A daemon started on an ephemeral throwaway profile — the E2E harnesses and test runs, the one profile
    /// kind a binary's location cannot describe — forwards its own binding so its terminals stay on it.
    func testTerminalLaunchEnvironmentForwardsAnEphemeralDatabasePathTheDaemonCarries() throws {
        let databasePath = try makeTempDirectory().appendingPathComponent("spaces.db", isDirectory: false).path
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore())

        let env = try withEnvironmentValues([SpacesProfile.databasePathEnvironmentVariable: databasePath]) {
            orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: true)
        }

        XCTAssertEqual(env[SpacesProfile.databasePathEnvironmentVariable], databasePath)
    }

    /// E2E harnesses start a daemon whose runtime root is deliberately not the default one beside its
    /// database. Those daemons forward the override so their terminals stay on the runtime root the daemon
    /// itself uses.
    func testTerminalLaunchEnvironmentForwardsAnExplicitDaemonRuntimeDirectory() throws {
        let profileRoot = try makeTempDirectory()
        let databasePath = profileRoot.appendingPathComponent("spaces.db", isDirectory: false).path
        let runtimeDirectory = profileRoot.appendingPathComponent("split-runtime", isDirectory: true).path
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore())

        let env = try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: databasePath, SpacesProfile.runtimeDirectoryEnvironmentVariable: runtimeDirectory,
        ]) { orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: true) }

        XCTAssertEqual(env[SpacesProfile.runtimeDirectoryEnvironmentVariable], runtimeDirectory)
        XCTAssertEqual(env[SpacesProfile.databasePathEnvironmentVariable], databasePath)
    }

    func testTerminalLaunchEnvironmentWithoutProfileEnvironmentExportsNoDatabasePath() throws {
        let databasePath = try makeTempDirectory().appendingPathComponent("spaces.db", isDirectory: false).path
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore())

        let env = try withEnvironmentValues([SpacesProfile.databasePathEnvironmentVariable: databasePath]) {
            orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: false)
        }

        XCTAssertNil(env[SpacesProfile.databasePathEnvironmentVariable])
    }
}
