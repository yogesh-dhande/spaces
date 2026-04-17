# Muxy Monorepo

Muxy is a macOS workspace orchestrator with a Swift app and CLI (`mx`), plus a static Next.js marketing and docs site.

## Repo Layout
- `apps/macos`: macOS app, `mx` CLI, Swift sources, tests, product docs
- `apps/web`: static marketing site and user-facing docs
- `scripts`: root wrappers for build, test, coverage, release, and deploy workflows

## Documentation Map
- `README.md`: repository development and deploy workflows
- `AGENTS.md`: how coding agents should write, verify, and document changes
- `apps/macos/spec.md`: expected product behavior and UX
- `apps/macos/docs/architecture.md`: data model, module boundaries, and implementation structure
- `apps/web/app/docs`: user-facing product and CLI documentation

## Development

### macOS app and CLI
Run from the repository root:

```bash
scripts/swiftpm.sh build
scripts/swiftpm.sh test --parallel
scripts/lint.sh
scripts/coverage.sh
```

Useful local entry points:

```bash
apps/macos/.build/debug/Muxy
apps/macos/.build/debug/mx --help
```

### Website
Run from `apps/web`:

```bash
npm run dev
npm run build
```

## Deploys

### macOS release
Use the single release workflow:

```bash
scripts/release-and-deploy.sh <version>
```

This workflow:
- builds the release binaries
- code-signs the app and CLI
- creates the DMG
- optionally notarizes it when `NOTARIZE=1`
- builds the website
- deploys the website and appcast assets

Important environment variables:
- `CODESIGN_IDENTITY`
- `NOTARIZE`
- `APPLE_ID`
- `TEAM_ID`
- `APP_PASSWORD`
- `FIREBASE_TOKEN` or `FIREBASE_SERVICE_ACCOUNT`

### Website-only deploy
If the DMG and release assets already exist, build the site in `apps/web` and deploy with:

```bash
scripts/deploy-to-firebase.sh <dmg-path> <version>
```

## Additional Readmes
- `apps/macos/README.md` covers day-to-day development for the macOS app and CLI.
- `apps/web/README.md` covers the website-specific workflow.
