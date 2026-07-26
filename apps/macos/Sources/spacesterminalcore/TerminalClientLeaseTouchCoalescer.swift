import Foundation

/// Rate-limits the DURABLE half of a client's attachment-lease touch.
///
/// Every control request an attached client sends — a keystroke, a paste, a resize, a heartbeat — refreshes
/// that client's lease so the daemon can tell a live client from one that vanished without detaching. The
/// in-memory half of that bookkeeping is cheap and stays exact. The durable half is a `BEGIN IMMEDIATE`
/// transaction against the profile database, so at one write per keystroke it contends with every other
/// writer on that database for no added information: a lease only has to prove the client was seen within
/// `TerminalSessionPersistence.remoteClientLeaseInterval`, and a second touch inside the same window says
/// exactly what the first one already said.
///
/// A core asks this type whether a client's lease touch is due; touches inside the window are dropped before
/// they ever reach SQLite. The cost is timing, not correctness: a client that dies is noticed up to one
/// coalescing interval later than its last touch would suggest, which the lease's own multi-second scale
/// already tolerates.
public struct TerminalClientLeaseTouchCoalescer {
    /// One quarter of the lease. Expressed against the lease rather than as a standalone constant so the two
    /// cannot drift apart if the lease is retuned: a coalesced lease is by construction never more than a
    /// quarter of its own lifetime behind the last touch, leaving three quarters of the lease as headroom
    /// for the touch cadence itself.
    public static let coalescingInterval: TimeInterval = TerminalSessionPersistence.remoteClientLeaseInterval / 4

    /// When each client's durable lease write was last PERFORMED — never when a touch was merely offered.
    /// Skipped touches leave this untouched, so the next eligible write stays one interval after the last
    /// real write and a stream of skipped touches cannot push it further out.
    private var lastDurableWriteAtByClientID: [String: Date] = [:]

    public init() {}

    /// Whether `clientID`'s durable lease write is due, recording `now` as its write instant when it is.
    ///
    /// A wall-clock step backwards leaves a future write instant on record; treating that as "not due" would
    /// suppress durable touches for the length of the jump and could let a live client's lease lapse, so a
    /// recorded instant in the future makes the touch due again.
    public mutating func isDurableTouchDue(clientID: String, now: Date) -> Bool {
        if let lastWriteAt = lastDurableWriteAtByClientID[clientID] {
            let elapsed = now.timeIntervalSince(lastWriteAt)
            if elapsed >= 0, elapsed < Self.coalescingInterval { return false }
        }
        lastDurableWriteAtByClientID[clientID] = now
        return true
    }

    /// Drops `clientID`'s record so its next touch writes. Called wherever the client's durable row changes
    /// out from under the record — attach, detach, expiry — so a fresh attachment never inherits the previous
    /// one's "already written recently" verdict.
    public mutating func forget(clientID: String) { lastDurableWriteAtByClientID[clientID] = nil }

    /// Drops every record, for the whole-session transitions that detach all clients at once (termination,
    /// and the relaunch that follows it).
    public mutating func forgetAll() { lastDurableWriteAtByClientID.removeAll() }
}
