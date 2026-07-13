#if os(Linux)
    import Foundation
    import Glibc
    import XCTest
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Exercises the Linux headless core's exec-in-place handoff: `quiesceForHandoff()`
    /// on a live session and `resumeFromHandoff(_:)` / `resumeInPlaceAfterFailedExec()`
    /// on the staged image, including `recreateVTRenderer`'s replay of `output.log` at
    /// the persisted grid.
    ///
    /// A single test process cannot actually `execv`, so the resume tests reconstruct
    /// the two halves of the handoff in process. The transcript and the handoff record
    /// come from a real `quiesceForHandoff()` on a first core. The resuming core is then
    /// handed a descriptor for a fresh, test-owned PTY plus a live "liveness" child (a
    /// bare `sleep`), standing in for the master fd and child that `execv` preserves —
    /// the resume code path adopts whatever descriptor it is given, so this faithfully
    /// drives replay + live-fd I/O. Injecting bytes on the test-owned PTY slave (rather
    /// than re-driving the original child) avoids the in-process artifact where two cores
    /// would fight over one PTY: `execv` destroys the old reader atomically, but a test
    /// cannot, and closing a PTY master out from under a blocked read hangs.
    final class GhosttyLinuxHeadlessSessionHandoffTests: XCTestCase {
        private var originalDatabasePath: String?
        private var databaseRoot: URL?

        override func setUpWithError() throws {
            try super.setUpWithError()
            originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            databaseRoot = root
            setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        }

        override func tearDownWithError() throws {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let databaseRoot { try? FileManager.default.removeItem(at: databaseRoot) }
            databaseRoot = nil
            originalDatabasePath = nil
            try super.tearDownWithError()
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

        private func makeTemporaryPaths() throws -> TerminalSessionPaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            return paths
        }

        private func makeConfiguration(sessionID: String, command: String?) -> TerminalSessionLaunchConfiguration {
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "handoff", workingDirectory: FileManager.default.temporaryDirectory.path,
                shell: "/bin/sh", command: command, createdAt: "2026-07-12T00:00:00Z", workspaceID: "workspace-handoff", kind: .shell)
        }

        private func makeAdoptablePTY() throws -> AdoptablePTY {
            // Swift's Linux Glibc overlay does not surface posix_openpt/grantpt/unlockpt/ptsname,
            // so allocate the master/slave pair with openpty (which it does expose) — a single
            // call that returns both descriptors of a fresh PTY.
            var master: Int32 = 0
            var slave: Int32 = 0
            XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0, "openpty failed")
            XCTAssertGreaterThanOrEqual(master, 0)
            XCTAssertGreaterThanOrEqual(slave, 0)

            var childPID: pid_t = 0
            let path = "/bin/sh"
            let arguments = [path, "-c", "sleep 120"]
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            defer { for argument in argv where argument != nil { free(argument) } }
            XCTAssertEqual(posix_spawn(&childPID, path, nil, nil, &argv, environ), 0, "posix_spawn of the liveness child failed")

            return AdoptablePTY(master: master, slave: slave, childPID: childPID)
        }

        private func tearDown(_ pty: AdoptablePTY) {
            close(pty.slave)
            kill(pty.childPID, SIGKILL)
            var status: Int32 = 0
            waitpid(pty.childPID, &status, WNOHANG)
        }

        /// A handoff record identical to `record` but pointing at a freshly adopted PTY and
        /// liveness child (see `AdoptablePTY`).
        private func handoffRecord(from record: DaemonHandoffSessionRecord, adopting pty: AdoptablePTY) -> DaemonHandoffSessionRecord {
            DaemonHandoffSessionRecord(
                sessionID: record.sessionID, masterFD: pty.master, childPID: pty.childPID, columns: record.columns, rows: record.rows,
                ownerEpoch: record.ownerEpoch, screenStateRevision: record.screenStateRevision, appearance: record.appearance)
        }

        // MARK: - Helpers

        /// Awaits `condition`, sleeping between polls so queued main-actor `handleOutput`
        /// Tasks run. libghostty-vt writes are synchronous, so unlike the macOS core's
        /// tick-pumped harness no renderer tick is needed here.
        @MainActor private func waitAsync(
            timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertTrue(condition(), "waitAsync timed out", file: file, line: line)
        }

        /// Attaches a remote-viewer owner so the core includes screen state in exported
        /// payloads (the state policy gates screen frames on an attached local/remote
        /// owner). Returns the attached client.
        @MainActor @discardableResult private func attachRemoteOwner(to core: GhosttyEmbeddedSessionCore, id: String) throws -> TerminalClient {
            let client = TerminalClient(
                id: id, kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
                connectedAt: "2026-07-12T00:00:00Z")
            let response = core.handleControlRequest(TerminalControlRequest(command: "attach", client: client, attachmentMode: .owner))
            XCTAssertTrue(response.ok, "attaching a remote owner must succeed: \(response.message)")
            return client
        }

        /// Reconstructs the visible screen text from a self-contained full-frame export.
        @MainActor private func renderedScreenText(of core: GhosttyEmbeddedSessionCore) -> String? {
            guard let snapshot = core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.renderSnapshot else { return nil }
            return Self.screenText(of: snapshot)
        }

        private static func screenText(of snapshot: GhosttyTerminalSnapshot) -> String {
            guard snapshot.columns > 0, snapshot.rows > 0 else { return "" }
            var lines: [String] = []
            for row in 0..<snapshot.rows {
                var line = ""
                for column in 0..<snapshot.columns {
                    let index = row * snapshot.columns + column
                    let codepoint = index < snapshot.cells.count ? snapshot.cells[index].codepoint : 0
                    if codepoint == 0 {
                        line.append(" ")
                    } else if let scalar = Unicode.Scalar(codepoint) {
                        line.append(Character(scalar))
                    } else {
                        line.append(" ")
                    }
                }
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }

        private func occurrences(of needle: String, in haystack: String) -> Int {
            guard !needle.isEmpty else { return 0 }
            return haystack.components(separatedBy: needle).count - 1
        }

        private func nonEmptyTrimmedLines(_ text: String?) -> [String] {
            (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { line in
                String(line).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }.filter { !$0.isEmpty }
        }

        /// Drives the trusted (client-less) resize command so the recorded grid is a known
        /// non-default size the resume path must restore before replay.
        @MainActor private func resize(_ core: GhosttyEmbeddedSessionCore, columns: Int, rows: Int) {
            let response = core.handleControlRequest(TerminalControlRequest(command: "resize", columns: columns, rows: rows))
            XCTAssertTrue(response.ok, "resize must succeed: \(response.message)")
        }

        // MARK: - 1. Replay fidelity + live continuity

        @MainActor func testResumeReplaysTranscriptAndKeepsPTYLive() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let marker = "HANDOFF_MARKER_ALPHA"
            let configuration = makeConfiguration(
                sessionID: "handoff-replay-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
            let sourceCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            try sourceCore.startIfNeeded()
            resize(sourceCore, columns: 100, rows: 30)
            try await waitAsync { (try? String(contentsOfFile: paths.outputPath))?.contains(marker) == true }

            guard let record = try await sourceCore.quiesceForHandoff() else {
                return XCTFail("quiesce produced no handoff record for a live session")
            }
            XCTAssertEqual(record.columns, 100)
            XCTAssertEqual(record.rows, 30)
            XCTAssertEqual(
                occurrences(of: marker, in: try String(contentsOfFile: paths.outputPath)), 1, "transcript must hold the marker exactly once")
            sourceCore.terminate()

            let pty = try makeAdoptablePTY()
            let resumedCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            defer {
                // Close the slave FIRST so the adopted master's blocked read hits EOF, then
                // terminate: closing a PTY master out from under a still-blocked read hangs.
                tearDown(pty)
                resumedCore.terminate()
            }
            try await resumedCore.resumeFromHandoff(handoffRecord(from: record, adopting: pty))

            // Scrollback/screen rebuilt from the replayed output.log.
            try attachRemoteOwner(to: resumedCore, id: "remote-owner")
            try await waitAsync { self.renderedScreenText(of: resumedCore)?.contains(marker) == true }

            // PTY I/O is live through the adopted fd: bytes injected on the slave land in
            // output.log on the resumed core exactly once.
            let secondMarker = "HANDOFF_MARKER_BETA"
            XCTAssertGreaterThan(write(pty.slave, "\(secondMarker)\n", secondMarker.utf8.count + 1), 0)
            try await waitAsync { (try? String(contentsOfFile: paths.outputPath))?.contains(secondMarker) == true }

            let transcript = try String(contentsOfFile: paths.outputPath)
            XCTAssertEqual(occurrences(of: marker, in: transcript), 1, "replay must not re-append the original transcript to output.log")
            XCTAssertEqual(occurrences(of: secondMarker, in: transcript), 1, "post-handoff output must land in output.log exactly once")
        }

        // MARK: - 2. Reflow invariant (persisted grid before new output)

        @MainActor func testResumeRestoresPersistedGridBeforeNewOutput() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            // A line wider than the grid so its wrapping depends on the replay width.
            let wideLine = String(repeating: "A", count: 150) + "DONE"
            let configuration = makeConfiguration(
                sessionID: "handoff-reflow-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(wideLine)'; cat")
            let sourceCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            // Keep the source alive so its owner attachment persists into the resumed core:
            // terminate() detaches clients, and the render-state export needs an owner.
            defer { sourceCore.terminate() }
            try sourceCore.startIfNeeded()
            resize(sourceCore, columns: 100, rows: 30)
            try attachRemoteOwner(to: sourceCore, id: "remote-owner")
            try await waitAsync { self.renderedScreenText(of: sourceCore)?.contains("DONE") == true }
            let preHandoffLines = nonEmptyTrimmedLines(renderedScreenText(of: sourceCore))
            XCTAssertGreaterThanOrEqual(preHandoffLines.count, 2, "a 154-column line must wrap at grid width 100")

            guard let record = try await sourceCore.quiesceForHandoff() else { return XCTFail("quiesce produced no handoff record") }

            let pty = try makeAdoptablePTY()
            let resumedCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            defer {
                // Close the slave FIRST so the adopted master's blocked read hits EOF, then
                // terminate: closing a PTY master out from under a still-blocked read hangs.
                tearDown(pty)
                resumedCore.terminate()
            }
            try await resumedCore.resumeFromHandoff(handoffRecord(from: record, adopting: pty))

            // The grid is the persisted size BEFORE any new output arrives (the liveness
            // child is a silent sleep).
            let snapshot = try XCTUnwrap(resumedCore.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.renderSnapshot)
            XCTAssertEqual(snapshot.columns, 100)
            XCTAssertEqual(snapshot.rows, 30)

            let postHandoffLines = nonEmptyTrimmedLines(renderedScreenText(of: resumedCore))
            XCTAssertEqual(postHandoffLines, preHandoffLines, "the wide line must wrap identically after replay at the persisted width")
        }

        // MARK: - 3. Epoch + revision carry

        @MainActor func testResumeCarriesOwnerEpochAndAdvancesRevision() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let marker = "EPOCH_MARKER"
            let configuration = makeConfiguration(
                sessionID: "handoff-epoch-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
            let sourceCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            try sourceCore.startIfNeeded()
            let owner = try attachRemoteOwner(to: sourceCore, id: "remote-owner")
            XCTAssertGreaterThan(sourceCore.debugOwnerEpoch, 0, "attaching an owner must advance the owner epoch")
            try await waitAsync { self.renderedScreenText(of: sourceCore)?.contains(marker) == true }

            guard let record = try await sourceCore.quiesceForHandoff() else { return XCTFail("quiesce produced no handoff record") }
            XCTAssertEqual(record.ownerEpoch, sourceCore.debugOwnerEpoch, "the record must carry the live owner epoch")
            let recordedEpoch = record.ownerEpoch
            // Do NOT terminate the source core: terminate() detaches active clients, and this
            // test relies on the owner attachment persisting across the handoff (quiesce
            // never detaches). The quiesced source core is cleaned up when it deinits.
            defer { sourceCore.terminate() }

            let pty = try makeAdoptablePTY()
            let resumedCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            defer {
                // Close the slave FIRST so the adopted master's blocked read hits EOF, then
                // terminate: closing a PTY master out from under a still-blocked read hangs.
                tearDown(pty)
                resumedCore.terminate()
            }
            try await resumedCore.resumeFromHandoff(handoffRecord(from: record, adopting: pty))

            // The resumed core enforces the carried epoch: a stale epoch is rejected, the
            // current one is accepted (the owner attachment persisted across the handoff).
            let staleResponse = resumedCore.handleControlRequest(
                TerminalControlRequest(command: "send", text: "x\n", clientID: owner.id, ownerEpoch: recordedEpoch - 1))
            XCTAssertFalse(staleResponse.ok, "a stale owner epoch must be rejected")
            XCTAssertEqual(staleResponse.errorCode, .ownershipRejected)
            let currentResponse = resumedCore.handleControlRequest(
                TerminalControlRequest(command: "send", text: "x\n", clientID: owner.id, ownerEpoch: recordedEpoch))
            XCTAssertTrue(currentResponse.ok, "the current owner epoch must be accepted: \(currentResponse.message)")

            // The first post-resume payload advances past the recorded revision and is a
            // self-contained full render update (the replayed marker must be on screen for
            // a render frame to be produced).
            try await waitAsync { self.renderedScreenText(of: resumedCore)?.contains(marker) == true }
            let payload = try XCTUnwrap(resumedCore.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial))
            let resumedRevision = try XCTUnwrap(payload.screenStateRevision)
            XCTAssertGreaterThan(resumedRevision, record.screenStateRevision, "the resumed revision must be strictly greater than the recorded one")
            let update = try XCTUnwrap(payload.decodedRenderUpdate)
            XCTAssertEqual(update.kind, .full, "the first post-resume frame must be a full render update")
        }

        // MARK: - 4. Dead child yields no record

        @MainActor func testQuiesceReturnsNilWhenChildAlreadyExited() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let configuration = makeConfiguration(sessionID: "handoff-dead-\(UUID().uuidString)", command: "true")
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            defer { core.terminate() }
            try core.startIfNeeded()

            // Wait for the short-lived child to exit and drive the session-closed path
            // (which flips the session out of its started state).
            try await waitAsync { !core.isStarted }

            let record = try await core.quiesceForHandoff()
            XCTAssertNil(record, "a session whose child already exited must not produce a handoff record")
        }

        // MARK: - 5. Failed-exec rebind

        @MainActor func testResumeInPlaceAfterFailedExecRestoresOutputAndSockets() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let marker = "REBIND_MARKER"
            let configuration = makeConfiguration(
                sessionID: "handoff-rebind-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            defer { core.terminate() }
            try core.startIfNeeded()
            try attachRemoteOwner(to: core, id: "remote-owner")
            try await waitAsync { (try? String(contentsOfFile: paths.outputPath))?.contains(marker) == true }

            // Quiesce as if about to exec, then take the failed-exec fallback on the SAME core.
            guard let record = try await core.quiesceForHandoff() else { return XCTFail("quiesce produced no handoff record") }
            XCTAssertGreaterThan(record.childPID, 0)
            core.resumeInPlaceAfterFailedExec()

            // The state-stream socket answers again: a fresh subscriber gets an initial payload.
            let received = InitialPayloadCollector()
            let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in received.record(payload) }
            try client.start()
            defer { client.stop() }
            try await waitAsync { received.count > 0 }

            // Output flows again through the rebound (never rebuilt) session and lands in
            // output.log: `cat` echoes the sent line back through the still-live child.
            let afterMarker = "AFTER_REBIND"
            let sendResponse = core.handleControlRequest(TerminalControlRequest(command: "send", text: "\(afterMarker)\n"))
            XCTAssertTrue(sendResponse.ok, "post-rebind send must succeed: \(sendResponse.message)")
            try await waitAsync { (try? String(contentsOfFile: paths.outputPath))?.contains(afterMarker) == true }

            let transcript = try String(contentsOfFile: paths.outputPath)
            XCTAssertEqual(occurrences(of: marker, in: transcript), 1)
            XCTAssertEqual(occurrences(of: afterMarker, in: transcript), 1)
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
#endif
