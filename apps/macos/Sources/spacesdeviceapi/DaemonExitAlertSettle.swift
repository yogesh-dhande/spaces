import Foundation
import spacesdevicecore
import workspacecore

/// Settles what the previous daemon's exit ended, at the next daemon's start: its terminals raise no
/// end-of-session alert, and its configured processes read as not started. The rules and the reason the
/// work waits for the next start are on the `WorkspaceOrchestrator` extension that keeps the shutdown
/// record.
///
/// Alerts are suppressed by recording dismissals, so the same overview a client would build decides which
/// alerts exist. Bells, agent alerts, automation runs, and sessions that ended on their own before the
/// daemon went away are left alone.
public enum DaemonExitAlertSettle {
    /// Runs before the daemon serves anything, on the thread that started it.
    ///
    /// - Parameters:
    ///   - strandedSessionIDs: sessions stale recovery repaired after an unclean exit.
    ///   - adoptedSessionIDs: sessions an in-place handoff carried over, which no exit ended.
    public static func settle(store: SQLiteStore, strandedSessionIDs: [String], adoptedSessionIDs: Set<String>) throws {
        let orchestrator = WorkspaceOrchestrator(store: store)
        let endedSessionIDs = try orchestrator.sessionsRecordedAsEndedByDaemonShutdown().union(strandedSessionIDs).subtracting(adoptedSessionIDs)
        if !endedSessionIDs.isEmpty {
            // Released first: the overview then lists the process terminals the way any client will see
            // them after the release, so the keys recorded below are the ones that would otherwise alert.
            try orchestrator.releaseProcessRowsEndedByDaemonExit(sessionIDs: endedSessionIDs)
            // No in-memory sessions (the daemon has built no core yet), no teardown in flight, and no
            // advertised addresses (the Device API is not listening yet). Alerts read none of them.
            let overview = try SpacesDeviceOverviewLoader(
                store: store, orchestrator: orchestrator, liveInMemorySessions: [], workspaceIDsWithTeardownInFlight: [], deviceAPIAddresses: []
            ).load()
            try orchestrator.recordAlertDismissals(keys: overview.endOfSessionAlertKeys(forSessionIDs: endedSessionIDs))
        }
        try orchestrator.clearSessionsEndedByDaemonShutdown()
    }
}
