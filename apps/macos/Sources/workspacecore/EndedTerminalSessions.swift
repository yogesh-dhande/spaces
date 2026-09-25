import Foundation
import spacesterminalcore

/// Which of a set of built-in terminal sessions have ended, decided from one read of their persisted rows.
///
/// The tracked-runtime rule classifies a session per retained pane and coding-agent row, and those rows
/// accumulate: an ended pane keeps its row so it stays listed and reopenable, most visibly on the home
/// workspace. Asking the database per row put two round trips per row on the profile database's serialized
/// lane, on a path the device overview rebuilds several times a second, so the rows every verdict needs
/// are read together (`WorkspaceOrchestrator.endedTerminalSessions`) and every verdict is decided here in
/// memory. The device overview reads one of these for a whole refresh and classifies every workspace
/// against it.
public struct EndedTerminalSessions: Sendable {
    private let lifecycles: [String: TerminalSessionLifecycleState]

    init(lifecycles: [String: TerminalSessionLifecycleState]) { self.lifecycles = lifecycles }

    /// Whether a built-in terminal session has ended: its persisted runtime state is no longer interactive
    /// (`exited` or `failed`), or there is no persisted state left to read, which is what a session already
    /// purged by retention garbage collection leaves behind. A session whose launch is still pending has
    /// not ended, whatever its persisted state reads.
    ///
    /// Past that launch check, only the persisted state is read, deliberately. This answers "has this
    /// session ended", which the daemon records once and for all when it does, while
    /// `WorkspaceOrchestrator.builtInTerminalSessionIsInteractive` answers "can this session be talked to
    /// right now" and therefore also probes the service process hosting it.
    func sessionHasEnded(_ sessionID: String, now: Date = Date()) -> Bool {
        // A launch still coming up is live runtime: its state write can be queued behind the per-core
        // persistence queue, so the read finds no state (or the previous run's leftover) for a session that
        // is starting right now, and nothing re-asserts a running flag cleared under it.
        if launchIsPending(sessionID, now: now) { return false }
        guard let state = lifecycles[sessionID]?.runtimeState else { return true }
        return !state.isInteractive
    }

    /// The same question `WorkspaceOrchestrator.builtInSessionLaunchIsPending` answers per session, decided
    /// against the batch already read: the registry is consulted first and its entry is trusted over any
    /// durable row, and a session whose durable state has already settled to a non-interactive one is not
    /// a launch in flight.
    private func launchIsPending(_ sessionID: String, now: Date) -> Bool {
        if let pending = TerminalSessionPendingLaunchRegistry.shared.pendingLaunchConfiguration(sessionID: sessionID) {
            guard let createdAt = TerminalSessionTimestamp.date(from: pending.createdAt) else { return false }
            return BuiltInTerminalLaunchWindow.covers(createdAt: createdAt, now: now)
        }
        guard let lifecycle = lifecycles[sessionID] else { return false }
        if let state = lifecycle.runtimeState, !state.isInteractive { return false }
        guard let createdAt = TerminalSessionTimestamp.date(from: lifecycle.createdAt) else { return false }
        return BuiltInTerminalLaunchWindow.covers(createdAt: createdAt, now: now)
    }
}
