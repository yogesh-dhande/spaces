# Spaces Development

Build, test, and release workflows for the Spaces monorepo. For product overview and adoption, see [README.md](../README.md).

## Repo Layout
- `apps/macos`: macOS app, `spaces` CLI, Swift sources, tests, product docs
- `apps/web`: static marketing site and user-facing docs
- `scripts`: root wrappers for build, test, coverage, release, and deploy workflows

## Documentation Map
- [`README.md`](../README.md): product overview and adoption pitch
- [`AGENTS.md`](../AGENTS.md): how coding agents should write, verify, and document changes
- [`docs/spec.md`](spec.md): expected product behavior and UX
- [`docs/implementation.md`](implementation.md): module boundaries, data model, and implementation rationale
- [`docs/terminal.md`](terminal.md): built-in terminal and libghostty integration notes, constraints, and verification guidance
- [`docs/design.md`](design.md): visual system and interaction patterns
- [`apps/web/app/docs`](../apps/web/app/docs): user-facing product and CLI documentation

## Requirements
- macOS 14+
- `yabai`
- Google Chrome
- Accessibility permission (handled via the in-app setup flow on first launch)

## macOS App and CLI

Run from the repository root:

```bash
scripts/format.sh
scripts/swiftpm.sh build
scripts/swiftpm.sh test --parallel
scripts/lint.sh
scripts/coverage.sh
scripts/verify.sh
```

`scripts/format.sh` performs an explicit tree-wide `swift format` pass across `apps/macos/Sources` and `apps/macos/Tests`.
`scripts/format-staged-swift.sh` formats staged macOS Swift source and test files in place and re-stages them.
`scripts/lint.sh` runs `scripts/format-staged-swift.sh` and then `SwiftLint` when `swiftlint` is available.
`scripts/coverage.sh` runs SwiftPM tests serially because several tests intentionally mutate process-wide environment variables while exercising profile-sensitive paths. Set `SPACES_TEST_PARALLEL=1` to opt into parallel coverage; auto-detected workers are capped at `8` unless you override it with `SPACES_TEST_WORKERS` or change the cap with `SPACES_TEST_MAX_AUTO_WORKERS`. When the debug CLI exists, coverage exports that CLI's repo-local profile before tests so profile-sensitive tests do not read the installed database. Coverage also points `XDG_CONFIG_HOME` at an empty build-local directory so Ghostty tests do not load a developer's personal Ghostty config.
`scripts/verify.sh` is the canonical sequential local verification path: staged formatting and lint, build, repo-local profile export, current-profile app and spacesd shutdown, coverage, then iOS unit tests. The profile shutdown is scoped to the repo-local profile so native Ghostty tests do not contend with a running debug app; set `SPACES_VERIFY_KEEP_PROFILE_RUNTIME=1` to leave that runtime running. The iOS unit pass prefers an available non-booted iPhone simulator so it does not attach to a simulator already owned by mobile E2E; set `SPACES_IOS_TEST_DESTINATION` to override the destination, or `SPACES_IOS_DERIVED_DATA` to override its DerivedData directory.
`scripts/swiftpm.sh` also uses a fail-fast lock around SwiftPM itself so overlapping build, test, or coverage commands stop immediately with a clear message instead of silently contending on the shared `.build` directory.

Useful local entry points:

```bash
apps/macos/.build/debug/SpacesApp
apps/macos/.build/debug/spaces --help
apps/macos/.build/debug/spacese2e --help
apps/macos/.build/debug/spaces import --title "debug" --notes "Local debug session"
apps/macos/.build/debug/spaces update --notes "Ready for review"
apps/macos/.build/debug/spaces restart
```

Use `scripts/dev-build-and-launch.sh` to launch the debug app without touching the installed app's database. Repo-local debug binaries derive a per-worktree profile automatically under `~/.spaces-dev/profiles/spaces/<branch-slug>-<worktree-hash>/`, and the script stops only the running app instance and spacesd daemon for that same profile before it relaunches.

For manual worktree-local shell sessions, export the same derived profile before launching the app, CLI, or E2E helper:

```bash
eval "$(apps/macos/.build/debug/spaces profile show --shell)"
apps/macos/.build/debug/SpacesApp
apps/macos/.build/debug/spaces terminal list
```

Override `SPACES_DB_PATH` when you need a one-off isolated profile root. Override `SPACES_RUNTIME_DIR` only when the runtime files themselves also need to move with that profile.

For branch-local Ghostty artifact setup, run:

```bash
apps/macos/scripts/setup_ghostty.sh
```

That installs `GhosttyKit.xcframework`, Ghostty resources, `libghostty-vt` headers, and `libghostty-vt` libraries under:
- `apps/macos/.local/ghosttykit/GhosttyKit.xcframework`
- `apps/macos/.local/ghosttykit/Resources`
- `apps/macos/.local/ghosttyvt/include`
- `apps/macos/.local/ghosttyvt/lib`

The Ghostty fork is tracked as the submodule at `apps/macos/vendor/ghostty`. The parent repo's submodule pointer is the single source of truth for the Ghostty commit used by both `GhosttyKit.xcframework` and `libghostty-vt`.
By default, `setup_ghostty.sh` reuses local artifacts only when `apps/macos/.local/ghostty-artifacts/manifest.json` matches the submodule SHA, setup script version, Zig version, and Xcode build version, and records a clean source build. Otherwise it downloads the Spaces-owned GitHub release named `ghostty-artifacts-<full-ghostty-sha>` and validates the same manifest fields before install. When the downloaded release artifact validates except for a different Xcode build, default setup leaves the download uninstalled and builds locally from the pinned submodule. The `--download-only` mode used by CI and publishing workflows is download-only and fails on an Xcode build mismatch.
The setup flow finishes by running `apps/macos/scripts/verify_ghosttykit.sh`, which checks that the artifact declares and exports the embedded terminal APIs that Spaces uses for raw I/O, host rebinding, session state callbacks, renderer attachment, headless session creation, render-frame export, and mirror renderer surfaces. Passive-viewer attachment exports are not part of the required contract.

When a Spaces branch depends on Ghostty fork work, edit and commit the fork change inside the submodule, push it to the fork's `spaces` branch, and update the parent repo's submodule pointer:

```bash
git -C apps/macos/vendor/ghostty status --short --branch
git -C apps/macos/vendor/ghostty push origin HEAD:spaces
git add apps/macos/vendor/ghostty
```

PR checks run `apps/macos/scripts/ensure_ghostty_artifacts.sh`, so existing `ghostty-artifacts-<sha>` releases are downloaded and validated before Swift verification starts. Same-repo PRs, manual PR-check runs, and pushes to `main` first run a non-cancelable trusted artifact publisher that builds from the pinned submodule and publishes a reusable release when the release is missing or incomplete for that build environment; verification waits for that publisher and then downloads the artifact. Fork PRs build missing artifacts locally without publishing, and the main-push publisher creates the reusable release after merge. Trusted publish runs repair incomplete artifact releases by rebuilding and uploading the full asset set. After the release is present, refresh local artifacts and run the normal verification pass:

```bash
git -C apps/macos/vendor/ghostty rev-parse HEAD
rm -rf apps/macos/.local/ghosttykit apps/macos/.local/ghosttyvt
apps/macos/scripts/setup_ghostty.sh
scripts/verify.sh
```

Spaces app releases run `apps/macos/scripts/ensure_ghostty_artifacts.sh --publish-missing`, so release builds consume a valid prebuilt artifact release when available and build plus publish from the pinned submodule when the release is absent. For uncommitted local Ghostty experiments, use `apps/macos/scripts/setup_ghostty.sh --build --allow-dirty`; the generated manifest records the dirty source state and must not be used for PR or release workflows.

To validate the real in-process Ghostty owner renderer path in `SpacesApp`, launch the app normally with an isolated database root:

```bash
apps/macos/scripts/setup_ghostty.sh --build --allow-dirty
export SPACES_DB_PATH="$TMPDIR/spaces-ghostty-owner/spaces.db"
mkdir -p "$(dirname "$SPACES_DB_PATH")"
pkill -x SpacesApp 2>/dev/null || true
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
```

When the app launches built-in Spaces terminals itself, `spacesd` owns the session and native owner windows attach through the service control socket. Use the normal app flows:
- Open a workspace terminal from the workspace detail pane.
- Launch a workspace process while the configured terminal host is `Spaces`.
- Launch a coding agent from the workspace detail pane.

Close one of those owner windows and reopen it from the app. Quit and relaunch `SpacesApp`, then reopen the same session from the app. The shell or long-running process should stay attached to the same service-owned Ghostty session without restarting.
CLI-created sessions such as `spaces terminal command` and CLI-managed `spaces start` use the same daemon-owned render-frame stream. The service publishes live Ghostty render frames to native client windows over the per-session subscription socket, while `output.log` remains the `spaces terminal tail` source.
For scripted real-system checks against the running app, `spacese2e` exposes `open-workspace-terminal`, `run-workspace-process`, and `launch-workspace-agent` so the manual harness can exercise the same app launch path without accessibility scripting.

To verify the embedded Ghostty backend on an isolated database root:

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-ghostty/spaces.db"
export SPACES_RUNTIME_DIR="$(dirname "$SPACES_DB_PATH")/runtime"
apps/macos/scripts/setup_ghostty.sh
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/SpacesApp
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  terminal command --backend ghostty-embedded --command cat --title verify-ghostty
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces terminal list
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  terminal send <session-id> "hello from ghostty" --newline
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  terminal tail <session-id> --lines 5
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  mobile status
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  terminal show <session-id>
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  terminal takeover <session-id> <other-client-id>
```

For built-in terminal verification, keep exactly one `SpacesApp` process running for the chosen profile root. The current `ghostty-embedded` slice keeps live Ghostty rendering owner-only on both macOS and iOS. Opening a terminal window or mobile detail view auto-attempts takeover, live non-owner states show takeover or status UI only, and ended sessions may still show the final Ghostty render when it was persisted.

For maintained simulator E2E coverage of the mobile terminal path:

```bash
apps/macos/Tests/e2e_mobile.sh
```

The mobile suite builds the macOS debug products once, builds the iOS app and UI tests once with `xcodebuild build-for-testing`, launches one daemon-backed simulator demo stack, and then runs the selected scenarios with `test-without-building` against that shared stack. Use `--list` to print scenarios, `--scenario <name>` to run one or more scenarios, `--keep-root` to preserve the shared demo root, and `--port <port>` to pin the daemon bridge port. The `ownership-guard` scenario covers the control-plane ownership checks: viewer input is rejected, takeover enables mobile input, Mac retakeover removes mobile ownership, and mobile input is rejected again. The `app-recovery` scenario kills only the current-profile `SpacesApp` owner, sends `launchSpacesApp` through the authenticated daemon bridge, and verifies the spacesd daemon PID and live session remain stable.

The daemon-hosted mobile bridge is the first-party seam for that proof of concept. Treat it as a paired Spaces-only bridge rather than a third-party external API surface. `spaces mobile serve` remains available when a harness needs a standalone bridge process with explicit host, port, or one-time pairing-window output; harness JSON calls go through `spaces mobile request` so local scripts use the same TLS-PSK transport as the iOS app. Standalone bridge processes reject daemon-only recovery commands such as `launchSpacesApp`.

Remote compute-host E2E coverage uses a reachable host running a matching `spacesd`. App-level remote E2E uses another Mac, a loopback remote profile that binds the remote listener on a separate profile root, or the Ubuntu 24.04 x86_64 daemon artifact published as `spacesd-ubuntu-24.04-x86_64.tar.gz`. Compute-host bootstrap, status, and test automation belongs in `spacese2e` so the product `spaces` CLI remains workspace-oriented. Use `upsert-compute-host` and `list-compute-hosts` to seed and inspect host records, `set-project-default-compute-host` and `set-workspace-compute-host-override` to exercise selection precedence, and `plan-workspace-runtime` to inspect the stable binding, daemon target, Remote SSH URI, and runtime manifest for a workspace.

Build the Linux daemon artifact from a Linux x86_64 environment:

```bash
docker run --rm --platform linux/amd64 \
  -v "$PWD":/workspace \
  -w /workspace \
  swift:6.2-noble \
  bash -lc 'apt-get update && apt-get install -y curl git xz-utils python3 pkg-config libsqlite3-dev libssl-dev openssl coreutils && apps/macos/scripts/build_linux_spacesd_artifact.sh'
```

The archive contains a `bin/spacesd` wrapper, the `spacesd-bin` executable, `libghostty-vt`, and the Swift runtime libraries needed on stock Ubuntu 24.04. Install it on the remote host by extracting the archive and putting its `bin` directory on the SSH PATH:

```bash
sudo tar -xzf spacesd-ubuntu-24.04-x86_64.tar.gz -C /opt
sudo ln -sfn /opt/spacesd-ubuntu-24.04-x86_64 /opt/spacesd
sudo ln -sfn /opt/spacesd/bin/spacesd /usr/local/bin/spacesd
```

For a real SSH smoke that exercises bootstrap, pinned-TLS status, runtime planning, remote terminal launch, and workspace stop through production orchestration:

```bash
eval "$(apps/macos/.build/debug/spaces profile show --shell)"
apps/macos/.build/debug/spacese2e remote-compute-host-smoke \
  --project-dir <local-git-project-dir> \
  --host-id lab-host \
  --ssh-host <ssh-host-or-alias> \
  --ssh-user <ssh-user> \
  --daemon-host <direct-daemon-ip-or-dns-name>
```

The command starts or reuses the remote daemon through `ComputeHostBootstrapper`, saves the host token for the current profile, sets the project default compute host, asserts the workspace resolves to the host, opens one remote ad hoc Spaces terminal, stops the workspace, and prints JSON with the host, bootstrap metadata, daemon status, runtime plan, terminal session ID, and stop outcome.

A remote daemon listener uses pinned TLS. Print the daemon certificate fingerprint with the same profile environment used to run the listener:

```bash
export SPACES_DB_PATH=/tmp/spaces-remote/spaces.db
export SPACES_RUNTIME_DIR=/tmp/spaces-remote/runtime
SPACESD_PRINT_CERTIFICATE_FINGERPRINT=1 <path-to-spacesd>
```

Start the remote listener with the configured private/LAN/VPN bind address and a shared token:

```bash
export SPACESD_LISTEN_HOST=0.0.0.0
export SPACESD_LISTEN_PORT=7443
export SPACESD_AUTH_TOKEN=<shared-token>
<path-to-spacesd>
```

Register that endpoint from the Mac-side profile. The host-specific token environment key is the uppercased compute host ID with non-alphanumeric characters replaced by `_`:

```bash
eval "$(apps/macos/.build/debug/spaces profile show --shell)"
export SPACESD_AUTH_TOKEN_LAB_MAC=<shared-token>
apps/macos/.build/debug/spacese2e upsert-compute-host \
  --id lab-mac \
  --name "Lab Mac" \
  --ssh-host <ssh-host> \
  --workspace-root /tmp/spaces-remote/workspaces \
  --daemon-host <remote-ip-or-dns-name> \
  --daemon-port 7443 \
  --certificate-fingerprint 'SHA256:<fingerprint-hex>'
```

The Mac-side host record can be created through the app. Open Remote Hosts from the sidebar, enter the SSH host and SSH user, optionally set a display name, and use Advanced only for SSH port or workspace folder overrides. The remote Mac must accept non-interactive SSH from the Mac and have `spacesd` discoverable on the SSH PATH. Connect resolves the SSH host, creates a stable remote profile under `~/.spaces/compute-hosts/<host-id>`, creates the workspace root, starts the remote listener with an internally selected port, stores the auth token in Keychain, saves the returned certificate fingerprint, and verifies the direct pinned-TLS endpoint before saving the host. Project settings can select the host as the project default, and workspace detail can select a workspace-specific override. Manual daemon host, daemon port, and certificate fingerprint fields are available only through `spacese2e` setup commands.

For focused terminal latency probes:

```bash
apps/macos/Tests/e2e_terminal_latency.sh --list
apps/macos/Tests/e2e_terminal_latency.sh --scenario mac-input-latency
apps/macos/Tests/e2e_terminal_latency.sh --scenario mac-scrollback-latency
apps/macos/Tests/e2e_terminal_latency.sh --scenario mac-scrollback-partial-latency
apps/macos/Tests/e2e_mobile_latency.sh --scenario ios-input-latency --network-profile local
apps/macos/Tests/e2e_mobile_latency.sh --scenario ios-input-latency --network-profile ios-constrained
apps/macos/Tests/e2e_mobile_latency.sh --scenario ios-scrollback-latency --network-profile local
apps/macos/Tests/e2e_mobile_latency.sh --scenario ios-scrollback-latency --network-profile ios-constrained
```

The latency scripts are fast performance iteration lanes rather than the canonical correctness gate. They write `terminal-latency-summary.json`, print p50, p95, max, per-sample timings, and render payload rates, fail input scenarios only on gross latency regressions or render-frame decode failures, and leave report-only targets visible in the terminal output. Input summaries include enqueue-to-RPC-begin, RPC duration, frame-apply or frame-publish timing, RPC-end-to-render-visible, and event-to-visible totals. Mac probes target the debug app by executable name; input totals are key-down-to-rendered-text, scroll totals are wheel-event-to-rendered-text-change with alternating directions across samples, and command-catchup totals use command-submit-to-visible output from one warmed shell session across samples. `mac-scrollback-latency` uses large scroll deltas and `mac-scrollback-partial-latency` uses smaller within-screen deltas. Mac summaries also split owner input activity to state change, state change to frame export, and frame export to mirror apply. Mobile summaries split host publish to relay read, relay read to network send begin, and network send begin to stream-visible. Scrollback summaries measure rendered text changes, no-op gesture counts, and render cadence as report-only metrics. The `ios-constrained` mobile profile shapes the standalone bridge with `80ms` RTT, `8Mbps` bandwidth, and `16KB` chunks unless `SPACES_MOBILE_BRIDGE_NETWORK_RTT_MS`, `SPACES_MOBILE_BRIDGE_NETWORK_BANDWIDTH_BPS`, or `SPACES_MOBILE_BRIDGE_NETWORK_CHUNK_BYTES` override those values.

For render-update profiling, run the latency scenario with a fixed sample count, terminal size, fixture command, target, and network profile. The scripts exercise the production v2 stream: full v2 updates for initial baselines and resyncs, plus delta updates with native scroll-rectangle operations for steady output and scrollback.

```bash
KEEP_ROOT=1 apps/macos/Tests/e2e_mobile_latency.sh --scenario ios-input-latency --network-profile local --samples 12
```

Summarize each preserved `mobile-terminal-performance.jsonl` or `terminal-performance.jsonl` with the latency summary JSON from the same work root. Render-update summaries report total selected payload bytes plus split fields for network send bytes, local publish/receive payload bytes, materialized render-update bytes, frame-kind byte totals, fallback reasons, and drop reasons:

```bash
apps/macos/Tests/render_update_profile_summary.py \
  --performance-log <work-root>/mobile-terminal-performance.jsonl \
  --summary-json <work-root>/terminal-latency-summary.json \
  --render-mode production \
  --sample-count 12 \
  --network-profile local \
  --target ios-input-latency
```

The summarizer copies the raw JSONL log and writes normalized JSON under `apps/macos/.artifacts/terminal-render-profiles/`, an ignored output directory. Each summary records git SHA, Ghostty submodule SHA, render mode, terminal size, sample and warmup counts, fixture command, network profile, target, timestamp, byte totals, average bytes per update, peak 1s and 10s bandwidth, frame mix, scrollRect delta byte totals, output-to-visible latency percentiles, encode/decode/apply CPU-proxy totals, and drop/resync/refresh counts.

For direct CLI verification of Spaces terminal commands:

```bash
apps/macos/Tests/e2e_terminal_cli_commands.sh
```

That script exercises `spaces terminal command`, `send`, `key`, `tail`, `show`, and both takeover directions against one isolated Spaces terminal session.

The Spaces terminal `tail` path also depends on the local `libghostty-vt` artifacts. Set them up before building or profiling terminal changes:

```bash
apps/macos/scripts/setup_ghostty.sh
```

The setup script installs Zig `0.15.2` under `apps/macos/.local/ghosttyvt/toolchain/` when a source build is requested. The fork keeps `main` mirrored from upstream, so the reviewable fork delta lives in the `spaces -> main` pull request.
For a browser view of fork drift against upstream, open [ghostty-org/ghostty compare view](https://github.com/ghostty-org/ghostty/compare/main...yogesh-dhande:ghostty:spaces).
The GitHub Actions PR and release workflows run this setup before the macOS build and coverage pass so clean runners have the matching `GhosttyKit`, `libghostty-vt` headers, and dylib available.

The terminal E2E, profiling, and soak scripts that launch `SpacesApp` acquire a shared harness lock before they run the Ghostty setup script or launch a new app instance. They stop only the app instance for their own profile. Hotkey-sensitive and real-system desktop-control workflows also wait for desktop-global control instead of killing unrelated running Spaces instances. When desktop control is already owned by another Spaces instance, the wait path also posts a macOS notification that asks you to close the running app when you are done with it.

For repeatable profiling of the built-in terminal owner and ownership-transfer flows:

```bash
ITERATIONS=3 apps/macos/Tests/profile_built_in_terminal.sh
```

The profiler runs against an isolated `SPACES_DB_PATH`, enables `DEBUG=1`, exercises owner attach, remote viewer attach, send, `tail`, and takeover, then summarizes the built-in terminal perf metrics captured from the app log.
It also writes `summary.txt` and `metrics.json` under its temp work root so baseline metric snapshots can be compared across terminal-window parity changes.

For repeatable profiling of the first-party iOS bridge and ownership transfer path:

```bash
apps/macos/Tests/profile_mobile_bridge.sh
```

That profiler runs against an isolated `SPACES_DB_PATH`, pairs a first-party iOS-shaped installation, attaches a local-window owner plus remote client, measures time-to-owner-render, ownership transfer to iOS, ownership transfer back to the macOS owner, and the streamed visibility latency for both iOS-side and macOS-side input.

For manual simulator verification of the iOS client:

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-ios-demo/spaces.db"
mkdir -p "$(dirname "$SPACES_DB_PATH")"
pkill -x SpacesApp 2>/dev/null || true
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces terminal command --backend ghostty-embedded --command cat --title ios-demo
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces mobile status
xcodebuild -project apps/ios/SpacesMobile.xcodeproj -scheme SpacesMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

On first launch, the iOS client opens its connection sheet. Open Mobile Connection in the Mac sidebar, open a pairing window, then scan the QR code or paste the full `spacesmobile://` link. The `run_mobile_terminal_demo.sh` harness opens one daemon pairing window per simulator and seeds both the iPad and iPhone simulator settings automatically. After pairing, the iOS client stores the issued credential and transport key and reconnects automatically on later launches. The client is terminal-only: it lists workspaces and live terminal sessions, auto-attempts takeover when a session detail is opened, renders service-published Ghostty render frames only after ownership is acquired, and shows takeover or status UI while another client still owns the session.
For the iOS simulator, a pairing link with `127.0.0.1` still works because the daemon bridge binds all IPv4 interfaces by default. A real device can scan the Mac QR code or open the deep link from the Mobile Connection panel. The iOS terminal detail path renders the owner-bootstrap Ghostty render frame through the same terminal-grid compatibility data as macOS, so the simulator should show a terminal-like view after takeover rather than a plain-text fallback.

For manual real-device verification of the iOS client:

1. Connect the iPhone or iPad to the Mac, unlock it, trust the Mac if prompted, and enable Developer Mode on the device if iOS asks.
2. Create a local `.env` from the tracked sample and set `SPACES_IOS_DEVICE_UDID` to the physical-device UDID printed by `xcrun xctrace list devices`. The `.env` file is ignored by git.

```bash
cp .env.sample .env
xcrun xctrace list devices
$EDITOR .env
```

3. Run the device installer. It builds `SpacesMobile`, installs it on the configured device, and attempts to launch it; if the device is locked, unlock it and tap SpacesMobile or rerun the script.

```bash
scripts/install-ios-device.sh
```

4. If Xcode reports that `dev.usespaces.spacesmobile` cannot be signed by the selected team, stop there and widen the first-party bundle policy before changing the bundle identifier. The current bridge accepts only that bundle identifier for pairing and reconnect. Set `SPACES_IOS_DEVELOPMENT_TEAM` in `.env` when the command-line build should override the project signing team.
5. Keep the Mac app and mobile bridge on the same `SPACES_DB_PATH`; the daemon bridge binds all IPv4 interfaces on port `47847` by default and persists a profile-specific fallback port if that port is already occupied.

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-ios-demo/spaces.db"
mkdir -p "$(dirname "$SPACES_DB_PATH")"
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces terminal command --backend ghostty-embedded --command cat --title ios-demo
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces mobile status
```

6. On the Mac, allow the incoming-network prompt if macOS shows one. In the Mac app, open Mobile Connection, open a pairing window, and scan the QR code or send the full pairing link to the device.
7. The first connection attempt should trigger the iOS local-network permission prompt; accept it so the app can reach the Mac bridge.

For a disposable one-command demo stack that launches the macOS app, uses the daemon-hosted mobile bridge, pairs both the iPad and iPhone simulators, and opens the mobile app on each:

```bash
apps/macos/Tests/run_mobile_terminal_demo.sh
```

The launcher expects the local Ghostty artifacts under `apps/macos/.local/ghosttykit/`. It builds the repo-local macOS debug products, builds a fresh simulator `SpacesMobile.app` into a DerivedData directory under the demo root, then installs that same app bundle on both the iPad and iPhone simulators. Demo runs use the current user's `HOME` and `XDG_CONFIG_HOME` so Ghostty themes and user settings match normal local debugging. By default, the demo uses isolated Spaces profile mode, which keeps the database and runtime under the demo root without moving user-level settings into a temporary home. Use `SPACES_MOBILE_DEMO_PROFILE_MODE=user` when the demo should attach to the repo-local Spaces profile instead. The launcher provisions two live Mac-owned workspace terminal sessions and waits for their owner attachments before launching the mobile clients so list-navigation and second-session takeover flows can be reproduced without exposing not-yet-owned sessions to iOS. It refuses to start if another `SpacesApp` instance or bridge listener is already running so the global hotkey and mobile port stay unambiguous, then reads the daemon bridge details through `spaces mobile status`. It prints the demo root, profile mode, PIDs, logs, screenshots, both terminal session IDs, the iOS app path, iOS build paths, and the simulator app stdout or stderr log paths as JSON, keeps the stack alive until `Ctrl+C`, and then tears the demo down cleanly.
The same demo root also contains `mobile-terminal-performance.jsonl`, and the printed JSON includes its `performanceLogPath`. The mobile E2E suite consumes that file directly when it asserts one bootstrap epoch, first render timing, input-ready timing, and scrollback behavior.

Useful overrides:
- `SPACES_MOBILE_DEMO_KEEP_ROOT=1` keeps the demo root after shutdown for log inspection.
- `SPACES_MOBILE_DEMO_PROFILE_MODE=isolated|user` selects the Spaces profile mode; demo and E2E runs default to isolated database/runtime paths.
- `SPACES_MOBILE_DEMO_ROOT_PARENT=...` changes the parent directory for demo roots; the default is `~/.spaces-dev/mobile-demo`.
- `SPACES_MOBILE_DEMO_BUILD_MACOS=0` skips the scripted macOS debug build when the existing repo-local binaries should be used.
- `SPACES_MOBILE_DEMO_IPAD_NAME=...` and `SPACES_MOBILE_DEMO_IPHONE_NAME=...` target different simulator names when the defaults are unavailable.
- `SPACES_MOBILE_DEMO_APP_PATH=...` skips the scripted `xcodebuild` and installs an explicit `SpacesMobile.app` bundle.
- `SPACES_MOBILE_DEMO_PORT=...` sets the daemon bridge port for the demo profile.
- `SPACES_MOBILE_E2E_DEVICE_KEY=iphone|ipad` and `SPACES_MOBILE_E2E_DEVICE_NAME=...` select the simulator used by `e2e_mobile.sh`; the default E2E target is `iPhone 17 Pro`.

For targeted mobile E2E runs, use `--scenario`:

```bash
apps/macos/Tests/e2e_mobile.sh --scenario codex
apps/macos/Tests/e2e_mobile.sh --scenario codex-resume-reopen
apps/macos/Tests/e2e_mobile.sh --scenario roundtrip
apps/macos/Tests/e2e_mobile.sh --scenario scrollback
apps/macos/Tests/e2e_mobile.sh --scenario two-session
apps/macos/Tests/e2e_mobile.sh --scenario ctrl-c-final-frame
apps/macos/Tests/e2e_mobile.sh --scenario ctrl-c-final-frame-codex-survivor
apps/macos/Tests/e2e_mobile.sh --scenario ownership-guard
apps/macos/Tests/e2e_mobile.sh --scenario app-recovery
```

`codex` starts real Codex in a fresh Mac-owned terminal session and verifies iPhone takeover against the already-running simulator app. Codex scenarios build a generated Codex home inside the demo root by copying the current user's config, linking signed-in auth files, and marking the demo project trusted so the test exercises the TUI instead of the directory-trust prompt. If Codex shows its startup update prompt, the harness selects `Skip` and continues waiting for the TUI. `codex-resume-reopen` runs `codex resume 019e380a-9def-7852-9834-74c67b2da894`, takes over on iPhone, returns to the terminal list, and repeatedly reopens the same session. `roundtrip` drives the Mac/iPhone/Mac/iPhone/Mac ownership path with rendered-content assertions at each handoff. `scrollback` fills the Mac-owned terminal with long output, transfers ownership to iPhone, scrolls away from bottom, runs an owner command while still scrolled up, and checks the owner epoch and prompt rendering. `two-session` takes over two fresh terminal sessions through list navigation. `ctrl-c-final-frame` creates `interrupt-target` and `survivor-peer` process-style sessions, sends `ctrl+c` to `interrupt-target` from the iOS owner path, checks the persisted final Ghostty frame on iOS and Mac, and verifies the `survivor-peer` session remains running. `ctrl-c-final-frame-codex-survivor` uses the same interrupt path with a real Codex TUI as the survivor session. `ownership-guard` exercises the mobile bridge ownership rules without UI automation. `app-recovery` exercises iOS-to-daemon Mac app recovery without UI automation by keeping the service and session alive while replacing the profile app-owner process.

Useful overrides:
- `SPACES_MOBILE_CODEX_COMMAND='codex resume <thread-id>'` replaces the default `codex` startup command for the `codex` scenario.
- `SPACES_MOBILE_CODEX_RESUME_THREAD_ID=<thread-id>` changes the thread used by `codex-resume-reopen`.
- `SPACES_MOBILE_CODEX_HOME=<path>` changes the source Codex home used by Codex scenarios; by default they use the current user's `CODEX_HOME` or `~/.codex`. The harness creates a demo-local Codex home from that source so signed-in Codex runs the real TUI without mutating the user's config.
- `SPACES_MOBILE_GHOSTTY_XDG_CONFIG_HOME=<path>` changes the source Ghostty XDG config root used by the mobile E2E harness; by default it uses the current user's `XDG_CONFIG_HOME` or `~/.config`.

When debugging mobile owner render dumps, keep terminal UI rendering frame-based. `GhosttyRemoteTerminalView` must not render from raw output bytes, must not call local session export APIs to reconstruct another owner, mobile owner bootstrap must use the service-published live Ghostty render frame, and macOS owner attach or takeover must use the same service-published frame policy. Do not use VT replay, snapshot-to-VT encoding, raw output, or `output.log` as a terminal-rendering fallback. Use the bootstrap frame, screenshots, event logs, and rendered-content dumps for E2E assertions.

For sustained throughput, repaint-heavy output, tail latency, and scrollback completeness on the built-in terminal path:

```bash
apps/macos/Tests/profile_built_in_terminal_stress.sh
```

That profiler runs four isolated scenarios against the embedded Ghostty backend:
- `lines`: high-volume append-only output
- `repaint`: full-screen ANSI clears and redraws
- `mixed`: status repaints plus ordered line emission
- `codex_churn`: long scrollback history plus Codex-style prompt, transcript, spinner, footer rewrite, cursor-move, and redraw churn

`codex_churn` is the primary large-churn regression scenario for the built-in terminal path. Each scenario verifies ordered `SEQ` markers in `output.log`, checks the final frame and final `tail` view, records repeated `spaces terminal tail` wall times, samples output-log growth during the run, and summarizes terminal metrics such as:
- `terminal_output_write`
- `terminal_surface_refresh`
- `terminal_tail_read`

The stress summary prints per-scenario `tail_min`, `tail_median`, `tail_avg`, `tail_p95`, and `tail_max` values so one slow sample does not hide the typical case.
It also prints output-growth summaries from the sampled `output.log` sizes so redraw-heavy regressions show whether tail latency is drifting while the transcript is still growing.
It also records CLI-side tail metrics for each scenario:
- `terminal_tail_read`
- `terminal_tail_command`

Those CLI metrics make it easier to distinguish the internal tail implementation cost from the full `spaces terminal tail` wall time.

For longer-running stability sampling of the same built-in terminal path:

```bash
DURATION_SECONDS=300 apps/macos/Tests/soak_built_in_terminal.sh
```

That soak harness supports `SOAK_MODE=repaint`, `SOAK_MODE=mixed`, and `SOAK_MODE=codex_churn` with `SOAK_MODE=codex` kept as an alias. The Codex-style mode adds a large initial scrollback history before the steady redraw workload so late-phase transcript pressure looks closer to real long-running Codex sessions.
The soak summary samples `SpacesApp` RSS, CPU, output growth, and `terminal tail` latency at a fixed interval, reports early-vs-late tail drift, verifies that the emitted sequence numbers and final frame stayed complete, and confirms that the final `spaces terminal tail` output still shows the terminal footer and expected last frame after the long run.

For repeatable profiling of the app-triggered built-in workspace-terminal open path:

```bash
ITERATIONS=3 apps/macos/Tests/profile_workspace_terminal_open.sh
```

That profiler seeds an isolated fixture workspace, triggers the app-side workspace-terminal open route through the manual E2E IPC helper, and summarizes:
- `workspace_terminal_open_wall`
- `workspace_terminal_open_ui`
- `terminal_session_wait_ready`
- `terminal_window_summon`

For real-system verification of live terminal edit and find shortcuts:

```bash
apps/macos/Tests/e2e_terminal_edit_shortcuts.sh
```

That harness runs the debug app against an isolated `SPACES_DB_PATH`, opens a `cat` session, verifies `Cmd+V` through `spaces terminal tail`, verifies mouse selection plus `Cmd+C` through `pbpaste`, and verifies `Cmd+F`, `Cmd+G`, `Cmd+Shift+G`, and `Esc` through the terminal-window debug dump. It requires the same Accessibility permissions as the other desktop-control E2E scripts.

For repeatable profiling of the built-in `Spaces terminal -> main window -> tracked process terminal` hotkey loop:

```bash
ITERATIONS=3 apps/macos/Tests/profile_spaces_terminal_hotkeys.sh
```

That profiler runs against an isolated `SPACES_DB_PATH`, enables `DEBUG=1`, focuses a tracked built-in process terminal, repeatedly toggles back to the main window with `Cmd+Opt+=`, then refocuses the tracked terminal through the normal workspace-process path while summarizing:
- `terminal_to_main_toggle_wall`
- `main_to_terminal_toggle_wall`
- `toggle_window_show`
- `toggle_window_hide`
- `toggle_window_return_terminal_focus`
- `toggle_window_reveal_target`
- `toggle_window_terminal_workspace_lookup`
- `toggle_window_selection_refresh`

For repeatable profiling of the built-in `Spaces terminal -> command palette -> tracked process terminal` hotkey loop:

```bash
ITERATIONS=3 apps/macos/Tests/profile_spaces_terminal_palette.sh
```

That profiler runs against an isolated `SPACES_DB_PATH`, enables `DEBUG=1`, focuses a tracked built-in process terminal, repeatedly opens the command palette with `Cmd+Opt+-`, then dismisses it and refocuses the tracked terminal through the normal workspace-process path while summarizing:
- `terminal_to_palette_toggle_wall`
- `toggle_palette`
- `toggle_palette_terminal_workspace_lookup`
- `toggle_palette_context_workspace`
- `toggle_palette_reveal_target`
- `toggle_palette_apply_filter`

For workspace-process profiling, use:

```bash
apps/macos/Tests/profile_workspace_process_terminal.sh
```

That profiler waits for the built-in session summon metric instead of sleeping a fixed second after refocus, so the reported close or reopen timings track the actual app-side window path more closely.

## Pre-commit Hook

Git commits can use the repo hook in `.githooks/pre-commit`, which runs the canonical local verification path.

Enable the repo-managed hooks once per clone:

```bash
git config core.hooksPath .githooks
```

Verify the setting:

```bash
git config --get core.hooksPath
```

Expected output:

```text
.githooks
```

The pre-commit hook runs `scripts/verify.sh`, which formats staged macOS Swift source and test files, lints, builds, runs coverage, and runs iOS unit tests.

Pull requests are checked in GitHub Actions with [`.github/workflows/pr-checks.yml`](../.github/workflows/pr-checks.yml), which runs the same Swift verification flow plus the static website build.

## Manual E2E

Run the real-system GUI/CLI suite from the repository root with:

```bash
apps/macos/Tests/e2e_macos_app.sh
```

Before the suite launches its isolated app instance, it waits for desktop-global control. A timeout from that wait is an environment-contention result and should be retried without killing unrelated running Spaces instances.

To capture a product-demo video from the same suite, record the run with the native `ScreenCaptureKit` helper and optionally add short editing-friendly pauses between visible transitions:

```bash
apps/macos/Tests/e2e_macos_app.sh \
  --record-video /tmp/spaces-real-e2e.mp4 \
  --pause-transitions
```

The recorder follows the current main display. `--capture-device` remains accepted as a no-op compatibility flag for older invocations.

To prepare the same fixture projects, localhost browser-session servers, and workspace records for manual exploration without running the assertions, use:

```bash
apps/macos/Tests/e2e_macos_app.sh --setup-fixtures-only
```

This suite is manual by design. It drives the real app, `spaces`, `yabai`, Chrome, and the built-in Spaces terminal in an interactive macOS session instead of XCTest.

Primary coverage:
- adding and archiving a workspace
- overriding workspace settings after creation
- launch, stop, restart, and dead-process recovery
- built-in Spaces terminal coverage
- extra user-added Chrome and terminal tabs
- workspace-detail numbered focus shortcuts
- forward/back workspace window cycling
- multi-workspace focus and cycling isolation

The suite emits performance metrics in milliseconds for the main window-focus and cycle paths, using the app's debug timing logs for the same shortcut and cycling flows covered by the standalone focus-profiling workflow. The final summary prints both the pass/fail case list and the collected timing samples, so this suite is the primary path for focus profiling during development.

Repeated real-system profiling also covers:
- main window visibility toggles from inactive and active app states
- command palette toggles from inactive and active app states
- built-in `Spaces terminal -> main window -> tracked process terminal` focus loops
- built-in `Spaces terminal -> command palette -> tracked process terminal` focus loops

When the suite finishes with recorded metrics, it appends aggregated metric history to `apps/macos/.artifacts/real-system-profiles/metrics-history.csv` and regenerates `apps/macos/.artifacts/real-system-profiles/report.html` with `best`, `previous`, and `latest` comparisons for each tracked metric. Metric names use `start.action.end`, such as `browser_untracked_tab.cli_window_focus.browser_tracked_tab`, and the start and end tokens refer to concrete visible surfaces rather than app-level state. Scenario context like workspace scope is stored alongside each row. Dirty worktrees are recorded alongside clean runs by pairing the base `HEAD` commit with a worktree fingerprint, so the report can distinguish two different uncommitted snapshots on the same branch.

The manual suite depends on a small set of debug-log lines from the app and CLI helpers. Treat these as test contracts when changing debug logging:
- `spaces: perf metric=...`
- `spaces: workspace_detail_ipc selecting ...` / `selected ...`
- `spaces: workspace_run_view workspace=... selected=... agents=... coding_entries=...`

## Website

Run from `apps/web`:

```bash
npm run dev
npm run build
```

## macOS Release

Publish macOS releases to GitHub Releases with:

```bash
scripts/release-and-deploy.sh <version> [build-number]
```

This workflow:
- syncs the checked-in version metadata used by the CLI, app menu, and bundle plist
- builds universal `arm64` + `x86_64` release binaries for the app, CLI, and `spacesd`
- code-signs the app, CLI, and spacesd daemon
- creates a signed manual-download DMG
- creates a Sparkle-served `Spaces.app` zip archive
- updates `dist/updates/stable/appcast.xml` plus any Sparkle delta files
- stages the Sparkle feed and Sparkle archives into `apps/web/public/releases`
- builds the static site so Firebase can serve `https://usespaces.dev/releases/*`
- optionally notarizes the DMG when `NOTARIZE=1`
- verifies the final DMG signature plus the bundled installer, app, CLI, and spacesd daemon before publish
- publishes the DMG to GitHub Releases

Important environment variables:
- `CODESIGN_IDENTITY`
- `CODESIGN_CERTIFICATE_P12`
- `CODESIGN_CERTIFICATE_PASSWORD`
- `SPARKLE_PUBLIC_ED_KEY`
- `SPARKLE_PRIVATE_ED_KEY`
- `SPARKLE_FEED_URL`
- `SPARKLE_DOWNLOAD_URL_PREFIX`
- `NOTARIZE`
- `APPLE_ID`
- `TEAM_ID`
- `APP_PASSWORD`
- `GH_TOKEN`

For GitHub Actions releases, `CODESIGN_CERTIFICATE_P12` must be the base64-encoded Developer ID Application `.p12` bundle that matches `CODESIGN_IDENTITY`, and `CODESIGN_CERTIFICATE_PASSWORD` must be the password used when exporting that `.p12`.

Sparkle update hosting lives under `https://usespaces.dev/releases/` on the static Firebase site. The update feed and Sparkle archives are staged into `apps/web/public/releases`, which Next.js exports as real static files before Firebase deploy. The release pipeline keeps a single DMG, a single Sparkle zip, and one stable `appcast.xml`, all backed by those universal binaries. The app bundle carries `spaces` and `spacesd` in `Contents/Resources`; the DMG installer also copies both executables to the selected CLI install directory so installed CLI commands can start the spacesd daemon without extra environment variables.

## Website Deploy

Firebase Hosting deploys from [`.github/workflows/firebase-hosting-merge.yml`](../.github/workflows/firebase-hosting-merge.yml). It builds `apps/web` and deploys the static export on pushes to `main` that touch the site or on manual dispatch.

The workflow authenticates with GitHub OIDC through Google Workload Identity Federation, then deploys through the Firebase Hosting REST API. This avoids `firebase-tools` service-account-key assumptions while keeping the deploy keyless.

Required GitHub secrets:
- `FIREBASE_PROJECT_ID`
- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_SERVICE_ACCOUNT_EMAIL`
