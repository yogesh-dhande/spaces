import Foundation

/// Installs the Spaces lifecycle plugin for opencode.
///
/// opencode auto-loads every file in `~/.config/opencode/plugin/` at startup (verified against
/// opencode 1.16), so installation is a single whole-file write — inherently idempotent, with no
/// user-config merge. The plugin reports lifecycle signals from inside the opencode process, running
/// `spaces agent signal`, which reads Spaces session env vars and no-ops in other terminals.
///
/// Signal mapping: plugin startup → `init`, `chat.message` hook → `working`, event-bus
/// `permission.asked` → `blocked`, event-bus `session.idle` → `done`. opencode has no session-end
/// event, so there is no `exit` signal.
enum AgentHookOpencodePluginWriter {
    static let pluginFileName = "spaces-agent-signal.js"

    static func install(pluginURL: URL, spacesExecutablePath: String, fileManager: FileManager = .default) throws {
        try AgentHookConfigFile.write(pluginContents(spacesExecutablePath: spacesExecutablePath), to: pluginURL, fileManager: fileManager)
    }

    /// A whole-file write means the plugin is either absent, or exactly what some Spaces build wrote.
    /// The header's version marker is what distinguishes this build's plugin from an older one's.
    static func installState(pluginURL: URL) -> AgentHookInstallState {
        guard let contents = try? String(contentsOf: pluginURL, encoding: .utf8), contents.contains(AgentHookCommand.marker) else {
            return .notInstalled
        }
        return AgentHookCommand.isCurrent(contents) ? .current : .outdated
    }

    /// The plugin source. Uses Bun's `$` shell helper (passed into every opencode plugin) to run the
    /// Spaces CLI at the absolute path resolved when hooks were installed, for the same reason the
    /// shell hook commands do — see `AgentHookCommand`. Bun's `$` interpolates a JS value as a single
    /// argument, so the path needs no shell quoting here. Failures are swallowed so a signal never
    /// disrupts the agent.
    static func pluginContents(spacesExecutablePath: String) -> String {
        return """
            // spaces-agent-signal — managed by Spaces (\(AgentHookCommand.versionedMarker())). Do not edit; reinstall from Spaces settings.

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
                event: async ({ event }) => {
                  if (event.type === "permission.asked") await signal("blocked")
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
}
