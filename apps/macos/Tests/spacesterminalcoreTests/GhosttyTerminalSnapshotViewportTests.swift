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
