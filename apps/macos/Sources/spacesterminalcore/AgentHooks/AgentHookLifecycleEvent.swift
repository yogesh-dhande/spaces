import Foundation

/// The lifecycle signals a coding agent reports to Spaces through `spaces agent signal`.
/// Each supported agent maps its own hook events onto these signals (see the per-agent writers).
public enum AgentHookLifecycleEvent: String, CaseIterable, Sendable {
    /// Session started; identify and attach the terminal.
    case initialize = "init"
    /// Agent is working on the user's request.
    case working
    /// Agent is blocked waiting on the user (permission or input).
    case blocked
    /// Agent finished a turn.
    case done
    /// Session ended.
    case exit
}
