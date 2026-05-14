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
}
