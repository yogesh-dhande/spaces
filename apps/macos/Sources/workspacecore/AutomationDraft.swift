import Foundation
import spacesterminalcore

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
    /// The workspace this automation runs in. Scripts use its root as their working directory.
    public var workspaceID: String
    public var timeoutSeconds: Int?
    public var concurrencyPolicy: AutomationConcurrencyPolicy
    public var missedRunPolicy: AutomationMissedRunPolicy

    public init(
        name: String, enabled: Bool, triggerKind: AutomationTriggerKind, cronExpression: String?, kind: AutomationKind = .script, script: String,
        agentCommand: String? = nil, agentPrompt: String? = nil, workspaceID: String, timeoutSeconds: Int?,
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
        self.timeoutSeconds = timeoutSeconds
        self.concurrencyPolicy = concurrencyPolicy
        self.missedRunPolicy = missedRunPolicy
    }

    /// Returns a normalized copy after enforcing the automation authoring rules, throwing an
    /// `AutomationValidationError` for the first violation:
    /// - `name` must be non-empty after trimming.
    /// - every draft requires a workspace. Script commands run at that workspace's root.
    /// - an `agent`-kind draft requires a non-empty `agentCommand` and `agentPrompt`. The `agentCommand` must
    ///   launch a supported coding agent (`AgentSpawnCommandGate`), so an unspawnable command is rejected at
    ///   save time rather than failing every run at launch.
    /// - a positive `timeoutSeconds` when present (a non-positive budget would time a run out instantly).
    /// - a cron automation must carry a cron expression that `AutomationCronSchedule.parse` accepts.
    /// - a manual automation must not carry a cron expression (it has no schedule).
    /// The returned draft has whitespace trimmed from `name`/`workspaceID` and its cron expression
    /// normalized to nil for a manual automation, so the persisted row is canonical regardless of caller.
    /// The fields that do not belong to the resolved `kind` are normalized away: `script` is cleared for
    /// agent drafts, and agent command/prompt are cleared for script drafts. The persisted row therefore
    /// never carries stale values from a kind switch.
    public func validated() throws -> AutomationDraft {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AutomationValidationError("Automation name must not be empty.") }
        if let timeoutSeconds, timeoutSeconds <= 0 { throw AutomationValidationError("Automation timeout must be greater than zero seconds.") }

        let resolvedScript: String
        let resolvedAgentCommand: String?
        let resolvedAgentPrompt: String?
        let resolvedWorkspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedWorkspaceID.isEmpty else { throw AutomationValidationError("An automation requires a workspace.") }
        switch kind {
        case .script:
            // The script runs verbatim in a shell, so only its emptiness is checked; interior whitespace is
            // meaningful and preserved.
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutomationValidationError("Automation script must not be empty.")
            }
            resolvedScript = script
            resolvedAgentCommand = nil
            resolvedAgentPrompt = nil
        case .agent:
            guard let agentCommand, !agentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutomationValidationError("An agent automation requires an agent command.")
            }
            // Reject a command that does not launch a supported coding agent at save time, so a typo
            // (e.g. `bash`) is caught here rather than failing every run at launch. This is the same gate
            // the executor applies before spawning; surfacing it as an `AutomationValidationError` keeps a
            // rejection uniform with the other authoring errors the create/update boundary relays.
            do { _ = try AgentSpawnCommandGate.resolveSpawnableAgent(command: agentCommand) } catch {
                throw AutomationValidationError(error.localizedDescription)
            }
            guard let agentPrompt, !agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutomationValidationError("An agent automation requires a prompt.")
            }
            resolvedScript = ""
            resolvedAgentCommand = agentCommand
            resolvedAgentPrompt = agentPrompt
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
            agentCommand: resolvedAgentCommand, agentPrompt: resolvedAgentPrompt, workspaceID: resolvedWorkspaceID, timeoutSeconds: timeoutSeconds,
            concurrencyPolicy: concurrencyPolicy, missedRunPolicy: missedRunPolicy)
    }
}
