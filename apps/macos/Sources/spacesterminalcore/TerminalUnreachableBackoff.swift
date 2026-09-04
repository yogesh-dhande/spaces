import Foundation

/// The automatic-redial backoff ladder for stage 2 ("Device unreachable").
///
/// Once every candidate address has failed to dial, hammering them again a moment later wastes battery
/// and network on a device that just proved it cannot be reached. The ladder spaces automatic redials
/// out (1, 2, 4, 8, 15s, then holding at 15s) so a real outage does not turn into a tight retry loop,
/// while still noticing quickly if the device comes back. Retry is the escape hatch: a user who believes
/// the device is back now can jump straight back to the front of the ladder instead of waiting out
/// whatever rung the automatic redials had reached.
public struct TerminalUnreachableBackoff: Sendable, Equatable {
    /// Delay in seconds before each successive automatic redial while in stage 2. The ladder holds at its
    /// last rung rather than growing without bound, since an unreachable device is either fixed in
    /// seconds or stays unreachable for a long time either way; 15s balances promptness against cost.
    public static let ladderSeconds: [TimeInterval] = [1, 2, 4, 8, 15]

    private var rungIndex = 0

    public init() {}

    /// Returns the delay before the next automatic redial and advances the ladder; stays at the last rung
    /// once reached.
    public mutating func nextDelay() -> TimeInterval {
        let delay = Self.ladderSeconds[rungIndex]
        if rungIndex < Self.ladderSeconds.count - 1 {
            rungIndex += 1
        }
        return delay
    }

    /// Returns the ladder to its first rung, so the next `nextDelay()` is the shortest delay again.
    public mutating func reset() {
        rungIndex = 0
    }
}
