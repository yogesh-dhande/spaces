# spaceship

`spaceship` is a local macOS control plane for workspace orchestration.
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
YAML is the source of truth:
- Path: `~/.spaceship/config.yaml`
- Runtime DB: `~/.spaceship/spaceship.db` (ephemeral)
- Cloned projects: `/Users/<username>/spaceship/projects/<project_name>`
- Git worktrees: `/Users/<username>/spaceship/workspaces/<projectname>/<dirname>` (dirname defaults to a unique food name and can be overridden on workspace creation)
- GUI shortcuts (when focused): `cmd+1` through `cmd+9` focus workspace windows
- Global window navigation (when GUI not focused): `cmd+shift+]` and `cmd+shift+[`

Example config:
```yaml
editor: vscode
port_range:
  start: 20000
  end: 30000
projects:
  - dir: /path/to/repo
    setup_script: cp /shared/.env .env
    stop_script: docker compose down --remove-orphans
    ports:
      - name: FRONTEND_PORT
      - name: API_PORT
    processes:
      - name: server
        command: PORT=$FRONTEND_PORT npm run dev
      - name: api
        command: PORT=$API_PORT npm run api
    status_checks:
      - name: web
        process: server
        command: curl -fsS http://localhost:$FRONTEND_PORT/health
        interval: 10
        timeout: 2
        onExit: notify
    browser_sessions:
      - url: http://localhost:$FRONTEND_PORT
```

Port definitions (`ports`) are configured at the project level and inherited by workspaces. Each named port (e.g. `FRONTEND_PORT`) is allocated a real port number from the configured `port_range`, reserved via OS sockets so no other process can claim it. Named port env vars are available in setup scripts, stop scripts, process commands, and status check commands. Workspaces can override port definitions in their settings.

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
- If the selected branch exists only on remote, spaceship fetches it first and then creates the worktree from `origin/<branch>`.
- If the branch exists locally, spaceship uses the local branch as-is (no implicit pull/rebase/merge during workspace creation).
- Workspace rows in the left pane use compact cards with workspace status + name.
- Folder and branch labels (with icons) are shown only when those values differ from workspace name.
- Git workspace rows also show relative last-modified time (latest tracked-file mtime) and tracked modified-file count.
- Workspace view includes:
  - Launch/Restart/Stop/Archive buttons
  - Open Editor/Terminal/Finder buttons (editor/terminal windows are tracked for cycling)
  - Workspace window records are refreshed periodically in a background pass so stale closed windows are pruned without blocking interaction
  - Browser session entries track target URLs and focus the matching Chrome tab during window navigation
  - Launch/Restart reuses existing matching Chrome tabs and tracks all matches instead of opening duplicate tabs when matches already exist
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
  - Brings spaceship to front and keeps current window-selection shortcuts active; workspace-window reconciliation runs on the periodic background interval
- Next running workspace: `cmd+shift+]`
- Previous running workspace: `cmd+shift+[`
- Activate selected workspace: `cmd+shift+return`
- Open editor: `cmd+shift+e`
- Open terminal: `cmd+shift+t`
- Open Finder: `cmd+shift+f`
- Focus workspace window 1-9: `cmd+1` through `cmd+9`

When text input is focused in the GUI, standard editing shortcuts (including `cmd+v`) are handled normally.

Set `DEBUG=1` when launching spaceship to log browser scan timing and browser-focus path/timing (indexed verify, refresh, cache hits/misses, and URL fallback decisions) to stderr.

## CLI
```bash
spaceship config path
spaceship config show

spaceship project list
spaceship project add --dir /path/to/repo
spaceship project add --git-url https://github.com/org/repo.git
spaceship project update --dir /path/to/repo --setup-script "cp ~/.env .env" --stop-script "docker compose down --remove-orphans"
spaceship project remove --dir /path/to/repo

spaceship workspace list --project-dir /path/to/repo --all
spaceship workspace create --project-dir /path/to/repo --name feature-x [--branch feature-branch] [--target-branch main] [--directory-name feature_branch]
spaceship workspace launch --project-dir /path/to/repo --name feature-x
spaceship workspace restart --project-dir /path/to/repo --name feature-x
spaceship workspace stop --project-dir /path/to/repo --name feature-x
spaceship workspace archive --project-dir /path/to/repo --name feature-x
spaceship workspace activate --project-dir /path/to/repo --name feature-x
```

For git projects, `workspace create` requires `--branch`; `--target-branch` defaults to `main`/`master` when available.
`workspace create --directory-name` (alias: `--dirname`) is optional for git projects and must use only letters, numbers, `-`, and `_` with no spaces.

Project/workspace removal behavior:
- `spaceship project remove --dir <path>` removes the project from spaceship. For git projects, it first removes related managed worktrees with `git worktree remove --force`, then deletes related workspace directories under `~/spaceship/workspaces`.
- `spaceship project remove --dir <path>` deletes the project directory only when it is a git repo inside `~/spaceship/projects` (the app-managed clone location).
- `spaceship workspace archive ...` removes git worktrees via `git worktree remove` and never deletes the project directory for non-git projects.

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
