import Foundation
import spacesterminalcore

/// What an explicit Stop on a workspace terminal row resolved to. The three outcomes are the decisions
/// the daemon makes, not transport wording: each transport phrases them for its own surface (the Device
/// API answers a sidebar Stop, the profile socket answers `spaces terminal stop`).
public enum WorkspaceTerminalStopOutcome: Sendable, Equatable {
    /// The session belonged to an active automation run, and cancelling that run owned the Stop.
    case canceledAutomationRun
    /// The session was terminated: as a coding agent, as a configured process, or as an ad hoc terminal.
    case stopped
    /// Nothing was left to stop: the session had already ended.
    case alreadyStopped
}

/// A dependency an explicit Stop needs that this daemon was not built with. Raised rather than resolved
/// locally so each transport keeps its own wording and error classification for an unserviceable daemon.
public enum WorkspaceTerminalStopUnavailable: Error, Sendable, Equatable {
    /// The session belongs to an automation run, but no automation service is installed.
    case automations
    /// The session is a coding agent, but no agent-session killer is installed.
    case agentStop
}

extension WorkspaceOrchestrator {
    /// The explicit-Stop decision `spaces terminal stop` drives: the shared ladder below, refused for a
    /// session that has already ended. An ended session keeps its rows so its scrollback stays reachable, so
    /// the ladder on its own would tear that retained state down, or cancel an automation run that has since
    /// moved on to another session, for a session id that names nothing live. The gate therefore reads the
    /// authorities that change with the session itself (`workspaceTerminalSessionIsLive`), not the durable
    /// runtime row, which trails an exit by however long its write-behind write takes.
    ///
    /// The shared ladder stays ungated for the Device API on purpose: the sidebar and the iOS runtime list
    /// offer Stop on a coding-agent row whatever the row's run state, and that Stop is how an agent row whose
    /// session is gone gets cleared, so gating the shared path would take that away. Every other row those
    /// surfaces offer Stop on carries it only while the row reads running.
    public func stopLiveWorkspaceTerminalSession(
        workspaceID: String, sessionID: String, automationOperations: AutomationOperations?, killAgentSession: ((String) throws -> Bool)?
    ) throws -> WorkspaceTerminalStopOutcome {
        guard workspaceTerminalSessionIsLive(sessionID: sessionID) else { return .alreadyStopped }
        return try stopWorkspaceTerminalSession(
            workspaceID: workspaceID, sessionID: sessionID, automationOperations: automationOperations, killAgentSession: killAgentSession)
    }

    /// Whether a terminal session still has something for an explicit Stop to end. Every authority read here
    /// changes at the moment the session's state changes, because the durable runtime row does not: the
    /// session host writes it through the write-behind persistence queue, so a session that has just exited
    /// still reads `.running` from that row for as long as the write takes.
    ///
    /// 1. The control socket is the live-session marker the host unlinks synchronously inside `terminate()`,
    ///    before it enqueues the exited row, so it is gone the instant the session is. `builtInSessionIsStillLive`
    ///    pairs it with the runtime row and the service process, which is the same liveness test the rest of
    ///    the daemon uses.
    /// 2. A launch whose durable writes are still queued has no row to read at all. The pending-launch
    ///    registry is the record of exactly that window: an entry is recorded before the launch write is
    ///    enqueued and removed only once it commits.
    /// 3. That entry clears when the launch row commits, which can land while the host is still bringing its
    ///    control socket up, so a launch that has not written a runtime row yet is still starting. This is the
    ///    one age-bounded reading, and it is narrowed to sessions with no runtime row, so a session that has
    ///    ever run (and therefore has one) is never read as live by its age.
    public func workspaceTerminalSessionIsLive(sessionID: String, now: Date = Date()) -> Bool {
        func launchIsRecent(_ configuration: TerminalSessionLaunchConfiguration) -> Bool {
            guard let createdAt = TerminalSessionTimestamp.date(from: configuration.createdAt) else { return false }
            let age = now.timeIntervalSince(createdAt)
            return age >= -5 && age < 60
        }
        if builtInSessionIsStillLive(sessionID: sessionID) { return true }
        if let pending = TerminalSessionPendingLaunchRegistry.shared.pendingLaunchConfiguration(sessionID: sessionID) {
            return launchIsRecent(pending)
        }
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return false }
        guard (try? TerminalSessionPersistence.readRuntimeState(paths: paths)) == nil else { return false }
        guard let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths) else { return false }
        return launchIsRecent(launchConfiguration)
    }

    /// The explicit-Stop decision for one terminal session inside a workspace, shared by every transport
    /// that offers Stop on a runtime target: the sidebar's Stop over the Device API and `spaces terminal
    /// stop` over the profile socket. Both must tear a session down identically, so the ladder lives here
    /// once instead of in each transport's handler.
    ///
    /// The order is the decision order, not a preference list:
    /// 1. An automation-attributed session belongs to its run. Cancelling the run tears down everything it
    ///    owns, so only a cancellation that actually won while the run was still active owns the Stop; a
    ///    cancel that serialized behind the run's own completion leaves a live session for the steps below.
    /// 2. A coding agent (one that registered through its hooks, or one spawned as `.agent` that has not
    ///    signaled yet) must go through the agent stop chokepoint, which tells its subscribers it exited
    ///    before deleting its row.
    /// 3. A configured process owns its terminal, so ending the process is what ends the session.
    /// 4. Anything else is an ad hoc workspace terminal.
    ///
    /// Every branch tears down through a path that takes the mutation-boundary daemon-handoff veto under the
    /// workspace lifecycle lock, so a handoff that begins after a transport's own entry check refuses the stop
    /// rather than deleting rows for a terminal that survives into the successor daemon.
    public func stopWorkspaceTerminalSession(
        workspaceID: String, sessionID: String, automationOperations: AutomationOperations?, killAgentSession: ((String) throws -> Bool)?
    ) throws -> WorkspaceTerminalStopOutcome {
        if let runID = try store.automationRunID(terminalSessionID: sessionID), let run = try store.automationRun(id: runID) {
            guard let automationOperations else { throw WorkspaceTerminalStopUnavailable.automations }
            let wasActiveBeforeCancel = !run.status.isTerminal
            let canceledRun = try automationOperations.cancelRun(runID)
            if wasActiveBeforeCancel, canceledRun.status == .canceled { return .canceledAutomationRun }
        }
        // A hook-registered agent can run inside a configured process terminal. Its launch kind stays
        // `.process`, so resolve the persisted agent row before the `.agent` launch-kind check reserved for
        // pre-signal sessions.
        let isRegisteredAgent = try store.agentWindowByTerminalSession(terminalSessionID: sessionID) != nil
        if isRegisteredAgent || workspaceTerminalSessionIsSpawnedAgent(workspaceID: workspaceID, sessionID: sessionID) {
            guard let killAgentSession else { throw WorkspaceTerminalStopUnavailable.agentStop }
            return try killAgentSession(sessionID) ? .stopped : .alreadyStopped
        }
        // The `running_processes` row is what the sidebar's process Stop targets, so a session a configured
        // process owns is stopped by stopping that process, through the same orchestrator call. The ad hoc
        // branch below refuses a session with a configured owner, so without this the CLI would report a
        // live configured-process terminal as already stopped while its process kept running.
        if let process = try builtInTerminalSessionOwnership(sessionID: sessionID).process {
            guard process.status != .exited else { return .alreadyStopped }
            try stopWorkspaceProcess(workspaceID: process.workspaceID, processID: process.id)
            return .stopped
        }
        return try stopAdHocBuiltInTerminalSession(workspaceID: workspaceID, sessionID: sessionID) ? .stopped : .alreadyStopped
    }
}
