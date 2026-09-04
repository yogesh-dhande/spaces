import Foundation

public final class TerminalInputSerialQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingTask: Task<Void, Never>?
    private var pendingTaskID: UInt64?
    private var queuedTasks: [UInt64: Task<Void, Never>] = [:]
    private var nextTaskID: UInt64 = 0
    private var generation: UInt64 = 0

    public init() {}

    /// `onError` is `async` (not just `Sendable`) so a caller whose failure classification lives behind
    /// an actor — e.g. the render host's link-state model — can `await` straight into it instead of
    /// firing a detached, unobservable hop. This queue's own detached task is already in an `async`
    /// context, so awaiting the callback costs nothing extra here.
    ///
    /// `onDiscarded` is invoked exactly once when the queued task returns without ever running
    /// `operation`: cancelled before its turn came up, or superseded by a `cancelAll()` generation bump
    /// while it was still waiting behind an earlier task. It never fires once `operation` has run,
    /// whether that run succeeded, threw, or threw `CancellationError`. An operation that never runs
    /// cannot run its own completion bookkeeping, so a caller holding a slot open until the operation
    /// finishes (e.g. `TerminalScrollCoalescer`'s one-batch-in-flight gate, released from inside the
    /// queued operation's own `onFinished`) needs a way to release that slot even on the discard path,
    /// or a batch dropped alongside a failed send behind it wedges the coalescer forever.
    public func enqueue(
        priority: TaskPriority? = nil, operation: @escaping @Sendable () async throws -> Void,
        onError: (@Sendable (Error) async -> Void)? = nil, onDiscarded: (@Sendable () async -> Void)? = nil
    ) {
        lock.lock()
        let previousTask = pendingTask
        let taskID = nextTaskID
        nextTaskID &+= 1
        let taskGeneration = generation
        let nextTask = Task.detached(priority: priority) { [weak self] in
            defer { self?.completeTask(id: taskID) }
            _ = await previousTask?.result
            guard !Task.isCancelled else {
                await onDiscarded?()
                return
            }
            guard self?.isCurrentGeneration(taskGeneration) == true else {
                await onDiscarded?()
                return
            }
            do {
                try Task.checkCancellation()
                try await operation()
            } catch is CancellationError { return } catch {
                guard self?.isCurrentGeneration(taskGeneration) == true else { return }
                await onError?(error)
            }
        }
        pendingTask = nextTask
        pendingTaskID = taskID
        queuedTasks[taskID] = nextTask
        lock.unlock()
    }

    public func cancelAll() {
        lock.lock()
        generation &+= 1
        let tasks = Array(queuedTasks.values)
        lock.unlock()
        for task in tasks { task.cancel() }
    }

    /// Suspends until the task chain enqueued so far has finished. Because each task awaits its
    /// predecessor, awaiting the current tail awaits the whole outstanding chain. Tasks enqueued after
    /// this call began are not awaited. Used by handoff quiesce to flush pending input before `execv`.
    public func drain() async { await currentTail()?.value }

    private func currentTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return pendingTask
    }

    private func isCurrentGeneration(_ taskGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == taskGeneration
    }

    private func completeTask(id taskID: UInt64) {
        lock.lock()
        queuedTasks.removeValue(forKey: taskID)
        if pendingTaskID == taskID {
            pendingTask = nil
            pendingTaskID = nil
        }
        lock.unlock()
    }
}
