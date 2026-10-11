import Foundation
import Testing

@testable import spacesterminalcore

/// The link table both mirror views hand to Ghostty: one entry per distinct target, and for each linked
/// cell the 1-based table index of its target.
@Suite struct GhosttyTerminalSnapshotLinkTableTests {
    private func snapshot(linkURLs: [Int: String], cellCount: Int = 12) -> GhosttyTerminalSnapshot {
        GhosttyTerminalSnapshot(
            columns: cellCount, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0, defaultBackgroundRGB: 0,
            cells: Array(repeating: .init(codepoint: 0x61, foregroundRGB: 0, backgroundRGB: 0, flags: 0), count: cellCount), linkURLs: linkURLs)
    }

    private func target(_ index: Int, in table: GhosttyTerminalSnapshotLinkTable.Flattened) -> String {
        let entry = table.entries[index - 1]
        return String(decoding: table.uriBytes[entry.offset..<(entry.offset + entry.count)], as: UTF8.self)
    }

    @Test func aFrameWithoutLinksFlattensToNothing() {
        let table = GhosttyTerminalSnapshotLinkTable.flatten(snapshot(linkURLs: [:]))
        #expect(table.uriBytes.isEmpty)
        #expect(table.entries.isEmpty)
        #expect(table.cellLinkIndexes.isEmpty)
    }

    @Test func eachDistinctTargetGetsOneEntryAndItsCellsShareTheIndex() {
        let table = GhosttyTerminalSnapshotLinkTable.flatten(
            snapshot(linkURLs: [0: "https://a.example", 1: "https://a.example", 4: "https://b.example", 9: "https://a.example"]))

        #expect(table.entries.count == 2)
        #expect(table.cellLinkIndexes == [0: 1, 1: 1, 4: 2, 9: 1])
        #expect(target(1, in: table) == "https://a.example")
        #expect(target(2, in: table) == "https://b.example")
    }

    /// Entries are numbered by the first cell that uses them, so a frame flattens the same way every time.
    @Test func entriesFollowTheOrderOfTheirFirstCell() {
        let table = GhosttyTerminalSnapshotLinkTable.flatten(snapshot(linkURLs: [8: "https://late.example", 2: "https://early.example"]))

        #expect(target(1, in: table) == "https://early.example")
        #expect(target(2, in: table) == "https://late.example")
        #expect(table.cellLinkIndexes == [2: 1, 8: 2])
    }

    /// Targets that are canonically equivalent as Swift strings but different bytes are different URLs.
    @Test func canonicallyEquivalentButByteDistinctTargetsGetSeparateEntries() {
        let precomposed = "https://example.com/caf\u{E9}"
        let decomposed = "https://example.com/cafe\u{301}"
        #expect(precomposed == decomposed)
        let table = GhosttyTerminalSnapshotLinkTable.flatten(snapshot(linkURLs: [1: precomposed, 5: decomposed, 7: precomposed]))

        #expect(table.entries.count == 2)
        #expect(table.cellLinkIndexes == [1: 1, 5: 2, 7: 1])
        let bytes = { (index: Int) in Array(table.uriBytes[table.entries[index].offset..<(table.entries[index].offset + table.entries[index].count)])
        }
        #expect(bytes(0) == Array(precomposed.utf8))
        #expect(bytes(1) == Array(decomposed.utf8))
    }

    @Test func nonASCIITargetsKeepTheirUTF8Bytes() {
        let url = "https://example.com/caf\u{E9}"
        let table = GhosttyTerminalSnapshotLinkTable.flatten(snapshot(linkURLs: [3: url]))

        #expect(target(1, in: table) == url)
        #expect(table.entries[0].count == url.utf8.count)
    }
}
