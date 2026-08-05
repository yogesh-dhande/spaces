import XCTest

@testable import spacesterminalcore

/// Cell text is resolved in one place, so the grid resolver and the display-run layout agree on what a
/// cell says: an emoji sequence reads as the whole cluster in accessibility text, copy buffers, and
/// scrollback replay alike.
final class GhosttyTerminalSnapshotCellTextTests: XCTestCase {
    func testClusterIsReturnedWhole() {
        for text in ["👋🏽", "👨‍👩‍👧‍👦", "🇯🇵", "e\u{0301}"] {
            let character = Character(text)
            XCTAssertEqual(GhosttyTerminalSnapshotCellText.displayText(for: makeCell(character), cluster: text), text)
        }
    }

    func testSingleScalarCellRendersItsCodepoint() {
        XCTAssertEqual(GhosttyTerminalSnapshotCellText.displayText(for: makeCell("A"), cluster: nil), "A")
        XCTAssertEqual(
            GhosttyTerminalSnapshotCellText.displayText(
                for: GhosttyTerminalSnapshot.Cell(codepoint: 0, foregroundRGB: 0, backgroundRGB: 0, flags: 0), cluster: nil), " ")
    }

    /// A codepoint no Unicode scalar can hold still renders as the replacement character rather than
    /// dropping the column.
    func testInvalidCodepointFallsBackToTheReplacementCharacter() {
        let cell = GhosttyTerminalSnapshot.Cell(codepoint: 0xD800, foregroundRGB: 0, backgroundRGB: 0, flags: 0)
        XCTAssertEqual(GhosttyTerminalSnapshotCellText.displayText(for: cell, cluster: nil), "\u{FFFD}")
    }

    /// The trailing half of a double-width glyph and an invisible cell both render as a space so the
    /// column positions of everything after them hold, cluster or not.
    func testSpacerAndInvisibleCellsRenderAsSpace() {
        let spacer = GhosttyTerminalSnapshot.Cell(
            codepoint: 0x1F44B, foregroundRGB: 0, backgroundRGB: 0, flags: GhosttyTerminalSnapshotGrid.spacerFlag)
        let invisible = GhosttyTerminalSnapshot.Cell(
            codepoint: 0x1F44B, foregroundRGB: 0, backgroundRGB: 0, flags: GhosttyTerminalSnapshotGrid.invisibleFlag)
        XCTAssertEqual(GhosttyTerminalSnapshotCellText.displayText(for: spacer, cluster: "👋🏽"), " ")
        XCTAssertEqual(GhosttyTerminalSnapshotCellText.displayText(for: invisible, cluster: "👋🏽"), " ")
    }

    func testGridAndLayoutTextAgreeOnClusters() {
        let snapshot = GhosttyTerminalSnapshot(
            columns: 3, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xEEEEEE, defaultBackgroundRGB: 0x101010,
            cells: [makeCell("👋🏽"), makeCell("e\u{0301}"), makeCell("x")], clusters: [0: "👋🏽", 1: "e\u{0301}"])

        XCTAssertEqual(GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot), "👋🏽e\u{0301}x")
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: snapshot), "👋🏽e\u{0301}x")
        XCTAssertEqual(GhosttyTerminalSnapshotGrid.resolvedCell(in: snapshot, row: 0, column: 0)?.text, "👋🏽")
    }

    private func makeCell(_ character: Character) -> GhosttyTerminalSnapshot.Cell {
        GhosttyTerminalSnapshot.Cell(
            codepoint: character.unicodeScalars.first?.value ?? 0x20, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0)
    }
}
