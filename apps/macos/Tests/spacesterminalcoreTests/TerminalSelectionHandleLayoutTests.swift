import Testing

@testable import spacesterminalcore

/// Where the two handles of a touch selection are drawn, and where the menu points.
@Suite struct TerminalSelectionHandleLayoutTests {
    private func range(
        _ startColumn: UInt16, _ startRow: UInt16, _ endColumn: UInt16, _ endRow: UInt16, extendsAbove: Bool = false, extendsBelow: Bool = false
    ) -> GhosttyTerminalSelectionRange {
        GhosttyTerminalSelectionRange(
            startColumn: startColumn, startRow: startRow, endColumn: endColumn, endRow: endRow, isRectangle: false, extendsAbove: extendsAbove,
            extendsBelow: extendsBelow)
    }

    private func layout(_ range: GhosttyTerminalSelectionRange) -> TerminalSelectionHandleLayout {
        TerminalSelectionHandleLayout(range: range, originX: 10, originY: 20, cellWidth: 8, cellHeight: 16, columns: 40)
    }

    @Test func theStartBarSitsOnTheLeftEdgeOfItsRowWithTheDotAbove() throws {
        let start = try #require(layout(range(3, 2, 9, 4)).start)

        #expect(start.barX == 10 + 3 * 8 - 1)
        #expect(start.barY == 20 + 2 * 16)
        #expect(start.barHeight == 16)
        #expect(start.dotCenterX == 10 + 3 * 8)
        #expect(start.dotCenterY == 20 + 2 * 16 - 5)
    }

    @Test func theEndBarSitsOnTheRightEdgeOfItsCellWithTheDotBelow() throws {
        let end = try #require(layout(range(3, 2, 9, 4)).end)

        #expect(end.barX == 10 + 10 * 8 - 1)
        #expect(end.barY == 20 + 4 * 16)
        #expect(end.dotCenterX == 10 + 10 * 8)
        #expect(end.dotCenterY == 20 + 5 * 16 + 5)
    }

    /// A two-letter selection puts the end handle's expanded target over the start handle's drawing; a
    /// touch on either drawing still grabs the handle it is drawn on.
    @Test func aTouchOnAShortSelectionsHandleGrabsTheNearestHandleNotTheOneWhoseTargetCoversIt() throws {
        let short = layout(range(3, 2, 4, 2))
        let start = try #require(short.start)
        let end = try #require(short.end)

        #expect(short.handle(atX: start.grabX, y: start.grabY) == .start)
        #expect(short.handle(atX: start.dotCenterX, y: start.dotCenterY) == .start)
        #expect(short.handle(atX: end.grabX, y: end.grabY) == .end)
        #expect(short.handle(atX: end.dotCenterX, y: end.dotCenterY) == .end)
    }

    @Test func aTouchBeyondBothTargetsGrabsNothing() { #expect(layout(range(3, 2, 9, 4)).handle(atX: 300, y: 300) == nil) }

    @Test func anEndThatIsOffScreenHasNoHandle() {
        #expect(layout(range(3, 0, 9, 4, extendsAbove: true)).start == nil)
        #expect(layout(range(3, 0, 9, 4, extendsAbove: true)).end != nil)
        #expect(layout(range(3, 2, 9, 9, extendsBelow: true)).end == nil)
        #expect(layout(range(3, 2, 9, 9, extendsBelow: true)).start != nil)
    }

    @Test func theMenuPointsAtTheSelectedPartOfASingleRowAndTheWholeWidthOfSeveral() {
        let singleRow = layout(range(3, 2, 9, 2))
        #expect(singleRow.anchorMinX == 10 + 3 * 8)
        #expect(singleRow.anchorWidth == 7 * 8)
        #expect(singleRow.anchorMinY == 20 + 2 * 16)
        #expect(singleRow.anchorHeight == 16)

        let severalRows = layout(range(3, 2, 9, 4))
        #expect(severalRows.anchorMinX == 10)
        #expect(severalRows.anchorWidth == 40 * 8)
        #expect(severalRows.anchorHeight == 3 * 16)
    }
}
