# agentmux

A local macOS control plane for AI coding streams.

`agentmux` manages:
- projects (`repo-root` + window specs)
- streams (git worktrees)
- deterministic window launch/attach/show/hide/focus across displays

## Current Model
- Projects have a generic list of windows, each with:
  - `name`
  - `kind` (`editor`, `browser`, `terminal`, `custom`)
  - `bundle-id`
  - layout (`display`, `tile`)
  - kind-specific fields (for example: browser URL, terminal command, custom launch command)
- Streams are per-project worktrees and can be shown/hidden/focused independently.

## Terminal Status Tracking
- Terminal windows with a configured command are launched via a wrapper script.
- Wrapper path: `~/.agentmux/bin/agentwrap.sh` (managed by `agentmux`).
- Status files are written per stream terminal at:
  - `<worktree>/.agentmux/terminal-status/<terminal-name>.json`
- Status payload is intentionally minimal:
  - `state`
  - `timestamp`
- GUI streams list shows active terminal statuses and refreshes periodically.

## CLI (core)
```bash
agentmux project create --name <name> --repo-root <path>
agentmux project window add --project <name> --name <win> --kind <editor|browser|terminal|custom> --bundle-id <id> --display <n> --tile <tile> [kind-specific flags]
agentmux stream create --project <name> --stream <stream>
agentmux show --project <name> --stream <stream>
agentmux hide --project <name> --stream <stream>
agentmux focus --project <name> --stream <stream>
agentmux doctor [--project <name>] [--stream <stream>]
```

## Build
```bash
swift build
```
