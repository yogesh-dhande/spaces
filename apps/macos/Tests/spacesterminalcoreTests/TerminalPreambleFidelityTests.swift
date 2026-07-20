import Foundation
import Testing
import ghosttyvtshim

@testable import spacesterminalcore

/// Fidelity of the state preamble the transcript trimmer writes at the head of a trimmed transcript
/// (`spaces_ghostty_vt_session_state_preamble`) and its grid repaint. These exercise the shim's C
/// painter directly (build a source session, generate a preamble, replay it) rather than going
/// through `TerminalTranscriptTrim`, so they can target smaller replay sizes, multi-codepoint
/// graphemes, and palette-indexed colors that the trim tests do not cover.
@Suite struct TerminalPreambleFidelityTests {
    // MARK: - Low-level session helpers

    /// Creates a shim session or fails the test. When libghostty-vt is unavailable `session_new`
    /// returns NULL; `#require` surfaces that as an explicit failure (matching the trim tests' unwrap).
    private func makeSession(columns: UInt16 = 80, rows: UInt16 = 24, scrollback: Int = 0) throws -> OpaquePointer {
        try #require(spaces_ghostty_vt_session_new(columns, rows, scrollback, nil))
    }

    private func write(_ session: OpaquePointer, _ text: String) {
        let data = Data(text.utf8)
        let ok = data.withUnsafeBytes {
            spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        #expect(ok)
    }

    /// The bytes of `spaces_ghostty_vt_session_state_preamble` for the session's current state.
    private func preamble(_ session: OpaquePointer) throws -> Data {
        var pointer: UnsafeMutablePointer<CChar>?
        var length = 0
        #expect(spaces_ghostty_vt_session_state_preamble(session, &pointer, &length))
        let pointer2 = try #require(pointer)
        defer { spaces_ghostty_vt_free_buffer(pointer2) }
        return pointer2.withMemoryRebound(to: UInt8.self, capacity: length) {
            Data(bytes: $0, count: length)
        }
    }

    private func replay(_ data: Data, columns: UInt16 = 80, rows: UInt16 = 24, scrollback: Int = 0) throws -> OpaquePointer {
        let session = try makeSession(columns: columns, rows: rows, scrollback: scrollback)
        let ok = data.withUnsafeBytes {
            spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        #expect(ok)
        return session
    }

    /// The visible viewport as one string per row, blanks rendered as spaces, via the shim snapshot.
    private func visibleRows(_ session: OpaquePointer) -> [String] {
        var snapshot = SpacesGhosttyVtSnapshot()
        guard spaces_ghostty_vt_session_copy_snapshot(session, &snapshot) else { return [] }
        defer { spaces_ghostty_vt_snapshot_free(&snapshot) }
        let columns = Int(snapshot.columns)
        let rows = Int(snapshot.rows)
        guard columns > 0, rows > 0, let cells = snapshot.cells else { return [] }
        var result: [String] = []
        result.reserveCapacity(rows)
        for row in 0..<rows {
            var line = ""
            for column in 0..<columns {
                let codepoint = cells[row * columns + column].codepoint
                let scalar = codepoint == 0 ? UnicodeScalar(0x20)! : (UnicodeScalar(codepoint) ?? UnicodeScalar(0x20)!)
                line.unicodeScalars.append(scalar)
            }
            result.append(line)
        }
        return result
    }

    private func dimensions(_ session: OpaquePointer) -> (columns: Int, rows: Int) {
        var snapshot = SpacesGhosttyVtSnapshot()
        guard spaces_ghostty_vt_session_copy_snapshot(session, &snapshot) else { return (0, 0) }
        defer { spaces_ghostty_vt_snapshot_free(&snapshot) }
        return (Int(snapshot.columns), Int(snapshot.rows))
    }

    private func plainText(_ session: OpaquePointer) -> String {
        var pointer: UnsafeMutablePointer<CChar>?
        var length = 0
        guard spaces_ghostty_vt_session_format_plain(session, &pointer, &length), let pointer2 = pointer else { return "" }
        defer { spaces_ghostty_vt_free_buffer(pointer2) }
        return String(decoding: UnsafeRawBufferPointer(UnsafeBufferPointer(start: pointer2, count: length)), as: UTF8.self)
    }

    private func occurrences(of needle: Data, in haystack: Data) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, in: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    private func marker(_ index: Int) -> String { "RMK\(String(format: "%03d", index))X" }

    // MARK: - FIX A: dimension tolerance (top-down flow instead of absolute CUP)

    /// A preamble that painted a 24-row static grid, replayed into a SMALLER 60x20 terminal, must keep
    /// every one of the newest 20 marker rows on its own line. The old painter homed each row with an
    /// absolute `CSI row;1 H`; at 20 rows the CUPs for rows 21-24 clamp onto the bottom row and destroy
    /// one another, so several markers vanish. Top-down flow painting (home once, `\r\n` between rows)
    /// makes the excess rows scroll like ordinary content, preserving them.
    @Test func dimensionTolerancePreservesRowsWhenReplayedSmaller() throws {
        let source = try makeSession(columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(source) }
        // Paint 24 distinct static rows with absolute addressing and no newlines, so nothing scrolls
        // in the source and every row carries a unique marker well under 60 columns wide.
        for index in 0..<24 { write(source, "\u{1B}[\(index + 1);1H\(marker(index))") }

        let bytes = try preamble(source)
        let replayed = try replay(bytes, columns: 60, rows: 20, scrollback: 64 * 1024)
        defer { spaces_ghostty_vt_session_free(replayed) }

        let rows = visibleRows(replayed)
        let joined = rows.joined(separator: "\n")

        // The newest 20 marker rows (indices 4...23) must each survive in the visible grid.
        for index in 4..<24 {
            #expect(joined.contains(marker(index)), "marker \(marker(index)) must survive replay at a smaller size")
        }

        // No visible row may hold two markers: that would prove one row was overwritten by another.
        for line in rows {
            let hits = (0..<24).filter { line.contains(marker($0)) }.count
            #expect(hits <= 1, "a single row must not carry two markers (overwrite): \(line)")
        }
    }

    // MARK: - Same-size identity

    /// Replayed at the original size, the preamble's grid repaint must reproduce the source grid
    /// exactly (belt-and-braces beside the trim-test equivalence checks).
    @Test func sameSizeReplayReproducesGrid() throws {
        let source = try makeSession(columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(source) }
        write(source, "\u{1B}[1;1H\u{2550}\u{2550} \u{6F22} HEADER \u{2550}\u{2550}")
        write(source, "\u{1B}[3;1Hplain middle row")
        write(source, "\u{1B}[24;1Hbottom row content")

        let bytes = try preamble(source)
        let replayed = try replay(bytes, columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(replayed) }

        #expect(visibleRows(replayed) == visibleRows(source), "same-size preamble replay must reproduce the source grid")
    }

    // MARK: - FIX B: multi-codepoint graphemes

    /// A cell whose content is a base letter plus a combining mark (`e` + U+0301) occupies one cell with
    /// two codepoints. The old painter emitted only the base codepoint, collapsing the cluster; the
    /// preamble bytes must instead carry the full cluster, and a replay must reproduce both codepoints.
    @Test func multiCodepointGraphemeSurvivesPreamble() throws {
        let source = try makeSession(columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(source) }
        // Enable grapheme clustering (mode 2027) so the base + combining mark share one cell.
        write(source, "\u{1B}[?2027h")
        write(source, "\u{1B}[1;1He\u{0301}")

        let bytes = try preamble(source)
        // U+0301 COMBINING ACUTE ACCENT encodes as 0xCC 0x81 in UTF-8; the base 'e' is 0x65.
        let combining = Data([0xCC, 0x81])
        #expect(bytes.range(of: combining) != nil, "preamble must carry the combining mark, not just the base codepoint")

        let replayed = try replay(bytes, columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(replayed) }
        #expect(plainText(replayed).contains("e\u{0301}"), "replayed grid must reproduce the full grapheme cluster")
    }

    // MARK: - FIX C: palette-indexed color semantics

    /// A palette-indexed foreground (SGR 31 -> palette index 1) must serialize as a palette SGR
    /// (`38;5;1`), so the viewer resolves it against the Spaces theme, while a genuinely truecolor
    /// foreground stays `38;2;r;g;b`. The old painter resolved every color to RGB against the snapshot's
    /// default palette, freezing palette cells to libghostty defaults and emitting truecolor for both.
    @Test func paletteColorsSerializeAsIndexedSgr() throws {
        let source = try makeSession(columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(source) }
        write(source, "\u{1B}[1;1H\u{1B}[31mA\u{1B}[0m\u{1B}[38;2;10;20;30mB\u{1B}[0m")

        let bytes = try preamble(source)

        #expect(bytes.range(of: Data("38;5;1".utf8)) != nil, "palette foreground must serialize as an indexed SGR (38;5;1)")
        #expect(bytes.range(of: Data("38;2;10;20;30".utf8)) != nil, "truecolor foreground must stay truecolor")
        // Exactly one truecolor foreground introducer: cell B only. A second would mean the palette cell
        // was frozen to resolved RGB.
        #expect(occurrences(of: Data("38;2;".utf8), in: bytes) == 1, "palette cell must not be serialized as truecolor")
    }

    // MARK: - Enabling change: in-place resize with reflow

    /// `spaces_ghostty_vt_session_resize` resizes the live terminal in place; render-state reads after
    /// the resize must report the new dimensions, and wraparound reflow must preserve content that now
    /// spans more rows than before.
    @Test func inPlaceResizeReflowsAndPreservesContent() throws {
        let session = try makeSession(columns: 80, rows: 24, scrollback: 64 * 1024)
        defer { spaces_ghostty_vt_session_free(session) }
        // A 60-column line, wider than the post-resize width, so it must reflow across two rows.
        let long = "START" + String(repeating: "a", count: 50) + "END"
        write(session, "\u{1B}[1;1H\(long)")

        #expect(spaces_ghostty_vt_session_resize(session, 40, 24), "resize must succeed")

        let dims = dimensions(session)
        #expect(dims.columns == 40, "render-state reads must reflect the new width")
        #expect(dims.rows == 24, "render-state reads must reflect the new height")

        let joined = visibleRows(session).joined()
        #expect(joined.contains("START"), "reflowed line head must survive the resize")
        #expect(joined.contains("END"), "reflowed line tail must survive the resize")
    }
}
