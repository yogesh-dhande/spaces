import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalOutputTailTests: XCTestCase {
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

    func testTailReturnsLastLinesWithoutScanningWholeFileInCaller() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let text = (1...10).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        try text.data(using: .utf8)?.write(to: url)

        let tailed = try TerminalOutputTail.tail(path: url.path, lineCount: 3)

        XCTAssertEqual(tailed, "line-8\nline-9\nline-10")
    }

    func testTailRendersVisibleScreenTextFromANSITranscript() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let text = """
            \u{001B}[24;1H  \u{001B}[1mWould you like to run the following command?\u{001B}[25;1H\u{001B}[22m
            \u{001B}[26;1H  Reason: \u{001B}[3mDo you want to allow `spaces agent signal --workspace ws --session s init` to access its database
            \u{001B}[27;1H\u{001B}[23m  outside the workspace so it can initialize successfully?\u{001B}[29;1H  $ \u{001B}[38;2;137;180;250;49mspaces\u{001B}[38;2;205;214;244;49m agent signal --workspace ws --session s init
            \u{001B}[31;1H\u{001B}[1m\u{001B}[38;5;6;48;2;65;69;76m› 1. Yes, proceed (y)
            \u{001B}[32;1H\u{001B}[22m\u{001B}[39;48;2;65;69;76m  2. Yes, and don't ask again for commands that start with `spaces agent signal` (p)
            \u{001B}[33;1H  3. No, and tell Codex what to do differently (esc)
            \u{001B}[35;3H\u{001B}[2m\u{001B}[39;49mPress enter to confirm or esc to cancel
            """
        try text.data(using: .utf8)?.write(to: url)

        let tailed = try TerminalOutputTail.tail(path: url.path, lineCount: 20)

        XCTAssertTrue(tailed.contains("Would you like to run the following command?"))
        XCTAssertTrue(tailed.contains("Reason: Do you want to allow `spaces agent signal --workspace ws --session s init` to access its database"))
        XCTAssertTrue(tailed.contains("outside the workspace so it can initialize successfully?"))
        XCTAssertTrue(tailed.contains("$ spaces agent signal --workspace ws --session s init"))
        XCTAssertTrue(tailed.contains("Yes, proceed (y)"))
        XCTAssertTrue(tailed.contains("don't ask again for commands that start with `spaces agent signal` (p)"))
        XCTAssertTrue(tailed.contains("No, and tell Codex what to do differently (esc)"))
        XCTAssertTrue(tailed.contains("Press enter to confirm or esc to cancel"))
    }

    func testTailPreservesOrderedSuffixForLargeTranscript() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let text = (1...10000).map { String(format: "SEQ %05d", $0) }.joined(separator: "\n") + "\n"
        try text.data(using: .utf8)?.write(to: url)

        let tailed = try TerminalOutputTail.tail(path: url.path, lineCount: 4)

        XCTAssertEqual(tailed, "SEQ 09997\nSEQ 09998\nSEQ 09999\nSEQ 10000")
    }

    func testTailKeepsPlainTextFastPathForCarriageReturnFreeLogs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let text = (1...2000).map { "plain-\($0)" }.joined(separator: "\n") + "\n"
        try text.data(using: .utf8)?.write(to: url)

        let tailed = try TerminalOutputTail.tail(path: url.path, lineCount: 2)

        XCTAssertEqual(tailed, "plain-1999\nplain-2000")
    }

    func testTailFallsBackToRenderedTranscriptWhenCarriageReturnsRewriteLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let text = "progress 10%\rprogress 100%\ncomplete\n"
        try text.data(using: .utf8)?.write(to: url)

        let tailed = try TerminalOutputTail.tail(path: url.path, lineCount: 2)

        XCTAssertEqual(tailed, "progress 100%\n\(String(repeating: " ", count: "progress 100%".count))complete")
    }

    func testTailRendersCursorHomeStatusRewriteThroughGhosttyVT() throws {
        let sessionRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionRoot) }
        let paths = TerminalSessionPaths(rootDirectory: sessionRoot.path)
        let url = URL(fileURLWithPath: paths.outputPath)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: "session-home", title: "Tail fixture", workingDirectory: sessionRoot.path, shell: "/bin/zsh", command: nil,
                createdAt: "2026-05-15T00:00:00Z", workspaceID: "tail-fixture-workspace", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "session-home", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-15T00:00:00Z",
                columns: 200, rows: 4), paths: paths)
        let text = """
            SEQ 00000001 bootstrap
            \u{001B}[HSTATUS frame=000002 total=000002\u{001B}[2;1HSEQ 00000002 FRAME 000002 ROW 001 alpha\u{001B}[3;1HSEQ 00000003 FRAME 000002 ROW 002 beta\u{001B}[4;1HSEQ 00000004 FRAME 000002 ROW 003 gamma
            """
        try text.data(using: .utf8)?.write(to: url)

        let tailed = try TerminalOutputTail.tail(path: url.path, lineCount: 3)

        XCTAssertEqual(
            tailed, "SEQ 00000002 FRAME 000002 ROW 001 alpha\nSEQ 00000003 FRAME 000002 ROW 002 beta\nSEQ 00000004 FRAME 000002 ROW 003 gamma")
    }

    /// The shape of every freshly spawned agent session, and the blank tail's dominant real-world
    /// trigger: the agent paints its panel once, then re-homes the cursor (`ESC [ H`) on every repaint
    /// cycle even when almost nothing changed.
    ///
    /// This is NOT a transcript-size case — the fixture is a couple of kilobytes, well inside the first
    /// window any end-relative scan would have looked in. It is a state case, and the home is what does
    /// the damage: because a cycle's home is followed by only tens of bytes, the NEWEST home-like
    /// boundary in a live transcript sits a few dozen bytes from its end, so a scan rooted there replays
    /// the tail of one repaint cycle into a blank vt and renders essentially nothing. Measured on a
    /// captured 3.2&nbsp;KB Claude transcript: replaying from the newest home, 44 bytes from EOF, gave
    /// zero non-blank lines, while replaying from byte 0 gave the complete 17-line panel. How many stray
    /// lines a session shows depends only on how much output happened to follow its last home, which is
    /// why the reported counts varied between zero and ten.
    ///
    /// The general rule underneath: a cursor home moves the cursor and nothing else, and a `CSI 2J`
    /// erases cells and nothing else — resetting neither the active screen, nor the margins, nor origin
    /// mode, nor the charsets. Neither reconstructs state, so neither is a position a replay can begin
    /// interpreting from.
    func testTailRendersAFreshAgentTUIThatRehomesItsCursorOnEveryRepaint() throws {
        let agent = try makeFreshAgentTranscript(sessionID: "session-agent")

        let tailed = try TerminalOutputTail.tail(path: agent.outputPath, lineCount: Self.rows)

        let nonBlankLines = tailed.split(separator: "\n", omittingEmptySubsequences: false).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        XCTAssertGreaterThanOrEqual(nonBlankLines.count, Self.agentPanelRows.count, "A live agent session must not tail as blank output: \(tailed)")
        for row in Self.agentPanelRows { XCTAssertTrue(tailed.contains(row), "The agent's panel must survive into the tail: \(tailed)") }
        XCTAssertTrue(tailed.contains(Self.inPlaceUpdateText(agent.lastUpdate)), "The agent's live status row must be shown: \(tailed)")
    }

    /// A full-screen program paints its frame once and then updates it with targeted absolute cursor
    /// addressing, so its last genuine repaint sits arbitrarily far behind the end of the transcript. The
    /// tail renders from byte 0 for exactly this reason: the screen is the accumulation of every byte
    /// before it, so any later starting point reconstructs it against a blank grid and hands an
    /// orchestrator empty output for a live, healthy session.
    func testTailRendersLiveScreenAfterSteadyStateUpdatesOutrunTheLastFullRepaint() throws {
        let steadyState = try makeSteadyStateTranscript(sessionID: "session-steady")

        let tailed = try TerminalOutputTail.tail(path: steadyState.outputPath, lineCount: Self.rows + 5)

        for row in 1...(Self.rows - 1) {
            XCTAssertTrue(
                tailed.contains("PANEL ROW \(String(format: "%02d", row)) static header content"),
                "Row \(row) of the live screen must survive into the tail: \(tailed)")
        }
        XCTAssertTrue(
            tailed.contains("STATUS frame=\(String(format: "%06d", steadyState.lastFrame))"), "The tail must show the newest update: \(tailed)")
    }

    /// `--lines n` is a request for history, not for the screen: an ordinary shell scrolls its output
    /// away, and every line of it is still in `output.log`, so the tail returns the newest `n` of them.
    func testTailReturnsRequestedHistoryFromAScrollingSession() throws {
        let scrolling = try makeScrollingTranscript(sessionID: "session-scrolling")
        let requestedLines = 100

        let tailed = try TerminalOutputTail.tail(path: scrolling.outputPath, lineCount: requestedLines)

        let lines = tailed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, requestedLines, "The tail must return the history it was asked for, not just the visible screen: \(tailed)")
        XCTAssertEqual(lines.last, Self.scrollingLineText(scrolling.lastLine), "The tail must end at the newest line: \(tailed)")
        XCTAssertEqual(
            lines.first, Self.scrollingLineText(scrolling.lastLine - requestedLines + 1),
            "The returned lines must be the contiguous newest ones: \(tailed)")
    }

    /// A shell that scrolled real output and then ran a long progress display rewriting one row in place.
    /// The scrollback sits behind the whole in-place run, and a tail asked for more lines than the screen
    /// holds has to reach past it.
    func testTailReturnsScrollbackBehindALongRunOfInPlaceUpdates() throws {
        let session = try makeScrollbackBehindInPlaceUpdatesTranscript(sessionID: "session-inplace")
        let requestedLines = 100

        let tailed = try TerminalOutputTail.tail(path: session.outputPath, lineCount: requestedLines)

        let lines = tailed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, requestedLines, "The tail must reach the scrollback behind the in-place updates: \(tailed)")
        XCTAssertTrue(tailed.contains(Self.scrollingLineText(session.lastScrollLine)), "The newest scrolled line must be shown: \(tailed)")
        XCTAssertTrue(tailed.contains(Self.inPlaceUpdateText(session.lastUpdate)), "The live in-place row must be shown: \(tailed)")
        let firstLine = try XCTUnwrap(lines.first)
        XCTAssertTrue(firstLine.hasPrefix("SCROLL LINE"), "The returned history must reach back into the scrolled output: \(tailed)")
    }

    /// Once a session outgrows the live-transcript bound its transcript is head-trimmed, and byte 0 stops
    /// being a blank terminal: it becomes the state-restoration preamble the trim synthesized. Rendering
    /// from byte 0 is what makes that preamble the tail's starting state, so output the dropped head drew
    /// and the retained tail never redraws still reaches the tail.
    func testTailRendersATrimmedTranscriptFromItsHeadPreamble() throws {
        let trimmed = try makeTrimmedTranscript(sessionID: "session-trimmed", output: Self.steadyStatePaint() + Self.steadyStateUpdates(count: 400))

        let tailed = try TerminalOutputTail.tail(path: trimmed, lineCount: Self.rows + 5)

        for row in 1...(Self.rows - 1) {
            XCTAssertTrue(
                tailed.contains("PANEL ROW \(String(format: "%02d", row)) static header content"),
                "Row \(row), painted before the trim's cut and never redrawn, must survive into the tail: \(tailed)")
        }
        XCTAssertTrue(tailed.contains("STATUS frame="), "The live status row must be shown: \(tailed)")
    }

    /// The trim's preamble has to restore the terminal state the dropped head established, not only the
    /// cells it drew. A program that sets a scrolling region once and afterwards only feeds lines into it
    /// never re-emits the DECSTBM, so a preamble without it is replayed into a terminal that has none and
    /// every following line feed scrolls the whole screen instead of the region — taking the static rows
    /// the program keeps outside it with it.
    func testTailKeepsStaticRowsOfATrimmedTUIThatOnlyScrollsInsideItsRegion() throws {
        let output = Self.regionFramePaint() + Self.regionUpdates(count: 400)
        let trimmed = try makeTrimmedTranscript(sessionID: "session-trimmed-region", output: output)

        let tailed = try TerminalOutputTail.tail(path: trimmed, lineCount: Self.rows)

        XCTAssertTrue(tailed.contains("STATIC HEADER"), "The row above the scrolling region must survive the trim: \(tailed)")
        XCTAssertTrue(tailed.contains("STATIC FOOTER"), "The row below the scrolling region must survive the trim: \(tailed)")
        XCTAssertTrue(tailed.contains(Self.regionLineText(400)), "The newest line inside the region must be shown: \(tailed)")
    }
    func testTailKeepsOutputThatScrolledAboveAPromptRedrawEraseBelow() throws {
        // A shell prompt redraw emits a bare erase-below (CSI J), not a full-screen clear, so output
        // that scrolled above the current prompt must still appear in the tail. This is the contract
        // agents rely on: `sendTerminalInput` runs a command, then `tailTerminalOutput` reads its
        // result even though the shell has already drawn a fresh prompt below it. A regression here
        // silently truncates the tail to just the final (empty) prompt line.
        let esc = "\u{001B}"
        // Zsh-style redraw: reverse-video PROMPT_EOL_MARK, carriage returns, SGR resets, a bare CSI J
        // to clear below the prompt, then the prompt text — mirroring a real interactive transcript.
        let promptRedraw = "\(esc)[1m\(esc)[7m%\(esc)[27m\(esc)[0m\r \r\r\(esc)[0m\(esc)[24m\(esc)[Juser@host demo % \(esc)[K\(esc)[?2004h"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let text = "\(promptRedraw)\(esc)[?2004le\u{0008}echo scrolled-marker\(esc)[?2004l\r\r\n" + "scrolled-marker\r\n" + promptRedraw
        try text.data(using: .utf8)?.write(to: url)

        let tailed = try TerminalOutputTail.tail(path: url.path, lineCount: 20)

        XCTAssertTrue(
            tailed.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.trimmingCharacters(in: .whitespaces) == "scrolled-marker" },
            "tail dropped output that scrolled above the redrawn prompt: \(tailed)")
    }

    func testTailUsesPersistedTerminalSizeForANSIWrapping() throws {
        let sessionRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionRoot) }

        let paths = TerminalSessionPaths(rootDirectory: sessionRoot.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: "session-size", title: "Tail fixture", workingDirectory: sessionRoot.path, shell: "/bin/zsh", command: nil,
                createdAt: "2026-05-15T00:00:00Z", workspaceID: "tail-fixture-workspace", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "session-size", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-15T00:00:00Z",
                columns: 4, rows: 3), paths: paths)
        let text = "\u{001B}[31mABCDEFGHIJ\u{001B}[0m"
        try text.data(using: .utf8)?.write(to: URL(fileURLWithPath: paths.outputPath))

        let tailed = try TerminalOutputTail.tail(path: paths.outputPath, lineCount: 2)

        XCTAssertEqual(tailed, "EFGH\nIJ")
    }

    func testTailSuppressesCodexInlineSuggestionAndPreservesStatusAfterCursor() throws {
        let escape = "\u{001B}"
        let output =
            "\(escape)[2J\(escape)[1;1Hcompleted output" + "\(escape)[5;1H› \(escape)[2mWrite tests for @filename\(escape)[22m"
            + "\(escape)[7;1Hgpt-5.6-sol medium · Context 92% left · main" + "\(escape)[5;3H\(escape)[?25h"

        let tailed = try renderedTail(output, columns: 80, rows: 8)

        XCTAssertTrue(tailed.contains("completed output"), tailed)
        XCTAssertTrue(tailed.contains("›"), tailed)
        XCTAssertFalse(tailed.contains("Write tests for @filename"), tailed)
        XCTAssertTrue(tailed.contains("gpt-5.6-sol medium · Context 92% left · main"), tailed)
    }

    func testTailSuppressesOnlyClaudeInlineSuggestionRun() throws {
        let escape = "\u{001B}"
        let output =
            "\(escape)[2J\(escape)[1;1Hanalysis complete"
            + "\(escape)[4;1H❯ \(escape)[2mShow me a preview of the running app\(escape)[22m queued input"
            + "\(escape)[6;3H\(escape)[2mautocomplete option\(escape)[22m" + "\(escape)[8;1Hyogesh@Mac demo | Fable 5 | ctx 40%"
            + "\(escape)[4;3H\(escape)[?25h"

        let tailed = try renderedTail(output, columns: 80, rows: 9)

        XCTAssertFalse(tailed.contains("Show me a preview of the running app"), tailed)
        XCTAssertTrue(tailed.contains("queued input"), tailed)
        XCTAssertTrue(tailed.contains("autocomplete option"), tailed)
        XCTAssertTrue(tailed.contains("yogesh@Mac demo | Fable 5 | ctx 40%"), tailed)
    }

    func testTailPreservesNormalUnsubmittedTextAtAndAfterCursor() throws {
        let escape = "\u{001B}"
        let output = "\(escape)[2J\(escape)[3;1H❯ keep-this-real-text" + "\(escape)[7;1Hstatus remains useful" + "\(escape)[3;8H\(escape)[?25h"

        let tailed = try renderedTail(output, columns: 60, rows: 8)

        XCTAssertTrue(tailed.contains("❯ keep-this-real-text"), tailed)
        XCTAssertTrue(tailed.contains("status remains useful"), tailed)
    }

    func testTailPreservesFaintTextWhenCursorIsHidden() throws {
        let escape = "\u{001B}"
        let output = "\(escape)[2J\(escape)[3;1H❯ \(escape)[2mpermission dialog instruction\(escape)[22m" + "\(escape)[3;3H\(escape)[?25l"

        let tailed = try renderedTail(output, columns: 60, rows: 6)

        XCTAssertTrue(tailed.contains("permission dialog instruction"), tailed)
    }

    func testTailSuppressesSoftWrappedInlineSuggestionWithoutRemovingFollowingRows() throws {
        let escape = "\u{001B}"
        let output =
            "\(escape)[2J\(escape)[2;1H› \(escape)[2mabcdefghijklmno\(escape)[22m" + "\(escape)[6;1Hstatus below" + "\(escape)[2;3H\(escape)[?25h"

        let tailed = try renderedTail(output, columns: 12, rows: 7)

        XCTAssertTrue(tailed.contains("›"), tailed)
        XCTAssertFalse(tailed.contains("abcdefghij"), tailed)
        XCTAssertFalse(tailed.contains("klmno"), tailed)
        XCTAssertTrue(tailed.contains("status below"), tailed)
    }

    func testTailPreservesFaintTextUnderCursorInOrdinaryTerminalSession() throws {
        let escape = "\u{001B}"
        let output = "\(escape)[2J\(escape)[3;1H\(escape)[2mreal dim editor content\(escape)[22m" + "\(escape)[3;1H\(escape)[?25h"

        let tailed = try renderedTail(output, columns: 60, rows: 6, sessionKind: .shell, detectedAgentKind: nil)

        XCTAssertTrue(tailed.contains("real dim editor content"), tailed)
    }

    func testTailSuppressesSuggestionForDedicatedAgentSessionWithoutForegroundClassification() throws {
        let escape = "\u{001B}"
        let output = "\(escape)[2J\(escape)[3;1H› \(escape)[2magent launch suggestion\(escape)[22m" + "\(escape)[3;3H\(escape)[?25h"

        let tailed = try renderedTail(output, columns: 60, rows: 6, sessionKind: .agent, detectedAgentKind: nil)

        XCTAssertTrue(tailed.contains("›"), tailed)
        XCTAssertFalse(tailed.contains("agent launch suggestion"), tailed)
    }

    func testStableTranscriptCollapsesPromptEOLMarkArtifactIntoPromptLine() throws {
        let transcript = try TerminalOutputTail.stableTranscript(from: promptEOLMarkFixtureOutput(), columns: 80, rows: 24)

        XCTAssertTrue(transcript.localizedStandardContains("Last login: Thu May 21 20:43:12 on ttys109"), transcript)
        XCTAssertTrue(transcript.localizedStandardContains("Using Node v24.11.1"), transcript)
        XCTAssertTrue(transcript.localizedStandardContains("shell % python3 /tmp/fixture.py --mode lines"), transcript)
        XCTAssertFalse(
            transcript.split(separator: "\n").contains { line in String(line).trimmingCharacters(in: .whitespacesAndNewlines) == "%" }, transcript)
    }

    func testStableTranscriptIncludesPromptOutputAfterTakeoverAppend() throws {
        let transcript = try TerminalOutputTail.stableTranscript(from: promptAppendFixtureOutput(), columns: 96, rows: 53)

        XCTAssertTrue(transcript.localizedStandardContains("shell % echo __roundtrip_ipad_one__"), transcript)
        XCTAssertTrue(transcript.localizedStandardContains("__roundtrip_ipad_one__"), transcript)
        XCTAssertFalse(
            transcript.split(separator: "\n").contains { line in String(line).trimmingCharacters(in: .whitespacesAndNewlines) == "%" }, transcript)
    }

    func testStableTranscriptClearsAutosuggestionOverwrite() throws {
        let transcript = try TerminalOutputTail.stableTranscript(from: autosuggestionEraseFixtureOutput(), columns: 80, rows: 8)

        XCTAssertTrue(transcript.localizedStandardContains("t not found"), transcript)
        XCTAssertFalse(transcript.localizedStandardContains("ailscale"), transcript)
    }

    private func promptEOLMarkFixtureOutput() -> Data {
        let eolMark =
            "\u{001B}[1m\u{001B}[7m%\u{001B}[27m\u{001B}[1m\u{001B}[0m" + String(repeating: " ", count: 96)
            + "\r \r\r\u{001B}[0m\u{001B}[27m\u{001B}[24m\u{001B}[J"
        let output = """
            Last login: Thu May 21 20:43:12 on ttys109\r
            Using Node \u{001B}[36mv24.11.1\u{001B}[0m\r
            \(eolMark)shell % \u{001B}[K\u{001B}[?2004hpython3 /tmp/fixture.py --mode lines\r
            FIXTURE_START mode=lines\r
            SEQ 00000001 example-scrollback-line\r
            FIXTURE_DONE mode=lines emitted=1\r
            shell % 
            """
        return Data(output.utf8)
    }

    private func promptAppendFixtureOutput() -> Data {
        let eolMark =
            "\u{001B}[1m\u{001B}[7m%\u{001B}[27m\u{001B}[1m\u{001B}[0m" + String(repeating: " ", count: 96)
            + "\r \r\r\u{001B}[0m\u{001B}[27m\u{001B}[24m\u{001B}[J"
        let output = """
            Last login: Fri May 22 11:03:38 on ttys260\r
            Using Node \u{001B}[36mv24.11.1\u{001B}[0m\r
            \(eolMark)shell % \u{001B}[K\u{001B}[?2004hprintf '__roundtrip_mac_before_takeover_two__\\n'\u{001B}[?2004l\r
            __roundtrip_mac_before_takeover_two__\r
            \(eolMark)shell % \u{001B}[K\u{001B}[?2004h\r
            \u{001B}[0m\u{001B}[27m\u{001B}[24m\u{001B}[Jshell % \r
            \u{001B}[0m\u{001B}[27m\u{001B}[24m\u{001B}[Jshell % e\u{0008}echo __roundtrip_ipad_one__\u{001B}[27D\u{001B}[32me\u{001B}[32mc\u{001B}[32mh\u{001B}[32mo\u{001B}[39m\u{001B}[23C\u{001B}[?2004l\r
            __roundtrip_ipad_one__\r
            \(eolMark)shell % \u{001B}[K\u{001B}[?2004h
            """
        return Data(output.utf8)
    }

    private func autosuggestionEraseFixtureOutput() -> Data {
        let clearSuggestion = String(repeating: "\u{0008}", count: 8) + String(repeating: "\u{001B}[39m ", count: 8) + "\u{001B}[8D"
        let output =
            "Using Node v24.11.1\r\n" + "\u{001B}[0m\u{001B}[27m\u{001B}[24m\u{001B}[J" + "shell % \u{001B}[K\u{001B}[?2004h" + "w\u{0008}which t"
            + String(repeating: "\u{0008}", count: 7) + "\u{001B}[32mw\u{001B}[32mh\u{001B}[32mi\u{001B}[32mc\u{001B}[32mh\u{001B}[39m"
            + "\u{001B}[2C\u{001B}[90mailscale\u{001B}[39m" + clearSuggestion + "\u{001B}[?2004l\r\r\n" + "t not found\r\n"
            + "\u{001B}[0m\u{001B}[27m\u{001B}[24m\u{001B}[J" + "shell % \u{001B}[K\u{001B}[?2004h"
        return Data(output.utf8)
    }

    // MARK: - Transcript fixtures

    private static let columns = 80
    private static let rows = 24
    /// Enough scrolled output to satisfy any line count these tests ask for, and enough in-place updates
    /// after it that the requested history sits entirely behind them.
    private static let scrolledLineCount = 1400
    private static let inPlaceUpdateCount = 7000
    private static let regionTopRow = 2
    private static let regionBottomRow = 23

    private static func scrollingLineText(_ line: Int) -> String { "SCROLL LINE \(String(format: "%06d", line))" }
    private static func regionLineText(_ line: Int) -> String { "REGION LINE \(String(format: "%06d", line))" }
    private static func inPlaceUpdateText(_ update: Int) -> String { "PROGRESS \(String(format: "%06d", update))" }

    /// The panel a coding agent draws on startup, in the order a real one emits it: a boxed welcome
    /// frame, then a prompt row.
    private static let agentPanelRows = [
        "╭──────────────────────────────────────────╮", "│ Welcome to the agent                     │",
        "│                                          │", "│   /help for help, /status for status     │",
        "│                                          │", "│   cwd: /Users/dev/project                │",
        "╰──────────────────────────────────────────╯",
    ]

    /// One repaint cycle of a full-screen TUI: home the cursor, then rewrite the status row. Real agents
    /// re-home on every cycle even when almost nothing else changed, which is what puts a home-like
    /// boundary within tens of bytes of a live transcript's end.
    private static func repaintCycles(count: Int) -> String {
        var text = ""
        for tick in 1...count { text += "\u{001B}[H\u{001B}[\(rows);3H\(inPlaceUpdateText(tick))" }
        return text
    }

    /// A freshly spawned agent's opening frame: enter the alternate screen, hide the cursor, clear, then
    /// paint the panel with absolute cursor addressing and never repaint it again.
    private static func alternateScreenAgentPaint() -> Data {
        var text = "\u{001B}[?1049h\u{001B}[?25l\u{001B}[2J"
        for (index, row) in agentPanelRows.enumerated() { text += "\u{001B}[\(index + 2);3H\(row)" }
        text += "\u{001B}[\(rows - 2);3H> "
        return Data(text.utf8)
    }

    /// The frame a full-screen program paints once and never repeats.
    private static func steadyStatePaint() -> Data {
        var paint = "\u{001B}[2J"
        for row in 1...(rows - 1) { paint += "\u{001B}[\(row);1HPANEL ROW \(String(format: "%02d", row)) static header content" }
        return Data(paint.utf8)
    }

    /// Steady-state updates that only address the cursor absolutely — no clear, no cursor home — so the
    /// transcript grows without the program ever repainting its frame again.
    private static func steadyStateUpdates(count: Int) -> Data {
        var text = ""
        for frame in 1...count { text += "\u{001B}[\(rows);1HSTATUS frame=\(String(format: "%06d", frame)) live-marker" }
        return Data(text.utf8)
    }

    /// Static rows above and below a scrolling region, then the region itself, painted once.
    private static func regionFramePaint() -> Data {
        Data("\u{001B}[2J\u{001B}[1;1HSTATIC HEADER\u{001B}[\(rows);1HSTATIC FOOTER\u{001B}[\(regionTopRow);\(regionBottomRow)r".utf8)
    }

    /// Lines fed at the region's bottom row: with the region in force these scroll rows
    /// regionTopRow…regionBottomRow and leave the static rows untouched. Replayed against a terminal with
    /// no region they walk off the bottom and scroll the whole screen instead.
    private static func regionUpdates(count: Int) -> Data {
        var text = ""
        for line in 1...count { text += "\u{001B}[\(regionBottomRow);1H\(regionLineText(line))\r\n" }
        return Data(text.utf8)
    }

    /// A session directory with persisted launch/runtime state and `output` as its transcript, laid out
    /// exactly as a session core leaves it on disk.
    private func makeSessionTranscript(sessionID: String, output: Data) throws -> String {
        let sessionRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sessionRoot) }
        let paths = TerminalSessionPaths(rootDirectory: sessionRoot.path)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: "Tail fixture", workingDirectory: sessionRoot.path, shell: "/bin/zsh", command: nil,
                createdAt: "2026-07-30T00:00:00Z", workspaceID: "tail-fixture-workspace", kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-07-30T00:00:00Z",
                columns: Self.columns, rows: Self.rows), paths: paths)
        try output.write(to: URL(fileURLWithPath: paths.outputPath))
        return paths.outputPath
    }

    /// The same transcript after a real head trim, so byte 0 is the preamble the trim synthesized rather
    /// than a blank terminal. The trigger and retained sizes are scaled down from the production policy
    /// so a test-sized transcript crosses them.
    private func makeTrimmedTranscript(sessionID: String, output: Data) throws -> String {
        let outputPath = try makeSessionTranscript(sessionID: sessionID, output: output)
        let endOffset = UInt64(output.count)
        let plan = try XCTUnwrap(
            TerminalTranscriptTrim.plan(
                outputPath: outputPath, currentEndOffset: endOffset, triggerBytes: endOffset / 2, retainedBytes: endOffset / 4),
            "The fixture must be long enough to trim.")
        let staged = try TerminalTranscriptTrim.stage(outputPath: outputPath, plan: plan, columns: Self.columns, rows: Self.rows)
        let result = try TerminalTranscriptTrim.commit(staged, outputPath: outputPath, currentEndOffset: endOffset)
        try result.writeHandle.close()
        XCTAssertLessThan(result.endOffset, endOffset, "The fixture must actually have been trimmed.")
        return outputPath
    }

    /// One full-screen paint, then steady-state updates that only address the cursor absolutely.
    private func makeSteadyStateTranscript(sessionID: String) throws -> (outputPath: String, lastFrame: Int) {
        let frames = 4000
        let outputPath = try makeSessionTranscript(sessionID: sessionID, output: Self.steadyStatePaint() + Self.steadyStateUpdates(count: frames))
        return (outputPath, frames)
    }

    /// Lines an ordinary shell writes and scrolls away. They carry SGR so the tail cannot answer from its
    /// plain-text fast path.
    private static func scrolledOutput(count: Int) -> String {
        var text = ""
        for line in 1...count { text += "\u{001B}[32m\(scrollingLineText(line))\u{001B}[0m\r\n" }
        return text
    }

    /// A progress display that only ever rewrites the bottom row.
    private static func inPlaceUpdates(count: Int) -> String {
        var text = ""
        for update in 1...count { text += "\u{001B}[\(rows);1H\(inPlaceUpdateText(update))" }
        return text
    }

    /// A freshly spawned agent session, at the size a real one reaches within its first seconds: the
    /// alternate-screen panel, then repaint cycles that each re-home the cursor. The last cycle's home
    /// lands a couple of dozen bytes from the end of the transcript, as it does in a live one.
    private func makeFreshAgentTranscript(sessionID: String) throws -> (outputPath: String, lastUpdate: Int) {
        let ticks = 60
        let output = Self.alternateScreenAgentPaint() + Data(Self.repaintCycles(count: ticks).utf8)
        return (try makeSessionTranscript(sessionID: sessionID, output: output), ticks)
    }

    /// A plain scrolling shell: every line is written and scrolled away, and nothing is ever repainted.
    private func makeScrollingTranscript(sessionID: String) throws -> (outputPath: String, lastLine: Int) {
        let output = Data(Self.scrolledOutput(count: Self.scrolledLineCount).utf8)
        return (try makeSessionTranscript(sessionID: sessionID, output: output), Self.scrolledLineCount)
    }

    /// A shell that scrolls real output into its scrollback and then runs a long progress display that
    /// only rewrites one row, so the requested history sits entirely behind the in-place run.
    private func makeScrollbackBehindInPlaceUpdatesTranscript(sessionID: String) throws -> (outputPath: String, lastScrollLine: Int, lastUpdate: Int)
    {
        let output = Data((Self.scrolledOutput(count: Self.scrolledLineCount) + Self.inPlaceUpdates(count: Self.inPlaceUpdateCount)).utf8)
        return (try makeSessionTranscript(sessionID: sessionID, output: output), Self.scrolledLineCount, Self.inPlaceUpdateCount)
    }

    private func renderedTail(
        _ output: String, columns: Int, rows: Int, lineCount: Int = 20, sessionKind: TerminalSessionKind = .shell,
        detectedAgentKind: TerminalDetectedAgentKind? = .opencode
    ) throws -> String {
        let sessionRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionRoot) }
        let paths = TerminalSessionPaths(rootDirectory: sessionRoot.path)
        let sessionID = UUID().uuidString
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: "Tail fixture", workingDirectory: sessionRoot.path, shell: "/bin/zsh", command: nil,
                createdAt: "2026-07-15T00:00:00Z", workspaceID: "tail-fixture-workspace", kind: sessionKind), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-07-15T00:00:00Z",
                columns: columns, rows: rows, foregroundDetectedAgentKind: detectedAgentKind), paths: paths)
        try Data(output.utf8).write(to: URL(fileURLWithPath: paths.outputPath))
        return try TerminalOutputTail.tail(path: paths.outputPath, lineCount: lineCount)
    }
}
