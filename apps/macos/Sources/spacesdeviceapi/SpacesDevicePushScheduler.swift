import Foundation

/// A cancellable delayed call.
protocol SpacesDevicePushScheduledWork: Sendable { func cancel() }

/// The clock and timers the push notifier runs on. Injected so tests advance the 10-second recheck, the
/// 1-second debounce, and the retry backoff without waiting.
protocol SpacesDevicePushScheduler: Sendable {
    var now: Date { get }
    /// Runs `work` once, no sooner than `seconds` from now, on any queue.
    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> any SpacesDevicePushScheduledWork
}

struct SpacesDevicePushDispatchScheduler: SpacesDevicePushScheduler {
    private final class Work: SpacesDevicePushScheduledWork, @unchecked Sendable {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    private static let queue = DispatchQueue(label: "spaces.device.push.timers", qos: .utility)

    var now: Date { Date() }

    func schedule(after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> any SpacesDevicePushScheduledWork {
        let item = DispatchWorkItem(block: work)
        Self.queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return Work(item)
    }
}
