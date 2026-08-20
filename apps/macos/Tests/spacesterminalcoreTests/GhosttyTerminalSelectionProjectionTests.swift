import Testing

@testable import spacesterminalcore

/// `GhosttyTerminalSelectionProjection.project` is the pure vertical crop the Linux headless core
/// uses every frame to rebase its screen-space selection (which can span scrollback the current
/// viewport does not show) into that frame's viewport coordinates. A realistic 24-row, 80-column
/// viewport is used throughout so the row/column math reads the same way the headless core's actual
/// grid does.
@Suite struct GhosttyTerminalSelectionProjectionTests {
    private let columns = 80
    private let rows = 24

    // MARK: - Fully inside the viewport

    @Test func selectionEntirelyInsideTheViewportRebasesWithNoExtension() {
        let projected = GhosttyTerminalSelectionProjection.project(
            startColumn: 5, startRow: 100, endColumn: 20, endRow: 102, isRectangle: false, viewportRowOffset: 100, columns: columns, rows: rows)
        #expect(
            projected
                == GhosttyTerminalSelectionRange(
                    startColumn: 5, startRow: 0, endColumn: 20, endRow: 2, isRectangle: false, extendsAbove: false, extendsBelow: false))
    }

    @Test func singleRowSelectionInsideTheViewportKeepsBothColumnBounds() {
        let projected = GhosttyTerminalSelectionProjection.project(
            startColumn: 10, startRow: 105, endColumn: 30, endRow: 105, isRectangle: false, viewportRowOffset: 100, columns: columns, rows: rows)
        #expect(
            projected
                == GhosttyTerminalSelectionRange(
                    startColumn: 10, startRow: 5, endColumn: 30, endRow: 5, isRectangle: false, extendsAbove: false, extendsBelow: false))
    }

    // MARK: - Extends above

    /// The selection starts in scrollback above the viewport. Its first surviving row is an interior
    /// row of the original selection (not the true start row), so the crop reports full width there.
    @Test func selectionStartingAboveTheViewportCropsToFullWidthOnItsFirstVisibleRow() {
        let projected = GhosttyTerminalSelectionProjection.project(
            startColumn: 40, startRow: 50, endColumn: 10, endRow: 102, isRectangle: false, viewportRowOffset: 100, columns: columns, rows: rows)
        #expect(projected?.extendsAbove == true)
        #expect(projected?.extendsBelow == false)
        #expect(projected?.startRow == 0)
        #expect(projected?.startColumn == 0, "the true start column is off-screen in scrollback, so the visible portion starts at column 0")
        #expect(projected?.endRow == 2)
        #expect(projected?.endColumn == 10)
    }

    /// Only one row of an above-extending selection survives the crop (the selection ends on the
    /// viewport's very first row), so that lone surviving row still reports its true end column
    /// rather than the full width an interior row would get.
    @Test func selectionEndingOnTheViewportsFirstRowKeepsItsTrueEndColumn() {
        let projected = GhosttyTerminalSelectionProjection.project(
            startColumn: 40, startRow: 50, endColumn: 15, endRow: 100, isRectangle: false, viewportRowOffset: 100, columns: columns, rows: rows)
        #expect(projected?.extendsAbove == true)
        #expect(projected?.extendsBelow == false)
        #expect(projected?.startRow == 0)
        #expect(projected?.startColumn == 0)
        #expect(projected?.endRow == 0)
        #expect(projected?.endColumn == 15)
    }

    // MARK: - Extends below

    @Test func selectionEndingBelowTheViewportCropsToFullWidthOnItsLastVisibleRow() {
        let projected = GhosttyTerminalSelectionProjection.project(
            startColumn: 8, startRow: 121, endColumn: 60, endRow: 200, isRectangle: false, viewportRowOffset: 100, columns: columns, rows: rows)
        #expect(projected?.extendsAbove == false)
        #expect(projected?.extendsBelow == true)
        #expect(projected?.startRow == 21)
        #expect(projected?.startColumn == 8)
        #expect(projected?.endRow == 23, "the viewport's last row (offset 100, 24 rows -> screen row 123)")
        #expect(projected?.endColumn == UInt16(columns - 1))
    }

    /// Only the viewport's last row survives an below-extending selection that starts there, so that
    /// lone surviving row keeps its true start column instead of full width.
    @Test func selectionStartingOnTheViewportsLastRowKeepsItsTrueStartColumn() {
        let projected = GhosttyTerminalSelectionProjection.project(
            startColumn: 30, startRow: 123, endColumn: 5, endRow: 200, isRectangle: false, viewportRowOffset: 100, columns: columns, rows: rows)
        #expect(projected?.extendsAbove == false)
        #expect(projected?.extendsBelow == true)
        #expect(projected?.startRow == 23)
        #expect(projected?.startColumn == 30)
        #expect(projected?.endRow == 23)
        #expect(projected?.endColumn == UInt16(columns - 1))
    }

    // MARK: - Extends both above and below

    @Test func selectionSpanningTheEntireViewportExtendsOnBothEndsAtFullWidth() {
        let projected = GhosttyTerminalSelectionProjection.project(
            startColumn: 50, startRow: 10, endColumn: 5, endRow: 500, isRectangle: false, viewportRowOffset: 100, columns: columns, rows: rows)
        #expect(
            projected
                == GhosttyTerminalSelectionRange(
                    startColumn: 0, startRow: 0, endColumn: UInt16(columns - 1), endRow: UInt16(rows - 1), isRectangle: false, extendsAbove: true,
                    extendsBelow: true))
    }

    // MARK: - No overlap

    @Test func selectionEntirelyAboveTheViewportProjectsToNil() {
        let projected = GhosttyTerminalSelectionProjection.project(
            startColumn: 0, startRow: 10, endColumn: 79, endRow: 40, isRectangle: false, viewportRowOffset: 100, columns: columns, rows: rows)
        #expect(projected == nil)
    }

    @Test func selectionEntirelyBelowTheViewportProjectsToNil() {
        let projected = GhosttyTerminalSelectionProjection.project(
            startColumn: 0, startRow: 200, endColumn: 79, endRow: 210, isRectangle: false, viewportRowOffset: 100, columns: columns, rows: rows)
        #expect(projected == nil)
    }

    @Test func zeroSizedViewportProjectsToNil() {
        let projected = GhosttyTerminalSelectionProjection.project(
            startColumn: 0, startRow: 100, endColumn: 10, endRow: 100, isRectangle: false, viewportRowOffset: 100, columns: 0, rows: rows)
        #expect(projected == nil)
    }

    // MARK: - Rectangle selections

    /// A rectangle selection only crops vertically, same as a stream selection; its column bounds are
    /// carried through unchanged (clamped to the grid) regardless of which rows survive the crop.
    @Test func rectangleSelectionKeepsItsColumnBoundsAcrossACrop() {
        let projected = GhosttyTerminalSelectionProjection.project(
            startColumn: 10, startRow: 90, endColumn: 30, endRow: 105, isRectangle: true, viewportRowOffset: 100, columns: columns, rows: rows)
        #expect(
            projected
                == GhosttyTerminalSelectionRange(
                    startColumn: 10, startRow: 0, endColumn: 30, endRow: 5, isRectangle: true, extendsAbove: true, extendsBelow: false))
    }

    @Test func rectangleSelectionClampsColumnsPastTheGridEdge() {
        let projected = GhosttyTerminalSelectionProjection.project(
            startColumn: 0, startRow: 100, endColumn: 9_999, endRow: 105, isRectangle: true, viewportRowOffset: 100, columns: columns, rows: rows)
        #expect(projected?.startColumn == 0)
        #expect(projected?.endColumn == UInt16(columns - 1))
    }

    /// The (y, x)-lexicographic endpoint ordering leaves a leftward-dragged rectangle with
    /// startColumn > endColumn; the projection normalizes to the min..max column band instead of
    /// treating the inverted pair as a non-range.
    @Test func rectangleSelectionWithReversedColumnsNormalizesToTheColumnBand() {
        let projected = GhosttyTerminalSelectionProjection.project(
            startColumn: 30, startRow: 102, endColumn: 10, endRow: 105, isRectangle: true, viewportRowOffset: 100, columns: columns, rows: rows)
        #expect(
            projected
                == GhosttyTerminalSelectionRange(
                    startColumn: 10, startRow: 2, endColumn: 30, endRow: 5, isRectangle: true, extendsAbove: false, extendsBelow: false))
    }
}
