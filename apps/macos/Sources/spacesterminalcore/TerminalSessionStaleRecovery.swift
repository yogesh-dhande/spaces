import Foundation

/// Startup reconciliation of durable runtime rows a predecessor daemon (or a crashed prior process)
/// left claiming a live state (`.starting`/`.running`). This is the single repair chokepoint the
/// daemon runs once at boot, AFTER handoff adoption, so `adoptedSessionIDs` names every session this
/// image legitimately took over and must be exempted.
///
/// The repair matrix is keyed on the row's `service_pid`:
///  - dead pid (process not alive) .................. repair `.failed` — the owning daemon process is gone.
///  - our pid, session adopted from handoff ......... leave — live, this image owns it.
///  - our pid, session NOT adopted .................. repair `.exited` — a session the predecessor image
///                                                     terminated but whose exited-state write was lost
///                                                     across `execv` (which preserves the pid), or a
///                                                     same-pid reuse after a prior daemon under this pid
///                                                     died. Either way the child is gone.
///  - other live pid ............................... leave — a live process owns it.
///
/// Why the own-pid-not-adopted case exists: the `execv` handoff keeps the same pid, so the plain
/// dead-pid check can never fire for a row the predecessor stranded — the pid is still alive as this
/// successor image. When a predecessor's exited-state write is dropped (e.g. the per-core persistence
/// queue exhausts its bounded retries under sustained writer-lock contention or a storage fault during
/// handoff), that `.running` row would otherwise remain forever, its `service_pid` matching this live
/// image, and the session would be stranded as running until some future daemon restart under a
/// different pid. Reconciling own-pid rows that were not adopted closes that lost-write-across-`execv`
/// class regardless of which write was dropped, and also hardens the pid-reuse corner on a fresh boot.
///
/// A plain (non-`execv`) daemon shutdown needs nothing beyond the dead-pid case: the successor runs
/// under a different pid, so the predecessor's rows fall to "dead pid → repair".
public enum TerminalSessionStaleRecovery {
    /// One repaired row: the session and the terminal state it was rewritten to.
    public struct FinalizedSession: Sendable, Equatable {
        public let sessionID: String
        public let state: TerminalSessionState

        public init(sessionID: String, state: TerminalSessionState) {
            self.sessionID = sessionID
            self.state = state
        }
    }

    /// Runs one reconciliation pass over every known session and returns the sessions it finalized.
    ///
    /// - Parameters:
    ///   - ownPID: this daemon image's pid (`getpid()`), matched against each row's `service_pid`.
    ///   - adoptedSessionIDs: sessions this image successfully adopted from the handoff table; exempt
    ///     from repair because they are live under this pid. Empty on a fresh boot.
    ///   - isProcessAlive: liveness probe for a foreign pid, injected so the daemon shares its own
    ///     `kill(pid, 0)` implementation and tests can drive the foreign-pid branch deterministically.
    ///   - now: repair timestamp, injected for testability.
    @discardableResult
    public static func reconcile(
        ownPID: Int32,
        adoptedSessionIDs: Set<String>,
        isProcessAlive: (Int32) -> Bool,
        now: Date = Date()
    ) throws -> [FinalizedSession] {
        let nowString = ISO8601DateFormatter().string(from: now)
        var finalized: [FinalizedSession] = []
        for launchConfiguration in try TerminalSessionPersistence.listKnownSessions() {
            let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
            guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { continue }
            guard runtimeState.state == .starting || runtimeState.state == .running else { continue }

            let terminalState: TerminalSessionState
            if runtimeState.servicePID == ownPID {
                // Our own pid. `execv` preserves the pid, so a row that claims this live image but was not
                // adopted from the handoff table is a predecessor's stranded session (its exited write was
                // dropped) — or a same-pid reuse after a prior daemon under this pid died. The predecessor
                // DID terminate the session, so `.exited` is the truthful terminal state (mirroring the
                // nil-quiesce handoff branch, which finalizes an already-exited child `.exited`).
                guard !adoptedSessionIDs.contains(launchConfiguration.sessionID) else { continue }
                terminalState = .exited
            } else {
                // A foreign pid: stale only if that process is gone. The owning daemon vanished without
                // finalizing this row, so `.failed` records that the run did not end cleanly.
                guard !isProcessAlive(runtimeState.servicePID) else { continue }
                terminalState = .failed
            }

            let finalizedState = TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: ownPID,
                childPID: runtimeState.childPID, state: terminalState, updatedAt: nowString, exitedAt: nowString,
                title: runtimeState.title ?? launchConfiguration.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory,
                columns: runtimeState.columns, rows: runtimeState.rows)
            try? TerminalSessionPersistence.writeRuntimeState(finalizedState, paths: paths)
            try? TerminalSessionPersistence.detachActiveClients(paths: paths, detachedAt: nowString)
            try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
            try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)
            finalized.append(FinalizedSession(sessionID: launchConfiguration.sessionID, state: terminalState))
        }
        return finalized
    }
}
