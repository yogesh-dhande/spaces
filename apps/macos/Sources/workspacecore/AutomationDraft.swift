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
    public var kind: AutomationKind
    /// The shell script a `script`-kind automation runs. Ignored for an `agent`-kind draft.
    public var script: String
    /// The shell command that launches the coding agent, for an `agent`-kind draft.
    public var agentCommand: String?
    /// The prompt seeded into the spawned coding agent, for an `agent`-kind draft.
    public var agentPrompt: String?
    /// The workspace an `agent`-kind automation's coding agent spawns into.
    public var workspaceID: String?
    /// The directory a `script`-kind draft's script runs in. Ignored for an `agent`-kind draft, which has
    /// no working directory of its own — its coding agent's location comes from `workspaceID`.
    public var workingDirectory: String
    public var timeoutSeconds: Int?
    public var concurrencyPolicy: AutomationConcurrencyPolicy
    public var missedRunPolicy: AutomationMissedRunPolicy

    public init(
        name: String, enabled: Bool, triggerKind: AutomationTriggerKind, cronExpression: String?, kind: AutomationKind = .script, script: String,
        agentCommand: String? = nil, agentPrompt: String? = nil, workspaceID: String? = nil, workingDirectory: String, timeoutSeconds: Int?,
        concurrencyPolicy: AutomationConcurrencyPolicy, missedRunPolicy: AutomationMissedRunPolicy
    ) {
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
    }

    /// Returns a normalized copy after enforcing the automation authoring rules, throwing an
    /// `AutomationValidationError` for the first violation:
    /// - `name` must be non-empty after trimming.
    /// - a `script`-kind draft requires a non-empty `script` and a non-empty `workingDirectory` (the
    ///   directory its script runs in).
    /// - an `agent`-kind draft requires a non-empty `agentCommand`, `agentPrompt`, and `workspaceID` instead;
    ///   it has no `workingDirectory` of its own — the coding agent's location comes from `workspaceID` — so
    ///   none is required (the editor has no cwd field for this kind; see commit 11).
    /// - a positive `timeoutSeconds` when present (a non-positive budget would time a run out instantly).
    /// - a cron automation must carry a cron expression that `AutomationCronSchedule.parse` accepts.
    /// - a manual automation must not carry a cron expression (it has no schedule).
    /// The returned draft has whitespace trimmed from `name`/`workingDirectory` and its cron expression
    /// normalized to nil for a manual automation, so the persisted row is canonical regardless of caller.
    /// The fields that don't belong to the resolved `kind` are normalized away (`script` and
    /// `workingDirectory` cleared for `agent`, the agent fields cleared for `script`) so the persisted row
    /// never carries stale values from a kind switch.
    public func validated() throws -> AutomationDraft {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AutomationValidationError("Automation name must not be empty.") }
        if let timeoutSeconds, timeoutSeconds <= 0 { throw AutomationValidationError("Automation timeout must be greater than zero seconds.") }

        let resolvedScript: String
        let resolvedAgentCommand: String?
        let resolvedAgentPrompt: String?
        let resolvedWorkspaceID: String?
        let resolvedWorkingDirectory: String
        switch kind {
        case .script:
            // The script runs verbatim in a shell, so only its emptiness is checked; interior whitespace is
            // meaningful and preserved.
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutomationValidationError("Automation script must not be empty.")
            }
            let trimmedWorkingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedWorkingDirectory.isEmpty else { throw AutomationValidationError("Automation working directory must not be empty.") }
            resolvedScript = script
            resolvedAgentCommand = nil
            resolvedAgentPrompt = nil
            resolvedWorkspaceID = nil
            resolvedWorkingDirectory = trimmedWorkingDirectory
        case .agent:
            guard let agentCommand, !agentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutomationValidationError("An agent automation requires an agent command.")
            }
            guard let agentPrompt, !agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutomationValidationError("An agent automation requires a prompt.")
            }
            guard let workspaceID, !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutomationValidationError("An agent automation requires a workspace.")
            }
            resolvedScript = ""
            resolvedAgentCommand = agentCommand
            resolvedAgentPrompt = agentPrompt
            resolvedWorkspaceID = workspaceID
            resolvedWorkingDirectory = ""
        }

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
            name: trimmedName, enabled: enabled, triggerKind: triggerKind, cronExpression: resolvedCron, kind: kind, script: resolvedScript,
            agentCommand: resolvedAgentCommand, agentPrompt: resolvedAgentPrompt, workspaceID: resolvedWorkspaceID,
            workingDirectory: resolvedWorkingDirectory, timeoutSeconds: timeoutSeconds, concurrencyPolicy: concurrencyPolicy,
            missedRunPolicy: missedRunPolicy)
    }
}
