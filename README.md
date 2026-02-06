# agentmux

A local macOS control plane for AI coding streams.

`agentmux` manages:
- projects (`repo-root`)
- streams (git worktrees)
- window sets captured per stream via **yabai**

## Requirements
- macOS
- `yabai` installed and running
- Accessibility permissions granted (for yabai window actions)

## Getting Started (GUI)
1. Launch the `agentmux` app.
2. Add a project:
   - Name: a short identifier (e.g. `agentmux`).
   - Repo Root: the absolute path to the git repository.
3. Create a stream:
   - Stream Name: a branch/worktree name (e.g. `feature-x`).
   - Display/Space: the target macOS display/space indices.
4. Open your editor/terminal in the stream worktree.
5. Use `show` to capture and recall the windows later (capture is automatic).

## Common Issues
- `yabai` missing or not running:
  - Install: `brew install yabai`
  - Start: `yabai --start-service`
- Accessibility permissions missing:
  - Go to System Settings -> Privacy & Security -> Accessibility.
  - Enable access for `yabai` and `agentmux` (if listed).
- Re-run `show` after granting access.

## Current Model
- Projects have:
  - `name`
  - `repo-root`
- Streams have:
  - `name`
  - `worktree-path`
  - `display index`
  - `space index`
- Each stream has a captured set of windows (yabai window IDs)
- Each terminal window can emit a status file via `agentmux wrap`

Note: If `show` reports that no compatible windows could be focused, close and reopen the target app windows, then re-run `show`.
Note: Database state is stored at `~/.agentmux/agentmux.db` and is managed automatically.

## Terminal Status Tracking
Use `agentmux wrap` to run a command under a PTY and publish status per terminal window:
```bash
agentmux wrap [--project <name> --stream <name>] -- <command> [args...]
agentmux wrap [--project <name> --stream <name>] <command> [args...]
```
Status files are written to `<worktree>/.agentmux/status/window-<id>.json` once the focused window is captured by `show`.
The GUI stream list shows a card per stream with one row per captured window (app/title) and status when available, auto-refreshing periodically.

## Build
```bash
swift build
```
