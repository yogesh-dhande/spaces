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
- Cloned projects: `/Users/<username>/muxy/projects/<project_name>`
- Git worktrees: `/Users/<username>/muxy/workspaces/<projectname>/<dirname>` (dirname defaults to a unique food name and can be overridden on workspace creation)
- GUI shortcuts (when focused): `cmd+1` through `cmd+9` focus workspace windows
- Global window navigation (when GUI not focused): `cmd+shift+]` and `cmd+shift+[`

Global preferences are stored in the DB and configurable via `mx config set` or the GUI Settings (⌘,):
- `editor`: preferred editor for `mx workspace open-editor` (`none`, `vscode`, `cursor`, `windsurf`, `vim`)
- `port_range`: range for workspace port allocation (default `20000-30000`)

```
mx config set --editor vscode
mx config set --port-range 20000-30000
mx config show
```

> **Note:** If you have an existing `~/.muxy/config.yaml`, its `editor`, `port_range`, and any legacy `projects:` entries are automatically migrated to the database on first launch. The YAML file is then ignored and can be deleted.

Projects and all project templates (processes, status checks, browser sessions, port definitions, setup/stop scripts) are stored in the SQLite database. Use `mx project add` or the GUI to add projects.

Port definitions are configured at the project level and inherited by workspaces. Each named port (e.g. `FRONTEND_PORT`) is allocated a real port number from the configured `port_range`, reserved via OS sockets so no other process can claim it. Named port env vars are available in setup scripts, stop scripts, process commands, and status check commands. Workspaces can override port definitions in their settings.

Workspaces snapshot project port definitions, processes, status checks, and browser sessions at creation time into the runtime DB.
Updates to workspace settings apply immediately when the workspace is running (new processes start, changed commands restart, and new browser sessions open).
`setup_script` runs when a workspace is created or revived. `stop_script` runs on stop/restart/archive after automatic process termination.

## GUI
- Two panes: projects/workspaces on the left, details on the right.
- No dialogs for add/edit; all forms are in the right pane.
- Right-pane forms are scrollable to avoid clipping on smaller window heights.
- New workspace form has separate inputs for target branch, branch name, and workspace name for git projects.
- Target branch is the first input and shows a searchable list of branches.
- Target branch defaults to `main`/`master` when available.
- Branch name is required for git projects.
- As you type branch name, workspace name is auto-populated from it by default; you can then edit workspace name to be more descriptive.
- Directory name is an optional git-only input that overrides the auto-generated worktree folder name.
- Directory name validation allows only letters, numbers, `-`, and `_` (no spaces).
- New branches are created from the latest commit on the selected target branch.
- If the selected branch exists only on remote, muxy fetches it first and then creates the worktree from `origin/<branch>`.
- If the branch exists locally, muxy uses the local branch as-is (no implicit pull/rebase/merge during workspace creation).
- Workspace rows in the left pane use compact cards with workspace status + name.
- Folder and branch labels (with icons) are shown only when those values differ from workspace name.
- Git workspace rows also show relative last-modified time (latest tracked-file mtime) and tracked modified-file count.
- Workspace view includes:
  - Launch/Restart/Stop/Archive buttons
  - Launch/Restart/Stop/Archive actions run in background tasks so the UI stays responsive during long-running workspace automation
  - Open Editor/Terminal/Finder buttons (editor/terminal windows are tracked for cycling)
  - Workspace window records are refreshed periodically in a background pass so stale closed windows are pruned without blocking interaction
  - Launch/Restart can extract one matching tab per browser session into a dedicated Chrome window and persist extracted-window mappings for faster focus
  - Browser focus tries extracted-window `yabai` focus first; stale mappings are invalidated and fallback continues via indexed tab focus + URL matching (without automatic re-extraction)
  - Launch/Restart reuses existing matching Chrome tabs and tracks all matches instead of opening duplicate tabs when matches already exist
  - If opening the preferred editor reuses an already-open editor window, launch captures the currently focused editor window so it is included in workspace window cycling
  - Editor tracking handles known yabai app-name aliases (for example VS Code can be reported as `Code`) so editor windows continue to appear in next/previous window loops
  - Stop/Restart/browser-session updates close tracked Chrome tabs only and never close full Chrome windows
  - Workspace window list/navigation rebuilds browser rows from Chrome tabs with a 10-second debounce (per workspace/prefix set) and includes tabs whose URLs start with configured browser session URLs (deduped by window+tab URL)
  - Browser focus targets cached tab index first, validates the active tab URL against workspace prefixes, refreshes once on mismatch, and falls back to URL matching if tab positions changed
  - Window-scoped Chrome tab focus/close uses string-based window-id checks in AppleScript for reliable matching
  - Browser tab rows are sorted by configured browser-session order and then URL so shortcut indices remain stable
  - Window cycling order is browser tabs first, then terminals, then other windows; once cycling starts, next/previous uses remembered cycle position
  - Global next/previous window navigation disambiguates reused Chrome windows by active tab URL, so shortcuts stay on the correct workspace
  - Processes with status check results shown as indented sub-rows (colored dots)
  - Windows list with shortcut hints
  - Env vars/ports tab
  - Workspace settings tab
- Settings view lets you choose a preferred editor from installed VS Code, Cursor, or Windsurf.
- Settings view also lets you override default keyboard shortcuts for app actions.
- New workspace `+` actions are shown for git projects only.

Hotkeys:
- Global focus: `cmd+shift+=`
  - Brings muxy to front and keeps current window-selection shortcuts active; workspace-window reconciliation runs on the periodic background interval
- Next running workspace: `cmd+shift+]`
- Previous running workspace: `cmd+shift+[`
- Activate selected workspace: `cmd+shift+return`
- Open editor: `cmd+shift+e`
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
mx version
```

## CLI
```bash
mx config path
mx config show

mx project list
mx project add --dir /path/to/repo
mx project add --git-url https://github.com/org/repo.git
mx project update --dir /path/to/repo --setup-script "cp ~/.env .env" --stop-script "docker compose down --remove-orphans"
mx project remove --dir /path/to/repo

mx workspace list --project-dir /path/to/repo --all
mx workspace create --project-dir /path/to/repo --name feature-x [--branch feature-branch] [--target-branch main] [--directory-name feature_branch]
mx workspace launch --project-dir /path/to/repo --name feature-x
mx workspace restart --project-dir /path/to/repo --name feature-x
mx workspace stop --project-dir /path/to/repo --name feature-x
mx workspace archive --project-dir /path/to/repo --name feature-x
mx workspace activate --project-dir /path/to/repo --name feature-x
```

For git projects, `workspace create` requires `--branch`; `--target-branch` defaults to `main`/`master` when available.
`workspace create --directory-name` (alias: `--dirname`) is optional for git projects and must use only letters, numbers, `-`, and `_` with no spaces.

Project/workspace removal behavior:
- `mx project remove --dir <path>` removes the project from Muxy. For git projects, it first removes related managed worktrees with `git worktree remove --force`, then deletes related workspace directories under `~/muxy/workspaces`.
- `mx project remove --dir <path>` deletes the project directory only when it is a git repo inside `~/muxy/projects` (the app-managed clone location).
- `mx workspace archive ...` removes git worktrees via `git worktree remove` and never deletes the project directory for non-git projects.

## Build
Use the SwiftPM wrapper to keep caches inside the workspace (avoids user cache warnings in sandboxed environments).
```bash
scripts/swiftpm.sh build
```

## Tests
```bash
scripts/swiftpm.sh test
```

## Lint
```bash
scripts/lint.sh
```

## Coverage
```bash
scripts/coverage.sh
```

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
