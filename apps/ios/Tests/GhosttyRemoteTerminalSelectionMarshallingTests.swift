#if canImport(UIKit)
    import XCTest
    import spacesterminalcore
    @testable import spacesterminalmobileghostty

    /// Pins the pure C-frame marshalling `GhosttyRemoteTerminalHostView.withCFrame` leans on for the
    /// host-anchored shared selection: none of it needs a live surface, a window, or the main actor, so
    /// it is exercised directly here instead of through the view. Mirrors
    /// `GhosttyMirrorSelectionMarshallingTests` on the macOS side, minus the scroll-rect carry buffer and
    /// absolute-row conversion the iOS mirror has no use for (iOS never drags a local selection).
    final class GhosttyRemoteTerminalSelectionMarshallingTests: XCTestCase {
        func testNilSelectionMapsToAllZeroFieldsWithScrollbarPassthrough() {
            let fields = GhosttyRemoteTerminalSelectionMarshalling.cSnapshotSelectionFields(selection: nil, scrollbarTotal: 500, scrollbarOffset: 12)

            XCTAssertEqual(
                fields,
                .init(
                    selectionFlags: 0, selectionStartX: 0, selectionStartY: 0, selectionEndX: 0, selectionEndY: 0, scrollbarTotal: 500,
                    scrollbarOffset: 12))
        }

        func testPresentSelectionSetsPresentFlagAndCopiesCoordinates() {
            let selection = GhosttyTerminalSelectionRange(
                startColumn: 3, startRow: 10, endColumn: 20, endRow: 15, isRectangle: false, extendsAbove: false, extendsBelow: false)

            let fields = GhosttyRemoteTerminalSelectionMarshalling.cSnapshotSelectionFields(
                selection: selection, scrollbarTotal: 0, scrollbarOffset: 0)

            XCTAssertEqual(fields.selectionFlags, GhosttyRemoteTerminalSelectionMarshalling.selectionFlagPresent)
            XCTAssertEqual(fields.selectionStartX, 3)
            XCTAssertEqual(fields.selectionStartY, 10)
            XCTAssertEqual(fields.selectionEndX, 20)
            XCTAssertEqual(fields.selectionEndY, 15)
        }

        func testRectangleAndExtendFlagsCombineWithPresent() {
            let selection = GhosttyTerminalSelectionRange(
                startColumn: 0, startRow: 0, endColumn: 0, endRow: 0, isRectangle: true, extendsAbove: true, extendsBelow: true)

            let fields = GhosttyRemoteTerminalSelectionMarshalling.cSnapshotSelectionFields(
                selection: selection, scrollbarTotal: 0, scrollbarOffset: 0)

            let expectedFlags =
                GhosttyRemoteTerminalSelectionMarshalling.selectionFlagPresent | GhosttyRemoteTerminalSelectionMarshalling.selectionFlagRectangle
                | GhosttyRemoteTerminalSelectionMarshalling.selectionFlagExtendsAbove
                | GhosttyRemoteTerminalSelectionMarshalling.selectionFlagExtendsBelow
            XCTAssertEqual(fields.selectionFlags, expectedFlags)
        }

        /// A selection that is present but neither a rectangle nor extending past this viewport carries
        /// only the present bit: the marshalling must not set a flag the daemon never asked for.
        func testStreamSelectionWithNoExtendCarriesOnlyThePresentFlag() {
            let selection = GhosttyTerminalSelectionRange(
                startColumn: 1, startRow: 2, endColumn: 8, endRow: 4, isRectangle: false, extendsAbove: false, extendsBelow: false)

            let fields = GhosttyRemoteTerminalSelectionMarshalling.cSnapshotSelectionFields(
                selection: selection, scrollbarTotal: 0, scrollbarOffset: 0)

            XCTAssertEqual(fields.selectionFlags, GhosttyRemoteTerminalSelectionMarshalling.selectionFlagPresent)
        }
    }

#endif
