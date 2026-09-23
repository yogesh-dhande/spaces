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
/// The plugin also reports the agent's own session id, which the CLI records so the conversation can
/// later be resumed. opencode delivers no stdin payload the CLI could read, so the id travels as
/// `--agent-session`: the hook inputs carry it directly (`input.sessionID`) and event-bus events carry
/// it at `event.properties.sessionID` (verified against opencode 1.18.18). The startup `init` signal
/// carries none, because no session exists when opencode loads its plugins.
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
    /// path; its version marker distinguishes this build's plugin from an older Spaces plugin; and,
    /// like `AgentHookJSONWriter.installState`, a current plugin still reports `.outdated` once the
    /// `spaces` path baked into its `SPACES_CLI` constant does not name an executable file on disk
    /// (e.g. a deleted development worktree), since that is what re-offers the install that repairs it.
    /// The check is existence only, never a match against the stable `~/.spaces/bin/spaces` location,
    /// for the same reason: a development daemon deliberately points the plugin at its own sibling CLI.
    static func installState(pluginURL: URL, fileManager: FileManager = .default) -> AgentHookInstallState {
        guard let contents = try? String(contentsOf: pluginURL, encoding: .utf8), isSpacesOwned(contents) else { return .notInstalled }
        guard AgentHookCommand.isCurrent(contents) else { return .outdated }
        guard let path = embeddedExecutablePath(in: contents), fileManager.isExecutableFile(atPath: path) else { return .outdated }
        return .current
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
              const signal = async (event, sessionID) => {
                try {
                  if (typeof sessionID === "string" && sessionID.length > 0) {
                    await $`${SPACES_CLI} agent signal ${event} --agent-session ${sessionID}`.quiet()
                  } else {
                    await $`${SPACES_CLI} agent signal ${event}`.quiet()
                  }
                } catch {}
              }
              await signal("init")
              return {
                "chat.message": async (input) => {
                  await signal("working", input?.sessionID)
                },
                "tool.execute.before": async (input) => {
                  await signal("working", input?.sessionID)
                },
                event: async ({ event }) => {
                  const sessionID = event.properties?.sessionID
                  if (event.type === "permission.asked") await signal("blocked", sessionID)
                  else if (event.type === "permission.replied") await signal("working", sessionID)
                  else if (event.type === "session.idle") await signal("done", sessionID)
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

    /// The `spaces` path baked into the plugin's `const SPACES_CLI = "..."` line, read back out of the
    /// double-quoted JavaScript string literal `javaScriptStringLiteral` writes: any character following
    /// a backslash is taken literally, and the first quote not preceded by one closes the string. Nil
    /// when the marker line, or its closing quote, is missing.
    private static func embeddedExecutablePath(in contents: String) -> String? {
        guard let markerRange = contents.range(of: "const SPACES_CLI = \"") else { return nil }
        var path = ""
        var index = markerRange.upperBound
        while index < contents.endIndex {
            let character = contents[index]
            if character == "\\" {
                let next = contents.index(after: index)
                guard next < contents.endIndex else { return nil }
                path.append(contents[next])
                index = contents.index(after: next)
                continue
            }
            if character == "\"" { return path }
            path.append(character)
            index = contents.index(after: index)
        }
        return nil  // no closing quote: not a well-formed string literal
    }

    private static func isSpacesOwned(_ contents: String) -> Bool {
        contents.contains(ownershipHeaderPrefix) && contents.contains(AgentHookCommand.marker)
    }
}
