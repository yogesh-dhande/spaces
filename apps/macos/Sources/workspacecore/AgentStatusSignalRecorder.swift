import Foundation

/// The terminal sessions whose coding agent has reported its status over OSC 7501.
///
/// A report is the agent saying what it is doing as it happens, so it outranks the status the agent's
/// hooks derive. Once a session is in this set, hook `working`/`blocked`/`done` signals for it stop
/// writing status (see `WorkspaceOrchestrator.recordAgentStatusSignal`); hooks keep owning everything
/// else. The daemon drops a session from the set when its agent goes away, so the next agent in that
/// terminal starts on hook status again.
///
/// Written on the terminal engine actor and read on the daemon's transport threads, hence the lock.
public final class ProgramStatusReportingSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionIDs: Set<String> = []

    public init() {}

    public func insert(sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        sessionIDs.insert(sessionID)
    }

    public func remove(sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        sessionIDs.remove(sessionID)
    }

    public func contains(sessionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionIDs.contains(sessionID)
    }
}

/// A status an agent can be reported in.
public enum AgentStatusSignal: String, Sendable {
    case working
    case blocked
    case done

    public var status: AgentWindowStatus {
        switch self {
        case .working: .spinning
        case .blocked: .waiting
        case .done: .done
        }
    }

    /// The subscriber notification this status produces, or `nil` when it produces none. Only
    /// blocked/done wake a watcher.
    var childNotificationTransition: AgentNotificationEngine.ChildTransition? {
        switch self {
        case .blocked: .blocked
        case .done: .done
        case .working: nil
        }
    }
}

/// Where an agent status report came from. The origin decides which source the event log records and
/// whether the program-status override applies.
public enum AgentStatusSignalOrigin: Sendable {
    /// A coding agent's lifecycle hook (`spaces agent signal`).
    case hook
    /// The agent's own OSC 7501 report, as read off the terminal.
    case programStatus

    var eventSource: String {
        switch self {
        case .hook: "spaces_agent_signal"
        case .programStatus: SQLiteStore.programStatusEventSource
        }
    }
}

public enum AgentStatusSignalOutcome: Equatable, Sendable {
    /// The row or its session key changed; interested surfaces should refresh.
    case recorded
    /// The signal was valid and changed nothing.
    case unchanged
    /// The signal does not apply to this terminal and was dropped.
    case ignored
}

extension WorkspaceOrchestrator {
    /// The one path every working/blocked/done report takes into agent rows and their notifications,
    /// whether it comes from a hook or from the agent's own OSC 7501 report, so blocked/done
    /// notifications, alerts, and push behave identically for both.
    ///
    /// `detectedAgentLabel` is the evidence that a coding agent runs in the terminal (its launch
    /// configuration or the classified foreground process). A report establishes a row only with that
    /// evidence; a report for a terminal with no agent and no row is ignored.
    ///
    /// A hook signal for a session in `programStatusSessions` writes no status and notifies no one: the
    /// agent's own report is the authority. It still lands its conversation id when it carries one,
    /// because only hooks learn that.
    public func recordAgentStatusSignal(
        _ signal: AgentStatusSignal, origin: AgentStatusSignalOrigin, workspaceID: String, terminalSessionID: String,
        sessionKey: AgentSessionKeyUpdate, detectedAgentLabel: String?, programStatusSessions: ProgramStatusReportingSessions,
        makeNotificationEngine: () -> AgentNotificationEngine
    ) throws -> AgentStatusSignalOutcome {
        let existingAgent = try agentWindows(workspaceID: workspaceID).first { $0.provider == .spaces && $0.terminalTrackingID == terminalSessionID }
        let existingLabel = existingAgent?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = detectedAgentLabel ?? (existingLabel?.isEmpty == false ? existingLabel : nil)
        guard existingAgent != nil || label != nil else { return .ignored }
        // A report waits on the delivery queue, so it can land after its agent ended (Codex sends `clear`
        // as it exits): the end already dropped the session from the reporting set and may have
        // finalized the row, and the late report must neither write status nor revive the row.
        if origin == .programStatus {
            guard programStatusSessions.contains(sessionID: terminalSessionID), existingAgent?.status != .exited else { return .ignored }
        }
        let environmentKeys = [Self.terminalTrackingIDEnvVar]

        if origin == .hook, programStatusSessions.contains(sessionID: terminalSessionID) {
            // An exited row is not this agent's to re-register; the registration would revive it.
            guard let existingAgent, existingAgent.status != .exited, sessionKey != .keep else { return .ignored }
            let changed = try updateAgentWindowSessionKey(
                id: existingAgent.id, sessionKey: sessionKey, eventSource: origin.eventSource, environmentKeys: environmentKeys)
            return changed ? .recorded : .unchanged
        }

        // Per-tool hooks fire `working` as each tool starts and again as it completes. When the agent is
        // already working the signal changes nothing, so return before building the engine; the store
        // layer enforces the same duplicate-working suppression for every other signal surface.
        if signal == .working, existingAgent?.status == signal.status { return .unchanged }

        // The first `working` after `blocked` is the resume that follows a permission approval, which
        // fires no hook of its own, so this transition is also what withdraws any held "is blocked"
        // line for this child before a subscriber can receive stale misinformation.
        let resumedFromBlocked = signal == .working && existingAgent?.status == .waiting
        let updated: AgentWindowRecord
        do {
            // A signal that read an existing row may update only that row: if a concurrent exit
            // finalized it first, the signal is dropped rather than recreating or reviving it.
            updated = try updateAgentWindowStatus(
                workspaceID: workspaceID, provider: .spaces, terminalTrackingID: terminalSessionID, sessionKey: sessionKey, label: label,
                status: signal.status, eventType: signal.rawValue, eventSource: origin.eventSource, environmentKeys: environmentKeys,
                readAgent: existingAgent)
        } catch is AgentRowFinalizedError { return .ignored }

        let engine = makeNotificationEngine()
        if resumedFromBlocked { try engine.childDidResumeWorking(agentSessionID: updated.id) }
        if let transition = signal.childNotificationTransition { try engine.childDidTransition(agent: updated, transition: transition) }
        // Gated on the RESULTING row status rather than the signal: queued child events must reach this
        // terminal's own agent only once that agent is idle or done.
        if updated.status.leavesSubscriberIdle { try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: terminalSessionID) }
        return .recorded
    }
}
