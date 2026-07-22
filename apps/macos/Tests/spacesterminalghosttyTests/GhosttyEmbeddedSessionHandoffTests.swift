import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Exercises the macOS core's exec-in-place handoff: `quiesceForHandoff()` on a live
/// session and `resumeFromHandoff(_:)` / `resumeInPlaceAfterFailedExec()` on the
/// staged image, including the driver's replay of `output.log` at the persisted grid.
///
/// A single test process cannot actually `execv`, so the resume tests reconstruct the
/// two halves of the handoff in process. The transcript and the handoff record come
/// from a real `quiesceForHandoff()` on a first core. The resuming core is then handed
/// a descriptor for a fresh, test-owned PTY plus a live "liveness" child (a bare
/// `sleep`), standing in for the master fd and child that `execv` preserves — the
/// resume code path adopts whatever descriptor it is given, so this faithfully drives
/// replay + live-fd I/O. Injecting bytes on the test-owned PTY slave (rather than
/// re-driving the original child) avoids the in-process artifact where two cores would
/// fight over one PTY: `execv` destroys the old reader atomically, but a test cannot,
/// and closing a PTY master out from under a blocked read hangs on macOS.
final class GhosttyEmbeddedSessionHandoffTests: XCTestCase {
    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var databaseRoot: URL?

    /// Carries an engine-isolated reference (created inside a `TerminalEngineActor.run` block) back out to
    /// the nonisolated test body; the value is only ever *used* on the engine actor via a later bridge.
    private final class Box<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

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

    func testGhosttyOutputDeliveryFenceWaitsForRegisteredCallback() {
        let fence = GhosttyEmbeddedHandoffOutputDeliveryFence()
        let drained = DispatchSemaphore(value: 0)
        fence.beginDelivery()

        Task {
            await fence.waitUntilDrained()
            drained.signal()
        }

        XCTAssertEqual(drained.wait(timeout: .now() + 0.1), .timedOut)
        fence.finishDelivery()
        XCTAssertEqual(drained.wait(timeout: .now() + 5), .success)
    }

    // MARK: - Fixtures

    /// A test-owned PTY plus a live child pid, standing in for the master fd and child
    /// that survive `execv` for the resuming core to adopt. The child is a bare `sleep`
    /// (spawned with `posix_spawn` so only the session driver ever reaps it) that keeps
    /// the resumed session's liveness checks satisfied; live output is injected by
    /// writing to `slave`, which the resumed core reads from `master`.
    private struct AdoptablePTY {
        let master: Int32
        let slave: Int32
        let childPID: Int32
    }

    private static func requireGhosttyAvailable() throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("GhosttyKit.xcframework is unavailable for embedded renderer testing.") }
    }

    private static func makeTemporaryPaths() throws -> TerminalSessionPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        return paths
    }

    private static func makeConfiguration(sessionID: String, command: String?) -> TerminalSessionLaunchConfiguration {
        TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "handoff", workingDirectory: FileManager.default.temporaryDirectory.path,
            shell: "/bin/sh", command: command, createdAt: "2026-07-12T00:00:00Z", workspaceID: "workspace-handoff", kind: .shell)
    }

    private static func makeAdoptablePTY() throws -> AdoptablePTY {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        XCTAssertGreaterThanOrEqual(master, 0, "posix_openpt failed")
        XCTAssertEqual(grantpt(master), 0)
        XCTAssertEqual(unlockpt(master), 0)
        let slaveName = try XCTUnwrap(ptsname(master).map { String(cString: $0) })
        let slave = open(slaveName, O_RDWR | O_NOCTTY)
        XCTAssertGreaterThanOrEqual(slave, 0, "opening the PTY slave failed")

        var childPID: pid_t = 0
        let path = "/bin/sh"
        let arguments = [path, "-c", "sleep 120"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { for argument in argv where argument != nil { free(argument) } }
        XCTAssertEqual(posix_spawn(&childPID, path, nil, nil, &argv, environ), 0, "posix_spawn of the liveness child failed")

        return AdoptablePTY(master: master, slave: slave, childPID: childPID)
    }

    private static func tearDown(_ pty: AdoptablePTY) {
        close(pty.slave)
        kill(pty.childPID, SIGKILL)
        var status: Int32 = 0
        waitpid(pty.childPID, &status, WNOHANG)
    }

    /// A handoff record identical to `record` but pointing at a freshly adopted PTY and
    /// liveness child (see `AdoptablePTY`).
    private static func handoffRecord(from record: DaemonHandoffSessionRecord, adopting pty: AdoptablePTY) -> DaemonHandoffSessionRecord {
        DaemonHandoffSessionRecord(
            sessionID: record.sessionID, masterFD: pty.master, childPID: pty.childPID, columns: record.columns, rows: record.rows,
            ownerEpoch: record.ownerEpoch, screenStateRevision: record.screenStateRevision, appearance: record.appearance)
    }

    /// Engine-isolated; call from inside a `TerminalEngineActor.run`/`runSynchronously` bridge.
    @TerminalEngineActor private static func headlessHost(for core: GhosttyEmbeddedSessionCore) throws -> GhosttyHeadlessRendererHost {
        try XCTUnwrap(core.rendererHost as? GhosttyHeadlessRendererHost)
    }

    /// Nonisolated poller: the polling loop itself must stay off the engine actor so its
    /// `Task.sleep` suspensions don't hold the engine's queue while the condition (and the tick pump
    /// that drives io-thread screen mutations to visibility) needs to run there. Each poll hops onto
    /// the engine synchronously to tick and evaluate the (engine-isolated) condition together.
    private func waitAsync(
        timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping @TerminalEngineActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let satisfied = TerminalEngineActor.runSynchronously { () -> Bool in
                if condition() { return true }
                GhosttyEmbeddedAppService.shared.tick()
                return false
            }
            if satisfied { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(TerminalEngineActor.runSynchronously { condition() }, "waitAsync timed out", file: file, line: line)
    }

    /// Engine-isolated; call from inside a `TerminalEngineActor.run`/`runSynchronously` bridge.
    @TerminalEngineActor private static func snapshotText(of core: GhosttyEmbeddedSessionCore) -> String? {
        core.rendererHost.requestSurfaceRefresh()
        GhosttyEmbeddedAppService.shared.tick()
        return core.rendererHost.snapshotText()
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    private static func nonEmptyTrimmedLines(_ text: String?) -> [String] {
        (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.filter { !$0.isEmpty }
    }

    // MARK: - 1. Replay fidelity + live continuity

    func testResumeReplaysTranscriptAndKeepsPTYLive() async throws {
        try Self.requireGhosttyAvailable()
        let paths = try Self.makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

        let marker = "HANDOFF_MARKER_ALPHA"
        let configuration = Self.makeConfiguration(
            sessionID: "handoff-replay-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
        let sourceCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
            let sourceCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            try sourceCore.startIfNeeded()
            XCTAssertTrue(try Self.headlessHost(for: sourceCore).resizeCellGrid(columns: 100, rows: 30))
            return Box(sourceCore)
        }
        let sourceCore = sourceCoreBox.value
        try await waitAsync { Self.snapshotText(of: sourceCore)?.contains(marker) == true }

        guard let record = try await sourceCore.quiesceForHandoff() else { return XCTFail("quiesce produced no handoff record for a live session") }
        XCTAssertEqual(record.columns, 100)
        XCTAssertEqual(record.rows, 30)
        XCTAssertEqual(Self.occurrences(of: marker, in: try String(contentsOfFile: paths.outputPath)), 1, "transcript must hold the marker exactly once")
        TerminalEngineActor.runSynchronously { sourceCore.terminate() }

        let pty = try Self.makeAdoptablePTY()
        let resumedCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
            Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
        }
        let resumedCore = resumedCoreBox.value
        defer {
            // Close the slave FIRST so the adopted master's blocked read hits EOF, then
            // terminate: closing a PTY master out from under a still-blocked read hangs.
            Self.tearDown(pty)
            TerminalEngineActor.runSynchronously { resumedCore.terminate() }
        }
        try await resumedCore.resumeFromHandoff(Self.handoffRecord(from: record, adopting: pty))

        // Scrollback/screen rebuilt from the replayed output.log.
        try await waitAsync { Self.snapshotText(of: resumedCore)?.contains(marker) == true }

        // PTY I/O is live through the adopted fd: bytes injected on the slave surface
        // on the resumed core and land in output.log exactly once.
        let secondMarker = "HANDOFF_MARKER_BETA"
        XCTAssertGreaterThan(write(pty.slave, "\(secondMarker)\n", secondMarker.utf8.count + 1), 0)
        try await waitAsync { Self.snapshotText(of: resumedCore)?.contains(secondMarker) == true }
        try await waitAsync { (try? String(contentsOfFile: paths.outputPath))?.contains(secondMarker) == true }

        let transcript = try String(contentsOfFile: paths.outputPath)
        XCTAssertEqual(Self.occurrences(of: marker, in: transcript), 1, "replay must not re-append the original transcript to output.log")
        XCTAssertEqual(Self.occurrences(of: secondMarker, in: transcript), 1, "post-handoff output must land in output.log exactly once")
    }

    func testResumeDoesNotRestoreClearedScreenOrScrollback() async throws {
        try Self.requireGhosttyAvailable()
        let paths = try Self.makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

        let clearedMarker = "HANDOFF_CLEARED_MARKER"
        let configuration = Self.makeConfiguration(
            sessionID: "handoff-cleared-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(clearedMarker)'; cat")
        let sourceCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
            let sourceCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            try sourceCore.startIfNeeded()
            return Box(sourceCore)
        }
        let sourceCore = sourceCoreBox.value
        try await waitAsync { Self.snapshotText(of: sourceCore)?.contains(clearedMarker) == true }
        XCTAssertTrue(TerminalEngineActor.runSynchronously { sourceCore.rendererHost.clearScreenAndScrollback() })
        try await waitAsync {
            guard let text = Self.snapshotText(of: sourceCore) else { return false }
            return !text.contains(clearedMarker)
        }

        guard let record = try await sourceCore.quiesceForHandoff() else { return XCTFail("quiesce produced no handoff record") }
        TerminalEngineActor.runSynchronously { sourceCore.terminate() }

        let pty = try Self.makeAdoptablePTY()
        let resumedCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
            Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
        }
        let resumedCore = resumedCoreBox.value
        defer {
            Self.tearDown(pty)
            TerminalEngineActor.runSynchronously { resumedCore.terminate() }
        }
        try await resumedCore.resumeFromHandoff(Self.handoffRecord(from: record, adopting: pty))
        let liveMarker = "HANDOFF_AFTER_CLEAR_MARKER"
        XCTAssertGreaterThan(write(pty.slave, "\(liveMarker)\n", liveMarker.utf8.count + 1), 0)
        try await waitAsync { Self.snapshotText(of: resumedCore)?.contains(liveMarker) == true }
        XCTAssertFalse(
            TerminalEngineActor.runSynchronously { Self.snapshotText(of: resumedCore) }?.contains(clearedMarker) == true,
            "handoff replay must preserve the cleared screen and scrollback")
    }

    // MARK: - 2. Reflow invariant (persisted grid before new output)

    func testResumeRestoresPersistedGridBeforeNewOutput() async throws {
        try Self.requireGhosttyAvailable()
        let paths = try Self.makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

        // A line wider than the grid so its wrapping depends on the replay width.
        let wideLine = String(repeating: "A", count: 150) + "DONE"
        let configuration = Self.makeConfiguration(
            sessionID: "handoff-reflow-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(wideLine)'; cat")
        let sourceCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
            let sourceCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            try sourceCore.startIfNeeded()
            XCTAssertTrue(try Self.headlessHost(for: sourceCore).resizeCellGrid(columns: 100, rows: 30))
            return Box(sourceCore)
        }
        let sourceCore = sourceCoreBox.value
        try await waitAsync { Self.snapshotText(of: sourceCore)?.contains("DONE") == true }
        let preHandoffLines = Self.nonEmptyTrimmedLines(TerminalEngineActor.runSynchronously { Self.snapshotText(of: sourceCore) })
        XCTAssertGreaterThanOrEqual(preHandoffLines.count, 2, "a 154-column line must wrap at grid width 100")

        guard let record = try await sourceCore.quiesceForHandoff() else { return XCTFail("quiesce produced no handoff record") }
        TerminalEngineActor.runSynchronously { sourceCore.terminate() }

        let pty = try Self.makeAdoptablePTY()
        let resumedCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
            Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
        }
        let resumedCore = resumedCoreBox.value
        defer {
            // Close the slave FIRST so the adopted master's blocked read hits EOF, then
            // terminate: closing a PTY master out from under a still-blocked read hangs.
            Self.tearDown(pty)
            TerminalEngineActor.runSynchronously { resumedCore.terminate() }
        }
        try await resumedCore.resumeFromHandoff(Self.handoffRecord(from: record, adopting: pty))

        // The grid is the persisted size BEFORE any new output arrives.
        let resumedSize = try await TerminalEngineActor.run { try Self.headlessHost(for: resumedCore).surfaceCellSize() }
        XCTAssertEqual(resumedSize?.columns, 100)
        XCTAssertEqual(resumedSize?.rows, 30)

        try await waitAsync { Self.snapshotText(of: resumedCore)?.contains("DONE") == true }
        let postHandoffLines = Self.nonEmptyTrimmedLines(TerminalEngineActor.runSynchronously { Self.snapshotText(of: resumedCore) })
        XCTAssertEqual(postHandoffLines, preHandoffLines, "the wide line must wrap identically after replay at the persisted width")
    }

    // MARK: - 3. Epoch + revision carry

    func testResumeCarriesOwnerEpochAndAdvancesRevision() async throws {
        try Self.requireGhosttyAvailable()
        let paths = try Self.makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

        let marker = "EPOCH_MARKER"
        let configuration = Self.makeConfiguration(
            sessionID: "handoff-epoch-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
        let owner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
            connectedAt: "2026-07-12T00:00:00Z")
        let sourceCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
            let sourceCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            try sourceCore.attachClient(owner, mode: .owner)
            XCTAssertGreaterThan(sourceCore.debugOwnerEpoch, 0, "attaching an owner must advance the owner epoch")
            return Box(sourceCore)
        }
        let sourceCore = sourceCoreBox.value
        try await waitAsync { Self.snapshotText(of: sourceCore)?.contains(marker) == true }

        guard let record = try await sourceCore.quiesceForHandoff() else { return XCTFail("quiesce produced no handoff record") }
        XCTAssertEqual(record.ownerEpoch, TerminalEngineActor.runSynchronously { sourceCore.debugOwnerEpoch }, "the record must carry the live owner epoch")
        let recordedEpoch = record.ownerEpoch
        // Do NOT terminate the source core here: terminate() detaches active clients, and
        // this test relies on the owner attachment persisting across the handoff (quiesce
        // itself never detaches). The quiesced source core is cleaned up when it deinits.
        defer { TerminalEngineActor.runSynchronously { sourceCore.terminate() } }

        let pty = try Self.makeAdoptablePTY()
        let resumedCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
            Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
        }
        let resumedCore = resumedCoreBox.value
        defer {
            // Close the slave FIRST so the adopted master's blocked read hits EOF, then
            // terminate: closing a PTY master out from under a still-blocked read hangs.
            Self.tearDown(pty)
            TerminalEngineActor.runSynchronously { resumedCore.terminate() }
        }
        try await resumedCore.resumeFromHandoff(Self.handoffRecord(from: record, adopting: pty))

        // The resumed core enforces the carried epoch: a stale epoch is rejected, the
        // current one is accepted (the owner attachment persisted across the handoff).
        try await TerminalEngineActor.run {
            let staleResponse = resumedCore.handleControlRequest(
                TerminalControlRequest(command: "send", text: "x\n", clientID: owner.id, ownerEpoch: recordedEpoch - 1))
            XCTAssertFalse(staleResponse.ok, "a stale owner epoch must be rejected")
            XCTAssertEqual(staleResponse.errorCode, .ownershipRejected)
            let currentResponse = resumedCore.handleControlRequest(
                TerminalControlRequest(command: "send", text: "x\n", clientID: owner.id, ownerEpoch: recordedEpoch))
            XCTAssertTrue(currentResponse.ok, "the current owner epoch must be accepted: \(currentResponse.message)")
        }

        // The first post-resume payload advances past the recorded revision and is a
        // self-contained full render update (the replayed marker must be on screen for
        // a render frame to be produced).
        try await waitAsync { Self.snapshotText(of: resumedCore)?.contains(marker) == true }
        try await TerminalEngineActor.run {
            let payload = try XCTUnwrap(resumedCore.debugCurrentRemoteSessionState(reason: TerminalRemoteSessionStateReason.initial))
            let resumedRevision = try XCTUnwrap(payload.screenStateRevision)
            XCTAssertGreaterThan(resumedRevision, record.screenStateRevision, "the resumed revision must be strictly greater than the recorded one")
            let update = try XCTUnwrap(payload.decodedRenderUpdate)
            XCTAssertEqual(update.kind, .full, "the first post-resume frame must be a full render update")
        }
    }

    // MARK: - 4. Dead child yields no record

    func testQuiesceReturnsNilWhenChildAlreadyExited() async throws {
        try Self.requireGhosttyAvailable()
        let paths = try Self.makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

        let configuration = Self.makeConfiguration(sessionID: "handoff-dead-\(UUID().uuidString)", command: "true")
        let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            try core.startIfNeeded()
            return Box(core)
        }
        let core = coreBox.value
        defer { TerminalEngineActor.runSynchronously { core.terminate() } }

        // Wait for the short-lived child to exit and drive the session-closed path
        // (childPID() reports the last known pid even after exit, so gate on the session
        // no longer being started instead).
        try await waitAsync { !core.isStarted }

        let record = try await core.quiesceForHandoff()
        XCTAssertNil(record, "a session whose child already exited must not produce a handoff record")
    }

    func testQuiesceThrowsWhenBufferedOutputCannotBePersisted() async throws {
        try Self.requireGhosttyAvailable()
        let paths = try Self.makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

        let marker = "PERSISTENCE_FAILURE_MARKER"
        let configuration = Self.makeConfiguration(
            sessionID: "handoff-persistence-failure-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
        let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            try core.startIfNeeded()
            return Box(core)
        }
        let core = coreBox.value
        defer { TerminalEngineActor.runSynchronously { core.terminate() } }
        try await waitAsync { Self.snapshotText(of: core)?.contains(marker) == true }

        // Replace output.log with a directory while the existing handle still refers to the
        // unlinked file. Quiesce closes that handle, then its direct append open must fail.
        try FileManager.default.removeItem(atPath: paths.outputPath)
        try FileManager.default.createDirectory(atPath: paths.outputPath, withIntermediateDirectories: false)

        do {
            _ = try await core.quiesceForHandoff()
            XCTFail("quiesce must not produce a handoff record when output.log cannot be opened")
        } catch { XCTAssertTrue(FileManager.default.fileExists(atPath: paths.outputPath)) }

        // Restore a writable transcript and prove the old image can rebind the buffered live core.
        try FileManager.default.removeItem(atPath: paths.outputPath)
        XCTAssertTrue(FileManager.default.createFile(atPath: paths.outputPath, contents: nil))
        await core.resumeInPlaceAfterFailedExec()
        let afterMarker = "AFTER_PERSISTENCE_FAILURE"
        try await TerminalEngineActor.run { try Self.headlessHost(for: core).sendRawBytes(Data("\(afterMarker)\n".utf8)) }
        try await waitAsync { (try? String(contentsOfFile: paths.outputPath))?.contains(afterMarker) == true }
    }

    // MARK: - 5. Failed-exec rebind

    func testResumeInPlaceAfterFailedExecRestoresOutputAndSockets() async throws {
        try Self.requireGhosttyAvailable()
        let paths = try Self.makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

        let marker = "REBIND_MARKER"
        let configuration = Self.makeConfiguration(
            sessionID: "handoff-rebind-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
        let owner = TerminalClient(
            id: "remote-owner", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPad", deviceName: "iPad"),
            connectedAt: "2026-07-12T00:00:00Z")
        let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            try core.attachClient(owner, mode: .owner)
            return Box(core)
        }
        let core = coreBox.value
        defer { TerminalEngineActor.runSynchronously { core.terminate() } }
        try await waitAsync { Self.snapshotText(of: core)?.contains(marker) == true }

        // Quiesce as if about to exec, then take the failed-exec fallback on the SAME core.
        guard let record = try await core.quiesceForHandoff() else { return XCTFail("quiesce produced no handoff record") }
        XCTAssertGreaterThan(record.childPID, 0)
        let duringHandoffMarker = "DURING_FAILED_HANDOFF"
        try await TerminalEngineActor.run { try Self.headlessHost(for: core).sendRawBytes(Data("\(duringHandoffMarker)\n".utf8)) }
        try await waitAsync { (try? String(contentsOfFile: paths.outputPath))?.contains(duringHandoffMarker) == true }
        XCTAssertFalse(
            TerminalEngineActor.runSynchronously { Self.snapshotText(of: core) }?.contains(duringHandoffMarker) == true,
            "quiesced output must bypass the renderer")

        await core.resumeInPlaceAfterFailedExec()
        try await waitAsync { Self.snapshotText(of: core)?.contains(duringHandoffMarker) == true }

        // The state-stream socket answers again: a fresh subscriber gets an initial payload.
        let received = InitialPayloadCollector()
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in received.record(payload) }
        try client.start()
        defer { client.stop() }
        try await waitAsync { received.count > 0 }

        // Output flows again through the rebound (never rebuilt) session and lands in output.log.
        let afterMarker = "AFTER_REBIND"
        try await TerminalEngineActor.run { try Self.headlessHost(for: core).sendRawBytes(Data("\(afterMarker)\n".utf8)) }
        try await waitAsync { Self.snapshotText(of: core)?.contains(afterMarker) == true }
        try await waitAsync { (try? String(contentsOfFile: paths.outputPath))?.contains(afterMarker) == true }

        let transcript = try String(contentsOfFile: paths.outputPath)
        XCTAssertEqual(Self.occurrences(of: marker, in: transcript), 1)
        XCTAssertEqual(Self.occurrences(of: duringHandoffMarker, in: transcript), 1)
        XCTAssertEqual(Self.occurrences(of: afterMarker, in: transcript), 1)
    }
}

/// Thread-safe collector for the state-stream subscriber callback.
private final class InitialPayloadCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [GhosttyRemoteSessionStatePayload] = []

    func record(_ payload: GhosttyRemoteSessionStatePayload) {
        lock.lock()
        payloads.append(payload)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return payloads.count
    }
}
