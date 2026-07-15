# Architecture

How Spaces is built and why: module boundaries, storage, runtime topology, and the rationale behind the major design choices. Written for a reader who needs the shape of the system and the constraints that make the code look the way it does — details inferable from the source are left to the source.

Related docs, each authoritative for its own layer:

| Doc | Owns |
| --- | --- |
| [spec.md](spec.md) | User-visible behavior and product semantics |
| [terminal.md](terminal.md) | Built-in terminal runtime, ownership, and the Ghostty boundary |
| [design.md](design.md) | Visual system and reusable interaction patterns |
| [dev.md](dev.md) | Build, install, release, and E2E workflows; concrete install paths |

## System Overview

Spaces is a macOS app, an iOS app, and a CLI, all of which are thin clients of a per-device daemon. Five invariants hold everywhere:

- SQLite is the single source of truth for persisted model data and global preferences.
- A **window is a client concept**. The daemon has no desktop session and stores no window identity; clients reconstruct windows from the overview payload.
- Workspace settings are seeded from project templates at workspace creation and preserved as per-workspace overrides after that.
- Store startup migrates older databases serially through every intermediate schema version and fails closed for versions it has no migration step for.
- Behavior lives in one orchestration layer, hosted by the daemon. Every surface — GUI, CLI, MCP, iOS — reaches it through the Device API or the local profile socket rather than re-implementing it. `Stop All and Quit` is the sole exception: it opens the local daemon store directly, because it has to coordinate the quit prompt with client-owned Chrome tab tracking that the daemon cannot see.

## Modules

One SwiftPM package (`apps/macos/Package.swift`) holds every Swift target except the iOS app, which is an Xcode target under `apps/ios`.

Dependencies flow strictly downward through the layers named in the table below.

```mermaid
flowchart TD
  SpacesApp --> spacesui
  spaces --> spacescli
  SpacesMobile -.->|Device API| spacesdeviceapi

  spacesui --> spacesterminalui
  spacesui --> spacesclientcore
  spacesui --> spacesdeviceapi
  spacescli --> spacesclientcore
  spacescli --> spacesdeviceapi
  spacesd --> spacesdeviceapi
  spacesd --> spacesruntimecore

  spacesdeviceapi --> workspacecore
  spacesdeviceapi --> spacesdevicecore
  spacesclientcore --> spacesdevicecore
  spacesdevicecore --> spacesterminalcore
  workspacecore --> spacesterminalcore
  workspacecore --> systembridge
  spacesterminalui --> spacesterminalghostty
  spacesterminalghostty --> ghosttyvtshim
  spacesterminalcore --> ghosttyvtshim

  workspacecore --> storage[("spacesdatabase")]
  spacesterminalcore --> storage
  spacesclientcore --> storage
```

| Module | Layer | Owns | LOC |
| --- | --- | --- | --- |
| `SpacesApp` | entry | AppKit boot, nothing else | 40 |
| `spaces` | entry | CLI shim over `spacescli` | 3 |
| `spacesd` | entry | Per-device daemon: Device API host, terminal sessions, runtimes | 1.5k |
| `spacese2e` | entry | E2E runner and screen-recorder harness | 3.5k |
| `SpacesMobile` | entry (Xcode, `apps/ios`) | iOS client; a Device API client only | 6.6k |
| `spacesui` | surface | AppKit UI, panels, sidebar, focus dispatch, updater | 23.7k |
| `spacescli` | surface | `swift-argument-parser` tree and the MCP server | 0.9k |
| `spacesterminalui` | surface | Terminal pane view controllers | 2.0k |
| `spacesdeviceapi` | service | Device API server, pairing, overview stream | 4.8k |
| `spacesclientcore` | service | Client database, device client, pairing secrets | 2.5k |
| `workspacecore` | core | Orchestration, lifecycle, environment, `AppVersion` | 9.6k |
| `spacesterminalcore` | core | Terminal primitives, theming, Caddy config, wire version | 9.7k |
| `spacesdevicecore` | core | Device API wire types, shared by daemon and every client | 2.4k |
| `spacesruntimecore` | core | Daemon-safe git helpers (no UI, Keychain, or AppKit) | 0.3k |
| `systembridge` | platform | Shell commands, AppleScript, Chrome automation | 1.5k |
| `spacesterminalghostty` | platform | Embedded libghostty host and app-side adapters | 5.8k |
| `spacesterminalmobileghostty` | platform (non-Linux) | iOS Ghostty rendering and input mapping | 1.8k |
| `ghosttyvtshim` | platform | C shim over `libghostty-vt` | — |
| `spacesdatabase` | storage | SQLite wrapper, migrator, schema, backup | 0.7k |

`AppVersion` constants are generated from `apps/macos/AppVersion.plist`, which also generates the app bundle `Info.plist`.

## Runtime Topology

Every client — the Mac app, the iOS app, and the CLI/MCP server — reaches daemon-owned state only through the Device API. `spacesd` runs on macOS and Linux and owns the daemon database, runtime files, workspace root, TLS identity, terminal sessions, and paired-client records.

```mermaid
flowchart LR
  subgraph macclient["macOS client"]
    app["Spaces.app"]
    clientdb[("spaces-client.db")]
    secrets["client-secrets"]
    chrome["Chrome"]
  end

  subgraph iosclient["iOS client"]
    mobile["SpacesMobile"]
    keychain["Keychain"]
  end

  cli["spaces CLI / MCP"]

  subgraph device["spacesd device (macOS or Linux)"]
    daemon["spacesd"]
    db[("spaces.db")]
    pairings["device-pairings.json"]
    tls["TLS identity"]
    sessions["terminal sessions"]
  end

  app --> clientdb & secrets & chrome
  cli --> clientdb & secrets
  mobile --> keychain

  app -->|Device API| daemon
  mobile -->|Device API| daemon
  cli -->|Device API| daemon
  cli -->|TerminalService| daemon
  app -.->|SSH: forwards, editor| device
  daemon -.->|Bonjour| app

  daemon --> db & pairings & tls & sessions
```

| Transport | Endpoint | Auth | Clients |
| --- | --- | --- | --- |
| Device API | TLS on `host:port` | Pinned daemon cert + per-client token | app, iOS, CLI/MCP |
| TerminalService | `/tmp/spaces-sockets-<uid>/…` | Unix filesystem permissions | local app, CLI/MCP |
| Bonjour | mDNS | None — discovery only | app, iOS |
| SSH | `ssh(1)` | The user's own SSH config | macOS app only — pairing sugar, browser forwards, editor opening |

Deliberate absences:

- **No relay transport.** Direct reachability over LAN, VPN, or Tailscale is required.
- **No TCP terminal-control bridge.** Terminal control rides profile-scoped Unix sockets and the authenticated Device API.
- **Bonjour carries no trust.** It advertises host and port; authorization is the pinned certificate plus the token.
- **Pairing credentials are file-only on both sides.** The daemon keeps token *hashes* in `device-pairings.json`; the Mac stores its token in a `client-secrets` file store so the app, CLI, and MCP server can all read it headlessly; iOS uses Keychain. None of this lives in SQLite, so no SQLite backup can leak a token.
- **Spaces never installs or updates a remote daemon.** SSH is never used for provisioning.
- **Terminal control never rides SSH.** A remote pane attaches, sends input, and receives render frames over the Device API like any other command.

SSH is a macOS-client-only capability with exactly three uses, none of them load-bearing for terminal or workspace control:

| Use | Owner |
| --- | --- |
| The `--ssh` pairing convenience path | `SpacesDevicePairingClient` |
| `ssh -L` browser port forwarding | `BrowserSSHForwardManager` |
| Opening a remote folder in the editor | `EditorRemoteSSHSupport` |

Even pairing is thin sugar: `spaces device pair --ssh` validates SSH, runs `spaces device pair --json` on the remote to obtain a `spaces://pair` link, then redeems that link over the pinned-TLS Device API like any other pairing. Removing SSH would cost remote browser sessions and remote editor opening, and nothing else.

## Persistence

State lives under `~/.spaces` on both macOS and Linux — the cross-platform dev-tool dotdir convention rather than platform-native directories (`~/Library/Application Support`, XDG). This keeps one code path across platforms, keeps paths space-free for shell tooling and AF_UNIX sockets, works on headless servers, and stays discoverable for CLI users. User project data lives at the visible `~/spaces/{workspaces,repos}`, outside the profile root, because those are the user's own working files rather than app state. Concrete install locations are in [dev.md](dev.md).

### Two databases

| Database | Owner | Holds |
| --- | --- | --- |
| `spaces.db` | `spacesd` | Projects, workspaces, runtime targets, process and agent rows, terminal metadata, daemon and global settings |
| `spaces-client.db` | The macOS app | Paired-device metadata, client settings, sidebar collapse state, panel layouts and window frames, browser window IDs, dismissed alerts |

The boundary is strict. A client reads daemon-owned data over the Device API rather than by opening `spaces.db`, so the two databases are never SQL-joined; they correlate in application code by stable keys (`workspace_id`, `runtime_target_id`, terminal `session_id`/`tracking_id`). The macOS GUI hosts no in-process orchestrator: focus, cycling, runtime controls, and workspace lookups are all reconstructed from the overview, and mutations go through the Device API. `Stop All and Quit` is the one path that opens the local daemon store directly (see [System Overview](#system-overview)).

### Profile resolution

- `SPACES_DB_PATH` wins whenever it is set for the current process.
- Otherwise repo-local development binaries derive one profile root from the current git branch plus the canonical worktree path.
- Installed binaries fall back to `~/.spaces/`.
- The runtime root is `<profile-root>/runtime` unless `SPACES_RUNTIME_DIR` overrides it.
- Client paired-device metadata follows the resolved profile root, so separate profiles never share paired remotes. Distributed-notification IPC is likewise scoped by a token derived from the profile root.

### Migration rules

- Fresh installs create the latest schema directly and record the current version.
- Databases behind the current version upgrade serially, one version per step (`vN` → `vN+1`). There are no version-skipping steps or jump paths.
- Startup fails closed when the recorded version has no migration step, or is newer than the binary supports.
- Startup runs `PRAGMA integrity_check` and fails unless it returns `ok`.
- Migrations carry user data forward. Tables and columns nothing reads are dropped by a step and removed from the schema definitions in the same change.
- Client migrations take a timestamped metadata-only backup first and restore it on failure.

## Data Model

`DatabaseSchema.currentVersion` is `4` and `SpacesClientDatabase.currentVersion` is `1`. `migration_state.current_version` records the canonical version; `PRAGMA user_version` is not used for migration control. Migration steps run serially, one version forward each. The `v1` → `v2` step adds `agent_sessions.note` and the `agent_subscriptions` table, carrying existing agent rows forward with a null note; the `v2` → `v3` step adds the `agent_pending_notifications` queue; the `v3` → `v4` step adds the `agent_remote_subscriptions` cross-device watch table. Each takes a pre-migration backup.

Diagrams show keys and discriminating columns only — full column lists live in `DatabaseSchema.swift` and `SpacesClientDatabase.swift`.

The template and config tables mirror each other one-for-one. For each of `services`, `processes`, `browser_sessions`, and `agent_launchers` there is a `project_*` template table and a `workspace_*` config table, each a child of its parent ordered by `order_index`. Only the `processes` pair is drawn below; the other three have the same shape.

```mermaid
erDiagram
  projects {
    TEXT id PK
    TEXT dir UK
    INTEGER is_git
  }
  project_processes {
    TEXT id PK
    TEXT project_id FK
  }
  workspaces {
    TEXT id PK
    TEXT project_id FK
    TEXT branch UK
    INTEGER is_running
  }
  workspace_settings {
    TEXT workspace_id PK
    TEXT setup_status
  }
  workspace_service_ports {
    TEXT workspace_id FK
    INTEGER service_index PK
    INTEGER port
  }
  workspace_processes {
    TEXT id PK
    TEXT workspace_id FK
  }
  runtime_targets {
    TEXT id PK
    TEXT workspace_id FK
    TEXT type
    TEXT tracking_id
  }
  browser_targets {
    TEXT runtime_target_id PK
    TEXT target_url
  }
  running_processes {
    TEXT id PK
    TEXT workspace_id FK
    TEXT runtime_target_id FK
    TEXT terminal_session_id
    TEXT status
  }
  agent_sessions {
    TEXT id PK
    TEXT workspace_id FK
    TEXT runtime_target_id FK
    TEXT terminal_session_id
    TEXT status
    TEXT note
  }
  agent_session_events {
    TEXT id PK
    TEXT agent_session_id FK
    TEXT event_type
  }
  agent_subscriptions {
    TEXT subscriber_terminal_session_id PK
    TEXT agent_session_id PK
  }
  agent_pending_notifications {
    TEXT id PK
    TEXT subscriber_terminal_session_id
    TEXT agent_session_id
    TEXT message
  }
  agent_remote_subscriptions {
    TEXT subscriber_terminal_session_id PK
    TEXT device_id PK
    TEXT agent_session_id PK
  }
  terminal_sessions {
    TEXT session_id PK
    TEXT root_directory UK
    TEXT workspace_id
    TEXT user_title
  }
  terminal_runtime_states {
    TEXT session_id PK
    TEXT state
    TEXT foreground_detected_agent_kind
  }
  terminal_clients {
    TEXT root_directory PK
    TEXT client_id PK
  }
  terminal_attachments {
    TEXT id PK
    TEXT session_id
    TEXT client_id
    TEXT mode
  }
  terminal_remote_session_states {
    TEXT session_id PK
    TEXT payload_json
  }
  terminal_agent_signal_events {
    TEXT id PK
    TEXT session_id
    TEXT event_type
  }
  ignored_worktrees {
    TEXT worktree_dir PK
    TEXT project_id FK
  }

  projects ||--o{ project_processes : owns
  projects ||--o{ workspaces : owns
  projects ||--o{ ignored_worktrees : owns
  workspaces ||--o| workspace_settings : has
  workspaces ||--o{ workspace_service_ports : allocates
  workspaces ||--o{ workspace_processes : configures
  workspaces ||--o{ runtime_targets : tracks
  workspaces ||--o{ running_processes : runs
  workspaces ||--o{ agent_sessions : tracks
  workspaces ||--o{ terminal_sessions : logical_owner
  runtime_targets ||--o| browser_targets : extends
  runtime_targets ||--o{ running_processes : focus_target
  runtime_targets ||--o{ agent_sessions : focus_target
  agent_sessions ||--o{ agent_session_events : records
  agent_sessions ||--o{ agent_subscriptions : watched_by
  terminal_sessions ||--o| terminal_runtime_states : state
  terminal_sessions ||--o{ terminal_clients : clients
  terminal_sessions ||--o{ terminal_attachments : attachments
  terminal_sessions ||--o| terminal_remote_session_states : final_render
  terminal_sessions ||--o{ terminal_agent_signal_events : pending_signals
```

| Group | Tables | Role |
| --- | --- | --- |
| Project templates | `projects`, `project_services`, `project_processes`, `project_browser_sessions`, `project_agent_launchers` | Defaults seeded into each workspace at creation |
| Workspace config | `workspaces`, `workspace_settings`, `workspace_services`, `workspace_processes`, `workspace_browser_sessions`, `workspace_agent_launchers` | Per-workspace overrides after creation |
| Runtime records | `workspace_service_ports`, `runtime_targets`, `browser_targets`, `running_processes`, `agent_sessions`, `agent_session_events`, `agent_subscriptions`, `agent_pending_notifications`, `agent_remote_subscriptions` | Live state, kept separate so template edits coexist with running processes |
| Terminal persistence | `terminal_sessions`, `terminal_runtime_states`, `terminal_clients`, `terminal_attachments`, `terminal_remote_session_states`, `terminal_agent_signal_events` | Session identity, attachments, final render state |
| Device | `settings`, `migration_state`, `ignored_worktrees` | Global preferences, schema version, discovery exclusions |

Uniqueness outside primary keys: `projects.dir`; `workspaces(project_id, branch)` for active non-empty branch names; `root_directory` on each of the three terminal tables that carry it; `agent_pending_notifications(subscriber_terminal_session_id, agent_session_id)`, which makes `INSERT OR REPLACE` coalesce a child's queued notifications to one latest-state line. Partial unique indexes on `terminal_attachments` enforce at most one active owner per root, and at most one active attachment per root/client pair.

### Window-ID ownership

There is no desktop or window-manager window identity anywhere in the daemon. Terminals, processes, and coding agents are tracked by terminal session ID; `runtime_targets` carries no `window_id` column and the device overview emits none. This is what lets a remote viewer render a device's runtime without being able to focus another desktop's windows.

The single exception is the Chrome window containing a browser session's tab, which is a client/desktop concept. The GUI records it in the client `browser_session_window_ids` table, keyed by `device_id` + `workspace_id` + resolved `target_url`, through `ClientBrowserWindowIDStore`. Several sessions in one workspace may share one Chrome window so they stay grouped as tabs.

### Runtime target model

- `runtime_targets` is the canonical inventory of focusable runtime items for a workspace: `type`, host app, durable terminal `tracking_id`, ordering, display metadata. The persisted `type` string is surfaced through the `WindowRole` typed view.
- `browser_targets` extends a browser target with its configured URL.
- `running_processes` and `agent_sessions` each link to a `runtime_target` when focusable, and each carries a durable `terminal_session_id` used for focus, restart, and final-frame viewing.
- `agent_session_events` records signal-driven lifecycle transitions, giving an inspectable trail across rebind, detach, and prune. Readiness for orchestration (`lastAgentSignalAt`) is defined as the most recent `agent_session_events` row whose `source` is `spaces_agent_signal`, so foreground-detected rows — which never signal — read as not-yet-ready.
- `agent_sessions.note` is an explicit, human-authored annotation for orchestration. It is written only through the annotate path (`setAgentSessionNote`); the `upsertAgentWindow` conflict clause coalesces an incoming null note back to the stored value, so a status signal never clobbers an annotation.
- `agent_subscriptions` is the same-device subscribe relationship an orchestrator uses to watch other agents. Its subscriber key is a **terminal session id**, not an agent id, because a subscriber may be a plain terminal with no agent row of its own; its target is an **agent session id** with an `ON DELETE CASCADE` foreign key, so deleting an agent row (e.g. an ad-hoc agent pruned on exit) removes its inbound subscriptions automatically. There is no parent/child column on `agent_sessions` — the subscription edge is the only relationship between agents.
- `agent_remote_subscriptions` is the cross-device counterpart: a local subscriber terminal watching a coding agent on a paired device. `agent_session_id` holds the watched child's **terminal session id on that device** — the stable cross-device handle a user addresses and a deep link targets — not a local row id, so the table deliberately has **no foreign key** (the watched agent lives in another device's database). Its lifecycle is driven by the watch service rather than a cascade: when the remote agent exits, the terminating line is delivered and the edge is dropped. Keying on the child's terminal session id also makes `agent unsubscribe --device` a local-only delete that works even when the device is offline.
- Targets are seeded as soon as a process or agent terminal is known, not filled in by a later window-reconciliation pass.

### Data modeling guidelines

- Base tables stay generic. A field that only makes sense for one provider belongs on an adapter-specific runtime path, not a cross-cutting base record.
- `runtime_targets` owns focus identity; process and agent rows own their configured slot state.
- Correlate and focus by durable terminal session identity, never by transient OS window handles.
- Agent rows describe logical session state, not terminal rendering internals; process rows describe process runtime and slot ownership, not window fields.
- Avoid provider-specific naming in shared schema. Generic `provider` and `session_key` are fine; a field named after one product is transitional.
- Prefer an event history for destructive transitions over piling `last_*` and `*_reason` columns onto canonical state rows.
- Add abstractions when behavior needs them. Speculative tables and fields wait for a real workflow.

Foreign keys stay enabled. Store-level delete-and-reinsert updates run inside immediate transactions so a partial child-table replacement cannot persist when one statement fails.

### Client database

Keyed by `device_id` wherever a row is scoped to a paired device, so one client database describes the local Mac and every remote it has paired with.

```mermaid
erDiagram
  paired_devices {
    TEXT id PK
    TEXT certificate_fingerprint
    TEXT ssh_host
  }
  client_settings {
    TEXT key PK
  }
  project_sidebar_state {
    TEXT device_id PK
    TEXT project_id PK
    INTEGER is_collapsed
  }
  browser_session_window_ids {
    TEXT device_id PK
    TEXT workspace_id PK
    TEXT target_url PK
    INTEGER window_id
  }
  workspace_panel_layouts {
    TEXT device_id PK
    TEXT workspace_id PK
    TEXT layout_json
  }
  panel_windows {
    TEXT id PK
    TEXT layout_json
    REAL width
  }
```

## Subsystems

Each section states what the subsystem is, where it lives, and the decision that governs it. The traps that shaped the code are collected in [Hard-Earned Learnings](#hard-earned-learnings).

### Panels and terminal panes

Terminal sessions present as panes inside tabbed panels, never as standalone windows. The machinery lives in `spacesui/Panels/`. `PanelLayout`/`PanelLayoutEngine` are pure value types and mutations — splits, closes with collapse, pruning, focus fallback — serialized as versioned JSON into the client database. `PanelCoordinator` (an `AppKitController` sub-controller) owns per-scope layouts and one `TerminalPaneContentController` per open session, enforcing **at most one pane per session across all panels**. `TerminalSessionPaneViewController` (`spacesterminalui`) owns all window-independent content: renderer switching, attachment lifecycle, key translation, find.

There are two `PanelScope`s: the selected workspace's panel, which fills the main window's right pane, and global panel windows (`.globalWindow(panelWindowID:)`). `PanelWindowController` is only an NSWindow shell — all layout state stays in `PanelCoordinator`. Moving a pane between them reuses the same remove-then-insert mutation that splitting uses, so the live Ghostty surface re-parents rather than being recreated. Global panel windows exist to mix workspace-bound sessions from different workspaces or devices in one window; every session is still workspace-owned. A window shell exists only while its layout has content, and every path that empties one funnels through a single dismissal that persists the deletion and closes the window.

Panes render the terminal surface only — runtime lifecycle actions live on the sidebar target rows. Lifecycle actions never remove panes; a pane keeps showing its session's final render.

### Focus and window cycling

Focus is a client concern, reconstructed from the overview. One device-agnostic dispatcher resolves a focus target — a browser URL, a terminal session, or a run-process/run-agent action — from the selected workspace's overview. Sidebar target rows, numbered shortcuts, the command palette, and attention-item focus all share it, so every surface gets identical recovery and hide policy. A missing pane is simply reopened by the dispatcher; there is no separate "recover this window" prompt.

Only two leaves depend on where the workspace's daemon runs: a browser session focuses a local Chrome tab (a remote service URL routes through the SSH forward and Caddy first), and a terminal session opens or focuses its pane through `PanelCoordinator`, with local and remote panes sharing one device-backed state path.

Focusing a terminal is an owner-intent, foregrounding action symmetric with focusing a browser: it activates Spaces, cancels any pending hide-after-browser-focus task, and reclaims owner attachment. Cycling rebuilds the same ordered targets, filters to those with an already-open client window, and tracks an in-memory cursor and short-lived cycle session per workspace — no database persistence. `WorkspaceRuntimeTargetIndex` materializes the one ordering shared by sidebar rows, palette items, numbered shortcuts, and cycling. Observable cycling rules are in [spec.md](spec.md).

### Browser sessions and service routing

The macOS daemon runs a bundled Caddy reverse proxy mapping `http://<service>.<slug>.localhost:<router port>` to each service's assigned port. Routing runs only on the Mac, because that is where the browser lives; headless daemons never seed a router port. Transport is plain HTTP bound to loopback only, so there is no LAN listener, TLS material, or certificate trust to manage — Chrome and Safari treat `*.localhost` as a secure context.

For a remote workspace, `BrowserSSHForwardManager` owns one `ssh -L` process per (device, workspace) with one binding per assigned service. It writes client-owned routes into the profile route registry and asks the local daemon to reconcile Caddy; the daemon is the only component that reloads Caddy, merging daemon-owned local routes with client-owned forward routes. Remote overview updates preload forwards for running workspaces and stop them for stopped ones, with on-demand opening as the fallback.

Browser-session matching is URL-based and tolerant of equivalent host forms, normalizing scheme, host, port, and path so `google.com` and `www.google.com` resolve to one session. Focus uses the tracked Chrome window ID for the fast path, then scans all windows by URL to adopt a tab the user moved by hand, then opens into an existing tracked workspace window before creating a fresh one.

iOS cannot script Chrome or hold an SSH session, so it reaches a workspace's browser sessions through a raw byte tunnel over the Device API instead. `openServiceTunnel(workspaceID, serviceName)` resolves the service's daemon-local port and dials IPv4 and IPv6 loopback; once the daemon acknowledges, the pinned-TLS connection becomes a transparent byte pipe spliced to the service — one TLS connection per browser TCP connection, no multiplexing (TLS already gives per-stream flow control), bounded at 64 concurrent tunnels per daemon. On the phone, `BrowserProxyServer` is a fixed-port loopback reverse proxy that routes by `Host` header and requires an unguessable per-route cookie before dialing, preserving the same per-service origin identity (`<service>.<slug>.localhost`) the Mac's Caddy flow gives Chrome, so cookies and storage isolate per service. The relay does a true half-close on both platforms and is identical for local and remote workspaces, so a phone reaches a remote workspace's browser session even while the Mac is asleep. The Mac's own Chrome-plus-Caddy flow is unchanged; the tunnel is a parallel mechanism for a client that has neither.

### Device API and pairing

Each daemon creates or loads a self-signed TLS identity under `~/.spaces/runtime/daemon-tls` (DER on macOS loaded into a Security identity; PEM on Linux loaded into the OpenSSL listener). Every client verifies the daemon's certificate fingerprint before sending any request, then presents a per-client token issued during a short-lived pairing window. Pairing links (version 3) carry endpoint, nonce, short code, certificate fingerprint, wire-protocol version, and app version. There is no transport key.

When a remote device has no Spaces installed, pairing fails with a **structured** `remoteSpacesNotInstalled` error carrying install guidance, not a prose string, so the client renders it as an affordance. An Ubuntu 24.04 target's error carries a version-pinned `curl -fsSL https://usespaces.dev/install.sh | bash -s -- <version>` command, and `installSpacesOnRemoteDeviceAndPair` (behind the "Install Spaces over SSH" action) runs that installer over an SSH `ControlMaster` and re-pairs on success with no second user action. The single Linux install path is `scripts/spaces-install-linux.sh`, served at `https://usespaces.dev/install.sh` (copied into `apps/web/public/` by the web build's `prebuild` step, not published as a per-release asset); it verifies the release manifest's Ed25519 signature *before* trusting its version, checksums the Ubuntu 24.04 archive, and enables systemd user lingering so the daemon survives SSH disconnects.

The listener binds all IPv4 interfaces on port `47847`, overridable by `SPACES_DEVICE_API_PORT`. The resolved host and port persist in `device-api.json` under the runtime root so paired clients keep reconnecting to a stable endpoint. The daemon advertises `_spaces-device._tcp.` over Bonjour for discovery only.

The API exposes device info, pairing, paired-client management, project and workspace CRUD, terminal and process and agent lifecycle, notes, setup state, alerts, and config import/export. Requests use a typed command envelope; responses use a typed result envelope. Mutation responses carry a refreshed overview plus action-specific identifiers, which keeps clients synchronized without inferring affected rows.

Terminal link opening also rides the API. `SpacesDeviceTerminalLinkClassifier` (`spacesdevicecore`) is the single cross-platform authority that classifies a clicked string as a web URL, a loopback URL, or a file link, and classifies a file's content type into a previewable artifact kind (raster image, video, PDF, Markdown, text, HTML). A local session's file link opens directly on the Mac — any file it can open — with no round trip; a remote session's link resolves on the daemon (`resolveTerminalLink`) and streams the file to the client in authorized chunks (`readTerminalLinkChunk`) keyed by a short-lived in-memory approval, so iOS and a remote macOS pane preview the artifact without SSH. iOS routes each resolved artifact to a dedicated viewer by kind and treats every loopback link as unreachable, since it is always a separate device from the session's host.

The macOS sidebar renders one section per paired device, each with an independent load state, so one offline device never fails the whole sidebar — including the local Mac, which degrades to `.offline` like any remote. Remote sections stay live through a per-device `subscribeOverview` push stream rather than polling; a dropped stream and a failed initial connect schedule the same delayed retry. The daemon's `DeviceOverviewStreamServer` rebuilds and pushes when source data changes, coalescing bursts into one broadcast.

Alerts aggregate across devices from one client-side builder over each device's overview payload, so the local device needs no orchestrator and no protocol differs by device.

### Wire compatibility and daemon restart

Clients and per-device daemons update on independent cadences, so a client can meet a daemon running a different build. Compatibility gates on `SpacesWireProtocol.version` — a hand-maintained integer distinct from the marketing `AppVersion`, raised whenever the Device API or TerminalService contract changes. Client and daemon must match it **exactly**; there is no backwards-compatibility window.

A **frozen stable core** of commands keeps a contractually fixed shape so even an incompatible client can negotiate and recover: `daemonStatus`, `requestDaemonRestart`, and `ping`. These cases are never removed or renamed, and `TerminalServiceDaemonStatus` decodes tolerantly — every field `decodeIfPresent` with a default — so a peer with a different field set still yields a decodable status.

Failure responses carry a machine-readable `errorCode` (`SpacesDeviceErrorCode`) alongside the human message. Clients branch on the code, never on substring-matching the message: the TLS servers close a pipelined connection only on `.unauthorized`, and authentication failures route into the re-pair recovery flow.

An incompatible device is **fully blocked** — no mutations, no overview data rendered — while other paired devices stay fully functional. A daemon applies an update by `execv`-ing the staged binary at the **same pid** rather than exiting for launchd/systemd to respawn, so its shells, coding agents, and workspace processes stay children of one unbroken pid and no session is interrupted. `requestDaemonRestart` triggers this in-place handoff, so the block offers a direct Restart for a local or remote Mac with no impact warning. A Linux daemon updates by installing a fresh release, so its block shows the version-pinned install one-liner instead; the installer pokes the running daemon (`spaces daemon apply-update`) to hand off in place, preserving its sessions across the reinstall. The handoff generation guard blocks a fourth consecutive same-version exec when no intervening run lasts one minute, then resets the chain after one minute of stable post-replay runtime so later development artifacts with unchanged version metadata remain installable.

The handoff (`spacesterminalcore/DaemonHandoff.swift`, cross-compiled to Linux) quiesces each session, hands its PTY master descriptor — `FD_CLOEXEC` cleared — plus a handoff table across the `execv`, and the resuming image replays each session's `output.log` at the persisted grid size before reading the live fd, so scrollback reflows exactly as it did before. The table is consumed at most once and only when its recorded pid equals the current process, which is what separates an exec-resume (pid preserved) from a crash respawn (new pid). The old image first runs the staged binary once with `--handoff-check`, and a generation counter guards against an exec-loop between two bad builds; every failure path — rejected preflight, guard trip, or a failed transcript flush — rebinds the quiesced sessions in place and leaves the daemon fully functional. A silent handoff fires on its own when a compatible daemon reports its on-disk `installedVersion` is newer than the build it is running.

### Discovery and reconciliation

Worktree discovery is owned by `spacesd`, not the GUI, because it acts on the device's own filesystem and database and must therefore run on headless remotes too. `WorktreeDiscoveryService` runs a catch-up scan at daemon startup and installs a `FileSystemWatcher` per local git project on the repo's git common directory (FSEvents on macOS, inotify on Linux).

Sidebar refresh is **write-triggered, not file-watched**: every process that commits a database write posts a profile-scoped `IPCNotification.databaseDidChange` from the `SQLiteStore` transaction commit, and the app reloads on that signal. `SidebarReloadCoordinator` coalesces — one snapshot load at a time, one pending request merged behind it.

Owned child-process exit detection also lives in `spacesd`: `ProcessExitMonitorService` installs a `DispatchSourceProcess` per running pid and runs the orchestrator's reconcile on exit, applying the configured on-exit behavior. This is the **device-detects, client-notifies** pattern. Device-runtime watchers live in the daemon; watchers that drive only client UI state stay in `AppKitController`/`SidebarController`. When a watcher cannot be installed, the affected feature surfaces the failure instead of falling back to polling.

Reconciliation may degrade runtime health, but never silently promotes or demotes workspace lifecycle state.

### Coding agents

Agent events are explicit CLI inputs. `spaces agent signal` resolves explicit workspace and terminal-session IDs: `init` creates or attaches the originating terminal's agent row, and non-`init` events update an existing row.

Independently, `TerminalForegroundAgentReconciler` in `spacesd` classifies the live foreground process of each terminal session against a known set (`codex`, `claude`, `claude-code`, `opencode`) and creates ad-hoc agent rows. The classifier matches the resolved executable basename and the POSIX `argv[0]` basename, then handles Node wrapper scripts; later arguments are ignored, so an editor or search tool that merely mentions an agent name is never promoted. Once a live session has an agent row, foreground samples never relabel, reclassify, or remove it.

Configured launcher rows occupy stable slots first, with unmatched ad-hoc rows appended, so shortcut ordering stays deterministic. Configured-agent relaunch is conservative: a reserved row still pointing at a live terminal makes launch a no-op, and only clearly stale rows are evicted. Alerts attention state derives from runtime records, never from UI state; dismissals persist as a set of attention-event IDs.

For those signals to fire, each agent's shell integration must call `spaces agent signal`, and `AgentHookInstaller` (`spacesterminalcore/AgentHooks/`, cross-compiled to Linux and run by the owning daemon on its own home) installs those hooks. `SupportedCodingAgentHook` owns each agent's config paths and event bindings: Claude Code and Codex share a JSON hook file (Codex additionally toggles its `hooks` feature through its own CLI), and opencode gets a Spaces-owned plugin. Availability probes the daemon user's interactive login-shell PATH — cached briefly — so version-manager installs are detected. Generated commands end in `|| true`, discard output, and embed a `SPACES_HOOK_VERSION` marker, so a stale hook reads back as outdated and the UI offers Update; writers ensure desired state rather than appending, and follow a config's symlink chain so a dotfiles repo is not silently detached. The daemon exposes `agentHooksStatus` and `installAgentHooks` over the Device API, so one `CodingAgentsView` manages local or remote hooks. Installs are always **user-initiated** — from Settings → Coding Agents or the launch setup step, never automatic. The setup step gates on This Mac only (a paired remote may be asleep) and writes its dismissal marker only when the user explicitly skips a given hook version, never when no agent was detected, so installing an agent later still surfaces the step.

### Theming

A Spaces-owned theme model is the single source of truth for app and terminal colors. `spacesterminalcore/Theming/` holds pure value types — `ThemeID`, `ThemeColor`, `ThemeAppearanceTokens`, `GhosttyThemeExport`, `ThemeDescriptor` — plus `ThemeRegistry`, seeded with the single shipped `spaces-brand` theme. The module is UI-free; adapters convert raw color data to platform types.

Theme selection is internal-only: `ActiveTheme` binds a process-wide value at launch from the client setting `app_theme_id`, with no settings control or change notification. App appearance (light/dark/system) is separate and user-facing, sharing one vocabulary (`AppAppearanceMode`) across both apps. Because the terminal variant and the AppKit tokens both resolve off `NSApp.effectiveAppearance`, that single lever drives app chrome and terminal variant together.

Local terminals are themed by config: `GhosttyThemeConfigGenerator` regenerates `<profile-root>/ghostty/` at every embedded-app start. Remote terminals are themed **at the source** instead, because their cell colors are baked into the render frames the daemon streams; `GhosttyEmbeddedSessionCore` resolves the palette from `ThemeRegistry` and hands it to the vt shim at session creation. The daemon cannot read the client's OS appearance, so light/dark rides the `attach` request and later changes ride the `setAppearance` command.

Future public theming builds selection UI and import/export on top of this model. Raw Ghostty theme files never become the app's source of truth.

### Editor integration

The preferred editor is VS Code, Devin Desktop, or Zed. `EditorPreference` is the single source of truth for each editor's display name, bundle identifier, and launch `family`. Editors are located by bundle identifier so detection survives app renames, and launched through their own command-line tool rather than `open -b`.

The `vscode` family (VS Code and its Devin Desktop fork) reads `product.json` to resolve the CLI and per-user data directory. A remote workspace opens with `--folder-uri vscode-remote://ssh-remote+[user@]host[:port]/path`, which requires an SSH-remote extension; the fork bundles one, stock VS Code does not, so the client checks and offers to install. Zed is its own family: a fixed `Contents/MacOS/cli`, built-in SSH remoting, and a plain `ssh://` URI.

Because the CLI forwards a folder open to a running instance — which focuses the existing window — the client tracks no editor windows of its own.

### CLI and MCP server

`spacescli` exposes grouped project, workspace, agent, terminal, pairing, and MCP commands. The CLI and the MCP server share one routing rule, decided by whether the invocation names a paired device:

| Route | Taken when | Transport |
| --- | --- | --- |
| `TerminalServiceProfileCommand` | No device selector | Profile service socket to the adjacent `spacesd` |
| `SpacesDeviceClient` | `--device <name-or-id>`, or the MCP `device` argument | Device API |

The three terminal commands (`terminal list`, `terminal tail`, `terminal send`), the discovery listings `project list` and `workspace list`, the workspace lifecycle commands `workspace create`/`start`/`restart`, and the agent orchestration commands `agent spawn`, `agent list`, `agent status`, `agent annotate`, `agent interrupt`, and `agent kill` accept a device selector, so they can take the Device API route. This is the surface an orchestrator on one device needs to discover and prepare work on a paired device before spawning agents there. `agent subscribe`/`unsubscribe` accept `--device` but always target the **local** daemon over the profile socket — the device selector names where the watched child lives, not where the command runs, because the watching daemon (this machine) owns the subscriber terminal and does the watching. `agent signal` always targets the same-machine daemon and takes no `--device`: an orchestrating agent may read a peer's status but must not forge it on another device. `spaces device list` reads the client database and contacts no daemon at all.

The discovery listings are **overview-backed**, not new Device API commands: `project list`/`workspace list --device` read `SpacesDeviceClient.projects`/`.workspaces`, which return the `projects`/`workspaces` arrays the device overview already carries (the same payload the sidebar loads), so the remote path adds no listing RPC. Because that overview lists only active workspaces, `workspace list --device` cannot surface archived ones; rather than silently return a filtered subset that reads like the full archived listing, it rejects `--include-archived` with `--device` loudly. `workspace create`/`start`/`restart --device` route to the existing `createWorkspace`/`launchWorkspace`/`restartWorkspace` Device API mutations. One semantic difference is deliberate: local `workspace start` uses `upWorkspace(restartIfRunning: false)` (idempotent ensure-running that also restarts exited processes), while the remote `launchWorkspace` is the daemon's plain launch and errors if the workspace is already running — an orchestrator starting a freshly created workspace is unaffected, and there is no existing Device API command for the ensure-running semantics.

The agent orchestration read/annotate commands (`agent list`, `agent status`, `agent annotate`) and their MCP tools (`spaces_agent_list`, `spaces_agent_status`, `spaces_agent_annotate`) resolve the daemon-side agent view — status, note, project/workspace/branch context, and `lastAgentSignalAt` readiness — and render a `spaces://terminal/<session-id>` deep link per row (`SpacesTerminalDeepLink`). The list-row build and the annotate write both live on `WorkspaceOrchestrator` (`agentSessionRows`, `annotateAgentSession`, `sanitizedAgentNote`), so the local profile handler and the Device API handler (`listAgentSessions`/`annotateAgentSession`) map identical rows from one implementation rather than duplicating the join and sanitize logic. `agent signal` is deliberately never exposed as an MCP tool: an orchestrating agent may read peers' status but must not forge it. `status`/`annotate` default their target session to `SPACES_TERMINAL_TRACKING_ID`.

`agent spawn`/`interrupt`/`kill`/`subscribe`/`unsubscribe` and their MCP tools run over the same profile socket. Spawn creates an ad-hoc coding-agent terminal through `Orchestrator.createWorkspaceAgentSession`, which mirrors `createWorkspaceTerminalSession` but launches with `kind: .agent`. That kind is load-bearing: the signal chokepoint (`recordProfileAgentSignal`) drops a non-`init` first signal unless it has deterministic label evidence that the session is an agent, and a `.agent` launch configuration is that evidence — so a coding agent like Codex that emits `working` before (or instead of) `init` still registers on its first signal. Spawn gates its command first (`AgentSpawnCommandGate`): the command's executable token — parsed past leading `VAR=value` assignments and a leading `env` — must match a supported coding agent whose hooks are `.current` (read via `AgentHookInstaller.status()`), otherwise there is no source for the readiness signal and the request fails loudly rather than starting an un-observable session.

Readiness is defined as the first hook-sourced lifecycle event (`lastAgentSignalAt != nil`), not "an agent row exists": foreground detection creates rows without signals, so a row alone is not readiness. The readiness wait is a CLI-side poll (`awaitAgentReadiness`, every 500ms up to the `--timeout` budget), not a blocking daemon RPC, because the daemon handles profile commands serially — a blocking spawn RPC would deadlock against the very `agent signal` it waits for. Per-provider signal behavior differs, and readiness inherits it: Claude Code and opencode emit `init` at session start, but Codex's interactive TUI emits no `SessionStart` hook at all — its first signal is `working` at the first prompt submission — so a Codex spawn without a prompt runs the full readiness budget out. Codex also gates hooks behind its own interactive trust review: after any hook install or change, the next Codex session shows a "hooks need review" prompt and fires nothing until the user trusts them, which reads from the outside as an agent that never signals; the spawn timeout message points at `terminal tail` because that is where both of these states are visible. The CLI and the `spaces_agent_spawn` MCP tool share one `performAgentSpawn` implementation so both block identically. Because agent rows only appear on the first signal, auto-subscribe runs after readiness (the subscription targets the resolved agent-session row id) and `--prompt` injection runs after that, over `.terminalSend`. `agent kill` resolves the Spaces agent row by terminal tracking id across workspaces (`resolveSpacesAgentSession`) and stops it through the coding-agent stop path, which terminates the terminal and deletes the row; before the first signal there is no row, so it terminates the terminal session directly, and a session that is neither an agent row nor a live terminal is a loud error. `interrupt` sends ESC (byte 27) over `.terminalSend`; killing a TUI is `kill`'s job. `unsubscribe` removes the edge through `deleteAgentSubscription`. `subscribe` runs `WorkspaceOrchestrator.validateAgentSubscription` before `insertAgentSubscription`: the target agent row must exist, must not run in the subscriber's own terminal, and must not close a cycle. Cycle detection treats the subscription graph as nodes = terminal session ids with edges `subscriber → the watched agent's terminal`; the proposed edge adds `subscriberTerminal → targetTerminal`, so it walks existing edges outward from `targetTerminal` (each terminal's own subscriptions, mapping each watched agent back to its terminal) and rejects the subscribe if the walk reaches `subscriberTerminal`. Enforcing acyclicity at subscribe time is what lets the injection engine deliver without loop guards. With `--device`, `subscribe`/`unsubscribe` record a **cross-device** edge instead (see below); the acyclic invariant is same-device only, because the remote's own subscription graph is not queryable locally.

The notification injection engine (`AgentNotificationEngine`, `workspacecore`) is pure logic over the store plus an injected `deliver(sessionID:line:)` closure; the daemon attaches it at the `recordProfileAgentSignal` chokepoint, wiring delivery to the same `sendProfileTerminalInput` path a `terminal send` uses (newline appended). One engine is built per signal and discarded. When a signal moves a child to blocked/done/exit, the engine renders one line per subscriber of that child and either delivers it now (subscriber idle) or coalesces it into `agent_pending_notifications`. A subscriber is idle when its own agent row is idle/done or absent (a plain terminal is always ready); spinning/waiting is busy. When a signal leaves the *signaling* terminal's own row idle/done (`init`, `done`, or `exit`), the engine flushes that terminal's pending queue in `created_at` order, deleting each row as it goes so a line is delivered exactly once. The line is fully rendered at enqueue time (`[spaces] <label> (<agent>) is <word> — note: <note> — open: <deep-link>`, note omitted when unset); the `[spaces]` prefix guarantees it never begins with `#`, `/`, or `!`. Notes and labels are rendered verbatim — notes are stripped of control characters at annotate time and labels come from launch-config titles, so there is no second sanitization pass. `agent_pending_notifications` deliberately has no foreign key to `agent_sessions`: for an `exit`, the engine renders and enqueues before `handleAgentExit` deletes the ad-hoc row (which cascades the subscription edges away), and the FK-free pending row is what carries the notice past that deletion. Its unique `(subscriber, agent)` index makes `INSERT OR REPLACE` coalesce a child's repeated transitions to one latest-state line while its subscriber is busy. A delivery that throws means the subscriber terminal has ended: the engine drops the subscription edge (and, on a flush, the pending row) and logs to stderr, so a vanished subscriber never accumulates undeliverable state.

### Remote orchestration routing (`--device`)

With a device selector, the orchestration commands route through the Device API instead of the profile socket. `spawnAgentSession`, `listAgentSessions`, `annotateAgentSession`, and `terminateTerminalSession` are dedicated Device API commands (`listAgentSessions` is marked replay-safe; the three mutations are not); interrupt reuses `sendTerminalInput` (ESC byte). Remote kill mirrors the local kill in two steps: it resolves the child's agent row through `listAgentSessions` and stops a signaled child through `stopCodingAgent`, and when no row exists yet it terminates the raw session through `terminateTerminalSession`. The server handlers run the same shared `WorkspaceOrchestrator` logic as the local path — including the identical `AgentSpawnCommandGate` hook gate — so the remote surface enforces the same contracts and reports the same rows (mapped to `SpacesDeviceAgentSessionRow`). Remote spawn differs in one contract: `workspaceID` is required, because a remote client shares no working directory the daemon could infer the workspace from. Remote readiness is still a client-side poll, now against `SpacesDeviceClient.listAgentSessions`, sharing `awaitAgentReadiness` with the local path through an abstracted row-fetch closure.

`terminateTerminalSession` is the remote counterpart of the local `.agentKill` terminate branch (`killProfileAgentSession`). It carries only the terminal session id — deliberately no `workspaceID`, because a pre-signal session has no agent row an orchestrator could resolve the workspace from, which is the exact gap this closes. The server handler calls `WorkspaceOrchestrator.terminateSpawnedAgentTerminalSession(sessionID:)`, which resolves the session's owning workspace from its tracking rows and tears the session down; a session that is not a tracked built-in terminal is a loud error. That method is distinct from `stopAdHocBuiltInTerminalSession`: the latter gates on ad-hoc-*shell* ownership and so refuses an `.agent`-kind session, while a spawned agent's launch kind is `.agent`; the kill path must not exclude it. `stopWorkspaceTerminal` was likewise not reused: it requires the `workspaceID` the pre-signal kill path cannot supply.

#### Cross-device subscriptions (the daemon as a device client)

A subscriber terminal can watch a coding agent on a paired device, receiving the same blocked/done/exited lines it gets for local children. The watching is done by the **subscriber's own daemon** acting as a Device API client — `spacesd` reads paired-device records and owner-only auth tokens exactly the way the CLI does, so no daemon-to-daemon peering is needed. `spaces agent subscribe <child-session> --device <name>` (and the `spaces_agent_subscribe` MCP `device` argument, and a remote `spawn`'s auto-subscribe) sends `.agentSubscribe` to the *local* daemon with the child's terminal session id and the device id; the subscriber is always the local terminal. The daemon validates the device is paired and that the child has an agent session on it (`RemoteAgentSubscriptionValidation.validate`, one `listAgentSessions(sessionID:)` call — a loud error otherwise), then records a row in `agent_remote_subscriptions` keyed on the child's terminal session id. Unsubscribe drops that row locally with no remote call, so it works even when the device is offline.

`RemoteAgentWatchService` (a `@MainActor` service owned by the daemon, started from `startDeviceRuntimeServices` and reconciled by the `databaseDidChange` observer) does the watching, modeled on the Mac sidebar's remote-overview consumer. For each device with at least one watch edge it holds one long-lived `subscribeOverview` push stream (detached connect, 5s reconnect on disconnect/failure — the stream has no built-in reconnect). The overview push is treated **purely as a change signal**: its `codingAgentRows` lack the note and status detail needed to tell blocked from waiting or to see an exit, so on each push the service pulls `listAgentSessions` (the source of truth) and diffs successive snapshots (`RemoteAgentSnapshotDiff`) to recover transitions — a status change to `waiting` is blocked, to `done` is done, and a previously-seen watched child that is absent from the listing has exited. Emission is gated per-agent on a prior observation, so the first snapshot after a (re)connect seeds a baseline silently (no replay storm on reconnect) and a freshly added edge seeds silently (subscribing never replays the state the child was already in). Transitions are delivered through the **same** `AgentNotificationEngine` — its remote entry point shares the idle-gating, `agent_pending_notifications` queue/flush, and render logic with the local path, differing only in that subscribers come from `agent_remote_subscriptions` and the deep link is device-qualified (`?device=<id>`). An exited transition delivers (or queues) the line and then drops the edge; a delivery that throws (the local subscriber ended) drops the cross-device edge. A device that is no longer paired has its edges dropped loudly.

**Cross-device cycle detection is not possible** and is not attempted: the acyclic invariant can only be checked against edges this daemon can see, and a paired device does not expose its own subscription graph. A pathological A-watches-B-watches-A loop across two machines is therefore the operator's responsibility.

Those `spaces://terminal/<session-id>[?device=<id>]` deep links (`SpacesTerminalDeepLink`, the single render/parse type used everywhere) are clickable end to end. The macOS app registers the `spaces` URL scheme through `CFBundleURLTypes` in the Info.plist template inside `scripts/sync-app-version.sh` — the generated `Sources/SpacesApp/Info.plist` is never hand-edited, so the scheme lives in the template or the next sync drops it (iOS registers the same scheme in its hand-maintained plist). `AppKitController.application(_:open:)` parses each incoming URL: a terminal link with no `device` (or the local device id `"local"`) opens the pane through `openTerminalSessionPane`, the exact path the `terminal show` IPC takes; a link naming a different paired device resolves that device's record and the session on it — from the device's loaded overview, else a fresh off-main Device API overview query (`resolveSessionSummaryMatchOffMain`) — then opens the session's remote-attached pane through that same `openTerminalSessionPane`, handing in a request built by `terminalSessionPaneOpenRequest(from:)` that pins the session's owning device so the pane attaches remotely instead of falling back to the local device the session-id-only resolve would pick; an unpaired/unreachable device or a session the device doesn't have surfaces a loud, specific alert; a `spaces://pair` link is redirected to the phone pairing flow rather than dropped; anything else is an "unrecognized link" alert. In-terminal clicks route through `SpacesDeviceTerminalLinkClassifier.route(for:)`, which gained a `.spacesTerminal` case classified purely by the URL scheme — Ghostty reports click kind `.unknown` for both regex-detected and OSC 8 links, so kind cannot be trusted — and `TerminalLinkOpenCoordinator` hands that case to the same `AppKitController` handler the URL scheme uses, focusing in-app with no OS round trip. `GhosttyTerminalLinkOpener` (the fallback opener used where no per-pane coordinator is wired) passes a `spaces://` URL to `NSWorkspace.open`, which the OS routes back to the registered scheme handler. On iOS, `RootTabView.onOpenURL` distinguishes the shared `spaces` scheme by shape (pairing vs terminal); `SpacesMobileAppModel.openTerminalDeepLink` switches to the named paired device if needed, resolves the session in the overview, and stages it for the Spaces tab to navigate to. Plain-text `spaces://` links are clickable in embedded terminals because the Ghostty fork's default `url_schemes` allowlist (`src/config/url.zig`) includes `spaces://`; OSC 8 wrapping is not an alternative for notification lines, because an injected line is typed input that the orchestrator TUI echoes as plain text, so only plain-text detection can linkify it.

The profile command is a one-key-tagged union with one case per operation, and required strings are validated at wire decode, so the daemon's `runProfileCommand` destructures a payload and performs only genuinely daemon-side checks.

`spaces mcp` is a JSON-RPC stdio server that an MCP client spawns; each tool call maps onto one of those two routes. Terminal send carries `TerminalProfileInput`, a tagged union of UTF-8 text or raw bytes, so the text-xor-bytes rule is structural on the wire. MCP tool descriptors colocate tool name, input schema, and handler so `tools/list` and `tools/call` cannot drift apart.

`spaces import` is deliberately not a public command: workspace creation allocates daemon state, ports, and setup state rather than passively discovering a directory.

### Environment and process model

Each service definition is allocated a local port per workspace and exposed as environment variables keyed by the uppercased service name with hyphens turned into underscores: `SPACES_<SERVICE>_PORT` (assigned daemon-local port), `SPACES_<SERVICE>_HOST` (routed hostname), and `SPACES_<SERVICE>_URL` (browser-facing URL). `_PORT` and `_HOST` come from the runtime manifest; `_URL` is added in `buildWorkspaceEnv` because it also needs the router port. Per-workspace identity is `SPACES_WORKSPACE_SLUG`, derived from the branch label (or project name) joined with a 12-character stable hash of the workspace ID.

There is no workspace-level host variable: each service already carries its own, so configs reference a concrete service (`$SPACES_WEB_URL`) rather than composing a host by hand.

Port assignments are pinned in the store. A stopped workspace additionally holds a placeholder reservation socket on each assigned port (`PortReserver`). While a workspace runs, assigned ports are best-effort environment contracts; if another process claims one first, the user resolves the conflict manually.

Setup scripts, stop scripts, process commands, and coding-agent launchers all execute on the owning daemon against the workspace environment, through the user's resolved login shell. Each workspace summary in the overview carries the full injected environment map, computed by the owning daemon through the same `buildWorkspaceEnv` used for process launch, so the settings dialog displays authoritative values for local and remote workspaces alike.

Workspace creation, launch, stop, and archive semantics are specified in [spec.md](spec.md). Two implementation patterns are worth naming: the Device API **defers setup** to a background queue with a fresh store and orchestrator, and workspace-terminal creation uses a **reservation path** that persists a `.starting` session and returns its `sessionID` before the shell backend is ready.

### Projects and `spaces.yaml`

A project's identity is a freshly minted UUID, separate from its filesystem path, so the same repository on two devices is two distinct projects and IDs never collide when one client aggregates several devices.

Managed clone directories under `~/spaces/repos` and worktree roots under `~/spaces/workspaces` are keyed by a **deterministic hash of the project source** (directory path or Git URL), never by project name or the project UUID, so cleanup, retries, and same-name projects cannot collide on disk ownership. Replacement of an existing managed folder is limited to entries inside those managed roots, and only when SQLite has no project or workspace owner at or beneath the entry.

Project configuration round-trips through `spaces.yaml`, resolved from the default workspace directory. Schema version `1` is the only accepted version; a missing `version` reads as `1`. Missing optional keys decode to app-state defaults without rewriting the source file, and internal database IDs are never emitted.

| Key | Value |
| --- | --- |
| `version` | Always `1` |
| `setup_script`, `stop_script` | Shell strings |
| `services[]` | Unique DNS-1123 labels, validated at the import and store boundary |
| `processes[]` | `name`, `command`, `on_exit` (`none` \| `restart` \| `notify`) |
| `browser_sessions[]` | `name`, `url` |
| `agent_launchers[]` | `name`, `command` |

A non-git project owns exactly one workspace and can never create more, so its template and that workspace's settings are treated as one. `updateProjectConfig` stays a mechanical primitive honoring its `updateAllWorkspaces` flag; forcing that flag for non-git projects is a **GUI policy**, not a core behavior, which is why the sidebar's flat non-git row opens ordinary project settings.

## Hard-Earned Learnings

Non-obvious constraints that shaped the code. Each names a trap and the consequence of not knowing it. Removing the guard described here reintroduces the bug.

### Editor

- **`open -b <id> --args …` never reaches a running app.** macOS drops `--args` when the target application is already running, so a remote URI silently fails to open. Launches go through the editor's own CLI tool instead.
- **Pin `TMPDIR` when launching an editor.** Going through the CLI makes the detached editor inherit the Spaces process environment. Under a harness-scoped ephemeral `TMPDIR`, the editor writes its SSH askpass script into a directory that is later torn down, and the connection fails.
- **Devin Desktop keeps the Windsurf bundle identifier** (`com.exafunction.windsurf`) after the rebrand. Locating editors by bundle identifier rather than display name survives renames like this.
- **Stock VS Code bundles no SSH-remote extension.** The Devin fork ships `codeium.windsurf-remote-openssh`; stock VS Code ships nothing, so a `vscode-remote://` open fails unless the client checks for a provider and offers to install one.

### SSH and remote

- **Tailscale SSH returns exit 0 even when the remote command failed.** A missing `~/.spaces/bin/spaces` arrives as exit 0 with empty stdout, so not-installed detection must also inspect stderr for the shell's missing-binary text. This is safe only because there is no pairing JSON on stdout to misread.
- **Pair against the effective OpenSSH `HostName`, not daemon-advertised interface metadata.** That is what lets an SSH alias resolve to a direct LAN, VPN, or Tailscale endpoint.

### Pairing and wire compatibility

- **The pre-authentication daemon gate discloses the daemon's app version.** Accepted deliberately: rejecting an incompatible client before validating the code means the one-time pairing window is never burned on a client that could not have used it.
- **A missing `protocolVersion` must decode to `0`, not to a match.** Tolerant decoding keeps the negotiation handshake from throwing, but a daemon too old to advertise a wire version has to evaluate as incompatible rather than as compatible-by-default.
- **Frozen-core commands are never renamed or removed.** `daemonStatus`, `requestDaemonRestart`, and `ping` are the only way an incompatible client can negotiate and recover, so any client that has the feature must always be able to decode them.
- **A transient overview failure must not present the compatibility block.** The standalone handshake is the authority for the blocked case; a failed inline-overview read triggers one extra handshake — which reports compatible — rather than a false block.

### Focus and windows

- **Interactive titlebar chrome must be an `NSTitlebarAccessoryViewController`.** AppKit's titlebar left-click handling intercepts events aimed at ordinary content in that region, below anything a view can override. Content under a hidden titlebar never receives left-clicks.
- **A `.left` titlebar accessory collapses to zero width.** AppKit's private clip view sizes it to its fitting size, so the view must pin the clip to span to the titlebar's trailing edge.
- **Select the rename editor's text with `currentEditor()?.selectAll`, never `selectText(_:)`.** `selectText(_:)` ends the just-started editing session and instantly commits the rename.
- **Overview ticks on a visible panel refresh only the footer.** Re-embedding the panel view destroys transient chrome anchored inside it — notably the tab rename editor. The tab strip likewise skips rebuilds mid-rename and replays the pending state when it ends.
- **The Ghostty mirror reclaims first responder only when focus has fallen back to the window itself.** The reclaim runs on every render frame for every attached owner pane, so grabbing unconditionally would continuously steal focus from sibling panes, the tab rename editor, and sidebar editors.
- **A terminal focus that fails to foreground the app corrupts the next window cycle.** Cycle navigation resolves the current target from the focused terminal only while Spaces is active; otherwise the next cycle starts from the frontmost browser tab instead.
- **Hide the whole app rather than ordering panel windows out individually.** The hide leg takes auxiliary panel windows along and unhiding brings them back, with no per-window bookkeeping.

### Browser and Chrome

- **Once Automation permission is denied, macOS suppresses re-prompts entirely.** The setup screen can raise the system consent prompt only while the permission is undecided; after a denial it must deep-link to System Settings and poll for the change.
- **Treat an unavailable Chrome automation status as do-not-block.** When Chrome is absent or the state is indeterminate there is nothing for the user to grant, so blocking would be a dead end. Consent surfaces on first browser focus instead.
- **Run AppleScript in-process through `NSAppleScript`, not by spawning `osascript`.** A per-focus process spawn is too costly on hot paths such as Chrome tab snapshots. Tests still route through mocked `osascript` commands so they never send real Apple Events.
- **Check whether Chrome is running via `NSRunningApplication`, not via Apple Events.** Probing with Apple Events relaunches a Chrome the user has quit. Workspace teardown closes only the matching tab, never the whole window, so unrelated tabs survive.
- **Exclude longer sibling prefixes from browser-URL fallback matching.** Exact-URL matching runs first; without the exclusion, a grouped root session focuses or closes a sibling path such as `/admin`.

### Caddy, routing, and sockets

- **AF_UNIX socket paths cap at 104 bytes on macOS.** A worktree- or branch-derived runtime directory can exceed that on its own, so the Caddy admin socket is named by a stable hash of that directory and lives in the shared socket root rather than nested inside it.
- **Re-validate the `/tmp` socket root before binding.** It must be a real directory, owned by the current user, with no group or other access — otherwise a predictable `/tmp` path can be pre-squatted by another local user.
- **Wait for a live Caddy by probing the admin socket, not by reading the config file.** The generated config survives a crash or a stop, so trusting it returns focus to an unserved route. Probing makes a stale-config recovery block through the daemon's Caddy restart.
- **`CaddyRouteRegistry.upsert` must evict by registry key *or* by route host.** The key embeds the daemon-local remote port, so a service re-forwarded on a changed port leaves a stale entry that `mergedRoutes` — first route per host — keeps in front of the fresh one.
- **Disable Caddy automatic HTTPS.** This is a plain-HTTP loopback router; left on, Caddy tries to provision TLS for it.
- **Derive the dev router port from a hash of the profile root.** The well-known `7391` is production-only. Concurrent worktrees, or an installed app running beside a dev build, otherwise contend for one port.
- **Route local Caddy upstreams through `localhost`, not a loopback literal.** App servers bind either IPv4 or IPv6 loopback, and only the name reaches both.

### Theming

- **`CGColor`s snapshot the appearance at assignment and never track it.** Layer-backed views assigning `layer.backgroundColor`/`borderColor` do not recolor on a light/dark flip the way dynamic `NSColor`s do, so those sites re-apply through `bindAppearanceReactiveLayer`.
- **`setAppearance` is deliberately not owner-gated.** Appearance is a per-client view preference, so a viewer may send it. Both daemon cores treat a same-value request as a cheap no-op.
- **The appearance broadcast cannot fire-loop.** It only *reads* `NSApp.effectiveAppearance` and sends `setAppearance`; it never assigns `NSApp.appearance`. The KVO observer is required because daemon-rendered terminals have no `NSApp` of their own, so per-view `viewDidChangeEffectiveAppearance` recolors chrome but never reaches them.
- **An appearance change arriving before a pane attaches must be stored, not dropped.** `SessionAppearanceStore` records it so the pending attach carries it.
- **Embedded Ghostty loads only the Spaces-generated config, never `~/.config/ghostty`.** The embedded config also pins `font-size`, overriding personal Ghostty settings inside Spaces, so the default look stays owned by the active theme.

### Database and persistence

- **`user_title` is a separate column from the launch-time `title`.** The runtime title is continuously rewritten from Ghostty `set_title` events, so a manual rename stored there would be clobbered. Effective title resolves `user_title` → runtime title → launch title.
- **The client SQLite connection needs a busy timeout.** The app, CLI, and MCP server write pairing records from separate processes. WAL plus a busy timeout avoids lock failures that are otherwise unavoidable.
- **Check managed-directory ownership twice — at preflight and immediately before deletion.** A folder that becomes database-owned in between must be preserved.
- **Unlink a symlinked managed entry at the managed path; do not follow the link.** Following the target deletes outside the managed root.
- **`PRAGMA user_version` is not Spaces' migration control.** `migration_state.current_version` is authoritative; treat `user_version` as informational when inspecting a database by hand.
- **Delete-and-reinsert child updates run in immediate transactions.** Otherwise a partial child-table replacement persists when one statement fails.

### Device routing

- **Clear a device section's cached overview when it goes offline.** `clientWorkspaceID(forTerminalSession:)` searches section overviews directly, so a stale overview resolves an offline remote's IDs while `deviceID(forWorkspaceID:)` falls back to the local daemon — misrouting terminal cleanup to the wrong device.
- **Terminal state changes raise `TerminalOverviewSignal`, not `databaseDidChange`.** Terminal runtime, title, and exit state live outside the database, so a database-change signal never fires for them. The signal is profile-scoped across processes so a daemon-hosted server hears app-hosted session changes.

### Process and environment

- **The recovery relaunch overwrites `SPACES_DB_PATH`, `SPACES_RUNTIME_DIR`, and `SPACESD_EXECUTABLE`.** This binds the relaunched app to the same profile and keeps terminal prewarm pointed at the still-running service binary, rather than deriving a different profile or path from the app process environment.
- **Any workspace start releases every port placeholder, including a terminal-only start.** Spaces cannot know which configured or ad-hoc process will bind which service port.
- **Bound the login-shell PATH enrichment.** The lookup falls back to the inherited `PATH` plus standard package-manager locations so a slow shell startup file cannot stall app launch. The inherited `PATH` stays authoritative; login-shell entries only fill gaps.
- **Coding-agent launchers run through an inner interactive login shell.** User PATH setup and tool bootstrap from files such as `.zshrc` have to be available to the agent.

### CLI and MCP

- **The MCP argument mapping is the only layer that can reject a text-and-bytes request.** `TerminalProfileInput` makes text-xor-bytes structural on the wire, but MCP arguments arrive as untyped JSON where a caller can supply both at once, so the ambiguity has to be caught during argument mapping rather than at decode.

### Reconciliation and IPC

- **The app's own database reads must not trigger a sidebar reload.** Reload is write-triggered from the transaction commit, which catches external CLI and daemon edits without polling and avoids a file-watch feedback loop. The post is synchronous so a short-lived CLI delivers it before exiting.
- **Wake the worktree watcher only on `HEAD` and `worktrees/` changes.** Ordinary object and index churn from commits would otherwise wake it constantly. Scans are serialized because the burst of filesystem events from one worktree mutation drives overlapping scans that race on row creation.
- **A bundle-less daemon cannot post OS notifications.** The `notify` on-exit behavior is forwarded to the client through `IPCNotification.deliverUserNotification` — the device-detects, client-notifies pattern.

### Deliberately accepted trade-offs

- **Image paste is not replay-safe after an ambiguous connection failure.** Retrying can create multiple temp files and send multiple path strings to the PTY. It stays image-only rather than becoming a general remote clipboard bridge.
- **Archive skips the terminal-exit wait that a plain stop performs.** A stop waits briefly so runtime state stays consistent; archive force-removes the worktree regardless of session state, trading that consistency for speed.
- **The Device API defers workspace setup to a background queue.** A long-running setup script would otherwise block the create request past the client request timeout. The daemon captures a log tail while setup runs or fails, so a remote client can stream progress from a file it cannot read by path.

## Performance Principles

- Focus and capture paths avoid unnecessary blocking work.
- Hot paths that need neither stdout nor stderr use lightweight process spawning.
- Long-running GUI actions execute off the main thread and reconcile state back into the UI afterward.
- Terminal input hot paths avoid publishing state frames that cannot contain render updates. Live streams use in-memory subscription delivery; remote-session-state persistence is reserved for final state and explicit snapshots.

## External Dependencies

- macOS 14+
- Google Chrome, for browser-session automation
- SQLite, for local persistence
- Caddy (Apache-2.0), bundled directly rather than through Docker or Homebrew
- Built-in terminal dependencies and Ghostty fork requirements are documented in [terminal.md](terminal.md)
