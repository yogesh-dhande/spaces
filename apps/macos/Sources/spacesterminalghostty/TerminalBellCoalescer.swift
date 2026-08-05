import Foundation

/// Collapses a session's terminal bells into the single timestamp its clients raise an alert from.
///
/// A bell is a notification, not a log. A build that rings five times as it fails is one thing the user
/// needs to know about, and because the timestamp IS the alert's dismissal identity, every distinct
/// value would mint a new alert and re-raise one the user just dismissed. So the recorded timestamp
/// advances at most once per quiet window and every bell inside that window is absorbed into it; once
/// the window has passed, a genuinely new bell mints a new identity and the alert returns.
///
/// Ghostty's terminal layer already debounces bells at 100 ms; this is the product-level window on top
/// of that, and it is the daemon's rule rather than a client's so every client sees the same alert.
struct TerminalBellCoalescer {
    /// A bell arriving within this long of the last recorded one changes nothing.
    static let defaultQuietWindow: TimeInterval = 30

    /// Shortened by tests so the window reopening can be exercised without sleeping through a real
    /// one. Product code always leaves it at the default.
    var quietWindow: TimeInterval = TerminalBellCoalescer.defaultQuietWindow

    private var lastAdvancedAt: Date?

    /// Restores the window from the timestamp a previous process image published. A daemon handoff
    /// rebuilds the session around a fresh coalescer, and the clients still hold the alert the old image
    /// raised; without this, the first bell after the handoff would advance the timestamp and mint a
    /// second alert for a bell the user has already been told about. `nil` — no bell recorded, or a
    /// persisted timestamp that does not parse — leaves the window open.
    mutating func seedLastAdvanced(at date: Date?) { lastAdvancedAt = date }

    /// Records a bell and returns the timestamp the session should publish, or nil when the bell falls
    /// inside the quiet window and the published timestamp must stay where it is.
    mutating func ring(at now: Date = Date()) -> Date? {
        if let lastAdvancedAt, now.timeIntervalSince(lastAdvancedAt) < quietWindow { return nil }
        lastAdvancedAt = now
        return now
    }
}
