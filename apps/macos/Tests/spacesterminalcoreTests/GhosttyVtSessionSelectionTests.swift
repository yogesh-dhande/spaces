import Foundation
import Testing
import ghosttyvtshim

/// The shim's selection and scroll-rect entry points, exercised against the real dynamic
/// libghostty-vt. These back the host-anchored selection feature: the daemon owns the terminal's
/// selection state and must be able to set it from a drag, read it back in screen-space coordinates,
/// format it to text for a copy, detect when scrollback trimming garbages a tracked endpoint, and
/// drain render scroll-rect hints.
@Suite struct GhosttyVtSessionSelectionTests {
    private func makeSession(columns: UInt16 = 20, rows: UInt16 = 3, maxScrollback: Int = 1 << 20) throws -> OpaquePointer {
        try #require(spaces_ghostty_vt_session_new(columns, rows, maxScrollback, nil))
    }

    private func write(_ session: OpaquePointer, _ text: String) {
        let data = Data(text.utf8)
        #expect(data.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
    }

    @discardableResult
    private func setSelection(
        _ session: OpaquePointer, startX: UInt16, startY: UInt32, endX: UInt16, endY: UInt32, rectangle: Bool = false
    ) -> Bool {
        spaces_ghostty_vt_session_set_selection(session, startX, startY, endX, endY, rectangle)
    }

    private func selectionState(_ session: OpaquePointer) throws -> SpacesGhosttyVtSelectionState {
        var state = SpacesGhosttyVtSelectionState()
        try #require(spaces_ghostty_vt_session_selection_state(session, &state))
        return state
    }

    private func selectionText(_ session: OpaquePointer) -> String? {
        var length = 0
        guard let pointer = spaces_ghostty_vt_session_selection_text_copy(session, &length) else { return nil }
        defer { spaces_ghostty_vt_session_selection_text_free(pointer) }
        return pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
            String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
        }
    }

    private func takeScrollRects(_ session: OpaquePointer, capacity: Int = 64) -> (rects: [SpacesGhosttyVtScrollRect], overflowed: Bool) {
        var buffer = Array(repeating: SpacesGhosttyVtScrollRect(), count: capacity)
        var overflowed = false
        let written = buffer.withUnsafeMutableBufferPointer {
            spaces_ghostty_vt_session_take_scroll_rects(session, $0.baseAddress, $0.count, &overflowed)
        }
        return (Array(buffer.prefix(written)), overflowed)
    }

    // MARK: - Set + read back

    @Test func readsBackTheCoordinatesAndRectangleFlagJustSet() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "hello world")

        #expect(setSelection(session, startX: 1, startY: 0, endX: 5, endY: 0, rectangle: true))
        let state = try selectionState(session)
        #expect(state.present)
        #expect(state.valid)
        #expect(state.rectangle)
        #expect(state.start_x == 1)
        #expect(state.start_y == 0)
        #expect(state.end_x == 5)
        #expect(state.end_y == 0)
    }

    /// GhosttySelection's own endpoints preserve drag direction and may be reversed; the state getter
    /// flattens that so callers always get (start_y, start_x) <= (end_y, end_x) regardless of which
    /// end the drag started from.
    @Test func ordersReversedEndpointsIntoForwardSpan() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "line one\r\nline two")

        #expect(setSelection(session, startX: 5, startY: 1, endX: 2, endY: 0))
        let state = try selectionState(session)
        #expect(state.present)
        #expect(state.valid)
        #expect(state.start_x == 2)
        #expect(state.start_y == 0)
        #expect(state.end_x == 5)
        #expect(state.end_y == 1)
    }

    /// A caller tracking a drag past the edge of live content does not have to clamp itself: the shim
    /// clamps into the terminal's current screen extent (columns against the session's column count,
    /// rows against the scrollbar's total row count) before resolving.
    @Test func clampsOutOfRangeCoordinatesToTheCurrentScreenExtent() throws {
        let session = try makeSession(columns: 20, rows: 3)
        defer { spaces_ghostty_vt_session_free(session) }

        #expect(setSelection(session, startX: 0, startY: 0, endX: 9_999, endY: 9_999))
        let state = try selectionState(session)
        #expect(state.present)
        #expect(state.valid)
        #expect(state.end_x == 19) // columns - 1
        #expect(state.end_y == 2) // rows - 1, no scrollback yet
    }

    @Test func reportsNoSelectionBeforeAnyIsSet() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        let state = try selectionState(session)
        #expect(!state.present)
        #expect(!state.valid)
        #expect(state.start_x == 0)
        #expect(state.start_y == 0)
        #expect(state.end_x == 0)
        #expect(state.end_y == 0)
    }

    // MARK: - Text copy

    /// Copy semantics match Ghostty's own Screen.selectionString(): soft-wrapped lines are unwrapped
    /// into one logical line with no inserted newline at the wrap boundary.
    @Test func selectionTextCopyUnwrapsASoftWrappedLine() throws {
        let session = try makeSession(columns: 10, rows: 3)
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "abcdefghijklmno") // wraps: row 0 "abcdefghij", row 1 "klmno"

        #expect(setSelection(session, startX: 0, startY: 0, endX: 4, endY: 1))
        #expect(selectionText(session) == "abcdefghijklmno")
    }

    /// Trailing whitespace on a non-blank line is trimmed even when the selection spans the row's
    /// full width, matching copy/clipboard semantics rather than a literal grid dump.
    @Test func selectionTextCopyTrimsTrailingWhitespace() throws {
        let session = try makeSession(columns: 10, rows: 3)
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "hi\r\nthere")

        #expect(setSelection(session, startX: 0, startY: 0, endX: 9, endY: 0))
        #expect(selectionText(session) == "hi")
    }

    @Test func selectionTextCopyReturnsNilWithoutAnActiveSelection() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "hello")
        #expect(selectionText(session) == nil)
    }

    // MARK: - Tracked anchoring

    /// A selection anchored to a row stays pinned to that same physical row (and so reads back with
    /// unchanged screen-space coordinates) across writes that grow scrollback without trimming it.
    @Test func selectionStaysAnchoredWithUnchangedCoordinatesAcrossWritesThatDoNotTrim() throws {
        let session = try makeSession(columns: 20, rows: 3, maxScrollback: 1 << 20)
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "line0\r\nline1\r\nline2\r\nline3\r\n")

        #expect(setSelection(session, startX: 0, startY: 0, endX: 4, endY: 0)) // anchors to the oldest row
        let before = try selectionState(session)
        #expect(before.present && before.valid)

        write(session, "line4\r\nline5\r\n") // grows scrollback, well under the byte cap: no trim

        let after = try selectionState(session)
        #expect(after.present)
        #expect(after.valid)
        #expect(after.start_x == before.start_x)
        #expect(after.start_y == before.start_y)
        #expect(after.end_x == before.end_x)
        #expect(after.end_y == before.end_y)
    }

    /// When scrollback trimming discards the page a tracked endpoint pins into, the terminal still
    /// reports a selection but marks it invalid, and its coordinates collapse to a meaningless
    /// position rather than the trimmed-away original: `selection_state` reports that as
    /// present-but-not-valid with zeroed coordinates, not as absent.
    @Test func trimmingThePinnedRowMarksTheSelectionPresentButInvalid() throws {
        // A tiny byte budget so a handful of additional rows force the oldest row out of scrollback.
        // libghostty-vt only prunes scrollback at "page" granularity (roughly 400KB per page at the
        // time of writing), so the byte limit is a lower bound rather than an exact cutoff: pruning
        // only removes *completed* historical pages once more than one has accumulated. A tiny
        // configured limit still needs several hundred KB of filler behind the selected row before an
        // old page is actually evicted.
        let session = try makeSession(columns: 20, rows: 3, maxScrollback: 1)
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "line0000000000000000\r\n")

        #expect(setSelection(session, startX: 0, startY: 0, endX: 4, endY: 0)) // anchors to the row now being trimmed
        let before = try selectionState(session)
        #expect(before.present && before.valid)

        let filler = String(repeating: "abcdefghijklmnopqrst\r\n", count: 100_000) // ~2.3MB, several pages
        write(session, filler)

        let after = try selectionState(session)
        #expect(after.present)
        #expect(!after.valid)
        #expect(after.start_x == 0)
        #expect(after.start_y == 0)
        #expect(after.end_x == 0)
        #expect(after.end_y == 0)
    }

    @Test func clearSelectionReportsNotPresent() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "hello")
        #expect(setSelection(session, startX: 0, startY: 0, endX: 4, endY: 0))
        #expect((try selectionState(session)).present)

        spaces_ghostty_vt_session_clear_selection(session)

        let state = try selectionState(session)
        #expect(!state.present)
        #expect(!state.valid)
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
        write(session, "line0\r\nline1\r\nline2\r\nline3\r\n") // one line past the 3-row active area

        let first = takeScrollRects(session)
        #expect(!first.overflowed)
        #expect(!first.rects.isEmpty)
        #expect(first.rects.contains { $0.delta_rows < 0 })

        let second = takeScrollRects(session)
        #expect(!second.overflowed)
        #expect(second.rects.isEmpty)
    }
}
