import Foundation
import spacesterminalcore

extension WorkspaceOrchestrator {
    /// Removes an exited automation session from its workspace's live runtime targets without touching the
    /// retained terminal session or its automation-run attribution. Runs-tab replay continues to use those
    /// persisted records; the workspace sidebar represents only live automation activity.
    @discardableResult func detachExitedAutomationSessionRuntimeTarget(sessionID: String) throws -> Bool {
        guard let (sessionID, workspaceID) = automationSessionWorkspace(sessionID: sessionID) else { return false }
        return try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            guard !automationSessionIsLive(sessionID: sessionID) else { return false }
            try cleanupAutomationTerminalSessionRuntimeTarget(sessionID: sessionID, workspaceID: workspaceID)
            return true
        }
    }

    /// Removes the workspace-side representation of an automation terminal that is about to have its
    /// persisted session, transcript, and run attribution deleted. Unlike the exited-session path, this
    /// accepts a live session because explicit automation deletion is terminating. It intentionally handles
    /// every automation launch kind: a script wrapper has no agent row, while agent-owned and attributed
    /// sessions may have rows and subscriber state that need the normal finalization chokepoint.
    @discardableResult func removeAutomationTerminalSessionRuntimeTargetForDeletion(sessionID: String) throws -> Bool {
        guard let (sessionID, workspaceID) = automationSessionWorkspace(sessionID: sessionID) else { return false }
        return try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            try cleanupAutomationTerminalSessionRuntimeTarget(sessionID: sessionID, workspaceID: workspaceID)
            return true
        }
    }

    /// Workspace/project teardown already owns the lifecycle gate. It uses the identical runtime-target,
    /// agent-row, subscriber, and running-state cleanup as ordinary automation deletion without reclaiming
    /// the gate.
    func removeAutomationTerminalSessionRuntimeTargetDuringWorkspaceTeardown(sessionID: String) throws {
        guard let (sessionID, workspaceID) = automationSessionWorkspace(sessionID: sessionID) else { return }
        try cleanupAutomationTerminalSessionRuntimeTarget(sessionID: sessionID, workspaceID: workspaceID)
    }

    private func automationSessionWorkspace(sessionID: String) -> (String, String)? {
        guard let sessionID = normalizedTerminalSessionID(sessionID), let launch = terminalSessionLaunchConfiguration(sessionID: sessionID),
            launch.automationRunID != nil, let workspaceID = launch.workspaceID
        else { return nil }
        return (sessionID, workspaceID)
    }

    /// Deletes the runtime target first so terminal-session persistence cannot disappear while the workspace
    /// still points at it. `deleteAgentRows` also tears down subscriber state for row-less script sessions.
    func cleanupAutomationTerminalSessionRuntimeTarget(sessionID: String, workspaceID: String) throws {
        for window in try store.windowsReferencingTerminalSession(terminalSessionID: sessionID) { try store.deleteWindow(id: window.id) }
        try deleteAgentRows(forBuiltInTerminalSession: sessionID, workspaceID: workspaceID)
        try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspaceID)
    }

    /// Single-quotes a token for safe interpolation into an automation command string.
    func automationShellQuoted(_ token: String) -> String { shellSingleQuoted(token) }

    /// Whether a built-in terminal session is still live (control socket present, interactive runtime
    /// state, service PID alive). Exposed for the automation executor's attributed-session sweep.
    func automationSessionIsLive(sessionID: String) -> Bool { builtInSessionIsStillLive(sessionID: sessionID) }

    /// Whether a built-in terminal session's launch is still pending — its runtime row is absent or stale
    /// (write-behind persistence, post-#224, has not landed it yet) while a recent launch configuration says
    /// it is coming up. Exposed for the automation executor's poll paths, which must read an absent runtime
    /// row within this grace window as indeterminate (session still launching) rather than as a completed or
    /// dead session that should finalize the run.
    func automationSessionLaunchIsPending(sessionID: String) -> Bool { builtInSessionLaunchIsPending(sessionID: sessionID) }

    /// Terminates a built-in terminal session through the daemon's existing termination machinery.
    func automationTerminateSession(sessionID: String) { builtInTerminalSessionTerminator(sessionID) }

    /// Writes input to an automation's terminal session, used by the agent-kind executor to deliver a seed
    /// prompt. `appendNewline: true` is the submit path: the session host's send chokepoint writes the text
    /// and a spaced Enter keystroke so every supported agent TUI runs the line. Routes through the
    /// process-wide input writer the daemon installs; with none installed (non-daemon callers, which never
    /// spawn agent automations) the write throws.
    func writeAutomationSessionInput(sessionID: String, input: TerminalProfileInput, appendNewline: Bool) throws {
        guard let writer = Self.builtInTerminalSessionInputWriterOverrideStore.get() else {
            throw WorkspaceError.invalidArgument(message: "No terminal session input writer is configured.")
        }
        try writer(sessionID, input, appendNewline)
    }
}
