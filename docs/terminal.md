# Built-in Terminal

This document describes the built-in terminal runtime in Spaces: what owns a session, what clients attach to, what is persisted on disk, and where the Ghostty compatibility boundary sits. User-visible behavior belongs in [spec.md](spec.md). Broader module boundaries belong in [implementation.md](implementation.md).

## Scope
- `ghostty-embedded` is the only supported built-in terminal backend for Spaces-owned sessions.
- Spaces consumes a forked `GhosttyKit.xcframework` from `yogesh-dhande/ghostty` because the integration depends on additive embedded terminal exports for raw PTY I/O, host rebinding, session state callbacks, renderer attachment, headless sessions, render-frame export, and mirror renderer surfaces.
- The Ghostty fork is pinned by the `apps/macos/vendor/ghostty` submodule; Spaces-owned prebuilt artifact releases use the `ghostty-artifacts-<full-ghostty-sha>` naming convention for PR, manual, main-push, and release workflow provisioning.
- Spaces renders built-in terminal UI from service-published Ghostty render frames; fork-level passive-viewer attachment APIs, VT replay, raw output, and `output.log` are outside the UI rendering path.
- Spaces also builds `libghostty-vt` from the same fork lineage for `spaces terminal tail` and diagnostics.
- The built-in terminal path does not require tmux.

## Ownership Model
- `SpacesTerminalService` owns built-in terminal sessions, including workspace terminals, built-in process windows, built-in coding-agent windows, mobile-visible sessions, and sessions created through `spaces terminal ...`.
- The service is a per-user background executable started on demand by first-party clients and can outlive `SpacesApp`.
- First-party clients attach through the same persisted session files, control socket, and render-frame stream.

## Session Boundary
Each session lives under `~/.spaces/terminal/sessions/<session-id>/`.

The session directory keeps:
- `metadata.json`: launch configuration, backend, and lifetime policy
- `state.json`: runtime state, service PID, child PID, title, working directory, and last known columns or rows
- `output.log`: append-only terminal output used for `spaces terminal tail` and diagnostics
- `clients.json`: known client identities
- `attachments.json`: owner or viewer attachment history
- `control.sock`: local control-plane socket for attach, detach, send, key, takeover, and related requests
- `subscription.sock`: service-published session state and Ghostty render-frame stream for daemon-owned client windows

Each live session also participates in a service-level control path:
- `~/.spaces/terminal/service.sock` is the service command socket used for session creation, listing, and termination.

## Service Runtime
- `GhosttyEmbeddedSessionHost` is the service-owned runtime for `ghostty-embedded`.
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
- `SpacesMobile` discovers the bridge through Bonjour or accepts manual host entry, keeps one selected terminal detail at a time, auto-attempts takeover for the opened session, and renders the owner path from service-published Ghostty render frames.
- Workspace process launch, built-in coding-agent launch, app-opened workspace terminals, CLI-created sessions, and mobile-visible sessions use the service-owned path.

## macOS Window Behavior
- `SpacesApp` uses `RemoteGhosttySessionHost` for service-owned sessions and subscribes to the daemon-owned session state stream for owner handoff compatibility and metadata updates.
- `TerminalSessionWindowController` attaches a local owner or viewer client record to the daemon-owned session, keeps window reuse keyed by stable session ID, renders owner windows from the service render-frame stream, and uses a compact ownership/status shell for non-owner windows instead of rendering a passive terminal transcript.
- The macOS daemon client path uses the service live Ghostty render-frame stream for owner bootstrap and output refreshes while a macOS window owns the session. V1 frames are encoded in the existing Codable state stream and carry Ghostty-exported grid, cursor, color, and style state for local mirror views. VT replay, snapshot-to-VT encoding, raw output bytes, and `output.log` are not terminal-rendering fallbacks.
- Title and working-directory updates still follow live session metadata emitted by the service.
- Owner or viewer attachment state is still authoritative in `attachments.json`.
- Only the active owner attachment may send input or drive PTY size.
- Reopening a built-in window for an existing session reattaches to the same shell session instead of creating a new one.

## Tail and Metadata
- `spaces terminal tail` reads `output.log`, not a live client window.
- ANSI and full-screen output are replayed through `libghostty-vt`.
- Tail rendering uses the persisted terminal size from `state.json` so wrapping and redraw-heavy transcripts stay aligned with the last visible geometry.
- The VT bridge feeds `spaces terminal tail` and diagnostics. Terminal UI rendering does not use VT replay, snapshot-to-VT encoding, or `output.log`.

## Mobile Bridge
- `SpacesTerminalService` starts the first-party TLS-PSK bridge for the iOS client on launch. The default listener binds all IPv4 interfaces on port `47847`; if another Spaces profile already owns that port, the daemon persists a deterministic profile-specific fallback port so paired devices keep reconnecting to a stable endpoint.
- The bridge settings live under the terminal root in `mobile-bridge.json`; the active bridge port and profile transport key persist there, and the transport key rotates when all mobile pairings are reset.
- `spaces mobile status` shows the active port, Bonjour service name, and reachable IPv4 addresses. `spaces mobile serve --host ... --port ... --pairing-code ...` runs the same bridge as a standalone process, opens a five-minute pairing window, and prints the full pairing link, code, expiry, host, and port. Harnesses that need to issue bridge JSON use `spaces mobile request` with the pairing link or transport key so they exercise the same TLS-PSK transport as the iOS app.
- The Mac sidebar mobile connection action opens a compact panel with endpoint details, a five-minute QR/deep-link pairing window, copy-link action, countdown, paired devices, revoke controls, and reset-all pairing rotation.
- The service advertises `_spaces-mobile._tcp.` with Bonjour so the iOS connection sheet can offer nearby Macs without requiring the user to type an IP address.
- The bridge serves workspace and terminal overview data plus authenticated attach, subscribe, takeover, send, and key requests over the same session boundary.
- Standalone bridge runs used by latency harnesses can apply test-only response and stream shaping through `SPACES_MOBILE_BRIDGE_NETWORK_PROFILE`; the app-supervised bridge path uses the default local profile.
- Pairing is first-party policy-gated: the Mac bridge issues a per-install auth token after one-time code and nonce verification inside an open pairing window, and persists the paired installation alongside device metadata and the expected iOS bundle identifier.
- Every later request must use the profile transport key at the TLS layer and present the stored auth token plus allowed bundle identity in the request, so an unpaired or non-first-party client is rejected before it can browse or control sessions.
- Remote attachments are lease-based. Host time stamps the lease, and only client-identified activity refreshes that specific remote lease.
- The mobile bridge is an internal first-party transport seam, not a stable third-party public API.
- Simulator-based manual verification can use a pairing link whose host is `127.0.0.1` or the discovered Bonjour service. A real device scans the Mac app QR code or opens the `spacesmobile://` link from the Mobile Connection panel.
- `GhosttyMobileAppService` prepares simulator stdio before it boots the local iOS terminal support runtime: missing stdout or stderr descriptors are repaired, and stdin is rebound to a kept-open pipe so manual `simctl launch` does not immediately deliver EOF.

## Mobile Owner Bootstrap
- `ghostty_session_export_render_frame` is the authoritative live owner export path for takeover and remote screen updates.
- The bridge takeover response carries a post-transfer terminal state payload when live state is readable; clients keep the takeover UI pending and issue one explicit state refresh when that payload is unavailable.
- Each takeover creates one owner epoch on iOS. The epoch carries the bootstrap render frame used for first paint, and later service-published render frames update that same rendered epoch.
- Output events carry byte counts and ending output byte offsets for ordering and diagnostics, but not raw output bytes for client rendering.
- macOS remote windows and iOS owner rendering use the same render-frame coordination policy for preserving an already-bootstrapped owner render and applying fresh service frames.
- Client renderers update from structured render frames and scroll gestures so prompt redraws and row clears are visible before readiness or rendered-text state advances.
- iOS first paint and first input-ready are driven from the bootstrap render frame. Raw-output history replay and incremental output byte rendering are not used for terminal rendering.
- Ordinary resize reconciles viewport geometry inside the owner epoch. It does not schedule another full bootstrap.
- If the owner epoch becomes desynchronized after takeover, the bridge prefers one explicit refresh or resync request instead of an implicit bootstrap loop.
- When `SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH` is set, the macOS host, mobile bridge, and the iOS client append structured JSONL events to that path. Events include wall-clock `emittedAt` plus monotonic `emittedUptimeNanoseconds` for same-process latency correlation. Render-frame events identify the current transport as `frame_kind=full` and include delta-ready revision and payload fields: `base_revision`, `target_revision`, `applied_revision`, `payload_bytes`, `apply_ms`, and `drop_reason`. Bridge stream relay events mark `stream_relay_read` and `stream_network_send_begin` so transport delay is separated from client rendering. The bridge `state` endpoint returns a materialized current render state for tests and diagnostics. The standalone demo and standalone E2E wrappers set this automatically and preserve the file under the disposable demo root as `mobile-terminal-performance.jsonl`.

## Scroll Rendering
- Scroll requests stay inside the active-owner control boundary. Requests carry Ghostty scroll modifier bits for precise deltas and momentum phases; legacy requests that omit those bits default to `0`.
- macOS service-owned terminal windows use `RemoteGhosttySessionHost` with `GhosttyMirrorTerminalView`. AppKit trackpad and mouse-wheel deltas are forwarded as precise pixel deltas to the service, scroll RPCs are coalesced to display-frame cadence, and Ghostty applies the scroll against its live terminal state. This path gives the highest fidelity because Ghostty owns scrollback, alternate-screen behavior, momentum interpretation, and viewport state.
- iOS owner rendering uses `GhosttyRemoteTerminalView`. It forwards the same precise deltas and momentum metadata through display-frame coalescing, but it also scrolls the cached render-frame snapshot locally for immediate touch feedback while the bridge request is in flight. The local snapshot viewport is row-based, so pixel deltas are divided by cell height and sub-row remainders accumulate until they become a whole row. Tiny swipes therefore stay tiny instead of forcing a one-row jump, and repeated tiny swipes still add up to visible scrollback movement.
- The macOS path does not use the iOS fractional row accumulator because the macOS viewer is local enough for Ghostty-native scrolling to feel immediate. Adding a manual row approximation before Ghostty sees the event would duplicate the terminal scroll model and reduce fidelity. The iOS path keeps the accumulator because relying only on the bridge round trip makes touch scrolling feel delayed under mobile transport latency.

## Ghostty Compatibility Boundary
- The Ghostty fork exposes additive headless-session, render-frame, and mirror-renderer entrypoints for Spaces without changing default Ghostty app behavior.
- The service remains the only PTY and session-state owner. Client windows and mobile views import service frames into local mirror state and may only send input, resize, mouse, keyboard, or scroll events while their client ID and owner epoch match the active owner.
- V1 render frames prioritize correctness over delta efficiency and can be full frames. Delta encoding and binary framing can be added behind the same service-owned session boundary.
- Pixel streaming is not the primary architecture.

## Validation
The terminal slice is considered healthy when these flows work:
- app-launched workspace terminals, built-in process windows, and coding-agent windows attach to service-owned sessions and reopen without restarting the session across `SpacesApp` quit and relaunch
- session creation through `spaces terminal command`
- `list`, `send`, `key`, `tail`, `show`, and `takeover`
- app quit followed by app relaunch and reopen of the same live session
- owner and viewer attachment persistence and lease expiry
- CLI `tail` transcript rendering from `output.log` with persisted geometry
- iOS attach, auto-takeover to the remote client, ownership transfer back to a macOS owner, and streamed render or input freshness on top of the same session boundary
- large-transcript iPhone takeover through the standalone demo path with a non-blank first owner frame, one owner bootstrap epoch, and preserved live updates after takeover
- long-output iPhone scrollback after takeover, with preserved scroll position while scrolled up and no stray prompt repaint rows during owner rendering
- built-in terminal churn profiling through `profile_built_in_terminal_stress.sh`, with `codex_churn` kept as the primary redraw-heavy regression scenario
- longer manual churn sampling through `soak_built_in_terminal.sh`, including `SOAK_MODE=codex_churn` for sustained scrollback pressure and redraw churn
