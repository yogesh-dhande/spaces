import Testing

@testable import spacesterminalcore
@testable import spacesterminalghostty

/// Pins the pure marshalling and carry-accumulation math `GhosttyMirrorTerminalView` leans on for the
/// host-anchored shared selection: none of it needs a live surface, a window, or the main actor, so it
/// is exercised directly here instead of through the view.
@Suite struct GhosttyMirrorSelectionMarshallingTests {
    @Test func nilSelectionMapsToAllZeroFieldsWithScrollbarPassthrough() {
        let fields = GhosttyMirrorSelectionMarshalling.cSnapshotSelectionFields(selection: nil, scrollbarTotal: 500, scrollbarOffset: 12)

        #expect(
            fields
                == .init(
                    selectionFlags: 0, selectionStartX: 0, selectionStartY: 0, selectionEndX: 0, selectionEndY: 0, scrollbarTotal: 500,
                    scrollbarOffset: 12))
    }

    @Test func presentSelectionSetsPresentFlagAndCopiesCoordinates() {
        let selection = GhosttyTerminalSelectionRange(
            startColumn: 3, startRow: 10, endColumn: 20, endRow: 15, isRectangle: false, extendsAbove: false, extendsBelow: false)

        let fields = GhosttyMirrorSelectionMarshalling.cSnapshotSelectionFields(selection: selection, scrollbarTotal: 0, scrollbarOffset: 0)

        #expect(fields.selectionFlags == GhosttyMirrorSelectionMarshalling.selectionFlagPresent)
        #expect(fields.selectionStartX == 3)
        #expect(fields.selectionStartY == 10)
        #expect(fields.selectionEndX == 20)
        #expect(fields.selectionEndY == 15)
    }

    @Test func rectangleAndExtendFlagsCombineWithPresent() {
        let selection = GhosttyTerminalSelectionRange(
            startColumn: 0, startRow: 0, endColumn: 0, endRow: 0, isRectangle: true, extendsAbove: true, extendsBelow: true)

        let fields = GhosttyMirrorSelectionMarshalling.cSnapshotSelectionFields(selection: selection, scrollbarTotal: 0, scrollbarOffset: 0)

        let expectedFlags =
            GhosttyMirrorSelectionMarshalling.selectionFlagPresent | GhosttyMirrorSelectionMarshalling.selectionFlagRectangle
            | GhosttyMirrorSelectionMarshalling.selectionFlagExtendsAbove | GhosttyMirrorSelectionMarshalling.selectionFlagExtendsBelow
        #expect(fields.selectionFlags == expectedFlags)
    }

    @Test func carryBufferAccumulatesRectsAcrossAppends() {
        var buffer = GhosttyMirrorSelectionMarshalling.ScrollRectCarryBuffer()
        let first = GhosttyRenderScrollRectOperation(rowStart: 0, rowCount: 1, columnStart: 0, columnCount: 80, deltaRows: -1, deltaColumns: 0)
        let second = GhosttyRenderScrollRectOperation(rowStart: 1, rowCount: 2, columnStart: 0, columnCount: 80, deltaRows: -2, deltaColumns: 0)

        buffer.append(rects: [first], overflowed: false)
        buffer.append(rects: [second], overflowed: false)

        #expect(buffer.rects == [first, second])
        #expect(buffer.isCarryValid)
    }

    @Test func anyOverflowedAppendPoisonsAndStaysPoisonedOnFurtherAppends() {
        var buffer = GhosttyMirrorSelectionMarshalling.ScrollRectCarryBuffer()
        buffer.append(rects: [], overflowed: true)
        #expect(!buffer.isCarryValid)

        let rect = GhosttyRenderScrollRectOperation(rowStart: 0, rowCount: 1, columnStart: 0, columnCount: 80, deltaRows: -1, deltaColumns: 0)
        buffer.append(rects: [rect], overflowed: false)
        #expect(!buffer.isCarryValid)
    }

    @Test func emptyUnpoisonedBufferIsValidCarry() {
        let buffer = GhosttyMirrorSelectionMarshalling.ScrollRectCarryBuffer()
        #expect(buffer.rects.isEmpty)
        #expect(buffer.isCarryValid)
    }

    @Test func clearResetsRectsAndPoisonedState() {
        var buffer = GhosttyMirrorSelectionMarshalling.ScrollRectCarryBuffer()
        buffer.append(rects: [], overflowed: true)

        buffer.clear()

        #expect(buffer.rects.isEmpty)
        #expect(buffer.isCarryValid)
    }

    @Test func absoluteSelectionRowAddsOffsetAndVirtualRow() {
        #expect(GhosttyMirrorSelectionMarshalling.absoluteSelectionRow(virtualRow: 5, scrollbarOffset: 100) == 105)
    }

    /// A local drag anchored above the mirror's own retained scrollback (a virtual row more negative
    /// than the current offset) has no meaningful absolute-space row: the daemon's oldest retained row,
    /// 0, is the closest one that does, and the arithmetic must clamp there rather than wrap through
    /// `UInt32` underflow.
    @Test func negativeVirtualRowLargerThanOffsetClampsToZero() {
        #expect(GhosttyMirrorSelectionMarshalling.absoluteSelectionRow(virtualRow: -50, scrollbarOffset: 10) == 0)
    }

    @Test func poisonedBufferDropsItsRectsAndTheCapPoisons() {
        var buffer = GhosttyMirrorSelectionMarshalling.ScrollRectCarryBuffer()
        buffer.append(rects: [GhosttyRenderScrollRectOperation(rowStart: 0, rowCount: 4, columnStart: 0, columnCount: 80, deltaRows: -1, deltaColumns: 0)], overflowed: true)
        #expect(buffer.poisoned)
        #expect(buffer.rects.isEmpty)

        var capped = GhosttyMirrorSelectionMarshalling.ScrollRectCarryBuffer()
        let rect = GhosttyRenderScrollRectOperation(rowStart: 0, rowCount: 4, columnStart: 0, columnCount: 80, deltaRows: -1, deltaColumns: 0)
        capped.append(rects: Array(repeating: rect, count: GhosttyMirrorSelectionMarshalling.ScrollRectCarryBuffer.maxCarriedRects + 1), overflowed: false)
        #expect(capped.poisoned)
        #expect(capped.rects.isEmpty)
        #expect(!capped.isCarryValid)
        capped.clear()
        #expect(capped.isCarryValid)
    }
}
