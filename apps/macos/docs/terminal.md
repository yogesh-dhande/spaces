# Built-in Terminal

This document captures the current libghostty-backed terminal integration in Spaces: what it is, how it is wired, what constraints shaped it, and what remains intentionally out of scope for this branch. User-facing behavior belongs in [spec.md](../spec.md). Module boundaries and broader app architecture belong in [architecture.md](architecture.md).

## Scope
- Spaces supports two built-in terminal backends:
  - `script-pty`
  - `ghostty-embedded`
- `ghostty-embedded` is the native terminal path for Spaces-owned windows.
- iTerm2 and Ghostty external-host integrations still exist on this branch and remain selectable overrides.

## Why libghostty Owns the Session
- A built-in owner window cannot be just a renderer wrapped around an unrelated PTY daemon.
- `spaces terminal send`, `spaces terminal key`, `spaces terminal tail`, takeover, and owner or viewer attachment all need one terminal runtime to own:
  - the PTY
  - terminal parsing and modes
  - raw output capture
  - raw input injection
  - render-state updates
- Because of that, the `ghostty-embedded` path is app-hosted and session-backed. The visible macOS owner window and the CLI control plane talk to the same underlying libghostty session.

## Runtime Shape
- `spacesterminalcore` owns session records, client records, attachment persistence, output paths, and control protocol types.
- `spacesterminalruntime` chooses the backend runtime for a session.
- `spacesterminalghostty` owns libghostty artifact discovery, session host behavior, clipboard hooks, runtime callbacks, and the native terminal view.
- `spacesterminalui` owns the window controller shell and local owner or viewer attachment UX.

The `ghostty-embedded` session path is:
1. `spaces terminal command --backend ghostty-embedded` persists launch metadata.
2. The running app creates or reuses a `GhosttyEmbeddedSessionHost`.
3. The host starts one `GhosttyEmbeddedTerminalView`, one control socket, one output log, and one runtime-state refresh loop.
4. Owner windows attach the live libghostty surface.
5. Viewer windows stay passive and read from the tailed session output until they take over.

## Session Files
Each session lives under `~/.spaces/terminal/sessions/<session-id>/` and keeps:
- `metadata.json`: launch configuration and declared backend
- `state.json`: live runtime state, including backend and child PID
- `output.log`: append-only terminal output used by `tail`
- `clients.json`: known client identities
- `attachments.json`: owner or viewer attachment history
- `control.sock`: local control-plane socket

The control socket path is shortened through `TerminalSessionPaths` so isolated `SPACES_DB_PATH` roots do not exceed Unix socket path limits.

## Additive libghostty Surface
Spaces depends on an additive patch strategy rather than a behavior fork.

The current integration assumes these exported hooks exist:
- `ghostty_surface_set_data_callback(...)`
  Used to tee raw PTY output into `output.log` for `spaces terminal tail` and passive viewers.
- `ghostty_surface_send_input_raw(...)`
  Used for exact control-plane input so `send` and `key` are not forced through paste semantics.

These hooks are important because snapshot-style render reads are not enough for:
- exact owner-only input injection
- incremental tail access
- snapshot-plus-stream attach semantics
- multi-client session ownership that is separate from one visible macOS window

## Owner and Viewer Model
- A session can have one active owner client and zero or more viewer clients.
- Only the owner can:
  - send text
  - send keys
  - hold the live libghostty surface
  - drive PTY size implicitly through the live owner window
- Viewer windows:
  - stay passive
  - show owner identity
  - can request takeover
  - continue using tailed output until ownership changes
- Once a session is no longer running, passive viewer windows stop presenting takeover affordances, script-pty fallback windows disable their inline send controls, and owner-window paste actions stop claiming the session is still interactive.

The takeover path updates `attachments.json`, moves ownership to the requested client, and rehosts the active libghostty surface without restarting the session.
Local macOS windows also react to ownership changes immediately through an in-process attachment-state notification, so owner and viewer chrome does not wait for the polling loop to catch up after takeover.
Live libghostty title and working-directory updates also propagate through an in-process metadata notification so the owner window title and summary stay in sync without waiting for the refresh loop.
Live runtime-state changes also propagate through an in-process notification so owner windows update compact state text, including the visible child PID, as soon as the session host persists a new runtime signature.
Active owner windows keep a slower two-second safety poll because the libghostty path already delivers direct attachment, metadata, and runtime-state notifications. Viewer and fallback windows stay on the faster 500 ms poll because they still depend on tailed output refresh.

## Native Window Behavior
- Active owner windows keep the libghostty surface as the primary experience.
- Viewer and fallback windows keep more diagnostic metadata because they are not the active terminal surface.
- When Spaces refocuses a live built-in process window, it also reasserts first-responder focus onto the owner libghostty surface so the user can type immediately after the window comes forward.
- If the running app already has one unambiguous live owner controller for that session, it reuses that in-memory owner window directly during focus instead of reloading attachment state from disk first.
- The owner path intentionally collapses redundant in-window chrome:
  - hides the in-window session ID
  - hides the redundant inline cwd and command summary once the titlebar carries live terminal title and path
  - hides renderer diagnostics
  - hides steady-state `running` status text for the active owner path, while still surfacing non-running or error state
  - hides empty status rows
  - collapses the entire inline header band when there is no owner status or error worth showing
  - uses compact runtime text such as `state` and `child`
- When the active owner session leaves steady-state `running`, the inline summary band expands again so the user can see session context while the terminal is exited or otherwise non-running.
- The native window titlebar remains the primary place for the live terminal title.
- Owner windows also project the live working directory into the native titlebar represented path when that directory exists on disk, so the proxy icon and document path behave like a normal macOS terminal window.
- Built-in terminal windows explicitly disable AppKit tabbing; one terminal session maps to one window.
- Built-in owner and viewer windows persist their last local frame per attachment mode, so close and reopen returns to the user’s last size and position instead of a generic default rectangle.

## Input, Mouse, and Clipboard
The active owner surface currently supports:
- direct keyboard input through the terminal view
- command-key bindings that libghostty claims
- raw `send` and `key` from the CLI
- mouse position and button forwarding
- mouse-move tracking while the owner window is key
- scroll-wheel forwarding
- copy from terminal selection
- paste from the macOS pasteboard
- owner-window focus reassertion when ownership is promoted locally
- owner-surface focus resync during window resize as well as app and window activation changes

The owner window controller also routes standard AppKit edit actions to the active terminal session:
- `Copy` reads from the live libghostty selection when the window owns the session
- `Paste` sends pasteboard text into the owner session rather than the hidden inline input field
- fallback or viewer windows keep using the text-output or inline-input path instead of pretending they own the live terminal surface
- fallback or viewer windows preserve selection plus both horizontal and vertical scroll position when new tailed output arrives, instead of snapping back to the bottom or left edge on every refresh

The headless `ghostty-embedded` backend runtime disables selection clipboard hooks because it is not the user-facing surface. The app-hosted owner path enables clipboard hooks through `GhosttyEmbeddedAppService`.

## Metadata and Runtime State
`GhosttyEmbeddedSessionHost` persists live runtime state derived from the active surface, including:
- foreground child PID
- live title
- live working directory

The host keeps the last non-nil foreground PID so transient libghostty zeroes do not erase the visible process identity for workspace-launched sessions.

The host also avoids rewriting `state.json` on every timer tick. Steady-state sessions persist runtime state when the effective session state changes and on a light heartbeat, which keeps owner windows responsive during long-running sessions without dropping liveness information.

## Performance Notes
The active owner path is treated as a hot rendering path.

Current performance decisions:
- `GhosttyEmbeddedTerminalView` caches the last surface geometry, focus state, and occlusion state before calling libghostty.
- If embedded Ghostty startup fails, the terminal view backs off surface creation retries briefly and suppresses duplicate failure logs until the next distinct error, so owner-window refreshes do not churn the same failing setup path.
- Owner-window focus avoids unnecessary `makeKeyAndOrderFront` and repeated focus toggles when the view is already first responder.
- Active owner windows skip fallback `output.log` tail reads while the live libghostty surface is visible, so steady-state refresh ticks do not churn hidden text views.
- Active owner windows also use the slower notification-first refresh cadence above, which keeps the live terminal path responsive without doing the same fallback polling work as passive windows.
- Active owner windows fall back to the faster 500 ms cadence again whenever the runtime state is no longer steady-state `running`, so exited or warning states refresh like the diagnostic viewer path instead of waiting on the slower safety poll.
- Fresh terminal window controllers do an immediate one-time render pass during construction but do not start their periodic refresh loop until `show()`, so summon and reopen avoid canceling and restarting a loop that the user has not seen yet.
- App-managed terminal summon paths also skip that constructor refresh for newly created controllers and rely on `show()` for the first render pass, so a real window summon does not pay the same synchronous metadata and output read twice.
- Reusing an already visible terminal window does not reapply its persisted frame or restart the refresh loop. Spaces brings that live window forward and refreshes it in place instead of treating it like a fresh summon.
- Owner-window summon also checks the in-memory live owner fast path before resolving session file paths, so the hottest reuse path does not pay unnecessary session-root work when the window controller is already alive.
- Owner and viewer frame persistence is coalesced during move and resize, then flushed immediately on live-resize end or window close so drag-heavy sessions do not spam synchronous state writes.
- Built-in workspace-process reopen prefers the currently focused `Spaces` window when rebinding a reopened owner session, instead of diffing broader yabai window snapshots first.
- Built-in workspace-process focus also tries the session-focus IPC path before it asks the app to reopen a built-in owner window, so a live owner controller with a missing persisted `windowID` can be rebound without unnecessary summon churn.
- The session-focus IPC path is focus-only. It reuses a live owner controller when one exists and leaves window creation to the explicit open IPC, so the `reopened_session` path does not pay redundant app-side summon work before the real reopen request.
- The app-side session-focus IPC also exits before resolving session files when there are no live controllers for that session, and it emits `terminal_window_focus_ipc` route metrics (`in_memory_owner`, `persisted_owner`, `missing`) so workspace-process profiles can show whether focus IPC actually reused a live window.
- Workspace-process focus metrics distinguish that lighter `rebound_session` path from a true `reopened_session`, so profile runs can separate live-window rebind cost from actual window recreation cost.
- The workspace-process profiler prints both the workspace-process focus route and the app-side `terminal_window_focus_ipc` route, which makes it easier to see whether a slow reopen actually tried and missed the live-window focus path or never exercised it.
- The built-in terminal profiler treats `spaces terminal command --backend ghostty-embedded` as the owner summon itself and waits for the first owner attach, instead of immediately posting a second owner `terminal show` that would measure an artificial re-summon.
- Session output still streams directly to `output.log`, but session runtime-state persistence is coalesced so steady-state windows are not constantly paying synchronous metadata write costs.
- Built-in terminal actions emit debug metrics through the shared `spaces: perf metric=...` format when `DEBUG=1`, including:
  - `terminal_session_start`
  - `terminal_surface_create`
  - `terminal_window_attach`
  - `terminal_window_summon`
  - `terminal_window_focus_ipc`
  - `terminal_owner_focus_sync`
  - `terminal_control_send`
  - `terminal_control_key`
  - `terminal_control_takeover`

These metrics are intended to guide regressions around owner-window attach, owner-focus reassertion, session bring-up, control-plane latency, and ownership handoff.

## Current Verification Baseline
The current branch has verified:
- `spaces terminal command`
- `spaces terminal list`
- `spaces terminal send`
- `spaces terminal key`
- `spaces terminal tail`
- `spaces terminal show`
- `spaces terminal takeover`
- owner or viewer attachment persistence
- owner-window reopen and reuse
- workspace-process launch into `Spaces` terminal sessions
- built-in process recovery when only the process row remains
- built-in process focus and reopen when stale yabai window IDs must be cleared or replaced

## Known Constraints
- Passive viewer windows still use tailed output rather than a second live libghostty surface.
- iPhone or VPN clients are intentionally out of scope for this branch.
- External iTerm2 and Ghostty hosts remain supported overrides on this branch.
- The Ghostty static archive still emits non-fatal linker warnings about ImGui-related symbols during build.

## Manual Verification
For branch-local manual checks:

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-ghostty/spaces.db"
apps/macos/scripts/setup_ghosttykit.sh
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces \
  terminal command --backend ghostty-embedded --command cat --title verify-ghostty
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces terminal list
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces \
  terminal send <session-id> "hello from ghostty" --newline
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces \
  terminal tail <session-id> --lines 10
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces \
  terminal show <session-id> --viewer
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces \
  terminal takeover <session-id> <viewer-client-id>
```

For repeatable performance sampling of the built-in terminal owner and viewer flows:

```bash
ITERATIONS=3 apps/macos/Tests/profile_built_in_terminal.sh
```

The profiler:
- installs or copies local Ghostty artifacts
- launches an isolated debug `SpacesApp` with `DEBUG=1`
- creates a `ghostty-embedded` session
- attaches an owner window and a viewer window
- sends input, verifies `tail`, and performs takeover
- aggregates the built-in terminal perf metrics into a short summary
- writes a machine-readable `metrics.json` baseline artifact next to the text summary
- breaks out `terminal_owner_focus_sync` samples by reason so focus churn can be tracked over time

## What This Branch Does Not Decide
- whether external hosts are removed in a later PR
- whether remote viewer clients should render via libghostty cells, byte streams, or another transport
- whether one session should ever have more than one simultaneously renderable libghostty surface on macOS
