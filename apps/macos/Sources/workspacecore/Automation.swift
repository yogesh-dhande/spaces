import Foundation
import spacesdevicecore

// `AutomationTriggerKind`, `AutomationKind`, `AutomationConcurrencyPolicy`, and `AutomationMissedRunPolicy`
// live in spacesdevicecore (Foundation-only, no workspacecore dependency) so iOS can import them without
// pulling in workspacecore. These re-exports keep every existing workspacecore/spacesd/spacesdeviceapi/
// spacescli call site compiling unchanged.
public typealias AutomationTriggerKind = spacesdevicecore.AutomationTriggerKind
public typealias AutomationKind = spacesdevicecore.AutomationKind
public typealias AutomationConcurrencyPolicy = spacesdevicecore.AutomationConcurrencyPolicy
public typealias AutomationMissedRunPolicy = spacesdevicecore.AutomationMissedRunPolicy

/// A daemon-owned scheduled automation that runs in a selected workspace.
public struct Automation: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let triggerKind: AutomationTriggerKind
    /// The 5-field cron string for a `cron` automation, or nil for a `manual` one.
    public let cronExpression: String?
    public let kind: AutomationKind
    /// The shell script a `script`-kind automation runs. Ignored (and empty) for an `agent`-kind automation.
    public let script: String
    /// The shell command that launches the coding agent, for an `agent`-kind automation; nil for `script`.
    public let agentCommand: String?
    /// The prompt seeded into the spawned coding agent, for an `agent`-kind automation; nil for `script`.
    public let agentPrompt: String?
    /// The workspace this automation runs in. Scripts use its root as their working directory.
    public let workspaceID: String
    /// Optional wall-clock budget after which a running run is terminated and recorded `timed_out`.
    public let timeoutSeconds: Int?
    public let concurrencyPolicy: AutomationConcurrencyPolicy
    public let missedRunPolicy: AutomationMissedRunPolicy
    /// The persisted next-due epoch for a cron automation; nil for a manual one or before it is computed.
    public let nextFireTime: Date?
    /// The device time zone in which `nextFireTime` was computed. Persisted with the anchor so startup can
    /// reinterpret that same wall-clock occurrence if the device moved while the daemon was stopped.
    public let anchorTimeZoneIdentifier: String?
    /// A user-chosen one-time instant that replaces this automation's next run. It survives daemon restarts
    /// and time-zone recomputation, is cleared when it fires (after which a cron automation resumes from its
    /// expression) and by an explicit edit of the automation.
    public let nextFireOverride: Date?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String, name: String, enabled: Bool, triggerKind: AutomationTriggerKind, cronExpression: String?, kind: AutomationKind = .script,
        script: String, agentCommand: String? = nil, agentPrompt: String? = nil, workspaceID: String, timeoutSeconds: Int?,
        concurrencyPolicy: AutomationConcurrencyPolicy, missedRunPolicy: AutomationMissedRunPolicy, nextFireTime: Date?, createdAt: Date,
        updatedAt: Date, anchorTimeZoneIdentifier: String? = nil, nextFireOverride: Date? = nil
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
        self.timeoutSeconds = timeoutSeconds
        self.concurrencyPolicy = concurrencyPolicy
        self.missedRunPolicy = missedRunPolicy
        self.nextFireTime = nextFireTime
        self.anchorTimeZoneIdentifier = anchorTimeZoneIdentifier
        self.nextFireOverride = nextFireOverride
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The parsed cron schedule for a cron automation, or nil for a manual one (or an unparseable
    /// expression, which is treated as unschedulable rather than crashing the scheduler tick).
    public var parsedCronSchedule: AutomationCronSchedule? {
        guard triggerKind == .cron, let cronExpression, !cronExpression.isEmpty else { return nil }
        return try? AutomationCronSchedule.parse(cronExpression)
    }

    /// The instant the clients render as "Next run": a pending one-time override outranks the cron anchor,
    /// because while an override stands it is the only occurrence that fires.
    public var effectiveNextFireTime: Date? { nextFireOverride ?? nextFireTime }
}
