import Foundation

/// Per-agent hook mechanics: the event → signal bindings, and the idempotent install/status logic that
/// wires them into each agent's config so its lifecycle reaches `spaces agent signal`.
extension CodingAgent {
    /// Claude and Codex use the same JSON hook shape; these are their event → signal bindings.
    /// opencode uses a plugin file instead and returns an empty list.
    ///
    /// **The post-tool events are what end a block.** Neither agent emits anything at the instant a
    /// permission prompt is answered, and both fire `PreToolUse` *before* the permission decision, so a
    /// tool that needs approval always fires `PreToolUse` and then `PermissionRequest` — the block
    /// always supersedes that tool's own `working`. The approved tool having run is the earliest
    /// evidence the human answered. Binding only `PreToolUse` leaves the row `waiting` for the whole
    /// execution of the approved tool and, when that tool is the turn's last, all the way to `Stop` — so
    /// the row never returns to `working` at all and its alert only ever changes from blocked to done.
    /// (Verified against claude-code 2.1.220 and codex-cli 0.146: `PreToolUse` → `PermissionRequest` →
    /// *approval, no hook* → post-tool event → next tool's `PreToolUse`.)
    ///
    /// Claude Code splits the post-tool event by outcome: a tool that succeeds fires `PostToolUse`, and
    /// one that fails or is interrupted fires `PostToolUseFailure` **instead**. Both must map to
    /// `working` or an approved command that exits non-zero — the common case, since a risky command is
    /// exactly what gets gated — would leave the row blocked. Codex has no failure variant in its hook
    /// registry (PreToolUse/PostToolUse/PermissionRequest/Pre+PostCompact/SessionStart/SessionEnd/
    /// UserPromptSubmit/SubagentStart/SubagentStop/Stop) and its single `PostToolUse` is verified to fire
    /// for a non-zero exit, so it needs no second binding and a name it does not know would only add an
    /// inert entry.
    ///
    /// **Denying a prompt is silent.** Both denial paths in Claude Code — `Esc` to cancel and the "No"
    /// option — end the turn without firing any hook at all, `PermissionDenied` and `Stop` included
    /// (`PermissionDenied` exists in the registry but is not the interactive-denial signal). Nothing can
    /// be bound for it; the row leaves `blocked` on the human's next prompt instead.
    ///
    /// The daemon suppresses the repeat `working` signals these events produce while the agent is
    /// already spinning.
    var jsonEventBindings: [AgentHookJSONWriter.EventBinding] {
        switch self {
        case .claudeCode:
            [
                .init(eventName: "SessionStart", event: .initialize), .init(eventName: "UserPromptSubmit", event: .working),
                .init(eventName: "PreToolUse", event: .working), .init(eventName: "PostToolUse", event: .working),
                .init(eventName: "PostToolUseFailure", event: .working), .init(eventName: "PermissionRequest", event: .blocked),
                .init(eventName: "Stop", event: .done), .init(eventName: "SessionEnd", event: .exit),
            ]
        case .codex:
            // Codex has no session-end event, so no `exit` binding. Its hooks feature accepts the
            // Claude-compatible event set including PreToolUse and PostToolUse (verified against
            // codex-cli 0.146).
            [
                .init(eventName: "SessionStart", event: .initialize), .init(eventName: "UserPromptSubmit", event: .working),
                .init(eventName: "PreToolUse", event: .working), .init(eventName: "PostToolUse", event: .working),
                .init(eventName: "PermissionRequest", event: .blocked), .init(eventName: "Stop", event: .done),
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
