import XCTest

@testable import spacesterminalghostty

/// Where the hovered-link tooltip goes, in AppKit's unflipped coordinates (y grows upward, so "below"
/// a row is a smaller y).
final class TerminalLinkTooltipViewTests: XCTestCase {
    private let pane = NSRect(x: 0, y: 0, width: 600, height: 400)
    private let tooltip = NSSize(width: 200, height: 24)

    private func row(atTop top: CGFloat) -> NSRect { NSRect(x: 0, y: pane.maxY - top - 18, width: 600, height: 18) }

    func testSitsFourPointsBelowTheRowAndStartsLeftOfThePointerCell() {
        let rowRect = row(atTop: 100)
        let frame = TerminalLinkTooltipView.frame(paneBounds: pane, rowRect: rowRect, anchorX: 120, tooltipSize: tooltip)
        XCTAssertEqual(frame.minX, 116)
        XCTAssertEqual(frame.maxY, rowRect.minY - 4)
        XCTAssertEqual(frame.size, tooltip)
    }

    func testFlipsAboveTheRowWhenThereIsNoRoomBelow() {
        let rowRect = row(atTop: 380)
        let frame = TerminalLinkTooltipView.frame(paneBounds: pane, rowRect: rowRect, anchorX: 120, tooltipSize: tooltip)
        XCTAssertEqual(frame.minY, rowRect.maxY + 4)
    }

    func testClampsInsideTheLeftAndRightEdgesWithMargin() {
        let rowRect = row(atTop: 100)
        let left = TerminalLinkTooltipView.frame(paneBounds: pane, rowRect: rowRect, anchorX: 2, tooltipSize: tooltip)
        XCTAssertEqual(left.minX, 8)
        let right = TerminalLinkTooltipView.frame(paneBounds: pane, rowRect: rowRect, anchorX: 590, tooltipSize: tooltip)
        XCTAssertEqual(right.maxX, 592)
    }

    func testTargetWiderThanThePaneIsCappedToThePaneMinusMargins() {
        let frame = TerminalLinkTooltipView.frame(
            paneBounds: pane, rowRect: row(atTop: 100), anchorX: 300, tooltipSize: NSSize(width: 2_000, height: 24))
        XCTAssertEqual(frame.minX, 8)
        XCTAssertEqual(frame.width, 584)
    }
}
