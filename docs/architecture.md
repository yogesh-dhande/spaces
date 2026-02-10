# Architecture

## Overview
`agentmux` is a macOS developer tool for workspace orchestration.

Key principles:
- YAML is the **source of truth** for user configuration.
- SQLite is **ephemeral runtime state** and may be rebuilt on startup.
- AppleScript is preferred for app automation (Chrome, iTerm2); yabai is used for window IDs, space/display, and focus.

Main modules:
- `appctl`: system adapters (yabai, AppleScript, Chrome, iTerm2).
- `streamctl`: core orchestration, models, persistence, config.
- `agentmux`: CLI entrypoint.
- `agentmux-gui`: AppKit GUI built on `streamctl`.

## Data Model
Configuration (YAML):
- `editor` preference.
- `port_range` base range.
- `projects` with:
  - `dir`, `setup_script`, `cleanup_script`
  - `processes`
  - `status_checks`
  - `browser_sessions`

Runtime (SQLite):
- `projects` derived from config (normalized dir, git info).
- `workspaces` runtime state.
- `workspace_ports` reserved ports per workspace.
- `running_processes`, `status_results`.
- `windows` tracked per workspace.
- `settings` for GUI hotkeys and active workspace.

## Lifecycle Semantics
- Project add/update: update YAML, re-sync runtime.
- Workspace create:
  - If git repo: create worktree under `/Users/<username>/agentmux/workspaces/<projectname>/<dirname>` (dirname is a unique food name).
  - Run `setup_script` once.
  - Reserve PORT0–PORT9 from `portRange`.
- Workspace launch:
  - Start processes in iTerm2 windows with env vars injected.
  - Ensure Chrome windows/tabs exist for BrowserSessions.
  - Open editor if configured.
  - Track window IDs via yabai.
- Workspace stop:
  - Close tracked windows and terminals.
  - Clear runtime process state.
- Workspace archive:
  - Stop workspace.
  - Run `cleanup_script` once.
  - Remove worktree (git projects).
  - Release reserved ports.

## Window Tracking
- AppleScript is used to open/manage Chrome and iTerm2 windows.
- yabai is the source of truth for window IDs and focus.
- On launch, agentmux captures new windows and stores IDs in the runtime DB.

## Hotkeys
- Global hotkey toggles GUI visibility.
- When GUI is focused: next/previous running workspace and activate selected workspace.
- `cmd+n` creates a new workspace for the selected project.
- Window focus uses yabai window IDs in the order: browser, editor, terminals.

## Dependencies
- macOS 14+
- `yabai` (window IDs + focus)
- iTerm2 (terminal processes)
- Google Chrome (browser sessions)
