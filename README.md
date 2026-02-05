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

## CLI (core)
```bash
agentmux project create --name <name> --repo-root <path>
agentmux project update --name <name> [--repo-root <path>]
agentmux project delete --name <name>

agentmux stream create --project <name> --stream <stream> --display <n> --space <n>
agentmux stream update --project <name> --stream <stream> [--display <n>] [--space <n>]
agentmux stream capture --project <name> --stream <stream>
agentmux stream destroy --project <name> --stream <stream>

agentmux show --project <name> --stream <stream>
agentmux doctor [--project <name>] [--stream <name>]
```

Note: If `show` reports that no compatible windows could be focused, close and reopen the target app windows, then re-run `stream capture`.

## Build
```bash
swift build
```
