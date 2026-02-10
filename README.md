# agentmux

`agentmux` is a local macOS control plane for workspace orchestration.
It manages projects, workspaces, processes, and window sets so you can move between coding contexts quickly.

## Requirements
- macOS 14+
- `yabai` installed and running (window IDs and focus)
- iTerm2 (terminal windows)
- Google Chrome (browser sessions)
- Accessibility permissions granted for window focus and control

## Configuration
YAML is the source of truth:
- Path: `~/.agentmux/config.yaml`
- Runtime DB: `~/.agentmux/agentmux.db` (ephemeral)
- Git worktrees: `/Users/<username>/agentmux/workspaces/<projectname>/<dirname>` (dirname is a unique food name)
- GUI shortcuts (when focused): `cmd+shift+1` through `cmd+shift+9` focus workspace windows
- Global window navigation (when GUI not focused): `cmd+shift+]` and `cmd+shift+[`

Example config:
```yaml
editor: vscode
port_range:
  start: 20000
  end: 30000
projects:
  - dir: /path/to/repo
    setup_script: cp /shared/.env .env
    cleanup_script: rm -f .env
    processes:
      - name: server
        command: PORT=$PORT0 npm run dev
    status_checks:
      - name: web
        process: server
        command: curl -fsS http://localhost:$PORT0/health
        interval: 10
        timeout: 2
        onExit: notify
    browser_sessions:
      - url: http://localhost:$PORT0
```

## GUI
- Two panes: projects/workspaces on the left, details on the right.
- No dialogs for add/edit; all forms are in the right pane.
- Workspace view includes:
  - Launch/Stop/Archive buttons
  - Processes and status
  - Windows list with shortcut hints
  - Env vars/ports tab

Hotkeys:
- Global focus: `cmd+shift+=`
- Next running workspace: `cmd+shift+]`
- Previous running workspace: `cmd+shift+[`
- Activate selected workspace: `cmd+shift+return`
- New workspace (when app is focused): `cmd+n`

## CLI
```bash
agentmux config path
agentmux config show

agentmux project list
agentmux project add --dir /path/to/repo
agentmux project update --dir /path/to/repo --setup-script "cp ~/.env .env"
agentmux project remove --dir /path/to/repo

agentmux workspace list --project-dir /path/to/repo --all
agentmux workspace create --project-dir /path/to/repo --name feature-x
agentmux workspace launch --project-dir /path/to/repo --name feature-x
agentmux workspace stop --project-dir /path/to/repo --name feature-x
agentmux workspace archive --project-dir /path/to/repo --name feature-x
agentmux workspace activate --project-dir /path/to/repo --name feature-x
```

## Build
```bash
swift build
```

## Tests
```bash
swift test
```

## Coverage
```bash
scripts/coverage.sh
```
