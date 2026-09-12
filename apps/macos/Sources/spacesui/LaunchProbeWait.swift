import Foundation

/// One launch probe's answer, waited on once however many setup steps read it.
///
/// Every probe the launch flow starts gets its own wait. A step that reads one probe must never be
/// decided by another: an agent-hook probe that hangs (it resolves the user's login shell `PATH`, which
/// sources their whole rc chain) cannot be allowed to discard the daemon status the restore step reads,
/// and a daemon that answers neither must not be asked twice.
///
/// The waits of one launch share a deadline, set when the flow begins, so a wedged daemon costs the
/// launch one timeout in total rather than one per step. The probes are blocking Device API calls and
/// cannot be cancelled; the deadline stops *waiting* on one rather than stopping it, and the orphaned
/// request is harmless because it is read-only.
@MainActor final class LaunchProbeWait<Value: Sendable> {
    /// What the first wait settled. A timeout is recorded as deliberately as an answer: a step that
    /// could not tell "timed out" from "not awaited yet" would start the whole wait over on exactly the
    /// launch that already proved the daemon is not answering.
    private enum Resolution {
        case answered(Value?)
        case timedOut
    }

    /// Names the probe in the log line a timeout writes, so a launch whose steps silently never appear
    /// says which probe went unanswered.
    private let description: String
    private let deadline: ContinuousClock.Instant
    private let task: Task<Value?, Never>
    private let answers = AnswerBox<Value>()
    private var resolution: Resolution?

    /// Whether reading this probe costs the user any time, so a step can decide whether to put a spinner
    /// on screen at all.
    var isSettled: Bool { resolution != nil || answers.isFilled }

    init(description: String, deadline: ContinuousClock.Instant, task: Task<Value?, Never>) {
        self.description = description
        self.deadline = deadline
        let answers = self.answers
        // Records the answer as it arrives rather than when a step happens to wait on it. See `AnswerBox`.
        self.task = Task {
            let value = await task.value
            answers.store(value)
            return value
        }
    }

    /// The probe's answer, or nil when it failed or did not answer by the launch's deadline.
    func value() async -> Value? {
        if let resolution { return Self.value(of: resolution) }
        if let answered = answers.answer { return settle(.answered(answered.value)) }
        let deadline = deadline
        let description = description
        let answers = answers
        let settled: Resolution = await withCheckedContinuation { continuation in
            let hasResumed = ResumeOnce()
            Task { [task] in
                let value = await task.value
                if hasResumed.claim() { continuation.resume(returning: .answered(value)) }
            }
            Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard hasResumed.claim() else { return }
                if let answered = answers.answer {
                    continuation.resume(returning: .answered(answered.value))
                    return
                }
                NSLog("Spaces: \(description) skipped, the local daemon did not answer in time")
                continuation.resume(returning: .timedOut)
            }
        }
        return settle(settled)
    }

    private func settle(_ resolution: Resolution) -> Value? {
        self.resolution = resolution
        return Self.value(of: resolution)
    }

    private static func value(of resolution: Resolution) -> Value? {
        switch resolution {
        case .answered(let value): return value
        case .timedOut: return nil
        }
    }
}

/// What a probe answered, distinguishing "answered with nothing" (the read failed) from "no answer yet".
private struct Answer<Value> { let value: Value? }

/// Holds a probe's answer from the moment it arrives, whether or not a step is waiting on it.
///
/// The launch's waits share one deadline, so a step that waits the deadline out leaves every later wait
/// already past it. Without this, such a step would read "timed out" from a probe that answered long
/// before, and the restore step would lose a record the daemon had already handed over. Read before the
/// wait starts and again when the deadline fires, so an answer always beats a passed deadline.
private final class AnswerBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Answer<Value>?

    var answer: Answer<Value>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var isFilled: Bool { answer != nil }

    func store(_ value: Value?) {
        lock.lock()
        defer { lock.unlock() }
        stored = Answer(value: value)
    }
}

/// Guards a `CheckedContinuation` that two racing tasks may reach; only the first claim resumes it.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
