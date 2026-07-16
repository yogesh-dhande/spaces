# Spaces

Manage parallel coding sessions across all of your devices

[Download](https://github.com/yogesh-dhande/spaces/releases/latest) · [Website](https://usespaces.dev) · [Docs](https://usespaces.dev/docs)

## Features

- **Projects and workspaces** — a project is any directory, Git or not; a workspace is one feature, branch, or experiment inside it, backed by a Git worktree or a separate clone. Keeps parallel work separate instead of stashing and switching branches in one checkout.
- **Agent orchestration** — one coding agent runs a fleet of child agents through the [Spaces MCP server](https://usespaces.dev/docs/orchestration), each child in its own isolated worktree, across harnesses, models, and machines. Delegate a big task and coordinate the whole team from a single terminal.
- **Agent notifications and an alerts view** — [coding agents](https://usespaces.dev/docs/coding-agents) report when they are working, blocked on a human, or done, aggregated with exited processes across every workspace. Tells you which agent needs attention without opening each terminal.
- **Built-in terminals** powered by [libghostty](https://github.com/ghostty-org/ghostty)
- **Managed ports and processes** — declare named services and processes once; each workspace gets its own dynamically assigned ports, exposed as `$SPACES_<SERVICE>_PORT`. Several checkouts of the same app run side by side without port conflicts or hand-edited `.env` files.
- **Window management** — each workspace tracks its processes, browser sessions, and agent terminals so you can jump to any terminal or chrome tab with keyboard shortcuts.
- **Caddy reverse proxy** — a bundled proxy serves every service at a stable URL like `http://api.my-branch.localhost:7391`. One address per service that never changes, and a separate cookie jar per workspace so logins don't collide across branches.
- **Remote machines** — pair with a Mac or Ubuntu machine and drive its workspaces, terminals, and processes from your laptop. Sessions run on the remote daemon and survive app quits.
- **iPhone control** — the iOS client pairs by QR code and attaches to any live terminal session. Check on a long-running agent or process away from your desk.
- **CLI** — [`spaces`](https://usespaces.dev/docs/cli) cli drives projects, workspaces, and terminal sessions from a shell. Scriptable, and the way coding agents report status.
- **MCP server** — [`spaces mcp`](https://usespaces.dev/docs/mcp) exposes projects, workspaces, and terminals as tools. A coding agent can inspect and drive Spaces directly.
- **Keyboard shortcuts** — focus and cycle windows scoped to the current workspace. Navigation stays inside the work you're on.
- **Global command palette** — `⌘⌥-` jumps to any window in any workspace. One key to reach anything without hunting through Mission Control.

## Requirements

- macOS 14+
- Google Chrome (for browser-session focus) - On first launch Spaces asks macOS for permission to control Google Chrome (the Automation privacy permission) so it can focus browser sessions. Grant it to enable browser-session focus.

## Install

Download the signed DMG from [GitHub Releases](https://github.com/yogesh-dhande/spaces/releases/latest).

## Development

Full build, test, lint, coverage, manual E2E, and release workflows: [`docs/dev.md`](docs/dev.md).

## License

See [LICENSE](LICENSE).
