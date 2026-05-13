import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalOutputTailTests: XCTestCase {
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
            \u{001B}[26;1H  Reason: \u{001B}[3mDo you want to allow `spaces signal init` to access its database outside the workspace so it can
            \u{001B}[27;1H\u{001B}[23m  initialize successfully?\u{001B}[29;1H  $ \u{001B}[38;2;137;180;250;49mspaces\u{001B}[38;2;205;214;244;49m signal init
            \u{001B}[31;1H\u{001B}[1m\u{001B}[38;5;6;48;2;65;69;76m› 1. Yes, proceed (y)
            \u{001B}[32;1H\u{001B}[22m\u{001B}[39;48;2;65;69;76m  2. Yes, and don't ask again for commands that start with `spaces signal init` (p)
            \u{001B}[33;1H  3. No, and tell Codex what to do differently (esc)
            \u{001B}[35;3H\u{001B}[2m\u{001B}[39;49mPress enter to confirm or esc to cancel
            """
        try text.data(using: .utf8)?.write(to: url)

        let tailed = try TerminalOutputTail.tail(path: url.path, lineCount: 20)

        XCTAssertTrue(tailed.contains("Would you like to run the following command?"))
        XCTAssertTrue(tailed.contains("Reason: Do you want to allow `spaces signal init` to access its database outside the workspace so it can"))
        XCTAssertTrue(tailed.contains("initialize successfully?"))
        XCTAssertTrue(tailed.contains("$ spaces signal init"))
        XCTAssertTrue(tailed.contains("Yes, proceed (y)"))
        XCTAssertTrue(tailed.contains("don't ask again for commands that start with `spaces signal init` (p)"))
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

        XCTAssertEqual(tailed, "progress 100%\ncomplete")
    }
}
