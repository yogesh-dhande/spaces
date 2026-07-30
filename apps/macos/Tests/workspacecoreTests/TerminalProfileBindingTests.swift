import Foundation
import XCTest

@testable import spacesterminalcore
@testable import workspacecore

/// A Spaces terminal — and a workspace script — inherits its daemon's profile environment and nothing more.
/// Both real profiles are discoverable from a binary's own location, so an unbound terminal is the correct
/// state for both: a `spaces` binary run inside one resolves the profile it belongs to. Only an ephemeral
/// throwaway profile has to be named explicitly, and that is exactly the case where the daemon itself carries
/// the variable.
///
/// The one exception is a process BOUND to the installed profile (`spacese2e --installed-profile`), which
/// states which profile it serves on its own command line: the overrides in its environment describe a
/// profile it is not serving, so it hands them to nothing it launches.
///
/// Building either environment resolves this process's profile, which is why these redirect `HOME` to a
/// temporary directory: it keeps the profile they resolve a throwaway one. The account's own `~/.spaces` and
/// `~/.spaces-dev/profiles` stay refused to a test process however it asks for them.
final class TerminalProfileBindingTests: XCTestCase {

    /// The daemon serving the installed profile runs under launchd with no `SPACES_*` set, and a repo-built
    /// daemon derives its worktree profile from its own path. Neither may hand a `SPACES_DB_PATH` to the
    /// terminals it launches: it leaked into every process started inside — agent hooks fire on every tool
    /// call — and a `spaces` invocation that autostarts a daemon passes the whole parent environment on,
    /// which is how a daemon serving `~/.spaces` came to be classified as a development profile and took a
    /// development-range Device API port.
    ///
    /// With neither override set, this repo-built test binary derives its worktree development profile under
    /// the redirected home — a profile the build owns, carrying no override, which is the daemon this covers.
    func testTerminalLaunchEnvironmentLeavesTheSessionUnboundWhenTheDaemonCarriesNoDatabasePath() throws {
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore())
        let home = try makeTempDirectory()
        defer { SpacesProfile.resetCacheForTesting() }

        let env = try withEnvironmentValues([
            "HOME": home.path, SpacesProfile.databasePathEnvironmentVariable: nil, SpacesProfile.runtimeDirectoryEnvironmentVariable: nil,
        ]) {
            SpacesProfile.resetCacheForTesting()
            return try orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: true)
        }

        XCTAssertNil(env[SpacesProfile.databasePathEnvironmentVariable])
        XCTAssertNil(env[SpacesProfile.runtimeDirectoryEnvironmentVariable])
    }

    /// A daemon started on an ephemeral throwaway profile — the E2E harnesses and test runs, the one profile
    /// kind a binary's location cannot describe — forwards its own binding so its terminals stay on it.
    func testTerminalLaunchEnvironmentForwardsAnEphemeralDatabasePathTheDaemonCarries() throws {
        let profileRoot = try makeTempDirectory()
        let databasePath = profileRoot.appendingPathComponent("spaces.db", isDirectory: false).path
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore())
        let home = try makeTempDirectory()
        defer { SpacesProfile.resetCacheForTesting() }

        let env = try withEnvironmentValues([
            "HOME": home.path, SpacesProfile.databasePathEnvironmentVariable: databasePath,
            SpacesProfile.runtimeDirectoryEnvironmentVariable: profileRoot.appendingPathComponent("runtime", isDirectory: true).path,
        ]) {
            SpacesProfile.resetCacheForTesting()
            return try orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: true)
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
        let home = try makeTempDirectory()
        defer { SpacesProfile.resetCacheForTesting() }

        let env = try withEnvironmentValues([
            "HOME": home.path, SpacesProfile.databasePathEnvironmentVariable: databasePath,
            SpacesProfile.runtimeDirectoryEnvironmentVariable: runtimeDirectory,
        ]) {
            SpacesProfile.resetCacheForTesting()
            return try orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: true)
        }

        XCTAssertEqual(env[SpacesProfile.runtimeDirectoryEnvironmentVariable], runtimeDirectory)
        XCTAssertEqual(env[SpacesProfile.databasePathEnvironmentVariable], databasePath)
    }

    /// The exception, at the terminal-session site: a bound process's overrides describe a profile it is not
    /// serving, so forwarding them would export a `SPACES_DB_PATH` into a terminal on the INSTALLED profile —
    /// the first test's failure reached from the other side. Only those two are dropped; everything else a
    /// session inherits is untouched.
    func testTerminalLaunchEnvironmentDropsBothOverridesWhenBoundToTheInstalledProfile() throws {
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore())
        let home = try makeTempDirectory()
        let strayRoot = try makeTempDirectory()
        let eventsLogPath = strayRoot.appendingPathComponent("events.log", isDirectory: false).path
        defer { SpacesProfile.resetCacheForTesting() }

        let env = try withEnvironmentValues([
            "HOME": home.path, SpacesProfile.databasePathEnvironmentVariable: strayRoot.appendingPathComponent("spaces.db").path,
            SpacesProfile.runtimeDirectoryEnvironmentVariable: strayRoot.appendingPathComponent("runtime").path,
            "SPACES_E2E_EVENTS_LOG": eventsLogPath,
        ]) {
            try SpacesProfile.withInstalledProfileBindingForTesting {
                try orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: true)
            }
        }

        XCTAssertNil(env[SpacesProfile.databasePathEnvironmentVariable])
        XCTAssertNil(env[SpacesProfile.runtimeDirectoryEnvironmentVariable])
        XCTAssertEqual(
            env["SPACES_E2E_EVENTS_LOG"], eventsLogPath,
            "Only the two profile overrides are dropped; everything else a session inherits is forwarded as before.")
    }

    func testTerminalLaunchEnvironmentWithoutProfileEnvironmentExportsNoDatabasePath() throws {
        let databasePath = try makeTempDirectory().appendingPathComponent("spaces.db", isDirectory: false).path
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore())

        let env = try withEnvironmentValues([SpacesProfile.databasePathEnvironmentVariable: databasePath]) {
            try orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: false)
        }

        XCTAssertNil(env[SpacesProfile.databasePathEnvironmentVariable])
    }

    /// A workspace stop script is user-authored shell that commonly calls `spaces`, so it follows the same
    /// rule as a terminal session: a daemon on an ephemeral profile passes its binding on, because that is
    /// the only thing describing the profile those calls have to reach.
    func testWorkspaceScriptEnvironmentForwardsTheProfileOverridesTheProcessCarries() throws {
        let profileRoot = try makeTempDirectory()
        let databasePath = profileRoot.appendingPathComponent("spaces.db", isDirectory: false).path
        let runtimeDirectory = profileRoot.appendingPathComponent("runtime", isDirectory: true).path
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore())
        let home = try makeTempDirectory()
        defer { SpacesProfile.resetCacheForTesting() }

        let env = try withEnvironmentValues([
            "HOME": home.path, SpacesProfile.databasePathEnvironmentVariable: databasePath,
            SpacesProfile.runtimeDirectoryEnvironmentVariable: runtimeDirectory,
        ]) {
            SpacesProfile.resetCacheForTesting()
            return try orchestrator.workspaceScriptEnvironment()
        }

        XCTAssertEqual(env[SpacesProfile.databasePathEnvironmentVariable], databasePath)
        XCTAssertEqual(env[SpacesProfile.runtimeDirectoryEnvironmentVariable], runtimeDirectory)
    }

    /// The exception, at the stop-script site: `spacese2e --installed-profile stop-workspace` runs the user's
    /// own stop script, and a `SPACES_DB_PATH` inherited from the shell that started it would point every
    /// `spaces` call inside that script at a profile the run is not serving. The script still gets its
    /// prepared PATH, so this is a subtraction rather than a different environment.
    func testWorkspaceScriptEnvironmentDropsBothOverridesWhenBoundToTheInstalledProfile() throws {
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore())
        let home = try makeTempDirectory()
        let strayRoot = try makeTempDirectory()
        defer { SpacesProfile.resetCacheForTesting() }

        let env = try withEnvironmentValues([
            "HOME": home.path, SpacesProfile.databasePathEnvironmentVariable: strayRoot.appendingPathComponent("spaces.db").path,
            SpacesProfile.runtimeDirectoryEnvironmentVariable: strayRoot.appendingPathComponent("runtime").path,
        ]) {
            try SpacesProfile.withInstalledProfileBindingForTesting { try orchestrator.workspaceScriptEnvironment() }
        }

        XCTAssertNil(env[SpacesProfile.databasePathEnvironmentVariable])
        XCTAssertNil(env[SpacesProfile.runtimeDirectoryEnvironmentVariable])
        XCTAssertFalse((env["PATH"] ?? "").isEmpty, "A stop script still runs with the prepared shell PATH it needs to find its tools.")
    }
}
