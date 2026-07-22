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

        let result = try TerminalSessionStaleRecovery.reconcile(
            ownPID: getpid(), adoptedSessionIDs: [], isProcessAlive: { _ in true })

        XCTAssertEqual(result.finalized, [TerminalSessionStaleRecovery.FinalizedSession(sessionID: sessionID, state: .exited)])
        XCTAssertTrue(result.unrepaired.isEmpty)
        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(runtimeState.state, .exited)
        XCTAssertNotNil(runtimeState.exitedAt)
        XCTAssertTrue(try TerminalSessionPersistence.activeAttachments(paths: paths).isEmpty, "clients must be detached during repair")
    }

    // MARK: - Own pid, adopted -> left live

    func testOwnPidAdoptedRowIsLeftRunning() throws {
        let sessionID = "session-adopted"
        let paths = try seedSession(sessionID: sessionID, servicePID: getpid(), state: .running)

        let result = try TerminalSessionStaleRecovery.reconcile(
            ownPID: getpid(), adoptedSessionIDs: [sessionID], isProcessAlive: { _ in true })

        XCTAssertTrue(result.finalized.isEmpty, "an adopted session is live under this pid and must not be touched")
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .running)
    }

    // MARK: - Foreign pid matrix

    func testDeadForeignPidRowIsFinalizedFailed() throws {
        let sessionID = "session-dead-daemon"
        let deadPID: Int32 = 999_999
        let paths = try seedSession(sessionID: sessionID, servicePID: deadPID, state: .running)

        let result = try TerminalSessionStaleRecovery.reconcile(
            ownPID: getpid(), adoptedSessionIDs: [], isProcessAlive: { _ in false })

        XCTAssertEqual(result.finalized, [TerminalSessionStaleRecovery.FinalizedSession(sessionID: sessionID, state: .failed)])
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .failed)
    }

    func testLiveForeignPidRowIsLeftRunning() throws {
        let sessionID = "session-other-live-daemon"
        let foreignPID: Int32 = 4242
        let paths = try seedSession(sessionID: sessionID, servicePID: foreignPID, state: .running)

        let result = try TerminalSessionStaleRecovery.reconcile(
            ownPID: getpid(), adoptedSessionIDs: [], isProcessAlive: { $0 == foreignPID })

        XCTAssertTrue(result.finalized.isEmpty, "a live foreign daemon still owns its session; leave it")
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .running)
    }

    // MARK: - Already-terminal rows are never revisited

    func testAlreadyExitedRowIsNotReconciled() throws {
        let sessionID = "session-already-exited"
        let paths = try seedSession(sessionID: sessionID, servicePID: getpid(), state: .exited)

        let result = try TerminalSessionStaleRecovery.reconcile(
            ownPID: getpid(), adoptedSessionIDs: [], isProcessAlive: { _ in true })

        XCTAssertTrue(result.finalized.isEmpty)
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .exited)
    }

    // MARK: - Repair write cannot commit -> not finalized, row untouched, healed on retry

    /// The repair itself is a durable write. When it cannot commit (a sustained writer lock or storage
    /// fault — the same failure class that can drop a predecessor's exited-state write), the sweep must
    /// NOT report the session as finalized and must leave the runtime row in its prior live state; the
    /// bug this guards against was the `try?` that suppressed the failed write yet unconditionally
    /// appended the session to the finalized list, so a caller believed a row was `.exited` while it
    /// stayed `.running` under this live pid until the next daemon restart.
    ///
    /// The repair's runtime-state write and client detach run inside ONE `finalizeSessionRepair`
    /// transaction, so partial commit (row finalized while its clients stay attached — which the
    /// terminal-row-skipping restart sweep could never revisit, permanently stranding ghost
    /// attachments) is structurally impossible rather than merely rare: there is no seam that can fail
    /// only the second half. The assertions below verify both halves rolled back together — the row is
    /// still `.running` AND its attachments are still active — proving neither committed alone.
    ///
    /// Failure injection makes ONLY the write fail while reads still succeed: the profile database is
    /// chmod'd read-only (`0o444`). Every connection opens read/write, but SQLite is lazy — `SELECT`
    /// (and the already-current `PRAGMA journal_mode=WAL` / migration check) needs no write, so
    /// `listKnownSessions`/`readRuntimeState` still serve the row, whereas the repair's `BEGIN IMMEDIATE`
    /// write transaction fails with "attempt to write a readonly database". Restoring the mode lets the
    /// bounded retry land the repair on a second pass, healing the strand within the daemon's lifetime.
    func testRepairWriteFailureLeavesRowRunningAndUnfinalizedThenHealsOnRetry() throws {
        let sessionID = "session-repair-write-fails"
        let paths = try seedSession(sessionID: sessionID, servicePID: getpid(), state: .running)
        try seedLiveOwnerClient(sessionID: sessionID, paths: paths)

        let databasePath = try SpacesProfile.current().databasePath
        // Sanity: reads and writes both work before the fault, so the failure below is attributable to
        // the injected read-only mode and not to a mis-seeded fixture.
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .running)

        let fileManager = FileManager.default
        let originalPermissions = try fileManager.attributesOfItem(atPath: databasePath)[.posixPermissions] as? NSNumber
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: databasePath)
        defer {
            if let originalPermissions {
                try? fileManager.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: databasePath)
            }
        }

        // Pre-fix behavior: the suppressed write (`try?`) would still append this session to `finalized`.
        // Post-fix: the bounded retry exhausts, the session is reported `unrepaired`, and the row is left
        // untouched in its prior `.running` state with its clients still attached.
        let failedResult = try TerminalSessionStaleRecovery.reconcile(
            ownPID: getpid(), adoptedSessionIDs: [], isProcessAlive: { _ in true })

        XCTAssertTrue(
            failedResult.finalized.isEmpty, "a repair whose write cannot commit must NOT be reported finalized (the pre-fix bug)")
        XCTAssertEqual(failedResult.unrepaired, [sessionID], "a repair that could not commit must be reported for the caller to log")
        XCTAssertEqual(
            try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .running,
            "the runtime row must be left in its prior live state when the repair write fails")
        XCTAssertEqual(
            try TerminalSessionPersistence.activeAttachments(paths: paths).count, 1,
            "clients must stay attached when the repair could not commit")

        // Restore write access and run the sweep again: the repair now commits and the row is finalized.
        if let originalPermissions {
            try fileManager.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: databasePath)
        }

        let healedResult = try TerminalSessionStaleRecovery.reconcile(
            ownPID: getpid(), adoptedSessionIDs: [], isProcessAlive: { _ in true })

        XCTAssertEqual(
            healedResult.finalized, [TerminalSessionStaleRecovery.FinalizedSession(sessionID: sessionID, state: .exited)],
            "once the database is writable again the retry lands the repair")
        XCTAssertTrue(healedResult.unrepaired.isEmpty)
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .exited)
        XCTAssertTrue(
            try TerminalSessionPersistence.activeAttachments(paths: paths).isEmpty, "clients must be detached once the repair commits")
    }
}
