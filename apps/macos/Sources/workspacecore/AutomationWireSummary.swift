import Foundation
import spacesterminalcore

/// Maps the persisted automation domain models to the shared terminal-service wire summaries. Living in
/// `workspacecore` (which sees both the domain models and the wire types) keeps the one mapping the daemon
/// uses for every transport in a single place; the enum-typed domain fields become their raw string values
/// and the domain `Date`s become ISO8601 strings.
extension TerminalServiceAutomationSummary {
    public init(_ automation: Automation) {
        self.init(
            id: automation.id, name: automation.name, enabled: automation.enabled, triggerKind: automation.triggerKind.rawValue,
            cronExpression: automation.cronExpression, kind: automation.kind.rawValue, script: automation.script,
            agentCommand: automation.agentCommand, agentPrompt: automation.agentPrompt, workspaceID: automation.workspaceID,
            workingDirectory: automation.workingDirectory, timeoutSeconds: automation.timeoutSeconds,
            concurrencyPolicy: automation.concurrencyPolicy.rawValue, missedRunPolicy: automation.missedRunPolicy.rawValue,
            nextFireTime: automation.nextFireTime.map(TerminalSessionTimestamp.string(from:)),
            createdAt: TerminalSessionTimestamp.string(from: automation.createdAt),
            updatedAt: TerminalSessionTimestamp.string(from: automation.updatedAt))
    }
}

extension TerminalServiceAutomationRunSummary {
    /// `automationName` is denormalized in by the caller (from the run's automation lookup, when it still
    /// exists); `attributedAgents` is the run's coding-agent breakdown, which the caller builds once for the
    /// whole listing (see `AutomationAttributedAgents`).
    public init(_ run: AutomationRun, automationName: String?, attributedAgents: [TerminalServiceAutomationAgentSummary] = []) {
        self.init(
            id: run.id, automationID: run.automationID, automationName: automationName, kind: run.kind.rawValue, status: run.status.rawValue,
            trigger: run.trigger.rawValue, skipReason: run.skipReason?.rawValue, exitCode: run.exitCode, terminalSessionID: run.terminalSessionID,
            startedAt: run.startedAt.map(TerminalSessionTimestamp.string(from:)), endedAt: run.endedAt.map(TerminalSessionTimestamp.string(from:)),
            createdAt: TerminalSessionTimestamp.string(from: run.createdAt), attributedAgents: attributedAgents)
    }
}

/// Builds the coding-agent breakdown attached to each automation run summary. Living in `workspacecore` (the
/// one module that sees the domain store, the orchestration agent rows, and the wire summaries) keeps this
/// mapping identical across every transport — the profile runs listing, the Device API runs listing, and the
/// device overview all call it, so a run's attributed agents read the same everywhere.
public enum AutomationAttributedAgents {
    /// The attributed-agent summaries for each of `runs`, keyed by run id. An attributed terminal session is
    /// surfaced as a coding agent when it has an orchestration agent row (the agent has signalled or been
    /// foreground-detected); with no row, the session's own agent-launch kind decides, so a live one reads as
    /// a row-less `idle` (an `agent`-kind run mid detection / prompt delivery) and an ended one as `exited`.
    /// The ended case is what keeps a run's retained replay reachable after the sweep or End-agents finalizes
    /// its row away: the run stays listed, so its agents stay listed with it, until retention prunes the run
    /// or the session collector reclaims the session row. A session that is not agent-launch kind — the run's
    /// own `.automation` wrapper — is not an agent and is omitted, as is one whose session row is gone.
    ///
    /// The agent rows and the persisted attributed-session rows are each batch-fetched once (the agent rows
    /// across every workspace, keyed by the terminal tracking id each attributed agent binds to) rather than
    /// queried per attributed session in a loop; liveness comes from the caller's already-loaded live-session
    /// catalog.
    public static func summariesByRunID(runs: [AutomationRun], store: SQLiteStore, liveSessions: [TerminalSessionCatalogEntry]) throws -> [String:
        [TerminalServiceAutomationAgentSummary]]
    {
        guard !runs.isEmpty else { return [:] }
        let liveSessionsByID = Dictionary(liveSessions.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        var agentRowsByTrackingID: [String: AgentWindowRecord] = [:]
        for (_, agents) in try store.agentWindowsByWorkspace() {
            for agent in agents where agent.provider == .spaces {
                if let trackingID = agent.terminalTrackingID { agentRowsByTrackingID[trackingID] = agent }
            }
        }
        let attributedSessionsByID = try store.automationAttributedSessions()

        var summariesByRunID: [String: [TerminalServiceAutomationAgentSummary]] = [:]
        for run in runs {
            let sessionIDs = (try? store.terminalSessionIDs(automationRunID: run.id)) ?? []
            var agents: [TerminalServiceAutomationAgentSummary] = []
            for sessionID in sessionIDs {
                let live = liveSessionsByID[sessionID] != nil
                if let agentRow = agentRowsByTrackingID[sessionID] {
                    agents.append(
                        TerminalServiceAutomationAgentSummary(
                            terminalSessionID: sessionID, status: agentRow.status.rawValue, live: live, title: agentRow.label,
                            workspaceID: agentRow.workspaceID))
                } else if let entry = liveSessionsByID[sessionID], entry.kind == .agent {
                    // Detection / prompt-delivery phase: a live agent-launch-kind session with no row yet.
                    // Reported as the row-less `idle` value with live == true rather than a separate status.
                    agents.append(
                        TerminalServiceAutomationAgentSummary(
                            terminalSessionID: sessionID, status: AgentWindowStatus.idle.rawValue, live: true, title: entry.name,
                            workspaceID: entry.workspaceID))
                } else if !live, let session = attributedSessionsByID[sessionID], session.kind == .agent {
                    // Ended agent whose row is finalized away: the persisted session row is all that still
                    // describes it. `exited` is the status the client renders as the ended dot.
                    agents.append(
                        TerminalServiceAutomationAgentSummary(
                            terminalSessionID: sessionID, status: AgentWindowStatus.exited.rawValue, live: false, title: session.name,
                            workspaceID: session.workspaceID))
                }
            }
            summariesByRunID[run.id] = agents
        }
        return summariesByRunID
    }
}
