import Foundation

/// A coding agent for which Spaces can install lifecycle hooks. Each case owns its config locations,
/// executable names (for availability detection), and the idempotent install/status logic that wires
/// the agent's hook events to `spaces agent signal`.
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
    ///
    /// `PreToolUse` → `working` exists because approving a permission prompt resumes execution without
    /// firing any hook (an approval is not a `UserPromptSubmit`): without it a `blocked` agent would
    /// stay `waiting` until its next Stop even while actively running tools. The first tool call after
    /// an approval re-marks the agent working; the daemon suppresses the repeat signals every
    /// subsequent tool call produces.
    var jsonEventBindings: [AgentHookJSONWriter.EventBinding] {
        switch self {
        case .claudeCode:
            [
                .init(eventName: "SessionStart", event: .initialize), .init(eventName: "UserPromptSubmit", event: .working),
                .init(eventName: "PreToolUse", event: .working), .init(eventName: "PermissionRequest", event: .blocked),
                .init(eventName: "Stop", event: .done), .init(eventName: "SessionEnd", event: .exit),
            ]
        case .codex:
            // Codex has no session-end event, so no `exit` binding. Its hooks feature accepts the
            // Claude-compatible event set including PreToolUse (verified against codex-cli 0.144).
            [
                .init(eventName: "SessionStart", event: .initialize), .init(eventName: "UserPromptSubmit", event: .working),
                .init(eventName: "PreToolUse", event: .working), .init(eventName: "PermissionRequest", event: .blocked),
                .init(eventName: "Stop", event: .done),
            ]
        case .opencode: []
        }
    }

    // MARK: - Per-agent install / status

    func install(home: URL, fileManager: FileManager, spacesExecutablePath: String, agentExecutablePath: String) throws {
        switch self {
        case .claudeCode:
            try AgentHookJSONWriter.install(
                fileURL: configDirectoryURL(home: home).appendingPathComponent("settings.json"), bindings: jsonEventBindings,
                spacesExecutablePath: spacesExecutablePath, fileManager: fileManager)
        case .codex:
            let codexDir = configDirectoryURL(home: home)
            try AgentHookJSONWriter.install(
                fileURL: codexDir.appendingPathComponent("hooks.json"), bindings: jsonEventBindings, spacesExecutablePath: spacesExecutablePath,
                fileManager: fileManager)
            try AgentHookCodexFeatureToggle.ensureEnabled(executablePath: agentExecutablePath, codexHome: codexDir)
        case .opencode:
            try AgentHookOpencodePluginWriter.install(
                pluginURL: opencodePluginURL(home: home), spacesExecutablePath: spacesExecutablePath, fileManager: fileManager)
        }
    }

    func installState(home: URL, fileManager: FileManager, agentExecutablePath: String?) -> AgentHookInstallState {
        switch self {
        case .claudeCode:
            return AgentHookJSONWriter.installState(
                fileURL: configDirectoryURL(home: home).appendingPathComponent("settings.json"), bindings: jsonEventBindings, fileManager: fileManager
            )
        case .codex:
            // Codex needs both halves: the hook entries, and `features.hooks = true` to run them.
            // Current entries with the flag off are `.outdated`, not `.current` — the hooks exist but
            // cannot fire — and reinstalling sets the flag.
            let codexDir = configDirectoryURL(home: home)
            let json = AgentHookJSONWriter.installState(
                fileURL: codexDir.appendingPathComponent("hooks.json"), bindings: jsonEventBindings, fileManager: fileManager)
            guard json != .notInstalled else { return .notInstalled }
            guard let agentExecutablePath else { return .outdated }
            let enabled = AgentHookCodexFeatureToggle.isEnabled(executablePath: agentExecutablePath, codexHome: codexDir)
            return json == .current && enabled ? .current : .outdated
        case .opencode: return AgentHookOpencodePluginWriter.installState(pluginURL: opencodePluginURL(home: home))
        }
    }

    private func opencodePluginURL(home: URL) -> URL {
        configDirectoryURL(home: home).appendingPathComponent("plugin/\(AgentHookOpencodePluginWriter.pluginFileName)")
    }
}
