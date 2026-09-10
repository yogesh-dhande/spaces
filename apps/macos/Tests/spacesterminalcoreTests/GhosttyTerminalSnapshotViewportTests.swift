import XCTest

@testable import spacesterminalcore

final class GhosttyTerminalSnapshotViewportTests: XCTestCase {
    func testCropPreservesLeadingColumnsWhenCursorAlreadyFits() {
        let snapshot = makeSnapshot(columns: 6, rows: 3, cursorColumn: 2, cursorRow: 2, glyphs: ["ABCDEF", "GHIJKL", "MNOPQR"])

        let cropped = GhosttyTerminalSnapshotViewport.crop(snapshot, columns: 4, rows: 2)

        XCTAssertEqual(cropped.columns, 4)
        XCTAssertEqual(cropped.rows, 2)
        XCTAssertEqual(cropped.cursorColumn, 2)
        XCTAssertEqual(cropped.cursorRow, 1)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: cropped), "GHIJ\nMNOP")
    }

    func testCropShiftsViewportToKeepCursorVisibleNearTrailingEdge() {
        let snapshot = makeSnapshot(columns: 8, rows: 2, cursorColumn: 6, cursorRow: 1, glyphs: ["ABCDEFGH", "IJKLMNOP"])

        let cropped = GhosttyTerminalSnapshotViewport.crop(snapshot, columns: 4, rows: 2)

        XCTAssertEqual(cropped.columns, 4)
        XCTAssertEqual(cropped.rows, 2)
        XCTAssertEqual(cropped.cursorColumn, 2)
        XCTAssertEqual(cropped.cursorRow, 1)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: cropped), "EFGH\nMNOP")
    }

    func testLeadingAlignmentPreservesLeftmostColumnsEvenWhenCursorIsNearTrailingEdge() {
        let snapshot = makeSnapshot(columns: 8, rows: 2, cursorColumn: 6, cursorRow: 1, glyphs: ["ABCDEFGH", "IJKLMNOP"])

        let cropped = GhosttyTerminalSnapshotViewport.crop(snapshot, columns: 4, rows: 2, horizontalAlignment: .leading)

        XCTAssertEqual(cropped.columns, 4)
        XCTAssertEqual(cropped.rows, 2)
        XCTAssertEqual(cropped.cursorColumn, 3)
        XCTAssertEqual(cropped.cursorRow, 1)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: cropped), "ABCD\nIJKL")
    }

    func testWindowCoversTheSnapshotOnlyWhenItShowsEveryRowAndColumnFromTheOrigin() {
        let snapshot = makeSnapshot(columns: 6, rows: 3, cursorColumn: 0, cursorRow: 0, glyphs: ["ABCDEF", "GHIJKL", "MNOPQR"])

        XCTAssertTrue(
            GhosttyTerminalSnapshotViewport.covers(snapshot, window: .init(columnOffset: 0, rowOffset: 0, columns: 6, rows: 3)),
            "a window the size of the grid at its origin shows the grid whole")
        XCTAssertFalse(GhosttyTerminalSnapshotViewport.covers(snapshot, window: .init(columnOffset: 0, rowOffset: 0, columns: 4, rows: 3)))
        XCTAssertFalse(GhosttyTerminalSnapshotViewport.covers(snapshot, window: .init(columnOffset: 0, rowOffset: 0, columns: 6, rows: 2)))
        XCTAssertFalse(GhosttyTerminalSnapshotViewport.covers(snapshot, window: .init(columnOffset: 1, rowOffset: 0, columns: 6, rows: 3)))
        XCTAssertFalse(GhosttyTerminalSnapshotViewport.covers(snapshot, window: .init(columnOffset: 0, rowOffset: 1, columns: 6, rows: 3)))
    }

    /// Column coverage answers a narrower question than ``covers``: whether the rows the window shows keep
    /// their full width. A wrapped logical line can be read back out of such a window, because a row window
    /// drops whole rows while a column window leaves each row's soft-wrap bit pointing at columns that are
    /// gone.
    func testColumnCoverageIgnoresRowsAndTracksOnlyWhetherRowsKeepTheirFullWidth() {
        let snapshot = makeSnapshot(columns: 6, rows: 3, cursorColumn: 0, cursorRow: 0, glyphs: ["ABCDEF", "GHIJKL", "MNOPQR"])

        XCTAssertTrue(GhosttyTerminalSnapshotViewport.coversColumns(snapshot, window: .init(columnOffset: 0, rowOffset: 0, columns: 6, rows: 3)))
        XCTAssertTrue(
            GhosttyTerminalSnapshotViewport.coversColumns(snapshot, window: .init(columnOffset: 0, rowOffset: 1, columns: 6, rows: 1)),
            "a window showing one full-width row still shows that row whole")
        XCTAssertFalse(GhosttyTerminalSnapshotViewport.coversColumns(snapshot, window: .init(columnOffset: 0, rowOffset: 0, columns: 4, rows: 3)))
        XCTAssertFalse(GhosttyTerminalSnapshotViewport.coversColumns(snapshot, window: .init(columnOffset: 1, rowOffset: 0, columns: 5, rows: 3)))
    }

    /// Coverage is exactly the condition under which cropping is a no-op, which is what lets a caller use
    /// it to tell "this frame is the grid" from "this frame is a slice of the grid".
    func testCoverageMatchesWhetherCroppingLeavesTheSnapshotUnchanged() {
        let snapshot = makeSnapshot(columns: 6, rows: 3, cursorColumn: 4, cursorRow: 2, glyphs: ["ABCDEF", "GHIJKL", "MNOPQR"])

        for window in [
            GhosttyTerminalSnapshotViewport.Window(columnOffset: 0, rowOffset: 0, columns: 6, rows: 3),
            GhosttyTerminalSnapshotViewport.Window(columnOffset: 0, rowOffset: 0, columns: 3, rows: 3),
            GhosttyTerminalSnapshotViewport.Window(columnOffset: 2, rowOffset: 1, columns: 4, rows: 2),
        ] {
            let cropped = GhosttyTerminalSnapshotViewport.crop(snapshot, window: window)
            XCTAssertEqual(GhosttyTerminalSnapshotViewport.covers(snapshot, window: window), cropped == snapshot, "window \(window)")
        }
    }

    func testViewportWindowCoversTheSnapshotWhenTheViewportIsAtLeastAsLargeAsTheGrid() {
        let snapshot = makeSnapshot(columns: 6, rows: 3, cursorColumn: 5, cursorRow: 2, glyphs: ["ABCDEF", "GHIJKL", "MNOPQR"])

        let fitting = GhosttyTerminalSnapshotViewport.window(for: snapshot, columns: 6, rows: 3, horizontalAlignment: .leading)
        XCTAssertTrue(GhosttyTerminalSnapshotViewport.covers(snapshot, window: fitting))

        let larger = GhosttyTerminalSnapshotViewport.window(for: snapshot, columns: 40, rows: 20, horizontalAlignment: .leading)
        XCTAssertTrue(GhosttyTerminalSnapshotViewport.covers(snapshot, window: larger), "a viewport wider than the grid still shows it whole")

        let narrow = GhosttyTerminalSnapshotViewport.window(for: snapshot, columns: 4, rows: 3, horizontalAlignment: .leading)
        XCTAssertFalse(GhosttyTerminalSnapshotViewport.covers(snapshot, window: narrow))
    }

    /// A selection entirely inside the window rebases coordinates without touching either extends flag:
    /// both ends already land on rows the window shows.
    func testCropRebasesASelectionFullyInsideTheWindow() {
        let snapshot = makeSnapshot(
            columns: 6, rows: 6, cursorColumn: 0, cursorRow: 0, glyphs: Array(repeating: "ABCDEF", count: 6),
            selection: GhosttyTerminalSelectionRange(
                startColumn: 1, startRow: 2, endColumn: 4, endRow: 3, isRectangle: false, extendsAbove: false, extendsBelow: false))

        let cropped = GhosttyTerminalSnapshotViewport.crop(
            snapshot, window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 0, rowOffset: 2, columns: 6, rows: 2))

        XCTAssertEqual(
            cropped.selection,
            GhosttyTerminalSelectionRange(startColumn: 1, startRow: 0, endColumn: 4, endRow: 1, isRectangle: false, extendsAbove: false, extendsBelow: false))
    }

    /// A selection whose start row is clipped off the top gets `extendsAbove` set and its cropped start
    /// column pinned to 0, since the row that becomes the new top is an interior (full-width) row of the
    /// original selection. Clipping off the bottom too pins the end column to the last window column.
    func testCropClipsASelectionPartiallyAboveAndBelowTheWindow() {
        let snapshot = makeSnapshot(
            columns: 6, rows: 6, cursorColumn: 0, cursorRow: 0, glyphs: Array(repeating: "ABCDEF", count: 6),
            selection: GhosttyTerminalSelectionRange(
                startColumn: 5, startRow: 1, endColumn: 2, endRow: 4, isRectangle: false, extendsAbove: false, extendsBelow: false))

        let cropped = GhosttyTerminalSnapshotViewport.crop(
            snapshot, window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 0, rowOffset: 2, columns: 6, rows: 2))

        XCTAssertEqual(
            cropped.selection,
            GhosttyTerminalSelectionRange(startColumn: 0, startRow: 0, endColumn: 5, endRow: 1, isRectangle: false, extendsAbove: true, extendsBelow: true))
    }

    /// A stream selection's start row can survive the row crop yet still lie entirely outside the column
    /// window: its occupied columns run from `startColumn` to the end of the source row, and a narrow
    /// leading window can miss that range altogether. The start row is trimmed away rather than clamped
    /// to a cell it never occupied, so only the (still-selected) second row survives, and `extendsAbove`
    /// records that the selection continues above what this window shows.
    func testCropTrimsAStreamSelectionsStartRowWhenItMissesTheColumnWindow() {
        let snapshot = makeSnapshot(
            columns: 10, rows: 2, cursorColumn: 0, cursorRow: 0, glyphs: ["ABCDEFGHIJ", "KLMNOPQRST"],
            selection: GhosttyTerminalSelectionRange(
                startColumn: 8, startRow: 0, endColumn: 2, endRow: 1, isRectangle: false, extendsAbove: false, extendsBelow: false))

        let cropped = GhosttyTerminalSnapshotViewport.crop(
            snapshot, window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 0, rowOffset: 0, columns: 4, rows: 2))

        XCTAssertEqual(
            cropped.selection,
            GhosttyTerminalSelectionRange(startColumn: 0, startRow: 1, endColumn: 2, endRow: 1, isRectangle: false, extendsAbove: true, extendsBelow: false))
    }

    /// Mirrors `testCropTrimsAStreamSelectionsStartRowWhenItMissesTheColumnWindow` off the end row: its
    /// occupied columns run from the start of the source row to `endColumn`, and a window past that range
    /// misses it. Trimming the end row away leaves just the (still-selected) earlier rows, and
    /// `extendsBelow` records the cut.
    func testCropTrimsAStreamSelectionsEndRowWhenItMissesTheColumnWindow() {
        let snapshot = makeSnapshot(
            columns: 10, rows: 3, cursorColumn: 0, cursorRow: 0, glyphs: ["ABCDEFGHIJ", "KLMNOPQRST", "UVWXYZabcd"],
            selection: GhosttyTerminalSelectionRange(
                startColumn: 5, startRow: 0, endColumn: 1, endRow: 2, isRectangle: false, extendsAbove: false, extendsBelow: false))

        let cropped = GhosttyTerminalSnapshotViewport.crop(
            snapshot, window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 4, rowOffset: 0, columns: 4, rows: 3))

        XCTAssertEqual(
            cropped.selection,
            GhosttyTerminalSelectionRange(startColumn: 1, startRow: 0, endColumn: 3, endRow: 1, isRectangle: false, extendsAbove: false, extendsBelow: true))
    }

    /// When trimming the start row leaves more than one row behind, the newly-topmost surviving row is an
    /// interior row of the original selection (it sits strictly between the true start and end rows), so
    /// it is full width rather than clamped to the true start row's own (out-of-window) range.
    func testCropTrimsAStreamSelectionsStartRowAcrossMultipleSurvivingRows() {
        let snapshot = makeSnapshot(
            columns: 10, rows: 3, cursorColumn: 0, cursorRow: 0, glyphs: ["ABCDEFGHIJ", "KLMNOPQRST", "UVWXYZabcd"],
            selection: GhosttyTerminalSelectionRange(
                startColumn: 8, startRow: 0, endColumn: 2, endRow: 2, isRectangle: false, extendsAbove: false, extendsBelow: false))

        let cropped = GhosttyTerminalSnapshotViewport.crop(
            snapshot, window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 0, rowOffset: 0, columns: 4, rows: 3))

        XCTAssertEqual(
            cropped.selection,
            GhosttyTerminalSelectionRange(startColumn: 0, startRow: 1, endColumn: 2, endRow: 2, isRectangle: false, extendsAbove: true, extendsBelow: false))
    }

    /// Both boundary rows can be trimmed at once: with none of the selection's occupied columns anywhere
    /// near the window, no row is left to show, and the crop drops the selection entirely instead of
    /// inventing a highlight from the clamp.
    func testCropDropsAStreamSelectionWhenBothBoundaryRowsMissTheColumnWindow() {
        let snapshot = makeSnapshot(
            columns: 10, rows: 2, cursorColumn: 0, cursorRow: 0, glyphs: ["ABCDEFGHIJ", "KLMNOPQRST"],
            selection: GhosttyTerminalSelectionRange(
                startColumn: 8, startRow: 0, endColumn: 2, endRow: 1, isRectangle: false, extendsAbove: false, extendsBelow: false))

        let cropped = GhosttyTerminalSnapshotViewport.crop(
            snapshot, window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 4, rowOffset: 0, columns: 4, rows: 2))

        XCTAssertNil(cropped.selection)
    }

    /// A regression check that an ordinary multi-row selection whose boundary rows both still intersect
    /// the column window (rather than missing it entirely) rebases exactly as before the trimming fix:
    /// the boundary rows clamp into the window and no `extends` flag is invented.
    func testCropDoesNotTrimAStreamSelectionWhoseBoundaryRowsIntersectTheColumnWindow() {
        let snapshot = makeSnapshot(
            columns: 6, rows: 6, cursorColumn: 0, cursorRow: 0, glyphs: Array(repeating: "ABCDEF", count: 6),
            selection: GhosttyTerminalSelectionRange(
                startColumn: 1, startRow: 2, endColumn: 2, endRow: 4, isRectangle: false, extendsAbove: false, extendsBelow: false))

        let cropped = GhosttyTerminalSnapshotViewport.crop(
            snapshot, window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 0, rowOffset: 2, columns: 4, rows: 3))

        XCTAssertEqual(
            cropped.selection,
            GhosttyTerminalSelectionRange(startColumn: 1, startRow: 0, endColumn: 2, endRow: 2, isRectangle: false, extendsAbove: false, extendsBelow: false))
    }

    /// A selection whose rows never reach the window at all crops away to nil rather than a degenerate
    /// range.
    func testCropDropsASelectionOutsideTheWindowEntirely() {
        let snapshot = makeSnapshot(
            columns: 6, rows: 6, cursorColumn: 0, cursorRow: 0, glyphs: Array(repeating: "ABCDEF", count: 6),
            selection: GhosttyTerminalSelectionRange(
                startColumn: 0, startRow: 0, endColumn: 5, endRow: 1, isRectangle: false, extendsAbove: false, extendsBelow: false))

        let cropped = GhosttyTerminalSnapshotViewport.crop(
            snapshot, window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 0, rowOffset: 3, columns: 6, rows: 2))

        XCTAssertNil(cropped.selection)
    }

    /// A rectangle selection clamps its columns into the window instead of pinning to the edges the way a
    /// stream selection's boundary rows do.
    func testCropClampsARectangleSelectionsColumnsIntoTheWindow() {
        let snapshot = makeSnapshot(
            columns: 6, rows: 6, cursorColumn: 0, cursorRow: 0, glyphs: Array(repeating: "ABCDEF", count: 6),
            selection: GhosttyTerminalSelectionRange(
                startColumn: 0, startRow: 1, endColumn: 5, endRow: 4, isRectangle: true, extendsAbove: false, extendsBelow: false))

        let cropped = GhosttyTerminalSnapshotViewport.crop(
            snapshot, window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 1, rowOffset: 2, columns: 3, rows: 2))

        XCTAssertEqual(
            cropped.selection,
            GhosttyTerminalSelectionRange(startColumn: 0, startRow: 0, endColumn: 2, endRow: 1, isRectangle: true, extendsAbove: true, extendsBelow: true))
    }

    /// The cropped viewport's scrollbar offset rebases by the window's row offset; the total is unchanged
    /// since it describes the whole terminal, not the window.
    func testCropRebasesScrollbarOffsetByTheWindowsRowOffset() {
        let snapshot = makeSnapshot(
            columns: 6, rows: 6, cursorColumn: 0, cursorRow: 0, glyphs: Array(repeating: "ABCDEF", count: 6), scrollbarTotal: 100,
            scrollbarOffset: 5)

        let cropped = GhosttyTerminalSnapshotViewport.crop(
            snapshot, window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 0, rowOffset: 2, columns: 6, rows: 2))

        XCTAssertEqual(cropped.scrollbarTotal, 100)
        XCTAssertEqual(cropped.scrollbarOffset, 7)
    }

    /// The row offset is the whole of the iOS keyboard's effect on the terminal: the session keeps its
    /// grid and the visible rows move down it by the smaller of what the viewport hides and what it takes
    /// to keep the cursor, plus its trailing context, on screen.
    func testWindowShiftsByTheSmallerOfTheHiddenRowsAndWhatTheCursorNeeds() {
        let glyphs = (0..<10).map { index in "ROW\(index)" }

        let cursorAtBottom = makeSnapshot(columns: 4, rows: 10, cursorColumn: 0, cursorRow: 9, glyphs: glyphs)
        XCTAssertEqual(
            GhosttyTerminalSnapshotViewport.window(for: cursorAtBottom, columns: 4, rows: 4, horizontalAlignment: .leading).rowOffset, 6,
            "a cursor on the last row needs every hidden row, so the shift is the whole hidden height")

        let cursorNearTop = makeSnapshot(columns: 4, rows: 10, cursorColumn: 0, cursorRow: 2, glyphs: glyphs)
        XCTAssertEqual(
            GhosttyTerminalSnapshotViewport.window(for: cursorNearTop, columns: 4, rows: 4, horizontalAlignment: .leading).rowOffset, 0,
            "a cursor already on screen needs no shift at all")

        let cursorMidway = makeSnapshot(columns: 4, rows: 10, cursorColumn: 0, cursorRow: 5, glyphs: glyphs)
        XCTAssertEqual(
            GhosttyTerminalSnapshotViewport.window(for: cursorMidway, columns: 4, rows: 4, horizontalAlignment: .leading).rowOffset, 3,
            "a cursor partway down shifts only as far as it takes to show it with its trailing row")
    }

    /// Scrolling has to move the visible rows exactly as far as it moves the content. A scrolled-back
    /// frame has no cursor in its exported viewport to follow, so it keeps the offset the frame before it
    /// was drawn at and the scroll already in the frame is the whole of the movement. Only a frame back
    /// at the bottom of its scrollback follows the cursor again.
    func testScrolledBackWindowKeepsTheOffsetTheFrameBeforeItWasDrawnAt() {
        let glyphs = (0..<10).map { index in "ROW\(index)" }

        // Four of ten rows visible, cursor near the top: nothing to shift for.
        let atBottom = makeSnapshot(
            columns: 4, rows: 10, cursorColumn: 0, cursorRow: 2, glyphs: glyphs, scrollbarTotal: 100, scrollbarOffset: 90)
        let atBottomOffset = GhosttyTerminalSnapshotViewport.window(
            for: atBottom, columns: 4, rows: 4, horizontalAlignment: .leading, retainedRowOffset: 0
        ).rowOffset
        XCTAssertEqual(atBottomOffset, 0, "a cursor already on screen needs no shift at all")

        let scrolledBackOneRow = makeSnapshot(
            columns: 4, rows: 10, cursorColumn: 0, cursorRow: 3, glyphs: glyphs, scrollbarTotal: 100, scrollbarOffset: 89)
        let scrolledBackOneRowOffset = GhosttyTerminalSnapshotViewport.window(
            for: scrolledBackOneRow, columns: 4, rows: 4, horizontalAlignment: .leading, retainedRowOffset: atBottomOffset
        ).rowOffset
        XCTAssertEqual(
            scrolledBackOneRowOffset, atBottomOffset,
            "one row of scroll must move the visible rows by that one row of content, not by the hidden row count")

        let scrolledBackFurther = makeSnapshot(
            columns: 4, rows: 10, cursorColumn: 0, cursorRow: 9, glyphs: glyphs, scrollbarTotal: 100, scrollbarOffset: 40)
        XCTAssertEqual(
            GhosttyTerminalSnapshotViewport.window(
                for: scrolledBackFurther, columns: 4, rows: 4, horizontalAlignment: .leading, retainedRowOffset: scrolledBackOneRowOffset
            ).rowOffset, scrolledBackOneRowOffset, "every further scrolled frame holds the same alignment, cursor row or not")

        let backAtTheBottom = makeSnapshot(
            columns: 4, rows: 10, cursorColumn: 0, cursorRow: 9, glyphs: glyphs, scrollbarTotal: 100, scrollbarOffset: 90)
        XCTAssertEqual(
            GhosttyTerminalSnapshotViewport.window(
                for: backAtTheBottom, columns: 4, rows: 4, horizontalAlignment: .leading, retainedRowOffset: scrolledBackOneRowOffset
            ).rowOffset, 6, "a frame at the end of its scrollback follows the cursor again")
    }

    /// Typing at the bottom of the scrollback keeps the prompt on screen however far the offset had
    /// travelled while the user was scrolled back: a frame that is not scrolled back re-follows its
    /// cursor instead of inheriting anything.
    func testWindowAtTheBottomRefollowsTheCursorRatherThanTheRetainedOffset() {
        let glyphs = (0..<10).map { index in "ROW\(index)" }

        let cursorAtBottom = makeSnapshot(
            columns: 4, rows: 10, cursorColumn: 0, cursorRow: 9, glyphs: glyphs, scrollbarTotal: 100, scrollbarOffset: 90)
        XCTAssertEqual(
            GhosttyTerminalSnapshotViewport.window(
                for: cursorAtBottom, columns: 4, rows: 4, horizontalAlignment: .leading, retainedRowOffset: 0
            ).rowOffset, 6, "a prompt on the last row is shifted onto the screen no matter where the last crop started")

        let cursorNearTop = makeSnapshot(
            columns: 4, rows: 10, cursorColumn: 0, cursorRow: 2, glyphs: glyphs, scrollbarTotal: 100, scrollbarOffset: 90)
        XCTAssertEqual(
            GhosttyTerminalSnapshotViewport.window(
                for: cursorNearTop, columns: 4, rows: 4, horizontalAlignment: .leading, retainedRowOffset: 6
            ).rowOffset, 0, "a cursor already on screen pulls the crop back to the top of the grid")
    }

    /// A retained offset from a taller crop cannot point past what this viewport can show: giving the
    /// keyboard more of the screen back leaves fewer rows below the offset than the crop needs.
    func testScrolledBackWindowClampsARetainedOffsetToWhatTheViewportCanShow() {
        let glyphs = (0..<10).map { index in "ROW\(index)" }
        let scrolledBack = makeSnapshot(
            columns: 4, rows: 10, cursorColumn: 0, cursorRow: 0, glyphs: glyphs, scrollbarTotal: 100, scrollbarOffset: 5)

        XCTAssertEqual(
            GhosttyTerminalSnapshotViewport.window(
                for: scrolledBack, columns: 4, rows: 8, horizontalAlignment: .leading, retainedRowOffset: 6
            ).rowOffset, 2)
    }

    private func makeSnapshot(
        columns: Int, rows: Int, cursorColumn: Int, cursorRow: Int, glyphs: [String], selection: GhosttyTerminalSelectionRange? = nil,
        scrollbarTotal: UInt32 = 0, scrollbarOffset: UInt32 = 0
    ) -> GhosttyTerminalSnapshot {
        let cells = glyphs.flatMap { row in
            row.unicodeScalars.map { scalar in
                GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0)
            }
        }

        return GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: cursorColumn, cursorRow: cursorRow, cursorVisible: true, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x111111, cells: cells, selection: selection, scrollbarTotal: scrollbarTotal, scrollbarOffset: scrollbarOffset)
    }
}
