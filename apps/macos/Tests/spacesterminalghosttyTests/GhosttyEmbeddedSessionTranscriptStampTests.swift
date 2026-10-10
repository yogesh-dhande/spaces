import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The history stamps the macOS host puts on every frame, driven through a real GhosttyKit session:
/// `historyRowBase` names the absolute row of viewport row 0, `historyEpoch` changes exactly when absolute
/// rows are renumbered, and `transcriptByteOffset` / `transcriptFileIdentity` name the `output.log` prefix
/// that reproduces the frame's grid.
final class GhosttyEmbeddedSessionTranscriptStampTests: XCTestCase {
    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var databaseRoot: URL?

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

    // MARK: - Fixtures

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

    private static func makeConfiguration(command: String) -> TerminalSessionLaunchConfiguration {
        TerminalSessionLaunchConfiguration(
            sessionID: "transcript-stamp-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "stamp",
            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: command, createdAt: "2026-10-08T00:00:00Z",
            workspaceID: "workspace-stamp", kind: .shell)
    }

    private func startCore(command: String, paths: TerminalSessionPaths) async throws -> GhosttyEmbeddedSessionCore {
        let configuration = Self.makeConfiguration(command: command)
        let box = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: configuration, paths: paths)
            try core.startIfNeeded()
            // Screen frames are only exported for a session some client owns.
            let client = TerminalClient(
                id: "stamp-owner", kind: .remote, identity: TerminalClientIdentity(label: "iPhone", deviceName: "iPhone"),
                connectedAt: "2026-10-08T00:00:00Z")
            let attached = core.handleControlRequest(TerminalControlRequest(command: "attach", client: client, attachmentMode: .owner))
            XCTAssertTrue(attached.ok, attached.message)
            return Box(core)
        }
        return box.value
    }

    /// The frame the daemon would export right now, with its history stamps.
    @TerminalEngineActor private static func frame(of core: GhosttyEmbeddedSessionCore) -> TranscriptFrame? {
        core.currentRemoteStatePayload(reason: .stateChange)?.transcriptFrame
    }

    @TerminalEngineActor private static func host(of core: GhosttyEmbeddedSessionCore) -> GhosttyHeadlessRendererHost {
        core.rendererHost as! GhosttyHeadlessRendererHost
    }

    /// Writes `text` to the session's PTY; the `cat` the session runs prints it back, which to the
    /// terminal is indistinguishable from the program writing it.
    private func sendThroughCat(_ text: String, to core: GhosttyEmbeddedSessionCore) {
        let sent = TerminalEngineActor.runSynchronously { Self.host(of: core).sendRawBytes(Data(text.utf8)) }
        XCTAssertTrue(sent)
    }

    /// Polls a frame until `condition` holds, ticking Ghostty between polls, and returns that frame.
    private func waitForFrame(
        of core: GhosttyEmbeddedSessionCore, timeout: TimeInterval = 60, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @escaping @Sendable (TranscriptFrame) -> Bool
    ) async throws -> TranscriptFrame {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = TerminalEngineActor.runSynchronously { () -> TranscriptFrame? in
                GhosttyEmbeddedAppService.shared.tick()
                guard let frame = Self.frame(of: core), condition(frame) else { return nil }
                return frame
            }
            if let found { return found }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Timed out waiting for a matching frame.", file: file, line: line)
        throw NSError(domain: "GhosttyEmbeddedSessionTranscriptStampTests", code: 1)
    }

    /// Clears the session the way Cmd+K does and returns once `text` is gone from its screen. Ghostty
    /// applies the clear on its IO thread after the call returns, and output sent before it lands would be
    /// wiped with the screen, so a test waits here before sending more.
    private func clearScreen(of core: GhosttyEmbeddedSessionCore, removing text: String) async throws {
        XCTAssertTrue(TerminalEngineActor.runSynchronously { Self.host(of: core).clearScreenAndScrollback() })
        let deadline = Date().addingTimeInterval(30)
        while let screen = TerminalEngineActor.runSynchronously({ () -> String? in
            GhosttyEmbeddedAppService.shared.tick()
            let screen = core.rendererHost.snapshotText() ?? ""
            return screen.contains(text) ? screen : nil
        }) {
            guard Date() < deadline else {
                XCTFail("the clear never took effect; the screen still reads:\n\(screen)")
                throw NSError(domain: "GhosttyEmbeddedSessionTranscriptStampTests", code: 2)
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    /// The colors a pane's replay is built with; nothing here reads them.
    private static let replayTheme = GhosttyThemeExport(
        background: ThemeColor(0, 0, 0), foreground: ThemeColor(255, 255, 255), cursorColor: ThemeColor(200, 200, 200),
        cursorText: ThemeColor(0, 0, 0), selectionBackground: ThemeColor(50, 50, 50), selectionForeground: ThemeColor(255, 255, 255),
        palette: (0..<16).map { ThemeColor($0 * 8, $0 * 8, $0 * 8) })

    private func terminate(_ core: GhosttyEmbeddedSessionCore) { TerminalEngineActor.runSynchronously { core.terminate() } }

    // MARK: - Absolute rows and transcript offsets under a flood

    /// A numbered flood far past the scrollback limit. Line k is written as the k-th line, so it lands on
    /// absolute row k and occupies bytes `[42k, 42k + 42)` of `output.log`. Every frame captured while the
    /// flood runs must therefore agree with itself three ways: the text on viewport row 0 is the line whose
    /// number is `historyRowBase`, the transcript offset (which fixes how many lines the parser has seen)
    /// predicts the same base and the partial last line, and the epoch never moves, since pruning does not
    /// renumber rows. Once the flood ends, replaying the file up to the final frame's offset reproduces
    /// that frame's grid.
    func testFloodFramesNameTheirAbsoluteRowsAndTranscriptPrefixes() async throws {
        try Self.requireGhosttyAvailable()
        let paths = try Self.makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

        let totalLines = 80_000
        let awk =
            "BEGIN{pad=\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"; for(i=0;i<\(totalLines);i++){h=sprintf(\"marker-%06d-\",i); print h substr(pad,1,40-length(h))}}"
        let core = try await startCore(command: "stty -echo; awk '\(awk)'; cat", paths: paths)
        defer { terminate(core) }

        let wireWidth = TranscriptReplayVT.wireWidth
        var framesChecked = 0
        var sawPruning = false
        // The first frames can straddle the session's startup resize, which legitimately renumbers rows;
        // the epoch is held to a single value from the first frame well past it and short of any pruning.
        var epoch: UInt64?
        var finalFrame: TranscriptFrame?
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, finalFrame == nil {
            guard let frame = TerminalEngineActor.runSynchronously({ Self.frame(of: core) }) else {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            let rows = TranscriptReplayVT.rowTexts(frame)
            if Int(frame.transcriptByteOffset) >= 2_000 * wireWidth {
                if let epoch { XCTAssertEqual(frame.historyEpoch, epoch, "pruning must not change the epoch") }
                epoch = epoch ?? frame.historyEpoch
            }
            if frame.historyRowBase > UInt64(frame.scrollbarOffset) { sawPruning = true }

            // Row 0 and every complete marker row below it name their own absolute row.
            for (y, text) in rows.enumerated() {
                guard let number = TranscriptReplayVT.markerNumber(text) else { continue }
                XCTAssertEqual(UInt64(number), frame.historyRowBase + UInt64(y), "row \(y) of a frame at base \(frame.historyRowBase)")
            }

            // The offset fixes the parser's position: n whole lines and a partial line n on the bottom row.
            let consumed = Int(frame.transcriptByteOffset)
            let completeLines = consumed / wireWidth
            if completeLines >= frame.rows {
                let partial = min(consumed % wireWidth, TranscriptReplayVT.markerWidth)
                let expectedBottom = String(TranscriptReplayVT.marker(completeLines).prefix(partial)).replacingOccurrences(
                    of: "\\s+$", with: "", options: .regularExpression)
                XCTAssertEqual(rows.last, expectedBottom, "bottom row at offset \(consumed)")
                XCTAssertEqual(frame.historyRowBase, UInt64(completeLines - (frame.rows - 1)), "base at offset \(consumed)")
                framesChecked += 1
            }
            if consumed >= totalLines * wireWidth { finalFrame = frame }
        }
        let final = try XCTUnwrap(finalFrame, "the flood did not finish")
        XCTAssertGreaterThan(framesChecked, 10)
        XCTAssertTrue(sawPruning, "the flood must overrun the scrollback limit so rows are pruned")
        XCTAssertEqual(final.transcriptFileIdentity, TranscriptReplayVT.fileIdentity(ofFileAt: paths.outputPath))

        let transcript = try await waitForTranscriptPrefix(at: paths.outputPath, length: final.transcriptByteOffset)
        XCTAssertEqual(
            TranscriptReplayVT.screenRows(columns: final.columns, rows: final.rows, bytes: transcript), TranscriptReplayVT.rowTexts(final),
            "replaying the transcript to the frame's offset must reproduce the frame's grid")
    }

    /// A clear reaches `output.log` and the parser as the same escape bytes, so the frame offset needs no
    /// correction for it and the prefix it names still reproduces the grid.
    func testTranscriptOffsetStaysAlignedThroughAClear() async throws {
        try Self.requireGhosttyAvailable()
        let paths = try Self.makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

        // `ready` prints only once `stty -echo` has run. Input sent before that is echoed by the tty as well
        // as by `cat`, and a clear landing between the two copies leaves the second one on screen.
        let core = try await startCore(command: "stty -echo; echo ready; cat", paths: paths)
        defer { terminate(core) }
        _ = try await waitForFrame(of: core) { TranscriptReplayVT.rowTexts($0).contains("ready") }

        sendThroughCat("before clear\n", to: core)
        _ = try await waitForFrame(of: core) { TranscriptReplayVT.rowTexts($0).contains("before clear") }
        try await clearScreen(of: core, removing: "before clear")
        sendThroughCat("after clear\n", to: core)
        let frame = try await waitForFrame(of: core) { TranscriptReplayVT.rowTexts($0).contains("after clear") }

        let transcript = try await waitForTranscriptPrefix(at: paths.outputPath, length: frame.transcriptByteOffset)
        XCTAssertEqual(TranscriptReplayVT.screenRows(columns: frame.columns, rows: frame.rows, bytes: transcript), TranscriptReplayVT.rowTexts(frame))
    }

    /// Cmd+K at a prompt the shell marked with OSC 133: Ghostty erases the screen and writes a form feed
    /// to the shell so it repaints. The form feed reaches the session (`cat` echoes it into the
    /// transcript), and the transcript replays to the live screen.
    func testAClearAtAMarkedPromptEmptiesTheScreenAndSendsAFormFeed() async throws {
        try Self.requireGhosttyAvailable()
        let paths = try Self.makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

        let core = try await startCore(
            command: "stty -echo; printf 'first line\\nsecond line\\n\\033]133;A\\007$ \\033]133;B\\007'; cat", paths: paths)
        defer { terminate(core) }
        _ = try await waitForFrame(of: core) { TranscriptReplayVT.rowTexts($0).contains("$") }

        try await clearScreen(of: core, removing: "first line")
        // `cat` hands back what the host wrote to the session once the line is complete.
        sendThroughCat("ls\n", to: core)
        let frame = try await waitForFrame(of: core) { frame in TranscriptReplayVT.rowTexts(frame).contains { $0.hasSuffix("ls") } }
        let transcript = try await waitForTranscriptPrefix(at: paths.outputPath, length: frame.transcriptByteOffset)

        XCTAssertTrue(transcript.contains(0x0C), "the host asks the shell to repaint with a form feed")
        XCTAssertFalse(TranscriptReplayVT.rowTexts(frame).contains { $0.contains("first line") || $0.contains("second line") })
        XCTAssertEqual(
            TranscriptReplayVT.screenRows(columns: frame.columns, rows: frame.rows, bytes: transcript), TranscriptReplayVT.rowTexts(frame),
            "replaying the transcript to the frame's offset must show the screen the clear left")
    }

    /// Cmd+K at a shell prompt with no OSC 133 marks (the shell has no integration, or it is a shell the
    /// integration does not cover), with output above the cursor and the prompt to its left. A pane copies
    /// and scrolls from its own replay of `output.log`, so whatever the clear leaves on screen the replay
    /// has to show too: replaying the file to the frame's offset reproduces the frame's grid, and copying
    /// the row the command was typed on gives the text the screen shows, prompt included.
    func testAClearAtAnUnmarkedPromptLeavesTheReplayShowingTheLiveScreen() async throws {
        try Self.requireGhosttyAvailable()
        let paths = try Self.makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

        // Two lines of output, then a prompt with the cursor after it, as a shell leaves a session waiting
        // for input.
        let core = try await startCore(command: "stty -echo; printf 'first line\\nsecond line\\n~ %% '; cat", paths: paths)
        defer { terminate(core) }
        _ = try await waitForFrame(of: core) { TranscriptReplayVT.rowTexts($0).contains("~ %") }

        try await clearScreen(of: core, removing: "first line")
        // The command typed at the prompt: `cat` prints it at the cursor, where a shell would echo it.
        sendThroughCat("ls\n", to: core)
        let frame = try await waitForFrame(of: core) { frame in TranscriptReplayVT.rowTexts(frame).contains { $0.hasSuffix("ls") } }
        let screen = TranscriptReplayVT.rowTexts(frame)
        let transcript = try await waitForTranscriptPrefix(at: paths.outputPath, length: frame.transcriptByteOffset)

        XCTAssertEqual(
            TranscriptReplayVT.screenRows(columns: frame.columns, rows: frame.rows, bytes: transcript), screen,
            "replaying the transcript to the frame's offset must show the screen the clear left")

        // Copy reads a selection over the command's row from a replay lined up with the host at this frame.
        let commandRow = try XCTUnwrap(screen.firstIndex { $0.hasSuffix("ls") })
        let stamp = try XCTUnwrap(TerminalLiveFrameStamp(frame: frame.frame))
        let replay = try XCTUnwrap(
            TerminalLocalScrollbackModel(
                columns: frame.columns, rows: frame.rows, theme: Self.replayTheme, appearance: .dark, transcript: transcript,
                transcriptStartByteOffset: 0, transcriptEndByteOffset: frame.transcriptByteOffset, requestedByteCount: transcript.count,
                transcriptFileIdentity: frame.transcriptFileIdentity, runIdentity: nil, stamps: [stamp]))
        let row = Int64(clamping: frame.historyRowBase) + Int64(commandRow)
        let selection = TerminalAbsoluteSelection(
            from: TerminalAbsoluteCell(column: 0, row: row), to: TerminalAbsoluteCell(column: frame.columns - 1, row: row), isRectangle: false,
            historyEpoch: frame.historyEpoch)
        XCTAssertEqual(replay.text(for: selection), screen[commandRow], "copying the command's row must give the text the screen shows")
    }

    /// A head trim swaps `output.log` for a preamble plus the retained tail: every offset renumbers and the
    /// file identity changes. A frame captured after the swap must name the new file and an offset in its
    /// coordinates, so replaying that file to the offset still reproduces the grid.
    func testTranscriptOffsetAndIdentityFollowAHeadTrim() async throws {
        try Self.requireGhosttyAvailable()
        let paths = try Self.makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

        // More than `liveTranscriptTrimTriggerBytes` (30 MB) of numbered lines, so the trim fires mid-flood.
        let totalLines = 760_000
        XCTAssertGreaterThan(totalLines * TranscriptReplayVT.wireWidth, TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes)
        let awk =
            "BEGIN{pad=\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"; for(i=0;i<\(totalLines);i++){h=sprintf(\"marker-%06d-\",i); print h substr(pad,1,40-length(h))}}"
        let core = try await startCore(command: "stty -echo; awk '\(awk)'; cat", paths: paths)
        defer { terminate(core) }
        let untrimmedIdentity = try XCTUnwrap(TranscriptReplayVT.fileIdentity(ofFileAt: paths.outputPath))

        let frame = try await waitForFrame(of: core, timeout: 240) {
            $0.historyRowBase + UInt64($0.rows - 1) == UInt64(totalLines) && $0.transcriptFileIdentity != untrimmedIdentity
        }

        XCTAssertEqual(frame.transcriptFileIdentity, TranscriptReplayVT.fileIdentity(ofFileAt: paths.outputPath))
        XCTAssertLessThan(
            frame.transcriptByteOffset, UInt64(totalLines * TranscriptReplayVT.wireWidth), "the trimmed file is shorter than the PTY stream")
        let transcript = try await waitForTranscriptPrefix(at: paths.outputPath, length: frame.transcriptByteOffset)
        XCTAssertEqual(TranscriptReplayVT.screenRows(columns: frame.columns, rows: frame.rows, bytes: transcript), TranscriptReplayVT.rowTexts(frame))
    }

    // MARK: - Epoch

    /// The epoch moves exactly when absolute rows are renumbered: erase of scrollback, a full reset, a
    /// primary/alternate switch in either direction, and a column-changing resize move it; a resize that
    /// changes only the row count does not.
    func testEpochChangesOnRenumberingEventsAndNotOnARowsOnlyResize() async throws {
        try Self.requireGhosttyAvailable()
        let paths = try Self.makeTemporaryPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.rootDirectory) }

        let core = try await startCore(command: "stty -echo; cat", paths: paths)
        defer { terminate(core) }

        sendThroughCat("hello\n", to: core)
        var previous = try await waitForFrame(of: core) { TranscriptReplayVT.rowTexts($0).contains("hello") }

        func expectEpochChange(after text: String, containing visible: String, _ event: String) async throws {
            sendThroughCat(text, to: core)
            let old = previous.historyEpoch
            let frame = try await waitForFrame(of: core) { TranscriptReplayVT.rowTexts($0).contains(visible) && $0.historyEpoch != old }
            XCTAssertNotEqual(frame.historyEpoch, old, event)
            previous = frame
        }
        try await expectEpochChange(after: "\u{1B}[3J" + "after erase\n", containing: "after erase", "ED 3")
        try await expectEpochChange(after: "\u{1B}c" + "after reset\n", containing: "after reset", "RIS")
        try await expectEpochChange(after: "\u{1B}[?1049h" + "alternate\n", containing: "alternate", "1049 enter")
        try await expectEpochChange(after: "\u{1B}[?1049l" + "primary again\n", containing: "primary again", "1049 exit")

        let columnsBefore = previous.columns
        XCTAssertTrue(TerminalEngineActor.runSynchronously { Self.host(of: core).resizeCellGrid(columns: columnsBefore + 20, rows: previous.rows) })
        let widened = try await waitForFrame(of: core) { $0.columns == columnsBefore + 20 }
        XCTAssertNotEqual(widened.historyEpoch, previous.historyEpoch, "a column-changing resize renumbers rows")

        XCTAssertTrue(TerminalEngineActor.runSynchronously { Self.host(of: core).resizeCellGrid(columns: widened.columns, rows: widened.rows + 5) })
        let taller = try await waitForFrame(of: core) { $0.rows == widened.rows + 5 }
        XCTAssertEqual(taller.historyEpoch, widened.historyEpoch, "a rows-only resize leaves absolute rows alone")
    }

    // MARK: - Helpers

    private func waitForTranscriptPrefix(at path: String, length: UInt64, timeout: TimeInterval = 30) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = TranscriptReplayVT.prefix(ofFileAt: path, length: length) { return data }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("output.log never reached the frame's transcript offset \(length)")
        throw NSError(domain: "GhosttyEmbeddedSessionTranscriptStampTests", code: 2)
    }
}
