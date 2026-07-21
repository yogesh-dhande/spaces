import Foundation

extension WorkspaceOrchestrator {
    /// Releases every product row that keeps an ended terminal session referenced, so the daemon's
    /// terminal-session garbage collector can then purge the session's on-disk state and
    /// `terminal_sessions` row. This is the age-based-expiry counterpart the collector calls once a session
    /// has been ended (state exited/failed, service dead) for longer than the retention window.
    ///
    /// PRECONDITION: the caller (the daemon GC) has already established that the session is ended and has no
    /// live attachment. This method NEVER inspects or mutates the session's own runtime/on-disk state — it
    /// only removes the `agent_sessions`, `running_processes`, and `runtime_targets` rows that reference it,
    /// because the backing terminal is provably gone. That fact is exactly the contract of the agent
    /// chokepoint's `.destroyed` disposition and of `stopRunningProcess`'s row cleanup, so both are reused
    /// here with their live-termination side effects (killing the terminal / process group, closing a
    /// window) suppressed — there is nothing left alive to terminate.
    ///
    /// After this returns, `store.terminalSessionIsReferencedByProduct(sessionID)` is false: the three
    /// reference sources it checks are cleared in order. It throws on the first failure; the GC contains
    /// per-session errors so one poisoned session cannot stall the sweep.
    public func releaseEndedTerminalSessionReferences(sessionID: String) throws {
        // 1. Agent rows — routed through the finalization chokepoint so inbound watch edges
        //    (`agent_subscriptions`, ON DELETE RESTRICT) are dropped and any subscriber is notified before
        //    the row is deleted. `terminateTerminalSession: false`: the backing terminal is already dead, so
        //    the chokepoint must not try to kill it. The `.destroyed` disposition deletes the row regardless
        //    of its status, which is correct here — the terminal is provably gone.
        for record in try store.agentWindowsByTerminalSession(terminalSessionID: sessionID) {
            try finalizeAgentRow(record, reason: .destroyed(terminateTerminalSession: false))
        }

        // 2. Running-process rows — mirror the row-cleanup half of `stopRunningProcess` without its
        //    termination side effects (no `terminateBuiltInTerminalSession` / `terminateProcessGroup` /
        //    `builtInTerminalWindowCloser`), since the process and its terminal are already dead.
        for process in try store.runningProcessesByTerminalSession(terminalSessionID: sessionID) {
            try releaseEndedRunningProcessRow(process)
        }

        // 3. Any remaining `runtime_targets` focus rows — ad-hoc terminal panes a workspace layout holds
        //    directly, not owned by a process or agent row. Sweeping these last clears the final reference
        //    source `terminalSessionIsReferencedByProduct` checks.
        for window in try store.windowsReferencingTerminalSession(terminalSessionID: sessionID) {
            try store.deleteWindow(id: window.id)
        }
    }

    /// Row-cleanup half of `stopRunningProcess` for a process whose backing terminal is already dead:
    /// deletes the process's tracked terminal window (matched exactly as `stopRunningProcess` does), the
    /// `running_processes` row, then marks the workspace stopped if it has no remaining tracked runtime
    /// indicators. No termination is issued — the process is gone.
    private func releaseEndedRunningProcessRow(_ process: RunningProcessRecord) throws {
        let workspaceID = process.workspaceID
        if let terminalWindow = try store.windows(workspaceID: workspaceID).first(where: { matchesTrackedTerminalWindow($0, process: process) }) {
            try store.deleteWindow(id: terminalWindow.id)
        }
        try store.deleteRunningProcess(id: process.id)
        try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspaceID)
    }
}
