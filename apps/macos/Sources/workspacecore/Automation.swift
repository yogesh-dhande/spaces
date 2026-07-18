import Foundation

/// How a scheduled automation is triggered. A `manual` automation only runs when explicitly triggered;
/// a `cron` automation carries a `cronExpression` and fires on the schedule the daemon maintains.
public enum AutomationTriggerKind: String, Codable, Sendable, CaseIterable {
    case manual
    case cron
}

/// What happens when a fire lands while an earlier run of the same automation is still queued or running.
/// `allow` always starts a new run; `skip` records a lightweight skipped row instead; `queue` coalesces to
/// at most one pending queued run that executes when the current one finishes.
public enum AutomationConcurrencyPolicy: String, Codable, Sendable, CaseIterable {
    case allow
    case skip
    case queue
}

/// What a restarted daemon does with a cron automation whose `nextFireTime` elapsed while it was down.
/// `runOnce` fires exactly one catch-up run regardless of how many occurrences were missed; `skip` records
/// one lightweight skipped row. Either way the automation's next fire time is recomputed from now.
public enum AutomationMissedRunPolicy: String, Codable, Sendable, CaseIterable {
    case runOnce = "run_once"
    case skip
}

/// A daemon-owned scheduled automation that runs a shell command in a workspace-less terminal session.
public struct Automation: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let triggerKind: AutomationTriggerKind
    /// The 5-field cron string for a `cron` automation, or nil for a `manual` one.
    public let cronExpression: String?
    public let command: String
    public let workingDirectory: String
    /// Optional wall-clock budget after which a running run is terminated and recorded `timed_out`.
    public let timeoutSeconds: Int?
    public let concurrencyPolicy: AutomationConcurrencyPolicy
    public let missedRunPolicy: AutomationMissedRunPolicy
    /// The persisted next-due epoch for a cron automation; nil for a manual one or before it is computed.
    public let nextFireTime: Date?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String, name: String, enabled: Bool, triggerKind: AutomationTriggerKind, cronExpression: String?, command: String,
        workingDirectory: String, timeoutSeconds: Int?, concurrencyPolicy: AutomationConcurrencyPolicy, missedRunPolicy: AutomationMissedRunPolicy,
        nextFireTime: Date?, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.triggerKind = triggerKind
        self.cronExpression = cronExpression
        self.command = command
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.concurrencyPolicy = concurrencyPolicy
        self.missedRunPolicy = missedRunPolicy
        self.nextFireTime = nextFireTime
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The parsed cron schedule for a cron automation, or nil for a manual one (or an unparseable
    /// expression, which is treated as unschedulable rather than crashing the scheduler tick).
    public var parsedCronSchedule: AutomationCronSchedule? {
        guard triggerKind == .cron, let cronExpression, !cronExpression.isEmpty else { return nil }
        return try? AutomationCronSchedule.parse(cronExpression)
    }
}
