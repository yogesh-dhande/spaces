# Architecture

## Overview
`agentmux` orchestrates coding streams (git worktrees) on macOS and manages stream-scoped windows.

Main modules:
- `winmove`: Accessibility (AX) window discovery/control and tiling.
- `appctl`: app-specific adapters (editor, Chrome, Terminal, launcher).
- `streamctl`: orchestration, models, persistence, diagnostics.
- `agentmux`: CLI entrypoint.
- `agentmux-gui`: AppKit desktop app using `streamctl` directly.

Window model is unified:
- `Project.windows[]` with `kind` in `editor|browser|terminal|custom`
- no legacy fixed terminal/custom per-project sections

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
- `windows[]` (`name`, `bundleID`, optional `windowID`, optional `windowTitle`, optional `anchorURL`)
- `updatedAt`

Behavior:
- `show/hide/focus/destroy` prefer persisted identity first.
- If unavailable, fallback heuristics are used.

## Terminal Status Pipeline
- Terminal window specs with `command` are launched through a managed wrapper:
  - `~/.agentmux/bin/agentwrap.sh`
- The wrapper writes status file updates to:
  - `<stream worktree>/.agentmux/terminal-status/<terminal-name>.json`
- Status payload:
  - `state`
  - `timestamp`
- `streamctl.terminalStatuses(projectName:streamName:)` reads these files and combines them with terminal window presence checks.
- AppKit streams list polls and refreshes terminal statuses periodically.

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
- `agentmux project window list|add|update|remove ...`
- `agentmux stream list|create|destroy ...`
- `agentmux show --project <name> --stream <name>`
- `agentmux hide --project <name> --stream <name>`
- `agentmux focus --project <name> --stream <name>`
- `agentmux list-active`
- `agentmux doctor [--project <name>] [--stream <name>]`

## Current Constraints
- macOS only.
- Local-only state and control plane.

## Diagnostics Notes
- CLI error messages include concrete Accessibility remediation steps and exact binaries to enable.
- `doctor` prints actionable follow-up commands when windows are missing.
