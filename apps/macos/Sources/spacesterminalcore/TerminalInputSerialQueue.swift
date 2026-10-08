import Foundation

public final class TerminalInputSerialQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingTask: Task<Void, Never>?
    private var pendingTaskID: UInt64?
    private var queuedTasks: [UInt64: Task<Void, Never>] = [:]
    private var nextTaskID: UInt64 = 0
    private var generation: UInt64 = 0
    /// The newest `supersedable` task that has not started its operation yet, and the earlier ones a
    /// newer one replaced while they still waited.
    private var supersedableTaskID: UInt64?
    private var supersededTaskIDs: Set<UInt64> = []

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
    ///
    /// A `supersedable` operation is replaced by the very next operation if that one is also
    /// `supersedable` and the older has not started: the older one is discarded (`onDiscarded`). Any
    /// operation that is not `supersedable` (a key, press or release) in between ends the run, so a
    /// motion queued before it still runs before it and a later motion never discards it. This is for a
    /// stream where only the latest value of consecutive entries matters, such as pointer motion under a
    /// program that tracks the mouse; non-supersedable operations are never dropped or reordered.
    public func enqueue(
        priority: TaskPriority? = nil, supersedable: Bool = false, operation: @escaping @Sendable () async throws -> Void,
        onError: (@Sendable (Error) async -> Void)? = nil, onDiscarded: (@Sendable () async -> Void)? = nil
    ) {
        lock.lock()
        let previousTask = pendingTask
        let taskID = nextTaskID
        nextTaskID &+= 1
        let taskGeneration = generation
        if supersedable {
            if let replaced = supersedableTaskID { supersededTaskIDs.insert(replaced) }
            supersedableTaskID = taskID
        } else {
            // Other input between two motions fences them: the earlier motion belongs before it.
            supersedableTaskID = nil
        }
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
            guard self?.claimTurn(taskID: taskID) == true else {
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
    /// this call began are not awaited.
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

    /// Whether the task may run its operation now. A superseded task may not; a `supersedable` task that
    /// starts can no longer be replaced.
    private func claimTurn(taskID: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if supersededTaskIDs.remove(taskID) != nil { return false }
        if supersedableTaskID == taskID { supersedableTaskID = nil }
        return true
    }

    private func completeTask(id taskID: UInt64) {
        lock.lock()
        queuedTasks.removeValue(forKey: taskID)
        supersededTaskIDs.remove(taskID)
        if supersedableTaskID == taskID { supersedableTaskID = nil }
        if pendingTaskID == taskID {
            pendingTask = nil
            pendingTaskID = nil
        }
        lock.unlock()
    }
}
