import Foundation

/// Client-local scrollback: a replay of a session's persisted output transcript that a client scrolls
/// by itself, with the daemon never told about the scroll.
///
/// One model serves both callers. An ended pane has no daemon renderer left to scroll, so the replay is
/// the only scrollback there is. A live session has one, but scrolling it costs a network round trip per
/// step, so a client scrolls this replay instead and the session's own viewport stays where it is.
///
/// The replay's oldest row is only as old as the bytes it was built from, so it records where those
/// bytes sit in `output.log`:
///
/// - `transcriptStartByteOffset` is the first transcript byte the replay holds. Zero means it holds the
///   whole file and no deeper read exists.
/// - `transcriptEndByteOffset` is where the bytes end, so live output produced after the fetch is
///   appended with a read of exactly `[end, newTotal)` rather than by rebuilding the replay.
/// - `transcriptFileIdentity` names the `output.log` those bytes were read from, which the next
///   continuation read sends back as proof the offset still names them: a head-trim rewrites the
///   transcript and renames the rewrite into its place, so the file the offsets belong to is what tells
///   a rewritten transcript from an appended one.
/// - `requestedByteCount` is how many bytes the read that built this replay asked the daemon for, which
///   is what says whether asking again could return more. The bytes actually returned differ (a capped
///   suffix is cut at a parser-safe boundary and carries a synthesized state preamble), so paging off
///   the returned count would ask for the same suffix again on every gesture.
///
/// Not `@MainActor`: it is constructed off the main actor (replaying a page of transcript can be slow)
/// and thereafter touched only on the main actor by its single owner, so it is `@unchecked Sendable`
/// purely to cross that one construction hop. Callers must not share it across threads.
public final class TerminalLocalScrollbackModel: @unchecked Sendable {
    /// What one scroll did: the snapshot to paint, absent when the viewport did not move at all, and the
    /// rows the replay could not apply because it reached a boundary. `unappliedRows` carries the sign of
    /// the delta that produced it, so a caller that pages deeper applies it to the deeper replay exactly
    /// as the gesture's own rows are applied.
    public struct Scroll: Sendable {
        public let snapshot: GhosttyTerminalSnapshot?
        public let unappliedRows: Int
    }

    private let replay: TerminalScrollbackReplaySession
    private let maxScrollbackBytes: Int
    private let theme: GhosttyThemeExport
    private let appearance: ThemeAppearance
    /// The grid this replay was built at, which is the grid the session's own frames carried. A session
    /// that has resized since holds rows this replay would wrap differently, so its owner rebuilds rather
    /// than scrolls.
    public let columns: Int
    public let rows: Int
    /// The run of the session these bytes were read from, so a later read that straddles a relaunch
    /// (which truncates `output.log`) is rejected rather than appended under the earlier run's rows.
    public let runIdentity: String?
    /// How many bytes the read that built this replay asked the daemon for. See the type's note: the
    /// returned bytes differ, so this is what the paging decisions are made against.
    public let requestedByteCount: Int
    /// Where this replay's transcript bytes begin in the session's `output.log`.
    public let transcriptStartByteOffset: UInt64
    /// Where this replay's transcript bytes end in the session's `output.log`. The next continuation
    /// fetch starts here.
    public private(set) var transcriptEndByteOffset: UInt64
    /// The `output.log` this replay's bytes were read from, which the next continuation read sends back
    /// so the daemon can tell an appended transcript from a rewritten one. Nil when the read carried no
    /// identity, which the daemon answers as a rebuild rather than a continuation.
    public let transcriptFileIdentity: UInt64?

    /// Builds the replay from the bytes a `terminalTranscript` read returned. `transcript` is what the
    /// daemon served, which for a suffix read is a state preamble followed by the file's bytes from
    /// `transcriptStartByteOffset`; `requestedByteCount` is what that read asked for.
    public init?(
        columns: Int, rows: Int, maxScrollbackBytes: Int = TerminalScrollbackBudget.defaultMaxBytes, theme: GhosttyThemeExport,
        appearance: ThemeAppearance, transcript: Data, transcriptStartByteOffset: UInt64, transcriptEndByteOffset: UInt64, requestedByteCount: Int,
        transcriptFileIdentity: UInt64?, runIdentity: String?
    ) {
        guard
            let replay = TerminalScrollbackReplaySession(
                columns: columns, rows: rows, maxScrollbackBytes: maxScrollbackBytes, theme: theme, appearance: appearance, transcript: transcript)
        else { return nil }
        self.replay = replay
        self.maxScrollbackBytes = maxScrollbackBytes
        self.theme = theme
        self.appearance = appearance
        self.columns = columns
        self.rows = rows
        self.runIdentity = runIdentity
        self.requestedByteCount = requestedByteCount
        self.transcriptStartByteOffset = transcriptStartByteOffset
        self.transcriptEndByteOffset = max(transcriptEndByteOffset, transcriptStartByteOffset)
        self.transcriptFileIdentity = transcriptFileIdentity
    }

    /// Replays transcript bytes produced after this replay's current end. Ghostty keeps the viewport
    /// pinned while output appends below it, so a replay the user has scrolled back into does not move on
    /// screen; the caller therefore needs no repaint for an append. Returns false when the bytes could not
    /// be replayed, which leaves the model unchanged and unusable for further paging.
    @discardableResult public func append(_ bytes: Data, transcriptEndByteOffset: UInt64) -> Bool {
        guard replay.write(bytes) else { return false }
        self.transcriptEndByteOffset = transcriptEndByteOffset
        return true
    }

    /// Scrolls the replay by `deltaRows` and reports what became of them. A gesture that runs into the
    /// replay's oldest row consumes only part of its delta, and the remainder is what the deeper page it
    /// triggers carries forward: a single pan or momentum event that crosses the boundary would otherwise
    /// lose everything past it, since the gesture can settle with no further event to page on.
    public func scroll(deltaRows: Int) -> Scroll {
        let offsetBefore = scrollbar.offset
        let snapshot = replay.scroll(deltaRows: deltaRows)
        return Scroll(snapshot: snapshot, unappliedRows: deltaRows - (scrollbar.offset - offsetBefore))
    }

    public func currentSnapshot() -> GhosttyTerminalSnapshot { replay.currentSnapshot() }

    /// The replay's scrollbar, which every paging decision below is read off.
    ///
    /// The query fails only on an invalid session: the shim rejects a null session or terminal handle, and
    /// libghostty-vt's `ghostty_terminal_get` rejects a null terminal or an unknown data kind. This model
    /// only ever holds a session `TerminalScrollbackReplaySession.init` built successfully (it returns nil
    /// otherwise) and asks for one compile-time constant kind, so neither is reachable here and there is no
    /// live-session failure for the zero substitution to hide. The query itself is amortized O(1) and reads
    /// state the replay already holds, so it cannot fail for a session that merely has nothing in it.
    public var scrollbar: TerminalScrollbackReplayScrollbar { replay.scrollbar() ?? TerminalScrollbackReplayScrollbar(total: 0, offset: 0, rows: 0) }

    /// True when the viewport sits on this replay's oldest row. Combined with `hasDeeperHistory` this is
    /// the paging trigger: the user asked for older content than the fetched bytes hold.
    public var isAtTop: Bool { scrollbar.offset == 0 }

    /// True when the replay's bytes reach back to the transcript's first byte, so there is nothing deeper
    /// to read.
    public var holdsWholeTranscript: Bool { transcriptStartByteOffset == 0 }

    /// True when a deeper read could actually return more history: the replay does not already start at
    /// the transcript's first byte, and the read it was built from did not already ask for the daemon's
    /// whole transcript budget. Both stops are about the request, not the response, because a suffix read
    /// comes back cut at a parser-safe boundary and carrying a preamble, so a client paging off the
    /// returned size would refetch and rebuild the same suffix on every upward gesture forever.
    public var hasDeeperHistory: Bool { !holdsWholeTranscript && requestedByteCount < TerminalScrollbackBudget.defaultMaxBytes }

    /// How far above the newest row the viewport currently sits. A rebuild restores this distance, so the
    /// rows on screen stay put across it.
    public var rowsFromBottom: Int {
        let scrollbar = self.scrollbar
        return max(scrollbar.total - scrollbar.rows - scrollbar.offset, 0)
    }

    /// Puts the viewport `rowsFromBottom` rows above the newest row, for a freshly built replay, which
    /// libghostty-vt starts at the bottom. Returns the resulting snapshot, or nil when the viewport did
    /// not move.
    @discardableResult public func scrollToRowsFromBottom(_ rowsFromBottom: Int) -> GhosttyTerminalSnapshot? {
        let delta = rowsFromBottom - self.rowsFromBottom
        guard delta != 0 else { return nil }
        return scroll(deltaRows: -delta).snapshot
    }
}
