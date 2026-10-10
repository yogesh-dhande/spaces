import Testing

@testable import spacesterminalcore

@Suite struct TerminalAbsoluteSelectionTests {
    private func cell(_ column: Int, _ row: Int64) -> TerminalAbsoluteCell { TerminalAbsoluteCell(column: column, row: row) }

    private func snapshot(base: UInt64, epoch: UInt64 = 5, columns: Int = 80, rows: Int = 24) -> GhosttyTerminalSnapshot {
        GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0, defaultBackgroundRGB: 0,
            cells: [], historyRowBase: base, historyEpoch: epoch)
    }

    private func selection(from first: TerminalAbsoluteCell, to second: TerminalAbsoluteCell, isRectangle: Bool = false, epoch: UInt64 = 5)
        -> TerminalAbsoluteSelection
    { TerminalAbsoluteSelection(from: first, to: second, isRectangle: isRectangle, historyEpoch: epoch) }

    // MARK: - Ordering

    @Test func aStreamSelectionOrdersItsEndsInReadingOrder() {
        let forward = selection(from: cell(5, 10), to: cell(2, 12))
        let backward = selection(from: cell(2, 12), to: cell(5, 10))

        #expect(forward == backward)
        #expect(forward.start == cell(5, 10))
        #expect(forward.end == cell(2, 12))
    }

    @Test func aRectangleOrdersItsRowsAndNormalizesItsColumnBand() {
        let dragged = selection(from: cell(30, 14), to: cell(10, 12), isRectangle: true)

        #expect(dragged.start == cell(10, 12))
        #expect(dragged.end == cell(30, 14))
    }

    // MARK: - Projection

    @Test func aSelectionFollowsItsTextAsTheFrameBaseGrows() {
        let held = selection(from: cell(3, 100), to: cell(7, 102))

        #expect(held.projection(onto: snapshot(base: 98))?.startRow == 2)
        #expect(held.projection(onto: snapshot(base: 98))?.endRow == 4)
        #expect(held.projection(onto: snapshot(base: 100))?.startRow == 0)
        let scrolledPast = held.projection(onto: snapshot(base: 101))
        #expect(scrolledPast?.startRow == 0)
        #expect(scrolledPast?.endRow == 1)
        #expect(scrolledPast?.extendsAbove == true)
        #expect(scrolledPast?.startColumn == 0, "the true start is above the viewport, so the first visible row is full width")
    }

    @Test func aSelectionIsClippedAtBothEdgesOfTheFrame() {
        let held = selection(from: cell(3, 100), to: cell(7, 140))

        let projected = held.projection(onto: snapshot(base: 110, rows: 10))

        #expect(projected?.extendsAbove == true)
        #expect(projected?.extendsBelow == true)
        #expect(projected?.startRow == 0)
        #expect(projected?.endRow == 9)
    }

    @Test func aSelectionOutsideTheFrameProjectsToNothing() {
        let held = selection(from: cell(3, 100), to: cell(7, 102))

        #expect(held.projection(onto: snapshot(base: 103)) == nil)
        #expect(held.projection(onto: snapshot(base: 70, rows: 24)) == nil)
    }

    @Test func aFrameFromAnotherEpochProjectsToNothing() {
        let held = selection(from: cell(3, 100), to: cell(7, 102), epoch: 5)

        #expect(held.projection(onto: snapshot(base: 100, epoch: 6)) == nil)
    }

    @Test func aRectangleKeepsItsColumnBandAcrossTheProjection() {
        let held = selection(from: cell(30, 100), to: cell(10, 104), isRectangle: true)

        let projected = held.projection(onto: snapshot(base: 102))

        #expect(projected?.isRectangle == true)
        #expect(projected?.startColumn == 10)
        #expect(projected?.endColumn == 30)
        #expect(projected?.startRow == 0)
        #expect(projected?.endRow == 2)
        #expect(projected?.extendsAbove == true)
    }

    @Test func clientSelectionReplacesTheSnapshotsSelectionAndNothingElse() {
        let base = snapshot(base: 100)
        let held = selection(from: cell(3, 101), to: cell(7, 102))

        let painted = base.withClientSelection(held)

        #expect(painted.selection == held.projection(onto: base))
        #expect(painted.historyRowBase == base.historyRowBase)
        #expect(painted.historyEpoch == base.historyEpoch)
        #expect(painted.columns == base.columns)
        #expect(base.withClientSelection(nil).selection == nil)
    }
}
