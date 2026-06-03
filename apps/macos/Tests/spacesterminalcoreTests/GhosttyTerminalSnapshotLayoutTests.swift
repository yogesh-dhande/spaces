import XCTest

@testable import spacesterminalcore

final class GhosttyTerminalSnapshotLayoutTests: XCTestCase {
    func testLayoutBuildsVisibleTextAndCursorCell() {
        let snapshot = GhosttyTerminalSnapshot(
            columns: 4, rows: 2, cursorColumn: 1, cursorRow: 1, cursorVisible: true, defaultForegroundRGB: 0xFFFFFF, defaultBackgroundRGB: 0x111111,
            cells: [
                .init(codepoint: 65, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 66, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 67, foregroundRGB: 0x00FF00, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
            ])

        let lines = GhosttyTerminalSnapshotLayout.lines(for: snapshot)

        XCTAssertEqual(lines.map(\.text), ["AB", "C "])
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: snapshot), "AB\nC ")
        XCTAssertEqual(lines[1].runs.count, 2)
        XCTAssertEqual(lines[1].runs[0].foregroundRGB, 0x00FF00)
        XCTAssertEqual(lines[1].runs[1].foregroundRGB, 0x111111)
        XCTAssertEqual(lines[1].runs[1].backgroundRGB, 0xFFFFFF)
    }

    func testLayoutPreservesBlankInteriorRowsAndStyles() {
        let underlineFlag: UInt16 = 1 << 7
        let snapshot = GhosttyTerminalSnapshot(
            columns: 3, rows: 3, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xEEEEEE, defaultBackgroundRGB: 0x101010,
            cells: [
                .init(codepoint: 88, foregroundRGB: 0xFF0000, backgroundRGB: 0x101010, flags: underlineFlag),
                .init(codepoint: 89, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 90, foregroundRGB: 0x00FF00, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
            ])

        let lines = GhosttyTerminalSnapshotLayout.lines(for: snapshot)

        XCTAssertEqual(lines.map(\.text), ["XY", "", "Z"])
        XCTAssertEqual(lines[0].runs.first?.isUnderline, true)
        XCTAssertTrue(lines[1].runs.isEmpty)
    }

    func testLayoutPreservesBackgroundOnlyBlankRuns() {
        let snapshot = GhosttyTerminalSnapshot(
            columns: 4, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xEEEEEE, defaultBackgroundRGB: 0x101010,
            cells: [
                .init(codepoint: 65, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x444444, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x444444, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
            ])

        let line = GhosttyTerminalSnapshotLayout.lines(for: snapshot)[0]

        XCTAssertEqual(line.text, "A  ")
        XCTAssertEqual(line.runs.count, 2)
        XCTAssertEqual(line.runs[1].text, "  ")
        XCTAssertEqual(line.runs[1].backgroundRGB, 0x444444)
    }
}
