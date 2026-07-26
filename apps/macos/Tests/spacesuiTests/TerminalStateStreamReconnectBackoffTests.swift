import Foundation
import Testing

@testable import spacesui

/// A pane keeps its state subscription for as long as it is open, so the schedule a failing
/// subscription retries on is what stands between a device that went away and a reconnect storm
/// lasting the whole outage. The delays are injected here, so the curve is asserted without waiting
/// out a single real second.
@Suite @MainActor struct TerminalStateStreamReconnectBackoffTests {
    private func makeBackoff(floor: Duration = .milliseconds(100), cap: Duration = .milliseconds(800)) -> TerminalStateStreamReconnectBackoff {
        let backoff = TerminalStateStreamReconnectBackoff()
        backoff.retryDelay = floor
        backoff.maxRetryDelay = cap
        backoff.retryJitterFraction = { 0 }
        return backoff
    }

    /// The first retry waits the floor — a daemon restart must not be paced like an outage — and each
    /// further failure doubles until the ceiling holds it to a slow probe.
    @Test func consecutiveFailuresDoubleTheDelayUpToTheCeiling() {
        let backoff = makeBackoff()

        let delays = (0..<6).map { _ in backoff.nextDelay() }

        #expect(delays == [.milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800), .milliseconds(800), .milliseconds(800)])
    }

    /// A subscription that opens ends the outage, so the next drop is a fresh incident and waits the
    /// floor again rather than inheriting the schedule the previous run of failures grew.
    @Test func openingASubscriptionResetsTheCurveToItsFloor() {
        let backoff = makeBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        #expect(backoff.nextDelay() == .milliseconds(400))

        backoff.reset()

        #expect(backoff.nextDelay() == .milliseconds(100))
    }

    /// Jitter spreads panes that dropped together — several panes on one device, or every pane on one
    /// network — so they do not redial in lockstep.
    @Test func jitterExtendsTheDelayByItsFraction() {
        let backoff = makeBackoff()
        backoff.retryJitterFraction = { 0.5 }

        #expect(backoff.nextDelay() == .milliseconds(150))
    }
}
