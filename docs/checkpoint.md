# Checkpoint

## Current Status
- Core backend is implemented and shared across CLI + GUI modules.
- GUI is AppKit-based and functional for project/stream operations.
- Stream window control uses **yabai** window IDs captured per stream.
- Database state lives at `~/.agentmux/agentmux.db` and is managed automatically.
- Terminal window status can be tracked via `agentmux wrap`.

## Accomplished
- Implemented shared Swift modules: `appctl`, `streamctl`.
- Implemented stream lifecycle backend: `create`, `capture` (manual), `show` (auto-captures), `destroy`.
- Implemented CLI project/stream CRUD:
  - `project list/create/update/delete`
  - `stream list/create/update/capture/destroy` (capture optional; `show` auto-captures)
- Implemented `doctor` diagnostics for captured/missing windows.
- Implemented AppKit GUI MVP:
  - project list/add/edit/delete
  - stream list/add/edit/destroy
  - stream actions: `show` (auto-captures), `doctor`
  - status line feedback
- Added `agentmux wrap` to emit per-terminal status files for streams.
- GUI stream list shows a card per stream with per-window status and auto-refresh.
- Added warning on `show` when no captured windows can be focused (suggests closing/reopening windows).
- Added repeatable smoke script: `Tests/smoke_cli.sh`.
- Added configurable global hotkey to toggle the GUI on the active space/display.
- GUI auto-reloads the hotkey when settings change.
- Hotkey moves the GUI to the active space when invoked from another space/display.
- Added GUI keyboard shortcuts to select next/previous stream and show the selected stream.
- Default stream worktrees now live under `<repo>/.worktrees/<stream>`.

## Remaining
- GUI polish:
  - better validation messages and inline guidance
  - richer stream row details (sorting/filtering)
- Optional: richer filtering/sorting in GUI
- Deeper automated tests for yabai integration (beyond smoke shell script)
