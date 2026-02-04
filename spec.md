# agentmux Product Spec (Current)

## 0. Summary

`agentmux` is a macOS-native stream orchestrator for coding workflows.

It manages:
- **Projects** (repo roots + window configuration)
- **Streams** (git worktrees per project)
- **Window lifecycle** (`show`, `hide`, `focus`, `destroy`) with deterministic positioning

Window model is **unified**: each project stores a list of window specs with a `kind`:
- `editor`
- `browser`
- `terminal`
- `custom`

No fixed editor/browser/terminal sections are required in project config.

---

## 1. Scope

### MUST (MVP)
1. Project + Stream model in local SQLite
2. Stream create/destroy with git worktrees
3. Per-stream window launch/attach/reposition
4. Multi-monitor placement via half/quarter tiles
5. Deterministic targeting by bundle ID + persisted stream identity
6. Stream diagnostics (`doctor`)
7. Terminal activity status tracking for command-backed terminal windows
8. AppKit GUI for project/stream/window operations

### SHOULD
- Better validation and guided inputs in GUI
- Better remediation text in diagnostics

### NOT IN MVP
- Spaces management
- Full session restore
- Cloud sync/state

---

## 2. Core Concepts

### Project
- `id`, `name`, `repoRoot`
- defaults (`defaultEditor`, `defaultBrowser`, `defaultTerminal`) kept for compatibility in orchestration defaults
- `windows[]` where each entry includes:
  - `name`
  - `kind` (`editor|browser|terminal|custom`)
  - `bundleID`
  - `layout` (`displayIndex`, `tile`)
  - optional fields by kind:
    - editor: `editorKind`, `matchTitle`
    - browser: `urls` (GUI currently uses one URL per browser window)
    - terminal: `command`
    - custom: `launchCommand`, `matchTitle`

### Stream
- `id`, `projectID`, `name`, `worktreePath`
- Worktree branch defaults to stream name on create.

### Stream Window Identity
Persisted per stream:
- `windows[]` identities (`name`, `bundleID`, optional `windowID`, optional `windowTitle`, optional `anchorURL`)
- `updatedAt`

---

## 3. Window Targeting Rules

Hard requirements:
1. Target apps by **bundle ID**
2. Before setting frame:
   - exit fullscreen
   - refetch window
   - unminimize if needed
   - apply position + size
3. Continue best-effort for non-critical windows; avoid global failure from single-window drift

---

## 4. Stream Lifecycle Semantics

### `stream create`
- Validate project exists
- Create git worktree
- Persist stream + seed empty window identity

### `show`
- If stream windows are found: focus/unminimize/reapply layout
- Else: run `up` behavior (launch/create as needed)
- Mark stream active

### `hide`
- Minimize known stream windows
- Mark stream inactive

### `focus`
- Bring/focus windows and reapply layout
- Refresh identity opportunistically
- Mark stream active

### `destroy`
- Hide windows
- Close browser window when anchor is available
- Remove git worktree (and branch optionally)
- Delete stream runtime/identity records

---

## 5. Terminal Status Tracking

For terminal windows with configured `command`:
- Launch command through managed wrapper:
  - `~/.agentmux/bin/agentwrap.sh`
- Wrapper writes status to:
  - `<worktree>/.agentmux/terminal-status/<terminal-name>.json`
- Status JSON is intentionally minimal:
  - `state`
  - `timestamp`

Expected states:
- `starting`
- `working`
- `waiting_for_input`
- `done`
- `error`
- `idle` (used when terminal has no configured command)

GUI streams table surfaces active terminal statuses and refreshes periodically.

---

## 6. Storage

SQLite at:
- default: `~/.agentmux/agentmux.db`
- optional override: `--db <path>`

Tables:
- `projects`
- `streams`
- `stream_runtime`
- `stream_window_identity`

---

## 7. UX Requirements (Current)

### GUI
- Projects pane:
  - add/edit/delete/refresh
- Project edit modal:
  - manage windows inline (add via dropdown menu, edit selected, remove selected)
- Streams pane:
  - add/destroy/refresh
  - show/hide/focus/doctor
  - display terminal status summaries

### CLI
- project CRUD
- project window CRUD
- stream create/list/destroy
- show/hide/focus
- list-active
- doctor

---

## 8. Diagnostics

`doctor` reports per stream:
- found windows count
- expected windows count
- list of missing window names

Further improvement area:
- richer remediation details for missing permissions/app launch issues

---

## 9. Testing

Current persistent coverage:
- `Tests/smoke_cli.sh`
  - project/window CRUD
  - stream create/destroy
  - show/hide active-state checks
  - doctor output shape check

Future:
- deeper module-level automated tests once toolchain constraints permit stable test target execution.
