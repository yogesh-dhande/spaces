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
- Google Chrome

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
`scripts/coverage.sh` runs SwiftPM tests in parallel. Process-wide environment mutations stay isolated because XCTest cases run in separate processes and the few Swift Testing suites that override `SPACES_DB_PATH` are serialized. Set `SPACES_TEST_PARALLEL=0` to force a serial run when debugging a contention issue; auto-detected workers are capped at `8` unless you override it with `SPACES_TEST_WORKERS` or change the cap with `SPACES_TEST_MAX_AUTO_WORKERS`. When the debug CLI exists, coverage exports that CLI's repo-local profile before tests so profile-sensitive tests do not read the installed database. Coverage also points `XDG_CONFIG_HOME` at an empty build-local directory so Ghostty tests do not load a developer's personal Ghostty config.
`scripts/verify.sh` is the canonical sequential local verification path: staged formatting and lint, build, repo-local profile export, current-profile app and spacesd shutdown, coverage, then iOS unit tests. The profile shutdown is scoped to the repo-local profile so native Ghostty tests do not contend with a running debug app; set `SPACES_VERIFY_KEEP_PROFILE_RUNTIME=1` to leave that runtime running. The iOS unit pass prefers an available non-booted iPhone simulator so it does not attach to a simulator already owned by mobile E2E, and the generated destination includes the host simulator architecture so Xcode resolves one concrete simulator target; set `SPACES_IOS_TEST_DESTINATION` to override the destination, or `SPACES_IOS_DERIVED_DATA` to override its DerivedData directory. A watchdog force-kills the whole run and exits non-zero if it exceeds `SPACES_VERIFY_TIMEOUT_SECONDS` (default 900), so a hung or deadlocked test fails the gate fast instead of blocking a commit indefinitely; set it to `0` to disable the ceiling (for example when attaching a debugger).
`scripts/swiftpm.sh` also uses a fail-fast lock around SwiftPM itself so overlapping build, test, or coverage commands stop immediately with a clear message instead of silently contending on the shared `.build` directory.

Useful local entry points:

```bash
apps/macos/.build/debug/SpacesApp
apps/macos/.build/debug/spaces --help
apps/macos/.build/debug/spacese2e --help
apps/macos/.build/debug/spaces project list
apps/macos/.build/debug/spaces workspace create --project <project-id> --branch debug
apps/macos/.build/debug/spaces workspace restart --workspace <workspace-id>
```

Use `scripts/dev-build-and-launch.sh` to launch the debug app without touching the installed app's database. The script prepares Ghostty artifacts before invoking SwiftPM; in Git worktrees it derives the primary checkout from `.git` metadata when `SPACES_GHOSTTY_CACHE_DIR` is unset, so branch worktrees restore prebuilt artifacts from the shared cache. Repo-local debug binaries derive a per-worktree profile automatically under `~/.spaces-dev/profiles/spaces/<branch-slug>-<worktree-hash>/`, and the script stops only that profile's running app instance before it relaunches; the profile's spacesd is stopped only when it owns no sessions, so live terminal sessions and workspace processes survive the relaunch and the app reattaches to them. When sessions are preserved, the running daemon may be an older build; replace it through the app's daemon-restart prompt, which warns about the sessions it would stop. When the repo `.env` configures `SPACES_E2E_REMOTE_SSH_HOST`, the script builds or reuses the current-checkout Ubuntu artifact, uploads it, installs it into the remote account's `~/.spaces` daemon, waits for the configured Device API port, and then relaunches the local app; pass `--local` to skip the remote deploy and only build and relaunch locally.

For manual worktree-local shell sessions, export the same derived profile before launching the app, CLI, or E2E helper:

```bash
eval "$(apps/macos/.build/debug/spacese2e profile-show --shell)"
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

`GhosttyKit.xcframework` includes a universal macOS slice, an `arm64` iOS device slice, and an `arm64` + `x86_64` iOS simulator slice so simulator verification works on Apple Silicon and Intel hosts.

Artifact validation requires the platform dynamic `libghostty-vt` runtime library (`libghostty-vt.dylib` on macOS, `libghostty-vt.so` on Linux). A static `libghostty-vt.a` alone is not a complete install because terminal transcript rendering loads the dynamic library at runtime.

The service router also needs a bundled Caddy binary. For branch-local setup, run:

```bash
apps/macos/scripts/setup_caddy.sh
```

That fetches a pinned universal Caddy binary into `apps/macos/.local/caddy/caddy`, mirroring `setup_ghostty.sh`. Standard app packaging invokes the same setup script before bundling Caddy into the app at `Contents/Resources/caddy`; DMG installs link `/usr/local/bin/spaces-caddy` to that bundled resource so launchd-started `spacesd` can run the local reverse proxy for workspace services without replacing a user-managed `caddy` executable.

The Ghostty fork is tracked as the submodule at `apps/macos/vendor/ghostty`. The parent repo's submodule pointer is the single source of truth for the Ghostty commit used by both `GhosttyKit.xcframework` and `libghostty-vt`.
By default, `setup_ghostty.sh` reuses local artifacts only when `apps/macos/.local/ghostty-artifacts/manifest.json` matches the submodule SHA, setup script version, Zig version, and Xcode build version, and records a clean source build. When the worktree-local artifacts do not match, default setup next checks a shared, content-addressed cache and restores from it with a local copy before falling back to a download. Otherwise it downloads the Spaces-owned GitHub release named `ghostty-artifacts-<full-ghostty-sha>` and validates the same manifest fields before install. When the downloaded release artifact validates except for a different Xcode build, default setup leaves the download uninstalled and builds locally from the pinned submodule. The `--download-only` mode used by CI and publishing workflows is download-only and fails on an Xcode build mismatch.

Local Ghostty source builds require Xcode's Metal Toolchain component because Ghostty compiles Metal shaders into the framework artifacts. Install the component with `xcodebuild -downloadComponent MetalToolchain`. If Xcode reports that first-launch packages need authorization, run `sudo xcodebuild -runFirstLaunch` first, then retry the Metal Toolchain install.

The shared cache lives at `$SPACES_GHOSTTY_CACHE_DIR` (default `apps/macos/.local/ghostty-cache`), keyed by `<ghostty-sha>/<xcode-build>-<arch>-<build-optimize>`. Each entry mirrors the installed `ghosttykit`, `ghosttyvt/include`, `ghosttyvt/lib`, and `ghostty-artifacts` trees (the Zig toolchain is not cached) and is validated against the same manifest fields before a restore. Every successful clean setup seeds the cache, so a worktree on a SHA the main checkout already built restores by local copy instead of redownloading or rebuilding. Worktree setup (`spaces.yaml`) points `SPACES_GHOSTTY_CACHE_DIR` at the main checkout (`$SPACES_PROJECT_DIR/apps/macos/.local/ghostty-cache`) so all worktrees share one store. Dirty builds (`--build --allow-dirty`) stay local to their worktree and are never written to the shared cache.
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
rm -rf apps/macos/.local/ghosttykit apps/macos/.local/ghosttyvt apps/macos/.local/ghostty-cache
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
CLI-created sessions such as `spaces terminal command` and CLI-managed `spaces workspace start --workspace <id>` use the same daemon-owned render-frame stream. The service publishes live Ghostty render frames to native client windows over the per-session subscription socket, while `output.log` remains the `spaces terminal tail` source.
For scripted real-system checks against the running app, `spacese2e` exposes `open-workspace-terminal`, `run-workspace-process`, and `launch-workspace-agent` so the manual harness can exercise the same app launch path without accessibility scripting.

To verify the embedded Ghostty backend on an isolated database root:

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-ghostty/spaces.db"
export SPACES_RUNTIME_DIR="$(dirname "$SPACES_DB_PATH")/runtime"
apps/macos/scripts/setup_ghostty.sh
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/SpacesApp
mkdir -p "$TMPDIR/spaces-ghostty/workspace"
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spacese2e \
  register-project --project-dir "$TMPDIR/spaces-ghostty/workspace" >/dev/null
spaces_cli="$(cd apps/macos/.build/debug && pwd)/spaces"
(cd "$TMPDIR/spaces-ghostty/workspace" && env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" "$spaces_cli" \
  terminal command --command cat --title verify-ghostty)
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces terminal list
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  terminal send <session-id> "hello from ghostty" --newline
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  terminal tail <session-id> --lines 5
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spacese2e \
  mobile-status
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  terminal show <session-id>
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  terminal takeover <session-id> <other-client-id>
```

For built-in terminal verification, keep exactly one `SpacesApp` process running for the chosen profile root. The current `ghostty-embedded` slice keeps live Ghostty rendering owner-only on both macOS and iOS. Opening a terminal window or mobile detail view auto-attempts takeover, live non-owner states show takeover or status UI only, and ended sessions may still show the final Ghostty render when it was persisted.

If Ghostty owner or mirror setup reports `ghostty_session_new_headless failed` or `ghostty_mirror_new failed`, inspect for stale debug daemons before rerunning. Stop only current-worktree or preserved E2E-profile processes: use `pgrep -af 'SpacesApp|spacesd|spacese2e|xcodebuild|e2e|mobile-demo'`, confirm each candidate with `ps eww -p <pid> -o pid,ppid,command`, and kill only processes whose executable and `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR` belong to the current checkout or a preserved E2E run root. Leave other worktree profiles running.

For maintained simulator E2E coverage of the mobile terminal path:

```bash
apps/macos/Tests/e2e.sh mobile
```

The mobile lane builds the macOS debug products once, builds the iOS app and UI tests once with `xcodebuild build-for-testing`, launches one daemon-backed simulator demo stack with local Beacon and Scout workspaces, and then runs selected scenarios against that stack. Use `--list` to print scenarios, `--scenario <name>` to run one or more scenarios, and `--keep-root` to preserve the shared demo root. The `ownership-guard` scenario covers the control-plane ownership checks: viewer input is rejected, takeover enables mobile input, Mac retakeover removes mobile ownership, and mobile input is rejected again.

The E2E helpers source the worktree `.env` (gitignored, at the repo root) via `scripts/spaces-e2e-env.sh` when it exists. Local-only scenarios run without `.env`; remote-host lanes require it. A working remote test host is configured in the primary checkout's `.env`; a fresh worktree has none, so copy it in to run remote lanes from that worktree:

```bash
cp ~/projects/spaces/.env .env
```

The remote keys it provides are `SPACES_E2E_REMOTE_SSH_HOST`, `SPACES_E2E_REMOTE_SSH_USER`, `SPACES_E2E_REMOTE_DAEMON_HOST`, `SPACES_E2E_REMOTE_DAEMON_PORT`, `SPACES_E2E_REMOTE_WORKSPACE_ROOT`, `SPACES_E2E_REMOTE_GIT_ROOT`, `SPACES_E2E_REMOTE_HOST_ID`, `SPACES_E2E_REMOTE_NAME`, and `SPACES_E2E_REMOTE_AUTH_TOKEN`. They drive the remote Device API lanes (`apps/macos/Tests/e2e.sh device-api remote` / `latency-compare`) and the Linux daemon deploy/cleanup scripts. Never commit `.env`.

Each `apps/macos/Tests/e2e.sh` invocation writes an ignored Markdown report under `apps/macos/.artifacts/e2e-runs/<timestamp>-<lane>/summary.md`. The run directory stores collected metric artifacts as flat step-prefixed files alongside the report. The report includes the command timeline, per-case timing table, per-step logs, flattened tables for collected JSON metrics and result files, TSV tables for app metric/result logs, and links to raw JSONL performance logs.

`apps/macos/Tests/e2e.sh all` is the shared-setup smoke lane for app, terminal, mobile, and paired-device coverage. `apps/macos/Tests/e2e.sh exhaustive` is the full manual lane: app full coverage, every terminal scenario, every mobile scenario, local and constrained iOS latency profiles, local and remote Device API parity, and Device API profiling.

Mobile terminal latency sweeps target the local paired daemon over the Device API; remote terminal latency runs through the paired-device parity harness instead of a separate direct-daemon channel.

The daemon-hosted Device API is a paired Spaces-only transport rather than a third-party external API surface. `spacese2e mobile-serve` is available when a harness needs a standalone Device API process with explicit host, port, or one-time pairing-window output; harness JSON calls go through `spacese2e mobile-request` so local scripts use the same pinned-TLS transport as the iOS app.

`apps/macos/Tests/e2e_remote_terminal_send.sh` verifies the orchestrator agent path end to end against the configured remote host: it pairs the CLI over SSH with `spaces device pair`, creates a remote terminal session, and drives it from the Mac with `spaces terminal list/send/tail --device`, using an isolated client database and secret directory. The remote daemon must be on the same wire-protocol version as the local build (redeploy with `apps/macos/scripts/deploy_linux_spacesd_e2e.sh` first).

Focused paired-device parity checks use one shared Device API flow for local and remote daemons:

```bash
apps/macos/Tests/e2e.sh device-api local
apps/macos/Tests/e2e.sh device-api remote
```

Both targets create a project and workspace through the paired daemon, open and stop a workspace terminal, run/restart/stop a configured process, and run/restart/stop a configured coding agent. During the terminal portion, the parity flow writes `terminal-latency-summary.json` with open-terminal request timing, state-readiness timing, send-to-state-progress samples, state request timing, and state progress counters. The remote target installs its test daemon against an isolated remote E2E database/runtime root, relies on the Linux installer enabling user lingering, and verifies the daemon remains reachable from the Mac after the setup SSH command exits; it does not keep a persistent SSH session open for service lifetime. `apps/macos/Tests/e2e.sh device-api` runs local and remote parity.

Focused remote terminal latency comparisons use the configured `.env` remote host, create one remote Device API workspace, and compare Device API workspace-terminal latency against a local Spaces terminal that SSHes into the same remote workspace directory:

```bash
apps/macos/Tests/e2e.sh device-api latency-compare --samples 12 --keep-root
```

The comparison writes `remote-terminal-latency-compare-summary.json` with Mac- and iOS-labeled input echo, command output, and scrollback scenarios. Each scenario reports p50/p95/max event-to-visible timings for `remote-workspace` over `device-api-request-session+subscribe` and `local-workspace-ssh` over the local terminal subscription socket, plus p95 delta and ratio. Input and command-output probes wait for decoded render text markers that are not present in the typed command, so local PTY echo does not satisfy remote-output measurements. Scrollback probes create a deterministic large scrollback fixture, verify that repeated scroll controls can reach top and bottom sentinels, wait for the setup output stream to go idle, and then require a decoded stream payload with `reason=scroll`, so pending command output does not satisfy scroll measurements. The summary includes all-sample and steady-state timings, control-request and response-to-stream phase summaries, request-session write/response/decode splits, local socket splits, stream emitted-to-received wall-clock estimates, grouped remote daemon performance events, per-scenario remote event groups, derived same-host timeline deltas such as send-control-to-output-stream and scroll-dispatch-to-stream-send, and the Device API state-polling baseline from the paired remote setup probe. The preserved run root also contains the raw remote daemon `remote-device-performance.jsonl` copied from the Linux service when the comparison enables `SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH`.

Remote Device API runs cache the Linux daemon archive under `apps/macos/.build/linux-e2e-cache/artifacts/` using a source fingerprint, skip re-upload when the remote archive checksum already matches, and reuse the installed remote daemon when the artifact checksum and Device API port marker match and the daemon is healthy.

The lower-level Linux artifact build command is:

```bash
docker run --rm --platform linux/amd64 \
  -v "$PWD":/workspace \
  -w /workspace \
  swift:6.2-noble \
  bash -lc 'apt-get update && apt-get install -y curl git xz-utils python3 pkg-config libsqlite3-dev libssl-dev openssl coreutils && apps/macos/scripts/build_linux_spacesd_artifact.sh --arch x86_64'
```

Use `--platform linux/arm64` with `--arch arm64` for the Ubuntu arm64 artifact. The archive contains `bin/spacesd`, `bin/spaces`, `install.sh`, the `spacesd-bin` executable, `libghostty-vt`, and the Swift runtime libraries needed on stock Ubuntu 24.04. The install script places the release under `~/.spaces/daemon/releases/<version>/`, updates `~/.spaces/daemon/current`, updates `~/.spaces/bin/spacesd` and `~/.spaces/bin/spaces`, points `~/.local/bin/spaces` to the managed CLI helper, creates `~/.spaces/runtime`, `~/spaces/workspaces`, and `~/spaces/repos`, installs `~/.config/systemd/user/spacesd.service`, enables user lingering so the service survives SSH disconnects, enables the user service, and restarts it. If the Linux account cannot enable lingering itself, run `sudo loginctl enable-linger <user>` on the Linux device and retry.

The single user-facing Linux install/upgrade path is the published `spaces-install-linux.sh` one-liner, run on the Ubuntu 24.04 device for a specific released version (the Mac app and CLI print this command when a remote daemon is missing or wire-incompatible):

```bash
curl -fsSL https://github.com/yogesh-dhande/spaces/releases/download/v<version>/spaces-install-linux.sh | bash -s -- <version>
```

For development or debugging against an unreleased build, install a locally built artifact on a reachable Linux device with scp plus the bundled `install.sh` (this is the offline alternative to the published one-liner):

```bash
scp .build/artifacts/spacesd-ubuntu-24.04-x86_64.tar.gz <host>:/tmp/
ssh <host> 'mkdir -p /tmp/spacesd-install && tar -xzf /tmp/spacesd-ubuntu-24.04-x86_64.tar.gz -C /tmp/spacesd-install && /tmp/spacesd-install/install.sh'
```

After install, verify the remote pairing command over strict SSH — the Mac app's `--ssh` pairing path runs the same command to fetch the remote pairing link:

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes <host> '~/.spaces/bin/spaces device pair --json'
```

Remote Macs are installed from the signed DMG instead of a headless artifact. The DMG install creates `/Applications/Spaces.app`, links `/usr/local/bin/spaces`, `/usr/local/bin/spacesd`, and `/usr/local/bin/spaces-caddy` to `Spaces.app/Contents/Resources/`, links `~/.spaces/bin/spaces` and `~/.spaces/bin/spacesd` to the same bundled binaries, writes the per-user LaunchAgent with `~/.spaces/bin/spacesd` as its program, and creates the default `~/.spaces` state directories. When a remote Mac has no Spaces install, pairing fails with guidance to install the Spaces app.

For focused terminal latency probes:

```bash
apps/macos/Tests/e2e.sh terminal --list
apps/macos/Tests/e2e.sh terminal --scenario mac-input-latency
apps/macos/Tests/e2e.sh terminal --scenario mac-scrollback-latency
apps/macos/Tests/e2e.sh terminal --scenario mac-scrollback-partial-latency
apps/macos/Tests/e2e.sh mobile --scenario ios-input-latency --network-profile local
apps/macos/Tests/e2e.sh mobile --scenario ios-input-latency --network-profile ios-constrained
apps/macos/Tests/e2e.sh mobile --scenario ios-scrollback-latency --network-profile local
apps/macos/Tests/e2e.sh mobile --scenario ios-scrollback-latency --network-profile ios-constrained
```

The latency scenarios are fast performance iteration lanes rather than the canonical correctness gate. They write `terminal-latency-summary.json`, print p50, p95, max, per-sample timings, visible render frame mix, median visible render-update bytes, and render payload rates. Input scenarios fail on gross latency regressions, render-frame decode failures, or measured typed echoes that arrive as full, missing, or `explicit_resync` frames instead of live stream deltas; report-only targets stay visible in the terminal output. Input summaries include enqueue-to-RPC-begin, RPC duration, frame-apply or frame-publish timing, RPC-end-to-render-visible, and event-to-visible totals. Mac probes target the debug app by executable name; input totals are key-down-to-frame-apply, scroll totals are wheel-event-to-frame-apply with alternating directions across samples, and command-catchup totals use command-submit-to-frame-apply from one warmed shell session across samples. `mac-scrollback-latency` uses large scroll deltas and `mac-scrollback-partial-latency` uses smaller within-screen deltas. Mac summaries also split owner input activity to state change, state change to frame export, frame export to mirror apply, and frame apply to dumped-state visibility. Mobile summaries split host publish to relay read, relay read to network send begin, network send begin to stream-visible, full versus delta visible sample counts, and average plus peak stream bytes per second. Scrollback summaries measure rendered text changes, no-op gesture counts, and render cadence as report-only metrics. The `ios-constrained` mobile profile shapes standalone Device API requests with `80ms` RTT, `8Mbps` bandwidth, and `16KB` chunks; normal terminal stream frames remain ordered but are not per-frame delayed by the shaper.

For render-update profiling, run the latency scenario with a fixed sample count, terminal size, fixture command, target, and network profile. The scenarios exercise the production v2 stream: self-contained full v2 updates for initial baselines, state fetches, and resyncs, plus delta updates with native scroll-rectangle operations for steady output, live `state_change`, and scrollback.

```bash
apps/macos/Tests/e2e.sh mobile --scenario ios-input-latency --network-profile local --samples 12 --keep-root
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
apps/macos/Tests/e2e.sh terminal --scenario cli
```

That scenario exercises `spaces terminal command`, `send`, `key`, `tail`, `show`, and both takeover directions against one isolated Spaces terminal session.

The Spaces terminal `tail` path also depends on the local `libghostty-vt` artifacts. Set them up before building or profiling terminal changes:

```bash
apps/macos/scripts/setup_ghostty.sh
```

The setup script installs Zig `0.15.2` under `apps/macos/.local/ghosttyvt/toolchain/` when a source build is requested. The fork keeps `main` mirrored from upstream, so the reviewable fork delta lives in the `spaces -> main` pull request.
For a browser view of fork drift against upstream, open [ghostty-org/ghostty compare view](https://github.com/ghostty-org/ghostty/compare/main...yogesh-dhande:ghostty:spaces).
The GitHub Actions PR and release workflows run this setup before the macOS build and coverage pass so clean runners have the matching `GhosttyKit`, `libghostty-vt` headers, and dylib available.

Terminal E2E, profiling, and soak scenarios that launch `SpacesApp` acquire a shared harness lock before they launch a profile-owned app instance. They stop only the app instance for their own profile. Hotkey-sensitive and real-system desktop-control workflows also wait for desktop-global control instead of killing unrelated running Spaces instances. When desktop control is already owned by another Spaces instance, the wait path also posts a macOS notification that asks you to close the running app when you are done with it.

For repeatable profiling of the built-in terminal owner and ownership-transfer flows:

```bash
apps/macos/Tests/e2e.sh terminal --scenario built-in-terminal-profile --samples 3
```

The profiler runs against an isolated `SPACES_DB_PATH`, enables `DEBUG=1`, exercises owner attach, remote viewer attach, send, `tail`, and takeover, then summarizes the built-in terminal perf metrics captured from the app log.
It also writes `summary.txt` and `metrics.json` under its temp work root so baseline metric snapshots can be compared across terminal-window parity changes.

For repeatable profiling of the first-party iOS bridge and ownership transfer path:

```bash
apps/macos/Tests/e2e.sh device-api profile
```

That profiler runs against an isolated `SPACES_DB_PATH`, pairs a first-party iOS-shaped installation, attaches a local-window owner plus remote client, measures time-to-owner-render, ownership transfer to iOS, ownership transfer back to the macOS owner, and the streamed visibility latency for both iOS-side and macOS-side input.

For manual simulator verification of the iOS client:

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-ios-demo/spaces.db"
mkdir -p "$(dirname "$SPACES_DB_PATH")"
pkill -x SpacesApp 2>/dev/null || true
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
mkdir -p "$TMPDIR/spaces-ios-demo/workspace"
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spacese2e register-project --project-dir "$TMPDIR/spaces-ios-demo/workspace" >/dev/null
(cd "$TMPDIR/spaces-ios-demo/workspace" && env SPACES_DB_PATH="$SPACES_DB_PATH" "$(cd apps/macos/.build/debug && pwd)/spaces" \
  terminal command --command cat --title ios-demo)
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spacese2e mobile-status
xcodebuild -project apps/ios/SpacesMobile.xcodeproj -scheme SpacesMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

On first launch, the iOS client opens its Devices sheet. Open Devices in the Mac sidebar or run `spaces device pair`, then scan the QR code. The mobile demo lane opens one daemon pairing window per simulator and seeds both the iPad and iPhone simulator settings automatically. The harness stores Mac client metadata in an isolated SQLite file by exporting `SPACES_CLIENT_DB_PATH` and stores harness-only Mac client secrets under `SPACES_CLIENT_SECRET_DIR`; these overrides are for E2E and demo profiles so test pairings do not mix with the user client database or client secret files. Remote mobile scenarios pair the Mac client and iOS simulators with the remote daemon over SSH-backed pairing windows before launching the apps. The demo keeps a local SSH forward to the remote daemon Device API and seeds the demo clients with that forwarded endpoint so the demo works from networks where the remote daemon port is not directly reachable. After pairing, the iOS client stores the issued credential and pinned daemon fingerprint and reconnects automatically on later launches. The client lists workspaces and live terminal sessions from the selected daemon, auto-attempts takeover when a session detail is opened, renders service-published Ghostty render frames only after ownership is acquired, and shows takeover or status UI while another client still owns the session.
For the iOS simulator, a seeded pairing link with `127.0.0.1` works because the daemon Device API binds all IPv4 interfaces by default. A real device scans the Mac QR code from the Devices panel. The iOS terminal detail path renders the owner-bootstrap Ghostty render frame through the same terminal-grid compatibility data as macOS, so the simulator should show a terminal-like view after takeover rather than a plain-text fallback.

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

4. If Xcode reports that `dev.usespaces.spacesmobile` cannot be signed by the selected team, stop there and widen the first-party bundle policy before changing the bundle identifier. The Device API accepts only that bundle identifier for pairing and reconnect. Set `SPACES_IOS_DEVELOPMENT_TEAM` in `.env` when the command-line build should override the project signing team.
5. Keep the Mac app and Device API on the same `SPACES_DB_PATH`; the daemon Device API binds all IPv4 interfaces on port `47847` by default.

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-ios-demo/spaces.db"
mkdir -p "$(dirname "$SPACES_DB_PATH")"
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
mkdir -p "$TMPDIR/spaces-ios-demo/workspace"
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spacese2e register-project --project-dir "$TMPDIR/spaces-ios-demo/workspace" >/dev/null
(cd "$TMPDIR/spaces-ios-demo/workspace" && env SPACES_DB_PATH="$SPACES_DB_PATH" "$(cd apps/macos/.build/debug && pwd)/spaces" \
  terminal command --command cat --title ios-demo)
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spacese2e mobile-status
```

6. On the Mac, allow the incoming-network prompt if macOS shows one. In the Mac app, open Devices, choose Pair iPhone or iPad for the target daemon, and scan the QR code from the iPhone or iPad.
7. The first connection attempt should trigger the iOS local-network permission prompt; accept it so the app can reach the daemon Device API.

For a disposable one-command demo stack that launches the macOS app, uses the daemon-hosted Device API, pairs both the iPad and iPhone simulators, and opens the mobile app on each:

```bash
apps/macos/Tests/e2e.sh mobile-demo
```

The launcher expects the local Ghostty artifacts under `apps/macos/.local/ghosttykit/` and remote E2E SSH settings in `.env`. The runner builds the repo-local macOS debug products, the demo builds a fresh simulator `SpacesMobile.app` into a DerivedData directory under the demo root, and that same app bundle is installed on both the iPad and iPhone simulators. Demo runs use the current user's `HOME` and `XDG_CONFIG_HOME` so Ghostty themes and user settings match normal local debugging. By default, the demo uses isolated Spaces profile mode, which keeps the database and runtime under the demo root without moving user-level settings into a temporary home. Use `SPACES_MOBILE_DEMO_PROFILE_MODE=user` when the demo should attach to the repo-local Spaces profile instead. The E2E wrapper uses an ephemeral local Device API port unless `SPACES_MOBILE_DEMO_PORT` is set. The launcher stops the current-profile app owner, current-profile terminal service, and stale repo-local listeners on the selected Device API port before launch. It provisions live Beacon and Scout workspace terminal sessions, waits for their owner attachments, builds or reuses the repo-local Linux E2E artifact for the configured remote, installs it on the remote daemon account, pairs the simulators with the local daemon and configured remote daemon, then reads the daemon Device API details through `spacese2e mobile-status`. It prints the demo root, profile mode, PIDs, logs, screenshots, project directories, terminal session IDs, the iOS app path, iOS build paths, remote device details, and the simulator app stdout or stderr log paths as JSON, keeps the stack alive until `Ctrl+C`, and then tears the demo down cleanly.
The same demo root also contains `mobile-terminal-performance.jsonl`, and the printed JSON includes its `performanceLogPath`. The mobile E2E lane consumes that file directly when it asserts one bootstrap epoch, first render timing, input-ready timing, and scrollback behavior.

Useful overrides:
- `SPACES_MOBILE_DEMO_KEEP_ROOT=1` keeps the demo root after shutdown for log inspection.
- `SPACES_MOBILE_DEMO_PROFILE_MODE=isolated|user` selects the Spaces profile mode; demo and E2E runs default to isolated database/runtime paths.
- `SPACES_MOBILE_DEMO_ROOT_PARENT=...` changes the parent directory for demo roots; the default is `~/.spaces-dev/mobile-demo`.
- `SPACES_MOBILE_DEMO_BUILD_MACOS=0` skips the scripted macOS debug build when the existing repo-local binaries should be used.
- `SPACES_MOBILE_DEMO_IPAD_NAME=...` and `SPACES_MOBILE_DEMO_IPHONE_NAME=...` target different simulator names when the defaults are unavailable.
- `SPACES_MOBILE_DEMO_APP_PATH=...` skips the scripted `xcodebuild` and installs an explicit `SpacesMobile.app` bundle.
- `SPACES_MOBILE_DEMO_PORT=...` sets the daemon Device API port for the demo profile; the E2E wrapper supplies `0` by default so the daemon chooses an available port.
- `SPACES_MOBILE_E2E_DEVICE_KEY=iphone|ipad` and `SPACES_MOBILE_E2E_DEVICE_NAME=...` select the simulator used by the mobile E2E lane; the default E2E target is `iPhone 17 Pro`.

For targeted mobile E2E runs, use `--scenario`:

```bash
apps/macos/Tests/e2e.sh mobile --scenario takeover
apps/macos/Tests/e2e.sh mobile --scenario codex
apps/macos/Tests/e2e.sh mobile --scenario codex-resume-reopen
apps/macos/Tests/e2e.sh mobile --scenario roundtrip
apps/macos/Tests/e2e.sh mobile --scenario scrollback
apps/macos/Tests/e2e.sh mobile --scenario two-session
apps/macos/Tests/e2e.sh mobile --scenario ctrl-c-final-frame
apps/macos/Tests/e2e.sh mobile --scenario ctrl-c-final-frame-codex-survivor
apps/macos/Tests/e2e.sh mobile --scenario ownership-guard
```

`codex` starts real Codex in a fresh Mac-owned terminal session and verifies iPhone takeover against the already-running simulator app. Codex scenarios build a generated Codex home inside the demo root by copying the current user's config, linking signed-in auth files, and marking the demo project trusted so the test exercises the TUI instead of the directory-trust prompt. If Codex shows its startup update prompt, the harness selects `Skip` and continues waiting for the TUI. `codex-resume-reopen` runs `codex resume 019e380a-9def-7852-9834-74c67b2da894`, takes over on iPhone, returns to the terminal list, and repeatedly reopens the same session. `roundtrip` drives the Mac/iPhone/Mac/iPhone/Mac ownership path with rendered-content assertions at each handoff. `scrollback` fills the Mac-owned terminal with long output, transfers ownership to iPhone, scrolls away from bottom, runs an owner command while still scrolled up, and checks the owner epoch and prompt rendering. `two-session` takes over two fresh terminal sessions through list navigation. `ctrl-c-final-frame` creates `interrupt-target` and `survivor-peer` process-style sessions, sends `ctrl+c` to `interrupt-target` from the iOS owner path, checks the persisted final Ghostty frame on iOS and Mac, and verifies the `survivor-peer` session remains running. `ctrl-c-final-frame-codex-survivor` uses the same interrupt path with a real Codex TUI as the survivor session. `ownership-guard` exercises the Device API ownership rules without UI automation.

Useful overrides:
- `SPACES_MOBILE_CODEX_COMMAND='codex resume <thread-id>'` replaces the default `codex` startup command for the `codex` scenario.
- `SPACES_MOBILE_CODEX_RESUME_THREAD_ID=<thread-id>` changes the thread used by `codex-resume-reopen`.
- `SPACES_MOBILE_CODEX_HOME=<path>` changes the source Codex home used by Codex scenarios; by default they use the current user's `CODEX_HOME` or `~/.codex`. The harness creates a demo-local Codex home from that source so signed-in Codex runs the real TUI without mutating the user's config.
- `SPACES_MOBILE_GHOSTTY_XDG_CONFIG_HOME=<path>` changes the source Ghostty XDG config root used by the mobile E2E harness; by default it uses the current user's `XDG_CONFIG_HOME` or `~/.config`.

When debugging mobile owner render dumps, keep terminal UI rendering frame-based. `GhosttyRemoteTerminalView` must not render from raw output bytes, must not call local session export APIs to reconstruct another owner, mobile owner bootstrap must use the service-published live Ghostty render frame, and macOS owner attach or takeover must use the same service-published frame policy. Do not use VT replay, snapshot-to-VT encoding, raw output, or `output.log` as a terminal-rendering fallback. Use the bootstrap frame, screenshots, event logs, and rendered-content dumps for E2E assertions.

For sustained throughput, repaint-heavy output, tail latency, and scrollback completeness on the built-in terminal path:

```bash
apps/macos/Tests/e2e.sh terminal --scenario stress
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
apps/macos/Tests/e2e.sh terminal --scenario soak --duration-seconds 300
```

That soak harness supports `SOAK_MODE=repaint`, `SOAK_MODE=mixed`, and `SOAK_MODE=codex_churn` with `SOAK_MODE=codex` kept as an alias. The Codex-style mode adds a large initial scrollback history before the steady redraw workload so late-phase transcript pressure looks closer to real long-running Codex sessions.
The soak summary samples `SpacesApp` RSS, CPU, output growth, and `terminal tail` latency at a fixed interval, reports early-vs-late tail drift, verifies that the emitted sequence numbers and final frame stayed complete, and confirms that the final `spaces terminal tail` output still shows the terminal footer and expected last frame after the long run.

For repeatable profiling of the app-triggered built-in workspace-terminal open path:

```bash
apps/macos/Tests/e2e.sh terminal --scenario workspace-terminal-open --samples 3
```

That profiler seeds an isolated fixture workspace, triggers the app-side workspace-terminal open route through the manual E2E IPC helper, and summarizes:
- `workspace_terminal_open_wall`
- `workspace_terminal_open_ui`
- `terminal_session_wait_ready`
- `terminal_window_summon`

For real-system verification of live terminal edit and find shortcuts:

```bash
apps/macos/Tests/e2e.sh terminal --scenario edit-shortcuts
```

That scenario runs the debug app against an isolated `SPACES_DB_PATH`, opens a `cat` session, verifies `Cmd+V` through `spaces terminal tail`, verifies mouse selection plus `Cmd+C` through `pbpaste`, and verifies `Cmd+F`, `Cmd+G`, `Cmd+Shift+G`, and `Esc` through the terminal-window debug dump. It requires the same Accessibility permissions as the other desktop-control E2E scenarios.

For repeatable profiling of the built-in `Spaces terminal -> main window -> tracked process terminal` hotkey loop:

```bash
apps/macos/Tests/e2e.sh terminal --scenario spaces-terminal-hotkeys --samples 3
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
apps/macos/Tests/e2e.sh terminal --scenario spaces-terminal-palette --samples 3
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
apps/macos/Tests/e2e.sh terminal --scenario workspace-process-terminal
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
apps/macos/Tests/e2e.sh app
```

Before the suite launches its isolated app instance, it waits for desktop-global control. A timeout from that wait is an environment-contention result and should be retried without killing unrelated running Spaces instances.

The macOS E2E suite seeds the shared Beacon, Scout, and Prism fixture repositories and runs the app-level launch, focus, cycling, workspace, and agent-status assertions against the current profile's same-machine daemon.

With `SPACES_E2E_RUN_REMOTE=1`, the suite also prepares a paired remote Linux daemon from the repo-root `.env`, seeds the Mac client with that device, starts a remote named service, focuses its browser session, and verifies the service through the Mac Caddy router backed by the SSH local forward. The remote lane reads the harness profile's Mac client identity through `spacese2e mac-client-installation-id` so pairing uses the same identity as the app.

For a focused app smoke pass:

```bash
apps/macos/Tests/e2e.sh app --scenario smoke
```

For the combined smoke lane:

```bash
apps/macos/Tests/e2e.sh all
```

This suite is manual by design. It drives the real app, `spaces`, Chrome, and the built-in Spaces terminal in an interactive macOS session instead of XCTest.

Primary coverage:
- adding and archiving a workspace
- overriding workspace settings after creation
- launch, stop, restart, and dead-process recovery
- built-in Spaces terminal coverage
- extra user-added Chrome and terminal tabs
- workspace-detail numbered focus shortcuts
- forward/back workspace window cycling
- multi-workspace focus and cycling isolation
- remote browser-session routing through SSH local forwarding and the Mac Caddy router

The suite emits performance metrics in milliseconds for the main window-focus and cycle paths, using the app's debug timing logs for the same shortcut and cycling flows covered by the standalone focus-profiling workflow. The final summary prints both the pass/fail case list and the collected timing samples, so this suite is the primary path for focus profiling during development. The `app window-cycle` scenario runs the existing window-cycle profile path; set `REAL_SYSTEM_PROFILE_WARMUPS=5 REAL_SYSTEM_PROFILE_REPETITIONS=30` to collect steady-state cycle samples after warmup without changing the normal full-suite pass.

Repeated real-system profiling also covers:
- main window visibility toggles from inactive and active app states
- command palette toggles from inactive and active app states
- built-in `Spaces terminal -> main window -> tracked process terminal` focus loops
- built-in `Spaces terminal -> command palette -> tracked process terminal` focus loops

When the suite finishes with recorded metrics, it appends aggregated metric history to `apps/macos/.artifacts/real-system-profiles/metrics-history.csv` and regenerates `apps/macos/.artifacts/real-system-profiles/report.html` with `best`, `previous`, and `latest` comparisons for each tracked metric. Metric rows include average, p50, p95, min, max, and raw samples. Metric names use `start.action.end`, such as `browser_untracked_tab.cli_window_focus.browser_tracked_tab`, and the start and end tokens refer to concrete visible surfaces rather than app-level state. Scenario context like workspace scope is stored alongside each row. Dirty worktrees are recorded alongside clean runs by pairing the base `HEAD` commit with a worktree fingerprint, so the report can distinguish two different uncommitted snapshots on the same branch. The E2E artifact report also preserves the app profile `perf.log` with raw `spaces: perf metric=...` lines and request IDs for stage-level joins.

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

Local release runs the Ubuntu remote daemon artifact builds inside Docker for `linux/amd64` and `linux/arm64`, so Docker must be available before running the script. These Linux artifacts are installed by the user-run `spaces-install-linux.sh` one-liner on the Ubuntu device; Spaces does not install them over SSH. Remote Macs use the signed DMG rather than a separate daemon artifact.

This workflow:
- syncs the checked-in version metadata used by the CLI, app menu, and bundle plist
- builds universal `arm64` + `x86_64` release binaries for the app, CLI, and `spacesd`
- code-signs the app, CLI, and spacesd daemon
- builds and smoke-tests Ubuntu 24.04 `x86_64` and `arm64` remote daemon artifacts
- signs `spaces-remote-artifacts.json` with the remote artifact Ed25519 key that the `spaces-install-linux.sh` installer uses to verify the Linux artifact download
- creates a signed manual-download DMG
- creates a Sparkle-served `Spaces.app` zip archive
- updates `dist/updates/stable/appcast.xml` plus any Sparkle delta files
- stages the Sparkle feed and Sparkle archives into `apps/web/public/releases`
- builds the static site so Firebase can serve `https://usespaces.dev/releases/*`
- optionally notarizes the DMG when `NOTARIZE=1`
- verifies the final DMG signature plus the bundled installer, app, CLI, and spacesd daemon before publish
- publishes the DMG to GitHub Releases
- publishes `spacesd-ubuntu-24.04-x86_64.tar.gz`, `spacesd-ubuntu-24.04-arm64.tar.gz`, their `.sha256` checksum files, `spaces-remote-artifacts.json`, and `spaces-remote-artifacts.json.sig` to the same GitHub Release

Important environment variables:
- `CODESIGN_IDENTITY`
- `CODESIGN_CERTIFICATE_P12`
- `CODESIGN_CERTIFICATE_PASSWORD`
- `SPARKLE_PUBLIC_ED_KEY`
- `SPARKLE_PRIVATE_ED_KEY`
- `REMOTE_ARTIFACT_PUBLIC_ED25519_KEY`
- `REMOTE_ARTIFACT_PRIVATE_ED25519_KEY`
- `SPARKLE_FEED_URL`
- `SPARKLE_DOWNLOAD_URL_PREFIX`
- `NOTARIZE`
- `APPLE_ID`
- `TEAM_ID`
- `APP_PASSWORD`
- `GH_TOKEN`

For GitHub Actions releases, `CODESIGN_CERTIFICATE_P12` must be the base64-encoded Developer ID Application `.p12` bundle that matches `CODESIGN_IDENTITY`, and `CODESIGN_CERTIFICATE_PASSWORD` must be the password used when exporting that `.p12`.

Sparkle update hosting lives under `https://usespaces.dev/releases/` on the static Firebase site. The update feed and Sparkle archives are staged into `apps/web/public/releases`, which Next.js exports as real static files before Firebase deploy. The release pipeline keeps a single DMG, a single Sparkle zip, one stable `appcast.xml`, the `spaces-install-linux.sh` installer, and signed Linux remote artifacts the installer downloads. The app bundle carries `spaces`, `spacesd`, and Caddy in `Contents/Resources`; the DMG installer links `/usr/local/bin` and `~/.spaces/bin` helpers to those bundled binaries so installed CLI commands, launchd, and remote Mac pairing use the updated app bundle after Sparkle updates. Linux artifacts link `~/.local/bin/spaces` to the managed `~/.spaces/bin/spaces` helper so user shells can run `spaces` without a system-wide install.

## Website Deploy

Firebase Hosting deploys from [`.github/workflows/firebase-hosting-merge.yml`](../.github/workflows/firebase-hosting-merge.yml). It builds `apps/web` and deploys the static export on pushes to `main` that touch the site or on manual dispatch.

The workflow authenticates with GitHub OIDC through Google Workload Identity Federation, then deploys through the Firebase Hosting REST API. This avoids `firebase-tools` service-account-key assumptions while keeping the deploy keyless.

Required GitHub secrets:
- `FIREBASE_PROJECT_ID`
- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_SERVICE_ACCOUNT_EMAIL`
