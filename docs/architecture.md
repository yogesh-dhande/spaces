# Architecture

## Overview
`agentmux` is a macOS Swift app for stream-based workspace orchestration. A stream is a captured set of windows tied to a workspace. YAML is the source of truth for configuration, while SQLite is an ephemeral runtime cache that can be rebuilt when the schema changes.

Key invariants:
- YAML config is the source of truth and is normalized on load.
- SQLite stores runtime state and can be recreated when the schema version changes.
- yabai is the source of truth for window IDs and focus.
- Stream capture must happen before a stream is shown or focused.
- Avoid window-level automation outside yabai.

## Module Map
```mermaid
flowchart LR
  cli["agentmux (CLI)"] --> stream["streamctl"]
  guiapp["agentmux-app (App entrypoint)"] --> gui["gui (AppKit UI)"]
  gui --> stream

  stream --> config["YAML config"]
  stream --> db["SQLite runtime DB"]
  stream --> appctl["appctl (system adapters)"]
  stream --> git["Git client"]
  stream --> editor["Editor launcher"]

  appctl --> yabai["yabai"]
  appctl --> iterm["iTerm2 (AppleScript)"]
  appctl --> chrome["Chrome (AppleScript)"]
```

Module responsibilities:
- `appctl`: Shell + AppleScript adapters for yabai, iTerm2, and Chrome.
- `streamctl`: Orchestration, config normalization, port allocation, workspace lifecycle, and persistence.
- `gui`: AppKit UI library that calls into `streamctl`.
- `agentmux`: CLI entrypoint that calls into `streamctl`.
- `agentmux-app`: GUI executable entrypoint that wires `NSApplication` to the `gui` library.

The `gui` target is the reusable UI library. `agentmux-app` is the minimal executable that boots AppKit and delegates to `gui`.

## Data Model
Config file:
- Path: `~/.agentmux/config.yaml`.
- Top-level fields: `editor`, `port_range`, `projects`.
- Project fields: `dir`, `setup_script`, `cleanup_script`, `processes`, `status_checks`, `browser_sessions`.

Runtime database:
- Path: `~/.agentmux/agentmux.db`.
- Schema is recreated when `schema_version` changes.

```mermaid
erDiagram
  projects ||--o{ workspaces : has
  workspaces ||--o{ workspace_ports : allocates
  workspaces ||--o{ running_processes : runs
  running_processes ||--o{ status_results : checks
  workspaces ||--o{ windows : captures

  projects {
    TEXT id PK
    TEXT name
    TEXT dir
    INTEGER is_git
    TEXT default_branch
  }

  workspaces {
    TEXT id PK
    TEXT project_id
    TEXT name
    TEXT dir
    TEXT dirname
    TEXT branch
    INTEGER is_default
    INTEGER is_archived
    INTEGER is_running
    TEXT last_launched_at
  }

  workspace_ports {
    TEXT workspace_id PK
    INTEGER port_index PK
    INTEGER port_number
  }

  running_processes {
    TEXT id PK
    TEXT workspace_id
    TEXT template_name
    TEXT command
    TEXT terminal_app
    INTEGER window_id
    INTEGER pid
    TEXT status
    TEXT log_path
    TEXT last_output_at
    TEXT started_at
    TEXT exited_at
  }

  status_results {
    TEXT process_id PK
    TEXT check_name PK
    TEXT status
    TEXT message
    TEXT last_run_at
  }

  windows {
    TEXT id PK
    TEXT workspace_id
    TEXT app
    TEXT title
    INTEGER window_id
    TEXT role
    INTEGER order_index
    TEXT last_seen_at
  }

  settings {
    TEXT key PK
    TEXT value
  }

  schema_version {
    INTEGER version
  }
```

## Workspace Lifecycle
Create and prepare a workspace:
```mermaid
flowchart TD
  start["Create workspace"] --> git{"Project is git repo?"}
  git -->|"yes"| worktree["Create or reuse worktree"]
  git -->|"no"| dir["Use project dir"]
  worktree --> setup["Run setup_script (if set)"]
  dir --> setup
  setup --> ports["Allocate PORT0-PORT9"]
  ports --> persist["Persist workspace + ports"]
```

Launch and capture windows:
```mermaid
flowchart TD
  launch["Launch workspace"] --> processes["Start processes in iTerm2"]
  processes --> browser["Open browser sessions in Chrome"]
  browser --> editor["Open editor (if configured)"]
  editor --> capture["Capture window IDs via yabai"]
  capture --> store["Store windows in DB"]
```

Stop or archive:
- Stop: close tracked windows, stop processes, clear runtime process state.
- Archive: stop, run `cleanup_script` (if set), remove worktree for git projects, release ports.

## Window Capture and Focus
```mermaid
sequenceDiagram
  actor User
  participant GUI
  participant Orchestrator
  participant Iterm2
  participant Chrome
  participant Yabai
  participant DB

  User->>GUI: Launch workspace
  GUI->>Orchestrator: launchWorkspace(...)
  Orchestrator->>Iterm2: open terminals (AppleScript)
  Orchestrator->>Chrome: open sessions (AppleScript)
  Orchestrator->>Yabai: query windows
  Orchestrator->>DB: store window IDs

  User->>GUI: Focus window (hotkey)
  GUI->>Orchestrator: focusWorkspaceWindow(...)
  Orchestrator->>Yabai: focusWindow(id)
```

## External Dependencies
- macOS 14+
- `yabai` for window IDs, focus, and display/space metadata
- iTerm2 for terminal processes
- Google Chrome for browser sessions
- Yams for YAML config parsing and encoding
- SQLite3 for runtime persistence
