import Foundation

/// Pacing for one terminal session's state-subscription reconnects.
///
/// A pane holds its subscription for as long as it is open, and an open pane survives its device
/// going away — so a flat retry cadence means one pinned-TLS dial per pane every half second for the
/// entire outage, against a device that is not answering. Each consecutive failure earns the next
/// attempt a longer wait on the same bounded exponential curve the sidebar paces a failing device
/// with (`RemoteConnectionBackoff`), and a subscription that opens clears the run so the next drop
/// starts at the floor again.
///
/// Per session rather than per device: a session's stream can be refused on its own terms (an ended
/// session is not streamable) while the device answers everything else, so a shared count would pace
/// healthy sessions behind failures they never had.
@MainActor final class TerminalStateStreamReconnectBackoff {
    /// Consecutive failed attempts, the exponent behind the delay. Cleared when a subscription opens.
    private var consecutiveFailures = 0

    /// Floor of the backoff: the delay before the first retry after a subscription drops. Short
    /// enough that the common case — a daemon restart, a brief network blip — reconnects before the
    /// user finishes reading the banner. Internal so behavior tests can shorten it instead of waiting
    /// out real seconds.
    var retryDelay: Duration = .milliseconds(500)
    /// Ceiling of the backoff, so a device that stays down settles into a slow probe instead of being
    /// dialed twice a second for as long as the pane is open. Internal so behavior tests can shorten
    /// it.
    var maxRetryDelay: Duration = .seconds(10)
    /// Fraction of the computed delay added on top as jitter, so panes that dropped together (one
    /// network outage, or one device with several open panes) don't retry in lockstep. Internal so
    /// behavior tests can pin it instead of depending on a random draw.
    var retryJitterFraction: @MainActor () -> Double = { Double.random(in: 0..<0.25) }

    /// Records a failed attempt and returns how long the next one waits.
    func nextDelay() -> Duration {
        consecutiveFailures += 1
        return RemoteConnectionBackoff.delay(
            consecutiveFailures: consecutiveFailures, floor: retryDelay, cap: maxRetryDelay, jitterFraction: retryJitterFraction())
    }

    /// Forgets the run of failures, so the next drop waits the floor again.
    func reset() { consecutiveFailures = 0 }
}
