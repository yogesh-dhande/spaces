import Foundation

/// What a terminal's OSC 7501 reports mean for the coding agent running in it, handed to the daemon
/// that owns agent rows.
public enum TerminalProgramStatusEvent: Sendable, Equatable {
    /// The agent's status changed. `agentLabel` is the detected agent's display label, carried here
    /// because the persisted runtime state the daemon would otherwise read it from is written behind
    /// the output turn that raised the report.
    case transition(TerminalProgramStatusTransition, agentLabel: String)
    /// The agent that was reporting is gone or was replaced by another, so whatever it said no longer
    /// describes this terminal.
    case agentEnded
}

/// Receives a session core's program status events on the terminal engine actor. The session id
/// travels with each event so one handler serves every core.
public typealias TerminalProgramStatusHandler = @TerminalEngineActor (_ sessionID: String, _ event: TerminalProgramStatusEvent) -> Void

/// A session core's OSC 7501 state: the report tracker plus the coding agent it is bound to.
///
/// Only a detected coding agent's reports count; a build script or a shell prompt that happens to send
/// OSC 7501 in a terminal with no agent is ignored outright. The binding is the foreground agent kind
/// the core already classifies for its runtime state, and any change of it, including to none, drops
/// every record: an agent's records say nothing about the next program in the terminal.
public struct TerminalProgramStatusRelay: Sendable {
    private var tracker = TerminalProgramStatusTracker()
    private var agentKind: TerminalDetectedAgentKind?
    private var agentLabel: String?

    public init() {}

    /// Records the foreground coding agent the core just classified (nil when none). Returns
    /// `.agentEnded` when a different binding replaces one that existed.
    public mutating func observeForegroundAgent(_ agent: TerminalForegroundAgentSnapshot?) -> TerminalProgramStatusEvent? {
        let kind = agent?.detectedAgentKind
        guard kind != agentKind else { return nil }
        let hadAgent = agentKind != nil
        agentKind = kind
        agentLabel = agent?.displayLabel
        tracker.reset()
        return hadAgent ? .agentEnded : nil
    }

    /// Applies one report, returning the agent status change it caused. Unknown states are dropped.
    public mutating func receive(stateValue: UInt32, id: String) -> TerminalProgramStatusEvent? {
        guard let agentLabel, let state = TerminalProgramStatusState(rawValue: stateValue) else { return nil }
        guard let transition = tracker.apply(state: state, id: id) else { return nil }
        return .transition(transition, agentLabel: agentLabel)
    }
}
