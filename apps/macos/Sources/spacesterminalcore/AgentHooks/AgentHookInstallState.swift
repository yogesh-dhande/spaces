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
    /// Codex only: entries this build wrote that the user reviewed and then switched off in Codex.
    /// Distinct from `awaitingTrust` because Codex asks for no review of a hook it was told to stop
    /// running, so the user is sent to re-enable it rather than to approve it. Reported ahead of
    /// `awaitingTrust` when both apply, since a hook that is switched off stays switched off however
    /// the review goes.
    case disabledByAgent
    /// Codex only: every bound event carries a current-version Spaces entry and the `hooks` feature is
    /// on, but Codex has not been told to trust those entries, so it runs none of them. Reinstalling
    /// cannot fix it, because rewriting the file is what puts Codex back into review, so this is the
    /// one state whose remedy belongs to the agent rather than to Spaces.
    case awaitingTrust
    /// Every bound event carries a current-version Spaces entry, and the agent will run them.
    case current
}
