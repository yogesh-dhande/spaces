# Spaces

Multiplex your work. Not just the terminal.

Native macOS app and CLI for orchestrating parallel coding sessions, plus a paired first-party iOS terminal client. Groups terminals, editors, browser windows, and CLI coding agents (`claude`, `codex`, `opencode`, etc.) into per-branch workspaces with isolated named services, environment, and process trees.

[usespaces.dev](https://usespaces.dev) · [Download](https://github.com/yogesh-dhande/spaces/releases/latest) · [Docs](https://usespaces.dev/docs)

![GUI](apps/web/public/media/gui.png)
![Command palette](apps/web/public/media/palette.png)

## What it does

A workspace is one feature, branch, or experiment with:

- a directory (Git worktree or separate clone)
- named services routed through a bundled Caddy reverse proxy, each reachable at a stable per-workspace URL like `http://api.my-branch.localhost:8088`
- configured processes, browser URLs, and coding-agent terminals
- a tracked set of dedicated windows for its processes, browser sessions, and coding agents

Launching a workspace starts its processes, opens its windows, and tracks them. Keyboard shortcuts focus or cycle windows scoped to the current workspace. Stopping shuts down processes and closes windows. Reopening restores state.

Worktrees, clones, and concurrent process trees stay isolated — each service gets a dynamically assigned port (exposed to processes as `$SPACES_<SERVICE>_PORT`) and a predictable per-workspace URL through Caddy on `http://<service>.<workspace>.localhost:8088`. Per-workspace hostnames keep cookies and local storage from colliding across branches, so you can run several workspaces of the same app side by side without remembering which port each service holds.

![Workspace detail](apps/web/public/media/demo_setup.gif)

## CLI

The `spaces` CLI is workspace-oriented and ID-based:

```
spaces project list
spaces workspace list
spaces workspace create --project <id> --branch feature/demo
spaces workspace start --workspace <id>
spaces workspace restart --workspace <id>
spaces pair                                 # open a short-lived same-device pairing window
spaces agent signal --workspace <id> --session <terminal-session-id> blocked
spaces terminal command --command "cat"   # start a Spaces terminal session
spaces terminal list                      # inspect live session IDs and working directories
spaces terminal send <session> "hello"    # write input to a session
spaces terminal key <session> ctrl+c      # send a named key or control chord
spaces terminal tail <session> --lines 20 # read recent output
spaces terminal show <session>            # open an owner-seeking window for a session
spaces terminal takeover <session> <id>   # hand input ownership to another client
```

Coding agents emit explicit `spaces agent signal` events from their terminals so the GUI knows which agents are working, waiting on a human, or done. See [coding-agent integration](https://usespaces.dev/docs/coding-agents).

## Features

- Alerts view aggregating exited processes and blocked/done coding agents across all workspaces.
- Workspaces backed by Git worktrees or separate clones.
- Per-workspace named services with dynamically assigned ports surfaced to processes via env vars and routed through a bundled Caddy proxy at stable `*.localhost` URLs.
- Global command palette (`⌘⌥-` by default) for any window across any workspace.

![Global command palette](apps/web/public/media/demo_palette.gif)
- Per-workspace navigation and window cycling — focus stays inside the current workspace.

![Workspace navigation](apps/web/public/media/demo_nav.gif)
- Workspace notes — coding agents can write context (what's pending, where things broke) into a per-workspace notes field, surfaced inline in the workspace detail pane.
- One-click workspace teardown closes tracked windows and shuts down processes; relaunching restores them.
- Native AppKit binary, under 10 MB.

## How it works

- The Spaces app tracks and focuses windows directly: its own AppKit windows for Spaces terminals, Chrome window IDs for browser sessions, Spaces terminal session IDs for processes and coding agents, and process IDs for cleaning up non-terminal processes.
- Built-in process and ad hoc terminals run through the paired device's `spacesd`, so sessions survive app quits and lifetime, takeover, and `spaces terminal` controls share one daemon-owned boundary.
- Every Mac or Linux `spacesd` owns its own database, projects, workspaces, runtime rows, terminal sessions, and workspace filesystem. macOS and iOS apps are thin clients connected to one active paired device.
- iOS pairing uses the short-lived QR/deep link from `spaces pair` or the Mac Devices panel. Remote-device pairing validates SSH, prepares supported Linux hosts from the signed release artifact when needed, opens the remote daemon's pairing window over `~/.spaces/bin/spaces pair --json`, pins the daemon TLS identity, and stores the client token in Keychain. Remote Macs require the DMG install.
- The `spaces` CLI targets the same-machine daemon. Remote macOS terminal attach, browser forwarding, and editor opening use SSH to the paired device when those features are invoked from the Mac app.
- The first-party iOS client pairs through QR/deep link, selects among paired devices, browses live Spaces terminal sessions, auto-takes ownership when opening one for live rendering, and can ask a paired macOS daemon to launch the Mac app after an app quit or crash.
- Browser sessions automate Google Chrome so you can quickly switch to view output without typing the URL or clicking through tabs.

## Requirements

- macOS 14+
- Google Chrome (for browser-session focus)

On first launch Spaces asks macOS for permission to control Google Chrome (the Automation privacy permission) so it can focus browser sessions. Grant it to enable browser-session focus.

## Install

Download the signed DMG from [GitHub Releases](https://github.com/yogesh-dhande/spaces/releases/latest). The installer drops `Spaces.app`, `/usr/local/bin/spaces`, `/usr/local/bin/spacesd`, `~/.spaces/bin` helper links, and a per-user LaunchAgent that keeps `spacesd` available after login. In-app updates are delivered via Sparkle.

## Development

Full build, test, lint, coverage, manual E2E, and release workflows: [`docs/dev.md`](docs/dev.md).

## License

See [LICENSE](LICENSE).
