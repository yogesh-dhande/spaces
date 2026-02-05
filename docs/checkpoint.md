# Checkpoint

## Current Status
- Core backend is implemented and shared across CLI + GUI modules.
- GUI is AppKit-based and functional for core project/stream operations.
- Window management is unified across window kinds (`editor`, `browser`, `terminal`, `custom`).
- Terminal status tracking is implemented and surfaced in streams view.

## Accomplished
- Implemented shared Swift modules: `winmove`, `appctl`, `streamctl`.
- Implemented stream lifecycle backend: `create`, `show`, `hide`, `destroy`, `focus`.
- Implemented CLI project/stream CRUD:
  - `project list/create/update/delete`
  - `stream list/create/destroy`
- Implemented CLI project window CRUD:
  - `project window list/add/update/remove`
- Added SQLite runtime + identity persistence:
  - `stream_runtime`
  - `stream_window_identity`
- Implemented `doctor` diagnostics with window found/expected counts and missing window names.
- Improved user-facing diagnostics:
  - explicit Accessibility permission steps
  - exact binary guidance (`Terminal.app`, running `agentmux` binary, `agentmux-gui`)
  - actionable next-step hints in `doctor` output
- Added repeatable smoke script: `tests/smoke_cli.sh`.
- Migrated GUI from SwiftUI attempt to AppKit.
- Implemented AppKit GUI MVP:
  - project list/add/edit/delete (on-demand dialogs)
  - project window add/edit/remove (on-demand dialogs)
  - stream list/add/destroy
  - stream actions: `show`, `hide`, `focus`, `doctor`
  - status line feedback
  - live terminal status summaries in streams table
- Implemented terminal command wrapper flow:
  - managed wrapper script at `~/.agentmux/bin/agentwrap.sh`
  - per-terminal status files in stream worktrees
- Added stronger smoke coverage:
  - stream active/inactive transitions via `show/hide`
  - doctor output shape checks

## Remaining
- GUI polish:
  - better validation messages and inline guidance
  - richer stream row details and sorting/filtering
  - show selectors where appropriate instead of free string input (e.g. window location "leftHalf", "rightHalf", "bottomHalf", "fullScreen")
- Hotkeys/shortcuts for quick stream switching (still open from spec intent)
- Additional hardening:
  - deeper automated tests (module-level tests beyond smoke shell script)
  - stronger `doctor` remediation guidance (permissions/app availability)
  - broader handling for non-Terminal terminal apps

## Next Task (start here)
- Implement keyboard shortcuts / hotkeys for stream focus and show/hide.
