import Foundation

/// The `[mcp_servers.spaces]` entry Spaces' Codex setup keeps in Codex's `config.toml`, so the Spaces
/// MCP server (`spaces mcp`) runs with the environment that identifies the calling terminal.
///
/// Codex hands an MCP server only a small default set of environment variables plus the names in that
/// server's `env_vars`. Without them the server cannot tell which terminal or automation run is calling,
/// and tools such as the agent brief cannot default to the caller.
public enum AgentHookCodexMCPEntry {
    static let serverName = "spaces"
    static let keyPath = "mcp_servers.\(serverName)"
    static let arguments = ["mcp"]

    /// Every variable `spaces mcp` reads to identify its caller. A new caller-identifying variable in the
    /// MCP server or the CLI commands it shares belongs here. The names are `WorkspaceOrchestrator`'s
    /// `terminalTrackingIDEnvVar` and `automationRunIDEnvVar`, spelled out because this module cannot see
    /// that type.
    public static let requiredEnvVars = ["SPACES_TERMINAL_TRACKING_ID", "SPACES_AUTOMATION_RUN_ID"]

    /// The entry as `config/read` reports it, or nil when Codex has no `spaces` server.
    typealias Existing = [String: Any]

    /// `env_vars` after setup: the user's own names first, in their order, then each required name that is
    /// not already there. Elements that are not plain names are kept untouched, since Codex may accept
    /// richer entries and `env_vars` is replaced as a whole by the write.
    static func envVars(existing: Existing?) -> [Any] {
        var merged: [Any] = (existing?["env_vars"] as? [Any]) ?? []
        let present = Set(merged.compactMap { $0 as? String })
        for name in requiredEnvVars where !present.contains(name) { merged.append(name) }
        return merged
    }

    /// The fields setup writes. `upsert` merges them into the existing table, so `startup_timeout_sec`,
    /// `env`, tool subtables and comments the user keeps there are left as they are.
    static func value(spacesExecutablePath: String, existing: Existing?) -> [String: Any] {
        ["command": spacesExecutablePath, "args": arguments, "env_vars": envVars(existing: existing)]
    }

    /// Whether `existing` already carries what setup would write.
    static func isCurrent(_ existing: Existing?, spacesExecutablePath: String) -> Bool {
        guard let existing, existing["command"] as? String == spacesExecutablePath, existing["args"] as? [String] == arguments else { return false }
        let present = Set((existing["env_vars"] as? [Any])?.compactMap { $0 as? String } ?? [])
        return requiredEnvVars.allSatisfy(present.contains)
    }
}
