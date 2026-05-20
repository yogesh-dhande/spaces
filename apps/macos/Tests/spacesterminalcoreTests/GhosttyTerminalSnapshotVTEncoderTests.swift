import Foundation
import Testing

@testable import spacesterminalcore

struct GhosttyTerminalSnapshotVTEncoderTests {
    @Test func encodesVisibleCellsAndCursor() throws {
        let snapshot = GhosttyTerminalSnapshot(
            columns: 3, rows: 2, cursorColumn: 1, cursorRow: 1, cursorVisible: true, defaultForegroundRGB: 0xFFFFFF, defaultBackgroundRGB: 0x101010,
            cells: [
                .init(codepoint: 65, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 66, foregroundRGB: 0xFF0000, backgroundRGB: 0x101010, flags: 1 << 0),
                .init(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 67, foregroundRGB: 0x00FF00, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x202020, flags: 0),
                .init(codepoint: 68, foregroundRGB: 0x0000FF, backgroundRGB: 0x101010, flags: 1 << 7),
            ])

        let encoded = try #require(String(data: GhosttyTerminalSnapshotVTEncoder.encode(snapshot), encoding: .utf8))
        #expect(encoded.hasPrefix("\u{1B}[?25l\u{1B}[0m\u{1B}[H\u{1B}[2J"))
        #expect(encoded.contains("\u{1B}[1;1H"))
        #expect(encoded.contains("A"))
        #expect(encoded.contains("B"))
        #expect(encoded.contains("\u{1B}[0;1;38;2;255;0;0;48;2;16;16;16mB"))
        #expect(encoded.contains("\u{1B}[0;38;2;255;255;255;48;2;32;32;32m "))
        #expect(encoded.contains("\u{1B}[K"))
        #expect(encoded.contains("\u{1B}[?25h"))
        #expect(encoded.hasSuffix("\u{1B}[2;2H"))
    }

    @Test func skipsSpacerCells() throws {
        let snapshot = GhosttyTerminalSnapshot(
            columns: 2, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF, defaultBackgroundRGB: 0x000000,
            cells: [
                .init(codepoint: 0x4E00, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 1 << 10),
            ])

        let encoded = try #require(String(data: GhosttyTerminalSnapshotVTEncoder.encode(snapshot), encoding: .utf8))
        #expect(encoded.contains("一"))
        #expect(!encoded.contains("一 "))
        #expect(encoded.contains("\u{1B}[?25l"))
    }
}
