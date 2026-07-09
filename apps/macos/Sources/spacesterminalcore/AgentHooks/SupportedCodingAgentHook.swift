import Foundation

/// A coding agent for which Spaces can auto-install lifecycle hooks. Each case owns its config
/// locations, executable names (for availability detection), and the idempotent install/status logic
/// that wires the agent's hook events to `spaces agent signal`.
///
/// Distinct from `TerminalDetectedAgentKind` (which splits `claude`/`claude-code` for foreground
/// process classification): here "Claude Code" is one target that owns `~/.claude/settings.json`.
public enum SupportedCodingAgentHook: String, CaseIterable, Sendable, Codable {
    case claudeCode
    case codex
    case opencode

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .opencode: "opencode"
        }
    }

    /// Two-letter tile text used in the settings row, matching the workspace agent-row tiles.
    public var tileText: String {
        switch self {
        case .claudeCode: "CL"
        case .codex: "CX"
        case .opencode: "OC"
        }
    }

    /// Executable names to probe on PATH / common install dirs for availability.
    var executableNames: [String] {
        switch self {
        case .claudeCode: ["claude"]
        case .codex: ["codex"]
        case .opencode: ["opencode"]
        }
    }

    /// The agent's config directory, relative to home.
    func configDirectoryURL(home: URL) -> URL {
        switch self {
        case .claudeCode: home.appendingPathComponent(".claude", isDirectory: true)
        case .codex: home.appendingPathComponent(".codex", isDirectory: true)
        case .opencode: home.appendingPathComponent(".config/opencode", isDirectory: true)
        }
    }

    /// Claude and Codex use the same JSON hook shape; these are their event → signal bindings.
    /// opencode uses a plugin file instead and returns an empty list.
    var jsonEventBindings: [AgentHookJSONWriter.EventBinding] {
        switch self {
        case .claudeCode:
            [
                .init(eventName: "SessionStart", event: .initialize),
                .init(eventName: "UserPromptSubmit", event: .working),
                .init(eventName: "PermissionRequest", event: .blocked),
                .init(eventName: "Stop", event: .done),
                .init(eventName: "SessionEnd", event: .exit),
            ]
        case .codex:
            // Codex has no session-end event, so no `exit` binding.
            [
                .init(eventName: "SessionStart", event: .initialize),
                .init(eventName: "UserPromptSubmit", event: .working),
                .init(eventName: "PermissionRequest", event: .blocked),
                .init(eventName: "Stop", event: .done),
            ]
        case .opencode: []
        }
    }

    // MARK: - Per-agent install / status

    func install(home: URL, cliPath: String, fileManager: FileManager) throws {
        switch self {
        case .claudeCode:
            try AgentHookJSONWriter.install(
                fileURL: configDirectoryURL(home: home).appendingPathComponent("settings.json"), cliPath: cliPath,
                bindings: jsonEventBindings, fileManager: fileManager)
        case .codex:
            let codexDir = configDirectoryURL(home: home)
            try AgentHookJSONWriter.install(
                fileURL: codexDir.appendingPathComponent("hooks.json"), cliPath: cliPath, bindings: jsonEventBindings, fileManager: fileManager)
            try AgentHookCodexFeatureToggle.ensureEnabled(fileURL: codexDir.appendingPathComponent("config.toml"), fileManager: fileManager)
        case .opencode:
            try AgentHookOpencodePluginWriter.install(
                pluginURL: opencodePluginURL(home: home), cliPath: cliPath, fileManager: fileManager)
        }
    }

    func hooksInstalled(home: URL, fileManager: FileManager) -> Bool {
        switch self {
        case .claudeCode:
            return AgentHookJSONWriter.isInstalled(
                fileURL: configDirectoryURL(home: home).appendingPathComponent("settings.json"), bindings: jsonEventBindings,
                fileManager: fileManager)
        case .codex:
            let codexDir = configDirectoryURL(home: home)
            return AgentHookJSONWriter.isInstalled(
                fileURL: codexDir.appendingPathComponent("hooks.json"), bindings: jsonEventBindings, fileManager: fileManager)
                && AgentHookCodexFeatureToggle.isEnabled(fileURL: codexDir.appendingPathComponent("config.toml"))
        case .opencode:
            return AgentHookOpencodePluginWriter.isInstalled(pluginURL: opencodePluginURL(home: home))
        }
    }

    private func opencodePluginURL(home: URL) -> URL {
        configDirectoryURL(home: home).appendingPathComponent("plugin/\(AgentHookOpencodePluginWriter.pluginFileName)")
    }
}
