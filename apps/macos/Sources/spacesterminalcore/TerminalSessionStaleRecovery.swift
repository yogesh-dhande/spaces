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
///
/// This sweep is a best-effort backstop, not a guarantee. The repair itself is a durable write, and a
/// write that cannot commit within a bounded in-place retry — the same pathological writer-lock or
/// storage fault that can drop a predecessor's exited-state write — leaves the row in its prior live
/// state rather than falsely reporting it finalized. Those sessions are returned in `unrepaired` so the
/// caller can log them, and they heal at the next daemon restart via the dead-pid branch (the successor
/// runs under a new pid, so the still-`.running` row falls to "dead pid → repair"). The strand is
/// therefore bounded to the current daemon's lifetime, never permanent.
public enum TerminalSessionStaleRecovery {
    /// Bounded in-place retry for a repair write that cannot commit, mirroring the per-core persistence
    /// queue's exited-write policy. This runs once on a cold startup path, so blocking a few extra
    /// seconds under a sustained storage fault is acceptable; each attempt already gets SQLite's own
    /// ~5s busy handling, so the loop only matters for a fault that persists past that window.
    static let repairWriteMaxAttempts = 5
    static let repairWriteRetryDelay: TimeInterval = 0.2

    /// One repaired row: the session and the terminal state it was rewritten to.
    public struct FinalizedSession: Sendable, Equatable {
        public let sessionID: String
        public let state: TerminalSessionState

        public init(sessionID: String, state: TerminalSessionState) {
            self.sessionID = sessionID
            self.state = state
        }
    }

    /// Outcome of one reconciliation pass.
    public struct ReconcileResult: Sendable, Equatable {
        /// Sessions this pass rewrote to a terminal state.
        public let finalized: [FinalizedSession]
        /// Sessions whose repair write could not commit within the bounded in-place retry (a sustained
        /// writer lock or storage fault). Left untouched in their prior live state; the caller logs them
        /// and the next daemon restart heals them via the dead-pid branch.
        public let unrepaired: [String]

        public init(finalized: [FinalizedSession], unrepaired: [String]) {
            self.finalized = finalized
            self.unrepaired = unrepaired
        }
    }

    /// Runs one reconciliation pass over every known session and reports the sessions it finalized and
    /// the ones whose repair write could not commit.
    ///
    /// - Parameters:
    ///   - ownPID: this daemon image's pid (`getpid()`), matched against each row's `service_pid`.
    ///   - adoptedSessionIDs: sessions this image successfully adopted from the handoff table; exempt
    ///     from repair because they are live under this pid. Empty on a fresh boot.
    ///   - isProcessAlive: liveness probe for a foreign pid, injected so the daemon shares its own
    ///     `kill(pid, 0)` implementation and tests can drive the foreign-pid branch deterministically.
    ///   - now: repair timestamp, injected for testability.
    @discardableResult public static func reconcile(
        ownPID: Int32, adoptedSessionIDs: Set<String>, isProcessAlive: (Int32) -> Bool, now: Date = Date()
    ) throws -> ReconcileResult {
        let nowString = ISO8601DateFormatter().string(from: now)
        var finalized: [FinalizedSession] = []
        var unrepaired: [String] = []
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
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: ownPID, childPID: runtimeState.childPID,
                state: terminalState, updatedAt: nowString, exitedAt: nowString, title: runtimeState.title ?? launchConfiguration.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, columns: runtimeState.columns,
                rows: runtimeState.rows)
            // The repair is a durable write. If it cannot commit within the bounded in-place retry (a
            // sustained writer lock or storage fault — the same failure that can drop a predecessor's
            // exited-state write), do NOT report the session as finalized: leave the row in its prior
            // live state so nothing observes a false terminal state, record it as unrepaired for the
            // caller to log, and let the next daemon restart heal it via the dead-pid branch.
            guard commitRepair(finalizedState, detachedAt: nowString, paths: paths) else {
                unrepaired.append(launchConfiguration.sessionID)
                continue
            }
            try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
            try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)
            finalized.append(FinalizedSession(sessionID: launchConfiguration.sessionID, state: terminalState))
        }
        return ReconcileResult(finalized: finalized, unrepaired: unrepaired)
    }

    /// Writes the finalized runtime state and detaches active clients as one repair, retrying in place
    /// up to `repairWriteMaxAttempts` with a `repairWriteRetryDelay` back-off between attempts (mirroring
    /// the persistence queue's exited-write pattern). Returns `true` once the repair commits, `false` if
    /// every attempt fails. The runtime-state write and the client detach are performed inside a single
    /// `finalizeSessionRepair` transaction, so the repair is all-or-nothing: on failure neither half has
    /// altered durable state and the row stays in its prior live state. This atomicity is what lets a
    /// failed repair heal at the next daemon restart via the dead-pid branch — a partial commit (row
    /// finalized but clients left attached) would strand ghost attachments the terminal-row-skipping
    /// sweep could never revisit.
    private static func commitRepair(_ finalizedState: TerminalSessionRuntimeState, detachedAt: String, paths: TerminalSessionPaths) -> Bool {
        var attempt = 0
        while true {
            do {
                try TerminalSessionPersistence.finalizeSessionRepair(finalizedState, detachedAt: detachedAt, paths: paths)
                return true
            } catch {
                attempt += 1
                guard attempt < repairWriteMaxAttempts else { return false }
                Thread.sleep(forTimeInterval: repairWriteRetryDelay)
            }
        }
    }
}
