# Checkpoint

## Current Status
- Core backend is implemented and shared across CLI + GUI modules.
- GUI is AppKit-based and functional for project/stream operations.
- Stream window control uses **yabai** window IDs captured per stream.
- Database state lives at `~/.agentmux/agentmux.db` and is managed automatically.

## Accomplished
- Implemented shared Swift modules: `appctl`, `streamctl`.
- Implemented stream lifecycle backend: `create`, `capture`, `show`, `destroy`.
- Implemented CLI project/stream CRUD:
  - `project list/create/update/delete`
  - `stream list/create/update/capture/destroy`
- Implemented `doctor` diagnostics for captured/missing windows.
- Implemented AppKit GUI MVP:
  - project list/add/edit/delete
  - stream list/add/edit/destroy
  - stream actions: `capture`, `show`, `doctor`
  - status line feedback
- Added warning on `show` when no captured windows can be focused (suggests closing/reopening windows).
- Added repeatable smoke script: `Tests/smoke_cli.sh`.

## Remaining
- GUI polish:
  - better validation messages and inline guidance
  - richer stream row details (sorting/filtering)
- Optional: show captured windows list in GUI
- Deeper automated tests for yabai integration (beyond smoke shell script)

## Next Task (start here)
- Add a GUI modal to display captured windows for a stream.
