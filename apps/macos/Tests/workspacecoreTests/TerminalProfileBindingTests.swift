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
/// states which profile it serves on its own command line: every Spaces-namespace variable in its environment
/// describes something it is not serving, so it hands none of them to what it launches. That subtraction is
/// `SpacesProfile.environmentServingThisProfile` and is covered directly in `TerminalServiceTests`; what these
/// cover here is the ordinary forwarding rule it is the exception to, and the fact that no test host can
/// build a bound environment at all.
///
/// Building either environment resolves this process's profile, which is why these redirect `HOME` to a
/// temporary directory: it keeps the profile they resolve a throwaway one. The account's own `~/.spaces` and
/// `~/.spaces-dev/profiles` stay refused to a test process however it asks for them — including through a
/// binding, which reads the account home and ignores `HOME` entirely.
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

    /// Both launch environments resolve this process's profile, and a bound resolution names the ACCOUNT's
    /// `~/.spaces` — which a test process is refused outright. So no suite can build an installed-profile
    /// session or script environment at all, whatever it does to `HOME`, and that refusal is the guarantee
    /// worth asserting at these sites: what a bound process would then subtract is settled by
    /// `SpacesProfile.environmentServingThisProfile`, which is covered directly in `TerminalServiceTests`
    /// where no live profile has to be resolved to exercise it.
    func testNoTestHostCanBuildAnInstalledProfileLaunchEnvironment() throws {
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore())
        let home = try makeTempDirectory()
        defer { SpacesProfile.resetCacheForTesting() }

        try withEnvironmentValues(["HOME": home.path]) {
            SpacesProfile.resetCacheForTesting()
            try SpacesProfile.withInstalledProfileBindingForTesting {
                XCTAssertThrowsError(
                    try orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: true))
                XCTAssertThrowsError(try orchestrator.workspaceScriptEnvironment())
            }
        }
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
    /// the only thing describing the profile those calls have to reach. It is this process's own environment,
    /// prepared PATH included — what a bound run applies to it is a subtraction, never a different
    /// environment.
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
        XCTAssertFalse((env["PATH"] ?? "").isEmpty, "A stop script runs with the prepared shell PATH it needs to find its tools.")
    }
}
