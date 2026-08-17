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

    private func makeSnapshot(columns: Int, rows: Int, cursorColumn: Int, cursorRow: Int, glyphs: [String]) -> GhosttyTerminalSnapshot {
        let cells = glyphs.flatMap { row in
            row.unicodeScalars.map { scalar in
                GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0)
            }
        }

        return GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: cursorColumn, cursorRow: cursorRow, cursorVisible: true, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x111111, cells: cells)
    }
}
