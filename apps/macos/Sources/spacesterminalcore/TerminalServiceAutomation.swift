import Foundation

/// Client-facing wire summary of a scheduled automation. Shared across every transport (the profile
/// command response, the Device API result payloads, and the device overview), so the daemon maps a
/// stored automation to this one shape once and every client decodes it identically. Enum-typed fields
/// (`triggerKind`, `concurrencyPolicy`, `missedRunPolicy`) are carried as their raw string values so this
/// module needs no dependency on the `workspacecore` domain enums that define them; timestamps are
/// ISO8601 strings, matching the rest of the terminal-service wire contract.
public struct TerminalServiceAutomationSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let triggerKind: String
    /// The 5-field cron string for a cron automation, or nil for a manual one.
    public let cronExpression: String?
    /// `script` or `agent` (raw `AutomationKind` value).
    public let kind: String
    /// The shell script a `script`-kind automation runs. Empty for an `agent`-kind automation.
    public let script: String
    /// The shell command that launches the coding agent, for an `agent`-kind automation; nil for `script`.
    public let agentCommand: String?
    /// The prompt seeded into the spawned coding agent, for an `agent`-kind automation; nil for `script`.
    public let agentPrompt: String?
    /// The workspace an `agent`-kind automation's coding agent spawns into; nil for `script`.
    public let workspaceID: String?
    /// The directory a `script`-kind automation's script runs in. Empty for an `agent`-kind automation.
    public let workingDirectory: String
    /// Wall-clock budget in seconds after which a running run is terminated and recorded timed_out, or nil.
    public let timeoutSeconds: Int?
    public let concurrencyPolicy: String
    public let missedRunPolicy: String
    /// The next scheduled fire time (ISO8601) for an enabled cron automation, or nil.
    public let nextFireTime: String?
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String, name: String, enabled: Bool, triggerKind: String, cronExpression: String?, kind: String = "script", script: String,
        agentCommand: String? = nil, agentPrompt: String? = nil, workspaceID: String? = nil, workingDirectory: String, timeoutSeconds: Int?,
        concurrencyPolicy: String, missedRunPolicy: String, nextFireTime: String?, createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.triggerKind = triggerKind
        self.cronExpression = cronExpression
        self.kind = kind
        self.script = script
        self.agentCommand = agentCommand
        self.agentPrompt = agentPrompt
        self.workspaceID = workspaceID
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.concurrencyPolicy = concurrencyPolicy
        self.missedRunPolicy = missedRunPolicy
        self.nextFireTime = nextFireTime
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Client-facing wire summary of one coding agent a run is attributed with. An automation run's attributed
/// agents are the terminal sessions stamped with the run id that carry a coding agent: an `agent`-kind run's
/// own spawned agent session, plus any coding agent a `script`-kind run's command spawned. The run's own
/// workspace-less `.automation` wrapper session (a `script`-kind run) is stamped too but is NOT an agent, so
/// it never appears here.
///
/// `status` is the agent's raw `AgentWindowStatus` (idle/spinning/waiting/done/exited) once the agent has an
/// orchestration row. A live, agent-launched session that has not produced a row yet — the detection /
/// prompt-delivery phase of a running `agent`-kind run — is reported as `idle` (the row-less "no agent has
/// started in this terminal yet" value) with `live == true`, rather than inventing a separate
/// detection-pending status; the `live` flag distinguishes it from a settled idle agent for a client that
/// needs to. An ended agent session whose row has been finalized away is reported as `exited` with
/// `live == false`, so a retained run keeps listing the agents whose transcripts it still replays. `title` is
/// the agent row's visible label (or the session's own name when no row exists).
public struct TerminalServiceAutomationAgentSummary: Codable, Sendable, Equatable {
    /// The attributed terminal session id the coding agent runs in.
    public let terminalSessionID: String
    /// The agent's raw `AgentWindowStatus`: the row's status, or the row-less `idle`/`exited` value matching
    /// the session's liveness.
    public let status: String
    /// Whether the agent's terminal session is currently live.
    public let live: Bool
    /// The agent's visible label (row label, or the session's own name when no row exists).
    public let title: String?
    /// The workspace the agent runs in.
    public let workspaceID: String?

    public init(terminalSessionID: String, status: String, live: Bool, title: String?, workspaceID: String?) {
        self.terminalSessionID = terminalSessionID
        self.status = status
        self.live = live
        self.title = title
        self.workspaceID = workspaceID
    }
}

/// Client-facing wire summary of one automation execution attempt. Carries the identity a client needs to
/// display run history and derive alert entries: the run's status, trigger origin, skip reason, exit code,
/// its command terminal session, and its timestamps. `automationName` is denormalized in so a run-centric
/// list (e.g. an alerts feed) can render without a second lookup. `attributedAgents` is the per-agent
/// breakdown of the run's attributed sessions that carry a coding agent, each with its own status and its
/// own `live` flag (a live-agent count is derived from these; a script run's own workspace-less wrapper
/// session is never one of them).
public struct TerminalServiceAutomationRunSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let automationID: String
    public let automationName: String?
    /// The run's own `script`/`agent` kind (raw `AutomationKind` value), stamped at creation time. A client
    /// opening a run's history dispatches on this, not on the automation's current kind: an automation's kind
    /// can be edited once its runs are terminal, but a retained historical run keeps the session shape it ran
    /// with, so this is what cold-resolves the run to the right workspace/kind/command.
    public let kind: String
    public let status: String
    public let trigger: String
    public let skipReason: String?
    public let exitCode: Int?
    public let terminalSessionID: String?
    public let startedAt: String?
    public let endedAt: String?
    public let createdAt: String
    public let attributedAgents: [TerminalServiceAutomationAgentSummary]

    public init(
        id: String, automationID: String, automationName: String?, kind: String, status: String, trigger: String, skipReason: String?,
        exitCode: Int?, terminalSessionID: String?, startedAt: String?, endedAt: String?, createdAt: String,
        attributedAgents: [TerminalServiceAutomationAgentSummary] = []
    ) {
        self.id = id
        self.automationID = automationID
        self.automationName = automationName
        self.kind = kind
        self.status = status
        self.trigger = trigger
        self.skipReason = skipReason
        self.exitCode = exitCode
        self.terminalSessionID = terminalSessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.attributedAgents = attributedAgents
    }
}
