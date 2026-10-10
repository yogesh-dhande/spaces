import Foundation
import ghosttyvtshim

/// The headless libghostty-vt session every client-local scrollback replay scrolls against. It owns the
/// C session pointer and the byte-level replay, and nothing else; the byte accounting and paging rules
/// live in `TerminalLocalScrollbackModel`, which is the only thing that builds one.
///
/// Not `@MainActor`: it is constructed off the main actor (replaying a large transcript can be slow)
/// and thereafter touched only on the main actor by its single owner, so it is `@unchecked Sendable`
/// purely to cross that one construction hop. Callers must not share it across threads.
final class TerminalScrollbackReplaySession: @unchecked Sendable {
    private let session: OpaquePointer

    /// Builds an empty replay session; the caller writes the transcript into it, in as many pieces as it
    /// needs to read the session's state between them. Fails (returns nil) when the vt session cannot be
    /// created, so the caller can mark scrollback unavailable rather than present a broken viewport.
    init?(columns: Int, rows: Int, maxScrollbackBytes: Int, theme: GhosttyThemeExport, appearance: ThemeAppearance) {
        var packedTheme = GhosttyVtSessionBridge.packTheme(theme, appearance: appearance)
        guard
            let session = withUnsafePointer(
                to: &packedTheme,
                { themePointer in
                    spaces_ghostty_vt_session_new(UInt16(clamping: max(columns, 1)), UInt16(clamping: max(rows, 1)), maxScrollbackBytes, themePointer)
                })
        else { return nil }
        self.session = session
    }

    deinit { spaces_ghostty_vt_session_free(session) }

    /// Replays more transcript bytes into the session. Empty input succeeds without touching the
    /// terminal. The session never enables libghostty-vt's event sink, so replayed bells and clipboard
    /// writes stay inert (see `spaces_ghostty_vt_session_enable_events`).
    @discardableResult func write(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty else { return true }
        return bytes.withUnsafeBytes { rawBuffer in
            spaces_ghostty_vt_session_write(session, rawBuffer.bindMemory(to: UInt8.self).baseAddress, rawBuffer.count)
        }
    }

    /// Scrolls the replay viewport by `deltaRows` and reports whether the viewport offset moved (false at
    /// the top or bottom boundary) so the caller can skip pushing a duplicate frame. Mirrors the Linux
    /// daemon scroll handler's boundary check.
    func scroll(deltaRows: Int) -> Bool {
        var before = SpacesGhosttyVtScrollbar()
        var after = SpacesGhosttyVtScrollbar()
        guard spaces_ghostty_vt_session_scroll_viewport_with_info(session, deltaRows, &before, &after) else { return false }
        return before.offset != after.offset
    }

    /// The replay's history position: scrollbar, rows pruned off its top, and its history epoch, read
    /// together. Nil only for an invalid session (see `TerminalLocalScrollbackModel.scrollbar`).
    func historyPosition() -> SpacesGhosttyVtHistoryPosition? {
        var position = SpacesGhosttyVtHistoryPosition()
        guard spaces_ghostty_vt_session_history_position(session, &position) else { return nil }
        return position
    }

    /// The text of screen rows `[startRow, endRow]` (row 0 is the oldest row the replay holds) in the
    /// shim's copy format, without touching the session's own selection. Endpoints must be ordered; a
    /// rectangle's columns may come in either order.
    func text(startColumn: Int, startRow: Int, endColumn: Int, endRow: Int, isRectangle: Bool) -> String? {
        var length = 0
        guard
            let pointer = spaces_ghostty_vt_session_range_text_copy(
                session, UInt16(clamping: startColumn), UInt32(clamping: startRow), UInt16(clamping: endColumn), UInt32(clamping: endRow),
                isRectangle, &length)
        else { return nil }
        defer { spaces_ghostty_vt_session_selection_text_free(pointer) }
        return pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
            String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
        }
    }

    /// libghostty-vt's select-all span in screen rows, nil when the replay holds no text.
    func selectAllSpan() -> (startColumn: Int, startRow: Int, endColumn: Int, endRow: Int)? {
        var state = SpacesGhosttyVtSelectionState()
        guard spaces_ghostty_vt_session_select_all_state(session, &state), state.present else { return nil }
        return (Int(state.start_x), Int(state.start_y), Int(state.end_x), Int(state.end_y))
    }

    /// The snapshot of the viewport, stamped with the history coordinates the caller resolved for it.
    func currentSnapshot(historyRowBase: UInt64, historyEpoch: UInt64) -> GhosttyTerminalSnapshot {
        var rawSnapshot = SpacesGhosttyVtSnapshot()
        guard spaces_ghostty_vt_session_copy_snapshot(session, &rawSnapshot) else {
            return GhosttyTerminalSnapshot(
                columns: 0, rows: 0, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0, defaultBackgroundRGB: 0, cells: [])
        }
        defer { spaces_ghostty_vt_snapshot_free(&rawSnapshot) }
        // The replay has no child process to report to, so its transcript's mouse modes are inert. The
        // active screen is read from the session itself: the replayed bytes can leave the terminal on the
        // alternate screen, and a frame that misreported that would describe a screen the replay is not on.
        return GhosttyVtSessionBridge.snapshot(
            from: rawSnapshot, mouseTrackingLevel: .none, alternateScreenActive: GhosttyVtSessionBridge.alternateScreenActive(session: session),
            historyRowBase: historyRowBase, historyEpoch: historyEpoch)
    }

    func scrollbar() -> TerminalScrollbackReplayScrollbar? {
        var raw = SpacesGhosttyVtScrollbar()
        guard spaces_ghostty_vt_session_scrollbar(session, &raw) else { return nil }
        return TerminalScrollbackReplayScrollbar(total: Int(raw.total), offset: Int(raw.offset), rows: Int(raw.len))
    }
}
