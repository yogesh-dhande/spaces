import Foundation
import ghosttyvtshim

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
/// Rows are numbered in the host's absolute rows once the replay is aligned with it. The replay's own
/// vt session numbers rows from whatever its bytes began with, so the model fixes the difference (a
/// constant shift) at a live frame stamp: a point in `output.log` where the host's absolute row of its
/// active area's top is known (`TerminalLiveFrameStamp`). While aligned, every snapshot the model returns
/// carries the host's row base and epoch, so a selection a client holds in absolute rows projects onto
/// live frames and replay frames alike, and the text of a selection that reaches into the replay's
/// scrollback is read from the replay. Before alignment, and after anything that renumbers the replay's
/// rows (a clear or a screen switch in appended bytes), the model reports its own numbering under an epoch
/// no host frame can have, so a selection made on the replay stays consistent within it and is dropped by
/// any frame from another coordinate system.
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

    /// How the replay's rows relate to the host's absolute rows, recorded where a live frame stamp
    /// aligned them. Valid only while the replay's own history epoch is still `replayEpoch`: a clear or
    /// screen switch in later bytes renumbers the replay's rows, and the shift no longer applies.
    private struct Alignment {
        /// Host absolute row minus replay absolute row (rows pruned plus screen row), constant while
        /// both terminals scroll in lockstep.
        let shift: Int64
        let replayEpoch: UInt64
        let hostEpoch: UInt64
    }
    private var alignment: Alignment?
    /// Makes the epoch of an unaligned replay differ from every host epoch and from every other model's.
    private let unalignedEpochSeed = UInt64.random(in: .min ... .max)

    /// Builds the replay from the bytes a `terminalTranscript` read returned. `transcript` is what the
    /// daemon served, which for a suffix read is a state preamble followed by the file's bytes from
    /// `transcriptStartByteOffset`; `requestedByteCount` is what that read asked for. `stamps` are the live
    /// frame stamps known now; the latest one that names this file at an offset inside the served bytes
    /// (`transcriptStartByteOffset` through `transcriptEndByteOffset`) aligns the replay with the host.
    public init?(
        columns: Int, rows: Int, maxScrollbackBytes: Int = TerminalScrollbackBudget.defaultMaxBytes, theme: GhosttyThemeExport,
        appearance: ThemeAppearance, transcript: Data, transcriptStartByteOffset: UInt64, transcriptEndByteOffset: UInt64, requestedByteCount: Int,
        transcriptFileIdentity: UInt64?, runIdentity: String?, stamps: [TerminalLiveFrameStamp] = []
    ) {
        guard
            let replay = TerminalScrollbackReplaySession(
                columns: columns, rows: rows, maxScrollbackBytes: maxScrollbackBytes, theme: theme, appearance: appearance)
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

        // A suffix read's data is a synthesized state preamble followed by the file's bytes from
        // `transcriptStartByteOffset` up to the end offset, so the file bytes are the last
        // `end - start` bytes of the data (a whole-file read has no preamble, so they are all of it).
        // A read whose data is shorter than its offsets claim cannot be mapped, so it is not aligned.
        let fileByteCount = self.transcriptEndByteOffset - transcriptStartByteOffset
        let mappable = fileByteCount <= UInt64(transcript.count)
        guard
            write(
                transcript, fileBytesStart: mappable ? transcript.count - Int(fileByteCount) : 0, fileOffsetAtStart: transcriptStartByteOffset,
                stampOffsets: mappable ? transcriptStartByteOffset...self.transcriptEndByteOffset : nil, stamps: stamps)
        else { return nil }
    }

    /// Replays transcript bytes produced after this replay's current end. Ghostty keeps the viewport
    /// pinned while output appends below it, so a replay the user has scrolled back into does not move on
    /// screen; the caller therefore needs no repaint for an append. `stamps` are the live frame stamps
    /// known now; the latest one that names this file at an offset inside the appended bytes (after the
    /// current end, through the new end) aligns the replay with the host there. Returns false when the
    /// bytes could not be replayed, which leaves the model unchanged and unusable for further paging.
    @discardableResult public func append(_ bytes: Data, transcriptEndByteOffset: UInt64, stamps: [TerminalLiveFrameStamp] = []) -> Bool {
        let currentEnd = self.transcriptEndByteOffset
        let appendedOffsets = transcriptEndByteOffset > currentEnd ? currentEnd + 1...transcriptEndByteOffset : nil
        guard write(bytes, fileBytesStart: 0, fileOffsetAtStart: currentEnd, stampOffsets: appendedOffsets, stamps: stamps) else { return false }
        self.transcriptEndByteOffset = transcriptEndByteOffset
        return true
    }

    /// Writes `bytes` into the replay, splitting the write at the latest stamp that names this model's
    /// file at an offset in `stampOffsets`, so the replay's history position can be read exactly where the
    /// host's state is known. `fileBytesStart` is the index in `bytes` of the file byte at
    /// `fileOffsetAtStart`; anything before it is a state preamble.
    private func write(
        _ bytes: Data, fileBytesStart: Int, fileOffsetAtStart: UInt64, stampOffsets: ClosedRange<UInt64>?, stamps: [TerminalLiveFrameStamp]
    ) -> Bool {
        guard let stampOffsets, let stamp = latestStamp(in: stampOffsets, of: stamps) else { return replay.write(bytes) }

        let splitIndex = fileBytesStart + Int(stamp.transcriptByteOffset - fileOffsetAtStart)
        guard splitIndex <= bytes.count else { return replay.write(bytes) }
        let splitPoint = bytes.index(bytes.startIndex, offsetBy: splitIndex)
        guard replay.write(bytes[..<splitPoint]) else { return false }
        recordAlignment(at: stamp)
        return replay.write(bytes[splitPoint...])
    }

    /// Aligns the replay with the host at a stamp that names this file at exactly the current end of the
    /// replay's bytes, writing nothing. A replay already caught up to the end of the file can only be
    /// aligned by a frame whose stamp arrives after its last write, and with nothing left to append no
    /// write would ever see that stamp. A stamp for another grid or another offset is ignored.
    public func align(with stamps: [TerminalLiveFrameStamp]) {
        guard let stamp = latestStamp(in: transcriptEndByteOffset...transcriptEndByteOffset, of: stamps) else { return }
        recordAlignment(at: stamp)
    }

    /// The stamp with the largest offset (the later arrival on a tie) that names this model's file and
    /// grid at an offset in `offsets`. A stamp from another grid is for a different row count, so its
    /// active top says nothing about this replay's rows.
    private func latestStamp(in offsets: ClosedRange<UInt64>, of stamps: [TerminalLiveFrameStamp]) -> TerminalLiveFrameStamp? {
        guard let identity = transcriptFileIdentity else { return nil }
        var latest: TerminalLiveFrameStamp?
        for stamp in stamps
        where stamp.transcriptFileIdentity == identity && stamp.columns == columns && stamp.rows == rows
            && offsets.contains(stamp.transcriptByteOffset)
        {
            if let current = latest, stamp.transcriptByteOffset < current.transcriptByteOffset { continue }
            latest = stamp
        }
        return latest
    }

    /// Records the shift between the host's rows and the replay's, read from the replay as it stands,
    /// which must be exactly the state the stamp describes.
    private func recordAlignment(at stamp: TerminalLiveFrameStamp) {
        guard let position = replay.historyPosition() else { return }
        let replayActiveTop = Int64(clamping: position.rows_pruned) + Int64(clamping: position.total) - Int64(rows)
        alignment = Alignment(shift: stamp.activeTopRow - replayActiveTop, replayEpoch: position.history_epoch, hostEpoch: stamp.historyEpoch)
    }

    /// Scrolls the replay by `deltaRows` and reports what became of them. A gesture that runs into the
    /// replay's oldest row consumes only part of its delta, and the remainder is what the deeper page it
    /// triggers carries forward: a single pan or momentum event that crosses the boundary would otherwise
    /// lose everything past it, since the gesture can settle with no further event to page on.
    public func scroll(deltaRows: Int) -> Scroll {
        let offsetBefore = scrollbar.offset
        let moved = replay.scroll(deltaRows: deltaRows)
        return Scroll(snapshot: moved ? currentSnapshot() : nil, unappliedRows: deltaRows - (scrollbar.offset - offsetBefore))
    }

    public func currentSnapshot() -> GhosttyTerminalSnapshot {
        let coordinates = coordinates
        let rowBase = Int64(clamping: coordinates.position.rows_pruned) + Int64(clamping: coordinates.position.offset) + coordinates.shift
        return replay.currentSnapshot(historyRowBase: UInt64(clamping: rowBase), historyEpoch: coordinates.epoch)
    }

    /// The row numbering the replay's snapshots are in right now: the host's while aligned, the replay's
    /// own otherwise.
    private var coordinates: (shift: Int64, epoch: UInt64, position: SpacesGhosttyVtHistoryPosition) {
        // The query fails only for an invalid session, which cannot be reached here for the same reason as
        // `scrollbar` below; the zero position then names an empty replay.
        let position = replay.historyPosition() ?? SpacesGhosttyVtHistoryPosition()
        if let alignment, alignment.replayEpoch == position.history_epoch { return (alignment.shift, alignment.hostEpoch, position) }
        return (0, unalignedEpochSeed &+ position.history_epoch, position)
    }

    /// The epoch of the row numbering the replay's snapshots carry now. A selection applies to the replay
    /// only while its epoch equals this.
    public var historyEpoch: UInt64 { coordinates.epoch }

    /// The absolute row, in the replay's current numbering, of the oldest row the replay holds. A copy
    /// whose selection starts above it needs a deeper page first.
    public var oldestAbsoluteRow: Int64 {
        let coordinates = coordinates
        return coordinates.shift + Int64(clamping: coordinates.position.rows_pruned)
    }

    /// The text of `selection` as the replay holds it, in the format Ghostty copies (soft wraps unwrapped,
    /// trailing blanks trimmed). Nil when the selection is in another epoch than the replay's current
    /// numbering, or lies wholly outside the rows the replay holds. Rows older than the replay holds are
    /// clipped off the start, which is why a caller pages deeper first when `oldestAbsoluteRow` is above the
    /// selection's start.
    public func text(for selection: TerminalAbsoluteSelection) -> String? {
        let coordinates = coordinates
        guard selection.historyEpoch == coordinates.epoch else { return nil }
        let top = coordinates.shift + Int64(clamping: coordinates.position.rows_pruned)
        let lastRow = Int64(clamping: coordinates.position.total) - 1
        var startRow = selection.start.row - top
        var endRow = selection.end.row - top
        guard endRow >= 0, startRow <= lastRow else { return nil }
        var startColumn = selection.start.column
        var endColumn = selection.end.column
        if startRow < 0 {
            startRow = 0
            if !selection.isRectangle { startColumn = 0 }
        }
        if endRow > lastRow {
            endRow = lastRow
            if !selection.isRectangle { endColumn = columns - 1 }
        }
        return replay.text(
            startColumn: startColumn, startRow: Int(startRow), endColumn: endColumn, endRow: Int(endRow), isRectangle: selection.isRectangle)
    }

    /// Select-all in the replay's current numbering: Ghostty's span from the first to the last
    /// non-whitespace cell of the whole screen, scrollback included. Nil when the replay holds no text.
    public func selectAllSelection() -> TerminalAbsoluteSelection? {
        guard let span = replay.selectAllSpan() else { return nil }
        let coordinates = coordinates
        let top = coordinates.shift + Int64(clamping: coordinates.position.rows_pruned)
        return TerminalAbsoluteSelection(
            from: TerminalAbsoluteCell(column: span.startColumn, row: top + Int64(span.startRow)),
            to: TerminalAbsoluteCell(column: span.endColumn, row: top + Int64(span.endRow)), isRectangle: false, historyEpoch: coordinates.epoch)
    }

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
