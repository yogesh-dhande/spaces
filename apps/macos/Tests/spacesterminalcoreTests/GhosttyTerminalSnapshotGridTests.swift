import XCTest

@testable import spacesterminalcore

final class GhosttyTerminalSnapshotGridTests: XCTestCase {
    func testResolvedCellsApplyCursorAndStyleFlags() {
        let underlineFlag = GhosttyTerminalSnapshotGrid.underlineFlag
        let snapshot = GhosttyTerminalSnapshot(
            columns: 2, rows: 1, cursorColumn: 1, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0xEEEEEE, defaultBackgroundRGB: 0x101010,
            cells: [
                .init(codepoint: 65, foregroundRGB: 0xFF0000, backgroundRGB: 0x101010, flags: underlineFlag),
                .init(codepoint: 66, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x202020, flags: 0),
            ])

        let first = GhosttyTerminalSnapshotGrid.resolvedCell(in: snapshot, row: 0, column: 0)
        let cursor = GhosttyTerminalSnapshotGrid.resolvedCell(in: snapshot, row: 0, column: 1)

        XCTAssertEqual(first?.text, "A")
        XCTAssertEqual(first?.foregroundRGB, 0xFF0000)
        XCTAssertEqual(first?.backgroundRGB, 0x101010)
        XCTAssertEqual(first?.isUnderline, true)
        XCTAssertEqual(cursor?.text, "B")
        XCTAssertEqual(cursor?.foregroundRGB, 0x202020)
        XCTAssertEqual(cursor?.backgroundRGB, 0xEEEEEE)
        XCTAssertEqual(cursor?.isCursor, true)
    }

    func testFullPlainTextKeepsTerminalGridShape() {
        let snapshot = GhosttyTerminalSnapshot(
            columns: 3, rows: 2, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xEEEEEE, defaultBackgroundRGB: 0x101010,
            cells: [
                .init(codepoint: 65, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 67, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 68, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
            ])

        XCTAssertEqual(GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot), "A C\n  D")
        XCTAssertTrue(GhosttyTerminalSnapshotGrid.containsVisibleContent(snapshot))
    }

    func testResolvedBlankCellsPreserveNonDefaultBackground() {
        let snapshot = GhosttyTerminalSnapshot(
            columns: 2, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xEEEEEE, defaultBackgroundRGB: 0x101010,
            cells: [
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x444444, flags: 0),
                .init(codepoint: 32, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x555555, flags: 0),
            ])

        let nullBlank = GhosttyTerminalSnapshotGrid.resolvedCell(in: snapshot, row: 0, column: 0)
        let spaceBlank = GhosttyTerminalSnapshotGrid.resolvedCell(in: snapshot, row: 0, column: 1)

        XCTAssertEqual(nullBlank?.text, " ")
        XCTAssertEqual(nullBlank?.backgroundRGB, 0x444444)
        XCTAssertEqual(spaceBlank?.text, " ")
        XCTAssertEqual(spaceBlank?.backgroundRGB, 0x555555)
        XCTAssertTrue(GhosttyTerminalSnapshotGrid.containsVisibleContent(snapshot))
    }
}
