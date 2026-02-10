# Checkpoint

## Current Status
- YAML config is the source of truth for projects, processes, browser sessions, and status checks.
- Runtime state lives in `~/.agentmux/agentmux.db` and is rebuilt when schema changes.
- Workspaces manage git worktrees, ports, and runtime process/window state.
- AppKit GUI uses a two-pane layout with in-place forms (no dialogs for add/edit).
- CLI updated to project/workspace management and config discovery.
- GUI supports cmd+shift+1 through cmd+shift+9 to focus workspace windows.
- Global cmd+shift+[ and cmd+shift+] cycle workspace windows when the GUI is not focused.

## Accomplished
- Replaced stream-based model with project/workspace/process design.
- Added YAML config loader/saver and default config generation.
- New runtime schema: workspaces, ports, processes, windows, and status results.
- Basic process launch in iTerm2 with env vars injected.
- Chrome browser sessions opened via AppleScript.
- Workspace launch/stop/archive and port allocation.
- Updated hotkey defaults to spec (`cmd+shift+=`, `cmd+shift+]`, `cmd+shift+[`, `cmd+shift+return`).
- Worktrees stored under `/Users/<username>/agentmux/workspaces/<projectname>/<dirname>` (dirname is a unique food name).
- Added `cmd+n` shortcut and toolbar button to create a new workspace for the selected project.

## Remaining
- Richer status check scheduling (periodic background runner).
- More robust window reconciliation on app restart.
- Enhanced GUI editing for process templates and status checks.
- Global window loop shortcuts when agentmux is not focused.
