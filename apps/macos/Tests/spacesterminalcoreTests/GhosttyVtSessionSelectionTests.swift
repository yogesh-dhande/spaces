import Foundation
import Testing
import ghosttyvtshim

/// The shim's range-text, select-all and scroll-rect entry points, exercised against the real dynamic
/// libghostty-vt. The daemon holds no selection of its own: a client asks it to format an explicit
/// range of screen-space coordinates for a copy, to report the extent a select-all would cover, and to
/// drain render scroll-rect hints for delta frames.
@Suite struct GhosttyVtSessionSelectionTests {
    private func makeSession(columns: UInt16 = 20, rows: UInt16 = 3, maxScrollback: Int = 1 << 20) throws -> OpaquePointer {
        try #require(spaces_ghostty_vt_session_new(columns, rows, maxScrollback, nil))
    }

    private func write(_ session: OpaquePointer, _ text: String) {
        let data = Data(text.utf8)
        #expect(data.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
    }

    private func takeScrollRects(_ session: OpaquePointer, capacity: Int = 64) -> [SpacesGhosttyVtScrollRect] {
        var buffer = Array(repeating: SpacesGhosttyVtScrollRect(), count: capacity)
        let written = buffer.withUnsafeMutableBufferPointer {
            spaces_ghostty_vt_session_take_scroll_rects(session, $0.baseAddress, $0.count)
        }
        return Array(buffer.prefix(written))
    }

    private func rangeText(_ session: OpaquePointer, startX: UInt16, startY: UInt32, endX: UInt16, endY: UInt32, rectangle: Bool = false) -> String? {
        var length = 0
        guard let pointer = spaces_ghostty_vt_session_range_text_copy(session, startX, startY, endX, endY, rectangle, &length) else { return nil }
        defer { spaces_ghostty_vt_session_selection_text_free(pointer) }
        return pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
            String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
        }
    }

    // MARK: - Range text

    @Test func rangeTextFormatsAnExplicitRange() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "hello world   \r\nsecond line")

        #expect(rangeText(session, startX: 6, startY: 0, endX: 19, endY: 1) == "world\nsecond line")
        #expect(rangeText(session, startX: 6, startY: 0, endX: 9, endY: 1, rectangle: true) == "worl\n lin")
    }

    /// Copy semantics match Ghostty's own Screen.selectionString(): soft-wrapped lines are unwrapped
    /// into one logical line with no inserted newline at the wrap boundary.
    @Test func rangeTextUnwrapsASoftWrappedLine() throws {
        let session = try makeSession(columns: 10, rows: 3)
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "abcdefghijklmno")  // wraps: row 0 "abcdefghij", row 1 "klmno"

        #expect(rangeText(session, startX: 0, startY: 0, endX: 4, endY: 1) == "abcdefghijklmno")
    }

    /// Trailing whitespace on a non-blank line is trimmed even when the range spans the row's full
    /// width, matching copy/clipboard semantics rather than a literal grid dump.
    @Test func rangeTextTrimsTrailingWhitespace() throws {
        let session = try makeSession(columns: 10, rows: 3)
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "hi\r\nthere")

        #expect(rangeText(session, startX: 0, startY: 0, endX: 9, endY: 0) == "hi")
    }

    // MARK: - Select all

    @Test func selectAllStateReportsTheFirstToLastNonBlankCell() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "  first\r\n\r\nlast   \r\n")

        var state = SpacesGhosttyVtSelectionState()
        #expect(spaces_ghostty_vt_session_select_all_state(session, &state))

        #expect(state.present)
        #expect((state.start_x, state.start_y, state.end_x, state.end_y) == (2, 0, 3, 2))
    }

    @Test func selectAllStateOfABlankScreenIsAbsent() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        var state = SpacesGhosttyVtSelectionState()
        #expect(spaces_ghostty_vt_session_select_all_state(session, &state))

        #expect(!state.present)
    }

    // MARK: - Scroll rects

    /// Writing past the bottom of a short terminal accumulates a render scroll-rect hint with a
    /// negative row delta (content shifted up). The first drain after that reports it; an immediate
    /// second drain reports nothing, since the pending buffer was already cleared.
    ///
    /// Kept to exactly one row past the 3-row active area on purpose: the terminal's internal pending
    /// buffer holds at most 64 rects before discarding everything and reporting overflow, and each
    /// additional wrapped line past the bottom consumes that budget much faster than one entry per
    /// scroll (observed empirically; the exact accounting is an internal library detail).
    @Test func takeScrollRectsReportsPendingRectsOnceThenDrainsToEmpty() throws {
        let session = try makeSession(columns: 20, rows: 3, maxScrollback: 1 << 20)
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "line0\r\nline1\r\nline2\r\nline3\r\n")  // one line past the 3-row active area

        let first = takeScrollRects(session)
        #expect(!first.isEmpty)
        #expect(first.contains { $0.delta_rows < 0 })

        let second = takeScrollRects(session)
        #expect(second.isEmpty)
    }
}
