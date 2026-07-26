import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// A Spaces terminal is bound to the profile of the daemon that launched it, so any `spaces` binary run
/// inside the session — a globally-configured agent hook naming one absolute build, or a command typed by
/// hand — acts on that profile instead of resolving one from its own location on disk.
///
/// The resolved profile database path is injected rather than resolved, so these tests never depend on a
/// live profile root being resolvable under XCTest.
final class TerminalProfileBindingTests: XCTestCase {

    func testTerminalLaunchEnvironmentExportsResolvedProfileDatabasePath() throws {
        let profileDatabasePath = try makeTempDirectory().appendingPathComponent("spaces.db", isDirectory: false).path
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore(), profileDatabasePath: { profileDatabasePath })

        let env = try orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: true)

        XCTAssertEqual(env[SpacesProfile.databasePathEnvironmentVariable], profileDatabasePath)
    }

    /// The daemon that serves the installed profile runs under launchd with no `SPACES_*` in its own
    /// environment. Binding must come from the resolved profile, not from forwarding what the daemon
    /// happens to carry, or installed-profile terminals stay unbound.
    func testTerminalLaunchEnvironmentBindsSessionWhenDaemonCarriesNoProfileEnvironment() throws {
        let profileDatabasePath = try makeTempDirectory().appendingPathComponent("spaces.db", isDirectory: false).path
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore(), profileDatabasePath: { profileDatabasePath })

        let env = try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: nil, SpacesProfile.runtimeDirectoryEnvironmentVariable: nil,
        ]) { try orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: true) }

        XCTAssertEqual(env[SpacesProfile.databasePathEnvironmentVariable], profileDatabasePath)
    }

    /// Naming the database alone binds the whole profile: the runtime directory derives from the directory
    /// holding it. Exporting it too would let a terminal be bound to one profile's database and another
    /// profile's sockets and locks.
    func testTerminalLaunchEnvironmentLeavesRuntimeDirectoryToDerivation() throws {
        let profileDatabasePath = try makeTempDirectory().appendingPathComponent("spaces.db", isDirectory: false).path
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore(), profileDatabasePath: { profileDatabasePath })

        let env = try withEnvironmentValues([SpacesProfile.runtimeDirectoryEnvironmentVariable: nil]) {
            try orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: true)
        }

        XCTAssertNil(env[SpacesProfile.runtimeDirectoryEnvironmentVariable])
    }

    /// E2E harnesses start a daemon whose runtime root is deliberately not the default one beside its
    /// database. Those daemons forward the override so their terminals stay on the runtime root the daemon
    /// itself uses.
    func testTerminalLaunchEnvironmentForwardsAnExplicitDaemonRuntimeDirectory() throws {
        let profileRoot = try makeTempDirectory()
        let profileDatabasePath = profileRoot.appendingPathComponent("spaces.db", isDirectory: false).path
        let runtimeDirectory = profileRoot.appendingPathComponent("split-runtime", isDirectory: true).path
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore(), profileDatabasePath: { profileDatabasePath })

        let env = try withEnvironmentValues([SpacesProfile.runtimeDirectoryEnvironmentVariable: runtimeDirectory]) {
            try orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: true)
        }

        XCTAssertEqual(env[SpacesProfile.runtimeDirectoryEnvironmentVariable], runtimeDirectory)
        XCTAssertEqual(env[SpacesProfile.databasePathEnvironmentVariable], profileDatabasePath)
    }

    func testTerminalLaunchEnvironmentWithoutProfileEnvironmentExportsNoDatabasePath() throws {
        let profileDatabasePath = try makeTempDirectory().appendingPathComponent("spaces.db", isDirectory: false).path
        let orchestrator = makeTestOrchestrator(store: try makeTemporaryStore(), profileDatabasePath: { profileDatabasePath })

        let env = try orchestrator.terminalLaunchEnvironment(base: [:], includeInheritedPath: false, includeProfileEnvironment: false)

        XCTAssertNil(env[SpacesProfile.databasePathEnvironmentVariable])
    }
}
