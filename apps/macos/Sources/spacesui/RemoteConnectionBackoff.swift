import Foundation

/// The bounded exponential delay a failing connection to one device is paced with: doubles from
/// `floor`, clamps at `cap`, then spreads by `jitterFraction` so devices that failed together (one
/// network outage) don't attempt in lockstep.
///
/// Shared by the two per-device schedules the sidebar keeps — the overview subscription's reconnect
/// and the overview pull's re-attempt — so a remote that is down is paced the same way whichever
/// attempt discovered it. Pure, so the growth curve is directly testable.
enum RemoteConnectionBackoff {
    static func delay(consecutiveFailures: Int, floor: Duration, cap: Duration, jitterFraction: Double) -> Duration {
        // Clamped before the exponentiation so a device that has been down for hours cannot overflow
        // the doubling into a nonsensical duration on its way to the cap.
        let doublings = min(max(consecutiveFailures - 1, 0), 16)
        return min(floor * pow(2, Double(doublings)), cap) * (1 + jitterFraction)
    }
}
