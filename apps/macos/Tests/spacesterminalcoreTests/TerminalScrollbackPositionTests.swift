import XCTest

@testable import spacesterminalcore

/// The derivation both clients read to decide whether to offer the jump-to-bottom control.
final class TerminalScrollbackPositionTests: XCTestCase {
    func testViewportAtTheLiveBottomIsNotScrolledBack() {
        let position = TerminalScrollbackPosition(scrollbarTotal: 500, scrollbarOffset: 476, viewportRows: 24)

        XCTAssertEqual(position.rowsFromLiveBottom, 0)
        XCTAssertFalse(position.isScrolledIntoScrollback, "a viewport showing the session's last row must not offer a jump to the bottom")
    }

    func testViewportAboveTheLiveBottomReportsTheRowsBelowIt() {
        let position = TerminalScrollbackPosition(scrollbarTotal: 500, scrollbarOffset: 100, viewportRows: 24)

        XCTAssertEqual(position.rowsFromLiveBottom, 376, "the rows hidden below the viewport are what the control jumps over")
        XCTAssertTrue(position.isScrolledIntoScrollback)
    }

    func testOneRowOfScrollbackBelowTheViewportCountsAsScrolledBack() {
        let position = TerminalScrollbackPosition(scrollbarTotal: 25, scrollbarOffset: 0, viewportRows: 24)

        XCTAssertEqual(position.rowsFromLiveBottom, 1)
        XCTAssertTrue(position.isScrolledIntoScrollback, "output one row below the viewport is output the user cannot see")
    }

    /// Ghostty reports a session with no scrollback as total == rows at offset 0, which is the live
    /// bottom. Reading that as "scrolled back by a screen" would leave the control on screen in every
    /// terminal that has never scrolled.
    func testSessionWithNoScrollbackIsAtTheLiveBottom() {
        let position = TerminalScrollbackPosition(scrollbarTotal: 24, scrollbarOffset: 0, viewportRows: 24)

        XCTAssertFalse(position.isScrolledIntoScrollback)
    }

    /// A frame carrying no scrollbar state at all: an ended pane's transcript replay exports none, and
    /// a viewport taller than the region it reports is at the bottom, never past it.
    func testFrameWithoutScrollbarStateIsAtTheLiveBottom() {
        let position = TerminalScrollbackPosition(scrollbarTotal: 0, scrollbarOffset: 0, viewportRows: 24)

        XCTAssertEqual(position.rowsFromLiveBottom, 0)
        XCTAssertFalse(position.isScrolledIntoScrollback)
    }

    func testPositionOfSnapshotReadsTheSnapshotsOwnViewportHeight() {
        let scrolledBack = makeSnapshot(rows: 10, scrollbarTotal: 100, scrollbarOffset: 40)

        XCTAssertEqual(TerminalScrollbackPosition.position(of: scrolledBack).rowsFromLiveBottom, 50)
        XCTAssertTrue(TerminalScrollbackPosition.position(of: scrolledBack).isScrolledIntoScrollback)

        let atBottom = makeSnapshot(rows: 10, scrollbarTotal: 100, scrollbarOffset: 90)

        XCTAssertFalse(
            TerminalScrollbackPosition.position(of: atBottom).isScrolledIntoScrollback,
            "a frame whose last row is the session's last row must hide the control again")
    }

    func testPaneWithNoFrameIsAtTheLiveBottom() {
        XCTAssertFalse(
            TerminalScrollbackPosition.position(of: nil).isScrolledIntoScrollback, "a pane with nothing rendered has no scrollback to be inside of")
    }

    private func makeSnapshot(rows: Int, scrollbarTotal: UInt32, scrollbarOffset: UInt32) -> GhosttyTerminalSnapshot {
        let cells = (0..<rows).map { _ in GhosttyTerminalSnapshot.Cell(codepoint: 32, foregroundRGB: 0xFFFFFF, backgroundRGB: 0, flags: 0) }
        return GhosttyTerminalSnapshot(
            columns: 1, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0xFFFFFF, defaultBackgroundRGB: 0,
            cells: cells, scrollbarTotal: scrollbarTotal, scrollbarOffset: scrollbarOffset)
    }
}
