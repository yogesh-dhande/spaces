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

    /// Builds the replay session and writes the transcript into it. Fails (returns nil) when the vt
    /// session cannot be created or the transcript cannot be replayed, so the caller can mark
    /// scrollback unavailable rather than present a broken viewport.
    init?(columns: Int, rows: Int, maxScrollbackBytes: Int, theme: GhosttyThemeExport, appearance: ThemeAppearance, transcript: Data) {
        var packedTheme = GhosttyVtSessionBridge.packTheme(theme, appearance: appearance)
        guard
            let session = withUnsafePointer(
                to: &packedTheme,
                { themePointer in
                    spaces_ghostty_vt_session_new(UInt16(clamping: max(columns, 1)), UInt16(clamping: max(rows, 1)), maxScrollbackBytes, themePointer)
                })
        else { return nil }
        self.session = session
        guard write(transcript) else {
            spaces_ghostty_vt_session_free(session)
            return nil
        }
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

    /// Scrolls the replay viewport by `deltaRows` and returns the resulting snapshot, or nil when the
    /// viewport offset did not move (already at the top or bottom boundary) so the caller can skip
    /// pushing a duplicate frame. Mirrors the Linux daemon scroll handler's boundary check.
    func scroll(deltaRows: Int) -> GhosttyTerminalSnapshot? {
        var before = SpacesGhosttyVtScrollbar()
        var after = SpacesGhosttyVtScrollbar()
        guard spaces_ghostty_vt_session_scroll_viewport_with_info(session, deltaRows, &before, &after) else { return nil }
        guard before.offset != after.offset else { return nil }
        return currentSnapshot()
    }

    func currentSnapshot() -> GhosttyTerminalSnapshot {
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
            from: rawSnapshot, mouseReportingActive: false, alternateScreenActive: GhosttyVtSessionBridge.alternateScreenActive(session: session))
    }

    /// The replay's current scrollbar, or nil when the underlying query fails.
    func scrollbar() -> TerminalScrollbackReplayScrollbar? {
        var raw = SpacesGhosttyVtScrollbar()
        guard spaces_ghostty_vt_session_scrollbar(session, &raw) else { return nil }
        return TerminalScrollbackReplayScrollbar(total: Int(raw.total), offset: Int(raw.offset), rows: Int(raw.len))
    }
}
