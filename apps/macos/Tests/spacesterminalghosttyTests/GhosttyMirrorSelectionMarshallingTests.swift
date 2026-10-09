import Testing

@testable import spacesterminalcore
@testable import spacesterminalghostty

/// Pins the pure marshalling math `GhosttyMirrorTerminalView` leans on to paint the client's selection:
/// none of it needs a live surface, a window, or the main actor, so it is exercised directly here
/// instead of through the view.
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

}
