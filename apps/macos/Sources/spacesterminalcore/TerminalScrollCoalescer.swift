import Foundation

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

    private let frameInterval: Duration
    private let enqueue: EnqueueHandler
    private var pending: Pending?
    private var flushTask: Task<Void, Never>?
    private var queuedBatchCount = 0

    public init(frameInterval: Duration = .milliseconds(16), enqueue: @escaping EnqueueHandler) {
        self.frameInterval = frameInterval
        self.enqueue = enqueue
    }

    public func append(horizontal: Double, vertical: Double, scrollMods: Int32 = 0, pointerPosition: TerminalScrollPointerPosition? = nil) {
        guard horizontal != 0 || vertical != 0 || scrollMods != 0 || pending != nil else { return }
        if pending == nil { pending = Pending(horizontal: 0, vertical: 0, scrollMods: 0, pointerPosition: nil) }
        pending?.append(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition)
        scheduleFlushIfPossible(after: frameInterval)
    }

    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        enqueuePendingIfNeeded(force: true)
    }

    public func cancel() {
        flushTask?.cancel()
        flushTask = nil
        pending = nil
    }

    private func scheduleFlushIfPossible(after delay: Duration) {
        guard queuedBatchCount == 0, pending != nil, flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) } else { await Task.yield() }
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.enqueuePendingIfNeeded(force: false)
        }
    }

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
        guard queuedBatchCount == 0, pending != nil else { return }
        scheduleFlushIfPossible(after: .zero)
    }
}
