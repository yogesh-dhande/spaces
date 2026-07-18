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
            cronExpression: automation.cronExpression, command: automation.command, workingDirectory: automation.workingDirectory,
            timeoutSeconds: automation.timeoutSeconds, concurrencyPolicy: automation.concurrencyPolicy.rawValue,
            missedRunPolicy: automation.missedRunPolicy.rawValue,
            nextFireTime: automation.nextFireTime.map(TerminalSessionTimestamp.string(from:)),
            createdAt: TerminalSessionTimestamp.string(from: automation.createdAt),
            updatedAt: TerminalSessionTimestamp.string(from: automation.updatedAt))
    }
}

extension TerminalServiceAutomationRunSummary {
    /// `automationName` is denormalized in by the caller (from the run's automation lookup, when it still
    /// exists); `liveAttributedSessionCount` is the number of the run's stamped terminal sessions currently
    /// live, which the caller computes from the live-session set.
    public init(_ run: AutomationRun, automationName: String?, liveAttributedSessionCount: Int) {
        self.init(
            id: run.id, automationID: run.automationID, automationName: automationName, status: run.status.rawValue, trigger: run.trigger.rawValue,
            skipReason: run.skipReason?.rawValue, exitCode: run.exitCode, terminalSessionID: run.terminalSessionID,
            startedAt: run.startedAt.map(TerminalSessionTimestamp.string(from:)),
            endedAt: run.endedAt.map(TerminalSessionTimestamp.string(from:)),
            createdAt: TerminalSessionTimestamp.string(from: run.createdAt), liveAttributedSessionCount: liveAttributedSessionCount)
    }
}
