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
- `yabai`, `tmux`
- Google Chrome
- Accessibility permission (handled via the in-app setup flow on first launch)

## macOS App and CLI

Run from the repository root:

```bash
scripts/swiftpm.sh build
scripts/swiftpm.sh test --parallel
scripts/format-staged-swift.sh
scripts/lint.sh
scripts/coverage.sh
```

`scripts/lint.sh` auto-formats `apps/macos/Sources` and `apps/macos/Tests` with `swift format` before running lint so formatter-driven warnings do not drown out real issues.

Useful local entry points:

```bash
apps/macos/.build/debug/SpacesApp
apps/macos/.build/debug/spaces --help
apps/macos/.build/debug/spacese2e --help
apps/macos/.build/debug/spaces import --title "debug" --notes "Local debug session"
apps/macos/.build/debug/spaces update --notes "Ready for review"
apps/macos/.build/debug/spaces restart
```

Use `scripts/dev-build-and-launch.sh` to launch the debug app without touching the installed app's database. The script sets `SPACES_DB_PATH` to `~/.spaces-dev/spaces.db` by default. Override it with `SPACES_DEV_DB_PATH=/custom/path/spaces.db` when you want a different isolated dev database.

For branch-local manual testing against a clean database and terminal-runtime root, override `SPACES_DB_PATH` before launching either binary:

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-branch/spaces.db"
mkdir -p "$(dirname "$SPACES_DB_PATH")"
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces terminal list
```

For branch-local libghostty artifact setup, run:

```bash
apps/macos/scripts/setup_ghosttykit.sh
```

That installs `GhosttyKit.xcframework` and the Ghostty resource bundle under `apps/macos/.local/ghosttykit/`, which the current branch-local resolver will discover automatically.

If `SPACES_PROJECT_DIR` points at another checkout that already has `apps/macos/.local/ghosttykit/`, the setup script copies those local artifacts first and only falls back to GitHub release download when needed.

To verify the embedded Ghostty backend on an isolated database root:

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
  terminal tail <session-id> --lines 5
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces \
  terminal show <session-id> --viewer
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spaces \
  terminal takeover <session-id> <viewer-client-id>
```

For owner or viewer verification, keep exactly one `SpacesApp` process running for the chosen `SPACES_DB_PATH`. The current `ghostty-embedded` slice supports one live libghostty owner window plus one or more passive viewer windows that follow `output.log` and can take over ownership without restarting the session.

For repeatable profiling of the built-in terminal owner and viewer flows:

```bash
ITERATIONS=3 apps/macos/Tests/profile_built_in_terminal.sh
```

The profiler runs against an isolated `SPACES_DB_PATH`, enables `DEBUG=1`, exercises owner attach, viewer attach, send, `tail`, and takeover, then summarizes the built-in terminal perf metrics captured from the app log.
It also writes `summary.txt` and `metrics.json` under its temp work root so baseline metric snapshots can be compared across terminal-window parity changes.

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

The pre-commit hook does three things:
- formats staged macOS Swift source and test files with `swift format`
- runs `scripts/lint.sh`, which also auto-formats the full macOS Swift source and test tree before linting
- runs `scripts/coverage.sh`

Pull requests are checked in GitHub Actions with [`.github/workflows/pr-checks.yml`](.github/workflows/pr-checks.yml), which runs the same Swift lint/build/coverage flow plus the static website build.

## Manual E2E

Run the real-system GUI/CLI suite from the repository root with:

```bash
apps/macos/Tests/e2e_real_system.sh
```

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

This suite is manual by design. It drives the real app, `spaces`, `yabai`, Chrome, and the configured terminal host in an interactive macOS session instead of XCTest.

Primary coverage:
- adding and archiving a workspace
- overriding workspace settings after creation
- launch, stop, restart, and dead-process recovery
- iTerm2 and Ghostty default terminal coverage
- extra user-added Chrome and terminal tabs
- workspace-detail numbered focus shortcuts
- forward/back workspace window cycling
- multi-workspace focus and cycling isolation

The suite emits performance metrics in milliseconds for the main window-focus and cycle paths, using the app's debug timing logs for the same shortcut and cycling flows covered by the standalone focus-profiling workflow. The final summary prints both the pass/fail case list and the collected timing samples, so this suite is the primary path for focus profiling during development.

Repeated real-system profiling also covers:
- main window visibility toggles from inactive and active app states
- command palette toggles from inactive and active app states

When the suite finishes with recorded metrics, it appends aggregated metric history to `apps/macos/.artifacts/real-system-profiles/metrics-history.csv` and regenerates `apps/macos/.artifacts/real-system-profiles/report.html` with `best`, `previous`, and `latest` comparisons for each tracked metric. Metric names use `start.action.end`, such as `browser_untracked_tab.cli_window_focus.browser_tracked_tab`, and the start and end tokens refer to concrete visible surfaces rather than app-level state. Scenario context like terminal host and workspace scope is stored alongside each row. Dirty worktrees are recorded alongside clean runs by pairing the base `HEAD` commit with a worktree fingerprint, so the report can distinguish two different uncommitted snapshots on the same branch.

The manual suite depends on a small set of debug-log lines from the app and CLI helpers. Treat these as test contracts when changing debug logging:
- `spaces: perf metric=...`
- `spaces: workspace_detail_ipc selecting ...` / `selected ...`
- `spaces: workspace_run_view workspace=... selected=... agents=... coding_entries=...`
- `spaces: iterm session_verification_succeeded ...` is used as an optional extra confirmation path for iTerm2 focus checks

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
