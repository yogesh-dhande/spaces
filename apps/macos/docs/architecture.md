# Architecture

## Overview
`muxy` is a macOS Swift app for stream-based workspace orchestration. A stream is a captured set of windows tied to a workspace. YAML is the source of truth for global settings and project templates, while SQLite stores runtime state plus per-workspace settings that are not written back to YAML.

Key invariants:
- YAML config is the source of truth for global settings and project templates and is normalized on load.
- Workspace settings are stored in SQLite and seeded from project templates; no YAML workspace overrides exist.
- SQLite stores runtime state and can be recreated when the schema version changes (workspace settings are re-seeded from templates).
- yabai is the source of truth for window IDs and focus.
- Stream capture must happen before a stream is shown or focused.
- Avoid window-level automation outside yabai.
- Local key monitors must not override standard text-edit shortcuts while an input has focus.

## Module Map
```mermaid
flowchart LR
  cli["muxy (CLI)"] --> stream["streamctl"]
  guiapp["MuxyApp (App entrypoint)"] --> gui["gui (AppKit UI)"]
  gui --> stream

  stream --> config["YAML config"]
  stream --> db["SQLite runtime DB"]
  stream --> appctl["appctl (system adapters)"]
  stream --> git["Git client"]
  stream --> editor["Editor launcher"]

  appctl --> yabai["yabai"]
  appctl --> iterm["iTerm2 (AppleScript)"]
  appctl --> chrome["Chrome (AppleScript)"]
```

Module responsibilities:
- `appctl`: Shell + AppleScript adapters for yabai, iTerm2, and Chrome.
- `streamctl`: Orchestration, config normalization, named port allocation (via `PortAllocator` and `PortReserver`), workspace lifecycle, and persistence.
- `gui`: AppKit UI library that calls into `streamctl`.
- `muxy`: CLI entrypoint that calls into `streamctl`.
- `MuxyApp`: GUI executable entrypoint that wires `NSApplication` to the `gui` library.

The `gui` target is the reusable UI library. `MuxyApp` is the minimal executable that boots AppKit and delegates to `gui`.

GUI interaction notes:
- Right-pane forms are hosted in a scroll view so long forms do not clip at smaller window heights.
- The "new workspace" affordance is shown in project UI only when the project is a git repository.
- New workspace forms use separate target-branch, branch-name, and workspace-name fields for git projects.
- Target branch is first and uses a searchable branch list.
- Target branch defaults to `main`/`master` when available.
- Workspace name auto-fills from branch while untouched, and can then be edited independently.
- New workspace forms also include an optional git-only worktree directory-name override.
- Directory-name overrides are validated to filesystem-safe ASCII (`A-Z`, `a-z`, `0-9`, `-`, `_`) and cannot contain spaces.
- For git projects, branch is required when creating a workspace.
- Newly created branches are based on the latest commit of the selected target branch.
- If the requested branch exists only on remote, the orchestrator fetches it into `refs/remotes/origin/*` before creating the worktree from `origin/<branch>`.
- If the requested branch exists locally, the local branch is used as-is (no implicit pull/rebase/merge in workspace creation).
- Workspace rows use compact card styling with status + workspace name on top.
- Workspace metadata rows show folder and branch labels with icons only when those values differ from workspace name.
- Git workspace rows include relative last-modified time (from latest tracked-file mtime) and tracked modified-file count.
- Window focus shortcuts in the GUI use `cmd+1` through `cmd+9`.
- Port definitions are editable via `PortEditor` in the project detail view, the add-project form, and workspace settings.
- Status checks are configured inline under each process in the `ProcessEditor` rather than in a separate form section; the process name is implicit from the parent row.
- The run tab displays status check results as indented sub-rows under each process with colored dots (green/red) instead of inline badge text.
- Keyboard shortcut overrides for GUI actions are persisted in SQLite settings and editable in the GUI Settings view and CLI settings commands.
- The app provides a standard Edit menu with Copy (Cmd+C) and Select All (Cmd+A) for system clipboard support in read-only text views.

## Data Model
Config file:
- Path: `~/.muxy/config.yaml`.
- Top-level fields: `editor`, `port_range`, `projects`.
- The GUI Settings view writes `editor` from installed VS Code, Cursor, or Windsurf.
- Project fields: `dir`, `setup_script`, `stop_script`, `ports` (named port definitions), `processes`, `status_checks`, `browser_sessions`.
- Script timing:
  - `setup_script` runs when a workspace is created or revived.
  - `stop_script` runs on stop/restart/archive stop phase after automatic process termination.
- New projects can be created from an existing directory or by cloning a repository into `/Users/<username>/muxy/projects/<project_name>`.
- Removing a project clears muxy state. For git projects, muxy first removes managed worktrees with `git worktree remove --force`, then deletes related workspace directories under `/Users/<username>/muxy/workspaces`.
- The project directory is deleted only for git projects located under `/Users/<username>/muxy/projects` (app-managed clones).

Workspace settings:
- Each workspace snapshots project `stop_script`, `ports` (named port definitions), `processes`, `status_checks`, and `browser_sessions` at creation.
- Snapshots are stored in the runtime DB alongside other workspace data.
- Edits are stored in SQLite only; YAML remains unchanged.
- Edits to a running workspace reconcile processes and browser sessions immediately.

Runtime database:
- Path: `~/.muxy/muxy.db`.
- Schema is recreated when `schema_version` changes; workspace settings are re-seeded from project templates as needed.

```mermaid
erDiagram
  projects ||--o{ workspaces : has
  workspaces ||--o{ workspace_port_definitions : defines
  workspaces ||--o{ workspace_ports : allocates
  workspaces ||--o{ workspace_settings : config
  workspaces ||--o{ workspace_processes : overrides
  workspaces ||--o{ workspace_status_checks : overrides
  workspaces ||--o{ workspace_browser_sessions : overrides
  workspaces ||--o{ running_processes : runs
  running_processes ||--o{ status_results : checks
  workspaces ||--o{ windows : captures

  projects {
    TEXT id PK
    TEXT name
    TEXT dir
    INTEGER is_git
    TEXT default_branch
  }

  workspaces {
    TEXT id PK
    TEXT project_id
    TEXT name
    TEXT dir
    TEXT dirname
    TEXT branch
    INTEGER is_default
    INTEGER is_archived
    INTEGER is_running
    TEXT last_launched_at
  }

  workspace_port_definitions {
    TEXT id PK
    TEXT workspace_id
    TEXT name
    INTEGER order_index
  }

  workspace_ports {
    TEXT workspace_id PK
    INTEGER port_index PK
    TEXT port_name
    INTEGER port_number
  }

  workspace_settings {
    TEXT workspace_id PK
    TEXT updated_at
    TEXT stop_script
  }

  workspace_processes {
    TEXT id PK
    TEXT workspace_id
    TEXT name
    TEXT command
    INTEGER order_index
  }

  workspace_status_checks {
    TEXT id PK
    TEXT workspace_id
    TEXT name
    TEXT process
    TEXT command
    INTEGER interval
    INTEGER timeout
    TEXT on_exit
    INTEGER order_index
  }

  workspace_browser_sessions {
    TEXT id PK
    TEXT workspace_id
    TEXT url
    TEXT extracted_target_url
    INTEGER extracted_window_id
    INTEGER extracted_window_valid
    INTEGER order_index
  }

  running_processes {
    TEXT id PK
    TEXT workspace_id
    TEXT template_name
    TEXT command
    TEXT terminal_app
    INTEGER window_id
    INTEGER pid
    TEXT status
    TEXT log_path
    TEXT last_output_at
    TEXT started_at
    TEXT exited_at
  }

  status_results {
    TEXT process_id PK
    TEXT check_name PK
    TEXT status
    TEXT message
    TEXT last_run_at
  }

  windows {
    TEXT id PK
    TEXT workspace_id
    TEXT app
    TEXT title
    TEXT target_url
    INTEGER window_id
    TEXT role
    INTEGER order_index
    TEXT last_seen_at
  }

  settings {
    TEXT key PK
    TEXT value
  }

  schema_version {
    INTEGER version
  }
```

## Workspace Lifecycle
Create and prepare a workspace:
```mermaid
flowchart TD
  start["Create workspace"] --> git{"Project is git repo?"}
  git -->|"yes"| dirname["Resolve dirname (override or auto-generated)"]
  dirname --> worktree["Create or reuse worktree"]
  git -->|"no"| dir["Use project dir"]
  worktree --> ports["Allocate named ports (PortReserver)"]
  dir --> ports
  ports --> setup["Run setup_script (if set, with named port env vars)"]
  setup --> persist["Persist workspace + port definitions + ports"]
```

Port allocation details:
- `PortAllocator.allocatePorts` accepts `definitions: [PortDefinition]` (named port definitions from the project or workspace) instead of a fixed count.
- Ports are allocated at workspace creation and persisted in the `workspace_ports` table; they are available immediately (including during the setup script).
- `PortReserver` (singleton) re-reserves allocated ports via OS sockets on app launch so they cannot be claimed by other processes between allocation and use.
- Ports are released when a workspace is archived.
- Port definitions are configured at the project level in YAML (under a `ports` list) and inherited by workspaces; workspaces can override definitions.
- Named ports appear as env vars in setup scripts, stop scripts, process commands, and status check commands (e.g. `$FRONTEND_PORT`, `$API_PORT`).
- `buildWorkspaceEnv` uses named port keys from definitions instead of anonymous `PORT0`, `PORT1`, etc.
- `buildWorkspaceEnv` sets `MUXY_WORKSPACE_DIR` (workspace directory) and `MUXY_PROJECT_DIR` (project directory) for every workspace process.

Launch and capture windows:
```mermaid
flowchart TD
  launch["Launch workspace"] --> processes["Start processes in iTerm2"]
  processes --> browser["Open browser sessions in Chrome"]
  browser --> editor["Open editor (if configured)"]
  editor --> capture["Capture window IDs via yabai"]
  capture --> store["Store windows in DB"]
```

Stop or archive:
- Stop: signal each tracked process group (`SIGINT` then `SIGTERM`), then run workspace `stop_script` (if set), then close tracked windows and clear runtime process state.
- Archive: reuse stop flow, run `git worktree remove --force` for git projects, release ports.
- Archive never deletes the project directory for non-git projects.
- Browser safety invariant: stop/restart/settings reconciliation closes tracked Chrome tabs by URL prefix, never full Chrome windows.

Run/recovery semantics:
- `launchWorkspace` is only for stopped workspaces. If `is_running` is set or runtime indicators already exist (`running_processes`/`windows` rows), launch fails with "use restart".
- `restartWorkspace` is the explicit recovery path and always performs stop then launch for the same workspace.
- Workspace lifecycle actions are guarded by a per-workspace in-flight lock so overlapping launch/stop/restart/archive actions cannot run concurrently for the same workspace.
- GUI run controls are state-aware: show `Launch` when stopped and `Restart` when running.
- AppKit launch/restart/stop/archive button handlers dispatch lifecycle work in detached background tasks (fresh orchestrator/store instances) so long-running automation does not block the UI event loop.

Degraded runtime edge cases and handling:
- `is_running` can drift from real OS state because users can close windows/processes manually.
- Restart is the user-visible "bring everything back" action for partial or stale runtime state.
- Chrome session discovery and focus are URL-prefix based end-to-end; title-based fallback matching is intentionally avoided to prevent binding sessions to the wrong tab.
- On launch/restart, muxy reuses existing Chrome tabs whose URLs match configured browser-session prefixes and tracks all matching tabs for workspace cycling.
- On launch/restart, muxy may extract one matching tab per browser session into a dedicated Chrome window and persist that extracted mapping (`extracted_target_url`, `extracted_window_id`, `extracted_window_valid`).
- Browser windows store an optional `target_url`; when focusing browser entries, muxy uses AppleScript to activate the matching tab (including when multiple tracked targets share one Chrome window) before falling back to raw window focus.
- Browser focus first attempts extracted-window `yabai` focus when a valid extracted mapping exists; if the window is missing or active-tab verification fails, the mapping is marked stale (`extracted_window_valid=0`) and focus falls back to indexed-tab/URL-prefix paths without automatic re-extraction.
- If a Chrome window is tracked both as targeted browser tabs and as an untargeted browser row, untargeted rows are filtered from workspace window navigation/listing to keep forward/backward traversal deterministic.
- Workspace window navigation/listing rebuilds browser rows from live Chrome tab scans with a configurable debounce interval (default: 10 seconds, see `PollingConstants.browserWindowScanDebounceInterval`) per `(workspace_id, resolved browser-session prefixes)` key, including every tab whose URL starts with any configured browser-session URL (deduplicated by `window_id + tab URL`); tabs with missing URLs are skipped.
- Browser focus for live-scanned rows targets cached `(window_id + tab_index)` first, then verifies the focused active tab URL against workspace prefixes, refreshes the live scan once on mismatch, and falls back to URL matching if needed.
- Window-scoped Chrome AppleScript operations compare `window_id` as string for reliable tab focus/close matching.
- Live browser rows are ordered deterministically by browser-session prefix order and then tab URL so `cmd+<n>` shortcut indices stay aligned with the on-screen list even as Chrome window z-order changes.
- Window cycling tracks a workspace-local navigation pointer, and Chrome row resolution uses the frontmost active tab URL with prefix checks to keep next/previous stable.
- Window cycling order is role-grouped for consistency: all browser tabs first, then terminal windows, then other window roles. Relative navigation prefers the remembered workspace-local index once cycling begins.
- Global next/previous shortcut routing resolves focused Chrome windows by `(window_id + active tab URL prefix)` so one reused Chrome window can be safely tracked by multiple workspaces without selecting the wrong workspace.
- Optional diagnostics: `DEBUG=1` logs browser tab scan count/match/elapsed and browser focus-path timing, including indexed verification, cache hit/miss, refresh, and fallback decisions.
- Performance benchmarking: `OrchestratorTests.testBenchmarkChromeIndexedTabFocusVsYabaiWindowFocusForExtractedTabs` uses calibrated delays (~52ms tab-index focus + ~38ms active-tab verify vs ~42ms extracted-window yabai focus) and currently reports break-even at about 15 switches after extraction setup.
- Terminal capture uses both yabai snapshot-diff and running-process window IDs to avoid dropping terminals when window discovery lags.
- Editor capture during launch uses yabai snapshot-diff first, then falls back to the currently focused editor window when launch reuses an existing editor window so it still participates in workspace cycling.
- Editor capture/matching supports known editor app-name aliases from yabai (for example VS Code may appear as `Code`) so editor rows remain eligible for next/previous cycling.
- Window IDs can become stale across app/desktop changes; stale rows are pruned during reconciliation paths.
- The GUI starts a periodic detached utility-priority refresh loop (`refreshAllWorkspaceWindows`) so non-archived workspace window rows are reconciled in the background on a fixed interval (`PollingConstants.workspaceWindowRefreshInterval`).
- Each background refresh pass uses a fresh orchestrator/store instance for thread-safe off-main reconciliation and keeps AppKit interaction responsive while refresh is in-flight.
- UI data is reloaded after successful periodic refresh passes only when the user is not actively editing text fields (to avoid interrupting unsaved form edits).
- `refreshAllWorkspaceWindows` returns a `RefreshResult` containing `didMutateDB` (whether windows were pruned or workspace running flags changed) and `trackedWindowCounts` (per-workspace tracked window counts including live browser scan results); the GUI compares both against the previous snapshot and skips `reloadData()` entirely when nothing changed, avoiding unnecessary UI rebuilds.

## Window Capture and Focus
```mermaid
sequenceDiagram
  actor User
  participant GUI
  participant Orchestrator
  participant Iterm2
  participant Chrome
  participant Yabai
  participant DB

  User->>GUI: Launch workspace
  GUI->>Orchestrator: launchWorkspace(...)
  Orchestrator->>Iterm2: open terminals (AppleScript)
  Orchestrator->>Chrome: open sessions (AppleScript)
  Orchestrator->>Yabai: query windows
  Orchestrator->>DB: store window IDs

  User->>GUI: Focus window (hotkey)
  GUI->>Orchestrator: focusWorkspaceWindow(...)
  Orchestrator->>Chrome: focus tab by target_url (browser entries)
  Orchestrator->>Yabai: focusWindow(id) fallback
```

Editor and terminal windows opened from the GUI (Open Editor/Open Terminal) are captured via yabai and stored in the
windows table so they participate in workspace window cycling.

## Polling Constants
All periodic polling intervals are centralized in `PollingConstants.swift` for easy configuration:

- **Browser window scan debounce**: `browserWindowScanDebounceInterval` = 10 seconds
  - Controls how frequently Chrome tab scans are performed per workspace/browser-session-prefix combination
  - Used to debounce expensive Chrome AppleScript queries during window navigation and focus operations

- **Status check default interval**: `statusCheckDefaultInterval` = 60 seconds
  - Default interval between status check executions for process health monitoring
  - User-configurable per status check in the GUI

- **Status check default timeout**: `statusCheckDefaultTimeout` = 5 seconds
  - Default timeout for status check command execution
  - User-configurable per status check in the GUI

These constants are referenced throughout the codebase to ensure consistent polling behavior.

## External Dependencies
- macOS 14+
- `yabai` for window IDs, focus, and display/space metadata
- iTerm2 for terminal processes
- Google Chrome for browser sessions
- Yams for YAML config parsing and encoding
- SQLite3 for runtime persistence

### yabai Dependency Analysis

Muxy uses 7 distinct yabai commands across 35+ call sites via `YabaiAdapter`:

| Command | Purpose | Call Sites |
|---------|---------|------------|
| `query --windows` | List all windows (snapshot-diff capture) | ~13 |
| `query --windows --window` | Get focused window | ~5 |
| `query --windows --space <N>` | List windows in a space | ~1 |
| `query --spaces` | List spaces across displays | 1 |
| `query --displays` | List all displays | 1 |
| `window --focus <ID>` | Focus a window by ID | 2 |
| `window --close <ID>` | Close a window by ID | 1 |

**Core usage patterns:**
1. **Snapshot-diff capture** — list windows before an action, list after, diff to find newly created windows. Used for terminal, editor, and browser window capture during launch.
2. **Window focus fallback** — after AppleScript-based browser focus attempts, yabai provides reliable cross-app window-level focus.
3. **Window cleanup** — close tracked non-browser windows on workspace stop.
4. **Space/display enumeration** — populate configuration UI dropdowns.

**Replacement feasibility (tested against real system):**

`CGWindowListCopyWindowInfo` returns the same integer window IDs as yabai (`kCGWindowNumber` == yabai `id`), so the snapshot-diff pattern could use CGWindowList for discovery. However, CGWindowList lacks `title`, `space`, `display`, `is-visible`, `is-sticky`, and `is-native-fullscreen` fields that yabai provides.

| Feature | macOS API Alternative | Viable? |
|---------|----------------------|---------|
| Window discovery/listing | `CGWindowListCopyWindowInfo` | Partial — IDs match, but no title/space/display |
| App-level focus | `NSRunningApplication.activate()` | Yes — but focuses app, not specific window |
| Window-level focus | Accessibility API (AXUIElement raise) | Unreliable across apps; yabai is the only reliable option |
| Space assignment | None (private SPI only) | No public API |
| Display assignment | Geometry matching via `kCGWindowBounds` | Fragile workaround |
| Window close | AX close button / AppleScript | Feasible but more complex |
| Window title | AX `kAXTitleAttribute` | Requires Accessibility permission per app |

**Conclusion:** yabai cannot be fully replaced with public macOS APIs. The critical gaps are window-level focus (vs app-level), space index assignment, and reliable cross-app window title access. The query side could be partially replaced by CGWindowList for ID-based snapshot-diff, but mutations (`--focus`, `--close`) and space/display metadata have no equivalent.
