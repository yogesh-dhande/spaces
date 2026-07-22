import XCTest

@testable import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Coverage for the startup stale-session repair chokepoint (`TerminalSessionStaleRecovery.reconcile`).
/// The daemon runs this after handoff adoption to finalize durable runtime rows a predecessor image (or
/// a crashed prior process) left in a live state. The critical case is own-pid-not-adopted: `execv`
/// preserves the pid, so a `.running` row whose `service_pid` matches this live image — but that this
/// image did not adopt from the handoff table — is a session the predecessor terminated whose exited
/// write was lost. The plain dead-pid rule can never repair it (the pid is alive), so it would be
/// stranded forever; this sweep finalizes it `.exited`.
final class TerminalSessionStaleRecoveryTests: XCTestCase {
    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var databaseRoot: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseRoot = root
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
    }

    override func tearDownWithError() throws {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
        if let databaseRoot { try? FileManager.default.removeItem(at: databaseRoot) }
        databaseRoot = nil
        originalDatabasePath = nil
        originalRuntimeDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func seedSession(sessionID: String, servicePID: Int32, state: TerminalSessionState) throws -> TerminalSessionPaths {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: sessionID, workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
                createdAt: "2026-05-08T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, servicePID: servicePID, childPID: 4242, state: state, updatedAt: "2026-05-08T00:00:00Z"),
            paths: paths)
        return paths
    }

    /// Attaches a live owner client so the sweep's `detachActiveClients` step has something to detach.
    private func seedLiveOwnerClient(sessionID: String, paths: TerminalSessionPaths) throws {
        let client = TerminalClient(
            id: "client-\(sessionID)", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"),
            connectedAt: "2026-05-08T00:00:00Z")
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID, client: client, mode: .owner, paths: paths, attachedAt: "2026-05-08T00:00:01Z")
    }

    // MARK: - Own pid, not adopted -> repair .exited (the lost-write-across-execv class)

    func testOwnPidUnadoptedRowIsFinalizedExitedAndClientsDetached() throws {
        let sessionID = "session-stranded"
        let paths = try seedSession(sessionID: sessionID, servicePID: getpid(), state: .running)
        try seedLiveOwnerClient(sessionID: sessionID, paths: paths)

        // Precondition establishing the pre-fix gap: this pid is ALIVE, so a dead-pid-only sweep
        // (`guard !isProcessAlive(servicePID)`) would skip the row and leave it `.running` forever.
        XCTAssertEqual(kill(getpid(), 0), 0, "own pid must be alive, which is exactly why the plain dead-pid rule can't repair it")
        XCTAssertTrue(try TerminalSessionPersistence.activeAttachments(paths: paths).count == 1)

        let finalized = try TerminalSessionStaleRecovery.reconcile(
            ownPID: getpid(), adoptedSessionIDs: [], isProcessAlive: { _ in true })

        XCTAssertEqual(finalized, [TerminalSessionStaleRecovery.FinalizedSession(sessionID: sessionID, state: .exited)])
        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(runtimeState.state, .exited)
        XCTAssertNotNil(runtimeState.exitedAt)
        XCTAssertTrue(try TerminalSessionPersistence.activeAttachments(paths: paths).isEmpty, "clients must be detached during repair")
    }

    // MARK: - Own pid, adopted -> left live

    func testOwnPidAdoptedRowIsLeftRunning() throws {
        let sessionID = "session-adopted"
        let paths = try seedSession(sessionID: sessionID, servicePID: getpid(), state: .running)

        let finalized = try TerminalSessionStaleRecovery.reconcile(
            ownPID: getpid(), adoptedSessionIDs: [sessionID], isProcessAlive: { _ in true })

        XCTAssertTrue(finalized.isEmpty, "an adopted session is live under this pid and must not be touched")
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .running)
    }

    // MARK: - Foreign pid matrix

    func testDeadForeignPidRowIsFinalizedFailed() throws {
        let sessionID = "session-dead-daemon"
        let deadPID: Int32 = 999_999
        let paths = try seedSession(sessionID: sessionID, servicePID: deadPID, state: .running)

        let finalized = try TerminalSessionStaleRecovery.reconcile(
            ownPID: getpid(), adoptedSessionIDs: [], isProcessAlive: { _ in false })

        XCTAssertEqual(finalized, [TerminalSessionStaleRecovery.FinalizedSession(sessionID: sessionID, state: .failed)])
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .failed)
    }

    func testLiveForeignPidRowIsLeftRunning() throws {
        let sessionID = "session-other-live-daemon"
        let foreignPID: Int32 = 4242
        let paths = try seedSession(sessionID: sessionID, servicePID: foreignPID, state: .running)

        let finalized = try TerminalSessionStaleRecovery.reconcile(
            ownPID: getpid(), adoptedSessionIDs: [], isProcessAlive: { $0 == foreignPID })

        XCTAssertTrue(finalized.isEmpty, "a live foreign daemon still owns its session; leave it")
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .running)
    }

    // MARK: - Already-terminal rows are never revisited

    func testAlreadyExitedRowIsNotReconciled() throws {
        let sessionID = "session-already-exited"
        let paths = try seedSession(sessionID: sessionID, servicePID: getpid(), state: .exited)

        let finalized = try TerminalSessionStaleRecovery.reconcile(
            ownPID: getpid(), adoptedSessionIDs: [], isProcessAlive: { _ in true })

        XCTAssertTrue(finalized.isEmpty)
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .exited)
    }
}
