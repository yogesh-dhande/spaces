import Foundation

/// The rowid of a turn in `turn_text` and `turns`, which encodes the time of the turn's newest message.
///
/// `AgentSessionIndex.search` scans in descending rowid order and stops once a page is full, so rowid
/// order has to be message-time order. Insertion order is not: the first build writes session by session,
/// and a session re-read whole is written again, so a session whose match is old but whose other turns
/// are recent would outrank a session with a newer match. A rowid is therefore the turn's time in
/// milliseconds times `slotsPerMillisecond`, plus the first free slot after that.
///
/// A turn with no timestamped message (some agents record none) takes its source file's modification
/// time, the only time information those agents give.
enum TurnRowID {
    static let slotsPerMillisecond: Int64 = 4096
    /// Keeps `time * slotsPerMillisecond` far inside Int64 whatever a transcript claims.
    private static let maximumMilliseconds: Int64 = 1 << 42

    /// The first rowid to try for a turn last active at `date`. The writer takes the next free one when
    /// other turns share the millisecond, so the outcome depends only on what is already indexed.
    static func firstCandidate(for date: Date) -> Int64 {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded(.down)
        let clamped = min(max(milliseconds.isFinite ? Int64(milliseconds) : 0, 0), maximumMilliseconds)
        return clamped * slotsPerMillisecond
    }

    static func date(of rowID: Int64) -> Date { Date(timeIntervalSince1970: Double(rowID / slotsPerMillisecond) / 1000) }
}
