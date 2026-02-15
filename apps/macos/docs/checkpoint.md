# Checkpoint

## Current Status
- YAML config at `~/.spaceship/config.yaml` is the source of truth for editor preference, port range, projects, and project templates (processes, browser sessions, status checks).
- Runtime state and workspace settings live in `~/.spaceship/spaceship.db` (projects, workspaces, ports, running processes, status results, windows, settings, workspace settings) and are rebuilt when the schema version changes; workspace settings are re-seeded from project templates when missing.
- Projects are normalized by real path; a default workspace is ensured per project with reserved ports.
- Project creation supports either existing directories or git clone; cloned repositories are stored at `/Users/<username>/spaceship/projects/<project_name>`.
- Project removal clears spaceship state, removes related managed git worktrees via `git worktree remove --force`, deletes related git workspace directories under `/Users/<username>/spaceship/workspaces`, and deletes the project directory only for git repositories under `/Users/<username>/spaceship/projects` (managed clones).
- Workspaces create git worktrees for git projects, run setup/stop scripts, and reserve 10 ports per workspace.
- Git workspace creation supports an optional directory-name override for the worktree folder; overrides must use only `A-Z`, `a-z`, `0-9`, `-`, `_` and cannot contain spaces.
- Archiving non-git workspaces does not delete the project directory.
- Archiving git workspaces removes the worktree via `git worktree remove --force` (and then archives workspace metadata/ports).
- Workspace launch starts processes in iTerm2 with env vars and logs under `~/.spaceship/runtime/<workspace-id>`, opens Chrome browser sessions, optionally opens the editor, and captures window IDs via yabai in browser/editor/terminal order.
- Browser window tracking includes target session URL so workspace focus actions can activate the matching Chrome tab (not just focus the window).
- Browser session mapping is URL-based; title-based fallback matching is removed to avoid binding sessions to unrelated active tabs in shared Chrome windows.
- Workspace launch/restart reuses existing matching Chrome tabs and tracks all matches for workspace window cycling.
- Workspace window lists/cycling now rebuild browser rows from Chrome scans with a 10-second debounce per workspace/prefix set and include every tab whose URL starts with any configured browser-session URL; overlapping session prefixes are deduplicated by `(window_id, tab URL)`.
- Live browser row focus now targets cached `(window_id, tab_index)` first, validates focused active-tab URL against workspace prefixes, refreshes the scan once on mismatch, and then falls back to URL matching if needed.
- Window-scoped Chrome AppleScript operations now compare window IDs as strings to keep tab focus/close matching reliable.
- Browser tab rows are emitted in deterministic order (browser-session prefix order, then URL) so displayed `cmd+<n>` hints map to stable targets.
- Stop/restart/settings reconciliation now close tracked Chrome tabs by URL prefix and do not close full Chrome windows.
- Window cycling order is now grouped as browser tabs, then terminals, then other roles; once cycling starts, navigation uses the remembered index for deterministic forward/backward traversal.
- `DEBUG=1` enables stderr timing logs for both Chrome tab scans (tab count, match count, elapsed ms) and indexed focus verification/cache/refresh/fallback behavior.
- Window cycling keeps a workspace-local navigation pointer but resolves Chrome entries using the currently active frontmost tab URL when multiple tracked tabs share one window.
- Focused Chrome windows now map to workspaces using both `window_id` and active tab URL prefix so global next/previous shortcuts choose the correct workspace even when Chrome windows are reused across workspaces.
- Workspace window listing/navigation filters untargeted browser rows when a targeted browser row already exists for the same Chrome `window_id`.
- Terminal window tracking now backfills from running-process window IDs and persists all newly captured terminal windows during process reconciliation.
- Launch is now reserved for stopped workspaces; running workspaces use explicit restart semantics (stop then launch) via GUI/CLI.
- Workspace settings snapshot project templates on creation into the runtime DB and are editable per workspace; updates to running workspaces reconcile processes and browser sessions immediately.
- AppKit GUI is two-pane with in-place forms and editors for processes, browser sessions, and status checks; workspace detail includes run/stop/archive, windows list with shortcut hints, an env/ports tab, and workspace settings.
- Workspace detail header shows a colored status dot (green = running, gray = stopped) to the left of the title, git branch with icon below, and directory path with folder icon and a copy-to-clipboard button.
- Launch/Stop/Restart buttons show icon-only labels without keyboard shortcut text (shortcuts don't function from those buttons).
- Window list shows URLs for browser sessions and process commands for terminal windows instead of raw window titles.
- New project form uses themed card sections (rounded borders, sidebar colors) for Source, Setup script, Processes, Browser sessions, Status checks, and Stop script; source popup and directory picker are on the same row.
- Right-pane forms are scrollable, use left-aligned full-width fields, and use text-labeled actions for create/cancel flows.
- New workspace `+` actions in project UI are shown only for git projects.
- New workspace forms now have separate target-branch, branch-name, and workspace-name inputs for git projects.
- New workspace forms also include an optional directory-name input for git projects to override auto-generated worktree folder names.
- Target branch is shown first with a searchable branch list and defaults to main/master when available.
- Workspace name auto-fills from branch by default, and users can edit workspace name independently.
- For git projects, branch is required when creating a workspace.
- Newly created branches are based on the latest commit of the selected target branch.
- When a branch exists only on remote, workspace creation fetches that branch into `origin/*` before creating the worktree.
- When a branch exists locally, workspace creation uses local branch state as-is without implicit pull/rebase/merge.
- Left-pane workspace rows now use compact cards with workspace status + name.
- Folder and branch metadata rows are shown with icons only when the value differs from workspace name.
- Git workspace rows show relative last-modified time (from latest tracked-file mtime) plus tracked modified-file count.
- Settings view in the GUI lets users pick a preferred editor from installed VS Code, Cursor, or Windsurf; the choice is stored in the YAML config.
- Settings view in the GUI also allows overriding default shortcuts for global toggle, workspace navigation/activation, and open editor/terminal/Finder; these values are stored in the runtime DB.
- Window focus shortcuts are `cmd+1` through `cmd+9` while the GUI is focused.
- Bringing spaceship to front with the global toggle hotkey refreshes the selected workspace detail view so the displayed window list reflects the most recent Chrome tab scan (up to 10 seconds old).
- The local key monitor defers to focused text inputs so standard edit shortcuts like `cmd+v` work in forms.
- CLI supports config path/show, project list/add/update/remove (including `project add --git-url ...`), workspace list/create/launch/stop/archive/activate, and settings get/set/reset for GUI shortcuts.
- Workspace run view includes Open Editor/Terminal/Finder actions; editor/terminal windows opened this way are captured and included in window cycling.
- Projects can define named ports (e.g. `FRONTEND_PORT`, `API_PORT`) instead of anonymous `PORT0`-`PORT9`; port definitions are configured at the project level in YAML and inherited/overridable at the workspace level.
- Named ports are OS-reserved via sockets (`PortReserver` singleton) so no other process can claim them between allocation and use.
- Named port env vars are available in setup scripts, stop scripts, process commands, and status check commands.
- Port allocation now happens before the setup script so env vars are available during setup.
- `PortAllocator.allocatePorts` accepts `definitions: [PortDefinition]` instead of a fixed count; `buildWorkspaceEnv` uses named port keys.
- Schema v7: `workspace_ports` table gains `port_name` column; new `workspace_port_definitions` table stores per-workspace port definitions.
- GUI: `PortEditor` provides an inline editor for port definitions in project detail, add-project form, and workspace settings.

## Accomplished
- Replaced stream-based model with project/workspace/process design.
- Added YAML config loader/saver with default config generation and port-range validation.
- New runtime schema for projects, workspaces, ports, processes, windows, status results, and settings.
- Implemented git worktree create/remove, port allocation, and setup/stop scripts.
- Added iTerm2 process launch with env injection, PID/log capture, and runtime tracking.
- Implemented Chrome browser session opening and yabai-based window capture.
- Built the AppKit GUI with two-pane layout, project/workspace editing, and window shortcut hints.
- Added CLI subcommands for projects/workspaces plus settings for hotkey customization.
- Implemented named port definitions with `PortDefinition` model, `PortReserver` (socket-based reservation), `PortEditor` GUI, schema v7 migration, and updated `PortAllocator`/`buildWorkspaceEnv` to use named ports.

## Remaining
- Dependency/permission onboarding (detect missing `yabai` or macOS accessibility permissions and guide the user).
- Periodic status check runner (honor interval/timeout) plus on-exit actions, with GUI status updates.
- Coding agent detection with idle/busy state tracking and notifications for idle/exited events.
- Window reconciliation on app restart and possibly also when starting to loop through windows of a workspace (re-scan existing windows, match browser sessions, and map them to workspaces).

## Polish
- Auto-update system (Sparkle) with signed releases and staged rollouts.
- Make a plan for charging users by selling licenses 
- Crash reporting + opt-in analytics, plus a diagnostics export (logs, db schema version, config summary).
- Structured logging with log levels and rotating files.
- Accessibility pass (VoiceOver, keyboard navigation, focus order, contrast checks).
- Localization scaffolding (even if only en-US ships initially).
- Data migration strategy for DB schema changes (beyond rebuild if/when persistence matters).
- Backup/restore for config + workspace settings.
- Code signing, notarization, and hardened runtime checks in CI.
- Performance/energy budget for background polling (status checks, agent idle detection).
- Security review for shell command execution and AppleScript boundaries.
- App health view (dependency status, permissions, last run errors).


### V2 features
- UX: Show autocomplete for ENV variables when editing a process command, or setup script or stop script
- Functionality: Integrate with GitHub for creating pull requests on behalf of users
- UX: AI agents to enhance user workflow (e.g. autogenerate summaries)
    - "run a small haiku bot looking at what I'm doing in any given instance and give me 200 characters on what I seem to be trying to do in a small div above my input box"
