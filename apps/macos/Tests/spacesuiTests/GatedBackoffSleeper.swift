import Foundation

@testable import spacesui

/// Stands in for `CodePaneContentController.reconnectBackoffSleep` so a test decides when each backoff
/// delay elapses. Every requested sleep suspends until the test releases it, which lets a test order an
/// action against a pending retry (or prove a retry did not act) without racing the wall clock.
@MainActor final class GatedBackoffSleeper {
    private(set) var requestedCount = 0
    private var releasedCount = 0
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// The closure to assign to `reconnectBackoffSleep`.
    var sleep: @MainActor (Duration) async -> Void {
        { [self] _ in await suspendUntilReleased() }
    }

    /// Suspends until at least `count` sleeps have been requested in total, released or not.
    func waitForRequestedCount(_ count: Int) async {
        guard requestedCount < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    /// Lets the oldest still-suspended sleep return.
    func releaseNext() {
        precondition(releasedCount < requestedCount, "no pending sleep to release")
        releasedCount += 1
        gates.removeFirst().resume()
    }

    private func suspendUntilReleased() async {
        await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
            gates.append(gate)
            requestedCount += 1
            let ready = requestWaiters.filter { $0.count <= requestedCount }
            requestWaiters.removeAll { $0.count <= requestedCount }
            for waiter in ready { waiter.continuation.resume() }
        }
    }
}
