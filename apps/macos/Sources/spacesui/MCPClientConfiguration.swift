import Foundation
import spacesterminalcore

/// Builds the copyable MCP client configuration shown in Settings → MCP.
///
/// Spaces exposes its MCP server over stdio: an MCP client (Claude Code, Codex,
/// opencode, Copilot, pi) spawns `spaces mcp`, which forwards every tool call to the running
/// `spacesd` daemon. The settings pane only needs to surface the resolved CLI
/// path and the snippets a user pastes into their client.
enum MCPClientConfiguration {
    static let serverName = "spaces"

    /// Resolves the path to display for the `spaces` CLI. Candidates are tried in
    /// order and the first existing executable wins; the helper path is also the
    /// fallback so the snippet stays copyable before the CLI is installed.
    static func resolvedCLIPath(
        fileManager: FileManager = .default, bundleResourceCLIPath: String? = defaultBundleResourceCLIPath(),
        homeDirectoryPath: String = NSHomeDirectory()
    ) -> String {
        let helperPath =
            SpacesBinaryLayout.userHelperLinkURL(for: .spaces, homeDirectoryURL: URL(fileURLWithPath: homeDirectoryPath, isDirectory: true))?.path
            ?? "\(homeDirectoryPath)/.spaces/bin/spaces"
        var candidates = [helperPath]
        if let bundleResourceCLIPath { candidates.append(bundleResourceCLIPath) }
        candidates.append(SpacesBinaryLayout.systemLinkURL(for: .spaces).path)
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) ?? helperPath
    }

    /// One-shot command that registers the stdio server with Claude Code at user scope so the tools are
    /// available in every directory rather than only the one the command ran in.
    static func claudeCodeAddCommand(cliPath: String) -> String { "claude mcp add \(serverName) -s user -- \(shellWord(cliPath)) mcp" }

    /// `path` as one shell word for a command the user pastes into a terminal. A path made only of
    /// characters the shell reads literally is left bare so the common snippet stays readable; any other
    /// (an app bundle path with a space, say) is single-quoted, or the shell would split it and the agent
    /// would register the wrong executable.
    static func shellWord(_ path: String) -> String {
        let literal = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%:,=")
        guard !path.isEmpty, path.unicodeScalars.allSatisfy(literal.contains) else {
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return path
    }

    /// `mcp_servers` table for the Codex CLI `~/.codex/config.toml`. Codex passes an MCP server only the
    /// variables named in `env_vars`, which is how the server learns which terminal is calling.
    static func codexConfigTOML(cliPath: String) -> String {
        """
        [mcp_servers.\(serverName)]
        command = "\(cliPath)"
        args = ["mcp"]
        env_vars = [\(AgentHookCodexMCPEntry.requiredEnvVars.map { "\"\($0)\"" }.joined(separator: ", "))]
        """
    }

    /// The `mcp.spaces` entry to merge into opencode's user config
    /// (`~/.config/opencode/opencode.json`). opencode models a local stdio server as
    /// `type: "local"` with `command` as an argv array; `enabled` opts the server in.
    static func opencodeConfigJSON(cliPath: String) -> String {
        """
        {
          "mcp": {
            "\(serverName)": {
              "type": "local",
              "command": ["\(cliPath)", "mcp"],
              "enabled": true
            }
          }
        }
        """
    }

    /// `copilot mcp add` registers the server for the Copilot CLI. The command writes the
    /// `mcpServers.spaces` entry into `~/.copilot/mcp-config.json` (a `type: "local"` server with
    /// `command`, `args` and `tools: ["*"]`, verified against copilot 1.0.95). Copilot passes the calling
    /// terminal's environment to MCP servers, so unlike Codex the entry names no variables (verified live:
    /// a Copilot session's `spaces_agent_brief_write` call wrote the brief of the terminal it ran in).
    static func copilotAddCommand(cliPath: String) -> String { "copilot mcp add \(serverName) -- \(shellWord(cliPath)) mcp" }

    /// `pi mcp add` registers the server for pi, writing it into `~/.pi/agent/mcp.json`. pi passes the
    /// launching terminal's environment to stdio MCP servers (verified live against pi 1.1.0), so like
    /// Copilot and unlike Codex the entry names no variables.
    static func piAddCommand(cliPath: String) -> String { "pi mcp add \(serverName) -- \(shellWord(cliPath)) mcp" }

    /// The CLI bundled at `Contents/Resources/spaces` when running from an app
    /// bundle; `nil` for non-bundled (test/dev tooling) executables.
    static func defaultBundleResourceCLIPath() -> String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(serverName)").path
    }
}

/// MCP-client presentation for the tabs shown in Settings → MCP. Each `CodingAgent` this app
/// integrates with is also an MCP client that can be configured to launch `spaces mcp`, so the
/// picker is driven by the shared `CodingAgent` registry rather than a second enum.
extension CodingAgent {
    /// Tab title in the MCP client picker. Deliberately distinct from `displayName` for `.codex`
    /// ("Codex CLI" vs "Codex") because this picker is specifically about configuring the Codex
    /// CLI's MCP server list, not the agent generally.
    var mcpClientTitle: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .opencode: "opencode"
        case .copilot: "Copilot CLI"
        case .pi: "pi"
        }
    }

    var mcpConfigHint: String {
        switch self {
        case .claudeCode: "Run once in your terminal."
        case .codex: "Add to the mcp_servers table in ~/.codex/config.toml."
        case .opencode: "Add to the mcp block in ~/.config/opencode/opencode.json."
        case .copilot, .pi: "Run once in your terminal."
        }
    }

    func mcpConfigSnippet(cliPath: String) -> String {
        switch self {
        case .claudeCode: MCPClientConfiguration.claudeCodeAddCommand(cliPath: cliPath)
        case .codex: MCPClientConfiguration.codexConfigTOML(cliPath: cliPath)
        case .opencode: MCPClientConfiguration.opencodeConfigJSON(cliPath: cliPath)
        case .copilot: MCPClientConfiguration.copilotAddCommand(cliPath: cliPath)
        case .pi: MCPClientConfiguration.piAddCommand(cliPath: cliPath)
        }
    }
}
