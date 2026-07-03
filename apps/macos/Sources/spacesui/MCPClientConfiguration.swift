import Foundation
import spacesterminalcore

/// Builds the copyable MCP client configuration shown in Settings → MCP.
///
/// Spaces exposes its MCP server over stdio: an MCP client (Claude Code, Claude
/// Desktop) spawns `spaces mcp`, which forwards every tool call to the running
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

    /// One-shot command that registers the stdio server with Claude Code.
    static func claudeCodeAddCommand(cliPath: String) -> String { "claude mcp add \(serverName) -- \(cliPath) mcp" }

    /// `mcp_servers` table for the Codex CLI `~/.codex/config.toml`.
    static func codexConfigTOML(cliPath: String) -> String {
        """
        [mcp_servers.\(serverName)]
        command = "\(cliPath)"
        args = ["mcp"]
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

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codexCLI: "Codex CLI"
        }
    }

    var configHint: String {
        switch self {
        case .claudeCode: "Run once in your terminal."
        case .codexCLI: "Add to the mcp_servers table in ~/.codex/config.toml."
        }
    }

    func configSnippet(cliPath: String) -> String {
        switch self {
        case .claudeCode: MCPClientConfiguration.claudeCodeAddCommand(cliPath: cliPath)
        case .codexCLI: MCPClientConfiguration.codexConfigTOML(cliPath: cliPath)
        }
    }
}
