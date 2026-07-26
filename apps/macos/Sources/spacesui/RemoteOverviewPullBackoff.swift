import Foundation

/// Per-device pacing for the sidebar's one-shot device-overview pulls.
///
/// Only a pull that returned data stamps the sidebar's freshness window, so a device whose pulls keep
/// failing carries nothing that paces it: every local-event sidebar reload and every reachability
/// watchdog tick would dial it again the moment the previous attempt failed, which against a remote
/// that refuses connections fast is a tight loop of TLS dials. Each failed pull holds the device back
/// for a bounded exponential delay (`RemoteConnectionBackoff`); an overview arriving from that device
/// — or the user asking for it — clears the hold and the count behind it.
///
/// The pull's schedule is deliberately its own rather than the subscription's, even though both
/// target the same device: the two attempts succeed and fail independently — a reachable but
/// wire-incompatible remote answers pulls, which is what paints its compatibility badge, while its
/// subscription keeps failing — so a single shared failure count would either starve the pull behind
/// a backoff its own attempts never earned, or let a pull's success flatten the subscription's
/// backoff into a reconnect storm.
///
/// Nothing here re-drives a pull. The hold only suppresses; the reachability watchdog's tick is what
/// attempts a held-back device again once its hold has elapsed.
@MainActor final class RemoteOverviewPullBackoff {
    /// Devices held back after a failed pull, each with the task that releases the hold when its delay
    /// elapses.
    private var holds: [String: Task<Void, Never>] = [:]
    /// Consecutive failed pulls per device, the exponent behind the hold's delay. Dropped when a pull
    /// returns data or the user asks for the device.
    private var consecutiveFailures: [String: Int] = [:]

    /// Floor of the hold: the delay a device is held back for after its first failed pull. Internal so
    /// behavior tests can shorten it instead of waiting out real seconds.
    var retryDelay: Duration = .seconds(5)
    /// Ceiling of the hold, so a remote that stays down settles into a slow probe instead of being
    /// pulled every few seconds for as long as the app runs. Internal so behavior tests can shorten it.
    var maxRetryDelay: Duration = .seconds(60)
    /// Fraction of the computed delay added on top as jitter. Internal so behavior tests can pin it
    /// instead of depending on a random draw.
    var retryJitterFraction: @MainActor () -> Double = { Double.random(in: 0..<0.25) }

    /// Whether a pull may be started for `deviceID`: false only while it is waiting out the hold its
    /// last failed pull armed.
    func allowsAttempt(deviceID: String) -> Bool { holds[deviceID] == nil }

    /// Holds `deviceID` back from further pulls for its next backoff delay, and returns that delay so
    /// the caller can trace when the device is next pullable.
    @discardableResult func recordFailure(deviceID: String) -> Duration {
        let failures = (consecutiveFailures[deviceID] ?? 0) + 1
        consecutiveFailures[deviceID] = failures
        let delay = RemoteConnectionBackoff.delay(
            consecutiveFailures: failures, floor: retryDelay, cap: maxRetryDelay, jitterFraction: retryJitterFraction())
        // Replacing a hold must cancel the one it replaces, or the outgoing task would release the new
        // hold when its own (shorter) delay elapses.
        holds.removeValue(forKey: deviceID)?.cancel()
        holds[deviceID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.holds[deviceID] = nil
        }
        return delay
    }

    /// Releases `deviceID` and forgets its failures, so the next pull runs immediately and a fresh
    /// failure starts the curve at its floor again. Called when an overview arrives from the device —
    /// pulled or pushed on its subscription, either way the schedule its outage grew no longer
    /// describes it — and when the user asks for this device, which is a stronger signal than that
    /// schedule.
    func clear(deviceID: String) {
        holds.removeValue(forKey: deviceID)?.cancel()
        consecutiveFailures[deviceID] = nil
    }

    /// Awaits every armed hold so a behavior test can assert on pacing deterministically instead of
    /// polling under a wall-clock ceiling. A no-op when no device is held back.
    func drainPendingHoldsForTesting() async { for task in holds.values { await task.value } }
}
