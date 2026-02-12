# Checkpoint

## Current Status
- YAML config at `~/.agentmux/config.yaml` is the source of truth for editor preference, port range, projects, and project templates (processes, browser sessions, status checks).
- Runtime state and workspace settings live in `~/.agentmux/agentmux.db` (projects, workspaces, ports, running processes, status results, windows, settings, workspace settings) and are rebuilt when the schema version changes; workspace settings are re-seeded from project templates when missing.
- Projects are normalized by real path; a default workspace is ensured per project with reserved ports.
- Project creation supports either existing directories or git clone; cloned repositories are stored at `/Users/<username>/agentmux/projects/<project_name>`.
- Project removal clears agentmux state, deletes related git workspace directories under `/Users/<username>/agentmux/workspaces`, and deletes the project directory only for git repositories under `/Users/<username>/agentmux/projects` (managed clones).
- Workspaces create git worktrees for git projects, run setup/cleanup scripts, and reserve 10 ports per workspace.
- Archiving non-git workspaces does not delete the project directory.
- Workspace launch starts processes in iTerm2 with env vars and logs under `~/.agentmux/runtime/<workspace-id>`, opens Chrome browser sessions, optionally opens the editor, and captures window IDs via yabai in browser/editor/terminal order.
- Workspace settings snapshot project templates on creation into the runtime DB and are editable per workspace; updates to running workspaces reconcile processes and browser sessions immediately.
- AppKit GUI is two-pane with in-place forms and editors for processes, browser sessions, and status checks; workspace detail includes run/stop/archive, windows list with shortcut hints, an env/ports tab, and workspace settings.
- Right-pane forms are scrollable, use left-aligned full-width fields, and use text-labeled actions for create/cancel flows.
- New workspace `+` actions in project UI are shown only for git projects.
- New workspace forms now have separate workspace-name and branch-name inputs.
- Branch name is shown first and starts empty.
- Workspace name auto-fills from branch by default, and users can edit workspace name independently.
- For git projects, branch is required when creating a workspace.
- Left-pane workspace rows show workspace name plus branch metadata on a second line with a branch icon.
- Settings view in the GUI lets users pick a preferred editor from installed VS Code, Cursor, or Windsurf; the choice is stored in the YAML config.
- Settings view in the GUI also allows overriding default shortcuts for global toggle, workspace navigation/activation, and open editor/terminal/Finder; these values are stored in the runtime DB.
- Window focus shortcuts are `cmd+1` through `cmd+9` while the GUI is focused.
- The local key monitor defers to focused text inputs so standard edit shortcuts like `cmd+v` work in forms.
- CLI supports config path/show, project list/add/update/remove (including `project add --git-url ...`), workspace list/create/launch/stop/archive/activate, and settings get/set/reset for GUI shortcuts.
- Workspace run view includes Open Editor/Terminal/Finder actions; editor/terminal windows opened this way are captured and included in window cycling.

## Accomplished
- Replaced stream-based model with project/workspace/process design.
- Added YAML config loader/saver with default config generation and port-range validation.
- New runtime schema for projects, workspaces, ports, processes, windows, status results, and settings.
- Implemented git worktree create/remove, port allocation, and setup/cleanup scripts.
- Added iTerm2 process launch with env injection, PID/log capture, and runtime tracking.
- Implemented Chrome browser session opening and yabai-based window capture.
- Built the AppKit GUI with two-pane layout, project/workspace editing, and window shortcut hints.
- Added CLI subcommands for projects/workspaces plus settings for hotkey customization.

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
- UX: Show autocomplete for ENV variables when editing a process command, or setup script or cleanup script
- Functionality: Integrate with GitHub for creating pull requests on behalf of users
- UX: AI agents to enhance user workflow (e.g. autogenerate summaries)
    - "run a small haiku bot looking at what I'm doing in any given instance and give me 200 characters on what I seem to be trying to do in a small div above my input box"
