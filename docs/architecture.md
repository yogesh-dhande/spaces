# Architecture

## Overview
`agentmux` orchestrates coding streams (git worktrees) on macOS and manages stream-scoped editor/browser/terminal windows.

Main modules:
- `winmove`: Accessibility (AX) window discovery/control and tiling.
- `appctl`: app-specific adapters (editor, Chrome, Terminal, launcher).
- `streamctl`: orchestration, models, persistence, diagnostics.
- `agentmux`: CLI entrypoint.
- `agentmux-gui`: AppKit desktop app using `streamctl` directly.

## Lifecycle Semantics
- `create`: create git worktree + persist stream.
- `show`: surface existing stream windows; fallback to launch path when missing.
- `hide`: minimize stream windows and mark inactive.
- `destroy`: teardown stream windows, remove worktree, remove records.
- `focus`: bring stream windows front and refresh layout best-effort.

## Persistence
SQLite default path: `~/.agentmux/agentmux.db`.

Tables:
- `projects`: serialized `Project` payload by `name`.
- `streams`: serialized `Stream` payload by `(project_id, name)`.
- `stream_runtime`: active/inactive state and timestamps.
- `stream_window_identity`: persisted identity used for deterministic targeting.

## Stream Window Identity
Stored per stream:
- `editorMatchTitle`
- `chromeAnchorURL`
- `terminalTitlePrefix`
- `updatedAt`

Behavior:
- `show/hide/focus/destroy` prefer persisted identity first.
- If unavailable, fallback heuristics are used.

## Window Targeting Rules
- Use bundle IDs, not app names.
- Before moving windows, normalize state:
  - exit fullscreen
  - refetch window
  - unminimize (or minimize for hide path)
  - set position/size
- Continue on non-editor window failures; fail fast on editor launch/move errors.

## Canonical CLI
- `agentmux project list|create|update|delete ...`
- `agentmux project terminal list|add|update|remove ...`
- `agentmux stream list|create|destroy ...`
- `agentmux show --project <name> --stream <name>`
- `agentmux hide --project <name> --stream <name>`
- `agentmux focus --project <name> --stream <name>`
- `agentmux list-active`
- `agentmux doctor [--project <name>] [--stream <name>]`

## Current Constraints
- macOS only.
- Local-only state and control plane.
- Chrome stream identity is tab-anchor based.
- Terminal stream identity uses custom tab-title prefix.
