import Foundation
import Testing
import ghosttyvtshim

@testable import spacesterminalcore

/// Grapheme fidelity of the libghostty-vt snapshot export and the bridge that turns it into render
/// cells: an emoji sequence a program prints reaches the render snapshot whole instead of collapsing
/// to its base scalar. These drive a real vt session through the shim (the same call the Linux
/// headless daemon and the client-local scrollback replay make), so they cover the C export, the
/// cluster cap, and the Swift bridge together.
@Suite struct GhosttyVtSnapshotGraphemeTests {
    /// Terminals segment these differently depending on mode 2027 (grapheme clustering): with it on,
    /// each sequence occupies one cell; with it off, only zero-width marks attach to the preceding
    /// cell and an emoji modifier or regional indicator starts a cell of its own. Both are correct
    /// terminal behavior — what Spaces owes is that no scalar is dropped either way.
    private static let sequences: [(name: String, text: String)] = [
        ("emoji presentation heart", "\u{2764}\u{FE0F}"), ("skin-tone wave", "👋🏽"), ("ZWJ family", "👨‍👩‍👧‍👦"), ("flag pair", "🇯🇵"),
        ("combining acute", "e\u{0301}"),
    ]

    private func makeSession(columns: UInt16 = 20, rows: UInt16 = 3) throws -> OpaquePointer {
        try #require(spaces_ghostty_vt_session_new(columns, rows, 0, nil))
    }

    private func write(_ session: OpaquePointer, _ text: String) {
        let data = Data(text.utf8)
        #expect(data.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
    }

    private func snapshot(_ session: OpaquePointer) throws -> GhosttyTerminalSnapshot {
        var raw = SpacesGhosttyVtSnapshot()
        #expect(spaces_ghostty_vt_session_copy_snapshot(session, &raw))
        defer { spaces_ghostty_vt_snapshot_free(&raw) }
        let snapshot = GhosttyVtSessionBridge.snapshot(from: raw, mouseReportingActive: false)
        try #require(snapshot.columns > 0)
        return snapshot
    }

    /// The text of the first row, skipping the spacer cells a double-width glyph trails, so the result
    /// is what the program printed regardless of how the terminal split it into cells.
    private func firstRowText(_ snapshot: GhosttyTerminalSnapshot) -> String {
        (0..<snapshot.columns).reduce(into: "") { text, column in
            let cell = snapshot.cells[column]
            guard cell.flags & GhosttyTerminalSnapshotGrid.spacerFlag == 0 else { return }
            text += snapshot.clusters[column] ?? (cell.codepoint == 0 ? "" : String(UnicodeScalar(cell.codepoint) ?? " "))
        }
    }

    /// Under grapheme clustering each sequence is one cell, and that cell carries the whole cluster —
    /// the case a client renders as a single glyph.
    @Test(arguments: sequences) func sequenceOccupiesOneClusterCellUnderMode2027(fixture: (name: String, text: String)) throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "\u{1B}[?2027h" + fixture.text + "|")

        let snapshot = try snapshot(session)
        #expect(
            GhosttyTerminalSnapshotCellText.displayText(for: snapshot.cells[0], cluster: snapshot.clusters[0]) == fixture.text,
            "\(fixture.name) lost its cluster")
        #expect(firstRowText(snapshot) == fixture.text + "|", "\(fixture.name) row text")
    }

    /// Without grapheme clustering the terminal may spread a sequence over several cells, but no scalar
    /// may be dropped: a zero-width mark still attaches to the cell it modifies, and the row read back
    /// still says exactly what the program printed.
    @Test(arguments: sequences) func sequenceKeepsEveryScalarWithoutMode2027(fixture: (name: String, text: String)) throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, fixture.text + "|")

        #expect(firstRowText(try snapshot(session)) == fixture.text + "|", "\(fixture.name) lost a scalar")
    }

    /// A cell whose cluster runs past the cap is exported as its base codepoint alone rather than
    /// letting one cell's combining marks drive an unbounded copy. The cap counts the base codepoint,
    /// so exactly-at-the-cap still carries the whole cluster.
    @Test func clusterBeyondTheCapDegradesToTheBaseCodepoint() throws {
        let atCap = "e" + String(repeating: "\u{0301}", count: GhosttyTerminalSnapshot.maximumClusterCodepointCount - 1)
        let pastCap = atCap + "\u{0301}"

        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, atCap + "\r\n" + pastCap)

        let snapshot = try snapshot(session)
        #expect(snapshot.clusters[0] == atCap)
        #expect(snapshot.clusters[snapshot.columns] == nil)
        #expect(snapshot.cells[snapshot.columns].codepoint == 0x65)
    }
}
