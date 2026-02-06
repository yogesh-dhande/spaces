# agentmux Product Spec (Current)

## 0. Summary

`agentmux` is a macOS stream orchestrator that uses **yabai** for window‑level control.

It manages:
- **Projects** (repo roots)
- **Streams** (git worktrees per project)
- **Captured window sets** per stream

Window management is done via yabai window IDs captured from a given space.

---

## 1. Scope

### MUST (MVP)
1. Project + Stream model in local SQLite
2. Stream create/destroy with git worktrees
3. Window capture per stream (yabai window IDs, refreshed on `show`)
4. Stream actions:
   - `show`: capture current space windows, then focus captured windows
   - `destroy`: close captured windows
5. Stream diagnostics (`doctor`) for captured/missing windows
6. AppKit GUI for project/stream operations
7. Terminal command wrapper that emits per-window status files (`wrap`)

### SHOULD
- Better validation and guided inputs in GUI
- Better remediation text in diagnostics

### NOT IN MVP
- Automatic window discovery without capture
- Full session restore
- Cloud sync/state

---

## 2. Core Concepts

### Project
- `id`, `name`, `repoRoot`

### Stream
- `id`, `projectID`, `name`, `worktreePath`
- `displayIndex`, `spaceIndex` (used for capture target)

### Stream Window Identity
Persisted per stream:
- `windows[]` (`id`, `app`, `title`, `space`, `display`)
- `updatedAt`

### Terminal Window Status
Per focused terminal window:
- `state` (`starting`, `working`, `waiting_for_input`, `done`, `error`)
- `timestamp`, `exit_code`, `last_output`
- `project`, `stream`, `window_id`
- Stored at `<worktree>/.agentmux/status/window-<id>.json`
 - Emitted after the window is captured into a stream

---

## 3. Stream Lifecycle Semantics

### `stream create`
- Validate project exists
- Create git worktree
- Persist stream with display + space

### `stream capture`
- Query yabai windows for the stream's space
- Persist the captured window set
Note: optional; `show` performs capture automatically.

### `show`
- Capture current space windows and focus each captured window
- Mark stream active
- If no window can be focused, warn and recommend closing/reopening the target app windows, then re-run `show`

### `destroy`
- Close each captured window
- Remove git worktree (and branch optionally)
- Delete stream runtime/identity records

---

## 4. Diagnostics

`doctor` reports per stream:
- captured window count
- missing window ids
- yabai availability

---

## 5. Storage

SQLite at:
- path: `~/.agentmux/agentmux.db` (managed automatically)

Tables:
- `projects`
- `streams`
- `stream_runtime`
- `stream_window_identity`

---

## 6. UX Requirements (Current)

### GUI
- Projects pane:
  - add/edit/delete/refresh
- Streams pane:
  - add/edit/destroy/refresh
  - capture/show/doctor
  - display + space shown per stream
  - captured windows listed per stream as rows in a card, with status when available and auto-refresh

### CLI
- project CRUD
- stream create/update/list/destroy
- stream capture (optional)
- show
- list-active
- doctor
- wrap

---

## 7. Testing

Current persistent coverage:
- `Tests/smoke_cli.sh`
  - project CRUD
  - stream create/destroy
