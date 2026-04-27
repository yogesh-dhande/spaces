# Muxy macOS App

`Muxy` is the macOS app and `mx` is the companion CLI for workspace import, metadata updates, idempotent workspace launch, and agent activity.

## Read This With
- [spec.md](/Users/yogesh/projects/muxy/apps/macos/spec.md): UX and product behavior
- [architecture.md](/Users/yogesh/projects/muxy/apps/macos/docs/architecture.md): modules, data model, and runtime structure
- [../../README.md](/Users/yogesh/projects/muxy/README.md): repo-wide development and deploy workflows
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

Useful commands:

```bash
apps/macos/.build/debug/Muxy
apps/macos/.build/debug/mx --help
apps/macos/.build/debug/mxe2e --help
apps/macos/.build/debug/mx workspace import --title "debug" --tooltip "Local debug session"
apps/macos/.build/debug/mx workspace update --tooltip "Ready for review"
apps/macos/.build/debug/mx workspace up --restart
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
  --record-video /tmp/muxy-real-e2e.mp4 \
  --pause-transitions
```

The recorder follows the current main display. `--capture-device` remains accepted as a no-op compatibility flag for older invocations.

This suite is manual by design. It drives the real app, `mx`, `yabai`, Chrome, and the configured terminal host in an interactive macOS session instead of XCTest.

Primary coverage includes:
- adding and archiving a workspace
- overriding workspace settings after creation
- launch, stop, restart, and dead-process recovery
- iTerm2 and Ghostty default terminal coverage
- extra user-added Chrome and terminal tabs
- workspace-detail numbered focus shortcuts
- forward/back workspace window cycling
- multi-workspace focus and cycling isolation

The suite also emits performance metrics in milliseconds for the main window-focus and cycle paths, using the app's debug timing logs for the same shortcut and cycling flows previously profiled by `scripts/profile-window-focus.sh`. The final summary prints both the pass/fail case list and the collected timing samples, so this suite is the primary replacement for that standalone focus-profiling script during development.

The manual suite depends on a small set of debug-log lines from the app and CLI helpers. Treat these as test contracts when changing debug logging:
- `muxy: perf metric=...`
- `muxy: workspace_detail_ipc selecting ...` / `selected ...`
- `muxy: workspace_run_view workspace=... selected=... agents=... coding_entries=...`
- `muxy: iterm session_verification_succeeded ...` is used as an optional extra confirmation path for iTerm2 focus checks

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
scripts/release-and-deploy.sh <version>
```

That script builds the release binaries, signs them, creates the DMG, optionally notarizes it, builds the website, and publishes the release assets.
