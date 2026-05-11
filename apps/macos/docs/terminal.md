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
- fallback or viewer windows preserve selection plus both horizontal and vertical scroll position when new tailed output arrives, including when the transcript is pinned to the bottom
- fallback transcript output disables smart quotes, dashes, spell correction, text replacement, and text completion so AppKit editing helpers do not mutate copied terminal text
- fallback windows choose a focused first responder on show: interactive inline-input sessions land in the input field, while passive viewer transcripts land directly in the output view for keyboard selection and scrolling

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
- If a window controller is created before `metadata.json` is readable, the next refresh upgrades that window to the persisted backend instead of leaving it stuck on fallback `script-pty` controls.
- Active owner windows fall back to the faster 500 ms cadence again whenever the runtime state is no longer steady-state `running`, so exited or warning states refresh like the diagnostic viewer path instead of waiting on the slower safety poll.
- Fresh terminal window controllers do an immediate one-time render pass during construction but do not start their periodic refresh loop until `show()`, so summon and reopen avoid canceling and restarting a loop that the user has not seen yet.
- App-managed terminal summon paths also skip that constructor refresh for newly created controllers and rely on `show()` for the first render pass, so a real window summon does not pay the same synchronous metadata and output read twice.
- Reusing an already visible terminal window does not reapply its persisted frame or restart the refresh loop. Spaces brings that live window forward and refreshes it in place instead of treating it like a fresh summon.
- Owner-window summon also checks the in-memory live owner fast path before resolving session file paths, so the hottest reuse path does not pay unnecessary session-root work when the window controller is already alive.
- Owner and viewer frame persistence is coalesced during move and resize, then flushed immediately on live-resize end or window close so drag-heavy sessions do not spam synchronous state writes.
- Built-in workspace-process reopen prefers the currently focused `Spaces` window when rebinding a reopened owner session, instead of diffing broader yabai window snapshots first.
- Built-in workspace-process focus also tries the session-focus IPC path before it asks the app to reopen a built-in owner window, so a live owner controller with a missing persisted `windowID` can be rebound without unnecessary summon churn.
- Ad hoc built-in terminal rows keep their tracked session identity even before yabai assigns a native window ID. Background workspace refresh treats a `Spaces` terminal row as live when its session control socket and runtime state are still present, so shortcut-opened `shell-*` windows stay visible in the workspace detail view instead of being pruned during the first refresh.
- The session-focus IPC path is focus-only. It reuses a live owner controller when one exists and leaves window creation to the explicit open IPC, so the `reopened_session` path does not pay redundant app-side summon work before the real reopen request.
- The app-side session-focus IPC also exits before resolving session files when there are no live controllers for that session, and it emits `terminal_window_focus_ipc` route metrics (`in_memory_owner`, `persisted_owner`, `missing`) so workspace-process profiles can show whether focus IPC actually reused a live window.
- Workspace-process focus metrics distinguish that lighter `rebound_session` path from a true `reopened_session`, so profile runs can separate live-window rebind cost from actual window recreation cost.
- The workspace-process profiler prints both the workspace-process focus route and the app-side `terminal_window_focus_ipc` route, which makes it easier to see whether a slow reopen actually tried and missed the live-window focus path or never exercised it.
- The built-in terminal profiler treats `spaces terminal command --backend ghostty-embedded` as the owner summon itself and waits for the first owner attach, instead of immediately posting a second owner `terminal show` that would measure an artificial re-summon.
- Session output still streams directly to `output.log`, but session runtime-state persistence is coalesced so steady-state windows are not constantly paying synchronous metadata write costs.
- Built-in process sessions use a lighter readiness policy than ad hoc terminals. Workspace-process launch waits only for the embedded session control socket plus `state.json` to exist, then lets later runtime-state refreshes reconcile a child PID after the window is already visible.
- Owner-surface attach forces one immediate layout + surface refresh, and later PTY output or local input coalesces explicit surface refresh requests. That keeps first-open prompts and command output visible on live `ghostty-embedded` process windows instead of relying on a close/reopen cycle to reveal buffered content.
- Ghostty owner windows suppress inline non-error send-status text because the live terminal surface is the interactive input path. The inline status area stays available for real errors and for fallback/viewer flows.
- App-side open/focus actions distinguish built-in `Spaces` terminal windows from external apps. Built-in terminal windows stay visible with the main app, while external terminal/browser/editor actions still use the hide-after-success behavior.
- Global app-toggle behavior also distinguishes the primary main window from auxiliary built-in windows. `Cmd+Opt+=` depends only on the main window's visible state, not on whether a built-in terminal or the command palette is focused. Toggling the app summons or hides only the main Spaces window instead of unhiding or fronting every Spaces-owned window in the process. `Cmd+Opt+-` similarly depends only on the command palette's visible state and shows or hides only the palette panel, so the main window and built-in terminal windows stay in their existing visibility state.
- Built-in terminal summon/focus flows keep the tracked workspace association in the `windows` table through the terminal session ID. That lets the main window restore the owning workspace detail view when the user toggles back from a focused built-in terminal, even before yabai has supplied or refreshed a native window ID.
- The main-window hotkey path resolves the owning workspace from the focused built-in terminal session first and skips the generic focused-window workspace lookup whenever that session mapping already exists. That keeps `Cmd+Opt+=` from paying an unnecessary focused-window lookup on every `Spaces terminal -> main window` transition.
- When `Cmd+Opt+=` brings the main window forward from a focused built-in terminal, the app remembers that terminal session and restores focus back to it when the user presses the hotkey again to hide the main window. That keeps the round-trip `terminal -> main window -> terminal` path explicit instead of leaving focus restoration to AppKit.
- When `Cmd+Opt+=` brings the main window forward from an untracked external app, the app remembers that frontmost non-Spaces process and reactivates it when the user presses the hotkey again to hide the main window. That keeps the `external app -> main window -> external app` round trip explicit instead of leaving Spaces frontmost after `orderOut(nil)`.
- When `Cmd+Opt+-` brings the command palette forward, the app remembers whether the focused target was a built-in terminal, the main window, or an external app. Hiding the palette returns focus to that same target instead of hiding the app or letting activation fall through to another Spaces window.
- The command-palette hotkey path follows the same pattern. When a built-in terminal is focused, it resolves the palette context workspace from the terminal session first and skips the generic focused-window lookup whenever the session already maps back to a workspace.
- Built-in terminal actions emit debug metrics through the shared `spaces: perf metric=...` format when `DEBUG=1`, including:
- `workspace_terminal_open_ui`
- `terminal_session_start`
  - `terminal_first_output`
  - `terminal_session_wait_ready`
  - `terminal_surface_create`
  - `terminal_window_attach`
  - `terminal_window_summon`
  - `terminal_window_focus_ipc`
  - `terminal_owner_focus_sync`
  - `terminal_control_send`
  - `terminal_control_key`
  - `terminal_control_takeover`
  - `toggle_palette_terminal_workspace_lookup`
  - `toggle_palette_focused_window_workspace_lookup`
  - `toggle_palette_context_workspace`
  - `toggle_palette_reveal_target`
  - `toggle_palette_apply_filter`
  - `toggle_window_terminal_workspace_lookup`
  - `toggle_window_focused_window_workspace_lookup`
  - `toggle_window_reveal_target`
  - `toggle_window_selection_refresh`
  - `toggle_window_return_terminal_focus`
  - `toggle_window_return_application_focus`
  - `toggle_window_flow`

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

For repeatable performance sampling of the app-triggered workspace-terminal open path:

```bash
ITERATIONS=3 apps/macos/Tests/profile_workspace_terminal_open.sh
```

The workspace-terminal-open profiler:
- seeds an isolated fixture workspace with terminal host `spaces`
- launches a debug `SpacesApp` with `DEBUG=1`
- triggers the app-side workspace-terminal open route through manual-E2E IPC instead of the CLI-only terminal session path
- records three timings that separate the visible launch cost:
  - `workspace_terminal_open_wall`: wall-clock time from the trigger until the app reports the open completed
  - `workspace_terminal_open_ui`: the app-side detached open action, including the backend readiness wait and sidebar reload
  - `terminal_session_wait_ready`: the built-in session bootstrap wait inside `WorkspaceOrchestrator`
- keeps `terminal_window_summon` in the same summary so the window-controller contribution stays visible next to the backend wait

A representative isolated debug run recorded:
- `workspace_terminal_open_wall`: `686-688ms`
- `workspace_terminal_open_ui`: `634-639ms`
- `terminal_session_wait_ready`: `588-597ms`
- `terminal_window_summon`: `26-34ms`

That split shows the dominant cost is session readiness rather than native window summon. The built-in app path therefore keeps the readiness wait for correctness but runs it off the main thread so the sidebar window does not spin while the embedded backend starts.

For repeatable performance sampling of the built-in `Spaces terminal -> main window -> tracked process terminal` hotkey loop:

```bash
ITERATIONS=3 apps/macos/Tests/profile_spaces_terminal_hotkeys.sh
```

That profiler:
- seeds an isolated fixture workspace with terminal host `spaces`
- launches a debug `SpacesApp` with `DEBUG=1`
- focuses a tracked built-in process terminal
- repeats `Cmd+Opt+=` to return to the main window
- repeats `Cmd+Opt+=` again to hide the main window and return focus to the built-in terminal
- records both wall-clock halves of the round trip alongside app-side hotkey metrics

A representative isolated debug run recorded:
- `terminal_to_main_toggle_wall`: `734-759ms`
- `toggle_window_show`: `1-4ms`
- `toggle_window_reveal_target`: `1-4ms`
- `toggle_window_terminal_workspace_lookup`: `0ms`
- `toggle_window_selection_refresh`: `26-32ms`

The profiler also records the return leg:
- `main_to_terminal_toggle_wall`
- `toggle_window_hide`
- `toggle_window_return_terminal_focus`

That split keeps the hide path measurable as a real `terminal -> main window -> terminal` round trip instead of leaving the second hotkey press to an implicit AppKit focus handoff.

For repeatable performance sampling of the built-in `Spaces terminal -> command palette -> tracked process terminal` hotkey loop:

```bash
ITERATIONS=3 apps/macos/Tests/profile_spaces_terminal_palette.sh
```

That profiler:
- seeds an isolated fixture workspace with terminal host `spaces`
- launches a debug `SpacesApp` with `DEBUG=1`
- focuses a tracked built-in process terminal
- repeats `Cmd+Opt+-` to present the command palette
- dismisses the palette and refocuses the tracked process terminal through the real workspace-process focus path
- records wall-clock palette timing alongside app-side palette metrics

A representative isolated debug run recorded:
- `terminal_to_palette_toggle_wall`: `751-771ms`
- `toggle_palette`: `3-21ms`
- `toggle_palette_terminal_workspace_lookup`: `0ms`
- `toggle_palette_context_workspace`: `0ms`
- `toggle_palette_reveal_target`: `2-7ms`
- `toggle_palette_apply_filter`: `0ms`

That split shows the built-in command-palette handler is also no longer spending meaningful time on terminal-session context lookup when a built-in terminal is focused. The remaining wall time lives in the broader real-system focus transition after the palette panel is presented, not in the terminal-aware lookup or filter path.

For repeatable profiling of built-in workspace-process launch, close, and reopen:

```bash
apps/macos/Tests/profile_workspace_process_terminal.sh
```

With the lighter built-in process readiness policy, a representative isolated debug run recorded:
- `workspace_start_wall`: `298ms`
- `terminal_session_wait_ready`: `53-59ms` per built-in process window, with `policy=session_ready`
- `terminal_window_summon`: `22-30ms`
- `workspace_process_focus_wall`: `164ms`

That profile shows the dominant process-launch overhead has moved off the built-in terminal bootstrap path. Remaining steady-state process-window work is now mostly in the workspace-level focus and reopen flow rather than the initial session bring-up.

The real-system E2E harness also asserts the macOS window-manager behavior behind those hotkeys. `apps/macos/Tests/e2e_real_system.sh` now checks that:
- a built-in terminal can hide and reshow the main window without changing the toggle semantics
- an untracked external app such as Ghostty or Chrome can summon the main window directly
- the second `Cmd+Opt+=` hides only the main window and returns focus to that external app

## What This Branch Does Not Decide
- whether external hosts are removed in a later PR
- whether remote viewer clients should render via libghostty cells, byte streams, or another transport
- whether one session should ever have more than one simultaneously renderable libghostty surface on macOS
