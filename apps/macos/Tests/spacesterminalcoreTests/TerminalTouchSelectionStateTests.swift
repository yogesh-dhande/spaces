import Testing

@testable import spacesterminalcore

/// The selection a touch client holds: how a long press and a handle grow it, and what ends it.
@Suite struct TerminalTouchSelectionStateTests {
    private func cell(_ column: Int, _ row: Int64) -> TerminalAbsoluteCell { TerminalAbsoluteCell(column: column, row: row) }

    private func selection(_ first: TerminalAbsoluteCell, _ second: TerminalAbsoluteCell, epoch: UInt64 = 4) -> TerminalAbsoluteSelection {
        TerminalAbsoluteSelection(from: first, to: second, isRectangle: false, historyEpoch: epoch)
    }

    @Test func aLongPressSelectsAWordAndTheDragExtendsItByCell() {
        var state = TerminalTouchSelectionState()

        state.beginWordSelection(selection(cell(2, 50), cell(6, 50)))
        #expect(state.selection == selection(cell(2, 50), cell(6, 50)))
        #expect(state.isDragging)

        state.extendDrag(to: cell(10, 51))
        #expect(state.selection == selection(cell(2, 50), cell(10, 51)))

        state.endDrag()
        #expect(!state.isDragging)
        #expect(state.selection == selection(cell(2, 50), cell(10, 51)))
    }

    @Test func aFingerThatMovesAfterTheDragEndedChangesNothing() {
        var state = TerminalTouchSelectionState()
        state.beginWordSelection(selection(cell(2, 50), cell(6, 50)))
        state.endDrag()

        state.extendDrag(to: cell(30, 60))

        #expect(state.selection == selection(cell(2, 50), cell(6, 50)))
    }

    @Test func draggingEachHandleAdjustsThatEndOnly() {
        var state = TerminalTouchSelectionState()
        state.beginWordSelection(selection(cell(2, 50), cell(6, 52)))
        state.endDrag()

        state.beginHandleDrag(.start)
        state.extendDrag(to: cell(0, 49))
        state.endDrag()
        #expect(state.selection == selection(cell(0, 49), cell(6, 52)))

        state.beginHandleDrag(.end)
        state.extendDrag(to: cell(12, 53))
        state.endDrag()
        #expect(state.selection == selection(cell(0, 49), cell(12, 53)))
    }

    @Test func aHandleDragNeedsASelection() {
        var state = TerminalTouchSelectionState()

        state.beginHandleDrag(.start)

        #expect(!state.isDragging)
        #expect(state.selection == nil)
    }

    @Test func selectAllReplacesTheSelectionWithNoDragBehindIt() {
        var state = TerminalTouchSelectionState()
        state.beginWordSelection(selection(cell(2, 50), cell(6, 50)))

        state.replace(with: selection(cell(0, 0), cell(79, 99)))

        #expect(state.selection == selection(cell(0, 0), cell(79, 99)))
        #expect(!state.isDragging)
    }

    @Test func clearingEndsTheSelectionAndTheDrag() {
        var state = TerminalTouchSelectionState()
        state.beginWordSelection(selection(cell(2, 50), cell(6, 50)))

        state.clear()

        #expect(state.selection == nil)
        #expect(!state.isDragging)
    }

    @Test func aShownFrameOfAnotherEpochEndsTheSelection() {
        var state = TerminalTouchSelectionState()
        state.beginWordSelection(selection(cell(2, 50), cell(6, 50), epoch: 4))

        state.noteShownFrameEpoch(4)
        #expect(state.selection != nil)

        state.noteShownFrameEpoch(5)
        #expect(state.selection == nil)
        #expect(!state.isDragging)
    }

    @Test func aLiveEpochChangeEndsASelectionMadeInThePreviousLiveEpoch() {
        var state = TerminalTouchSelectionState()
        state.noteLiveFrameEpoch(4)
        state.beginWordSelection(selection(cell(2, 50), cell(6, 50), epoch: 4))

        state.noteLiveFrameEpoch(4)
        #expect(state.selection != nil)

        state.noteLiveFrameEpoch(5)
        #expect(state.selection == nil)
    }

    @Test func aLiveEpochChangeKeepsASelectionMadeOnAnUnalignedReplay() {
        var state = TerminalTouchSelectionState()
        state.noteLiveFrameEpoch(4)
        state.beginWordSelection(selection(cell(2, 50), cell(6, 50), epoch: 987_654))

        state.noteLiveFrameEpoch(5)

        #expect(state.selection != nil)
    }

    @Test func theFirstLiveFrameEndsNothing() {
        var state = TerminalTouchSelectionState()
        state.beginWordSelection(selection(cell(2, 50), cell(6, 50), epoch: 4))

        state.noteLiveFrameEpoch(9)

        #expect(state.selection != nil)
    }
}
