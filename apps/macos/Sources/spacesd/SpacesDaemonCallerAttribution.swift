import Foundation
import spacesterminalcore

/// Enforces, before any profile command runs, that a request which took its terminal from the caller's
/// environment really comes from a process inside that terminal (see `CallerTerminalCheck`).
///
/// It is the single gate at the top of the daemon's dispatch rather than a check in each handler, so the
/// verdict is reached while the request is in flight and ahead of any work a handler enqueues before it
/// replies. Commands that name their terminal explicitly carry no caller pid and pass through.
enum SpacesDaemonCallerAttribution {
    /// The reply that ends the request early, or nil when the command should run.
    ///
    /// - A hook signal from outside is dropped with an ok reply, like a hook in a non-Spaces terminal, so
    ///   the agent's hook stays quiet and nothing is recorded.
    /// - Draining held notifications from outside returns none and consumes none: the tool call it rides
    ///   on succeeded, and the real owner of those notifications must still get them.
    /// - Every other command is refused with an error naming the cause.
    ///
    /// A spawn's automation run id comes from the environment, so it is only a claim too. It is accepted
    /// only for the verified caller terminal, and only when `terminalBelongsToAutomationRun(terminalID,
    /// runID)` says that terminal is the run's original terminal or carries the run's stamp. A child
    /// terminal the run spawned has its own process tree outside the original terminal's, so ancestry
    /// under the original terminal is not the test. A run id with no caller terminal to verify is refused.
    static func earlyResponse(
        for command: TerminalServiceProfileCommand, check: CallerTerminalCheck,
        terminalBelongsToAutomationRun: (_ terminalSessionID: String, _ runID: String) -> Bool
    ) -> TerminalServiceResponse? {
        switch command {
        case .agentSignal(let payload):
            guard !check.permits(sessionID: payload.terminalSessionID, callerProcessID: payload.callerProcessID) else { return nil }
            return profileReply("Ignored agent signal from a process outside terminal \(payload.terminalSessionID).")
        case .agentConsumePendingEvents(let target):
            guard !check.permits(sessionID: target.sessionID, callerProcessID: target.callerProcessID) else { return nil }
            return profileReply("No pending agent events.")
        case .agentList(let payload): return refusal(check, sessionID: payload.sessionID, callerProcessID: payload.callerProcessID)
        case .agentBriefWrite(let payload): return refusal(check, sessionID: payload.sessionID, callerProcessID: payload.callerProcessID)
        case .agentBriefRead(let target), .agentBriefClear(let target):
            return refusal(check, sessionID: target.sessionID, callerProcessID: target.callerProcessID)
        case .agentSubscribe(let payload), .agentUnsubscribe(let payload):
            return refusal(check, sessionID: payload.subscriberTerminalSessionID, callerProcessID: payload.callerProcessID)
        case .agentSpawn(let payload):
            if let refused = refusal(check, sessionID: payload.callerTerminalSessionID, callerProcessID: payload.callerProcessID) { return refused }
            guard let runID = payload.automationRunID else { return nil }
            guard let terminalID = payload.callerTerminalSessionID, terminalBelongsToAutomationRun(terminalID, runID) else {
                return TerminalServiceResponse(ok: false, message: CallerOutsideTerminalError().errorDescription ?? "", errorCode: .invalidArgument)
            }
            return nil
        default: return nil
        }
    }

    /// An ok reply shaped like the handlers' own: `sendProfileCommand` throws on an ok reply with no
    /// `profile`, which would fail the MCP tool call these no-ops ride on. Both commands' normal replies
    /// carry a message-only profile when they have nothing to report (an ignored signal, an empty drain).
    private static func profileReply(_ message: String) -> TerminalServiceResponse {
        let profile = TerminalServiceProfileCommandResponse(message: message)
        return TerminalServiceResponse(ok: true, message: message, sessions: profile.terminalSessions, profile: profile)
    }

    private static func refusal(_ check: CallerTerminalCheck, sessionID: String?, callerProcessID: Int32?) -> TerminalServiceResponse? {
        guard let sessionID, !check.permits(sessionID: sessionID, callerProcessID: callerProcessID) else { return nil }
        return TerminalServiceResponse(ok: false, message: CallerOutsideTerminalError().errorDescription ?? "", errorCode: .invalidArgument)
    }
}
