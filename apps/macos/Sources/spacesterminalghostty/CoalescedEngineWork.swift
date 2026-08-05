import Foundation

/// Runs idempotent terminal-engine catch-up work with at most one Swift task in flight, however many
/// times it is requested.
///
/// Ghostty signals the daemon from its IO threads far more often than the work needs to run: every
/// PTY read wakes the app loop and can raise a session-state change, and each of those signals
/// resolves to the same job — drain whatever Ghostty has queued and publish the result. Because the
/// work is a catch-up to current state rather than per-event work, one run after the last signal is
/// equivalent to one run per signal. Spawning a task per signal instead made task allocation a
/// measurable share of IO-thread time under an output flood, and the tasks all serialized onto the
/// same actor anyway.
///
/// The guarantee callers rely on: every request is followed by the work *starting* after that
/// request was recorded, so nothing a request signalled can go unobserved. Requests are never
/// deferred — when no task is in flight, the caller spawns one immediately.
///
/// This carries no data. Bytes are handed to Ghostty synchronously on the reader thread before a
/// request is made, so coalescing cannot reorder or drop output.
final class CoalescedEngineWork: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var taskInFlight = false

    /// Records a request. Returns true when the caller must spawn the task that serves it.
    func requestShouldSpawnTask() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        requested = true
        if taskInFlight { return false }
        taskInFlight = true
        return true
    }

    /// Returns true while a recorded request is still unserved.
    ///
    /// The spawned task MUST loop on this and run the work once per `true`, and must keep looping
    /// until it returns false: a request recorded while the work was running is served by a further
    /// pass rather than dropped, and the false return is what releases the in-flight slot so a later
    /// request can spawn again. A task that exits early strands the slot and silences the signal.
    func claimPendingRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard requested else {
            taskInFlight = false
            return false
        }
        requested = false
        return true
    }
}
