import Foundation

public final class TerminalInputSerialQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingTask: Task<Void, Never>?
    private var pendingTaskID: UInt64?
    private var queuedTasks: [UInt64: Task<Void, Never>] = [:]
    private var nextTaskID: UInt64 = 0
    private var generation: UInt64 = 0

    public init() {}

    public func enqueue(
        priority: TaskPriority? = nil, operation: @escaping @Sendable () async throws -> Void, onError: (@Sendable (Error) -> Void)? = nil
    ) {
        lock.lock()
        let previousTask = pendingTask
        let taskID = nextTaskID
        nextTaskID &+= 1
        let taskGeneration = generation
        let nextTask = Task.detached(priority: priority) { [weak self] in
            defer { self?.completeTask(id: taskID) }
            _ = await previousTask?.result
            guard !Task.isCancelled else { return }
            guard self?.isCurrentGeneration(taskGeneration) == true else { return }
            do {
                try Task.checkCancellation()
                try await operation()
            } catch is CancellationError { return } catch {
                guard self?.isCurrentGeneration(taskGeneration) == true else { return }
                onError?(error)
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
    public func drain() async {
        await currentTail()?.value
    }

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
