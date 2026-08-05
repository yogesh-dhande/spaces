import Foundation

/// Installs the Spaces lifecycle plugin for opencode.
///
/// opencode auto-loads every file in `~/.config/opencode/plugin/` at startup (verified against
/// opencode 1.16), so installation is a single whole-file write — inherently idempotent, with no
/// user-config merge. The plugin reports lifecycle signals from inside the opencode process, running
/// `spaces agent signal`, which reads Spaces session env vars and no-ops in other terminals.
///
/// Signal mapping: plugin startup → `init`, `chat.message` and `tool.execute.before` hooks →
/// `working`, event-bus `permission.asked` → `blocked`, event-bus `permission.replied` → `working`,
/// event-bus `session.idle` → `done`. opencode has no session-end event, so there is no `exit` signal.
///
/// opencode is the only supported agent that reports the *answer* to a permission prompt:
/// `permission.replied` fires the moment the human allows or rejects, which is exactly when the block
/// ends. Claude Code and Codex have no such event and can only infer the resume from the approved tool
/// having run. `tool.execute.before` (verified against opencode 1.16) still carries `working` for every
/// other tool call, since an approval fires no `chat.message`.
enum AgentHookOpencodePluginWriter {
    static let pluginFileName = "spaces-agent-signal.js"
    private static let ownershipHeaderPrefix = "// spaces-agent-signal — managed by Spaces ("

    struct UnmanagedPluginError: LocalizedError {
        let path: String
        var errorDescription: String? { "\(path) already exists and is not managed by Spaces; refusing to overwrite it." }
    }

    static func install(pluginURL: URL, spacesExecutablePath: String, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: pluginURL.path) {
            let existing = try String(contentsOf: pluginURL, encoding: .utf8)
            guard isSpacesOwned(existing) else { throw UnmanagedPluginError(path: pluginURL.path) }
        }
        try AgentHookConfigFile.write(pluginContents(spacesExecutablePath: spacesExecutablePath), to: pluginURL, fileManager: fileManager)
    }

    /// The ownership marker distinguishes the Spaces plugin from an unrelated file at the managed
    /// path; its version marker distinguishes this build's plugin from an older Spaces plugin.
    static func installState(pluginURL: URL) -> AgentHookInstallState {
        guard let contents = try? String(contentsOf: pluginURL, encoding: .utf8), isSpacesOwned(contents) else { return .notInstalled }
        return AgentHookCommand.isCurrent(contents) ? .current : .outdated
    }

    /// The plugin source. Uses Bun's `$` shell helper (passed into every opencode plugin) to run the
    /// Spaces CLI at the absolute path resolved when hooks were installed, for the same reason the
    /// shell hook commands do — see `AgentHookCommand`. Bun's `$` interpolates a JS value as a single
    /// argument, so the path needs no shell quoting here. Failures are swallowed so a signal never
    /// disrupts the agent.
    static func pluginContents(spacesExecutablePath: String) -> String {
        return """
            \(ownershipHeaderPrefix)\(AgentHookCommand.versionedMarker())). Do not edit; reinstall from Spaces settings.

            const SPACES_CLI = \(javaScriptStringLiteral(spacesExecutablePath))

            export const SpacesAgentSignal = async ({ $ }) => {
              const signal = async (event) => {
                try {
                  await $`${SPACES_CLI} agent signal ${event}`.quiet()
                } catch {}
              }
              await signal("init")
              return {
                "chat.message": async () => {
                  await signal("working")
                },
                "tool.execute.before": async () => {
                  await signal("working")
                },
                event: async ({ event }) => {
                  if (event.type === "permission.asked") await signal("blocked")
                  else if (event.type === "permission.replied") await signal("working")
                  else if (event.type === "session.idle") await signal("done")
                },
              }
            }

            """
    }

    /// Renders `value` as a double-quoted JavaScript string literal.
    private static func javaScriptStringLiteral(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func isSpacesOwned(_ contents: String) -> Bool {
        contents.contains(ownershipHeaderPrefix) && contents.contains(AgentHookCommand.marker)
    }
}
