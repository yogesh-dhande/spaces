import Foundation

/// Rate-limits terminal scroll deltas to one request in flight at a time. The first delta of a gesture
/// is sent the moment it arrives; every delta that arrives while that request is outstanding merges
/// into one batch, which is sent as soon as the request completes. Nothing is ever delayed by a timer:
/// on the paths that still send wheel deltas to the daemon (a mouse-tracking application, and the Mac
/// pane attached to a remote daemon) the first event of a gesture is the one the user is waiting on.
@MainActor public final class TerminalScrollCoalescer {
    public struct Batch: Equatable, Sendable {
        public let horizontal: Double
        public let vertical: Double
        public let scrollMods: Int32
        public let pointerPosition: TerminalScrollPointerPosition?

        public init(horizontal: Double, vertical: Double, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition? = nil) {
            self.horizontal = horizontal
            self.vertical = vertical
            self.scrollMods = scrollMods
            self.pointerPosition = pointerPosition
        }

        public var hasPayload: Bool { horizontal != 0 || vertical != 0 || scrollMods != 0 }
    }

    public typealias FinishHandler = @MainActor @Sendable () -> Void
    public typealias EnqueueHandler = @MainActor (Batch, @escaping FinishHandler) -> Void

    private struct Pending {
        var horizontal: Double
        var vertical: Double
        var scrollMods: Int32
        var pointerPosition: TerminalScrollPointerPosition?

        mutating func append(horizontal: Double, vertical: Double, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?) {
            self.horizontal += horizontal
            self.vertical += vertical
            if scrollMods != 0 { self.scrollMods = scrollMods }
            if let pointerPosition { self.pointerPosition = pointerPosition }
        }

        var batch: Batch { Batch(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition) }
    }

    private let enqueue: EnqueueHandler
    private var pending: Pending?
    private var queuedBatchCount = 0

    public init(enqueue: @escaping EnqueueHandler) { self.enqueue = enqueue }

    public func append(horizontal: Double, vertical: Double, scrollMods: Int32 = 0, pointerPosition: TerminalScrollPointerPosition? = nil) {
        guard horizontal != 0 || vertical != 0 || scrollMods != 0 || pending != nil else { return }
        if pending == nil { pending = Pending(horizontal: 0, vertical: 0, scrollMods: 0, pointerPosition: nil) }
        pending?.append(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition)
        enqueuePendingIfNeeded(force: false)
    }

    /// Sends whatever is pending right now, even with a batch already in flight. Callers use this to
    /// order a scroll ahead of an input send that must land after it.
    public func flush() { enqueuePendingIfNeeded(force: true) }

    public func cancel() { pending = nil }

    private func enqueuePendingIfNeeded(force: Bool) {
        guard force || queuedBatchCount == 0 else { return }
        guard let batch = pending?.batch, batch.hasPayload else {
            pending = nil
            return
        }
        pending = nil
        queuedBatchCount += 1
        enqueue(batch) { [weak self] in self?.finishBatch() }
    }

    private func finishBatch() {
        queuedBatchCount = max(queuedBatchCount - 1, 0)
        guard queuedBatchCount == 0 else { return }
        enqueuePendingIfNeeded(force: false)
    }
}
