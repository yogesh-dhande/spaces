import Foundation
import spacesdevicecore

// `AutomationRunStatus` lives in spacesdevicecore (Foundation-only, no workspacecore dependency) so iOS
// can import it without pulling in workspacecore. This re-export keeps every existing workspacecore/
// spacesd/spacesdeviceapi/spacescli call site compiling unchanged.
public typealias AutomationRunStatus = spacesdevicecore.AutomationRunStatus

/// Why a `skipped` run never ran.
public enum AutomationRunSkipReason: String, Codable, Sendable, CaseIterable {
    /// A concurrency policy blocked an overlapping run.
    case concurrency
    /// A missed cron occurrence was skipped on daemon start (missed-run policy `skip`).
    case missed
}

/// How a run was initiated. Mirrors `AutomationTriggerKind` for cron/manual fires, adds the `missedCatchUp`
/// origin a restarted daemon records when it fires a single catch-up run, and `scheduled` for a fire from a
/// user-set one-time next-run override (of either a cron or a manual automation).
public enum AutomationRunTrigger: String, Codable, Sendable, CaseIterable {
    case manual
    case cron
    case missedCatchUp = "missed_catch_up"
    case scheduled
}

/// One row per automation execution attempt.
public struct AutomationRun: Equatable, Sendable, Identifiable {
    public let id: String
    public let automationID: String
    /// The automation's `script`/`agent` kind stamped onto the run at creation time. An automation's kind can
    /// be edited once its runs are terminal, so a retained historical run keeps the session shape it actually
    /// ran with. Opening a run's history dispatches on this, not on the automation's current kind, so a run
    /// whose automation later switched kind still cold-resolves with the right workspace/kind/command.
    public let kind: AutomationKind
    public let status: AutomationRunStatus
    public let skipReason: AutomationRunSkipReason?
    public let trigger: AutomationRunTrigger
    public let exitCode: Int?
    /// The workspace-bound terminal session that carried the command, or nil for a queued/skipped run.
    public let terminalSessionID: String?
    public let startedAt: Date?
    public let endedAt: Date?
    public let createdAt: Date
    /// When an `agent`-kind run's seed prompt was taken by the agent — written to its session and observably
    /// being worked on (see `AutomationAgentPromptDelivery`) — or nil if not yet delivered (or a
    /// `script`-kind run, which has no prompt). This is the agent-run phase marker: NULL means the run is
    /// still detecting the agent / delivering the prompt, set means it is awaiting the agent's done signal or
    /// session end. Persisting it (rather than holding it in memory) is what lets a daemon restart resume
    /// the correct phase instead of re-sending a prompt the agent already took.
    public let promptDeliveredAt: Date?

    public init(
        id: String, automationID: String, kind: AutomationKind, status: AutomationRunStatus, skipReason: AutomationRunSkipReason?,
        trigger: AutomationRunTrigger, exitCode: Int?, terminalSessionID: String?, startedAt: Date?, endedAt: Date?, createdAt: Date,
        promptDeliveredAt: Date? = nil
    ) {
        self.id = id
        self.automationID = automationID
        self.kind = kind
        self.status = status
        self.skipReason = skipReason
        self.trigger = trigger
        self.exitCode = exitCode
        self.terminalSessionID = terminalSessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.promptDeliveredAt = promptDeliveredAt
    }
}
