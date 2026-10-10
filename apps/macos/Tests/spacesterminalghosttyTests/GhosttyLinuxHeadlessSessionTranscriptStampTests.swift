#if os(Linux)
    import Foundation
    import Glibc
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Linux headless host stamps: every exported frame names the absolute row of its first history row,
    /// the terminal incarnation, and the transcript prefix (`output.log` bytes and inode) that reproduces
    /// its grid. `handleOutput` appends to the transcript and writes the vt renderer in one engine turn, so
    /// a frame's offset is the file length at capture time.
    ///
    /// Same engine-actor and `.serialized` constraints as `GhosttyLinuxHeadlessSessionTranscriptTrimTests`.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSessionTranscriptStampTests {
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

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

        /// A test-owned PTY plus a live child pid, standing in for the master fd and child that survive
        /// `execv` for the resuming core to adopt. The child is a bare `sleep` (spawned with `posix_spawn` so
        /// only the session driver ever reaps it) that keeps the resumed session's liveness checks satisfied.
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
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "trim", workingDirectory: FileManager.default.temporaryDirectory.path,
                shell: "/bin/sh", command: command, createdAt: "2026-07-20T00:00:00Z", workspaceID: "workspace-trim", kind: .shell)
        }

        private func makeAdoptablePTY() throws -> AdoptablePTY {
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
                wait: "waitAsync at \(sourceLocation)", elapsed: Date().timeIntervalSince(started), timeout: timeout, transcriptPath: transcriptPath)
            #expect(TerminalEngineActor.runSynchronously { condition() }, "waitAsync timed out", sourceLocation: sourceLocation)
        }

        private struct Harness {
            let core: GhosttyEmbeddedSessionCore
            let pty: AdoptablePTY
            let paths: TerminalSessionPaths
        }

        private func startResumedCore(prefill: Data = Data(), columns: Int = 80, rows: Int = 24) async throws -> (
            Box<GhosttyEmbeddedSessionCore>, AdoptablePTY, TerminalSessionPaths
        ) {
            let paths = try makeTemporaryPaths()
            if !prefill.isEmpty { try prefill.write(to: URL(fileURLWithPath: paths.outputPath)) }
            let configuration = makeConfiguration(sessionID: "stamp-\(UUID().uuidString)", command: "cat")
            let pty = try makeAdoptablePTY()
            let box = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                Box(GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths))
            }
            let record = DaemonHandoffSessionRecord(
                sessionID: configuration.sessionID, masterFD: pty.master, childPID: pty.childPID, columns: columns, rows: rows, ownerEpoch: 0,
                screenStateRevision: 0, appearance: ThemeAppearance.dark.rawValue, transcriptOffsetAtQuiesce: nil)
            try await box.value.resumeFromHandoff(record)
            try await TerminalEngineActor.run { Self.attachRemoteOwner(to: box.value, id: "remote-owner") }
            return (box, pty, paths)
        }

        private static func fileSize(_ path: String) -> UInt64 { (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0 }

        @TerminalEngineActor private static func frame(of core: GhosttyEmbeddedSessionCore) -> TranscriptFrame? {
            core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.stateChange)?.transcriptFrame
        }

        private func send(_ text: String, to pty: AdoptablePTY) {
            let bytes = Array(text.utf8)
            var written = 0
            while written < bytes.count {
                let count = bytes[written...].withUnsafeBytes { write(pty.slave, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                written += count
            }
            #expect(written == bytes.count, "the whole input must reach the PTY")
        }

        /// Sends `text`, waits until the host has appended and rendered it, and returns the frame.
        private func sendAndCapture(_ text: String, to harness: Harness, awaiting needle: String) async throws -> TranscriptFrame {
            send(text, to: harness.pty)
            try await waitAsync(transcriptPath: harness.paths.outputPath) {
                guard let frame = Self.frame(of: harness.core) else { return false }
                return TranscriptReplayVT.rowTexts(frame).contains { $0.contains(needle) }
            }
            return try #require(TerminalEngineActor.runSynchronously { Self.frame(of: harness.core) })
        }

        private func expectPrefixReproduces(_ frame: TranscriptFrame, at path: String) throws {
            let prefix = try #require(TranscriptReplayVT.prefix(ofFileAt: path, length: frame.transcriptByteOffset))
            #expect(
                TranscriptReplayVT.screenRows(columns: frame.columns, rows: frame.rows, bytes: prefix) == TranscriptReplayVT.rowTexts(frame),
                "the transcript prefix at the frame's offset must reproduce its grid")
        }

        /// Attaches a remote-viewer owner so the core includes screen state in exported payloads (the state
        /// policy gates screen frames on an attached local/remote owner).
        @TerminalEngineActor private static func attachRemoteOwner(to core: GhosttyEmbeddedSessionCore, id: String) {
            let client = TerminalClient(
                id: id, kind: .remote, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"), connectedAt: "2026-07-20T00:00:00Z")
            let response = core.handleControlRequest(TerminalControlRequest(command: "attach", client: client, attachmentMode: .owner))
            #expect(response.ok, "attaching a remote owner must succeed: \(response.message)")
        }

        /// Reconstructs the visible screen text from a self-contained full-frame export.
        @TerminalEngineActor private static func renderedScreenText(of core: GhosttyEmbeddedSessionCore) -> String? {
            guard let snapshot = core.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.initial)?.renderSnapshot else { return nil }
            return screenText(of: snapshot)
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

        // MARK: - Tests

        /// A flood that scrolls well past the screen: each frame's offset is the file length and replays to
        /// its grid, its row base maps visible marker rows to their absolute line numbers, and the epoch
        /// stays constant under plain output.
        @Test func floodFramesNameTheirAbsoluteRowsAndTranscriptPrefixes() async throws {
            let (box, pty, paths) = try await startResumedCore()
            defer {
                tearDown(pty)
                TerminalEngineActor.runSynchronously { box.value.terminate() }
                try? FileManager.default.removeItem(atPath: paths.rootDirectory)
            }
            let harness = Harness(core: box.value, pty: pty, paths: paths)
            let identity = try #require(TranscriptReplayVT.fileIdentity(ofFileAt: paths.outputPath))

            var epoch: UInt64?
            var number = 0
            for _ in 0..<40 {
                var chunk = ""
                for _ in 0..<50 {
                    chunk += TranscriptReplayVT.marker(number) + "\n"
                    number += 1
                }
                let frame = try await sendAndCapture(chunk, to: harness, awaiting: TranscriptReplayVT.marker(number - 1))
                #expect(frame.transcriptFileIdentity == identity)
                #expect(frame.transcriptByteOffset == Self.fileSize(paths.outputPath), "the host appends and renders in one turn")
                if let epoch { #expect(frame.historyEpoch == epoch, "plain output never renumbers rows") }
                epoch = frame.historyEpoch
                for (row, text) in TranscriptReplayVT.rowTexts(frame).enumerated() {
                    guard let markerNumber = TranscriptReplayVT.markerNumber(text) else { continue }
                    #expect(
                        UInt64(markerNumber) == frame.historyRowBase + UInt64(row),
                        "row \(row) shows marker \(markerNumber) at base \(frame.historyRowBase)")
                }
                try expectPrefixReproduces(frame, at: paths.outputPath)
            }
            let final = try #require(TerminalEngineActor.runSynchronously { Self.frame(of: harness.core) })
            #expect(final.historyRowBase > 0, "2000 lines in 24 rows must have scrolled history")
        }

        /// The clear control request appends its marker to the transcript and clears the vt in the same
        /// turn, so the frame offset still equals the file length and its prefix still reproduces the grid.
        @Test func clearScreenKeepsOffsetEqualToFileLength() async throws {
            let (box, pty, paths) = try await startResumedCore()
            defer {
                tearDown(pty)
                TerminalEngineActor.runSynchronously { box.value.terminate() }
                try? FileManager.default.removeItem(atPath: paths.rootDirectory)
            }
            let harness = Harness(core: box.value, pty: pty, paths: paths)
            _ = try await sendAndCapture("before clear\n", to: harness, awaiting: "before clear")
            let response = TerminalEngineActor.runSynchronously { box.value.handleControlRequest(TerminalControlRequest(command: "clearScreen")) }
            #expect(response.ok)
            let frame = try await sendAndCapture("after clear\n", to: harness, awaiting: "after clear")
            #expect(frame.transcriptByteOffset == Self.fileSize(paths.outputPath))
            #expect(!TranscriptReplayVT.rowTexts(frame).contains { $0.contains("before clear") })
            try expectPrefixReproduces(frame, at: paths.outputPath)
        }

        /// Puts the test's end of the PTY in raw, non-blocking mode so what the host writes to the session
        /// (its input) can be read back without echo or line editing.
        private func prepareToReadHostInput(from pty: AdoptablePTY) {
            var attributes = termios()
            #expect(tcgetattr(pty.slave, &attributes) == 0)
            attributes.c_lflag &= ~tcflag_t(ECHO | ICANON)
            #expect(tcsetattr(pty.slave, TCSANOW, &attributes) == 0)
            #expect(fcntl(pty.slave, F_SETFL, fcntl(pty.slave, F_GETFL) | O_NONBLOCK) != -1)
        }

        /// The bytes the host has written to the session so far, waiting up to `timeout` for the first.
        private func readHostInput(from pty: AdoptablePTY, timeout: TimeInterval) async -> [UInt8] {
            var collected: [UInt8] = []
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                var buffer = [UInt8](repeating: 0, count: 64)
                let count = read(pty.slave, &buffer, buffer.count)
                if count > 0 {
                    collected += buffer[..<count]
                } else if !collected.isEmpty {
                    break
                } else {
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
            return collected
        }

        /// Ghostty's rule away from a shell-integration prompt mark: scrollback goes, the rows above the cursor
        /// go, and the prompt row moves to the top with the cursor still after the prompt. No form feed is
        /// sent. The transcript replays to the live screen, so a client copying the command it just ran gets
        /// the row the screen shows.
        @Test func clearAtAnUnmarkedPromptKeepsThePromptRowAndReplaysToTheLiveScreen() async throws {
            let (box, pty, paths) = try await startResumedCore()
            defer {
                tearDown(pty)
                TerminalEngineActor.runSynchronously { box.value.terminate() }
                try? FileManager.default.removeItem(atPath: paths.rootDirectory)
            }
            prepareToReadHostInput(from: pty)
            let harness = Harness(core: box.value, pty: pty, paths: paths)
            _ = try await sendAndCapture("first line\nsecond line\n~ % ", to: harness, awaiting: "~ %")
            let response = TerminalEngineActor.runSynchronously { box.value.handleControlRequest(TerminalControlRequest(command: "clearScreen")) }
            #expect(response.ok, "\(response.message)")
            let frame = try await sendAndCapture("ls\n", to: harness, awaiting: "ls")
            #expect(TranscriptReplayVT.rowTexts(frame).first == "~ % ls", "the prompt row moves to the top with the command after it")
            #expect(!TranscriptReplayVT.rowTexts(frame).contains { $0.contains("first line") || $0.contains("second line") })
            try expectPrefixReproduces(frame, at: paths.outputPath)
            #expect(await readHostInput(from: pty, timeout: 0.3).isEmpty, "away from a marked prompt no form feed is sent")
        }

        /// At a prompt the shell marked with OSC 133, Ghostty erases the screen and asks the shell to repaint
        /// with a form feed. The repaint is ordinary output, so it reaches the transcript like any other.
        @Test func clearAtAMarkedPromptEmptiesTheScreenAndAsksTheShellToRepaint() async throws {
            let (box, pty, paths) = try await startResumedCore()
            defer {
                tearDown(pty)
                TerminalEngineActor.runSynchronously { box.value.terminate() }
                try? FileManager.default.removeItem(atPath: paths.rootDirectory)
            }
            prepareToReadHostInput(from: pty)
            let harness = Harness(core: box.value, pty: pty, paths: paths)
            let prompt = "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}"
            _ = try await sendAndCapture("old output\n" + prompt, to: harness, awaiting: "$")
            let response = TerminalEngineActor.runSynchronously { box.value.handleControlRequest(TerminalControlRequest(command: "clearScreen")) }
            #expect(response.ok, "\(response.message)")
            #expect(await readHostInput(from: pty, timeout: 10) == [0x0C], "the shell is asked to repaint with a form feed")
            let cleared = try #require(TerminalEngineActor.runSynchronously { Self.frame(of: box.value) })
            #expect(!TranscriptReplayVT.rowTexts(cleared).contains { $0.contains("old output") })
            try expectPrefixReproduces(cleared, at: paths.outputPath)

            let repainted = try await sendAndCapture("\r" + prompt + "pwd\n", to: harness, awaiting: "pwd")
            #expect(!TranscriptReplayVT.rowTexts(repainted).contains { $0.contains("old output") })
            try expectPrefixReproduces(repainted, at: paths.outputPath)
        }

        /// The alternate screen belongs to the running program: the clear does nothing and writes nothing.
        @Test func clearOnTheAlternateScreenChangesNothing() async throws {
            let (box, pty, paths) = try await startResumedCore()
            defer {
                tearDown(pty)
                TerminalEngineActor.runSynchronously { box.value.terminate() }
                try? FileManager.default.removeItem(atPath: paths.rootDirectory)
            }
            prepareToReadHostInput(from: pty)
            let harness = Harness(core: box.value, pty: pty, paths: paths)
            _ = try await sendAndCapture("\u{1B}[?1049hfull screen app", to: harness, awaiting: "full screen app")
            let sizeBefore = Self.fileSize(paths.outputPath)
            let response = TerminalEngineActor.runSynchronously { box.value.handleControlRequest(TerminalControlRequest(command: "clearScreen")) }
            #expect(!response.ok)
            #expect(Self.fileSize(paths.outputPath) == sizeBefore, "nothing is recorded")
            let frame = try #require(TerminalEngineActor.runSynchronously { Self.frame(of: box.value) })
            #expect(TranscriptReplayVT.rowTexts(frame).contains { $0.contains("full screen app") })
            #expect(await readHostInput(from: pty, timeout: 0.3).isEmpty)
        }

        /// Renumbering events (ED3, RIS, alternate-screen enter and exit, a column resize) change the epoch;
        /// a rows-only resize does not.
        @Test func epochChangesOnRenumberingEventsAndNotOnARowsOnlyResize() async throws {
            let (box, pty, paths) = try await startResumedCore()
            defer {
                tearDown(pty)
                TerminalEngineActor.runSynchronously { box.value.terminate() }
                try? FileManager.default.removeItem(atPath: paths.rootDirectory)
            }
            let harness = Harness(core: box.value, pty: pty, paths: paths)
            var current = try await sendAndCapture("e0\n", to: harness, awaiting: "e0").historyEpoch

            func expectEpoch(afterSending text: String, marker: String, changes: Bool, _ what: String) async throws {
                let frame = try await sendAndCapture(text + marker + "\n", to: harness, awaiting: marker)
                if changes {
                    #expect(frame.historyEpoch != current, "\(what) must change the epoch")
                } else {
                    #expect(frame.historyEpoch == current, "\(what) must not change the epoch")
                }
                current = frame.historyEpoch
            }
            try await expectEpoch(afterSending: "\u{1b}[3J", marker: "e1", changes: true, "ED3")
            try await expectEpoch(afterSending: "\u{1b}c", marker: "e2", changes: true, "RIS")
            try await expectEpoch(afterSending: "\u{1b}[?1049h", marker: "e3", changes: true, "entering the alternate screen")
            try await expectEpoch(afterSending: "\u{1b}[?1049l", marker: "e4", changes: true, "leaving the alternate screen")

            let rowsOnly = TerminalEngineActor.runSynchronously { Self.resize(box.value, columns: 80, rows: 30) }
            #expect(rowsOnly.ok, "\(rowsOnly.message)")
            try await expectEpoch(afterSending: "", marker: "e5", changes: false, "a rows-only resize")
            let wider = TerminalEngineActor.runSynchronously { Self.resize(box.value, columns: 100, rows: 30) }
            #expect(wider.ok, "\(wider.message)")
            try await expectEpoch(afterSending: "", marker: "e6", changes: true, "a column resize")
        }

        /// A transcript over the live trim trigger is head-trimmed on the next append: the identity changes
        /// to the trimmed file's inode and the offset stays equal to its length.
        @Test func headTrimKeepsOffsetAndIdentityConsistent() async throws {
            // Newline-terminated lines past the trim trigger: the trim cuts only at a parser-safe boundary,
            // so one unbroken run of bytes would defer it until a newline entered the scan window.
            let line = Data(repeating: UInt8(ascii: "A"), count: 99) + Data("\n".utf8)
            var transcript = Data(capacity: TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes + 2 * line.count)
            while transcript.count <= TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes { transcript.append(line) }
            transcript.append(contentsOf: "PREFILL_END\n".utf8)
            let (box, pty, paths) = try await startResumedCore(prefill: transcript)
            defer {
                tearDown(pty)
                TerminalEngineActor.runSynchronously { box.value.terminate() }
                try? FileManager.default.removeItem(atPath: paths.rootDirectory)
            }
            let harness = Harness(core: box.value, pty: pty, paths: paths)
            _ = try await sendAndCapture("after trim\n", to: harness, awaiting: "after trim")
            try await waitAsync(transcriptPath: paths.outputPath) {
                Self.fileSize(paths.outputPath) < UInt64(TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes)
            }
            let settled = try await sendAndCapture("settled\n", to: harness, awaiting: "settled")
            #expect(settled.transcriptFileIdentity == TranscriptReplayVT.fileIdentity(ofFileAt: paths.outputPath))
            #expect(settled.transcriptByteOffset == Self.fileSize(paths.outputPath))
            try expectPrefixReproduces(settled, at: paths.outputPath)
        }

        private static func resize(_ core: GhosttyEmbeddedSessionCore, columns: Int, rows: Int) -> TerminalControlResponse {
            core.handleControlRequest(TerminalControlRequest(command: "resize", columns: columns, rows: rows))
        }
    }
#endif
