import Foundation

/// Installs the Spaces lifecycle plugin for opencode.
///
/// opencode auto-loads every file in `~/.config/opencode/plugin/` at startup (verified against
/// opencode 1.16), so installation is a single whole-file write — inherently idempotent, with no
/// user-config merge. The plugin reports lifecycle signals from inside the opencode process, reading
/// `spaces agent signal`, which reads Spaces session env vars and no-ops in other terminals.
///
/// Signal mapping: plugin startup → `init`, `chat.message` hook → `working`, event-bus
/// `permission.asked` → `blocked`, event-bus `session.idle` → `done`. opencode has no session-end
/// event, so there is no `exit` signal.
enum AgentHookOpencodePluginWriter {
    static let pluginFileName = "spaces-agent-signal.js"

    static func install(pluginURL: URL, fileManager: FileManager = .default) throws {
        try AgentHookConfigFile.write(pluginContents(), to: pluginURL, fileManager: fileManager)
    }

    static func isInstalled(pluginURL: URL) -> Bool {
        guard let contents = try? String(contentsOf: pluginURL, encoding: .utf8) else { return false }
        return contents.contains(AgentHookCommand.marker)
    }

    /// The plugin source. Uses Bun's `$` shell helper (passed into every opencode plugin) to run the
    /// `spaces` CLI from PATH; failures are swallowed so a signal never disrupts the agent.
    static func pluginContents() -> String {
        return """
            // spaces-agent-signal — managed by Spaces (\(AgentHookCommand.marker)). Do not edit; reinstall from Spaces settings.

            export const SpacesAgentSignal = async ({ $ }) => {
              const signal = async (event) => {
                try {
                  await $`spaces agent signal ${event}`.quiet()
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
}
