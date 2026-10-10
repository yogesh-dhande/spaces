import Foundation

/// Where one live host frame sits, in the two coordinate systems a client needs to line its transcript
/// replay up with the host: the `output.log` position that reproduces the frame, and the absolute row
/// numbering of the frame's active area.
public struct TerminalLiveFrameStamp: Equatable, Sendable {
    /// `GhosttyRenderFrame.transcriptByteOffset`: replaying the file's bytes `[0, offset)` reproduces the frame.
    public let transcriptByteOffset: UInt64
    public let transcriptFileIdentity: UInt64
    /// `GhosttyTerminalSnapshot.historyEpoch` of the frame.
    public let historyEpoch: UInt64
    /// The host's absolute row of the first row of the active area (the bottom `rows` rows of the screen),
    /// which is the row a replay of the same bytes also has at its own active top. The active area is the
    /// anchor because it is the only part of the screen both terminals are guaranteed to agree on: the
    /// scrollback above it differs by whatever each side pruned.
    public let activeTopRow: Int64
    /// The grid of the uncropped frame. A rows-only resize leaves the host's history epoch alone but moves
    /// the active top, so a replay aligns only with stamps taken at its own grid.
    public let columns: Int
    public let rows: Int

    public init(transcriptByteOffset: UInt64, transcriptFileIdentity: UInt64, historyEpoch: UInt64, activeTopRow: Int64, columns: Int, rows: Int) {
        self.transcriptByteOffset = transcriptByteOffset
        self.transcriptFileIdentity = transcriptFileIdentity
        self.historyEpoch = historyEpoch
        self.activeTopRow = activeTopRow
        self.columns = columns
        self.rows = rows
    }

    /// The stamp of an uncropped host frame: a viewport crop rebases `historyRowBase` and `scrollbarOffset`
    /// together, but not `scrollbarTotal`, so the active top needs the frame as the host exported it.
    /// Nil for a frame that carries no stamp (a client replay frame, whose file identity is zero) or no
    /// scrollbar.
    ///
    /// The active top is `historyRowBase - scrollbarOffset` (absolute row of screen row 0, Ghostty's
    /// pruned-row count) plus `scrollbarTotal - rows` (screen rows above the active area).
    public init?(frame: GhosttyRenderFrame) {
        let snapshot = frame.snapshot
        guard frame.transcriptFileIdentity != 0, snapshot.rows > 0, Int(snapshot.scrollbarTotal) >= snapshot.rows else { return nil }
        let screenTop = Int64(clamping: snapshot.historyRowBase) - Int64(snapshot.scrollbarOffset)
        self.init(
            transcriptByteOffset: frame.transcriptByteOffset, transcriptFileIdentity: frame.transcriptFileIdentity,
            historyEpoch: snapshot.historyEpoch, activeTopRow: screenTop + Int64(snapshot.scrollbarTotal) - Int64(snapshot.rows),
            columns: snapshot.columns, rows: snapshot.rows)
    }
}

/// The most recent live frame stamps, oldest first, for a client to hand the scrollback model whenever it
/// builds or extends a replay.
///
/// A replay can only be aligned at a stamp whose offset falls inside the bytes being written, that is,
/// after the replay's previous end. Under streaming output those are the most recent frames, and 128 of
/// them is a little over two seconds at the 60 Hz a pane redraws at, longer than a transcript read takes
/// on a slow remote link. An idle session's newest stamps stay in the ring however old they are, because
/// the ring holds the last 128 distinct stamps rather than a time window. A stamp costs under 64 bytes.
public struct TerminalLiveFrameStampRing: Equatable, Sendable {
    public static let capacity = 128

    public private(set) var stamps: [TerminalLiveFrameStamp] = []

    public init() {}

    /// The stamps a read that started with `stampsAtReadStart` should be installed with: those and the
    /// ring now, deduplicated, in offset order. A read held in flight while more than `capacity` frames
    /// arrive has lost the stamps inside the bytes it served from the ring, but still holds them here.
    public func stamps(including stampsAtReadStart: [TerminalLiveFrameStamp]) -> [TerminalLiveFrameStamp] {
        var union = stampsAtReadStart
        for stamp in stamps where !union.contains(stamp) { union.append(stamp) }
        return union.enumerated().sorted { lhs, rhs in
            lhs.element.transcriptByteOffset != rhs.element.transcriptByteOffset
                ? lhs.element.transcriptByteOffset < rhs.element.transcriptByteOffset : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Records the stamp of a live frame. A frame that repeats the newest stamp (output that changed no
    /// cell and moved nothing) adds nothing.
    public mutating func record(_ stamp: TerminalLiveFrameStamp) {
        guard stamps.last != stamp else { return }
        stamps.append(stamp)
        if stamps.count > Self.capacity { stamps.removeFirst(stamps.count - Self.capacity) }
    }
}
