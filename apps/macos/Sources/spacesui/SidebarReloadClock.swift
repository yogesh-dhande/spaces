import Foundation

/// The reload coordinator's only source of time, so that the spacing between reload starts can be driven
/// deterministically. The app runs on the monotonic system clock; a test supplies a clock it advances by
/// hand, which keeps "the scheduled start has not fired yet" a fact about the coordinator instead of a
/// fact about how loaded the machine running the test is.
@MainActor protocol SidebarReloadClock: Sendable {
    var now: ContinuousClock.Instant { get }
    /// Returns once `deadline` is reached, and early when the calling task is cancelled: the caller
    /// rechecks cancellation itself.
    func sleep(until deadline: ContinuousClock.Instant) async
}

struct SidebarReloadSystemClock: SidebarReloadClock {
    private let clock = ContinuousClock()

    var now: ContinuousClock.Instant { clock.now }

    func sleep(until deadline: ContinuousClock.Instant) async { try? await clock.sleep(until: deadline, tolerance: nil) }
}
