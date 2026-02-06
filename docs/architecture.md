# Architecture

## Overview
`agentmux` orchestrates coding streams (git worktrees) on macOS and uses **yabai** for window‑level control.

Main modules:
- `appctl`: external system adapters (yabai).
- `streamctl`: orchestration, models, persistence, diagnostics.
- `agentmux`: CLI entrypoint.
- `agentmux-gui`: AppKit desktop app using `streamctl` directly.

GUI shortcuts:
- Global hotkey toggles the GUI (user-configurable).
- When the GUI is active: `cmd+]` next stream, `cmd+[` previous stream, `cmd+return` show selected stream.

## Lifecycle Semantics
- `create`: create git worktree + persist stream.
- `capture`: query yabai windows for the stream's space + persist identity (optional; `show` auto-captures).
- `show`: capture current space windows, focus captured windows + mark active; warn when none are focusable.
- `destroy`: close captured windows + remove worktree + remove records.

## Persistence
SQLite path: `~/.agentmux/agentmux.db` (managed automatically).

Tables:
- `projects`: serialized `Project` payload by `name`.
- `streams`: serialized `Stream` payload by `(project_id, name)`.
- `stream_runtime`: active/inactive state and timestamps.
- `stream_window_identity`: captured window sets per stream.
- `settings`: key/value settings (e.g., GUI hotkey).

Local status files:
- Terminal status files written by `agentmux wrap` once the focused window is captured.
- Path: `<worktree>/.agentmux/status/window-<id>.json`.
- GUI reads captured windows per stream and maps statuses by window ID, resolving titles via yabai.

## Yabai Integration
- Window capture:
  - `yabai -m query --windows --space <space>`
- Window actions:
  - `yabai -m window --focus <id>`
  - `yabai -m window --close <id>`

## Canonical CLI
- `agentmux project list|create|update|delete ...`
- `agentmux stream list|create|update|capture|destroy ...`
- `agentmux show --project <name> --stream <name>`
- `agentmux list-active`
- `agentmux doctor [--project <name>] [--stream <name>]`
- `agentmux settings get|set|reset --gui-hotkey ...`
- `agentmux wrap [--project <name> --stream <name>] -- <command> [args...]`
- `agentmux wrap [--project <name> --stream <name>] <command> [args...]`

## Current Constraints
- macOS only.
- Local-only state and control plane.
- Requires yabai + Accessibility permissions.
