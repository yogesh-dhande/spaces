# Checkpoint

## Current Status
- Core backend is implemented and shared across CLI + GUI modules.
- GUI is AppKit-based and functional for core project/stream operations.

## Accomplished
- Implemented shared Swift modules: `winmove`, `appctl`, `streamctl`.
- Implemented stream lifecycle backend: `create`, `show`, `hide`, `destroy`, `focus`.
- Implemented CLI project/stream CRUD:
  - `project list/create/update/delete`
  - `stream list/create/destroy`
- Implemented CLI project terminal-spec CRUD:
  - `project terminal list/add/update/remove`
- Added SQLite runtime + identity persistence:
  - `stream_runtime`
  - `stream_window_identity`
- Implemented `doctor` diagnostics with:
  - editor/chrome status
  - terminal found/expected counts
- Added repeatable smoke script: `tests/smoke_cli.sh`.
- Migrated GUI from SwiftUI attempt to AppKit.
- Implemented AppKit GUI MVP:
  - project list/add/edit/delete (on-demand dialogs)
  - stream list/add/destroy
  - stream actions: `show`, `hide`, `focus`, `doctor`
  - status line feedback

## Remaining
- Add GUI terminal-spec management:
  - list/add/edit/remove terminal specs per project (on-demand dialogs)
- Sync docs fully with current state:
  - `AGENTS.md`
  - `docs/architecture.md`
  - `README.md`
- GUI polish:
  - better validation messages
  - keyboard shortcuts
- Additional hardening:
  - expand automated tests beyond smoke script
  - improve `doctor` fix guidance for permission/app issues

## Next Task (start here)
- Implement AppKit dialogs for project terminal-spec CRUD, then wire refresh and status feedback.
