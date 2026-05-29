# Built-in Terminal

This document describes the built-in terminal runtime in Spaces: what owns a session, what clients attach to, what is persisted on disk, and where the current Ghostty compatibility boundary sits. User-visible behavior belongs in [spec.md](spec.md). Broader module boundaries belong in [implementation.md](implementation.md).

## Scope
- `ghostty-embedded` is the only supported built-in terminal backend for Spaces-owned sessions.
- Spaces consumes a forked `GhosttyKit.xcframework` from `yogesh-dhande/ghostty` because the integration depends on additive embedded terminal exports for raw PTY I/O, host rebinding, session state callbacks, renderer attachment, and live terminal snapshot capture.
- The Ghostty fork is pinned by the `apps/macos/vendor/ghostty` submodule; Spaces-owned prebuilt artifact releases use the `ghostty-artifacts-<full-ghostty-sha>` naming convention for PR, manual, main-push, and release workflow provisioning.
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
- App-created ad hoc workspace terminals use persistent service-owned sessions so they survive app quit. The `.whileAttached` lifetime policy remains available for callers that intentionally want service reaping after the final live attachment detaches or expires.
- If the service restarts and finds a session left in `starting` or `running` by a dead service PID, it marks that session failed and removes the stale `control.sock`.

## App Client Runtime
- Built-in Spaces terminals are service-owned, so `SpacesApp` windows attach to sessions through the service control socket and can reconnect after app quit or relaunch.
- App shutdown does not terminate service-owned terminal sessions. The quit prompt offers a destructive stop-all option for users who want to end every live service session before quitting.

## First-Party Clients
- `spaces terminal command` creates sessions through `SpacesTerminalService`.
- `spaces terminal list` reads live session summaries from the service abstraction.
- `spaces terminal show` asks `SpacesApp` to open a native owner-seeking window for an existing session ID.
- `spaces terminal send`, `key`, and `takeover` still operate on the per-session control socket that the service owns.
- `SpacesTerminalService` publishes the first-party TLS-PSK bridge consumed by the iOS client. `spaces mobile status` starts the service if needed and prints address details, while `spaces mobile serve` remains available for standalone harnesses and opens an ephemeral pairing window.
- `SpacesMobile` discovers the bridge through Bonjour or accepts manual host entry, keeps one selected terminal detail at a time, auto-attempts takeover for the opened session, and renders the owner path through a local iOS Ghostty surface seeded from the exported live snapshot plus streamed live output.
- Workspace process launch, built-in coding-agent launch, app-opened workspace terminals, CLI-created sessions, and mobile-visible sessions use the service-owned path.

## macOS Window Behavior
- `SpacesApp` uses `RemoteGhosttySessionHost` for service-owned sessions and subscribes to the daemon-owned session state stream for owner handoff compatibility and metadata updates.
- `TerminalSessionWindowController` attaches a local owner or viewer client record to the daemon-owned session, keeps window reuse keyed by stable session ID, mounts a live Ghostty surface only for the active owner, and uses a compact ownership/status shell for non-owner windows instead of rendering a passive terminal transcript.
- The current macOS daemon client path uses the service live snapshot export for owner bootstrap, with `output.log` replay through `libghostty-vt` retained for transcript history, `spaces terminal tail`, and explicit no-live-session fallback recovery.
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
- `SpacesTerminalService` starts the first-party TLS-PSK bridge for the iOS client on launch. The default listener binds all IPv4 interfaces on port `47847`; if another Spaces profile already owns that port, the daemon persists a deterministic profile-specific fallback port so paired devices keep reconnecting to a stable endpoint.
- The bridge settings live under the terminal root in `mobile-bridge.json`; the active bridge port and profile transport key persist there, and the transport key rotates when all mobile pairings are reset.
- `spaces mobile status` shows the active port, Bonjour service name, and reachable IPv4 addresses. `spaces mobile serve --host ... --port ... --pairing-code ...` runs the same bridge as a standalone process, opens a five-minute pairing window, and prints the full pairing link, code, expiry, host, and port. Harnesses that need to issue bridge JSON use `spaces mobile request` with the pairing link or transport key so they exercise the same TLS-PSK transport as the iOS app.
- The Mac sidebar mobile connection action opens a compact panel with endpoint details, a five-minute QR/deep-link pairing window, copy-link action, countdown, paired devices, revoke controls, and reset-all pairing rotation.
- The service advertises `_spaces-mobile._tcp.` with Bonjour so the iOS connection sheet can offer nearby Macs without requiring the user to type an IP address.
- The bridge serves workspace and terminal overview data plus authenticated attach, subscribe, takeover, send, and key requests over the same session boundary.
- Pairing is first-party policy-gated: the Mac bridge issues a per-install auth token after one-time code and nonce verification inside an open pairing window, and persists the paired installation alongside device metadata and the expected iOS bundle identifier.
- Every later request must use the profile transport key at the TLS layer and present the stored auth token plus allowed bundle identity in the request, so an unpaired or non-first-party client is rejected before it can browse or control sessions.
- Remote attachments are lease-based. Host time stamps the lease, and only client-identified activity refreshes that specific remote lease.
- The mobile bridge is an internal first-party transport seam, not a stable third-party public API.
- Simulator-based manual verification can use a pairing link whose host is `127.0.0.1` or the discovered Bonjour service. A real device scans the Mac app QR code or opens the `spacesmobile://` link from the Mobile Connection panel.
- `GhosttyMobileAppService` prepares simulator stdio before it boots the local iOS Ghostty runtime: missing stdout or stderr descriptors are repaired, and stdin is rebound to a kept-open pipe so the local Ghostty carrier subprocess does not inherit immediate EOF under manual `simctl launch`.

## Mobile Owner Bootstrap
- `ghostty_session_export_snapshot` is the authoritative live owner export path for mobile takeover.
- Each takeover creates one owner epoch on iOS. The epoch carries:
  - the bootstrap snapshot used for first paint
  - optional deferred bounded raw-output history seed data for scrollback when the complete replay fits the transfer budget
  - incremental live output batches appended after bootstrap
- History seed responses and live output batches carry their ending `output.log` byte offset so iOS can keep only the live batches not covered by a sampled full-history replay, including batches delivered after the replay data has been applied and released.
- macOS remote windows and iOS owner rendering use the same replay coordination policy for deciding whether to apply a history seed, preserve an already-bootstrapped owner render, or drop output bytes already covered by history replay.
- Client renderers force a current Ghostty frame after replayed snapshots, history seeds, incremental output, and scroll gestures so prompt redraws and row clears are visible before readiness or rendered-text state advances.
- iOS first paint and first input-ready are driven from the bootstrap snapshot plus incremental live output. Raw-output history replay is deferred until the user scrolls away from the live bottom edge, and oversized logs keep the bootstrap render instead of replaying a partial VT stream from the middle of `output.log`.
- Ordinary resize reconciles viewport geometry inside the current owner epoch. It does not schedule another full bootstrap or another history replay.
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
- app-launched workspace terminals, built-in process windows, and coding-agent windows attach to service-owned sessions and reopen without restarting the session across `SpacesApp` quit and relaunch
- session creation through `spaces terminal command`
- `list`, `send`, `key`, `tail`, `show`, and `takeover`
- app quit followed by app relaunch and reopen of the same live session
- owner and viewer attachment persistence and lease expiry
- transcript replay from `output.log` with persisted geometry
- iOS attach, auto-takeover to the remote client, ownership transfer back to a macOS owner, and streamed render or input freshness on top of the same session boundary
- large-transcript iPhone takeover through the standalone demo path with a non-blank first owner frame, one owner bootstrap epoch, and preserved live updates after takeover
- long-output iPhone scrollback after takeover, with deferred history seeding, preserved scroll position while scrolled up, and no stray prompt repaint rows during owner rendering
- built-in terminal churn profiling through `profile_built_in_terminal_stress.sh`, with `codex_churn` kept as the primary redraw-heavy regression scenario
- longer manual churn sampling through `soak_built_in_terminal.sh`, including `SOAK_MODE=codex_churn` for sustained scrollback pressure and redraw churn
