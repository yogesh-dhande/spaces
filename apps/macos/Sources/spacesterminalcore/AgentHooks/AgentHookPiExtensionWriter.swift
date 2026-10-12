import Foundation

/// Installs the Spaces lifecycle extension for pi.
///
/// pi auto-loads every single-file extension in `~/.pi/agent/extensions/` at startup (TypeScript or
/// JavaScript, compiled on the fly, no build step; verified against pi 1.1.0), and runs a user-level one
/// without a trust prompt. Spaces owns exactly one file, `spaces.ts`, and writes it wholesale, so
/// installation is inherently idempotent and never merges into a file the user keeps. Like the opencode
/// plugin, the extension reports from inside the agent process by running `spaces agent signal`, which
/// reads Spaces session env vars and no-ops in other terminals.
///
/// Extensions also load in print, json and rpc modes, so every handler does nothing unless
/// `ctx.mode === "tui"`: only the interactive terminal UI is a session a Spaces row stands for.
///
/// Signal mapping, with a `running` flag that is true from a submitted prompt (`input`, which fires for
/// prompts and not for slash commands) or `agent_start` until `agent_settled`. It starts at `input`
/// because another extension can open a dialog in its own `before_agent_start` handler, which pi awaits
/// before `agent_start`; that dialog is a block like any other. Accepted: when another extension's
/// `input` handler swallows the prompt (`{ action: "handled" }`), no turn runs and `running` stays set
/// until the next prompt settles, so a dialog opened while idle in between reads as a block. That needs
/// an input-intercepting extension plus an idle-time dialog, and it clears at the next `done`; `ctx.isIdle()`
/// cannot replace the flag because pi marks a run active only after `before_agent_start`.
/// The mapping:
/// `session_start` → `init`, `before_agent_start` → `working`, `ui_prompt_start` → `blocked` (only while
/// `running`), `ui_prompt_end` → `working` (only if a block was signaled), `agent_settled` → `done`,
/// `session_shutdown` with reason `quit` → `exit`.
///
/// - `agent_end` is not final (retries and compaction can follow it); `agent_settled` is, and still
///   fires when the human aborts a run with Escape.
/// - pi has no permission prompts by design. The only surface that waits on the human is a blocking
///   dialog an extension opens (`ctx.ui.confirm`, `select`, `input`), reported by `ui_prompt_start` and
///   `ui_prompt_end`. pi's built-in dialogs (the project trust prompt at startup, the `/login` provider
///   picker) fire neither; the trust prompt is the same accepted gap as the startup trust prompts of
///   Claude Code and Codex, and `/login` is user-initiated. A dialog opened by an idle slash command is
///   the human already at the keyboard, which is why a block is signaled only while `running`.
/// - Every `session_start` (reasons `startup`, `new`, `resume`, `fork`, `reload`) signals `init` with the
///   session id then open, so the row re-keys to the conversation now showing. `/new` keeps the process
///   and starts a new conversation; only reason `quit` ends the agent.
/// - The conversation travels as the Claude Code shaped stdin payload, `{ session_id, transcript_path }`,
///   with the session file (`ctx.sessionManager.getSessionFile()`) as both. The path rather than pi's
///   session id is the resume key because `pi --session <id>` searches only the session directory in
///   effect for the relaunch, while a session started with `--session-dir` or a project `sessionDir`
///   setting lives elsewhere and `process.title` hides that option from the captured command;
///   `pi --session <path>` opens the file wherever it is. The CLI then applies the rule it applies to
///   Claude (`AgentHookSessionKey.report`): resumable only once the file exists, pending before. pi
///   writes the file at the first prompt, not at `session_start`, and `pi --session` for a session with
///   no file exits with "No session found" (verified against pi 1.1.0). Pending is also what clears the
///   previous conversation's key after `/new`. A `--no-session` run has no file and sends no payload, so
///   it is never offered for resume.
/// - A throwing `tool_call` handler blocks the tool and other handler errors surface in pi's UI, so
///   a signal call swallows its own errors and always resolves.
/// - The extension imports `VERSION` from `@earendil-works/pi-coding-agent` (pi aliases that module name
///   for extensions in both npm and standalone builds) and registers nothing below 1.1.0: older builds
///   lack `agent_settled` and `ui_prompt_*`, so a row would stick on working.
///
/// Unchecking the extension in `pi config` switches it off for good without touching the file (see
/// `extensionExcluded`); `--no-extensions` switches it off for one run and is not visible to Spaces.
enum AgentHookPiExtensionWriter {
    static let extensionFileName = "spaces.ts"
    private static let ownershipHeaderPrefix = "// spaces-agent-signal: managed by Spaces ("

    struct UnmanagedExtensionError: LocalizedError {
        let path: String
        var errorDescription: String? { "\(path) already exists and is not managed by Spaces; refusing to overwrite it." }
    }

    static func extensionURL(piHome: URL) -> URL { piHome.appendingPathComponent("extensions/\(extensionFileName)") }

    static func install(extensionURL: URL, spacesExecutablePath: String, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: extensionURL.path) {
            let existing = try String(contentsOf: extensionURL, encoding: .utf8)
            guard isSpacesOwned(existing) else { throw UnmanagedExtensionError(path: extensionURL.path) }
        }
        try AgentHookConfigFile.write(extensionContents(spacesExecutablePath: spacesExecutablePath), to: extensionURL, fileManager: fileManager)
    }

    /// `.notInstalled` without a Spaces-owned file at the managed path, `.outdated` when its version
    /// marker is not this build's or the `spaces` path baked into `SPACES_CLI` is not
    /// `spacesExecutablePath` (the same rule as `AgentHookOpencodePluginWriter.installState`).
    static func installState(extensionURL: URL, spacesExecutablePath: String?) -> AgentHookInstallState {
        guard let contents = try? String(contentsOf: extensionURL, encoding: .utf8), isSpacesOwned(contents) else { return .notInstalled }
        guard AgentHookCommand.isCurrent(contents) else { return .outdated }
        guard let spacesExecutablePath, AgentHookEmbeddedCLIPath.path(in: contents) == spacesExecutablePath else { return .outdated }
        return .current
    }

    /// The extension source. It runs the Spaces CLI at the absolute path resolved when hooks were
    /// installed, for the same reason the shell hook commands do (see `AgentHookCommand`). `execFile`
    /// takes the path and arguments as an array, so the path needs no shell quoting. Signals run one at a
    /// time through a promise queue, in the order the events fired: pi awaits most handlers in order but
    /// emits `ui_prompt_start` and `ui_prompt_end` without awaiting them, so a dialog closing as a turn
    /// settles could otherwise land its `working` after `done` and leave a settled row marked busy. The payload is written to the child's stdin and
    /// stdin is then closed, an empty write when there is no session file, since the CLI reads stdin to
    /// EOF.
    static func extensionContents(spacesExecutablePath: String) -> String {
        return """
            \(ownershipHeaderPrefix)\(AgentHookCommand.versionedMarker())). Do not edit; reinstall from Spaces settings.
            import { execFile } from "node:child_process"
            import { VERSION } from "@earendil-works/pi-coding-agent"

            \(AgentHookEmbeddedCLIPath.declaration(for: spacesExecutablePath))
            const MINIMUM_PI_VERSION = [1, 1, 0]

            const atLeast = (version, floor) => {
              const parts = String(version).split(".").map((part) => parseInt(part, 10))
              for (let index = 0; index < floor.length; index++) {
                const have = parts[index] || 0
                if (have !== floor[index]) return have > floor[index]
              }
              return true
            }

            const sessionPayload = (ctx) => {
              try {
                const transcriptPath = ctx.sessionManager.getSessionFile()
                if (!transcriptPath) return ""
                return JSON.stringify({ session_id: transcriptPath, transcript_path: transcriptPath })
              } catch {
                return ""
              }
            }

            const send = (event, payload) =>
              new Promise((resolve) => {
                try {
                  const child = execFile(SPACES_CLI, ["agent", "signal", event], { timeout: 10000 }, () => resolve())
                  child.stdin?.end(payload)
                } catch {
                  resolve()
                }
              })

            let queue = Promise.resolve()
            const signal = (event, ctx) => {
              const payload = sessionPayload(ctx)
              queue = queue.then(() => send(event, payload))
              return queue
            }

            const interactive = (ctx) => ctx?.mode === "tui"

            export default function (pi) {
              if (!atLeast(VERSION, MINIMUM_PI_VERSION)) return
              let running = false
              let blockSignaled = false

              pi.on("session_start", async (_event, ctx) => {
                if (!interactive(ctx)) return
                running = false
                blockSignaled = false
                await signal("init", ctx)
              })
              pi.on("before_agent_start", async (_event, ctx) => {
                if (!interactive(ctx)) return
                await signal("working", ctx)
              })
              pi.on("input", async (_event, ctx) => {
                if (!interactive(ctx)) return
                running = true
              })
              pi.on("agent_start", async (_event, ctx) => {
                if (!interactive(ctx)) return
                running = true
                await signal("working", ctx)
              })
              pi.on("ui_prompt_start", async (_event, ctx) => {
                if (!interactive(ctx) || !running) return
                blockSignaled = true
                await signal("blocked", ctx)
              })
              pi.on("ui_prompt_end", async (_event, ctx) => {
                if (!interactive(ctx) || !blockSignaled) return
                blockSignaled = false
                await signal("working", ctx)
              })
              pi.on("agent_settled", async (_event, ctx) => {
                if (!interactive(ctx)) return
                running = false
                blockSignaled = false
                await signal("done", ctx)
              })
              pi.on("session_shutdown", async (event, ctx) => {
                if (!interactive(ctx) || event?.reason !== "quit") return
                await signal("exit", ctx)
              })
            }

            """
    }

    /// The entry `pi config` adds to the user settings' `extensions` list when the Spaces extension is
    /// unchecked: a `-` exclusion of its path relative to `~/.pi/agent` (verified against pi 1.1.0).
    static let configExclusionEntry = "-extensions/\(extensionFileName)"

    /// Whether the user switched the Spaces extension off in `pi config`, read from the user-level
    /// `settings.json`. Only the exact entry `pi config` writes is read: other exclusion patterns a
    /// person can write by hand (globs, absolute paths) and a project's `.pi/settings.json`, which
    /// applies to one folder, are not.
    static func extensionExcluded(settingsURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let entries = root["extensions"] as? [String]
        else { return false }
        return entries.contains(configExclusionEntry)
    }

    private static func isSpacesOwned(_ contents: String) -> Bool {
        contents.contains(ownershipHeaderPrefix) && contents.contains(AgentHookCommand.marker)
    }
}
