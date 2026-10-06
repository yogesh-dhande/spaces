import Foundation

/// What a daemon exit (a clean shutdown, or a crash found at the next start) leaves behind for the next
/// daemon to settle: the terminals it ended must not alert, and the configured processes it ended read
/// as not started, exactly like Stop All.
///
/// The work happens at the next start, not at shutdown: a process row is finalized only by the exit
/// monitor after the listeners open, a kill can land between terminating the sessions and any later
/// write, and a logout gives shutdown only a few seconds. Shutdown therefore writes one small record
/// before it terminates anything, and the next start acts on it.
extension WorkspaceOrchestrator {
    private static let sessionsEndedByDaemonShutdownKey = "daemon_shutdown_session_ids"

    /// Names the sessions a shutdown is about to end. Replaces any earlier record.
    public func recordSessionsEndedByDaemonShutdown(_ sessionIDs: [String]) throws {
        let data = try JSONEncoder().encode(sessionIDs.sorted())
        try store.setSetting(key: Self.sessionsEndedByDaemonShutdownKey, value: String(decoding: data, as: UTF8.self))
    }

    public func sessionsRecordedAsEndedByDaemonShutdown() throws -> Set<String> {
        guard let json = try store.setting(key: Self.sessionsEndedByDaemonShutdownKey) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(json.utf8)))
    }

    public func clearSessionsEndedByDaemonShutdown() throws { try store.setSetting(key: Self.sessionsEndedByDaemonShutdownKey, value: nil) }

    /// Releases the running-process rows of `sessionIDs` the way Stop All leaves them: the row and its
    /// tracked terminal window go, nothing is terminated, and the workspace's running flag is recomputed.
    /// Run before the process-exit monitor starts, so it never sees these rows and no on-exit policy
    /// (a "Process Exited" notification, a relaunch) runs for them.
    ///
    /// A process set to restart on exit is released too: a restart brings its workspace back stopped as a
    /// whole, as Stop All does, rather than partly running, because restoring never starts workspaces.
    ///
    /// A bell the process rang goes with its rows, since nothing lists the ended session afterwards. Stop
    /// All drops it the same way, and keeping a row only to carry a dev server's bell is not worth it.
    public func releaseProcessRowsEndedByDaemonExit(sessionIDs: Set<String>) throws {
        for sessionID in sessionIDs.sorted() {
            for process in try store.runningProcessesByTerminalSession(terminalSessionID: sessionID) {
                try withWorkspaceLifecycleLockWaiting(workspaceID: process.workspaceID) { try releaseEndedRunningProcessRow(process) }
            }
        }
    }
}
