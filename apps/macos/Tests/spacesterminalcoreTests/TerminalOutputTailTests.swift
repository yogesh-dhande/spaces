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
