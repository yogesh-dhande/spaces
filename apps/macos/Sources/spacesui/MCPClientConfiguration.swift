import Foundation
import spacesterminalcore

/// Builds the copyable MCP client configuration shown in Settings → MCP.
///
/// Spaces exposes its MCP server over stdio: an MCP client (Claude Code, Codex,
/// opencode) spawns `spaces mcp`, which forwards every tool call to the running
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
    static func claudeCodeAddCommand(cliPath: String) -> String { "claude mcp add \(serverName) -s user -- \(cliPath) mcp" }

    /// `mcp_servers` table for the Codex CLI `~/.codex/config.toml`.
    static func codexConfigTOML(cliPath: String) -> String {
        """
        [mcp_servers.\(serverName)]
        command = "\(cliPath)"
        args = ["mcp"]
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

    /// The CLI bundled at `Contents/Resources/spaces` when running from an app
    /// bundle; `nil` for non-bundled (test/dev tooling) executables.
    static func defaultBundleResourceCLIPath() -> String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(serverName)").path
    }
}

/// MCP clients shown as tabs in Settings → MCP, each with its own snippet format.
enum MCPClient: CaseIterable, Equatable {
    case claudeCode
    case codexCLI
    case opencode

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codexCLI: "Codex CLI"
        case .opencode: "opencode"
        }
    }

    var configHint: String {
        switch self {
        case .claudeCode: "Run once in your terminal."
        case .codexCLI: "Add to the mcp_servers table in ~/.codex/config.toml."
        case .opencode: "Add to the mcp block in ~/.config/opencode/opencode.json."
        }
    }

    func configSnippet(cliPath: String) -> String {
        switch self {
        case .claudeCode: MCPClientConfiguration.claudeCodeAddCommand(cliPath: cliPath)
        case .codexCLI: MCPClientConfiguration.codexConfigTOML(cliPath: cliPath)
        case .opencode: MCPClientConfiguration.opencodeConfigJSON(cliPath: cliPath)
        }
    }
}
