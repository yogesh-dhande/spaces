import Foundation
import ghosttyvtshim

/// Client-local scrollback for an ended terminal session. The session's process is gone, so there is
/// no daemon renderer left to scroll; instead the persisted output transcript is replayed into a
/// headless libghostty-vt session at the session's final grid size, and viewport scrolling happens
/// locally against that replay. The ended pane's initial paint stays the exact final daemon frame;
/// this replay takes over from the first scroll.
///
/// Not `@MainActor`: it is constructed off the main actor (replaying a large transcript can be slow)
/// and thereafter touched only on the main actor by its single owner, so it is `@unchecked Sendable`
/// purely to cross that one construction hop. Callers must not share it across threads.
public final class TerminalEndedSessionScrollbackModel: @unchecked Sendable {
    private let session: OpaquePointer

    /// Builds the replay session and writes the transcript into it. Fails (returns nil) when the vt
    /// session cannot be created or the transcript cannot be replayed, so the caller can mark
    /// scrollback unavailable rather than present a broken viewport.
    public init?(
        columns: Int, rows: Int, maxScrollbackBytes: Int = TerminalScrollbackBudget.defaultMaxBytes, theme: GhosttyThemeExport, transcript: Data
    ) {
        var packedTheme = GhosttyVtSessionBridge.packTheme(theme)
        guard
            let session = withUnsafePointer(
                to: &packedTheme,
                { themePointer in
                    spaces_ghostty_vt_session_new(UInt16(clamping: max(columns, 1)), UInt16(clamping: max(rows, 1)), maxScrollbackBytes, themePointer)
                })
        else { return nil }
        if !transcript.isEmpty {
            let replayed = transcript.withUnsafeBytes { rawBuffer in
                spaces_ghostty_vt_session_write(session, rawBuffer.bindMemory(to: UInt8.self).baseAddress, rawBuffer.count)
            }
            guard replayed else {
                spaces_ghostty_vt_session_free(session)
                return nil
            }
        }
        self.session = session
    }

    deinit { spaces_ghostty_vt_session_free(session) }

    /// Scrolls the replay viewport by `deltaRows` and returns the resulting snapshot, or nil when the
    /// viewport offset did not move (already at the top or bottom boundary) so the caller can skip
    /// pushing a duplicate frame. Mirrors the Linux daemon scroll handler's boundary check.
    public func scroll(deltaRows: Int) -> GhosttyTerminalSnapshot? {
        var before = SpacesGhosttyVtScrollbar()
        var after = SpacesGhosttyVtScrollbar()
        guard spaces_ghostty_vt_session_scroll_viewport_with_info(session, deltaRows, &before, &after) else { return nil }
        guard before.offset != after.offset else { return nil }
        return currentSnapshot()
    }

    public func currentSnapshot() -> GhosttyTerminalSnapshot {
        var rawSnapshot = SpacesGhosttyVtSnapshot()
        guard spaces_ghostty_vt_session_copy_snapshot(session, &rawSnapshot) else {
            return GhosttyTerminalSnapshot(
                columns: 0, rows: 0, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0, defaultBackgroundRGB: 0, cells: [])
        }
        defer { spaces_ghostty_vt_snapshot_free(&rawSnapshot) }
        return GhosttyVtSessionBridge.snapshot(from: rawSnapshot)
    }
}
