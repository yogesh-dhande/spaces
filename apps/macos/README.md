# Muxy macOS App

`Muxy` is the macOS app and `mx` is the companion CLI for managing projects, workspaces, windows, and agent activity.

## Read This With
- [spec.md](/Users/yogesh/projects/muxy/apps/macos/spec.md): UX and product behavior
- [architecture.md](/Users/yogesh/projects/muxy/apps/macos/docs/architecture.md): modules, data model, and runtime structure
- [../../README.md](/Users/yogesh/projects/muxy/README.md): repo-wide development and deploy workflows
- `apps/web/app/docs`: user-facing docs and CLI reference

## Requirements
- macOS 14+
- `yabai`
- iTerm2
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

Useful commands:

```bash
apps/macos/.build/debug/Muxy
apps/macos/.build/debug/mx --help
apps/macos/.build/debug/mx workspace list --all
```

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
