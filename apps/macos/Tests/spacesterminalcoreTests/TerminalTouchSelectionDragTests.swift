import Testing

@testable import spacesterminalcore

/// A touch drag's selection: a pressed word extended by cell, and a handle moved to a new cell.
@Suite struct TerminalTouchSelectionDragTests {
    private let epoch: UInt64 = 9

    private func cell(_ column: Int, _ row: Int64) -> TerminalAbsoluteCell { TerminalAbsoluteCell(column: column, row: row) }

    private func selection(_ first: TerminalAbsoluteCell, _ second: TerminalAbsoluteCell) -> TerminalAbsoluteSelection {
        TerminalAbsoluteSelection(from: first, to: second, isRectangle: false, historyEpoch: epoch)
    }

    // MARK: - A long press that selected a word

    @Test func thePointerInsideTheWordKeepsTheWordWhole() {
        let word = selection(cell(4, 100), cell(8, 100))
        let drag = TerminalTouchSelectionDrag(word: word)

        #expect(drag.selection(pointerAt: cell(6, 100)) == word)
        #expect(drag.selection(pointerAt: cell(4, 100)) == word)
        #expect(drag.selection(pointerAt: cell(8, 100)) == word)
    }

    @Test func thePointerAfterTheWordExtendsItsEndByCell() {
        let drag = TerminalTouchSelectionDrag(word: selection(cell(4, 100), cell(8, 100)))

        #expect(drag.selection(pointerAt: cell(12, 100)) == selection(cell(4, 100), cell(12, 100)))
        #expect(drag.selection(pointerAt: cell(2, 103)) == selection(cell(4, 100), cell(2, 103)))
    }

    @Test func thePointerBeforeTheWordExtendsItsStartByCell() {
        let drag = TerminalTouchSelectionDrag(word: selection(cell(4, 100), cell(8, 100)))

        #expect(drag.selection(pointerAt: cell(1, 100)) == selection(cell(1, 100), cell(8, 100)))
        #expect(drag.selection(pointerAt: cell(30, 98)) == selection(cell(30, 98), cell(8, 100)))
    }

    @Test func draggingBackAcrossTheWordFlipsTheSelectionInsteadOfCollapsingIt() {
        let drag = TerminalTouchSelectionDrag(word: selection(cell(4, 100), cell(8, 100)))

        #expect(drag.selection(pointerAt: cell(12, 100)).end == cell(12, 100))
        #expect(drag.selection(pointerAt: cell(0, 100)) == selection(cell(0, 100), cell(8, 100)))
    }

    @Test func aPointerAboveOrBelowTheViewportExtendsIntoRowsNoFrameShows() {
        let drag = TerminalTouchSelectionDrag(word: selection(cell(4, 100), cell(8, 100)))

        #expect(drag.selection(pointerAt: cell(0, 90)).start == cell(0, 90))
        #expect(drag.selection(pointerAt: cell(0, 130)).end == cell(0, 130))
    }

    // MARK: - A handle drag

    @Test func movingTheStartHandleKeepsTheEndFixed() {
        let current = selection(cell(4, 100), cell(8, 102))
        let drag = TerminalTouchSelectionDrag(moving: .start, of: current)

        #expect(drag.selection(pointerAt: cell(1, 99)) == selection(cell(1, 99), cell(8, 102)))
        #expect(drag.selection(pointerAt: cell(6, 101)) == selection(cell(6, 101), cell(8, 102)))
    }

    @Test func movingTheEndHandleKeepsTheStartFixed() {
        let current = selection(cell(4, 100), cell(8, 102))
        let drag = TerminalTouchSelectionDrag(moving: .end, of: current)

        #expect(drag.selection(pointerAt: cell(20, 105)) == selection(cell(4, 100), cell(20, 105)))
        #expect(drag.selection(pointerAt: cell(5, 100)) == selection(cell(4, 100), cell(5, 100)))
    }

    @Test func aHandleDraggedPastTheOtherEndSwapsWhichSideItIsOn() {
        let current = selection(cell(4, 100), cell(8, 102))
        let drag = TerminalTouchSelectionDrag(moving: .start, of: current)

        #expect(drag.selection(pointerAt: cell(3, 104)) == selection(cell(8, 102), cell(3, 104)))
    }

    @Test func theDragKeepsTheEpochOfTheSelectionItGrowsFrom() {
        #expect(TerminalTouchSelectionDrag(word: selection(cell(0, 1), cell(1, 1))).historyEpoch == epoch)
        #expect(
            TerminalTouchSelectionDrag(moving: .end, of: selection(cell(0, 1), cell(1, 1))).selection(pointerAt: cell(5, 1)).historyEpoch == epoch)
    }
}
