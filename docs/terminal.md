# Built-in Terminal

This document describes the built-in terminal runtime in Spaces: what owns a session, what clients attach to, what is persisted on disk, and where the Ghostty compatibility boundary sits. User-visible behavior belongs in [spec.md](spec.md). Broader module boundaries belong in [implementation.md](implementation.md).

## Scope
- `ghostty-embedded` is the only supported built-in terminal backend for Spaces-owned sessions.
- Spaces consumes a forked `GhosttyKit.xcframework` from `yogesh-dhande/ghostty` because the integration depends on additive embedded terminal exports for raw PTY I/O, host rebinding, session state callbacks, renderer attachment, headless sessions, render-frame export, and mirror renderer surfaces.
- The Ghostty fork is pinned by the `apps/macos/vendor/ghostty` submodule; Spaces-owned prebuilt artifact releases use the `ghostty-artifacts-<full-ghostty-sha>` naming convention for PR, manual, main-push, and release workflow provisioning.
- Spaces renders built-in terminal UI from service-published Ghostty render frames; fork-level passive-viewer attachment APIs, VT replay, raw output, and `output.log` are outside the UI rendering path.
- Spaces also builds `libghostty-vt` from the same fork lineage for `spaces terminal tail` and diagnostics.
- Spaces terminal sessions own process lifetime directly.

## Ownership Model
- `SpacesTerminalService` owns built-in terminal sessions, including workspace terminals, built-in process windows, built-in coding-agent windows, mobile-visible sessions, and sessions created through `spaces terminal ...`.
- The service is a per-user background executable started on demand by first-party clients and can outlive `SpacesApp`.
- First-party clients attach through SQLite-backed session metadata, the per-session control socket, and the render-frame stream.

## Session Boundary
Each session keeps canonical metadata in SQLite and runtime-only files under `<profile-root>/runtime/terminal/sessions/<session-id>/`.

SQLite stores:
- launch configuration, backend, lifetime policy, launch workspace ID, and session kind
- runtime state, service PID, child PID, title, working directory, and last known columns or rows
- known client identities and remote lease timestamps
- owner or viewer attachment history
- saved terminal window frames
- final Ghostty remote session-state payloads keyed by session ID

The session directory keeps:
- `output.log`: append-only terminal output used for `spaces terminal tail` and diagnostics
- `control.sock`: local control-plane socket for attach, detach, send, key, takeover, and related requests
- `subscription.sock`: service-published session state and Ghostty render-frame stream for daemon-owned client windows
- `service.log`: service diagnostics for the session

Each live session also participates in a service-level control path:
- `/tmp/spaces-terminal-sockets/service-<profile-hash>.sock` is the profile-scoped service command socket used for session creation, listing, and termination.

## Service Runtime
- `GhosttyEmbeddedSessionHost` is the service-owned runtime for `ghostty-embedded`.
- It owns one live libghostty-backed session, writes `output.log`, refreshes SQLite runtime state, enforces owner-only input or resize, and expires stale remote leases from SQLite client rows.
- It also preserves live metadata such as title, working directory, and child PID so attached clients can reopen a session without restarting the shell.
- During termination it captures the Ghostty render frame before renderer teardown, writes a final `terminated` payload to SQLite, broadcasts that payload to attached clients, marks active attachments detached, and then closes the live stream and renderer.
- App-created ad hoc workspace terminals use persistent service-owned sessions so they survive app quit. The `.whileAttached` lifetime policy remains available for callers that intentionally want service reaping after the final live attachment detaches or expires.
- Closing a native Spaces terminal window detaches the local window from process and coding-agent sessions while preserving the owning runtime and service session. Ad hoc workspace terminal closes terminate the matching service-owned session. Programmatic closes used by stop and restart are marked as terminating so AppKit cleanup does not issue an ad hoc close cleanup.
- If the service restarts and finds a session left in `starting` or `running` by a dead service PID, it marks that session failed and removes the stale `control.sock`.

## App Client Runtime
- Built-in Spaces terminals are service-owned, so `SpacesApp` windows attach to sessions through the service control socket and can reconnect after app quit or relaunch.
- App shutdown does not terminate service-owned terminal sessions. The quit prompt offers a destructive stop-all option for users who want to end every live service session before quitting.

## First-Party Clients
- `spaces terminal command` creates sessions through `SpacesTerminalService`.
- `spaces terminal list` reads live session summaries from the service abstraction.
- `spaces terminal show` asks `SpacesApp` to open a native owner-seeking window for an existing session ID.
- `spaces terminal send`, `key`, and `takeover` still operate on the per-session control socket that the service owns.
- `SpacesTerminalService` publishes the first-party TLS-PSK bridge consumed by the iOS client. `spaces mobile status` starts the service if needed and prints address details, while `spaces mobile serve` remains available for standalone harnesses and opens an ephemeral pairing window. Standalone bridges reject daemon-only recovery commands such as `launchSpacesApp`.
- The daemon bridge can service the authenticated `launchSpacesApp` recovery command while `SpacesTerminalService` remains alive. The command launches `SpacesApp` for the current profile only when the profile has no live app-owner lease, so service-owned sessions and the bridge process continue without restart.
- `SpacesMobile` discovers the bridge through Bonjour or accepts manual host entry, shows workspaces with mobile-controllable process, coding-agent, and workspace-terminal rows, keeps one selected terminal detail at a time, auto-attempts takeover for live opened sessions, renders the owner path from service-published Ghostty render frames, and renders ended sessions from persisted final Ghostty state.
- Workspace process launch, built-in coding-agent launch, app-opened workspace terminals, CLI-created sessions, and mobile-visible sessions use the service-owned path.

## macOS Window Behavior
- `SpacesApp` uses `RemoteGhosttySessionHost` for service-owned sessions and subscribes to the daemon-owned session state stream for owner handoff compatibility and metadata updates.
- `TerminalSessionWindowController` attaches a local owner or viewer client record to the daemon-owned session, keeps window reuse keyed by stable session ID, renders owner windows from the service render-frame stream, and uses a compact ownership/status shell for non-owner windows instead of rendering a passive terminal transcript.
- Process, coding-agent, and ad hoc workspace terminal windows can receive compact runtime controls from `spacesui`. The native window title carries the row title while the terminal UI renders only right-aligned icon actions; workspace lookup, stable process-template and launcher-ID matching, and lifecycle mutations remain in `AppKitController` and `workspacecore`.
- The macOS daemon client path uses the service live Ghostty render stream for owner bootstrap and output refreshes while a macOS window owns the session. The state stream carries compact binary v2 render updates: full updates establish baselines and resync clients, while steady live updates, including `state_change`, use cell-run deltas and Ghostty-exported scroll-rectangle operations when the stream baseline is valid. One-shot state fetches and subscriber bootstrap payloads are self-contained full updates so callers can materialize the current screen without prior stream history. Render-update revisions are monotonic render revisions, so viewport-only scrollback changes advance the render revision even when the underlying session-state revision is unchanged. VT replay, snapshot-to-VT encoding, raw output bytes, and `output.log` are not terminal-rendering fallbacks.
- Title and working-directory updates still follow live session metadata emitted by the service.
- Owner or viewer attachment state is authoritative in SQLite.
- Only the active owner attachment may send input or drive PTY size.
- Owner macOS windows dispatch standard edit and find command-key equivalents directly to the terminal session window controller so AppKit menu routing does not bypass the live Ghostty surface. Copy, select-all, find, use-selection-for-find, and find navigation use Ghostty binding actions on the active mirror surface; paste reads the system pasteboard and sends text through the active owner input path because the PTY remains service-owned. `Ctrl+C` and terminal-owned navigation or clear shortcuts continue through the terminal key translator.
- `GhosttyMirrorTerminalView` forwards mouse press, release, move, and drag events into the local mirror surface using Ghostty's AppKit coordinate convention and modifier bits. The mirror surface owns selection hit testing, copy selection behavior, and search match navigation.
- Live terminal find uses a compact overlay owned by the macOS mirror view. Ghostty search action events open and close the overlay and update match counts; query edits call `search:<query>`, navigation calls `navigate_search:next` or `navigate_search:previous`, and `Esc` sends `end_search`.
- Reopening a built-in window for an existing session reattaches to the same shell session instead of creating a new one.
- Non-running sessions are treated as read-only even when older attachment rows still name an owner. macOS windows for ended sessions mount the local Ghostty mirror surface from the persisted final render frame and do not take ownership, resize, or send input.

## Tail and Metadata
- `spaces terminal tail` reads `output.log`, not a live client window.
- ANSI and full-screen output are replayed through `libghostty-vt`.
- Tail rendering uses the persisted terminal size from SQLite so wrapping and redraw-heavy transcripts stay aligned with the last visible geometry.
- The VT bridge feeds `spaces terminal tail` and diagnostics. Terminal UI rendering does not use VT replay, snapshot-to-VT encoding, or `output.log`.

## Mobile Bridge
- `SpacesTerminalService` starts the first-party TLS-PSK bridge for the iOS client on launch. The default listener binds all IPv4 interfaces on port `47847`; if another Spaces profile already owns that port, the daemon persists a deterministic profile-specific fallback port so paired devices keep reconnecting to a stable endpoint.
- The bridge settings live under the terminal root in `mobile-bridge.json`; the active bridge port and profile transport key persist there, and the transport key rotates when all mobile pairings are reset.
- `spaces mobile status` shows the active port, Bonjour service name, and reachable IPv4 addresses. `spaces mobile serve --host ... --port ... --pairing-code ...` runs the bridge as a standalone process, opens a five-minute pairing window, and prints the full pairing link, code, expiry, host, and port. Harnesses that need to issue bridge JSON use `spaces mobile request` with the pairing link or transport key so they exercise the same TLS-PSK transport as the iOS app. Standalone bridge processes do not service `launchSpacesApp` because they do not own the terminal-service executable context.
- The Mac sidebar mobile connection action opens a compact panel with endpoint details, a five-minute QR/deep-link pairing window, copy-link action, countdown, paired devices, revoke controls, and reset-all pairing rotation.
- The service advertises `_spaces-mobile._tcp.` with Bonjour so the iOS connection sheet can offer nearby Macs without requiring the user to type an IP address.
- The bridge serves workspace and terminal overview data plus authenticated attach, subscribe, takeover, send, key, workspace-creation, workspace-terminal, process, and coding-agent lifecycle requests over the same session boundary.
- The daemon bridge also serves the authenticated `launchSpacesApp` recovery request. It checks the current profile app-owner lease before spawning, returns success immediately when `SpacesApp` already owns the profile, and otherwise starts the resolved `SpacesApp` executable with `SPACES_DB_PATH`, `SPACES_RUNTIME_DIR`, and `SPACES_TERMINAL_SERVICE_EXECUTABLE` set for the current profile and service executable.
- Mobile workspace terminals are persistent service-owned sessions created at the workspace root. The bridge uses the workspace terminal reservation and finish flow with no native macOS window opener, so the session is immediately visible to iOS without presenting a Mac terminal window. Stop requests terminate ad hoc workspace terminal sessions through the same workspacecore path used for native window close.
- Mobile process actions reuse the same configured-process recovery and running-process stop or restart behavior as the macOS app. A configured process without a live runtime is launched from its saved workspace settings; a live row is stopped or restarted by running-process identity.
- Mobile coding-agent actions use the workspace agent lifecycle path. Stopping a Spaces-backed agent closes any tracked native terminal window, terminates the backing service session, removes the runtime row, and leaves the configured launcher in settings. Restarting is available for configured launchers and claimed launcher rows; unconfigured live agents can stop but cannot restart.
- Terminal overview rows are assembled from workspace runtime rows first: configured processes use `running_processes`, configured coding agents use `agent_sessions`, and both carry the runtime target's terminal session ID. Live ad-hoc terminal sessions are included only when they are not represented by one of those configured rows, resolve workspace ownership from launch metadata before legacy working-directory matching, and expose stop availability only while running with a live session ID.
- Spaces-owned ad-hoc terminal sessions are promoted to coding-agent rows while their persisted foreground runtime metadata identifies a known agent command such as `codex`, `claude`, `claude-code`, or `opencode`. The underlying terminal row name is preserved, and the agent detail shows the live foreground command when it is distinct from the agent label.
- The bridge `state` endpoint returns a self-contained live service state for interactive sessions and the persisted final `terminated` payload for ended sessions. Ended-session `subscribe` requests send that same final payload and complete so stale clients do not report a missing live stream. Attach, takeover, input, resize, and scroll control remain live-session-only operations.
- The iOS terminal detail view resolves the selected session back to the latest mobile overview runtime row while it is visible. Its trailing `...` menu reuses the app model's run, stop, and restart mutations, and swaps to a replacement session when run or restart returns one.
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
- Active macOS and iOS owners receive screen-state-change render frames from the service, so command output, row clears, and prompts are published from the terminal state stream without depending on later input activity.
- macOS owner command submissions keep a trailing `input_output` render-frame resync after the first interactive output chunk, while ordinary character echo can remain on the fast output path.
- Render-frame snapshots preserve Ghostty row wrap metadata in internal cell flags when exported by the service and restore it when materialized into a local mirror surface. The iOS mirror therefore keeps Ghostty's native selection and link detection semantics for soft-wrapped output, including file paths with spaces that wrap across rows.
- Output events carry byte counts and ending output byte offsets for ordering and diagnostics, but not raw output bytes for client rendering.
- macOS remote windows and iOS owner rendering use the same render-frame coordination policy for preserving an already-bootstrapped owner render and applying fresh service frames.
- Client renderers update from structured render frames and scroll gestures so prompt redraws and row clears are visible before readiness or rendered-text state advances.
- iOS first paint and first input-ready are driven from the bootstrap render frame. Raw-output history replay and incremental output byte rendering are not used for terminal rendering.
- macOS owner windows and the iOS toolbar share `TerminalKeyInput` named key specs for terminal line editing. `cmd+left` and `cmd+right` encode as `Ctrl+A` and `Ctrl+E`, `opt+left` and `opt+right` encode as meta backward/forward word, and `cmd+backspace` or `opt+backspace` encode as kill-line-left or kill-word-left. `cmd+k` is a terminal-owned host action that clears the visible screen and scrollback without sending `Ctrl+L` as PTY input.
- Ordinary resize reconciles viewport geometry inside the owner epoch. It does not schedule another full bootstrap.
- If the owner epoch becomes desynchronized after takeover, the bridge prefers one explicit refresh or resync request instead of an implicit bootstrap loop.
- When `SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH` is set, the macOS host, mobile bridge, and the iOS client append structured JSONL events to that path. Events include wall-clock `emittedAt` plus monotonic `emittedUptimeNanoseconds` for same-process latency correlation. Render events identify `frame_kind=full`, `frame_kind=delta`, or `frame_kind=resync_required` and include revision, payload, delta, and recovery fields: `base_revision`, `target_revision`, `applied_revision`, `payload_bytes`, `render_update_bytes`, `operation_count`, `changed_cell_count`, `scroll_operation_count`, `full_frame_fallback_reason`, `apply_ms`, and `drop_reason`. Bridge stream relay events mark `stream_relay_read` and `stream_network_send_begin` so transport delay is separated from client rendering. The bridge `state` endpoint returns a materialized current render state for tests and diagnostics. The standalone demo and standalone E2E wrappers set this automatically and preserve the file under the disposable demo root as `mobile-terminal-performance.jsonl`.

## Scroll Rendering
- Scroll requests stay inside the active-owner control boundary. Requests carry Ghostty scroll modifier bits for precise deltas and momentum phases; legacy requests that omit those bits default to `0`.
- macOS service-owned terminal windows use `RemoteGhosttySessionHost` with `GhosttyMirrorTerminalView`. AppKit trackpad and mouse-wheel deltas are forwarded as precise pixel deltas to the service, scroll RPCs are coalesced to display-frame cadence, and Ghostty applies the scroll against its live terminal state. This path gives the highest fidelity because Ghostty owns scrollback, alternate-screen behavior, momentum interpretation, and viewport state.
- iOS owner rendering uses `GhosttyRemoteTerminalView`. It forwards the same precise deltas and momentum metadata through display-frame coalescing, but it also scrolls the cached render-frame snapshot locally for immediate touch feedback while the bridge request is in flight. The local snapshot viewport is row-based, so pixel deltas are divided by cell height and sub-row remainders accumulate until they become a whole row. Tiny swipes therefore stay tiny instead of forcing a one-row jump, and repeated tiny swipes still add up to visible scrollback movement.
- The macOS path does not use the iOS fractional row accumulator because the macOS viewer is local enough for Ghostty-native scrolling to feel immediate. Adding a manual row approximation before Ghostty sees the event would duplicate the terminal scroll model and reduce fidelity. The iOS path keeps the accumulator because relying only on the bridge round trip makes touch scrolling feel delayed under mobile transport latency.

## Ghostty Compatibility Boundary
- The Ghostty fork exposes additive headless-session, render-frame, and mirror-renderer entrypoints for Spaces without changing default Ghostty app behavior. Spaces keeps the v2 render-update protocol behind its first-party service and bridge boundary; current clients materialize v2 updates back into Ghostty mirror snapshots until the prebuilt GhosttyKit contract exposes direct native render-update apply calls.
- The service remains the only PTY and session-state owner. Client windows and mobile views import service frames into local mirror state and may only send input, resize, mouse, keyboard, binding-action, or scroll events while their client ID and owner epoch match the active owner.
- The first-party render stream uses v2 render updates only. Full v2 updates are retained for initial baselines, self-contained fetches, resize, termination, `input_output`, subscriber baseline resets, and correctness resyncs; steady-state output, `state_change` prompt redraws, and scrollback movement use deltas with native scroll-rectangle operations when Ghostty provides them.
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
