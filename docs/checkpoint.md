# Checkpoint

## Current Status
- Core backend is implemented and shared across CLI + GUI modules.
- GUI is AppKit-based and functional for core project/stream operations.
- Window management is unified across window kinds (`editor`, `browser`, `terminal`, `custom`).

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
- Added repeatable smoke script: `tests/smoke_cli.sh`.
- Migrated GUI from SwiftUI attempt to AppKit.
- Implemented AppKit GUI MVP:
  - project list/add/edit/delete (on-demand dialogs)
  - project window add/edit/remove (on-demand dialogs)
  - stream list/add/destroy
  - stream actions: `show`, `hide`, `focus`, `doctor`
  - status line feedback

## Remaining
- Sync docs fully with current state:
  - `AGENTS.md`
  - `README.md`
- GUI polish:
  - better validation messages
  - keyboard shortcuts
- Additional hardening:
  - expand automated tests beyond smoke script
  - improve `doctor` fix guidance for permission/app issues

## Next Task (start here)
- Add richer validation and guided inputs in the AppKit window dialogs (kind-specific hints and required fields).
