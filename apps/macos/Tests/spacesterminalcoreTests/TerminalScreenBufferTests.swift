import XCTest

@testable import spacesterminalcore

final class TerminalScreenBufferTests: XCTestCase {
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

    func testIngestTracksCursorVisibilityModes() {
        var buffer = TerminalScreenBuffer()

        buffer.ingest("hi")
        XCTAssertTrue(buffer.renderedScreen().cursorVisible)

        buffer.ingest("\u{001B}[?25l")
        XCTAssertFalse(buffer.renderedScreen().cursorVisible)

        buffer.ingest("\u{001B}[?25h")
        XCTAssertTrue(buffer.renderedScreen().cursorVisible)
    }
}
