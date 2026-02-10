# Checkpoint

## Current Status
- YAML config at `~/.agentmux/config.yaml` is the source of truth for editor preference, port range, projects, processes, browser sessions, and status checks.
- Runtime state lives in `~/.agentmux/agentmux.db` (projects, workspaces, ports, running processes, status results, windows, settings) and is rebuilt when the schema version changes.
- Projects are normalized by real path; a default workspace is ensured per project with reserved ports.
- Workspaces create git worktrees for git projects, run setup/cleanup scripts, and reserve 10 ports per workspace.
- Workspace launch starts processes in iTerm2 with env vars and logs under `~/.agentmux/runtime/<workspace-id>`, opens Chrome browser sessions, optionally opens the editor, and captures window IDs via yabai in browser/editor/terminal order.
- AppKit GUI is two-pane with in-place forms and editors for processes, browser sessions, and status checks; workspace detail includes run/stop/archive, windows list with shortcut hints, and an env/ports tab.
- Hotkeys are configurable (settings stored in the runtime DB): global toggle `cmd+shift+=`, global window navigation `cmd+shift+]` and `cmd+shift+[`, activate selected workspace `cmd+shift+return`, new workspace `cmd+n`, window focus `cmd+shift+1` through `cmd+shift+9`.
- CLI supports config path/show, project list/add/update/remove, workspace list/create/launch/stop/archive/activate, and settings get/set/reset for GUI shortcuts.

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
- Periodic status check runner (honor interval/timeout) plus on-exit actions.
- Coding agent detection with idle/busy state tracking.
- Window reconciliation on app restart (re-scan existing windows and map to workspaces).
