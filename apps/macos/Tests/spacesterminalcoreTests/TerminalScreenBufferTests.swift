import XCTest

@testable import spacesterminalcore

final class TerminalScreenBufferTests: XCTestCase {
    private func fixture(named name: String) throws -> String {
        let fixturesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "fixtures", isDirectory: true)
        let data = try Data(contentsOf: fixturesRoot.appendingPathComponent(name))
        return String(decoding: data, as: UTF8.self)
    }

    func testIngestBuildsVisibleScreenAcrossChunks() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("hello")
        buffer.ingest("\rworld\nsecond")

        XCTAssertEqual(buffer.renderedText(), "world\nsecond")
    }

    func testIngestAppliesCursorMovesAndClearSequencesAcrossChunks() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("\u{001B}[2J")
        buffer.ingest("\u{001B}[24;1HWould you like to run")
        buffer.ingest("\u{001B}[25;1H$ spaces test")
        buffer.ingest("\u{001B}[25;3HSPACES")

        XCTAssertEqual(buffer.renderedText(), "Would you like to run\n$ SPACES test")
    }

    func testResetClearsExistingState() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("first line")
        buffer.reset()
        buffer.ingest("second line")

        XCTAssertEqual(buffer.renderedText(), "second line")
    }

    func testIngestSupportsSavingCursorAndCharacterEdits() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("hello")
        buffer.ingest("\u{001B}7")
        buffer.ingest("\nsecond")
        buffer.ingest("\u{001B}8!")
        buffer.ingest("\u{001B}[1G\u{001B}[2@XY")
        buffer.ingest("\u{001B}[5G\u{001B}[2P")

        XCTAssertEqual(buffer.renderedText(), "XYheo!\nsecond")
    }

    func testIngestSupportsLineInsertionDeletionAndCursorRestore() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("one\ntwo\nthree")
        buffer.ingest("\u{001B}[2;1H")
        buffer.ingest("\u{001B}[1Linserted")
        buffer.ingest("\u{001B}[3;1H\u{001B}[1M")

        XCTAssertEqual(buffer.renderedText(), "one\ninserted\nthree")
    }

    func testIngestSupportsAlternateScreenEnterAndExit() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("shell prompt")
        buffer.ingest("\u{001B}[?1049h")
        buffer.ingest("fullscreen app")
        XCTAssertEqual(buffer.renderedText(), "fullscreen app")

        buffer.ingest("\u{001B}[?1049l")
        XCTAssertEqual(buffer.renderedText(), "shell prompt")
    }

    func testAlternateScreenRestorePreservesPrimarySavedCursorState() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("one\ntwo\nthree")
        buffer.ingest("\u{001B}[2;2H\u{001B}7")
        buffer.ingest("\u{001B}[?1049h")
        buffer.ingest("\u{001B}[1;1H\u{001B}7")
        buffer.ingest("\u{001B}[?1049l")
        buffer.ingest("\u{001B}8X")

        XCTAssertEqual(buffer.renderedText(), "one\ntXo\nthree")
    }

    func testPrivateMode1048RestoresSavedCursorPosition() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("one\ntwo")
        buffer.ingest("\u{001B}[2;2H\u{001B}[?1048h")
        buffer.ingest("\u{001B}[1;1H")
        buffer.ingest("\u{001B}[?1048lX")

        XCTAssertEqual(buffer.renderedText(), "one\ntXo")
    }

    func testIngestTracksCursorVisibilityModes() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("hi")
        XCTAssertTrue(buffer.renderedScreen().cursorVisible)

        buffer.ingest("\u{001B}[?25l")
        XCTAssertFalse(buffer.renderedScreen().cursorVisible)

        buffer.ingest("\u{001B}[?25h")
        XCTAssertTrue(buffer.renderedScreen().cursorVisible)
    }

    func testIngestTracksCursorStyleModes() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("x")
        XCTAssertEqual(buffer.renderedScreen().cursorStyle, .block)

        buffer.ingest("\u{001B}[3 q")
        XCTAssertEqual(buffer.renderedScreen().cursorStyle, .underline)

        buffer.ingest("\u{001B}[5 q")
        XCTAssertEqual(buffer.renderedScreen().cursorStyle, .bar)

        buffer.ingest("\u{001B}[2 q")
        XCTAssertEqual(buffer.renderedScreen().cursorStyle, .block)
    }

    func testIngestSupportsScrollRegionsAndReverseIndex() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("top\none\ntwo\nbottom")
        buffer.ingest("\u{001B}[2;3r")
        buffer.ingest("\u{001B}[2;1H")
        buffer.ingest("\u{001B}M")
        buffer.ingest("inserted")

        XCTAssertEqual(buffer.renderedText(), "top\ninserted\none\nbottom")
    }

    func testIngestTracksMouseReportingModes() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("\u{001B}[?1006h\u{001B}[?1000h")
        XCTAssertEqual(buffer.renderedScreen().mouseTrackingMode, .click)
        XCTAssertTrue(buffer.renderedScreen().usesSGRMouseEncoding)

        buffer.ingest("\u{001B}[?1002h")
        XCTAssertEqual(buffer.renderedScreen().mouseTrackingMode, .drag)

        buffer.ingest("\u{001B}[?1003h")
        XCTAssertEqual(buffer.renderedScreen().mouseTrackingMode, .move)

        buffer.ingest("\u{001B}[?1007h")
        XCTAssertTrue(buffer.renderedScreen().usesAlternateScrollMode)

        buffer.ingest("\u{001B}[?2004h")
        XCTAssertTrue(buffer.renderedScreen().usesBracketedPasteMode)

        buffer.ingest("\u{001B}[?1004h")
        XCTAssertTrue(buffer.renderedScreen().usesFocusReporting)

        buffer.ingest("\u{001B}[?1003l\u{001B}[?1006l\u{001B}[?1007l\u{001B}[?2004l\u{001B}[?1004l")
        XCTAssertEqual(buffer.renderedScreen().mouseTrackingMode, .disabled)
        XCTAssertFalse(buffer.renderedScreen().usesSGRMouseEncoding)
        XCTAssertFalse(buffer.renderedScreen().usesAlternateScrollMode)
        XCTAssertFalse(buffer.renderedScreen().usesBracketedPasteMode)
        XCTAssertFalse(buffer.renderedScreen().usesFocusReporting)
    }

    func testIngestSupportsTabStopsAndTabClearSequences() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("a\tb")
        XCTAssertEqual(buffer.renderedText(), "a       b")

        buffer.reset()
        buffer.ingest("1234\u{001B}H\tX")
        XCTAssertEqual(buffer.renderedText(), "1234    X")

        buffer.ingest("\u{001B}[0g\r\tY")
        XCTAssertEqual(buffer.renderedText(), "1234Y   X")

        buffer.reset()
        buffer.ingest("\u{001B}[3g1234\u{001B}H\r\tZ")
        XCTAssertEqual(buffer.renderedText(), "1234Z")
    }

    func testIngestSupportsHardAndSoftTerminalResetSequences() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("hello\u{001B}[31m red\u{001B}[?1004h\u{001B}[?2004h")
        buffer.ingest("\u{001B}[!p")

        let softResetScreen = buffer.renderedScreen()
        XCTAssertEqual(buffer.renderedText(), "hello red")
        XCTAssertFalse(softResetScreen.usesFocusReporting)
        XCTAssertFalse(softResetScreen.usesBracketedPasteMode)
        XCTAssertTrue(softResetScreen.cursorVisible)

        buffer.ingest("\u{001B}creset")
        let hardResetScreen = buffer.renderedScreen()
        XCTAssertEqual(buffer.renderedText(), "reset")
        XCTAssertFalse(hardResetScreen.usesAlternateScreen)
        XCTAssertFalse(hardResetScreen.usesFocusReporting)
        XCTAssertFalse(hardResetScreen.usesBracketedPasteMode)
        XCTAssertTrue(hardResetScreen.cursorVisible)
    }

    func testIngestTracksOSCHyperlinkRanges() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("\u{001B}]8;;https://example.com\u{0007}link\u{001B}]8;;\u{0007} plain")

        let screen = buffer.renderedScreen()
        XCTAssertEqual(buffer.renderedText(), "link plain")
        XCTAssertEqual(screen.rows.first?[0].style.hyperlink, "https://example.com")
        XCTAssertEqual(screen.rows.first?[3].style.hyperlink, "https://example.com")
        XCTAssertNil(screen.rows.first?[5].style.hyperlink)
    }

    func testIngestTracksDoubleUnderlineAndUnderlineColor() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("\u{001B}[4;58;5;196mred\u{001B}[21;58;2;10;20;30mdouble\u{001B}[24;59mplain")

        let screen = buffer.renderedScreen()
        XCTAssertEqual(screen.rows.first?[0].style.underlineStyle, .single)
        XCTAssertEqual(screen.rows.first?[0].style.underlineColor, .palette(196))
        XCTAssertEqual(screen.rows.first?[3].style.underlineStyle, .double)
        XCTAssertEqual(screen.rows.first?[3].style.underlineColor, .rgb(10, 20, 30))
        XCTAssertEqual(screen.rows.first?[9].style.underlineStyle, .some(TerminalUnderlineStyle.none))
        XCTAssertNil(screen.rows.first?[9].style.underlineColor)
    }

    func testPrimaryScreenFullRegionScrollPreservesScrollbackHistory() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("\u{001B}[1;4r")
        buffer.ingest("one\ntwo\nthree\nfour")
        buffer.ingest("\u{001B}[4;1H")
        buffer.ingest("\nfive")

        XCTAssertEqual(buffer.renderedText(), "one\ntwo\nthree\nfour\nfive")
    }

    func testPrimaryScreenSubregionScrollPreservesScrollbackHistory() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("header")
        buffer.ingest("\u{001B}[2;4r")
        buffer.ingest("\u{001B}[2;1H")
        buffer.ingest("one\ntwo\nthree")
        buffer.ingest("\u{001B}[4;1H")
        buffer.ingest("\nfour")

        XCTAssertEqual(buffer.renderedText(), "one\nheader\ntwo\nthree\nfour")
    }

    func testAlternateScreenScrollDoesNotLeakIntoPrimaryScrollback() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("shell")
        buffer.ingest("\u{001B}[?1049h")
        buffer.ingest("\u{001B}[1;4r")
        buffer.ingest("one\ntwo\nthree\nfour")
        buffer.ingest("\u{001B}[4;1H")
        buffer.ingest("\nfive")
        XCTAssertEqual(buffer.renderedText(), "two\nthree\nfour\nfive")

        buffer.ingest("\u{001B}[?1049l")

        XCTAssertEqual(buffer.renderedText(), "shell")
    }

    func testAlternateScreenRestorePreservesPrimaryScrollRegionState() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("1\n2\n3\n4")
        buffer.ingest("\u{001B}[2;3r")
        buffer.ingest("\u{001B}[3;1H")
        buffer.ingest("\u{001B}[?1049halt\u{001B}[?1049l")
        buffer.ingest("\nX")

        XCTAssertTrue(buffer.renderedText().contains("X\n4"))
        XCTAssertTrue(buffer.renderedText().hasPrefix("2\n1\n3\n"))
    }

    func testCodexSessionFixtureProducesScrollableHistory() throws {
        var buffer = TerminalScreenBuffer()

        buffer.ingest(try fixture(named: "codex_session_120x40.ansi"))

        let renderedLines = buffer.renderedText().split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(renderedLines.count, 8)
        XCTAssertTrue(buffer.renderedText().contains("OpenAI Codex"))
        XCTAssertFalse(buffer.renderedText().contains("Context 0% used"))
    }
}
