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
    /// `AgentHookCommand.hookVersion`, a bound event with no entry, or, for Codex, an entry naming a
    /// `spaces` other than the one this device resolves or hooks the agent's own config has not enabled.
    /// Reinstalling brings them current.
    case outdated
    /// Codex only: entries this build wrote that the user switched off in Codex. Codex runs no hook it
    /// was told to stop running, whatever its trust says, and Spaces never switches one back on, so the
    /// user is sent to Codex to turn it on again. Reported ahead of `awaitingTrust` when both apply,
    /// since a hook that is switched off stays switched off however the trust goes.
    case disabledByAgent
    /// Codex only: every bound event carries this build's exact Spaces entry and the `hooks` feature is
    /// on, but Codex has not trusted those entries at their current text, so it runs none of them.
    /// Reinstalling cannot fix it; trusting can, which the user does from Spaces (recorded through Codex
    /// itself) or inside Codex.
    case awaitingTrust
    /// Every bound event carries a current-version Spaces entry, and the agent will run them.
    case current
}
