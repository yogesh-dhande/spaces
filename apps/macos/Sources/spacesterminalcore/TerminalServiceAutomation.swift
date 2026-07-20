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

/// Client-facing wire summary of one automation execution attempt. Carries the identity a client needs to
/// display run history and derive alert entries: the run's status, trigger origin, skip reason, exit code,
/// its command terminal session, and its timestamps. `automationName` is denormalized in so a run-centric
/// list (e.g. an alerts feed) can render without a second lookup. `liveAttributedSessionCount` is the
/// number of terminal sessions stamped with this run that are currently live — non-zero only for a running
/// or recently-ended run whose spawned coding-agent sessions have not been swept yet.
public struct TerminalServiceAutomationRunSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let automationID: String
    public let automationName: String?
    public let status: String
    public let trigger: String
    public let skipReason: String?
    public let exitCode: Int?
    public let terminalSessionID: String?
    public let startedAt: String?
    public let endedAt: String?
    public let createdAt: String
    public let liveAttributedSessionCount: Int

    public init(
        id: String, automationID: String, automationName: String?, status: String, trigger: String, skipReason: String?, exitCode: Int?,
        terminalSessionID: String?, startedAt: String?, endedAt: String?, createdAt: String, liveAttributedSessionCount: Int
    ) {
        self.id = id
        self.automationID = automationID
        self.automationName = automationName
        self.status = status
        self.trigger = trigger
        self.skipReason = skipReason
        self.exitCode = exitCode
        self.terminalSessionID = terminalSessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.liveAttributedSessionCount = liveAttributedSessionCount
    }
}
