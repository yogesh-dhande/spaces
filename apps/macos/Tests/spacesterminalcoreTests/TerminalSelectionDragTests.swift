import Testing

@testable import spacesterminalcore

/// The anchor-side merge for a drag whose anchor scrolls off the grid. Frames are 20 columns by 10 rows;
/// a resolution is what Ghostty reported for the frame (ordered viewport cells).
@Suite struct TerminalSelectionDragTests {
    private let epoch: UInt64 = 5

    private func cell(_ column: Int, _ row: Int64) -> TerminalAbsoluteCell { TerminalAbsoluteCell(column: column, row: row) }

    private func frame(base: UInt64, epoch: UInt64 = 5) -> TerminalSelectionDragFrame {
        TerminalSelectionDragFrame(historyRowBase: base, historyEpoch: epoch, columns: 20, rows: 10)
    }

    private func resolution(_ start: (Int, Int), _ end: (Int, Int), rectangle: Bool = false) -> TerminalSelectionDragResolution {
        TerminalSelectionDragResolution(startColumn: start.0, startRow: start.1, endColumn: end.0, endRow: end.1, isRectangle: rectangle)
    }

    private func selection(_ first: TerminalAbsoluteCell, _ second: TerminalAbsoluteCell, rectangle: Bool = false) -> TerminalAbsoluteSelection {
        TerminalAbsoluteSelection(from: first, to: second, isRectangle: rectangle, historyEpoch: epoch)
    }

    // MARK: - Anchor geometry

    @Test func theAnchorsViewportRowIsSignedAndOnGridOnlyInsideTheFrame() {
        let drag = TerminalSelectionDrag(anchor: cell(5, 1003), historyEpoch: epoch)

        #expect(drag.anchorViewportRow(in: frame(base: 1000)) == 3)
        #expect(drag.anchorIsOnGrid(in: frame(base: 1000)))
        #expect(drag.anchorViewportRow(in: frame(base: 1005)) == -2)
        #expect(!drag.anchorIsOnGrid(in: frame(base: 1005)))
        #expect(drag.anchorViewportRow(in: frame(base: 990)) == 13)
        #expect(!drag.anchorIsOnGrid(in: frame(base: 990)))
        #expect(drag.anchorIsOnGrid(in: frame(base: 1003)))
        #expect(drag.anchorIsOnGrid(in: frame(base: 994)))
        #expect(!drag.anchorIsOnGrid(in: frame(base: 993)))
    }

    // MARK: - Anchor on the grid

    @Test func withTheAnchorOnTheGridGhosttysResultIsTheSelection() {
        var drag = TerminalSelectionDrag(anchor: cell(5, 1003), historyEpoch: epoch)

        let merged = drag.merge(resolution((5, 3), (12, 6)), pointerColumn: 12, pointerRow: 6, in: frame(base: 1000))

        #expect(merged == selection(cell(5, 1003), cell(12, 1006)))
    }

    @Test func aClickWithoutMovementIsNoSelection() {
        var drag = TerminalSelectionDrag(anchor: cell(5, 1003), historyEpoch: epoch)

        #expect(drag.merge(nil, pointerColumn: 5, pointerRow: 3, in: frame(base: 1000)) == nil)
    }

    // MARK: - Anchor scrolls above the viewport

    @Test func aForwardDragKeepsTheAnchorSideWhenTheAnchorScrollsAbove() {
        var drag = TerminalSelectionDrag(anchor: cell(5, 1003), historyEpoch: epoch)
        _ = drag.merge(resolution((5, 3), (12, 6)), pointerColumn: 12, pointerRow: 6, in: frame(base: 1000))

        // Anchor now at viewport row -2: Ghostty seats the click on the top-left cell, so its start is the
        // stand-in (0, 0) and only its end is the pointer's.
        let merged = drag.merge(resolution((0, 0), (12, 8)), pointerColumn: 12, pointerRow: 8, in: frame(base: 1005))

        #expect(merged == selection(cell(5, 1003), cell(12, 1013)))
    }

    @Test func aWordDragKeepsTheWordsStartAsTheAnchorSide() {
        // Double-click inside the word spanning columns 8...13 of row 1005, then drag forward.
        var drag = TerminalSelectionDrag(anchor: cell(10, 1005), historyEpoch: epoch)
        let atAnchor = drag.merge(resolution((8, 5), (13, 5)), pointerColumn: 10, pointerRow: 5, in: frame(base: 1000))
        #expect(atAnchor == selection(cell(8, 1005), cell(13, 1005)))
        _ = drag.merge(resolution((8, 5), (19, 7)), pointerColumn: 18, pointerRow: 7, in: frame(base: 1000))

        let merged = drag.merge(resolution((0, 0), (15, 3)), pointerColumn: 14, pointerRow: 3, in: frame(base: 1008))

        #expect(merged == selection(cell(8, 1005), cell(15, 1011)))
    }

    @Test func withNoRecordedAnchorSideTheDragUsesThePressCell() {
        var drag = TerminalSelectionDrag(anchor: cell(5, 995), historyEpoch: epoch)

        let merged = drag.merge(resolution((0, 0), (9, 3)), pointerColumn: 9, pointerRow: 3, in: frame(base: 1000))

        #expect(merged == selection(cell(5, 995), cell(9, 1003)))
    }

    // MARK: - Anchor scrolls below the viewport

    @Test func aBackwardDragKeepsTheAnchorSideWhenTheAnchorScrollsBelow() {
        var drag = TerminalSelectionDrag(anchor: cell(10, 1005), historyEpoch: epoch)
        let atPointer = drag.merge(resolution((3, 2), (10, 5)), pointerColumn: 3, pointerRow: 2, in: frame(base: 1000))
        #expect(atPointer == selection(cell(3, 1002), cell(10, 1005)))

        // Anchor now at viewport row 15: the stand-in is the bottom-right cell, so Ghostty's end is the
        // stand-in and its start is the pointer's.
        let merged = drag.merge(resolution((4, 1), (19, 9)), pointerColumn: 4, pointerRow: 1, in: frame(base: 990))

        #expect(merged == selection(cell(4, 991), cell(10, 1005)))
    }

    @Test func aBackwardWordDragRecordsTheWordsEndAsTheAnchorSide() {
        var drag = TerminalSelectionDrag(anchor: cell(10, 1005), historyEpoch: epoch)
        _ = drag.merge(resolution((2, 3), (13, 5)), pointerColumn: 3, pointerRow: 3, in: frame(base: 1000))

        let merged = drag.merge(resolution((6, 0), (19, 9)), pointerColumn: 6, pointerRow: 0, in: frame(base: 992))

        #expect(merged == selection(cell(6, 992), cell(13, 1005)))
    }

    // MARK: - Rectangle

    @Test func aRectangleKeepsGhosttysColumnBandAndTheAnchorsRowWhenTheAnchorIsAbove() {
        var drag = TerminalSelectionDrag(anchor: cell(6, 1002), historyEpoch: epoch)
        let onGrid = drag.merge(resolution((6, 2), (12, 4), rectangle: true), pointerColumn: 12, pointerRow: 4, in: frame(base: 1000))
        #expect(onGrid == selection(cell(6, 1002), cell(12, 1004), rectangle: true))

        // The stand-in keeps the anchor's column, so Ghostty's band is right and its start row is row 0.
        let merged = drag.merge(resolution((6, 0), (14, 4), rectangle: true), pointerColumn: 14, pointerRow: 4, in: frame(base: 1005))

        #expect(merged == selection(cell(6, 1002), cell(14, 1009), rectangle: true))
        #expect(merged?.start == cell(6, 1002))
        #expect(merged?.end == cell(14, 1009))
    }

    @Test func aRectangleDraggedUpAndLeftKeepsTheAnchorsRowWhenTheAnchorIsBelow() {
        var drag = TerminalSelectionDrag(anchor: cell(12, 1006), historyEpoch: epoch)
        let onGrid = drag.merge(resolution((4, 2), (12, 6), rectangle: true), pointerColumn: 4, pointerRow: 2, in: frame(base: 1000))
        #expect(onGrid == selection(cell(4, 1002), cell(12, 1006), rectangle: true))

        let merged = drag.merge(resolution((4, 1), (12, 9), rectangle: true), pointerColumn: 4, pointerRow: 1, in: frame(base: 995))

        #expect(merged == selection(cell(4, 996), cell(12, 1006), rectangle: true))
    }

    // MARK: - Ghostty resolves nothing

    @Test func whileTheAnchorIsOffTheGridANoSelectionResolutionKeepsTheLastMergedSelection() {
        var drag = TerminalSelectionDrag(anchor: cell(5, 1003), historyEpoch: epoch)
        _ = drag.merge(resolution((5, 3), (12, 6)), pointerColumn: 12, pointerRow: 6, in: frame(base: 1000))
        let offGrid = drag.merge(resolution((0, 0), (12, 8)), pointerColumn: 12, pointerRow: 8, in: frame(base: 1005))

        // The pointer is inside the stand-in cell (0, 0): Ghostty resolves nothing.
        let kept = drag.merge(nil, pointerColumn: 0, pointerRow: 0, in: frame(base: 1005))

        #expect(kept == offGrid)
        #expect(kept != nil)
    }

    @Test func aNoSelectionResolutionBeforeAnySelectionStaysNoSelectionWhileTheAnchorIsOffTheGrid() {
        var drag = TerminalSelectionDrag(anchor: cell(5, 995), historyEpoch: epoch)

        #expect(drag.merge(nil, pointerColumn: 0, pointerRow: 0, in: frame(base: 1000)) == nil)
    }

    @Test func movingBackOntoTheAnchorCellOnTheGridClearsTheSelection() {
        var drag = TerminalSelectionDrag(anchor: cell(5, 1003), historyEpoch: epoch)
        _ = drag.merge(resolution((5, 3), (12, 6)), pointerColumn: 12, pointerRow: 6, in: frame(base: 1000))

        #expect(drag.merge(nil, pointerColumn: 5, pointerRow: 3, in: frame(base: 1000)) == nil)
    }

    // MARK: - Renumbered rows

    @Test func aFrameFromAnotherEpochEndsTheSelection() {
        var drag = TerminalSelectionDrag(anchor: cell(5, 1003), historyEpoch: epoch)
        _ = drag.merge(resolution((5, 3), (12, 6)), pointerColumn: 12, pointerRow: 6, in: frame(base: 1000))

        #expect(drag.merge(resolution((0, 0), (12, 8)), pointerColumn: 12, pointerRow: 8, in: frame(base: 1005, epoch: 6)) == nil)
        #expect(drag.merge(nil, pointerColumn: 0, pointerRow: 0, in: frame(base: 1005, epoch: 6)) == nil)
    }
}
