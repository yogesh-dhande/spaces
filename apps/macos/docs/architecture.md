# Architecture

This document describes how Spaces is built and why: module boundaries, storage, runtime flows, external integrations, and the rationale behind the major design choices. User-visible behavior belongs in [spec.md](../spec.md). Built-in terminal integration details live in [terminal.md](terminal.md).

## System Overview
Spaces is a macOS Swift app and CLI built around a shared orchestration layer.

Core invariants:
- SQLite is the single source of truth for persisted model data and global preferences.
- yabai is the source of truth for window IDs and cross-app window focus.
- Workspace settings are seeded from project templates and preserved as per-workspace overrides.
- Schema changes must be additive and non-destructive.
- GUI and CLI both call the same orchestration layer instead of re-implementing behavior independently.

## Module Map

```mermaid
flowchart LR
  cli["spaces"] --> spacescli["spacescli"]
  spacescli --> stream["workspacecore"]
  app["SpacesApp"] --> spacesui["spacesui"]
  spacesui --> stream

  stream --> store["SQLite store"]
  stream --> systembridge["systembridge adapters"]
  stream --> git["Git helpers"]

  systembridge --> yabai["yabai"]
  systembridge --> iterm["iTerm2 AppleScript"]
  systembridge --> ghostty["Ghostty AppleScript"]
  systembridge --> chrome["Chrome AppleScript"]
```

## Module Responsibilities
- `SpacesApp`: minimal app entry point that boots AppKit.
- `spacesui`: AppKit UI layer that renders state and dispatches actions into `workspacecore`. Shared visual language lives in `Theme.swift` (brand color tokens mirroring `apps/web/app/globals.css`) and `RowPrimitives.swift` (status dot, type icon tile, shortcut/project/branch chips, `ColoredBackgroundView` helper). The workspace detail pane is a single scrollable `NSStackView`; it stacks the header, directory meta row, inline notes editor, and five configuration sections (Processes, Browser sessions, Coding agents, Named ports, Stop script) in order. Each section is a self-contained class (e.g. `ProcessesSection.swift`) that owns its transient form state, swaps each row between collapsed and editing subviews via `NSAnimationContext`, and publishes commits through an `onCommit` closure that the host bridges to `orchestrator.updateWorkspaceSettings`. Named-port rows render the configured env-var name plus the currently reserved port number from `workspace_ports`, mirroring how browser-session rows separate configured input from resolved display output. The `⋯` overflow menu is built by the static `AppKitController.makeWorkspaceOverflowMenu(workspaceID:path:target:)`, which emits a stock `NSMenu` whose path-based items forward to `copyDirectoryPath(_:)` and `revealDirectoryInFinder(_:)`, while workspace actions use the same shared `senderIdentifier(_:)` helper for `NSMenuItem` and `NSControl` senders. Update delivery also lives here: `AppKitController` owns a programmatic `SPUStandardUpdaterController` from Sparkle, wires the application menu’s `Check for Updates...` item directly to Sparkle, and relies on one stable appcast feed configured in the app bundle metadata. That stable feed serves one universal Sparkle archive and one manual-download DMG rather than arch-specific release artifacts.
- `spaces`: executable shim that boots the declarative CLI parser.
- `spacescli`: declarative `swift-argument-parser` command tree for `spaces`, including command help, leaf validation, translation from CLI inputs into orchestration calls, and the first tmux-free `spaces terminal` session controls for `command`, `send`, `key`, `tail`, `list`, `show`, and `takeover`.
- `spacesterminalcore`: tmux-free terminal runtime primitives, PTY-session metadata persistence, per-session file layout, output tailing, backend selection, and the backend runtime interface used by `spaces terminal command|send|tail|list`.
- `spacesterminalghostty`: embedded libghostty integration, including local artifact discovery, runtime callbacks, control-plane bridging, and renderer availability against the session's declared backend.
- `spacesterminalruntime`: backend orchestration layer that is allowed to depend on both `spacesterminalcore` and `spacesterminalghostty`. It selects the concrete runtime for each terminal session so the core session model stays decoupled from any one renderer or PTY engine.
- `spacesterminalui`: native terminal-session window controllers owned by the Spaces app. The current slice opens one or more windows for a session ID, registers each local window as an owner or viewer client, and keeps those local windows attached through the same per-session control socket and attachment records used by the CLI.
- `workspacecore`: core orchestration, lifecycle, validation, persistence coordination, environment building, and the shared `AppVersion` constants consumed by both the GUI and CLI. Those constants are generated from `apps/macos/AppVersion.plist`, which is also used to generate the app bundle `Info.plist`.
- `systembridge`: system adapters for shell commands, yabai, iTerm2, Ghostty, Chrome, and related OS integrations.

### Terminal Session Slice
- The first tmux-free terminal slice is intentionally CLI-first.
- `spaces terminal command` starts a background PTY-backed session through `spacesterminalcore` for `script-pty`, and asks the running Spaces app to create the session in-process for `ghostty-embedded`.
- `spaces terminal show` asks the running Spaces app to open a native session window for a specific session ID through distributed notifications.
- Each session is addressed by a stable session ID and stored under `~/.spaces/terminal/sessions/<session-id>/`.
- `metadata.json` stores launch inputs including the declared backend, `state.json` stores live runtime state including the active backend, `clients.json` and `attachments.json` store client identity and owner or viewer attachment history, `control.sock` accepts local owner commands through a small request/response protocol for both text send and named-key send, and `output.log` records terminal output for `spaces terminal tail`.
- `TerminalSessionRunner` in `spacesterminalruntime` selects a concrete backend runtime for each session. The current implementation ships `ScriptPTYTerminalSessionRuntime` for `script-pty` and `GhosttyEmbeddedTerminalSessionRuntime` for `ghostty-embedded`.
- `GhosttyEmbeddedSessionHost` in `spacesterminalghostty` is the first session host layer for `ghostty-embedded`. It owns one libghostty-backed session runtime, the local control socket, output logging, runtime-state refresh, and the active owner client ID for that session.
- `GhosttyEmbeddedSessionHost` coalesces `state.json` writes so steady-state sessions refresh runtime state on change and on a light heartbeat instead of rewriting session metadata every timer tick.
- The current native window keeps one shared window-controller shell but swaps its body by backend: `script-pty` uses the recent-output shell fallback, while `ghostty-embedded` keeps the active owner window on the session host's libghostty surface. Passive viewer windows remain on the tail-based read-only view.
- `TerminalSessionWindowController` keeps the libghostty owner path focused on the embedded surface itself while viewer windows stay passive, show the current owner identity, and expose takeover without rehosting the session.
- `TerminalSessionWindowController` treats the live owner path as notification-first. Owner windows still keep a slower safety poll, but viewer and fallback windows stay on the faster tail-refresh cadence because they depend on tailed output instead of direct libghostty events.
- `TerminalSessionWindowController` performs one synchronous render pass during construction, then starts its periodic refresh loop only when `show()` actually presents the window, which avoids redundant loop churn during summon and reopen.
- `TerminalSessionWindowController.show()` treats an already visible window as a reuse path: it leaves the persisted frame alone, keeps the existing refresh task alive, and just brings the live terminal window forward before refreshing visible state.
- `TerminalSessionWindowController` keeps the owner Ghostty window chrome compact by hiding renderer diagnostics on the active owner path while retaining richer runtime and ownership metadata for viewer and fallback states.
- `TerminalSessionWindowController` uses a collapsing header stack so the active owner path can hide redundant in-window session identifiers and empty status rows while viewer and fallback windows continue to expose those diagnostics.
- The window shell summarizes process launch commands before rendering them into the header so large exported environment wrappers do not force process windows wider than the visible screen.
- `GhosttyEmbeddedAppService` routes libghostty runtime actions back to the owning surface so `GhosttyEmbeddedSessionHost` can track live session metadata such as title and working directory and expose that state to the shared window shell.
- `GhosttyEmbeddedTerminalView` caches surface geometry, focus, and occlusion state before calling libghostty so routine AppKit layout churn does not spam redundant surface updates during resize, focus, and window moves.
- `AppKitController` keeps a lightweight controller registry keyed by session ID and drops closed controllers so reopening a terminal window cleanly reattaches a fresh local client to the existing session host.
- When a live built-in process window is focused through the normal workspace flow, `WorkspaceOrchestrator` first uses yabai to bring the native window forward and then sends a lightweight in-process session-focus IPC so `AppKitController` can reassert first-responder focus onto the owner libghostty surface instead of reopening the session.
- `WorkspaceOrchestrator` waits for both the built-in session control socket and an initial settled runtime state before it persists a `Spaces` process row, so workspace-launched built-in terminals record stable session IDs and child PIDs instead of racing the app-hosted backend.
- Built-in `Spaces` process and terminal focus prefers the tracked live yabai window ID when one exists, falls back to reopening the session by stable session ID only when no live native window can be focused, and either clears the stale native window binding or replaces it with the freshly observed yabai window ID during that same reopen path so the next focus targets the live window without waiting for a later refresh pass.
- When the running app already holds exactly one live owner controller for a built-in session, `AppKitController` reuses that in-memory owner controller directly during focus IPC instead of reloading attachment state from disk before it reasserts owner-surface focus.
- `spacesterminalghostty` owns path and resource discovery for a branch-local `GhosttyKit.xcframework` plus Ghostty resource bundle, the `ghostty-embedded` session runtime, the raw-output callback bridge into `output.log`, and the raw-input path used by `spaces terminal send` and `spaces terminal key`.
- The app-hosted `ghostty-embedded` path keeps `control.sock`, `output.log`, `clients.json`, and `attachments.json` as the session boundary so later owner or viewer attachment can fan out beyond the local macOS window instead of baking control into one view.
- Owner or viewer state is persisted in `attachments.json`. CLI `send` and `key` remain privileged control-plane commands, while attached UI clients identify themselves so the session host can reject input from passive viewer windows and accept ownership transfer through `spaces terminal takeover`.
- The current terminal slice is backend-explicit: `script-pty` and `ghostty-embedded` are both supported runtime backends. `script-pty` remains the default CLI path, while `ghostty-embedded` is enabled when Ghostty artifacts are installed locally.
- This slice does not yet replace workspace-managed tmux process sessions or external terminal hosts.

## Persistence

### Database
- Path: `~/.spaces/spaces.db`
- SQLite stores projects, workspaces, runtime state, and global settings.
- SQLite should run in WAL mode with a busy timeout so overlapping GUI, CLI, and background work does not produce avoidable lock failures.
- `migration_state.current_version` records the canonical schema version. The active schema is version `1`.
- `PRAGMA user_version` is not used by Spaces for migration control; if present, treat it as informational only and keep it aligned with `migration_state` when inspecting or repairing a database manually.

### Migration Rules
- Fresh installs create the latest schema directly and record the current schema version.
- Existing installs should migrate in ordered `N -> N+1` steps until they reach the current schema version.
- Each migration step should run inside `BEGIN IMMEDIATE ... COMMIT`, update `migration_state` in the same transaction, and roll back on failure.
- Compatible schema changes should use additive techniques such as `CREATE TABLE IF NOT EXISTS`, `ALTER TABLE`, backfills, indexes, and table rebuilds with copy when SQLite requires them.
- Store startup validates `migration_state.current_version` against the canonical schema version and fails closed when they do not match.
- Startup runs `PRAGMA integrity_check` and fails if validation does not return `ok`.

## Data Model

```mermaid
classDiagram
  class Project {
    +id
    +name
    +dir
    +is_git
    +default_branch
    +is_collapsed
    +setup_script
    +stop_script
  }

  class Workspace {
    +id
    +project_id
    +title
    +dir
    +dirname
    +branch
    +target_branch
    +is_default
    +is_archived
    +is_hidden
    +is_running
    +last_launched_at
    +notes
  }

  class WorkspaceSettings {
    +workspace_id
    +stop_script
    +setup_status
    +setup_error
    +setup_started_at
    +setup_finished_at
  }

  class WorkspacePort {
    +workspace_id
    +port_index
    +port_number
    +port_name
    +definition_id
  }

  class RunningProcess {
    +id
    +workspace_id
    +template_name
    +command
    +runtime_target_id
    +pid
    +status
    +log_path
    +last_output_at
    +started_at
    +exited_at
  }

  class RuntimeTarget {
    +id
    +workspace_id
    +type
    +name
    +detail
    +app
    +window_id
    +order_index
    +created_at
    +updated_at
  }

  class TerminalTarget {
    +runtime_target_id
    +provider
    +tracking_id
    +native_id
    +container_id
    +iterm_tab_index
    +tmux_window_id
  }

  class BrowserTarget {
    +runtime_target_id
    +target_url
    +resolved_url
  }

  class AgentSession {
    +id
    +workspace_id
    +provider
    +label
    +status
    +runtime_target_id
    +session_key
    +claimed_launcher_name
    +created_at
    +updated_at
  }

  class RuntimeTargetEvent {
    +id
    +runtime_target_id
    +event_type
    +source
    +message
    +window_id
    +created_at
  }

  class AgentSessionEvent {
    +id
    +agent_session_id
    +event_type
    +source
    +message
    +runtime_target_id
    +created_at
  }

  Project "1" --> "*" Workspace
  Workspace "1" --> "0..1" WorkspaceSettings
  Workspace "1" --> "*" WorkspacePort
  Workspace "1" --> "*" RunningProcess
  Workspace "1" --> "*" RuntimeTarget
  Workspace "1" --> "*" AgentSession
  RunningProcess "*" --> "0..1" RuntimeTarget : runtime_target_id
  RuntimeTarget "1" --> "0..1" TerminalTarget
  RuntimeTarget "1" --> "0..1" BrowserTarget
  RuntimeTarget "1" --> "*" RuntimeTargetEvent
  AgentSession "*" --> "0..1" RuntimeTarget : runtime_target_id
  AgentSession "1" --> "*" AgentSessionEvent
  AgentSessionEvent "*" --> "0..1" RuntimeTarget : runtime_target_id
```

### Projects
Projects persist:
- opaque project identity separate from filesystem paths
- source directory and git status
- sidebar collapsed state
- setup and stop scripts
- port definitions
- process templates

Managed clone directories under `~/spaces/repos` and managed worktree roots under `~/spaces/workspaces` must be keyed by project identity rather than project name so cleanup, retries, and same-name projects cannot collide on disk ownership.
- browser-session templates

### Workspaces
Workspaces persist:
- directory identity
- title, notes, and branch metadata
- branch identity as the unique git-workspace key, while titles remain non-unique display text
- default and archived flags
- hidden sidebar visibility state
- explicit lifecycle state (`running` vs `stopped`)
- seeded per-workspace copies of launch-time settings

### Runtime Records
Runtime state persists separately from project and workspace templates:
- allocated ports
- running processes
- runtime targets
- terminal target details
- browser target details
- agent sessions

This separation lets template edits coexist with current runtime state and per-workspace overrides.
It also lets lifecycle state stay explicit while runtime health is derived from the current runtime records.

### Runtime Target Model
- `runtime_targets` is the canonical inventory of focusable runtime items for a workspace. Each row stores only shared fields such as `type`, host app, current yabai `window_id`, ordering, and display metadata.
- `terminal_targets` extends terminal runtime targets with terminal-host identity. Current fields are the terminal provider, the hook attribution ID, the provider-native terminal ID, the provider container ID, optional iTerm tab index, and tmux window ID.
- `browser_targets` extends browser runtime targets with the configured target URL and the last resolved URL.
- `agent_sessions` models logical coding-agent sessions separately from focusable windows. Each row links to a `runtime_target` and stores only agent-session state: provider, display label, status, provider session key, claimed launcher name, and timestamps.
- `agent_session_events` records signal-driven lifecycle updates and launcher-driven agent transitions. Each event keeps the resolved runtime-target link plus a compact message containing the provider, label, tracking token, native terminal ID, provider session key, yabai window ID, and the full set of environment key names seen by `spaces signal` for that event.
- `running_processes` is the canonical process-status record. Each row links to a `runtime_target` and stores only process runtime state such as command, PID, status, log path, and timestamps.
- Runtime targets are seeded as soon as a process or agent terminal is known, even before a separate window-reconciliation pass fills in a live yabai `window_id`. That keeps process and agent rows linked to a single canonical target instead of caching terminal identity on the base row.

### Data Modeling Guidelines
- Base tables should stay generic. If a field only makes sense for one target type or one provider, it should live on a subtype table or adapter-specific runtime path rather than on a cross-cutting base record.
- `runtime_targets` is the shared focus inventory. New target kinds should extend it through subtype tables rather than by adding more nullable type-specific columns to the base row.
- Agent-session records should describe logical session state, not terminal implementation details. Terminal identity belongs on `terminal_targets`, and agent sessions should relate to that state through `runtime_targets` instead of copying terminal fields onto the session row.
- Running-process records should describe process runtime, not terminal identity. Terminal identity belongs on `terminal_targets`, and process rows should link to the relevant runtime target instead of owning terminal-specific fields.
- When a process or agent needs terminal identity before yabai has reconciled a live window, seed or reuse a `runtime_target` plus `terminal_target` record rather than persisting terminal identity on the base process or session row.
- Provider-specific naming should be avoided in shared schema. Generic fields such as `provider` and `session_key` are acceptable when the same concept exists across providers; fields named for one product should be treated as transitional and refactored away.
- Add abstractions only when current behavior needs them. Extensibility matters, but speculative tables or fields should not be added before a real workflow requires them.
- Prefer event history for debugging destructive transitions over piling more `last_*` and `*_reason` fields onto canonical state rows. When a target or session is rebound, detached, or pruned, the system should leave an inspectable event trail.
- Distinguish hook attribution identity from provider-native identity. Some hosts use one value for both, while others need separate identities for “which shell emitted this event?” and “which live host object should be focused or checked for liveness?”

### Referential Integrity
- SQLite foreign keys stay enabled for persisted parent-child relationships.
- Store-level delete-and-reinsert updates run inside immediate transactions so partial child-table replacements cannot persist if one statement fails.

## Core Flows

### Workspace Creation
1. Resolve the target project and workspace identity.
2. For git projects, treat `Create branch` as a strictly new-branch flow and reject any branch name that already exists locally, remotely, or in an archived workspace record; only the explicit existing-branch path may reuse that branch and revive its archived workspace.
3. Create or import the workspace directory.
4. Persist the workspace and seed per-workspace settings from project templates.
5. Allocate named ports.
6. Run setup logic.

### Workspace Launch
1. Validate that the workspace is launchable.
2. Build the workspace environment, including named port variables and workspace paths.
3. Start tracked processes inside tmux-backed dedicated terminal contexts, verify the tmux pane did not die immediately, and only then open the dedicated attach window.
4. Leave configured browser sessions unopened until the user focuses them.
5. Capture new terminal windows through yabai and persist the mapping.

### Workspace Stop or Archive
1. Stop tracked processes.
2. Run the workspace stop script when appropriate.
3. Close tracked dedicated windows safely.
4. Clear runtime state.
5. Release ports.
6. Archive git worktrees when the action requires it.
7. When the user opted in during archive confirmation, attempt remote-branch deletion first and local-branch deletion second, then surface any skipped or failed branch cleanup as a post-archive notice instead of rolling back the archive.

### Discovery and Reconciliation
- Background worktree discovery imports valid unmanaged worktrees for known projects.
- Background reconciliation removes stale tracked windows and refreshes persisted workspace metadata from disk where needed.
- Saving workspace settings updates persisted configuration and synchronizes named-port reservations, but it does not reconcile live runtime by auto-starting or auto-stopping processes, browser sessions, or coding agents.
- Reconciliation may degrade runtime health, but it should not silently promote or demote workspace lifecycle state.
- Sidebar snapshot refresh can update the backing lists in the background without rebuilding the active detail pane when the current selection is still valid.
- These passes should not block the main UI thread.

## Environment and Process Model
- Named port definitions are allocated per workspace and exposed as environment variables. Workspace-settings saves preserve existing allocations where possible, allocate newly added definitions immediately, and release removed definitions without waiting for the next launch.
- Workspace processes also receive stable environment variables such as project and workspace directories.
- Setup scripts, stop scripts, and process commands all execute against the workspace-specific environment.
- Process launch and terminal recovery use tmux so the process lifetime can outlive a missing terminal window and be reattached later.
- Immediate process-start failures should be surfaced from the recent tmux pane output itself so launch errors report the real command failure instead of a follow-on tmux attach error.
- Core external dependencies that the GUI invokes directly, such as `tmux`, `yabai`, and `git`, are resolved through a shared executable-locator path instead of relying on the Finder app environment to provide a complete `PATH`.
- Global app settings include the selected terminal host, defaulting to `Spaces`, and the GUI is the configuration surface for that value.
- App-level settings such as terminal host and shell-mode process shell are persisted in the shared store but are configured through the app rather than through `spaces`.
- Global app settings also store the app-toggle hotkey and the separate command-palette hotkey.
- Global settings also store the shared window focus pulse color and enabled state behind window-scoped keys.
- Each `ProcessTemplate` persists an `execution_mode` of `direct` or `shell`. Missing fields in older saved data decode as `direct`.
- Direct mode is parsed as an executable plus argv and rejects shell-only syntax such as pipelines, redirection, command substitution, and backticks.
- Before launching a direct-mode process, Spaces validates `$...` usage against a narrow allowlist and only interpolates simple Spaces-provided variables such as named ports and `SPACES_*` paths inside tokens without invoking a shell.
- Supported direct-mode variable references are limited to `$NAME` and `${NAME}`. Unknown variable names and unsupported shell expansion forms such as `${NAME:-fallback}`, `$$`, and `$?` fail validation against the raw user command instead of being passed through literally.
- Shell mode treats the command text as shell input and launches it through the global app `process_shell` setting with a consistent `<shell> -lc <command>` invocation. The allowed shell values are `zsh`, `bash`, and `sh`, with `zsh` as the default.
- Project and workspace editors, workspace launch, running-process restart validation, JSON import/export, and CLI text output all preserve the same execution-mode semantics.

## Window and Focus Architecture
- yabai provides stable window identity and cross-app focusing.
- iTerm2, Ghostty, and Chrome AppleScript integrations add app-specific behavior on top of yabai, such as returning launch-time terminal IDs or selecting the intended browser target.
- Browser sessions are stored as workspace configuration and only become tracked windows after an explicit focus action opens them.
- Browser-session focus uses the tracked Chrome window plus tab `1` as the fast path, instead of rescanning Chrome tabs on every focus.
- CLI workspace focus resolves explicit names instead of numeric window indexes. Those names come from the same workspace-level focus model used for browser sessions, running processes, and agent terminals, and the names must stay unique within a workspace.
- The CLI stays path-based: commands target the current working directory by default or accept an explicit workspace path argument.
- Terminal focus pulsing is terminal-agnostic: Spaces queries the target yabai window and briefly presents an AppKit overlay aligned to that window instead of mutating terminal-specific appearance settings.
- iTerm2 focus now splits into two phases: a fast AppleScript select path that returns as soon as the target session/window is brought forward, followed by a background verification pass that confirms the intended session became current without delaying the pulse overlay.
- Tracked windows are persisted so Spaces can refocus or clean up only the windows it owns.
- Direct focus requests auto-recover stale browser-session windows by reopening and re-tracking them, while process and generic window failures still surface typed missing-window errors to the GUI.
- Browser-session existence is not polled during background refresh; stale browser mappings are detected on demand when the user focuses that session.
- Window cycling is tolerant of stale tracked yabai IDs and keeps advancing until it finds the next live target.
- Reconciliation is required because window state can drift outside the app.

### Terminal Integration Contract
Spaces currently supports iTerm2 and Ghostty. A future terminal integration should plug into the same orchestration flow instead of adding one-off launch and focus paths.

Target shape:

```swift
protocol TerminalAdapter: Sendable {
    var appName: String { get }
    var bundleIdentifier: String { get }

    func isAvailable() -> Bool
    func openWindowAndRun(
        command: String,
        cwd: String,
        environment: [String: String],
        background: Bool
    ) throws -> TerminalLaunchResult
    func resolveCurrentAttributionIdentity(
        environment: [String: String],
        yabaiFocusedWindowID: Int?
    ) throws -> TerminalTrackingIdentity?
    func focusTrackedTerminal(_ target: TerminalFocusTarget) throws -> Bool
    func listLiveProviderIdentities() throws -> Set<TerminalTrackingIdentity>
}

enum TerminalTrackingIdentity: Hashable, Sendable {
    case session(String)
    case window(Int)
    case tmux(String)
}

struct TerminalLaunchResult: Sendable {
    let providerIdentity: TerminalTrackingIdentity?
    let hookAttributionID: String?
    let containerIdentity: String?
    let fallbackWindowID: Int?
}

struct TerminalFocusTarget: Sendable {
    let providerIdentity: TerminalTrackingIdentity?
    let windowID: Int?
}
```

Required behavior:
- Availability: expose a cheap `isAvailable()` check so setup validation and host selection can reject unsupported terminals early.
- Launch: create a new dedicated terminal context, inject the requested environment into the child shell, and run the provided command without requiring Spaces to synthesize host-specific shell glue outside the adapter.
- Identity: return a stable provider identity that Spaces can persist on runtime targets and process records, plus a separate hook attribution identity when the provider needs one.
- Current-context resolution: turn the current hook process environment into the attribution identity that the CLI should use for agent-event matching.
- Focus: refocus the tracked terminal target, not just the containing yabai window, so tabbed terminals reopen the exact tracked session or surface when possible.
- Reconciliation: enumerate live provider identities so Spaces can detect stale runtime records after users close windows manually.

Identity rules:
- yabai remains the source of truth for window IDs and cross-app focus.
- The terminal adapter may use a richer native identity for tracking, but that identity must be stable enough to survive normal reconciliation and refocus flows.
- If the terminal cannot provide a durable session identifier, the integration must still provide a deterministic fallback that maps back to the yabai-managed window.
- Current examples:
  `iTerm2` uses session identity for both attribution and focus, so the same provider identity usually satisfies both needs.
  `Ghostty` uses the real Ghostty terminal ID for focus and liveness, plus a separate Spaces-issued hook token for event attribution.
- Runtime target rows store a stable `name` for focus identity separately from a display `detail`, so CLI focus targets can stay deterministic while GUI rows still show live browser URLs, process commands, or terminal window titles.

Operational requirements:
- Workspace shell launch and process launch must both work through the same adapter surface.
- Process sessions must still run under tmux so terminal closure does not kill the underlying process.
- The adapter must tolerate background launch (`background: true`) because `spaces start`, `spaces restart`, and recovery flows may avoid stealing focus.
- The integration must not introduce window management outside yabai; any native terminal APIs are only for terminal-local actions such as opening, closing, or selecting a terminal target.

Implementation note:
- The shared launch and discovery contract now lives in `systembridge` as `TerminalAdapter`, and `WorkspaceOrchestrator` resolves `TerminalHost` to a concrete adapter through one registry.
- `TerminalAdapter.openWindowAndRun(...)` must inject any requested launch environment into the child shell process and return both the provider identity and the hook attribution identity needed by later reconciliation, focus, and agent-event flows.
- The shared focus contract now also requires host-specific refocus by typed tracking identity. iTerm2 implements that with session/tab selection, while Ghostty refocuses the tracked terminal by Ghostty terminal ID and only falls back to the yabai window when direct terminal focus fails.
- Richer iTerm2-only helpers can still exist outside the shared interface, but a new terminal should first conform to `TerminalAdapter` so launch, focus, and discovery all follow one path.

## Agent Integration
- Agent events are explicit CLI inputs that attach status to tracked workspace agent windows.
- `spaces signal` only resolves direct terminal environments. If the command is run from tmux, the CLI rejects it explicitly because Spaces does not support coding agents running inside tmux.
- Agent windows are stored separately from regular process windows because they carry provider and lifecycle metadata, but `init` also reconciles them against tracked terminal windows so ad-hoc agent terminals become focusable tracked rows.
- Configured agent-launcher names are treated as reserved focus labels. The launcher-owned agent instance may keep that exact label, while unrelated ad-hoc agents that report the same label are suffixed during registration so GUI rows and CLI focus targets stay unambiguous.
- Workspace launch now opens configured coding agents through the same direct-terminal path as manual agent launch. That creates the tracked agent rows eagerly, while later `spaces signal` calls still supply the actual lifecycle status.
- Alerts and numbered window shortcuts keep configured and ad-hoc agent rows in one `Coding Agents` section. Configured rows occupy their stable slots first, then unmatched ad-hoc agent rows append after them so shortcut ordering remains deterministic.
- Configured-agent relaunch is conservative: if a reserved row still points at a live tracked terminal, Spaces keeps that row and treats launch as a no-op. Only clearly stale rows are evicted and replaced.
- Agent reconciliation prefers terminal identity first:
  `iTerm2` uses the shell session ID from the environment.
  `Ghostty` keeps a Spaces-issued `terminalTrackingID` for CLI hook attribution, a separate `terminalNativeID` for the real Ghostty terminal, and a `terminalContainerID` for the Ghostty tab container used during teardown. Hook events only trust the tracking token; they do not infer the emitting shell from the frontmost Ghostty terminal or yabai window.
- Workspace-managed process terminals persist the tmux window ID on their running-process and tracked-window records so later agent events, reattachment, and exit cleanup can reconcile against the same process-backed terminal slot.
- When an agent attaches to a workspace-managed process terminal, the record keeps the tmux window ID so a later `exit` can keep an idle placeholder row instead of deleting it.
- Alerts attention state is derived from runtime records rather than inferred from UI state.
- `waiting` and `done` agent events both contribute alerts and dock attention until the user dismisses that specific attention event; the workspace row still renders the underlying agent status independently.

Ghostty-specific reconciliation:
- Ghostty AppleScript exposes stable terminal IDs through the window -> tab -> terminal graph, but does not reliably expose live terminal environment variables on current Ghostty builds.
- Because yabai window IDs can change when users retab or add tabs in Ghostty, Spaces treats the Ghostty terminal ID as the durable identity and yabai window IDs as refreshable focus bindings.
- Ghostty rows without a stored native terminal ID are not treated as live just because their tracking token still exists; only the real Ghostty terminal ID participates in liveness and retab rebinding.
- Background refresh keeps a tracked Ghostty row alive when its stored terminal ID still appears in Ghostty's live terminal graph, even if the previously stored yabai window ID has disappeared.
- Managed Ghostty terminals persist the Ghostty tab ID as `terminalContainerID` and re-resolve the current live tab by `terminalNativeID` before close/restart teardown. If older rows only have a `terminalNativeID`, Spaces recovers the current Ghostty tab from the live terminal graph instead of guessing from the focused yabai window.
- Later agent events can refresh metadata only when they present the stored tracking token and Spaces can unambiguously recover the existing native terminal ID from tracked rows.
- Focus is slightly more permissive than liveness for Ghostty: refocus still prefers `terminalNativeID`, but if the matching tracked terminal row has not been backfilled with that native ID yet, Spaces may fall back to the persisted `terminalTrackingID` for the same workspace row. This fallback is intentionally scoped to already-tracked rows and does not use the frontmost Ghostty terminal or a guessed yabai window.
- Alerts dismissals are stored as a persisted set of attention-event IDs in SQLite global settings, then filtered in the GUI so workspace detail panes keep showing the underlying runtime rows.

Terminal host notes:
- iTerm2 exposes a usable shell session ID directly (`ITERM_SESSION_ID`), so Spaces can rely on that same host-native identifier for launch tracking, hook attribution, liveness checks, and refocus.
- iTerm2 hook events without `ITERM_SESSION_ID` are treated as untracked and dropped rather than being rebound to the currently focused yabai window.
- Ghostty does not expose an equivalent shell-local native terminal ID to the running shell on this machine. That is why Ghostty needs the split between `terminalTrackingID` and `terminalNativeID`.
- Ghostty AppleScript can enumerate the real terminal graph and focus a terminal by Ghostty terminal ID, but it cannot safely tell Spaces which background shell emitted an `spaces signal`. That attribution must come from the Spaces-issued hook token.
- Ghostty direct-property or environment-variable AppleScript access has proven unreliable enough that Spaces should avoid new designs that depend on reading live terminal env vars back out of Ghostty.

## Lifecycle and Health
- Workspace lifecycle state is explicit and persisted on the workspace record.
- Runtime health is derived from runtime records, configured browser/process expectations, and agent waiting state.
- The GUI should render lifecycle state directly and layer runtime-health warnings on top instead of inferring lifecycle from stale runtime leftovers.

## Shortcut Architecture
- Shortcut defaults and user overrides are stored in SQLite global settings and edited from the GUI settings panel.
- Global shortcuts use Carbon hotkey registration for actions that must work while Spaces is not frontmost.
- The command palette is implemented as a separate AppKit panel instead of reusing the main split-view window, so the hotkey can surface a focused search field without depending on the full app shell staying visible.
- Command-palette items are built from two sources: Alerts attention entries and the same ordered workspace run-target model that powers workspace-detail numbered shortcuts. With an empty query, the panel shows Alerts attention first and then only the current workspace's run targets. Once the user types, the fuzzy matcher ranks across the full combined item set.
- Palette search uses a local multi-field fuzzy matcher over workspace title, target label, and detail text, then maps the selected row back onto the existing target-level focus/open request path.
- In-app shortcuts use an AppKit event monitor so they can respect focused text inputs and support digit-family shortcuts such as window `1` through `9`.
- Leader-based shortcuts store a suffix key spec and derive their shared modifiers from `gui_leader_hotkey`; the orchestrator resolves them to full effective hotkeys for both the GUI and CLI. Reload and the workspace terminal action use this same leader-backed resolution path.
- Window focus shortcuts are modeled as a modifier family rather than nine separate persisted bindings, with digits `1` through `9` sharing one direct-focus binding.
- Alerts shares the same direct-focus shortcut family as workspace detail, and those focus shortcuts take precedence over Alerts-local create actions while Alerts is visible.

## Performance Principles
- Focus and capture paths should avoid unnecessary blocking work.
- Hot paths that do not need stdout or stderr should use lightweight process spawning.
- Long-running GUI actions should execute off the main thread and reconcile state back into the UI afterward.

## External Dependencies
- macOS 14+
- yabai for window identity and focus
- tmux for recoverable terminal-hosted process sessions
- iTerm2 or Ghostty for terminal process hosting
- Google Chrome for browser-session automation
- SQLite for local persistence
