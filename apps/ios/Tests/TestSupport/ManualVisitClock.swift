#if canImport(UIKit)
    import Foundation
    @testable import SpacesMobile

    /// A wall clock and visit scheduler stepped by hand, so the 2 second dwell is exact instead of raced.
    /// Timers only run inside `advance`, which tests call from the main actor.
    final class ManualVisitClock: @unchecked Sendable {
        private(set) var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        private var timers: [Int: (due: Date, action: @MainActor () -> Void)] = [:]
        private var nextID = 0

        var schedule: SpacesMobileTerminalVisitTracker.Schedule {
            { [self] delay, action in
                let id = nextID
                nextID += 1
                timers[id] = (now.addingTimeInterval(delay), action)
                return { [self] in timers[id] = nil }
            }
        }

        /// Moves time forward, firing each timer at the moment it falls due.
        @MainActor func advance(_ seconds: TimeInterval) {
            let target = now.addingTimeInterval(seconds)
            while let next = timers.min(by: { $0.value.due < $1.value.due }), next.value.due <= target {
                timers[next.key] = nil
                now = max(now, next.value.due)
                next.value.action()
            }
            now = target
        }
    }
#endif
