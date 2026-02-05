# Architecture

## Overview
`agentmux` orchestrates coding streams (git worktrees) on macOS and uses **yabai** for window‑level control.

Main modules:
- `appctl`: external system adapters (yabai).
- `streamctl`: orchestration, models, persistence, diagnostics.
- `agentmux`: CLI entrypoint.
- `agentmux-gui`: AppKit desktop app using `streamctl` directly.

## Lifecycle Semantics
- `create`: create git worktree + persist stream.
- `capture`: query yabai windows for the stream's space + persist identity.
- `show`: focus captured windows + mark active; warn when none are focusable.
- `hide`: minimize captured windows + mark inactive.
- `destroy`: close captured windows + remove worktree + remove records.
- `focus`: same as `show`.

## Persistence
SQLite default path: `~/.agentmux/agentmux.db`.

Tables:
- `projects`: serialized `Project` payload by `name`.
- `streams`: serialized `Stream` payload by `(project_id, name)`.
- `stream_runtime`: active/inactive state and timestamps.
- `stream_window_identity`: captured window sets per stream.

## Yabai Integration
- Window capture:
  - `yabai -m query --windows --space <space>`
- Window actions:
  - `yabai -m window --focus <id>`
  - `yabai -m window --minimize <id>`
  - `yabai -m window --close <id>`

## Canonical CLI
- `agentmux project list|create|update|delete ...`
- `agentmux stream list|create|update|capture|destroy ...`
- `agentmux show --project <name> --stream <name>`
- `agentmux hide --project <name> --stream <name>`
- `agentmux focus --project <name> --stream <name>`
- `agentmux list-active`
- `agentmux doctor [--project <name>] [--stream <name>]`

## Current Constraints
- macOS only.
- Local-only state and control plane.
- Requires yabai + Accessibility permissions.
