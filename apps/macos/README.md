# Spaces macOS App

`Spaces` is the macOS app and `spaces` is the companion CLI for `import`, `update`, `start`, `restart`, `open`, and `signal`.

## Read This With
- [spec.md](/Users/yogesh/projects/spaces/apps/macos/spec.md): UX and product behavior
- [architecture.md](/Users/yogesh/projects/spaces/apps/macos/docs/architecture.md): modules, data model, and runtime structure
- [../../README.md](/Users/yogesh/projects/spaces/README.md): repo-wide development and deploy workflows
- `apps/web/app/docs`: user-facing docs and CLI reference

## Requirements
- macOS 14+
- `yabai`
- `tmux`
- iTerm2 or Ghostty
- Google Chrome
- Accessibility permission for the app stack that needs to focus windows

The app handles missing prerequisites through its in-app setup flow. The exact onboarding behavior is specified in `spec.md`.

## Local Development
Run from the repository root:

```bash
scripts/swiftpm.sh build
scripts/swiftpm.sh test --parallel
scripts/lint.sh
scripts/coverage.sh
```

`scripts/lint.sh` auto-formats `apps/macos/Sources` and `apps/macos/Tests` with `swift format` before linting, which keeps formatter noise out of the diagnostics.

Persistence notes:
- Migration safety backups are written to `~/.spaces/backups/` before any on-disk schema upgrade and retained as a rolling set of the newest 10 snapshots.
- Any schema change in `workspacecore` must ship with an ordered migration step and test coverage for the upgrade path.

Useful commands:

```bash
apps/macos/.build/debug/SpacesApp
apps/macos/.build/debug/spaces --help
apps/macos/.build/debug/spacese2e --help
apps/macos/.build/debug/spaces import --title "debug" --notes "Local debug session"
apps/macos/.build/debug/spaces update --notes "Ready for review"
apps/macos/.build/debug/spaces restart
apps/macos/Tests/e2e_real_system.sh
```

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

Primary coverage includes:
- adding and archiving a workspace
- overriding workspace settings after creation
- launch, stop, restart, and dead-process recovery
- iTerm2 and Ghostty default terminal coverage
- extra user-added Chrome and terminal tabs
- workspace-detail numbered focus shortcuts
- forward/back workspace window cycling
- multi-workspace focus and cycling isolation

The suite also emits performance metrics in milliseconds for the main window-focus and cycle paths, using the app's debug timing logs for the same shortcut and cycling flows covered by the standalone focus-profiling workflow. The final summary prints both the pass/fail case list and the collected timing samples, so this suite is the primary path for focus profiling during development.

Repeated real-system profiling also covers:
- main window visibility toggles from inactive and active app states
- command palette toggles from inactive and active app states

When the suite finishes with recorded metrics, it appends aggregated metric history to `apps/macos/.artifacts/real-system-profiles/metrics-history.csv` and regenerates `apps/macos/.artifacts/real-system-profiles/report.html` with `best`, `previous`, and `latest` comparisons for each tracked metric. Metric names use `start.action.end`, such as `browser_untracked_tab.cli_window_focus.browser_tracked_tab`, and the start and end tokens refer to concrete visible surfaces rather than app-level state. Scenario context like terminal host and workspace scope is stored alongside each row. Dirty worktrees are recorded alongside clean runs by pairing the base `HEAD` commit with a worktree fingerprint, so the report can distinguish two different uncommitted snapshots on the same branch.

The manual suite depends on a small set of debug-log lines from the app and CLI helpers. Treat these as test contracts when changing debug logging:
- `spaces: perf metric=...`
- `spaces: workspace_detail_ipc selecting ...` / `selected ...`
- `spaces: workspace_run_view workspace=... selected=... agents=... coding_entries=...`
- `spaces: iterm session_verification_succeeded ...` is used as an optional extra confirmation path for iTerm2 focus checks

## Scope of This README
This file intentionally does not duplicate:
- CLI command semantics
- UX requirements
- database schema details
- workspace lifecycle internals
- update or focus-path implementation details

Those belong in the spec, architecture doc, or website docs.

## Release
Build and deploy a release from the repository root with:

```bash
scripts/release-and-deploy.sh <version> [build-number]
```

That script syncs the shared version metadata, builds the release binaries, signs them, creates a signed manual-download DMG plus a Sparkle update zip, verifies the final DMG and bundled apps, refreshes the stable appcast, stages Sparkle files into the website static assets, and publishes the DMG to GitHub Releases.

GitHub Actions release publishing requires these repository secrets:
- `CODESIGN_IDENTITY`
- `CODESIGN_CERTIFICATE_P12`
- `CODESIGN_CERTIFICATE_PASSWORD`
- `SPARKLE_PUBLIC_ED_KEY`
- `SPARKLE_PRIVATE_ED_KEY`
- `FIREBASE_SERVICE_ACCOUNT_SPACES_A1814`
