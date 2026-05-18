# Built-in Terminal

This document describes the built-in terminal runtime in Spaces: what owns a session, what clients attach to, what is persisted on disk, and where the current Ghostty compatibility boundary sits. User-visible behavior belongs in [spec.md](../spec.md). Broader module boundaries belong in [architecture.md](architecture.md).

## Scope
- `ghostty-embedded` is the only supported built-in terminal backend for Spaces-owned sessions.
- Spaces consumes a forked `GhosttyKit.xcframework` from `yogesh-dhande/ghostty` because the integration depends on additive PTY I/O exports:
  - `ghostty_surface_set_data_callback(...)`
  - `ghostty_surface_send_input_raw(...)`
  - `ghostty_surface_set_host(...)`
- Spaces also builds `libghostty-vt` from the same fork lineage for transcript replay so `spaces terminal tail` and non-surface clients stay aligned with Ghostty terminal behavior.
- The built-in terminal path does not require tmux.

## Ownership Model
- The current compatibility bridge has two ownership modes.
- `SpacesApp` owns the live Ghostty session for built-in terminals that the app launches itself: workspace terminals, built-in process windows, and built-in coding-agent windows.
- `SpacesTerminalService` owns daemon-backed sessions created through `spaces terminal ...` and the remaining first-party service path.
- The service is a per-user background executable started on demand by first-party clients and can outlive `SpacesApp`.
- Both owners persist the same session files and expose the same per-session control socket shape.

## Session Boundary
Each session lives under `~/.spaces/terminal/sessions/<session-id>/`.

The session directory keeps:
- `metadata.json`: launch configuration, backend, and lifetime policy
- `state.json`: runtime state, service PID, child PID, title, working directory, and last known columns or rows
- `output.log`: append-only terminal output used for replay
- `clients.json`: known client identities
- `attachments.json`: owner or viewer attachment history
- `control.sock`: local control-plane socket for attach, detach, send, key, takeover, and related requests
- `subscription.sock`: service-published session state and Ghostty snapshot stream for daemon-owned client windows

Each live session also participates in a service-level control path:
- `~/.spaces/terminal/service.sock` is the service command socket used for session creation, listing, and termination.

## Service Runtime
- `GhosttyEmbeddedSessionHost` is the current service-owned runtime for `ghostty-embedded`.
- It owns one live libghostty-backed session, writes `output.log`, refreshes `state.json`, enforces owner-only input or resize, and expires stale remote leases.
- It also preserves live metadata such as title, working directory, and child PID so attached clients can reopen a session without restarting the shell.
- Ad hoc sessions can use `.whileAttached` lifetime policy, which allows the service to reap them once the final live attachment detaches or expires.
- If the service restarts and finds a session left in `starting` or `running` by a dead service PID, it marks that session failed and removes the stale `control.sock`.

## App-Owned Runtime
- `GhosttyEmbeddedSessionRegistry` keeps app-owned `GhosttyEmbeddedSessionHost` instances keyed by session ID.
- `WorkspaceOrchestrator` uses a process-wide launcher override inside `SpacesApp` so app-created built-in sessions start through that registry even when the launch originates from detached background work.
- `SpacesApp` terminates those app-owned hosts on app shutdown and uses the same session ID to reopen owner windows onto the same live host while the app remains running.

## First-Party Clients
- `spaces terminal command` creates sessions through `SpacesTerminalService`.
- `spaces terminal list` reads live session summaries from the service abstraction.
- `spaces terminal show` asks `SpacesApp` to open a native owner or viewer window for an existing session ID.
- `spaces terminal send`, `key`, and `takeover` still operate on the per-session control socket that the service owns.
- Workspace process launch, built-in coding-agent launch, and app-opened workspace terminals use the local app-owned live Ghostty path when they are launched from `SpacesApp`.
- CLI-managed workspace launches still use the daemon-owned compatibility path.

## macOS Window Behavior
- `SpacesApp` reuses an in-process `GhosttyEmbeddedSessionHost` when the target session already exists in `GhosttyEmbeddedSessionRegistry`.
- If no in-process host exists for that session ID, `SpacesApp` falls back to `RemoteGhosttySessionHost` and subscribes to the daemon-owned session state stream for live Ghostty snapshots.
- `TerminalSessionWindowController` attaches a local owner or viewer client record to the daemon-owned session and keeps window reuse keyed by stable session ID.
- The embedded Ghostty owner view can rebind a live surface to a replacement AppKit host view without restarting the underlying terminal session, which is the current fork-level bridge toward detachable renderers.
- The current macOS daemon client path uses the service snapshot stream as its primary live renderer feed, with `output.log` replay through `libghostty-vt` retained for transcript history, `spaces terminal tail`, and fallback recovery when the live stream is unavailable.
- Title and working-directory updates still follow live session metadata emitted by the service.
- Owner or viewer attachment state is still authoritative in `attachments.json`.
- Only the active owner attachment may send input or drive PTY size.
- Reopening a built-in window for an existing session reattaches to the same shell session instead of creating a new one.

## Replay and Metadata
- `spaces terminal tail` reads `output.log`, not a live client window.
- ANSI and full-screen output are replayed through `libghostty-vt`.
- Replay uses the persisted terminal size from `state.json` so wrapping and redraw-heavy transcripts stay aligned with the last visible geometry.
- The VT bridge feeds `spaces terminal tail` plus the fallback replay path, and it remains the intended bootstrap path for future snapshot-plus-delta clients because it can hold terminal state independently of a live renderer.

## Remote Bridge
- `spaces terminal proxy <session-id> --host ... --port ... --auth-token ...` remains a thin TCP bridge over the same session boundary.
- The proxy answers `tail` from persisted session state and forwards the remaining first-party control requests into `control.sock`.
- Remote attachments are lease-based. Host time stamps the lease, and only client-identified activity refreshes that specific remote lease.
- The proxy is an internal transport seam for first-party clients, not a stable third-party public API.

## Ghostty Compatibility Boundary
- The current Ghostty fork still couples PTY ownership to a renderer instance.
- Because of that, the service keeps the live hidden Ghostty host and exports full Ghostty snapshots over `subscription.sock` to other clients instead of attaching multiple native renderers to the same session. `output.log` remains the transcript and recovery surface, not the primary live-view path.
- The intended fork boundary is a true session core plus attachable renderers:
  - session-owned PTY and terminal state
  - attach or detach renderer instances without killing the session
  - a full snapshot export for late joiners
  - incremental terminal-state deltas for live remote rendering
- Snapshot plus terminal-state deltas are the canonical shared representation for future multi-client rendering. Pixel streaming is not the primary architecture.

## Validation
The terminal slice is considered healthy when these flows work:
- app-launched workspace terminals, built-in process windows, and coding-agent windows attach to the live in-process Ghostty host and reopen without restarting the session while `SpacesApp` stays alive
- session creation through `spaces terminal command`
- `list`, `send`, `key`, `tail`, `show`, and `takeover`
- app quit followed by app relaunch and reopen of the same live session
- owner or viewer attachment persistence and lease expiry
- transcript replay from `output.log` with persisted geometry
- remote proxy attach and takeover on top of the same session boundary
