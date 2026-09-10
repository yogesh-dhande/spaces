#if canImport(UIKit)
    import CoreGraphics
    import XCTest
    import spacesterminalcore
    @testable import SpacesMobile

    /// Pure placement math for the Copy pill offered while the daemon's shared selection is present
    /// (`TerminalSelectionCopyPillLayout`). No SwiftUI, UIKit, or live terminal surface is needed to pin
    /// the anchor rule, so it is exercised directly here rather than through `TerminalDetailView`.
    final class TerminalSelectionCopyPillLayoutTests: XCTestCase {
        private func selection(
            startColumn: UInt16 = 0, startRow: UInt16, endColumn: UInt16, endRow: UInt16, isRectangle: Bool = false, extendsAbove: Bool = false,
            extendsBelow: Bool = false
        ) -> GhosttyTerminalSelectionRange {
            GhosttyTerminalSelectionRange(
                startColumn: startColumn, startRow: startRow, endColumn: endColumn, endRow: endRow, isRectangle: isRectangle,
                extendsAbove: extendsAbove, extendsBelow: extendsBelow)
        }

        func testAnchorSitsAboveTheEndRowRightAlignedOneColumnPastTheSelection() {
            let range = selection(startRow: 5, endColumn: 10, endRow: 8)

            let anchor = TerminalSelectionCopyPillLayout.anchor(
                for: range, columns: 80, rows: 24, contentOrigin: CGPoint(x: 8, y: 6), cellWidth: 10, cellHeight: 20)

            XCTAssertEqual(anchor, .init(point: CGPoint(x: 118, y: 166), flipsBelow: false))
        }

        func testAnchorFlipsBelowWhenTheSelectionStartsAtTheTopRow() {
            let range = selection(startRow: 0, endColumn: 5, endRow: 3)

            let anchor = TerminalSelectionCopyPillLayout.anchor(
                for: range, columns: 80, rows: 24, contentOrigin: CGPoint(x: 8, y: 6), cellWidth: 10, cellHeight: 20)

            XCTAssertEqual(anchor, .init(point: CGPoint(x: 68, y: 86), flipsBelow: true))
        }

        /// A selection that continues into scrollback above this viewport's top row flips below even when
        /// its (viewport-local) start row is not literally row 0: `extendsAbove` is what actually means
        /// "the daemon's selection keeps going further up than what this frame shows."
        func testAnchorFlipsBelowWhenTheSelectionExtendsAboveTheViewport() {
            let range = selection(startRow: 5, endColumn: 2, endRow: 9, extendsAbove: true)

            let anchor = TerminalSelectionCopyPillLayout.anchor(for: range, columns: 80, rows: 24, contentOrigin: .zero, cellWidth: 8, cellHeight: 16)

            XCTAssertEqual(anchor, .init(point: CGPoint(x: 24, y: 160), flipsBelow: true))
        }

        /// A selection reaching the grid's last column anchors flush with the right edge rather than one
        /// column past it: the "+1" is clamped to the grid width, not left to overflow.
        func testAnchorClampsToTheGridsRightEdgeWhenTheSelectionEndsAtTheLastColumn() {
            let range = selection(startRow: 1, endColumn: 39, endRow: 2)

            let anchor = TerminalSelectionCopyPillLayout.anchor(for: range, columns: 40, rows: 24, contentOrigin: .zero, cellWidth: 10, cellHeight: 20)

            XCTAssertEqual(anchor?.point.x, 400, "40 columns * 10pt must not be pushed past the grid's own right edge")
        }

        /// A highlight touching both the top and the last viewport row (a select-all from the Mac, say)
        /// has no room below either, so the flip is skipped and the pill sits above the end row over the
        /// selection's tail rather than rendering past the bottom edge, off screen.
        func testAnchorStaysAboveWhenAFlippedPillWouldFallPastTheLastRow() {
            let range = selection(startRow: 0, endColumn: 10, endRow: 23, extendsAbove: true)

            let anchor = TerminalSelectionCopyPillLayout.anchor(for: range, columns: 80, rows: 24, contentOrigin: .zero, cellWidth: 10, cellHeight: 20)

            XCTAssertEqual(anchor, .init(point: CGPoint(x: 110, y: 460), flipsBelow: false))
        }

        func testAnchorForSelectionIsNilWhenColumnsOrCellMetricsAreInvalid() {
            let range = selection(startRow: 1, endColumn: 2, endRow: 2)

            XCTAssertNil(TerminalSelectionCopyPillLayout.anchor(for: range, columns: 0, rows: 24, contentOrigin: .zero, cellWidth: 10, cellHeight: 20))
            XCTAssertNil(TerminalSelectionCopyPillLayout.anchor(for: range, columns: 80, rows: 24, contentOrigin: .zero, cellWidth: 0, cellHeight: 20))
            XCTAssertNil(TerminalSelectionCopyPillLayout.anchor(for: range, columns: 80, rows: 0, contentOrigin: .zero, cellWidth: 10, cellHeight: 20))
            XCTAssertNil(TerminalSelectionCopyPillLayout.anchor(for: range, columns: 80, rows: 24, contentOrigin: .zero, cellWidth: 10, cellHeight: 0))
        }

        private func snapshot(
            columns: Int, rows: Int, selection: GhosttyTerminalSelectionRange?, scrollbarTotal: UInt32 = 0, scrollbarOffset: UInt32 = 0
        ) -> GhosttyTerminalSnapshot {
            GhosttyTerminalSnapshot(
                columns: columns, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xF2F2F2,
                defaultBackgroundRGB: 0x1A1E26,
                cells: (0..<(columns * rows)).map { _ in
                    GhosttyTerminalSnapshot.Cell(codepoint: 0x20, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0)
                }, selection: selection, scrollbarTotal: scrollbarTotal, scrollbarOffset: scrollbarOffset)
        }

        func testAnchorFromSnapshotIsNilWhenTheFrameCarriesNoSelection() {
            let grid = snapshot(columns: 40, rows: 10, selection: nil)
            let window = GhosttyTerminalSnapshotViewport.window(for: grid, columns: 40, rows: 10, horizontalAlignment: .leading)

            let anchor = TerminalSelectionCopyPillLayout.anchor(snapshot: grid, window: window, contentOrigin: .zero, cellWidth: 10, cellHeight: 20)

            XCTAssertNil(anchor)
        }

        /// A snapshot already sized to the viewport crops to itself, so the anchor matches the pure
        /// selection-only rule exactly: this is the seam `TerminalDetailView`'s overlay reads every frame.
        func testAnchorFromSnapshotMatchesThePureSelectionRuleWhenTheSnapshotFillsTheViewport() {
            let range = selection(startRow: 2, endColumn: 4, endRow: 3)
            let grid = snapshot(columns: 40, rows: 10, selection: range)
            let window = GhosttyTerminalSnapshotViewport.window(for: grid, columns: 40, rows: 10, horizontalAlignment: .leading)

            let anchor = TerminalSelectionCopyPillLayout.anchor(
                snapshot: grid, window: window, contentOrigin: CGPoint(x: 8, y: 6), cellWidth: 10, cellHeight: 20)

            let expected = TerminalSelectionCopyPillLayout.anchor(
                for: range, columns: 40, rows: 10, contentOrigin: CGPoint(x: 8, y: 6), cellWidth: 10, cellHeight: 20)
            XCTAssertEqual(anchor, expected)
        }

        func testAnchorFromSnapshotIsNilWhenTheWindowHasNoColumnsOrRows() {
            let range = selection(startRow: 0, endColumn: 1, endRow: 0)
            let grid = snapshot(columns: 40, rows: 10, selection: range)

            XCTAssertNil(
                TerminalSelectionCopyPillLayout.anchor(
                    snapshot: grid, window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 0, rowOffset: 0, columns: 0, rows: 10),
                    contentOrigin: .zero, cellWidth: 10, cellHeight: 20))
            XCTAssertNil(
                TerminalSelectionCopyPillLayout.anchor(
                    snapshot: grid, window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 0, rowOffset: 0, columns: 40, rows: 0),
                    contentOrigin: .zero, cellWidth: 10, cellHeight: 20))
        }

        /// While scrolled back with a row offset carried over from the frame before it -- exactly what the
        /// software keyboard produces, and what a plain scroll produces on its own -- the pill has to crop
        /// against the window the surface actually rendered, not one recomputed at row offset 0. A
        /// selection that sits only inside the retained window's rows would otherwise anchor nowhere near
        /// the highlight, or (as tested here) not appear at all.
        func testAnchorFromSnapshotCropsWithTheGivenWindowRatherThanRecomputingOneAtRowOffsetZero() {
            let range = selection(startRow: 25, endColumn: 10, endRow: 25)
            let grid = snapshot(columns: 40, rows: 40, selection: range, scrollbarTotal: 200, scrollbarOffset: 50)

            let renderedWindow = GhosttyTerminalSnapshotViewport.window(
                for: grid, columns: 40, rows: 20, horizontalAlignment: .leading, retainedRowOffset: 12)
            XCTAssertEqual(renderedWindow.rowOffset, 12, "a scrolled-back frame keeps the offset the last render was drawn at")

            let anchor = TerminalSelectionCopyPillLayout.anchor(
                snapshot: grid, window: renderedWindow, contentOrigin: .zero, cellWidth: 10, cellHeight: 20)
            XCTAssertEqual(
                anchor, .init(point: CGPoint(x: 110, y: 260), flipsBelow: false),
                "row 25 sits at local row 13 under the actual rendered window (25 minus its 12-row offset)")

            let windowRecomputedAtRowOffsetZero = GhosttyTerminalSnapshotViewport.window(
                for: grid, columns: 40, rows: 20, horizontalAlignment: .leading, retainedRowOffset: 0)
            XCTAssertEqual(windowRecomputedAtRowOffsetZero.rowOffset, 0)
            XCTAssertNil(
                TerminalSelectionCopyPillLayout.anchor(
                    snapshot: grid, window: windowRecomputedAtRowOffsetZero, contentOrigin: .zero, cellWidth: 10, cellHeight: 20),
                "a window recomputed at row offset 0 shows none of the selection at all, proving the two windows disagree")
        }

        func testOriginMatchesTheUnclampedMathForAMidGridAnchor() {
            let anchor = TerminalSelectionCopyPillLayout.Anchor(point: CGPoint(x: 118, y: 166), flipsBelow: false)

            let origin = TerminalSelectionCopyPillLayout.origin(
                anchor: anchor, pillSize: CGSize(width: 60, height: 30), gap: 6, contentOrigin: CGPoint(x: 8, y: 6),
                gridSize: CGSize(width: 800, height: 480))

            XCTAssertEqual(origin, CGPoint(x: 58, y: 130), "well within the grid, so the clamp must not move it")
        }

        /// A selection ending at (or near) column 0 pushes the unclamped x negative, since the pill sits
        /// entirely to the left of the anchor; the clamp pins it to the grid's leading edge instead of
        /// letting it run off screen.
        func testOriginClampsXToTheGridsLeadingEdgeWhenTheUnclampedOriginWouldGoNegative() {
            let anchor = TerminalSelectionCopyPillLayout.Anchor(point: CGPoint(x: 8, y: 100), flipsBelow: false)

            let origin = TerminalSelectionCopyPillLayout.origin(
                anchor: anchor, pillSize: CGSize(width: 60, height: 30), gap: 6, contentOrigin: CGPoint(x: 8, y: 6),
                gridSize: CGSize(width: 800, height: 480))

            XCTAssertEqual(origin, CGPoint(x: 8, y: 64))
        }

        /// A not-flipped anchor on row 1 has too little room above it for the pill's height, so the
        /// unclamped y goes above the grid's top edge; the clamp pins it to the grid's top instead.
        func testOriginClampsYToTheGridsTopEdgeWhenANotFlippedPillWouldRiseAboveTheGrid() {
            let anchor = TerminalSelectionCopyPillLayout.Anchor(point: CGPoint(x: 118, y: 26), flipsBelow: false)

            let origin = TerminalSelectionCopyPillLayout.origin(
                anchor: anchor, pillSize: CGSize(width: 60, height: 40), gap: 6, contentOrigin: CGPoint(x: 8, y: 6),
                gridSize: CGSize(width: 800, height: 480))

            XCTAssertEqual(origin, CGPoint(x: 58, y: 6))
        }

        /// A flipped anchor near the grid's last row would otherwise place the pill's bottom edge past the
        /// grid; the clamp pins the origin so the pill's bottom lands exactly on the grid's bottom edge.
        func testOriginClampsAFlippedPillNearTheLastRowSoItsBottomStaysInsideTheGrid() {
            let anchor = TerminalSelectionCopyPillLayout.Anchor(point: CGPoint(x: 118, y: 470), flipsBelow: true)

            let origin = TerminalSelectionCopyPillLayout.origin(
                anchor: anchor, pillSize: CGSize(width: 60, height: 30), gap: 6, contentOrigin: CGPoint(x: 8, y: 6),
                gridSize: CGSize(width: 800, height: 480))

            XCTAssertEqual(origin, CGPoint(x: 58, y: 456), "6 + 480 - 30 = 456, so the pill's bottom lands on the grid's own bottom edge")
        }

        /// A zero pill size (the first frame before `SelectionCopyPillSizePreferenceKey` reports a measured
        /// size) still clamps into the grid rather than producing a point outside it.
        func testOriginWithAZeroPillSizeStillClampsIntoTheGrid() {
            let anchor = TerminalSelectionCopyPillLayout.Anchor(point: CGPoint(x: -10, y: 50), flipsBelow: false)

            let origin = TerminalSelectionCopyPillLayout.origin(
                anchor: anchor, pillSize: .zero, gap: 0, contentOrigin: .zero, gridSize: CGSize(width: 200, height: 200))

            XCTAssertEqual(origin, CGPoint(x: 0, y: 50))
        }
    }
#endif
