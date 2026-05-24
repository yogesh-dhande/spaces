# Spaces Development

Build, test, and release workflows for the Spaces monorepo. For product overview and adoption, see [README.md](README.md).

## Repo Layout
- `apps/macos`: macOS app, `spaces` CLI, Swift sources, tests, product docs
- `apps/web`: static marketing site and user-facing docs
- `scripts`: root wrappers for build, test, coverage, release, and deploy workflows

## Documentation Map
- [`README.md`](README.md): product overview and adoption pitch
- [`AGENTS.md`](AGENTS.md): how coding agents should write, verify, and document changes
- [`apps/macos/spec.md`](apps/macos/spec.md): expected product behavior and UX
- [`apps/macos/docs/architecture.md`](apps/macos/docs/architecture.md): module boundaries, data model, and implementation rationale
- [`apps/macos/docs/terminal.md`](apps/macos/docs/terminal.md): built-in terminal and libghostty integration notes, constraints, and verification guidance
- [`design.md`](design.md): visual system and interaction patterns
- [`apps/web/app/docs`](apps/web/app/docs): user-facing product and CLI documentation

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
`scripts/coverage.sh` runs SwiftPM tests in parallel by default and caps auto-detected workers at `8` unless you override it with `SPACES_TEST_WORKERS` or change the cap with `SPACES_TEST_MAX_AUTO_WORKERS`.
`scripts/verify.sh` is the canonical sequential local verification path: staged formatting and lint, build, then coverage.
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

Use `scripts/dev-build-and-launch.sh` to launch the debug app without touching the installed app's database. Repo-local debug binaries derive a per-worktree profile automatically under `~/.spaces-dev/profiles/spaces/<branch-slug>-<worktree-hash>/`, and the script stops only the running app instance for that same profile before it relaunches.

For manual worktree-local shell sessions, export the same derived profile before launching the app, CLI, or E2E helper:

```bash
eval "$(apps/macos/.build/debug/spaces profile show --shell)"
apps/macos/.build/debug/SpacesApp
apps/macos/.build/debug/spaces terminal list
```

Override `SPACES_DB_PATH` when you need a one-off isolated profile root. Override `SPACES_RUNTIME_DIR` only when the runtime files themselves also need to move with that profile.

For branch-local libghostty artifact setup, run:

```bash
apps/macos/scripts/setup_ghosttykit.sh
```

That installs `GhosttyKit.xcframework` and the Ghostty resource bundle under `apps/macos/.local/ghosttykit/`, which the current branch-local resolver will discover automatically.
The default fork build comes from `apps/macos/ghosttykit-release-tag.txt`, and the setup script also accepts an explicit release tag argument plus `SPACES_GHOSTTYKIT_RELEASE_TAG` and `SPACES_GHOSTTYKIT_REPO` overrides when you need a different build or fork locally.
The setup flow finishes by running `apps/macos/scripts/verify_ghosttykit.sh`, which checks that the downloaded artifact still declares and exports the raw input and surface callback hooks that Spaces uses for owner rendering and final-state replay. Passive-viewer attachment exports are not part of the required contract.
The GitHub Actions PR and release workflows run this setup before SwiftPM resolves the macOS package so clean runners have the pinned branch-local `GhosttyKit` artifact in place.

If `SPACES_PROJECT_DIR` points at another checkout that already has `apps/macos/.local/ghosttykit/`, the setup script copies those local artifacts first and only falls back to GitHub release download when needed.
If you are iterating on unpublished fork APIs, run `apps/macos/scripts/setup_ghosttyvt.sh` first and then set `SPACES_GHOSTTYKIT_BUILD_FROM_SOURCE=1` when invoking `apps/macos/scripts/setup_ghosttykit.sh`. That rebuilds `GhosttyKit.xcframework` from the branch-local Ghostty fork checkout under `apps/macos/.local/ghosttyvt/src/` and refreshes the local resources from the same source tree instead of downloading the pinned release artifact.
The repo also runs [`.github/workflows/sync-ghosttykit-release.yml`](.github/workflows/sync-ghosttykit-release.yml) daily to bump that pinned tag to the latest published build from the Spaces-owned fork via pull request. The fork itself should run its own daily upstream-sync and rebuild automation; this repo only consumes the published release tag.

To validate the real in-process Ghostty owner renderer path in `SpacesApp`, launch the app normally with an isolated database root:

```bash
apps/macos/scripts/setup_ghosttyvt.sh
SPACES_GHOSTTYKIT_BUILD_FROM_SOURCE=1 apps/macos/scripts/setup_ghosttykit.sh
export SPACES_DB_PATH="$TMPDIR/spaces-ghostty-owner/spaces.db"
mkdir -p "$(dirname "$SPACES_DB_PATH")"
pkill -x SpacesApp 2>/dev/null || true
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
```

When the app launches built-in Spaces terminals itself, owner windows use the live `GhosttyEmbeddedSessionRegistry` path automatically instead of the daemon replay bridge. Use the normal app flows:
- Open a workspace terminal from the workspace detail pane.
- Launch a workspace process while the configured terminal host is `Spaces`.
- Launch a coding agent from the workspace detail pane.

Close one of those owner windows and reopen it from the app. The shell or long-running process should stay attached to the same local Ghostty session without restarting.
CLI-created sessions such as `spaces terminal command` and CLI-managed `spaces start` use the daemon-owned snapshot-stream path. The service publishes live Ghostty snapshots to native client windows over the per-session subscription socket, while `output.log` remains the transcript fallback and `spaces terminal tail` source.
For scripted real-system checks against the running app, `spacese2e` exposes `open-workspace-terminal`, `run-workspace-process`, and `launch-workspace-agent` so the manual harness can exercise the same app-owned launch path without accessibility scripting.

To verify the embedded Ghostty backend on an isolated database root:

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-ghostty/spaces.db"
export SPACES_RUNTIME_DIR="$(dirname "$SPACES_DB_PATH")/runtime"
apps/macos/scripts/setup_ghosttykit.sh
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

For the headless mobile-shaped control proof of concept against the Ghostty-owner path:

```bash
python3 apps/macos/Tests/poc_mobile_terminal_client.py --start-app
```

That flow launches an isolated `SpacesApp`, starts one `ghostty-embedded` session, exposes it through the first-party mobile bridge, pairs a first-party iPhone-shaped client, verifies non-owner input rejection at the control plane, closes the real macOS owner window, promotes the mobile client, sends text plus `Enter`, reopens the native owner window for the same session, and finally transfers ownership back to that reopened macOS owner.

For the maintained E2E wrapper around that same flow:

```bash
apps/macos/Tests/e2e_terminal_mobile_client.sh
```

Use the shell wrapper when you want one command that exercises the full attach, takeover, owner-close, owner-reopen, send, and key path without remembering the Python invocation.
Set `SPACES_MOBILE_E2E_UI_TEST_NAME=SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverAfterMacRetakeover` to run the iPad auto-takeover -> Mac retakeover -> iPad `Take Over` regression path.

The daemon-hosted mobile bridge is the current first-party seam for that proof of concept. Treat it as a paired Spaces-only bridge rather than a third-party external API surface. `spaces mobile serve` remains available when a harness needs a standalone bridge process with explicit host, port, or pairing-code overrides.

For direct CLI verification of Spaces terminal commands:

```bash
apps/macos/Tests/e2e_terminal_cli_commands.sh
```

That script exercises `spaces terminal command`, `send`, `key`, `tail`, `show`, and both takeover directions against one isolated Spaces terminal session.

The Spaces terminal `tail` path also depends on a local `libghostty-vt` build. Set that up before building or profiling terminal changes:

```bash
apps/macos/scripts/setup_ghosttyvt.sh
```

That script pins a local `ghostty` checkout to `apps/macos/ghosttyvt-revision.txt`, installs Zig `0.15.2` under `apps/macos/.local/ghosttyvt/toolchain/`, and builds `libghostty-vt` under `apps/macos/.local/ghosttyvt/src/zig-out/`.
The default source remote is the same Spaces-owned fork that publishes `GhosttyKit.xcframework`, and the setup script clones or refetches that fork through its `spaces` branch. The fork keeps `main` mirrored from upstream, so the reviewable fork delta lives in the `spaces -> main` pull request.
For a browser view of fork drift against upstream, open [ghostty-org/ghostty compare view](https://github.com/ghostty-org/ghostty/compare/main...yogesh-dhande:ghostty:spaces).
When you use the repo defaults, the setup flow also verifies that `apps/macos/ghosttyvt-revision.txt` matches the commit behind `apps/macos/ghosttykit-release-tag.txt` so the editable Ghostty source, published xcframework, and local `libghostty-vt` build stay on the same fork lineage.
The GitHub Actions PR and release workflows run this setup before the macOS build and coverage pass so clean runners have the matching `libghostty-vt` headers and dylib available.

The terminal E2E, profiling, and soak scripts that launch `SpacesApp` acquire a shared harness lock before they run `setup_ghosttykit` or launch a new app instance. They stop only the app instance for their own profile. Hotkey-sensitive and real-system desktop-control workflows also wait for desktop-global control instead of killing unrelated running Spaces instances. When desktop control is already owned by another Spaces instance, the wait path also posts a macOS notification that asks you to close the running app when you are done with it.

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
xcodebuild -project apps/ios/SpacesMobile.xcodeproj -scheme SpacesMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

On first launch, the iOS client opens its connection sheet. Choose the nearby Mac when it appears or enter `127.0.0.1` for the simulator, then enter the pairing code from `spaces mobile status`. After pairing, the iOS client stores the issued credential and reconnects automatically on later launches. The current client is terminal-only: it lists workspaces and live terminal sessions, auto-attempts takeover when a session detail is opened, mounts the Ghostty surface only after ownership is acquired, and shows takeover or status UI while another client still owns the session.
For the iOS simulator, `127.0.0.1` still works because the daemon bridge binds all IPv4 interfaces by default. A real device can use the nearby Mac discovered by Bonjour or one of the LAN addresses printed by `spaces mobile status`. The current iOS terminal detail path renders the owner-bootstrap terminal-grid snapshot through a local iOS Ghostty surface, so the simulator should show a terminal-like view after takeover rather than the earlier plain-text fallback.

For manual real-device verification of the iOS client:

1. Connect the iPhone or iPad to the Mac, unlock it, trust the Mac if prompted, and enable Developer Mode on the device if iOS asks.
2. Open `apps/ios/SpacesMobile.xcodeproj` in Xcode, select the `SpacesMobile` target, enable Automatically manage signing, and choose the Apple Developer team that should sign the app.
3. If Xcode reports that `com.yogeshdhande.spacesmobile` cannot be signed by that team, stop there and widen the first-party bundle policy before changing the bundle identifier. The current bridge accepts only that bundle identifier for pairing and reconnect.
4. Keep the Mac app and mobile bridge on the same `SPACES_DB_PATH`; the daemon bridge binds all IPv4 interfaces on port `47847` by default.

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-ios-demo/spaces.db"
mkdir -p "$(dirname "$SPACES_DB_PATH")"
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces terminal command --backend ghostty-embedded --command cat --title ios-demo
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces mobile status
```

5. On the Mac, allow the incoming-network prompt if macOS shows one. In the iOS app, choose the nearby Mac or enter one of the printed LAN addresses as the host, keep port `47847`, and pair with the code from `spaces mobile status`.
6. Run the app from Xcode with the physical device selected as the destination. The first connection attempt should trigger the iOS local-network permission prompt; accept it so the app can reach the Mac bridge.

For a disposable one-command demo stack that launches the macOS app, uses the daemon-hosted mobile bridge, pairs both the iPad and iPhone simulators, and opens the mobile app on each:

```bash
apps/macos/Tests/run_mobile_terminal_demo.sh
```

The launcher expects the debug macOS binaries and the local Ghostty artifacts under `apps/macos/.local/ghosttykit/`. It builds a fresh simulator `SpacesMobile.app` into a disposable DerivedData directory under the demo temp root, then installs that same app bundle on both the iPad and iPhone simulators. It provisions two live workspace terminal sessions before launching the mobile clients so list-navigation and second-session takeover flows can be reproduced without extra manual setup. It refuses to start if another `SpacesApp` instance or bridge listener is already running so the global hotkey and mobile port stay unambiguous, then reads the daemon bridge details through `spaces mobile status`. It prints the disposable temp root, PIDs, logs, screenshots, both terminal session IDs, the iOS app path, iOS build paths, and the simulator app stdout or stderr log paths as JSON, keeps the stack alive until `Ctrl+C`, and then tears the demo down cleanly.
The same demo root also contains `mobile-terminal-performance.jsonl`, and the printed JSON includes its `performanceLogPath`. The standalone takeover wrappers consume that file directly when they assert one bootstrap epoch, first render timing, input-ready timing, and scrollback history seeding behavior.

Useful overrides:
- `SPACES_MOBILE_DEMO_KEEP_ROOT=1` keeps the temp root after shutdown for log inspection.
- `SPACES_MOBILE_DEMO_IPAD_NAME=...` and `SPACES_MOBILE_DEMO_IPHONE_NAME=...` target different simulator names when the defaults are unavailable.
- `SPACES_MOBILE_DEMO_APP_PATH=...` skips the scripted `xcodebuild` and installs an explicit `SpacesMobile.app` bundle.
- `SPACES_MOBILE_DEMO_PORT=...` sets the daemon bridge port for that disposable profile.

For the real standalone Codex takeover repro path on iPad, use the dedicated wrapper instead of driving the demo by hand:

```bash
apps/macos/Tests/e2e_terminal_mobile_codex_standalone.sh
```

That wrapper launches the disposable demo stack, starts real Codex in the Mac-owned terminal session, accepts the Codex trust prompt when needed, and then attaches the iPad UI test to the already-running standalone simulator app so takeover happens against the same `simctl`-launched runtime as the manual demo. On failure it preserves the demo root and tails the relevant macOS app, bridge, and UI test logs automatically.

Useful overrides:
- `SPACES_MOBILE_CODEX_COMMAND='codex resume <thread-id>'` replaces the default `codex` startup command.
- `SPACES_MOBILE_REOPEN_SAME_SESSION=1` makes the standalone iPad UI test go back to the list and reopen the same terminal repeatedly after takeover.

For the resumed-Codex reopen regression on iPad, use the dedicated wrapper:

```bash
apps/macos/Tests/e2e_terminal_mobile_codex_resume_reopen_standalone.sh
```

That wrapper runs `codex resume 019e380a-9def-7852-9834-74c67b2da894` on the Mac-owned session, takes over on iPad, returns to the terminal list, and then reopens the same session repeatedly so the resumed-session owner path and the back-navigation relaunch path stay covered together.

When debugging iPad owner render dumps, keep the mobile live-output path snapshot-free after owner bootstrap. `GhosttyRemoteTerminalView` must not call `ghostty_session_export_snapshot` on its local renderer after applying live output, passive viewer open or reopen must not make the Mac host export a live session snapshot while a local Mac window owns the session, and mobile owner bootstrap must use the cached Ghostty session snapshot rather than the VT snapshot stream. The Mac host may refresh that cached session snapshot immediately before transferring ownership to a remote mobile owner, but it must not force a Ghostty surface refresh or synthesize a second visual path from transcript data. Use the bootstrap snapshot, screenshots, event logs, and history-seed performance events for E2E assertions.

For the real standalone Mac/iPad/Mac/iPad/Mac ownership round trip with rendered-content assertions at each handoff, use:

```bash
apps/macos/Tests/e2e_terminal_mobile_roundtrip_standalone.sh
```

That wrapper launches the disposable demo stack, seeds terminal output on the Mac-owned session, drives two iPad-owned commands through the mobile app, retakes ownership on Mac, hands it back to iPad twice, and then finishes on Mac again. It preserves the demo root on failure so the render dumps, event log, screenshots, and UI test log stay available for triage.

For the standalone long-output scrollback regression after iPad takeover, use:

```bash
apps/macos/Tests/e2e_terminal_mobile_scrollback_standalone.sh
```

That wrapper launches the same disposable demo stack, fills the Mac-owned terminal with long output, transfers ownership to the standalone iPad app, scrolls away from bottom, runs an owner command while still scrolled up, and then asserts that the first owner epoch stayed singular, the viewport remained off the bottom, and the owner render never produced a stray prompt-only `%` row.

For the dedicated two-session iPad takeover regression, use:

```bash
apps/macos/Tests/e2e_terminal_mobile_two_session_standalone.sh
```

That wrapper launches the same two-session demo stack, takes over the primary terminal on iPad, alternates back through the list into the secondary terminal, and then repeats the reopen cycle once more so the multi-session dismissal and relaunch path stays covered.

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

Git commits can use the repo hook in `.githooks/pre-commit`, which auto-formats staged Swift files under `apps/macos/Sources` and `apps/macos/Tests` before running lint and coverage.

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

The pre-commit hook does two things:
- runs `scripts/lint.sh`, which formats staged macOS Swift source and test files and then runs any additional lint checks
- runs `scripts/coverage.sh`

Pull requests are checked in GitHub Actions with [`.github/workflows/pr-checks.yml`](.github/workflows/pr-checks.yml), which runs the same Swift lint/build/coverage flow plus the static website build.

## Manual E2E

Run the real-system GUI/CLI suite from the repository root with:

```bash
apps/macos/Tests/e2e_real_system.sh
```

Before the suite launches its isolated app instance, it waits for desktop-global control. A timeout from that wait is an environment-contention result and should be retried without killing unrelated running Spaces instances.

To capture a product-demo video from the same suite, record the run with the native `ScreenCaptureKit` helper and optionally add short editing-friendly pauses between visible transitions:

```bash
apps/macos/Tests/e2e_real_system.sh \
  --record-video /tmp/spaces-real-e2e.mp4 \
  --pause-transitions
```

The recorder follows the current main display. `--capture-device` remains accepted as a no-op compatibility flag for older invocations.

To prepare the same fixture projects, localhost browser-session servers, and workspace records for manual exploration without running the assertions, use:

```bash
apps/macos/Tests/e2e_real_system.sh --setup-fixtures-only
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
- builds universal `arm64` + `x86_64` release binaries for both the app and CLI
- code-signs the app and CLI
- creates a signed manual-download DMG
- creates a Sparkle-served `Spaces.app` zip archive
- updates `dist/updates/stable/appcast.xml` plus any Sparkle delta files
- stages the Sparkle feed and Sparkle archives into `apps/web/public/releases`
- builds the static site so Firebase can serve `https://usespaces.dev/releases/*`
- optionally notarizes the DMG when `NOTARIZE=1`
- verifies the final DMG signature plus the bundled installer and app before publish
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

Sparkle update hosting lives under `https://usespaces.dev/releases/` on the static Firebase site. The update feed and Sparkle archives are staged into `apps/web/public/releases`, which Next.js exports as real static files before Firebase deploy. The release pipeline keeps a single DMG, a single Sparkle zip, and one stable `appcast.xml`, all backed by those universal binaries.

## Website Deploy

Firebase Hosting deploys from [`.github/workflows/firebase-hosting-merge.yml`](.github/workflows/firebase-hosting-merge.yml). It builds `apps/web` and deploys the static export on pushes to `main` that touch the site or on manual dispatch.

The workflow authenticates with GitHub OIDC through Google Workload Identity Federation, then deploys through the Firebase Hosting REST API. This avoids `firebase-tools` service-account-key assumptions while keeping the deploy keyless.

Required GitHub secrets:
- `FIREBASE_PROJECT_ID`
- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_SERVICE_ACCOUNT_EMAIL`
