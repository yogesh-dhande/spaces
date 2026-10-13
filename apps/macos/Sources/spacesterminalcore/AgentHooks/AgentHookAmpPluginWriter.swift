import Foundation

/// Installs the Spaces lifecycle plugin for Amp.
///
/// Amp auto-loads every `*.ts` file in `~/.config/amp/plugins/` (system plugins) at launch, with no
/// approval prompt, and runs each with Bun in its own child process (`amp run <tmp>/plugin-runtime.ts
/// <plugin>`) in its own process group, inheriting the terminal's environment (verified against amp
/// 0.0.1791849701). Spaces owns exactly one file, `spaces.ts`, and writes it wholesale, so installation
/// is inherently idempotent and never merges into a file the user keeps. Like the opencode plugin and
/// the pi extension, the plugin reports from inside the agent's process tree by running `spaces agent
/// signal`, which reads Spaces session env vars and no-ops in other terminals.
///
/// Everything keys off `amp.activeThread`, the thread the TUI is showing. It emits null at load, then
/// the thread id at the first submitted prompt of a fresh launch (or at launch for `amp threads
/// continue <id>`), and null again when the user starts a new thread from the command palette until
/// that thread's first prompt; it can repeat an id, so the plugin dedupes. In execute mode (`amp -x`)
/// it stays null for the whole run although `session.start`, thread state and `agent.end` still fire, so
/// keying off it is what keeps a one-shot run from being reported as a session. Accepted: a freshly
/// launched Amp signals nothing until its first prompt, and foreground process detection shows it
/// meanwhile.
///
/// Signal mapping:
/// - `activeThread` emitting a new id → `init` with `{ "session_id": id }`. Amp's thread id is directly
///   resumable (`amp threads continue <id>`) and there is no transcript file, so the payload carries no
///   `transcript_path` and the CLI reports the id `resumable` as it stands (see `AgentHookSessionKey`).
///   A thread exists from its first prompt, which is when the id is emitted.
/// - `activeThread` emitting null after an id (a new thread) → `init` with `{ "session_id": "" }`, which
///   the CLI reads as pending for Amp and uses to clear the previous thread's resume key (an empty
///   payload would read as unreported and leave the stale key in place). That reading depends on the
///   agent, so every signal passes `--agent amp`.
/// - The row keeps the last status it was sent, and `init` deliberately does not reset it. Switching
///   from a busy thread to one that is not working (a new thread, or an idle one) therefore sends `done`,
///   or the row would stay busy until the shown thread next runs.
/// - `session.start` fires once per thread when it starts in this process; the plugin subscribes to that
///   thread's state then. `ThreadState` is `idle | running | awaiting-approval | error`. Only the active
///   thread's transitions are forwarded: `running` → `working`, `awaiting-approval` → `blocked`, `idle`
///   or `error` → `done`, the last only if the thread had been running or awaiting approval since its
///   previous `done` (a continued thread's initial `idle` is not a finished turn). A thread that becomes
///   active mid-turn is signaled from its latest known state.
/// - The plugin sends no `exit`; process detection reports Amp leaving the terminal. `amp.onDispose`
///   cannot stand in for it: it also fires when plugins are reloaded (the `plugins: reload` command, or
///   Spaces rewriting this file), and a false exit would end the row's subscriptions while Amp runs on.
///
/// - `awaiting-approval` is Amp's own signal for a turn blocked on a tool approval. It was not observed
///   in probes, because default Amp asks for no tool approvals. An agent question (`ask_user_choice`) and
///   a plugin `ctx.ui.confirm` dialog leave the state at `running` and fire no event, so they do not show
///   as blocked. That gap is accepted.
/// - `agent.end` is not used: it was missed once for a turn that had a dialog, and a plugin can continue
///   the thread after it. The state stream is the authority on whether a turn is over.
/// - Signals run one at a time through a promise queue in the order the events fired, so a late `working`
///   cannot land after a `done`. The payload is written to the child's stdin and stdin is then closed,
///   an empty write when there is no payload, since the CLI reads stdin to EOF. A signal call swallows
///   its own errors and always resolves.
/// - The plugin registers nothing when `amp.activeThread.subscribe` is not a function (builds without
///   it). Amp versions are build timestamps (`0.0.<n>`), so a feature check replaces a version floor.
///
/// Amp has no per-plugin disable switch Spaces can read, so there is no `disabledByAgent` state:
/// removing the file is how the plugin is uninstalled.
enum AgentHookAmpPluginWriter {
    static let pluginFileName = "spaces.ts"
    private static let ownershipHeaderPrefix = "// spaces-agent-signal: managed by Spaces ("

    struct UnmanagedPluginError: LocalizedError {
        let path: String
        var errorDescription: String? { "\(path) already exists and is not managed by Spaces; refusing to overwrite it." }
    }

    static func pluginURL(ampHome: URL) -> URL { ampHome.appendingPathComponent("plugins/\(pluginFileName)") }

    static func install(pluginURL: URL, spacesExecutablePath: String, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: pluginURL.path) {
            let existing = try String(contentsOf: pluginURL, encoding: .utf8)
            guard isSpacesOwned(existing) else { throw UnmanagedPluginError(path: pluginURL.path) }
        }
        try AgentHookConfigFile.write(pluginContents(spacesExecutablePath: spacesExecutablePath), to: pluginURL, fileManager: fileManager)
    }

    /// `.notInstalled` without a Spaces-owned file at the managed path, `.outdated` when its version
    /// marker is not this build's or the `spaces` path baked into `SPACES_CLI` is not
    /// `spacesExecutablePath` (the same rule as `AgentHookOpencodePluginWriter.installState`).
    static func installState(pluginURL: URL, spacesExecutablePath: String?) -> AgentHookInstallState {
        guard let contents = try? String(contentsOf: pluginURL, encoding: .utf8), isSpacesOwned(contents) else { return .notInstalled }
        guard AgentHookCommand.isCurrent(contents) else { return .outdated }
        guard let spacesExecutablePath, AgentHookEmbeddedCLIPath.path(in: contents) == spacesExecutablePath else { return .outdated }
        return .current
    }

    /// The plugin source. It runs the Spaces CLI at the absolute path resolved when hooks were installed,
    /// for the same reason the shell hook commands do (see `AgentHookCommand`). `execFile` takes the path
    /// and arguments as an array, so the path needs no shell quoting.
    static func pluginContents(spacesExecutablePath: String) -> String {
        return """
            \(ownershipHeaderPrefix)\(AgentHookCommand.versionedMarker())). Do not edit; reinstall from Spaces settings.
            import { execFile } from "node:child_process"

            \(AgentHookEmbeddedCLIPath.declaration(for: spacesExecutablePath))

            const send = (event, payload) =>
              new Promise((resolve) => {
                try {
                  const child = execFile(SPACES_CLI, ["agent", "signal", event, "--agent", "amp"], { timeout: 10000 }, () => resolve())
                  child.stdin?.end(payload)
                } catch {
                  resolve()
                }
              })

            let queue = Promise.resolve()
            const signal = (event, payload = "") => {
              queue = queue.then(() => send(event, payload))
              return queue
            }

            const isLive = (state) => state === "running" || state === "awaiting-approval"

            export default function (amp) {
              if (typeof amp?.activeThread?.subscribe !== "function") return
              let activeID = null
              let rowBusy = false
              const latestState = new Map()
              const busy = new Set()
              const watched = new Set()

              const forward = (event) => {
                rowBusy = event === "working" || event === "blocked"
                return signal(event)
              }

              const report = (id, state) => {
                if (state === "running") {
                  busy.add(id)
                  return forward("working")
                }
                if (state === "awaiting-approval") {
                  busy.add(id)
                  return forward("blocked")
                }
                if ((state === "idle" || state === "error") && busy.delete(id)) return forward("done")
              }

              amp.activeThread.subscribe({
                next: (thread) => {
                  const id = thread?.id ?? null
                  if (id === activeID) return
                  activeID = id
                  signal("init", JSON.stringify({ session_id: id ?? "" }))
                  const state = id === null ? undefined : latestState.get(id)
                  if (isLive(state)) report(id, state)
                  else if (rowBusy) forward("done")
                },
              })

              amp.on("session.start", async (event, ctx) => {
                const id = event?.thread?.id
                const state = ctx?.thread?.state
                if (!id || watched.has(id) || typeof state?.subscribe !== "function") return
                watched.add(id)
                state.subscribe({
                  next: (value) => {
                    latestState.set(id, value)
                    if (id === activeID) report(id, value)
                    else if (!isLive(value)) busy.delete(id)
                  },
                })
              })
            }

            """
    }

    private static func isSpacesOwned(_ contents: String) -> Bool {
        contents.contains(ownershipHeaderPrefix) && contents.contains(AgentHookCommand.marker)
    }
}
