import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalEndedSessionScrollbackModelTests: XCTestCase {
    private func theme(background: ThemeColor = ThemeColor(0, 0, 0), foreground: ThemeColor = ThemeColor(255, 255, 255)) -> GhosttyThemeExport {
        GhosttyThemeExport(
            background: background, foreground: foreground, cursorColor: ThemeColor(200, 200, 200), cursorText: ThemeColor(0, 0, 0),
            selectionBackground: ThemeColor(50, 50, 50), selectionForeground: ThemeColor(255, 255, 255),
            palette: (0..<16).map { ThemeColor($0 * 8, $0 * 8, $0 * 8) })
    }

    /// Transcript of `count` CRLF-terminated numbered lines ("row-001", "row-002", …), so a small grid
    /// pushes earlier lines into scrollback.
    private func numberedTranscript(count: Int) -> Data { Data((1...count).map { String(format: "row-%03d", $0) }.joined(separator: "\r\n").utf8) }

    private func plainText(_ snapshot: GhosttyTerminalSnapshot) -> String {
        guard snapshot.columns > 0, snapshot.rows > 0, snapshot.cells.count >= snapshot.columns * snapshot.rows else { return "" }
        var lines: [String] = []
        for row in 0..<snapshot.rows {
            var scalars = String.UnicodeScalarView()
            for column in 0..<snapshot.columns {
                let codepoint = snapshot.cells[row * snapshot.columns + column].codepoint
                scalars.append(Unicode.Scalar(codepoint == 0 ? 32 : codepoint) ?? " ")
            }
            lines.append(String(scalars).trimmingCharacters(in: .whitespaces))
        }
        return lines.joined(separator: "\n")
    }

    func testScrollUpRevealsEarlierRows() throws {
        let model = try XCTUnwrap(
            TerminalEndedSessionScrollbackModel(columns: 10, rows: 3, theme: theme(), appearance: .dark, transcript: numberedTranscript(count: 60)))

        let bottom = plainText(model.currentSnapshot())
        XCTAssertTrue(bottom.contains("row-060"), bottom)
        XCTAssertFalse(bottom.contains("row-050"), bottom)

        let scrolled = try XCTUnwrap(model.scroll(deltaRows: -20))
        let scrolledText = plainText(scrolled)
        XCTAssertFalse(scrolledText.contains("row-060"), scrolledText)
        XCTAssertTrue(scrolledText.contains("row-040") || scrolledText.contains("row-039") || scrolledText.contains("row-038"), scrolledText)
    }

    func testScrollClampsAtTop() throws {
        let model = try XCTUnwrap(
            TerminalEndedSessionScrollbackModel(columns: 10, rows: 3, theme: theme(), appearance: .dark, transcript: numberedTranscript(count: 60)))

        // Overscroll far past the top; the next scroll up must report no movement.
        _ = model.scroll(deltaRows: -1000)
        XCTAssertNil(model.scroll(deltaRows: -50))

        let topText = plainText(model.currentSnapshot())
        XCTAssertTrue(topText.contains("row-001"), topText)
    }

    func testScrollsBackToBottom() throws {
        let model = try XCTUnwrap(
            TerminalEndedSessionScrollbackModel(columns: 10, rows: 3, theme: theme(), appearance: .dark, transcript: numberedTranscript(count: 60)))

        XCTAssertNotNil(model.scroll(deltaRows: -30))
        // Scroll back down to the bottom; the last line is visible again and a further scroll clamps.
        _ = model.scroll(deltaRows: 1000)
        XCTAssertNil(model.scroll(deltaRows: 50))

        let bottomText = plainText(model.currentSnapshot())
        XCTAssertTrue(bottomText.contains("row-060"), bottomText)
    }

    func testEmptyTranscriptBuildsWithoutContent() throws {
        let model = try XCTUnwrap(TerminalEndedSessionScrollbackModel(columns: 8, rows: 4, theme: theme(), appearance: .dark, transcript: Data()))
        XCTAssertNil(model.scroll(deltaRows: -5))
        XCTAssertEqual(plainText(model.currentSnapshot()).trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testThemeDefaultForegroundAndBackgroundApplied() throws {
        let background = ThemeColor(1, 2, 3)
        let foreground = ThemeColor(4, 5, 6)
        let model = try XCTUnwrap(
            TerminalEndedSessionScrollbackModel(
                columns: 8, rows: 4, theme: theme(background: background, foreground: foreground), appearance: .dark, transcript: Data()))

        let snapshot = model.currentSnapshot()
        XCTAssertEqual(snapshot.defaultBackgroundRGB, background.packedRGB)
        XCTAssertEqual(snapshot.defaultForegroundRGB, foreground.packedRGB)
    }
}
