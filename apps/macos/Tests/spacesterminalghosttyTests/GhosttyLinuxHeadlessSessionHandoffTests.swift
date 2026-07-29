#if os(Linux)
    import Dispatch
    import Foundation
    import Glibc
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Exercises the Linux headless core's exec-in-place handoff: `quiesceForHandoff()`
    /// on a live session and `resumeFromHandoff(_:)` / `resumeInPlaceAfterFailedExec()`
    /// on the staged image, including `recreateVTRenderer`'s replay of `output.log` at
    /// the persisted grid.
    ///
    /// The headless core runs on `TerminalEngineActor`, so the test body stays nonisolated and
    /// hops onto the engine for every core call: cores are created inside a
    /// `TerminalEngineActor.run` block, carried back out through a `Box`, and used only via
    /// `runSynchronously`/`run` bridges (or a direct `await` for the core's async handoff
    /// methods).
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
    /// and closing a PTY master out from under a blocked read hangs.
    ///
    /// Swift Testing (not XCTest) on purpose: the swift-testing runner executes tests from an
    /// async main, so async tests actually make progress on Linux. Under corelibs-xctest an
    /// async test deadlocks before its first line regardless of isolation — the test job is
    /// queued to run while XCTest's blocked main thread polls in a loop that never drains it.
    /// Test bodies stay nonisolated (not `@MainActor`) because the headless core is isolated
    /// to `TerminalEngineActor`, a distinct global actor from `MainActor`: a nonisolated body
    /// can legally bridge onto the engine with the synchronous `TerminalEngineActor.runSynchronously`,
    /// whereas the one-way rule forbids calling that bridge from the main actor. `.serialized`
    /// because each test mutates the process-wide SPACES_* environment and owns a real PTY child.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSessionHandoffTests {
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

        /// Carries an engine-isolated reference (created inside a `TerminalEngineActor.run` block) back out
        /// to the nonisolated test body; the value is only ever *used* on the engine actor via a later bridge.
        private final class Box<Value>: @unchecked Sendable {
            let value: Value
            init(_ value: Value) { self.value = value }
        }

        init() throws {
            originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
            originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            databaseRoot = root
            setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
            setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        }

        deinit {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: databaseRoot)
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
            #expect(openpty(&master, &slave, nil, nil, nil) == 0, "openpty failed")
            #expect(master >= 0)
            #expect(slave >= 0)

            // Spawn `/bin/sleep` itself rather than `sh -c "sleep 120"`: `tearDown` kills exactly the pid
            // reported here, and a shell layer would fork the real `sleep` (dash does not exec it), leaving
            // that grandchild running after the shell is killed. Redirect the child's stdio to /dev/null so
            // it never inherits the test runner's stdout/stderr: a surviving child holding SwiftPM's output
            // pipe blocks `swift test` on pipe EOF long after the test binary itself has exited.
            var childPID: pid_t = 0
            let path = "/bin/sleep"
            let arguments = ["sleep", "120"]
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            defer { for argument in argv where argument != nil { free(argument) } }
            var fileActions = posix_spawn_file_actions_t()
            #expect(posix_spawn_file_actions_init(&fileActions) == 0, "posix_spawn_file_actions_init failed")
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            #expect(posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0) == 0, "redirecting child stdin failed")
            #expect(posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0) == 0, "redirecting child stdout failed")
            #expect(posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0) == 0, "redirecting child stderr failed")
            #expect(posix_spawn(&childPID, path, &fileActions, nil, &argv, environ) == 0, "posix_spawn of the liveness child failed")

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

        private static func remoteOwnerClient(id: String) -> TerminalClient {
            TerminalClient(
                id: id, kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
                connectedAt: "2026-07-12T00:00:00Z")
        }

        // MARK: - Engine-isolated helpers (call from inside a run/runSynchronously bridge)

        /// Attaches a remote-viewer owner so the core includes screen state in exported
        /// payloads (the state policy gates screen frames on an attached local/remote owner).
        @TerminalEngineActor private static func attachRemoteOwner(to core: GhosttyEmbeddedSessionCore, client: TerminalClient) {
            let response = core.handleControlRequest(TerminalControlRequest(command: "attach", client: client, attachmentMode: .owner))
            #expect(response.ok, "attaching a remote owner must succeed: \(response.message)")
        }

        /// Drives the trusted (client-less) resize command so the recorded grid is a known
        /// non-default size the resume path must restore before replay.
        @TerminalEngineActor private static func resize(_ core: GhosttyEmbeddedSessionCore, columns: Int, rows: Int) {
            let response = core.handleControlRequest(TerminalControlRequest(command: "resize", columns: columns, rows: rows))
            #expect(response.ok, "resize must succeed: \(response.message)")
        }

        /// Reconstructs the visible screen text from a self-contained full-frame export.
        @TerminalEngineActor private static func renderedScreenText(of core: GhosttyEmbeddedSessionCore) -> String? {
            guard let snapshot = core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.renderSnapshot else { return nil }
            return screenText(of: snapshot)
        }

        // MARK: - Nonisolated helpers

        /// Nonisolated poller so its `Task.sleep` suspensions don't hold the engine's queue while the
        /// engine runs the queued `handleOutput` tasks the condition is waiting on. Each poll hops onto
        /// the engine synchronously to evaluate the (engine-isolated) condition. libghostty-vt writes are
        /// synchronous, so unlike the macOS harness no renderer tick is needed here.
        private func waitAsync(
            timeout: TimeInterval = 30, transcriptPath: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
            _ condition: @escaping @TerminalEngineActor () -> Bool
        ) async throws {
            let started = Date()
            let deadline = started.addingTimeInterval(timeout)
            while Date() < deadline {
                if TerminalEngineActor.runSynchronously({ condition() }) { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
            await GhosttyLinuxHeadlessHangDiagnostics.report(
                wait: "waitAsync at \(sourceLocation)", elapsed: Date().timeIntervalSince(started), timeout: timeout,
                transcriptPath: transcriptPath)
            #expect(TerminalEngineActor.runSynchronously { condition() }, "waitAsync timed out", sourceLocation: sourceLocation)
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

        // MARK: - Replay unit coverage (nonisolated statics)

        @Test func transcriptReplayUsesBoundedChunksWithoutLosingBytes() throws {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
            defer { try? FileManager.default.removeItem(atPath: path) }
            var expected = Data(repeating: 0xA5, count: GhosttyEmbeddedSessionCore.outputReplayChunkByteCount * 2)
            expected.append(Data(repeating: 0x5A, count: 137))
            try expected.write(to: URL(fileURLWithPath: path))

            var replayed = Data()
            var chunkSizes: [Int] = []
            let replayedOutput = try GhosttyEmbeddedSessionCore.replayOutputLog(at: path) { chunk in
                chunkSizes.append(chunk.count)
                replayed.append(chunk)
            }

            #expect(replayedOutput)
            #expect(chunkSizes.count > 2)
            #expect((chunkSizes.max() ?? 0) <= GhosttyEmbeddedSessionCore.outputReplayChunkByteCount)
            #expect(replayed == expected)
        }

        @Test func transcriptReplayCanStreamOnlyTheHandoffSuffix() throws {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let prefix = Data("already-rendered\n".utf8)
            let suffix = Data(repeating: 0x5A, count: GhosttyEmbeddedSessionCore.outputReplayChunkByteCount + 37)
            try (prefix + suffix).write(to: URL(fileURLWithPath: path))

            var replayed = Data()
            var chunkSizes: [Int] = []
            let replayedOutput = try GhosttyEmbeddedSessionCore.replayOutputLog(at: path, startingAt: UInt64(prefix.count)) { chunk in
                chunkSizes.append(chunk.count)
                replayed.append(chunk)
            }

            #expect(replayedOutput)
            #expect(replayed == suffix)
            #expect((chunkSizes.max() ?? 0) <= GhosttyEmbeddedSessionCore.outputReplayChunkByteCount)
        }

        @Test func outputDeliveryFenceWaitsForScheduledPersistence() {
            let fence = GhosttyLinuxHandoffOutputDeliveryFence()
            fence.beginDelivery()

            let completed = DispatchSemaphore(value: 0)
            Task {
                await fence.waitUntilDrained()
                completed.signal()
            }
            #expect(completed.wait(timeout: .now() + .milliseconds(50)) == .timedOut)

            fence.finishDelivery()
            #expect(completed.wait(timeout: .now() + .seconds(1)) == .success)
        }

        // MARK: - 1. Replay fidelity + live continuity

        @Test func resumeReplaysTranscriptAndKeepsPTYLive() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let marker = "HANDOFF_MARKER_ALPHA"
            let configuration = makeConfiguration(
                sessionID: "handoff-replay-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
            let sourceCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let sourceCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try sourceCore.startIfNeeded()
                Self.resize(sourceCore, columns: 100, rows: 30)
                return Box(sourceCore)
            }
            let sourceCore = sourceCoreBox.value
            try await waitAsync(transcriptPath: paths.outputPath) { (try? String(contentsOfFile: paths.outputPath))?.contains(marker) == true }

            guard let record = try await sourceCore.quiesceForHandoff() else {
                Issue.record("quiesce produced no handoff record for a live session")
                return
            }
            #expect(record.columns == 100)
            #expect(record.rows == 30)
            #expect(
                occurrences(of: marker, in: try String(contentsOfFile: paths.outputPath)) == 1, "transcript must hold the marker exactly once")
            TerminalEngineActor.runSynchronously { sourceCore.terminate() }

            let pty = try makeAdoptablePTY()
            let resumedCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
            }
            let resumedCore = resumedCoreBox.value
            defer {
                // Close the slave FIRST so the adopted master's blocked read hits EOF, then
                // terminate: closing a PTY master out from under a still-blocked read hangs.
                tearDown(pty)
                TerminalEngineActor.runSynchronously { resumedCore.terminate() }
            }
            try await resumedCore.resumeFromHandoff(handoffRecord(from: record, adopting: pty))

            // Scrollback/screen rebuilt from the replayed output.log.
            let owner = Self.remoteOwnerClient(id: "remote-owner")
            try await TerminalEngineActor.run { Self.attachRemoteOwner(to: resumedCore, client: owner) }
            try await waitAsync(transcriptPath: paths.outputPath) { Self.renderedScreenText(of: resumedCore)?.contains(marker) == true }

            // PTY I/O is live through the adopted fd: bytes injected on the slave land in
            // output.log on the resumed core exactly once.
            let secondMarker = "HANDOFF_MARKER_BETA"
            #expect(write(pty.slave, "\(secondMarker)\n", secondMarker.utf8.count + 1) > 0)
            try await waitAsync(transcriptPath: paths.outputPath) { (try? String(contentsOfFile: paths.outputPath))?.contains(secondMarker) == true }

            let transcript = try String(contentsOfFile: paths.outputPath)
            #expect(occurrences(of: marker, in: transcript) == 1, "replay must not re-append the original transcript to output.log")
            #expect(occurrences(of: secondMarker, in: transcript) == 1, "post-handoff output must land in output.log exactly once")
        }

        @Test func resumeDoesNotRestoreClearedScreenOrScrollback() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let clearedMarker = "HANDOFF_CLEARED_MARKER"
            let configuration = makeConfiguration(
                sessionID: "handoff-cleared-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(clearedMarker)'; cat")
            let sourceCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let sourceCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try sourceCore.startIfNeeded()
                return Box(sourceCore)
            }
            let sourceCore = sourceCoreBox.value
            try await waitAsync(transcriptPath: paths.outputPath) { (try? String(contentsOfFile: paths.outputPath))?.contains(clearedMarker) == true }
            let clearResponse = TerminalEngineActor.runSynchronously {
                sourceCore.handleControlRequest(TerminalControlRequest(command: "clearScreen"))
            }
            #expect(clearResponse.ok, "clear must succeed: \(clearResponse.message)")

            guard let record = try await sourceCore.quiesceForHandoff() else {
                Issue.record("quiesce produced no handoff record")
                return
            }
            TerminalEngineActor.runSynchronously { sourceCore.terminate() }

            let pty = try makeAdoptablePTY()
            let resumedCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
            }
            let resumedCore = resumedCoreBox.value
            defer {
                tearDown(pty)
                TerminalEngineActor.runSynchronously { resumedCore.terminate() }
            }
            try await resumedCore.resumeFromHandoff(handoffRecord(from: record, adopting: pty))
            let owner = Self.remoteOwnerClient(id: "remote-owner")
            try await TerminalEngineActor.run { Self.attachRemoteOwner(to: resumedCore, client: owner) }
            let screen = try #require(TerminalEngineActor.runSynchronously { Self.renderedScreenText(of: resumedCore) })
            #expect(!screen.contains(clearedMarker), "handoff replay must preserve the cleared screen and scrollback")
        }

        @Test func resumePreservesVTParserStateAcrossReplayChunkBoundary() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let staleMarker = "SHOULD_BE_CLEARED"
            let liveMarker = "BOUNDARY_REPLAY_MARKER"
            var transcript = Data(repeating: 0, count: GhosttyEmbeddedSessionCore.outputReplayChunkByteCount * 2 - staleMarker.utf8.count - 1)
            transcript.append(contentsOf: staleMarker.utf8)
            transcript.append(0x1B)
            transcript.append(contentsOf: "[2J\u{001B}[H\(liveMarker)\n".utf8)
            try transcript.write(to: URL(fileURLWithPath: paths.outputPath))

            let configuration = makeConfiguration(sessionID: "handoff-chunk-boundary-\(UUID().uuidString)", command: "cat")
            let pty = try makeAdoptablePTY()
            let resumedCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
            }
            let resumedCore = resumedCoreBox.value
            defer {
                tearDown(pty)
                TerminalEngineActor.runSynchronously { resumedCore.terminate() }
            }
            let record = DaemonHandoffSessionRecord(
                sessionID: configuration.sessionID, masterFD: pty.master, childPID: pty.childPID, columns: 80, rows: 24, ownerEpoch: 0,
                screenStateRevision: 0, appearance: ThemeAppearance.dark.rawValue)

            try await resumedCore.resumeFromHandoff(record)
            let owner = Self.remoteOwnerClient(id: "remote-owner")
            try await TerminalEngineActor.run { Self.attachRemoteOwner(to: resumedCore, client: owner) }
            let screen = try #require(TerminalEngineActor.runSynchronously { Self.renderedScreenText(of: resumedCore) })
            #expect(screen.contains(liveMarker), "output after the split escape sequence must render")
            #expect(!screen.contains(staleMarker), "the clear-screen sequence split across chunks must retain parser state")
        }

        // MARK: - 2. Reflow invariant (persisted grid before new output)

        @Test func resumeRestoresPersistedGridBeforeNewOutput() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            // A line wider than the grid so its wrapping depends on the replay width.
            let wideLine = String(repeating: "A", count: 150) + "DONE"
            let configuration = makeConfiguration(
                sessionID: "handoff-reflow-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(wideLine)'; cat")
            let owner = Self.remoteOwnerClient(id: "remote-owner")
            let sourceCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let sourceCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try sourceCore.startIfNeeded()
                Self.resize(sourceCore, columns: 100, rows: 30)
                Self.attachRemoteOwner(to: sourceCore, client: owner)
                return Box(sourceCore)
            }
            let sourceCore = sourceCoreBox.value
            // Keep the source alive so its owner attachment persists into the resumed core:
            // terminate() detaches clients, and the render-state export needs an owner.
            defer { TerminalEngineActor.runSynchronously { sourceCore.terminate() } }
            try await waitAsync(transcriptPath: paths.outputPath) { Self.renderedScreenText(of: sourceCore)?.contains("DONE") == true }
            let preHandoffLines = nonEmptyTrimmedLines(TerminalEngineActor.runSynchronously { Self.renderedScreenText(of: sourceCore) })
            #expect(preHandoffLines.count >= 2, "a 154-column line must wrap at grid width 100")

            guard let record = try await sourceCore.quiesceForHandoff() else {
                Issue.record("quiesce produced no handoff record")
                return
            }

            let pty = try makeAdoptablePTY()
            let resumedCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
            }
            let resumedCore = resumedCoreBox.value
            defer {
                // Close the slave FIRST so the adopted master's blocked read hits EOF, then
                // terminate: closing a PTY master out from under a still-blocked read hangs.
                tearDown(pty)
                TerminalEngineActor.runSynchronously { resumedCore.terminate() }
            }
            try await resumedCore.resumeFromHandoff(handoffRecord(from: record, adopting: pty))

            // The grid is the persisted size BEFORE any new output arrives (the liveness
            // child is a silent sleep).
            let snapshot = try #require(
                TerminalEngineActor.runSynchronously {
                    resumedCore.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.renderSnapshot
                })
            #expect(snapshot.columns == 100)
            #expect(snapshot.rows == 30)

            let postHandoffLines = nonEmptyTrimmedLines(TerminalEngineActor.runSynchronously { Self.renderedScreenText(of: resumedCore) })
            #expect(postHandoffLines == preHandoffLines, "the wide line must wrap identically after replay at the persisted width")
        }

        // MARK: - 3. Epoch + revision carry

        @Test func resumeCarriesOwnerEpochAndAdvancesRevision() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let marker = "EPOCH_MARKER"
            let configuration = makeConfiguration(
                sessionID: "handoff-epoch-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
            let owner = Self.remoteOwnerClient(id: "remote-owner")
            let sourceCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let sourceCore = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try sourceCore.startIfNeeded()
                Self.attachRemoteOwner(to: sourceCore, client: owner)
                #expect(sourceCore.debugOwnerEpoch > 0, "attaching an owner must advance the owner epoch")
                return Box(sourceCore)
            }
            let sourceCore = sourceCoreBox.value
            try await waitAsync(transcriptPath: paths.outputPath) { Self.renderedScreenText(of: sourceCore)?.contains(marker) == true }

            guard let record = try await sourceCore.quiesceForHandoff() else {
                Issue.record("quiesce produced no handoff record")
                return
            }
            #expect(
                record.ownerEpoch == TerminalEngineActor.runSynchronously { sourceCore.debugOwnerEpoch },
                "the record must carry the live owner epoch")
            let recordedEpoch = record.ownerEpoch
            // Do NOT terminate the source core here: terminate() detaches active clients, and
            // this test relies on the owner attachment persisting across the handoff (quiesce
            // never detaches). The quiesced source core is cleaned up when it deinits.
            defer { TerminalEngineActor.runSynchronously { sourceCore.terminate() } }

            let pty = try makeAdoptablePTY()
            let resumedCoreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
            }
            let resumedCore = resumedCoreBox.value
            defer {
                // Close the slave FIRST so the adopted master's blocked read hits EOF, then
                // terminate: closing a PTY master out from under a still-blocked read hangs.
                tearDown(pty)
                TerminalEngineActor.runSynchronously { resumedCore.terminate() }
            }
            try await resumedCore.resumeFromHandoff(handoffRecord(from: record, adopting: pty))

            // The resumed core enforces the carried epoch: a stale epoch is rejected, the
            // current one is accepted (the owner attachment persisted across the handoff).
            await TerminalEngineActor.run {
                let staleResponse = resumedCore.handleControlRequest(
                    TerminalControlRequest(command: "send", text: "x\n", clientID: owner.id, ownerEpoch: recordedEpoch - 1))
                #expect(!staleResponse.ok, "a stale owner epoch must be rejected")
                #expect(staleResponse.errorCode == .ownershipRejected)
                let currentResponse = resumedCore.handleControlRequest(
                    TerminalControlRequest(command: "send", text: "x\n", clientID: owner.id, ownerEpoch: recordedEpoch))
                #expect(currentResponse.ok, "the current owner epoch must be accepted: \(currentResponse.message)")
            }

            // The first post-resume payload advances past the recorded revision and is a
            // self-contained full render update (the replayed marker must be on screen for
            // a render frame to be produced).
            try await waitAsync(transcriptPath: paths.outputPath) { Self.renderedScreenText(of: resumedCore)?.contains(marker) == true }
            try await TerminalEngineActor.run {
                let payload = try #require(resumedCore.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial))
                let resumedRevision = try #require(payload.screenStateRevision)
                #expect(
                    resumedRevision > record.screenStateRevision, "the resumed revision must be strictly greater than the recorded one")
                let update = try #require(payload.decodedRenderUpdate)
                #expect(update.kind == .full, "the first post-resume frame must be a full render update")
            }
        }

        // MARK: - 4. Dead child yields no record

        @Test func quiesceReturnsNilWhenChildAlreadyExited() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let configuration = makeConfiguration(sessionID: "handoff-dead-\(UUID().uuidString)", command: "true")
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                return Box(core)
            }
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }

            // Wait for the short-lived child to exit and drive the session-closed path
            // (which flips the session out of its started state).
            try await waitAsync(transcriptPath: paths.outputPath) { !core.isStarted }

            let record = try await core.quiesceForHandoff()
            #expect(record == nil, "a session whose child already exited must not produce a handoff record")
        }

        // MARK: - 5. Failed-exec rebind

        @Test func resumeInPlaceAfterFailedExecRestoresOutputAndSockets() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let marker = "REBIND_MARKER"
            let configuration = makeConfiguration(
                sessionID: "handoff-rebind-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
            let owner = Self.remoteOwnerClient(id: "remote-owner")
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                Self.attachRemoteOwner(to: core, client: owner)
                return Box(core)
            }
            let core = coreBox.value
            defer { TerminalEngineActor.runSynchronously { core.terminate() } }
            try await waitAsync(transcriptPath: paths.outputPath) { (try? String(contentsOfFile: paths.outputPath))?.contains(marker) == true }

            // Quiesce as if about to exec, then take the failed-exec fallback on the SAME core.
            guard let record = try await core.quiesceForHandoff() else {
                Issue.record("quiesce produced no handoff record")
                return
            }
            #expect(record.childPID > 0)
            let duringHandoffMarker = "DURING_FAILED_HANDOFF"
            let duringHandoffResponse = TerminalEngineActor.runSynchronously {
                core.handleControlRequest(TerminalControlRequest(command: "send", text: "\(duringHandoffMarker)\n"))
            }
            #expect(duringHandoffResponse.ok, "handoff-window input must reach the live child")
            try await waitAsync(transcriptPath: paths.outputPath) {
                (try? String(contentsOfFile: paths.outputPath))?.contains(duringHandoffMarker) == true
            }
            #expect(
                TerminalEngineActor.runSynchronously { Self.renderedScreenText(of: core) }?.contains(duringHandoffMarker) != true,
                "quiesced output must bypass the renderer")

            await core.resumeInPlaceAfterFailedExec()
            try await waitAsync(transcriptPath: paths.outputPath) { Self.renderedScreenText(of: core)?.contains(duringHandoffMarker) == true }

            // The state-stream socket answers again: a fresh subscriber gets an initial payload.
            let received = InitialPayloadCollector()
            let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in received.record(payload) }
            try client.start()
            defer { client.stop() }
            try await waitAsync(transcriptPath: paths.outputPath) { received.count > 0 }

            // Output flows again through the rebound (never rebuilt) session and lands in
            // output.log: `cat` echoes the sent line back through the still-live child.
            let afterMarker = "AFTER_REBIND"
            let sendResponse = TerminalEngineActor.runSynchronously {
                core.handleControlRequest(TerminalControlRequest(command: "send", text: "\(afterMarker)\n"))
            }
            #expect(sendResponse.ok, "post-rebind send must succeed: \(sendResponse.message)")
            try await waitAsync(transcriptPath: paths.outputPath) { (try? String(contentsOfFile: paths.outputPath))?.contains(afterMarker) == true }

            let transcript = try String(contentsOfFile: paths.outputPath)
            #expect(occurrences(of: marker, in: transcript) == 1)
            #expect(occurrences(of: duringHandoffMarker, in: transcript) == 1)
            #expect(occurrences(of: afterMarker, in: transcript) == 1)
        }

        // MARK: - 6. Exit identity consistency

        /// The persisted runtime state and the broadcast/persisted final payload must carry one exit
        /// `runIdentity`. Ended-scrollback replay arms itself with the identity from the final state
        /// payload and the transcript endpoint reports the identity from the persisted runtime state,
        /// so a mismatch makes the client reject the ended run's transcript (scrollback unavailable).
        /// `runIdentity` embeds a sub-second exit timestamp, so stamping the exit twice would diverge.
        @Test func terminateStampsSingleExitIdentityForRuntimeStateAndFinalPayload() async throws {
            let paths = try makeTemporaryPaths()
            defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

            let marker = "EXIT_IDENTITY_MARKER"
            let configuration = makeConfiguration(
                sessionID: "exit-identity-\(UUID().uuidString)", command: "stty -echo; printf '%s\\n' '\(marker)'; cat")
            let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
                try core.startIfNeeded()
                return Box(core)
            }
            let core = coreBox.value
            try await waitAsync(transcriptPath: paths.outputPath) { (try? String(contentsOfFile: paths.outputPath))?.contains(marker) == true }

            TerminalEngineActor.runSynchronously { core.terminate() }
            // terminate() enqueues its exited-state write off the engine; block on the persistence
            // queue before reading the durable mirror or this read races the async commit.
            await core.drainPersistenceForShutdown()

            let persistedRuntimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            let finalPayload = try TerminalSessionPersistence.readRemoteSessionState(paths: paths)
            let payloadRuntimeState = try #require(finalPayload.runtimeState, "the terminated payload must embed a runtime state")

            #expect(persistedRuntimeState.state == .exited, "the persisted runtime state must be exited")
            #expect(payloadRuntimeState.state == .exited, "the final payload's runtime state must be exited")
            #expect(
                persistedRuntimeState.runIdentity == payloadRuntimeState.runIdentity,
                "the persisted runtime state and the final payload must share one exit identity so the client accepts the ended run's transcript")
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
