import Foundation

/// Process-wide index of sessions whose launch-configuration durable write is still queued behind the
/// per-core persistence queue (write-behind, see `TerminalCorePersistenceQueue`). The in-memory core is
/// the authority and the `terminal_sessions` row is only its mirror, so just after a create there is a
/// window, stretched by database write contention, where a live session has no durable row at all.
/// Durable-row readers that classify sessions (the orchestrator's launch-pending probe, which automation
/// polling and tracked-window liveness ride on) consult this registry first so a live, just-created
/// session is never misread as vanished and torn down while its first write waits out contention.
///
/// An entry is recorded before its write is enqueued and removed only after the row commits (or after the
/// write's final failure, which terminates the core), so readers must check the registry BEFORE the
/// durable row: in that order a registry miss means the row is already committed or the session is
/// genuinely gone, while the reverse order could miss on both sides of a commit-then-clear.
///
/// Entries are keyed by session id alone, but a session id can get a second core in this process while the
/// first core's launch write is still queued (a handoff resume re-enqueues the launch write under the same
/// id, and the daemon can build a fresh core for an id it has seen before). To keep an older, still-queued
/// write from clobbering a newer core's entry, `recordPending` returns a generation token identifying the
/// recording, and `clear` only removes the entry when the generation passed back still matches what is
/// stored. An entry is cleared only by the launch write that recorded it, so an older queued write's later
/// commit or failure can never erase a newer same-session-id launch's entry.
public final class TerminalSessionPendingLaunchRegistry: @unchecked Sendable {
    public static let shared = TerminalSessionPendingLaunchRegistry()

    public init() {}

    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var pendingBySessionID: [String: (generation: UInt64, configuration: TerminalSessionLaunchConfiguration)] = [:]

    /// Records the configuration as pending and returns the generation token for this recording. Pass the
    /// token to `clear` so only this specific recording, not a later one for the same session id, can be
    /// removed by it.
    public func recordPending(_ configuration: TerminalSessionLaunchConfiguration) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextGeneration += 1
        let generation = nextGeneration
        pendingBySessionID[configuration.sessionID] = (generation, configuration)
        return generation
    }

    /// Removes the entry for `sessionID` only if it is still the one recorded under `generation`. A
    /// mismatch means a newer launch for the same session id recorded its own entry after this caller's,
    /// and that newer entry must survive this call.
    public func clear(sessionID: String, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard pendingBySessionID[sessionID]?.generation == generation else { return }
        pendingBySessionID.removeValue(forKey: sessionID)
    }

    public func pendingLaunchConfiguration(sessionID: String) -> TerminalSessionLaunchConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return pendingBySessionID[sessionID]?.configuration
    }
}
