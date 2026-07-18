import Foundation

/// Raised when an automation's editable fields fail validation at the create/update boundary. Carries a
/// human-readable explanation so the boundary that rejected the draft (a profile command or a Device API
/// handler) can relay exactly what was wrong.
public struct AutomationValidationError: LocalizedError, Equatable {
    private let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The editable fields of an automation, decoupled from the persisted `Automation` (which also carries the
/// server-owned id, timestamps, and scheduler-owned next-fire time). Both create and update take a draft,
/// so the single validation and persistence path in `AutomationService` is shared across every transport.
public struct AutomationDraft: Sendable, Equatable {
    public var name: String
    public var enabled: Bool
    public var triggerKind: AutomationTriggerKind
    public var cronExpression: String?
    public var command: String
    public var workingDirectory: String
    public var timeoutSeconds: Int?
    public var concurrencyPolicy: AutomationConcurrencyPolicy
    public var missedRunPolicy: AutomationMissedRunPolicy

    public init(
        name: String, enabled: Bool, triggerKind: AutomationTriggerKind, cronExpression: String?, command: String, workingDirectory: String,
        timeoutSeconds: Int?, concurrencyPolicy: AutomationConcurrencyPolicy, missedRunPolicy: AutomationMissedRunPolicy
    ) {
        self.name = name
        self.enabled = enabled
        self.triggerKind = triggerKind
        self.cronExpression = cronExpression
        self.command = command
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.concurrencyPolicy = concurrencyPolicy
        self.missedRunPolicy = missedRunPolicy
    }

    /// Returns a normalized copy after enforcing the automation authoring rules, throwing an
    /// `AutomationValidationError` for the first violation:
    /// - `name`, `command`, and `workingDirectory` must be non-empty after trimming.
    /// - a positive `timeoutSeconds` when present (a non-positive budget would time a run out instantly).
    /// - a cron automation must carry a cron expression that `AutomationCronSchedule.parse` accepts.
    /// - a manual automation must not carry a cron expression (it has no schedule).
    /// The returned draft has whitespace trimmed from `name`/`workingDirectory` and its cron expression
    /// normalized to nil for a manual automation, so the persisted row is canonical regardless of caller.
    public func validated() throws -> AutomationDraft {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AutomationValidationError("Automation name must not be empty.") }
        // The command runs verbatim in a shell, so only its emptiness is checked; interior whitespace is
        // meaningful and preserved.
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationValidationError("Automation command must not be empty.")
        }
        let trimmedWorkingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWorkingDirectory.isEmpty else { throw AutomationValidationError("Automation working directory must not be empty.") }
        if let timeoutSeconds, timeoutSeconds <= 0 { throw AutomationValidationError("Automation timeout must be greater than zero seconds.") }

        let normalizedCron = cronExpression?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCron: String?
        switch triggerKind {
        case .cron:
            guard let normalizedCron, !normalizedCron.isEmpty else {
                throw AutomationValidationError("A cron automation requires a cron expression.")
            }
            _ = try AutomationCronSchedule.parse(normalizedCron)
            resolvedCron = normalizedCron
        case .manual:
            guard normalizedCron == nil || normalizedCron?.isEmpty == true else {
                throw AutomationValidationError("A manual automation must not carry a cron expression.")
            }
            resolvedCron = nil
        }

        return AutomationDraft(
            name: trimmedName, enabled: enabled, triggerKind: triggerKind, cronExpression: resolvedCron, command: command,
            workingDirectory: trimmedWorkingDirectory, timeoutSeconds: timeoutSeconds, concurrencyPolicy: concurrencyPolicy,
            missedRunPolicy: missedRunPolicy)
    }
}
