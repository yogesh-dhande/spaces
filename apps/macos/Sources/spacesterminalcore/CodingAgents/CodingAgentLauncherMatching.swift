import Foundation

extension CodingAgent {
    /// Lowercased, alphanumeric-only tokens that identify this agent when found in a launcher's free-form
    /// name or command text (e.g. "Codex CLI", "claude code cli", "OPENCODE run"). Distinct from
    /// `executableNames`, which are exact executable basenames for PATH probing and shell-token matching.
    var launcherTokens: Set<String> {
        switch self {
        case .codex: ["codex", "codexcli"]
        case .claudeCode: ["claude", "claudecode", "claudecodecli"]
        case .opencode: ["opencode", "opencodecli"]
        }
    }

    /// Matches a launcher's display name or command against `launcherTokens` to find which known agent it
    /// launches, for tile-text rendering in the workspace agent-launchers UI. Fuzzier than
    /// `AgentSpawnCommandGate.matching(command:)`, which parses the actual executable token from a shell
    /// command line to gate `spaces agent spawn`; this instead tokenizes the whole string on
    /// non-alphanumeric characters and checks for known-agent tokens anywhere in it, since a launcher's
    /// name (not just its command) may be the only readable hint (e.g. "Codex CLI"). Returns `nil` when no
    /// known agent's tokens appear, in which case callers fall back to the launcher name's initials.
    ///
    /// Checks `.codex`, then `.claudeCode`, then `.opencode` — this fixed precedence (not `allCases`
    /// order) matches the historical behavior being ported here and only matters if a string somehow
    /// carries tokens for more than one agent at once.
    public static func matching(launcherText: String) -> CodingAgent? {
        let tokens = Set(launcherTokens(in: launcherText))
        for agent: CodingAgent in [.codex, .claudeCode, .opencode] where !tokens.isDisjoint(with: agent.launcherTokens) { return agent }
        return nil
    }

    private static func launcherTokens(in text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
