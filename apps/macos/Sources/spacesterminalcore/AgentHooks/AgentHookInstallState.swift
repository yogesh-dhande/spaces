import Foundation

/// How completely one coding agent's config carries the hooks this Spaces build wants.
///
/// `outdated` exists so a Spaces release that changes the hook shape — a new lifecycle event binding,
/// a different command, a rewritten plugin — can tell that the hooks present were written by an older
/// build and offer to update them. Without it, hooks installed once would never be corrected.
public enum AgentHookInstallState: String, Sendable, Equatable, Codable {
    /// No Spaces-owned hook entry exists for this agent.
    case notInstalled
    /// Spaces-owned entries exist, but they are not what this build writes: an older
    /// `AgentHookCommand.hookVersion`, a bound event with no entry, or (for Codex) hooks the agent's
    /// own config has not enabled. Reinstalling brings them current.
    case outdated
    /// Every bound event carries a current-version Spaces entry, and the agent will run them.
    case current
}
