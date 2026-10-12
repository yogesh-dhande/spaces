import Foundation

/// Per-agent hook mechanics: the event → signal bindings, and the idempotent install/status logic that
/// wires them into each agent's config so its lifecycle reaches `spaces agent signal`.
extension CodingAgent {
    /// Claude and Codex use the same JSON hook shape; these are their event → signal bindings. Copilot's
    /// file shape differs (flat entries, see `AgentHookCopilotHooksWriter`) but binds events the same way,
    /// so its table lives here too. opencode uses a plugin file instead and returns an empty list.
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
    /// registry (PreToolUse/PermissionRequest/PostToolUse/Pre+PostCompact/SessionStart/SessionEnd/
    /// UserPromptSubmit/SubagentStart/SubagentStop/Stop/Interrupt, read from codex-cli 0.153.4) and its
    /// single `PostToolUse` is verified to fire for a non-zero exit, so it needs no second binding and a
    /// name it does not know would only add an inert entry.
    ///
    /// **Denying a prompt is silent.** Both denial paths in Claude Code — `Esc` to cancel and the "No"
    /// option — end the turn without firing any hook at all, `PermissionDenied` and `Stop` included
    /// (`PermissionDenied` exists in the registry but is not the interactive-denial signal). Nothing can
    /// be bound for it; the row leaves `blocked` on the human's next prompt instead.
    ///
    /// **A question to the human is the same state as a permission prompt.** Claude Code's
    /// `AskUserQuestion` is a tool, so asking one fires `PermissionRequest` and lands the row in
    /// `blocked` exactly like a gated command does (verified against claude-code 2.1.220, including
    /// under `--dangerously-skip-permissions`, where question prompts still fire it). Codex's approval
    /// dialog and opencode's `permission.asked` behave the same way. Spaces deliberately keeps one
    /// waiting state for both: what the human needs to know is that the agent stopped for them, and the
    /// pane itself shows which kind of answer it wants.
    ///
    /// **A turn that ends with a prose question reads as `done`, not `blocked`** — the agent emits
    /// `Stop` and nothing distinguishes "here is your answer" from "what should I do next?". Accepted:
    /// both mean the agent stopped and the turn is over, and blue-with-an-alert already brings the human
    /// back to the pane.
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
            // Codex's hooks feature accepts the Claude-compatible event set including PreToolUse and
            // PostToolUse, and registers `SessionEnd` ("right before a session ends") alongside them
            // (verified against codex-cli 0.153.4's hook registry). Binding it is what lets a codex
            // agent report its own exit instead of waiting for the daemon's coarser exited-session
            // sweep to notice.
            //
            // The binding needs no version probe: codex's hook registry has carried `SessionEnd` since
            // codex-cli 0.145.0 (openai/codex #33895, 2026-07-17), and 0.146 is the earliest release
            // this integration is verified against, so no supported codex lacks the event.
            [
                .init(eventName: "SessionStart", event: .initialize), .init(eventName: "UserPromptSubmit", event: .working),
                .init(eventName: "PreToolUse", event: .working), .init(eventName: "PostToolUse", event: .working),
                .init(eventName: "PermissionRequest", event: .blocked), .init(eventName: "Stop", event: .done),
                .init(eventName: "SessionEnd", event: .exit),
            ]
        case .copilot:
            // Verified against copilot 1.0.91 to 1.0.95. Copilot fires `sessionStart` only when the first
            // prompt of the process is sent, not at launch, so a Copilot that has had no prompt reports
            // nothing and relies on foreground detection, like a promptless Codex.
            //
            // `notification` is bound for the two dialogs Copilot draws: `permission_prompt` (a gated
            // tool) and `elicitation_dialog` (the `ask_user` tool). Copilot's entries carry no matcher, so
            // the other notification types (`agent_idle`, `agent_completed`, `shell_completed`,
            // `shell_detached_completed`) are filtered where the payload is read
            // (`AgentHookCopilotPayload.reportsBlock`). `permissionRequest` is deliberately not bound: it
            // runs before Copilot's permission service decides, so it fires for requests that are never
            // shown, and a block raised for a dialog that never draws would never end.
            //
            // The post-tool events end a block exactly as they do for Claude: an approval fires no hook,
            // and the approved tool having run is the evidence. A deny with feedback ends in `agentStop`,
            // and `Esc` on the dialog fires nothing (the same accepted silent denial as Claude Code).
            //
            // `subagentStart`, `subagentStop` and `userPromptTransformed` are not bound: a subagent's
            // lifecycle is not the main agent's turn, and `userPromptSubmitted` already marks the prompt.
            [
                .init(eventName: "sessionStart", event: .initialize), .init(eventName: "userPromptSubmitted", event: .working),
                .init(eventName: "preToolUse", event: .working), .init(eventName: "postToolUse", event: .working),
                .init(eventName: "postToolUseFailure", event: .working), .init(eventName: "notification", event: .blocked),
                .init(eventName: "agentStop", event: .done), .init(eventName: "sessionEnd", event: .exit),
            ]
        case .opencode: []
        }
    }

    /// Whether this agent's `exit` hook signal counts only when it names the conversation the agent's
    /// row already learned from an earlier signal.
    ///
    /// Copilot is the one: `copilot --resume <id>` creates and tears down a throwaway session while it
    /// starts, so a phantom `sessionEnd` fires carrying the `sessionId` of a session that never started.
    /// Taking it as an exit would finalize the row of an agent that is still starting. A real exit names
    /// the conversation the row learned. An exit the filter drops costs nothing, since process-exit
    /// detection still catches a real one.
    public var countsExitOnlyForLearnedConversation: Bool {
        switch self {
        case .copilot: true
        case .claudeCode, .codex, .opencode: false
        }
    }

    /// Whether an `exit` signal from this agent finalizes its row, given the conversation the signal names
    /// and the one the row holds (see `countsExitOnlyForLearnedConversation`).
    public func exitSignalCounts(reportedKey: AgentHookSessionKeyReport, rowSessionKey: String?) -> Bool {
        guard countsExitOnlyForLearnedConversation else { return true }
        guard case .resumable(let reported) = reportedKey, let rowSessionKey else { return false }
        return reported == rowSessionKey
    }

    // MARK: - Per-agent install / status

    func install(
        home: URL, fileManager: FileManager, spacesExecutablePath: String, agentExecutablePath: String,
        codexAppServer: AgentHookCodexAppServer.Launcher
    ) throws {
        switch self {
        case .claudeCode:
            try AgentHookJSONWriter.install(
                fileURL: configDirectoryURL(home: home).appendingPathComponent("settings.json"), bindings: jsonEventBindings,
                spacesExecutablePath: spacesExecutablePath, fileManager: fileManager)
        case .codex:
            let codexDir = configDirectoryURL(home: home)
            let hooksFileURL = codexDir.appendingPathComponent("hooks.json")
            try AgentHookJSONWriter.install(
                fileURL: hooksFileURL, bindings: jsonEventBindings, spacesExecutablePath: spacesExecutablePath, fileManager: fileManager)
            // Codex's records of the entries (`[hooks.state."<key>"]` in `config.toml`) are left as they
            // are. Codex compares a record's `trusted_hash` with the entry's current text, so an entry the
            // rewrite changed already reads untrusted and is asked about again, while one written back
            // unchanged at the same coordinate keeps its trust. The same record holds the user's
            // `enabled = false`, which has to outlast a Spaces update that changes the hook.
            try AgentHookCodexFeatureToggle.ensureEnabled(executablePath: agentExecutablePath, codexHome: codexDir)
            // The Spaces MCP server entry goes in through Codex as well, so Codex stays the only writer of
            // its TOML and the user's other settings on the entry survive.
            try AgentHookCodexAppServer.withSession(
                executablePath: agentExecutablePath, codexHome: codexDir, timeoutSeconds: AgentHookCodexTrust.trustTimeoutSeconds,
                launcher: codexAppServer
            ) { try $0.registerSpacesMCPServer(spacesExecutablePath: spacesExecutablePath) }
        case .opencode:
            try AgentHookOpencodePluginWriter.install(
                pluginURL: opencodePluginURL(home: home), spacesExecutablePath: spacesExecutablePath, fileManager: fileManager)
        case .copilot:
            try AgentHookCopilotHooksWriter.install(
                fileURL: AgentHookCopilotHooksWriter.hooksFileURL(copilotHome: configDirectoryURL(home: home)), bindings: jsonEventBindings,
                spacesExecutablePath: spacesExecutablePath, fileManager: fileManager)
        }
    }

    /// How completely the agent's own config files carry the hooks this build writes.
    ///
    /// For Codex this covers the hooks file and the `hooks` feature flag only (the `spaces` MCP server entry
    /// is read through the app-server with the trust state, see `AgentHookCodexTrust.status`), and its `current` means
    /// "ready to be trusted": whether Codex has trusted the entries, or the user switched them off, is
    /// Codex's to say and is read through `AgentHookCodexTrust` once this reports `current`. The states
    /// are ordered by what fixes them. Entries an older Spaces wrote, or the feature flag being off, are
    /// `.outdated` because reinstalling fixes both, and reinstalling first is what makes the trust
    /// question worth asking, since it is the entries this build writes that the user is asked to trust.
    ///
    /// Every agent's hook commands must name `spacesExecutablePath`, the installed CLI, to read `current`.
    func configState(home: URL, fileManager: FileManager, agentExecutablePath: String?, spacesExecutablePath: String?) -> AgentHookInstallState {
        switch self {
        case .claudeCode:
            return AgentHookJSONWriter.installState(
                fileURL: configDirectoryURL(home: home).appendingPathComponent("settings.json"), bindings: jsonEventBindings,
                spacesExecutablePath: spacesExecutablePath, fileManager: fileManager)
        case .codex:
            let codexDir = configDirectoryURL(home: home)
            let json = AgentHookJSONWriter.installState(
                fileURL: codexDir.appendingPathComponent("hooks.json"), bindings: jsonEventBindings, spacesExecutablePath: spacesExecutablePath,
                fileManager: fileManager)
            guard json != .notInstalled else { return .notInstalled }
            guard let agentExecutablePath else { return .outdated }
            let enabled = AgentHookCodexFeatureToggle.isEnabled(executablePath: agentExecutablePath, codexHome: codexDir)
            return json == .current && enabled ? .current : .outdated
        case .opencode:
            return AgentHookOpencodePluginWriter.installState(
                pluginURL: opencodePluginURL(home: home), spacesExecutablePath: spacesExecutablePath, fileManager: fileManager)
        case .copilot:
            let hooksFileURL = AgentHookCopilotHooksWriter.hooksFileURL(copilotHome: configDirectoryURL(home: home))
            let state = AgentHookCopilotHooksWriter.installState(
                fileURL: hooksFileURL, bindings: jsonEventBindings, spacesExecutablePath: spacesExecutablePath)
            guard state == .current else { return state }
            // Copilot runs no hook while `disableAllHooks` is set, whatever the file carries, and Spaces
            // never edits the user's settings, so the user is sent to Copilot to turn hooks back on.
            let settingsURL = configDirectoryURL(home: home).appendingPathComponent("settings.json")
            return AgentHookCopilotHooksWriter.hooksDisabled(settingsURL: settingsURL) ? .disabledByAgent : .current
        }
    }

    private func opencodePluginURL(home: URL) -> URL {
        configDirectoryURL(home: home).appendingPathComponent("plugin/\(AgentHookOpencodePluginWriter.pluginFileName)")
    }
}
