# Muxy

`mx` is a local macOS control plane for workspace orchestration.
It manages projects, workspaces, processes, and window sets so you can move between coding contexts quickly.

## Docs
- Architecture: `docs/architecture.md`
- Specification: `spec.md`

## Requirements
- macOS 14+
- `yabai` installed and running (window IDs and focus)
- iTerm2 (terminal windows)
- Google Chrome (browser sessions)
- Accessibility permissions granted for window focus and control

## Configuration
- DB: `~/.muxy/muxy.db` — all model data and global preferences (projects, templates, workspaces, ports, windows, settings, editor, port range)
- Managed git repos (from `mx project add --git-url`): `/Users/<username>/muxy/repos/<project_name>` (bare repo)
- Git worktrees: `/Users/<username>/muxy/workspaces/<projectname>/<dirname>` (dirname defaults to a unique food name and can be overridden on workspace creation)
- GUI shortcuts (when focused): `cmd+1` through `cmd+9` focus workspace windows
- Global window navigation (when GUI not focused): `cmd+shift+]` and `cmd+shift+[`

Global preferences are stored in the DB and configurable via `mx settings set` or the GUI Settings (⌘,):
- `editor`: preferred editor for `mx workspace open-editor` (`none`, `vscode`, `cursor`, `windsurf`, `vim`)
- `port_range`: range for workspace port allocation (default `20000-30000`)

```
mx settings set --editor vscode
mx settings set --port-range 20000-30000
mx settings get --editor
mx settings get --port-range
```

> **Note:** If you have an existing `~/.muxy/config.yaml`, its `editor`, `port_range`, and any legacy `projects:` entries are automatically migrated to the database on first launch. The YAML file is then ignored and can be deleted.

SQLite startup migrations are additive and preserve existing data, including backfilling legacy status-check `on_fail` columns with default `none` when missing.

Projects and all project templates (processes, status checks, browser sessions, port definitions, setup/stop scripts) are stored in the SQLite database. SQLite connections use WAL mode and a busy timeout to reduce transient `database is locked` failures during concurrent background actions. Use `mx project add` or the GUI to add projects.
Browser sessions support optional names (same pattern as process names) so workspace window rows can show stable labels instead of only raw URLs.

Port definitions are configured at the project level and inherited by workspaces. Each named port (e.g. `FRONTEND_PORT`) is allocated a real port number from the configured `port_range`, reserved via OS sockets so no other process can claim it. Named port env vars are available in setup scripts, stop scripts, process commands, and status check commands. Workspaces can override port definitions in their settings.

Workspaces snapshot project port definitions, processes, status checks, and browser sessions at creation time into the runtime DB.
Updates to workspace settings apply immediately when the workspace is running (new processes start, changed commands restart, and new browser sessions open).
Workspace settings include the workspace title and tooltip; non-default workspace titles can be edited after creation.
`setup_script` runs when a workspace is created or revived. In the GUI create flow, workspace records are persisted first and setup continues in the background so new workspaces appear faster; launch waits for setup completion and surfaces setup failures. `stop_script` runs on stop/restart/archive after automatic process termination. If the workspace directory is missing, muxy still completes stop/archive cleanup and skips the stop script.
Muxy periodically discovers and reconciles git worktrees for existing projects. Discovery auto-registers untracked valid worktrees (running the same `setup_script` flow for each new workspace), archives non-default workspaces whose worktrees are no longer valid, refreshes stored workspace branch names from on-disk worktrees, and will not auto-recreate workspaces you explicitly deleted from Muxy.

## GUI
- Two panes: projects/workspaces on the left, details on the right.
- On startup, the details pane shows a loading message and spinner while initial projects/workspaces are loaded in the background.
- Global hotkeys are available immediately at startup (before data hydration completes) so focus/show actions are not delayed.
- Startup background reconciliation updates the sidebar via async snapshots to keep workspace switching responsive while launch tasks are still running.
- No dialogs for add/edit; all forms are in the right pane.
- Right-pane forms are scrollable to avoid clipping on smaller window heights.
- New workspace `+` actions open the New Workspace form for git projects.
- `cmd+n` opens the New Workspace form for the currently selected project/workspace.
- On the New Workspace form, `cmd+n` quick-creates using generated defaults (suggested title/branch, auto-generated directory, default target branch).
- The New Workspace header shows a `cmd+n` hint for quick-create with generated names.
- `cmd+n` form-open and quick-create paths are optimized to avoid blocking remote branch lookups; branch options are loaded from local refs first and refreshed asynchronously, and suggested workspace names come from cached local workspace state.
- For git projects, the New Workspace form starts with only the branch input visible; target branch/title/directory/tooltip are progressively revealed after branch typing begins.
- New Project starts with only source selection (directory picker or git URL); setup script, ports, processes, browser sessions, and stop script are shown after source input is provided.
- New Project and New Workspace forms support keyboard shortcuts (`Return` to create, `Esc` to cancel); Create labels omit shortcut text while Cancel keeps `(Esc)` in the label.
- Primary create/save actions use a shared high-contrast style (darker accent background with white text/icons) for consistent readability.
- Branch and tooltip can be edited from inline labels in workspace detail, title can be edited in the workspace header, and all metadata can be edited via `mx workspace update`.
- Workspace title stays in the top header (`project / workspace`) and is editable there via double-click.
- Workspace detail also shows inline branch and tooltip labels above Launch/Stop actions; double-click a label to edit and reveal small Save/Cancel controls.
- While editing inline metadata, pressing `Escape` or clicking outside the inline controls cancels without saving.
- Changing branch name from the inline editor renames the underlying git worktree branch (not metadata-only).
- New branches are created from the latest commit on the selected target branch.
- If the selected branch exists only on remote, muxy fetches it first and then creates the worktree from `origin/<branch>`.
- If the branch exists locally, muxy uses the local branch as-is (no implicit pull/rebase/merge during workspace creation).
- Project rows in the left pane show a folder icon next to the project name.
- Workspace rows in the left pane use compact cards with workspace status + name.
- Git workspace rows also show ahead/behind commit counts relative to the workspace target branch (the branch the workspace branch was created from), merge-conflict status, and relative last-modified time (latest tracked-file mtime) with tracked modified-file count.
- Workspace detail branch metadata shows `current-branch (forked from target-branch)` when a target branch exists and differs.
- Workspace view includes:
  - Launch/Restart/Stop/Archive buttons
  - Launch/Restart/Stop/Archive actions run in background tasks so the UI stays responsive during long-running workspace automation
  - Open Editor/Terminal/Finder buttons (terminal windows are tracked for cycling)
  - Workspace window records are refreshed periodically in a background pass so stale closed windows are pruned without blocking interaction
  - The same refresh pass updates terminal window fallback labels (title/app) from live yabai data when that terminal window is not linked to a running process record
  - Launch/Restart can extract one matching tab per browser session into a dedicated Chrome window and persist extracted-window mappings for faster focus
  - Browser focus tries extracted-window `yabai` focus first; stale mappings are invalidated and fallback continues via indexed tab focus + URL matching (without automatic re-extraction)
  - Launch/Restart reuses existing matching Chrome tabs and tracks all matches instead of opening duplicate tabs when matches already exist
  - Stop/Restart/browser-session updates close tracked Chrome tabs only and never close full Chrome windows
  - If a workspace directory is missing during stop, muxy still stops the workspace and shows an informational message that stop-script execution was skipped
  - Workspace window list/navigation rebuilds browser rows from Chrome tabs with a 10-second debounce (per workspace/prefix set) and includes tabs whose URLs start with configured browser session URLs (deduped by window+tab URL)
  - Browser focus targets cached tab index first, validates the active tab URL against workspace prefixes, refreshes once on mismatch, and falls back to URL matching if tab positions changed
  - Window-scoped Chrome tab focus/close uses string-based window-id checks in AppleScript for reliable matching
  - Browser tab rows are sorted by configured browser-session order and then URL so shortcut indices remain stable
  - Browser session names are optional but preferred for display labels in workspace window rows; when present, rows show `name + URL` in the same split-label style as process rows
  - Window cycling order is browser tabs first, then terminals, then other windows; once cycling starts, next/previous uses remembered cycle position
  - Global next/previous window navigation disambiguates reused Chrome windows by active tab URL, so shortcuts stay on the correct workspace
  - Process restarts (status-check failure or `on_exit=restart`) terminate and wait for the tracked runtime PID before relaunch; if a clean stop does not finish in time, muxy restarts in a new terminal window instead of queueing in the busy one
  - Processes with status check results shown as indented sub-rows (colored dots)
  - Status checks run in periodic background monitoring for running workspaces (respecting each check interval), so health rows and on-fail restarts update even when the run tab is not open
  - Windows list with shortcut hints
  - Env vars/ports tab
  - Workspace settings tab
- Settings view lets you choose a preferred editor from installed VS Code, Cursor, or Windsurf.
- Settings view also lets you override default keyboard shortcuts for app actions.
- New workspace `+` actions are shown for git projects only.

Hotkeys:
- Global focus: `cmd+shift+=`
  - Brings muxy to front and keeps current window-selection shortcuts active; workspace-window reconciliation runs on the periodic background interval
  - Defers selected-workspace detail refresh to the next main-actor turn so focus feels immediate
- Next running workspace: `cmd+shift+]`
- Previous running workspace: `cmd+shift+[`
- Focus selected workspace: `cmd+shift+return`
- Open editor (global): `cmd+shift+e` (opens editor for the workspace owning the focused workspace window)
- Open terminal: `cmd+shift+t`
- Open Finder: `cmd+shift+f`
- Focus workspace window 1-9: `cmd+1` through `cmd+9`

When text input is focused in the GUI, standard editing shortcuts (including `cmd+v`) are handled normally.

Set `DEBUG=1` when launching Muxy to log browser scan timing and browser-focus path/timing (indexed verify, refresh, cache hits/misses, and URL fallback decisions) to stderr.

Browser switching benchmark:
- `OrchestratorTests.testBenchmarkChromeIndexedTabFocusVsYabaiWindowFocusForExtractedTabs` compares calibrated indexed-tab switching (~52ms tab-index focus + ~38ms active-tab verification) against extracted-window focus (~42ms `yabai`), and prints average switch timings plus estimated break-even switch count (currently ~15 switches).
- Run it with:
  - `scripts/swiftpm.sh test --filter OrchestratorTests/testBenchmarkChromeIndexedTabFocusVsYabaiWindowFocusForExtractedTabs`

## Auto-Update
Muxy checks for updates from the appcast feed on launch and every 4 hours. Use the app menu **Check for Updates...** to check manually.

When an update is available, a CTA button appears at the top of the left panel. Clicking it downloads the DMG, installs the app to /Applications, and relaunches.

From the CLI:
```bash
mx --version
```

## CLI
```bash
mx settings get --editor
mx settings get --port-range
mx settings set --editor vscode
mx settings set --port-range 20000-30000

mx project list
mx project add --dir /path/to/repo
mx project add --git-url https://github.com/org/repo.git
mx project update --dir /path/to/repo --setup-script "cp ~/.env .env" --stop-script "docker compose down --remove-orphans"
mx project remove --dir /path/to/repo
mx project browser-session add --dir /path/to/repo --url http://localhost:3000 --name frontend
mx project browser-session list --dir /path/to/repo
mx project browser-session remove --dir /path/to/repo --url http://localhost:3000

mx workspace list --project-dir /path/to/repo --all
mx discover
mx workspace create --project-dir /path/to/repo --name feature-x [--branch feature-branch] [--target-branch main] [--directory-name feature_branch]
mx workspace import [--dir /path/to/worktree] [--title feature-y] [--tooltip "Working on auth"]
mx workspace update --dir /path/to/workspace [--title feature-y] [--branch feature-y] [--directory-name feature_y] [--tooltip "Working on auth" | --clear-tooltip]
mx workspace launch --dir /path/to/workspace
mx workspace restart --dir /path/to/workspace
mx workspace up --dir /path/to/workspace [--restart] [--tooltip "Working on auth flows"]
mx workspace stop --dir /path/to/workspace
mx workspace archive --dir /path/to/workspace
mx workspace focus --dir /path/to/workspace [--window 2]
```

For git projects, `workspace create` requires `--branch`; `--target-branch` defaults to `main`/`master` when available.
`workspace create --directory-name` (alias: `--dirname`) is optional for git projects and must use only letters, numbers, `-`, and `_` with no spaces.
`workspace import` supports `--title` (preferred; `--name` also accepted for backward compatibility) and optional `--tooltip`.
`workspace update` updates workspace metadata (`--title`, `--branch`, `--directory-name`/`--dirname`/`--dir-name`, and tooltip values). Default workspaces keep their fixed initial title (`default` for directory projects, `main`/`master` for git-url imports).
`workspace up` is idempotent: it launches a stopped workspace, and otherwise does nothing by default.
Add `--restart` to force stop+launch when runtime state is already present.
`workspace up` always focuses the workspace, and `--tooltip [text]` displays the tooltip overlay after focus (updating tooltip text when text is provided).
`mx discover` scans all registered git projects and reconciles worktrees by creating missing workspaces, archiving workspaces whose worktrees are no longer valid, and refreshing workspace branch names from disk.
When tooltip overlay is shown for focused workspace, it always displays workspace title as the title; when tooltip text is set, it is shown as body content.

Project/workspace removal behavior:
- `mx project remove --dir <path>` removes the project from Muxy. For git projects, it first removes related managed worktrees with `git worktree remove --force`, then deletes related workspace directories under `~/muxy/workspaces`.
- `mx project remove --dir <path>` deletes the project directory only when it is a git repo inside `~/muxy/repos` (or legacy `~/muxy/projects`) as an app-managed clone location.
- `mx workspace archive ...` removes git worktrees via `git worktree remove` and never deletes the project directory for non-git projects.

## Build
Use the SwiftPM wrapper to keep caches inside the workspace (avoids user cache warnings in sandboxed environments).
```bash
scripts/swiftpm.sh build
```

## Tests
```bash
scripts/swiftpm.sh test --parallel
```

## Lint
```bash
scripts/lint.sh
```

## Coverage
```bash
scripts/coverage.sh
```

Test-speed knobs:
- `scripts/coverage.sh` runs tests in parallel by default.
- `scripts/coverage.sh` auto-detects logical CPU count for `--num-workers`.
- Set `MUXY_TEST_WORKERS=<n>` to override worker count.
- Set `MUXY_TEST_SKIP_BUILD=1` for faster repeated local coverage reruns when build artifacts are already current.
- Set `MOCK_TEST_DELAY_CAP_MS=<ms>` to cap mock-script sleeps used by orchestrator tests.

## Release


The release workflow:
1. Builds in release configuration
2. Code-signs `Muxy` app and `mx` CLI
3. Creates a DMG installer with app bundle and CLI installer
4. Optionally notarizes the DMG
5. Uploads to Firebase Hosting with long cache headers
6. Generates and uploads appcast.xml with no-cache headers

Required secrets:
- `CODESIGN_IDENTITY`: Developer ID Application certificate
- `APPLE_ID`, `TEAM_ID`, `APP_PASSWORD`: For notarization
