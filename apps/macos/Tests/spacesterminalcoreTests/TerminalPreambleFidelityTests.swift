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
        let ok = data.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        #expect(ok)
    }

    /// The bytes of `spaces_ghostty_vt_session_state_preamble` for the session's current state.
    private func preamble(_ session: OpaquePointer) throws -> Data {
        var pointer: UnsafeMutablePointer<CChar>?
        var length = 0
        #expect(spaces_ghostty_vt_session_state_preamble(session, &pointer, &length))
        let pointer2 = try #require(pointer)
        defer { spaces_ghostty_vt_free_buffer(pointer2) }
        return pointer2.withMemoryRebound(to: UInt8.self, capacity: length) { Data(bytes: $0, count: length) }
    }

    private func write(_ session: OpaquePointer, _ data: Data) {
        let ok = data.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        #expect(ok)
    }

    private func replay(_ data: Data, columns: UInt16 = 80, rows: UInt16 = 24, scrollback: Int = 0) throws -> OpaquePointer {
        let session = try makeSession(columns: columns, rows: rows, scrollback: scrollback)
        write(session, data)
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

    // MARK: - Paint-neutral margins across a resize

    /// A preamble is replayed at whatever size the terminal has then, which is not necessarily the size
    /// it was captured at: a handoff or a tail after the terminal was resized past the last trim replays
    /// it wider or narrower. Its paint-neutral margins therefore have to mean "this terminal's full
    /// extent", which is what the sequences' default extent parameters give — an explicit column count
    /// would pin the captured width, and since the region restore emits no DECSLRM at all when the
    /// captured margins were already full, nothing after it would widen the margin back out.
    ///
    /// The source enables DECLRMM because left/right margins are only installed while it is set; that is
    /// the state in which a pinned width is not silently ignored. The assertion is on output written
    /// AFTER the preamble, since a stale right margin shows up as that output wrapping early.
    @Test func paintNeutralMarginsFollowTheReplayWidthRatherThanTheCapturedOne() throws {
        let source = try makeSession(columns: 60, rows: 24)
        defer { spaces_ghostty_vt_session_free(source) }
        write(source, "\u{1B}[?69h")  // DECLRMM: left/right margins can be installed at all.
        write(source, "\u{1B}[3;1H\(marker(1))")
        write(source, "\u{1B}[1;1H")

        let bytes = try preamble(source)
        let replayed = try replay(bytes, columns: 100, rows: 24)
        defer { spaces_ghostty_vt_session_free(replayed) }
        let run = String(repeating: "X", count: 90)
        write(replayed, run)

        let rows = visibleRows(replayed)
        #expect(rows.first?.hasPrefix(run) == true, "output after the preamble must reach the replay terminal's right edge: \(rows.first ?? "")")
        #expect(rows.count > 2 && rows[2].hasPrefix(marker(1)), "the repaint must still land where it did: \(rows)")
    }

    // MARK: - Charset restoration

    /// A preamble is not only replayed into a blank terminal: a from-zero replay of a trimmed transcript
    /// reaches the head preamble with whatever state the file's earlier bytes established, and a program
    /// drawing box characters leaves GL invoking the DEC line-drawing set for as long as it draws. The
    /// repaint's own bytes would then be mapped through that set — the library translates ASCII through
    /// the table and renders anything above U+00FF as a space — so the preamble normalizes the invocation
    /// before painting and restores the captured designations after.
    @Test func repaintSurvivesReplayIntoATerminalWithACharsetInvoked() throws {
        let source = try makeSession(columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(source) }
        write(source, "\u{1B})0\u{000E}")  // G1 = DEC special graphics, invoked on GL and left invoked.
        write(source, "\u{1B}[1;1Hqqqqqqqq")  // Renders as a run of U+2500.
        write(source, "\u{1B}[3;1H\u{000F}plain row\u{000E}")

        let bytes = try preamble(source)
        let replayed = try makeSession(columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(replayed) }
        write(replayed, "\u{1B})0\u{000E}")
        write(replayed, bytes)

        #expect(visibleRows(replayed) == visibleRows(source), "the repaint must not be charset-mapped by the terminal it replays into")
    }

    // MARK: - Cursor restoration under origin mode

    /// The preamble restores the scrolling region before the cursor, because DECSTBM homes the cursor and
    /// would otherwise discard it. That ordering makes the cursor step subtle: with origin mode (DECOM)
    /// set, CUP is interpreted against the region's top-left corner while the library's cursor getters
    /// report absolute coordinates, so an absolute CUP lands a region's-worth of rows too low or clamps.
    /// Positioning with origin mode temporarily off is not available either — re-enabling it homes the
    /// cursor again — so the emitted coordinates have to be region-relative.
    ///
    /// Writing the same text into the source and into the replay is what makes this cell-level: the two
    /// grids can only match if the restored cursor sat on the same cell.
    @Test func cursorUnderOriginModeAndAScrollingRegionSurvivesPreamble() throws {
        let source = try makeSession(columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(source) }
        write(source, "\u{1B}[?6h")  // DECOM: CUP becomes region-relative.
        write(source, "\u{1B}[5;20r")  // Region rows 5...20; homes the cursor to its top-left.
        write(source, "\u{1B}[3;1H")  // Region-relative row 3, i.e. absolute row 7.

        let bytes = try preamble(source)
        let replayed = try replay(bytes, columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(replayed) }

        write(source, marker(1))
        write(replayed, marker(1))

        #expect(visibleRows(replayed) == visibleRows(source), "the preamble's cursor must land on the same cell under origin mode")
    }

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
        for index in 4..<24 { #expect(joined.contains(marker(index)), "marker \(marker(index)) must survive replay at a smaller size") }

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

    /// A degenerate cell whose cluster is one base letter followed by tens of thousands of combining
    /// marks must not crash or corrupt preamble construction. The shim sizes its grapheme buffer from a
    /// uint16_t and the library writes the full reported cluster length, so a count above 0xFFFF must
    /// fall back to the base codepoint alone rather than overflow the buffer. The contract this guards is
    /// only that the preamble still builds and the base character survives; the excess combining marks may
    /// be dropped. (Ghostty's internal storage may cap the cluster below 65,535, in which case this input
    /// never reaches the overflow path; the test still stands as the regression guard for the contract.)
    @Test func oversizedGraphemeClusterDoesNotCorruptPreamble() throws {
        let source = try makeSession(columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(source) }
        // Grapheme clustering (mode 2027) folds the base + every combining mark into one cell, with no
        // cursor movement between them, so the single cell reports an enormous cluster length.
        write(source, "\u{1B}[?2027h")
        write(source, "\u{1B}[1;1HZ" + String(repeating: "\u{0301}", count: 70_000))
        write(source, "\u{1B}[3;1Hordinary trailing row")

        let bytes = try preamble(source)

        let replayed = try replay(bytes, columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(replayed) }
        // Match on unicode scalars: when the library caps the cluster below the shim's uint16_t limit,
        // the replayed cell is the base plus the retained combining marks, which as a Swift grapheme
        // cluster is not equal to "Z" even though the base codepoint survived.
        #expect(
            plainText(replayed).unicodeScalars.contains { $0 == "Z" },
            "the base codepoint of a degenerate cluster must survive preamble replay")
        #expect(plainText(replayed).contains("ordinary trailing row"), "content after a degenerate cluster must survive")
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

    // MARK: - Extended text decorations (blink / overline / underline style + color)

    /// Blink, overline, underline STYLE (double/curly/dotted/dashed), and underline COLOR must survive
    /// the transcript preamble. The pen used to be built only from `spaces_ghostty_vt_flags_for_style`,
    /// which retains a generic underline bit but drops the underline *variant* and color and has no
    /// blink/overline bits at all, so before the fix these attributes plained out: every underline
    /// emitted as a bare `;4` and blink/overline/underline-color were dropped entirely, durably losing
    /// them from the rewritten transcript.
    ///
    /// The oracle here is a ROUND-TRIP FIXPOINT of the preamble, not the client snapshot: the snapshot
    /// pipeline (`GhosttyTerminalSnapshot.Cell.flags`) deliberately renders only a subset of decorations
    /// and cannot represent underline variant/color or overline, so it cannot witness these attributes.
    /// Instead we assert the source preamble carries the emitted colon-form fragments, then replay it and
    /// assert the replayed session's preamble carries the SAME fragments — which only holds if the pinned
    /// libghostty-vt actually parsed the colon forms and retained them in cell style state.
    @Test func extendedTextDecorationsSurvivePreamble() throws {
        let source = try makeSession(columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(source) }
        // Each cell is preceded by a full reset so its pen is isolated; the reset-first emitter then
        // reproduces each pen deterministically from the cell alone.
        write(source, "\u{1B}[1;1H")
        write(source, "\u{1B}[0m\u{1B}[4:3m\u{1B}[58:5:196mC")  // curly underline + palette-196 underline color
        write(source, "\u{1B}[0m\u{1B}[4:2mD")  // double underline
        write(source, "\u{1B}[0m\u{1B}[5mB")  // blink
        write(source, "\u{1B}[0m\u{1B}[53mO")  // overline
        write(source, "\u{1B}[0m\u{1B}[4m\u{1B}[58:2::10:20:30mR")  // single underline + RGB underline color

        // Distinctive, pen-boundary-anchored fragments (avoid substring collisions such as ";5" inside
        // ";53" or "58:5"). The blink-only and overline-only cells assert the whole reset-first pen.
        let fragments: [(String, Data)] = [
            ("curly underline variant", Data("4:3".utf8)), ("palette underline color", Data("58:5:196".utf8)),
            ("double underline variant", Data("4:2".utf8)), ("blink pen", Data("[0;5m".utf8)), ("overline pen", Data("[0;53m".utf8)),
            ("rgb underline color", Data("58:2::10:20:30".utf8)),
        ]

        let sourceBytes = try preamble(source)
        for (label, fragment) in fragments { #expect(sourceBytes.range(of: fragment) != nil, "source preamble must carry \(label)") }

        let replayed = try replay(sourceBytes, columns: 80, rows: 24)
        defer { spaces_ghostty_vt_session_free(replayed) }
        let replayedBytes = try preamble(replayed)
        for (label, fragment) in fragments { #expect(replayedBytes.range(of: fragment) != nil, "replayed preamble must carry \(label) (round-trip)") }
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

    // MARK: - Wide glyph ending at the right edge

    /// A two-column glyph whose spacer lands on the final column fills the row: its leading cell (the
    /// last content cell) sits at `columns-2`, so a naive `last_content_column < columns-1` check emits
    /// a trailing `CSI K`. On replay the cursor sits in deferred-wrap on the last column after printing
    /// the glyph, and EL erases the just-painted wide glyph (terminals clear the whole glyph when asked
    /// to erase half of it). Feeding `AA漢` into a 4-column grid puts 漢's spacer exactly on the last
    /// column; same-size replay must keep the glyph intact.
    @Test func wideGlyphAtRightEdgeSurvivesReplay() throws {
        let source = try makeSession(columns: 4, rows: 4)
        defer { spaces_ghostty_vt_session_free(source) }
        write(source, "\u{1B}[1;1HAA\u{6F22}")  // 漢 is a two-column glyph filling columns 2-3.

        let bytes = try preamble(source)
        let replayed = try replay(bytes, columns: 4, rows: 4)
        defer { spaces_ghostty_vt_session_free(replayed) }

        #expect(visibleRows(replayed) == visibleRows(source), "wide glyph ending at the right edge must survive same-size replay")
        #expect(plainText(replayed).contains("\u{6F22}"), "the wide glyph must not be erased by a trailing EL")
    }

    /// A wide glyph followed by genuine blank cells still needs a trailing EL to clear them; the
    /// spacer-aware check must advance only past the glyph's own spacer, not suppress EL for real
    /// blanks that follow. `漢` at the start of a 6-column row leaves columns 2-5 blank, so the
    /// preamble must still carry an EL.
    @Test func wideGlyphWithTrailingBlanksStillClears() throws {
        let source = try makeSession(columns: 6, rows: 4)
        defer { spaces_ghostty_vt_session_free(source) }
        write(source, "\u{1B}[1;1H\u{6F22}")  // 漢 fills columns 0-1; columns 2-5 stay blank.

        let bytes = try preamble(source)
        #expect(bytes.range(of: Data("\u{1B}[K".utf8)) != nil, "trailing blank cells after a wide glyph must still emit EL")

        let replayed = try replay(bytes, columns: 6, rows: 4)
        defer { spaces_ghostty_vt_session_free(replayed) }
        #expect(visibleRows(replayed) == visibleRows(source), "wide glyph with trailing blanks must replay identically")
    }
}
