# Built-in Terminal

This document describes the built-in terminal runtime in Spaces: what owns a session, what clients attach to, what is persisted on disk, and where the current Ghostty compatibility boundary sits. User-visible behavior belongs in [spec.md](../spec.md). Broader module boundaries belong in [architecture.md](architecture.md).

## Scope
- `ghostty-embedded` is the only supported built-in terminal backend for Spaces-owned sessions.
- Spaces consumes a forked `GhosttyKit.xcframework` from `yogesh-dhande/ghostty` because the integration depends on additive embedded terminal exports for raw PTY I/O, host rebinding, session state callbacks, renderer attachment, and live terminal snapshot capture.
- Spaces no longer depends on fork-level passive-viewer attachment APIs; live rendering is owner-only on both macOS and iOS.
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
- `spaces terminal show` asks `SpacesApp` to open a native owner-seeking window for an existing session ID.
- `spaces terminal send`, `key`, and `takeover` still operate on the per-session control socket that the service owns.
- `SpacesTerminalService` publishes the first-party TCP bridge consumed by the iOS client. `spaces mobile status` starts the service if needed and prints the current pairing details, while `spaces mobile serve` remains available for standalone harnesses.
- `SpacesMobile` discovers the bridge through Bonjour or accepts manual host entry, keeps one selected terminal detail at a time, auto-attempts takeover for the opened session, and renders the owner path through a local iOS Ghostty surface seeded from the exported live snapshot plus streamed live output.
- Workspace process launch, built-in coding-agent launch, and app-opened workspace terminals use the local app-owned live Ghostty path when they are launched from `SpacesApp`.
- CLI-managed workspace launches still use the daemon-owned compatibility path.

## macOS Window Behavior
- `SpacesApp` reuses an in-process `GhosttyEmbeddedSessionHost` when the target session already exists in `GhosttyEmbeddedSessionRegistry`.
- If no in-process host exists for that session ID, `SpacesApp` falls back to `RemoteGhosttySessionHost` and subscribes to the daemon-owned session state stream for owner handoff compatibility, metadata updates, and ended-session final renders.
- `TerminalSessionWindowController` attaches a local owner or viewer client record to the daemon-owned session, keeps window reuse keyed by stable session ID, mounts a live Ghostty surface only for the active owner, and otherwise shows takeover or terminal-ended status shells.
- The embedded Ghostty owner view can rebind a live surface to a replacement AppKit host view without restarting the underlying terminal session, which is the current fork-level bridge toward detachable renderers.
- The current macOS daemon client path uses the service live snapshot export for owner bootstrap and ended-session final renders, with `output.log` replay through `libghostty-vt` retained for transcript history, `spaces terminal tail`, and explicit no-live-session fallback recovery.
- Title and working-directory updates still follow live session metadata emitted by the service.
- Owner or viewer attachment state is still authoritative in `attachments.json`.
- Only the active owner attachment may send input or drive PTY size.
- Reopening a built-in window for an existing session reattaches to the same shell session instead of creating a new one.

## Replay and Metadata
- `spaces terminal tail` reads `output.log`, not a live client window.
- ANSI and full-screen output are replayed through `libghostty-vt`.
- Replay uses the persisted terminal size from `state.json` so wrapping and redraw-heavy transcripts stay aligned with the last visible geometry.
- The VT bridge feeds `spaces terminal tail` plus the ended-session or no-live-session fallback replay path. Live owner bootstrap does not wait on VT history reconstruction before first paint.

## Mobile Bridge
- `SpacesTerminalService` starts the first-party TCP bridge for the iOS client on launch. The default listener binds all IPv4 interfaces on port `47847`, which keeps simulator loopback and real-device LAN access on the same stable port.
- The bridge settings live under the terminal root in `mobile-bridge.json`; the pairing code is generated once per profile unless overridden by `SPACES_MOBILE_PAIRING_CODE`.
- `spaces mobile status` shows the active port, pairing code, Bonjour service name, and reachable IPv4 addresses. `spaces mobile serve --host ... --port ... --pairing-code ...` runs the same bridge as a standalone process for harnesses.
- The Mac sidebar mobile connection action shows the same pairing code, port, Bonjour name, and reachable addresses without requiring a terminal.
- The service advertises `_spaces-mobile._tcp.` with Bonjour so the iOS connection sheet can offer nearby Macs without requiring the user to type an IP address.
- The bridge serves workspace and terminal overview data plus authenticated attach, subscribe, takeover, send, and key requests over the same session boundary.
- Pairing is first-party only: the Mac bridge issues a per-install auth token after one-time pairing-code verification and persists the paired installation alongside the expected iOS bundle identifier.
- Every later request must present both the stored auth token and the first-party iOS bundle identity, so an unpaired or non-first-party client is rejected before it can browse or control sessions.
- Remote attachments are lease-based. Host time stamps the lease, and only client-identified activity refreshes that specific remote lease.
- The mobile bridge is an internal first-party transport seam, not a stable third-party public API.
- Simulator-based manual verification can use `127.0.0.1` as the bridge host or the discovered Bonjour service. A real device can choose the nearby Mac from the connection sheet or use one of the LAN addresses printed by `spaces mobile status`.
- `GhosttyMobileAppService` prepares simulator stdio before it boots the local iOS Ghostty runtime: missing stdout or stderr descriptors are repaired, and stdin is rebound to a kept-open pipe so the local Ghostty carrier subprocess does not inherit immediate EOF under manual `simctl launch`.

## Mobile Owner Bootstrap
- `ghostty_session_export_snapshot` is the authoritative live owner export path for mobile takeover.
- Each takeover creates one owner epoch on iOS. The epoch carries:
  - the bootstrap snapshot used for first paint
  - optional deferred history seed data for scrollback
  - incremental live output batches appended after bootstrap
- iOS first paint and first input-ready are driven from the bootstrap snapshot plus incremental live output. Full transcript replay is deferred until the user scrolls away from the live bottom edge.
- Ordinary resize reconciles viewport geometry inside the current owner epoch. It does not schedule another full bootstrap or another full transcript replay.
- If the current owner epoch becomes desynchronized after takeover, the bridge prefers one explicit refresh or resync request instead of an implicit bootstrap loop.
- When `SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH` is set, the macOS host and the iOS client append structured JSONL events to that path. The standalone demo and standalone E2E wrappers set this automatically and preserve the file under the disposable demo root as `mobile-terminal-performance.jsonl`.

## Ghostty Compatibility Boundary
- The current Ghostty fork still couples PTY ownership to a renderer instance.
- Because of that, the service keeps the live hidden Ghostty host and exports one live Ghostty snapshot for takeover bootstrap plus incremental output and state updates for the active remote owner instead of attaching multiple native renderers to the same session.
- The current iOS client uses a compatibility renderer bridge on top of that export path: it boots a local Ghostty renderer session on iOS from the exported bootstrap snapshot, applies incremental output batches as they arrive, and seeds older scrollback only after the owner surface is already interactive. This preserves Ghostty rendering characteristics on iOS without requiring the full session-core attach or detach fork boundary yet.
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
- owner and viewer attachment persistence and lease expiry
- transcript replay from `output.log` with persisted geometry
- iOS attach, auto-takeover to the remote client, ownership transfer back to a macOS owner, and streamed render or input freshness on top of the same session boundary
- large-transcript iPad takeover through the standalone demo path with a non-blank first owner frame, one owner bootstrap epoch, and preserved live updates after takeover
- long-output iPad scrollback after takeover, with deferred history seeding, preserved scroll position while scrolled up, and no stray prompt repaint rows during owner rendering
- built-in terminal churn profiling through `profile_built_in_terminal_stress.sh`, with `codex_churn` kept as the primary redraw-heavy regression scenario
- longer manual churn sampling through `soak_built_in_terminal.sh`, including `SOAK_MODE=codex_churn` for sustained scrollback pressure and redraw churn
