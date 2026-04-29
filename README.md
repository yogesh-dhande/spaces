# Muxy Monorepo

Muxy is a macOS workspace orchestrator with a Swift app and CLI (`muxy`) plus a static Next.js marketing and docs site.

## Repo Layout
- `apps/macos`: macOS app, `muxy` CLI, Swift sources, tests, product docs
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
scripts/format-staged-swift.sh
scripts/lint.sh
scripts/coverage.sh
```

`scripts/lint.sh` auto-formats `apps/macos/Sources` and `apps/macos/Tests` with `swift format` before running lint so formatter-driven warnings do not drown out real issues.

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

The pre-commit hook currently does three things:
- formats staged macOS Swift source and test files with `swift format`
- runs `scripts/lint.sh`, which also auto-formats the full macOS Swift source and test tree before linting
- runs `scripts/coverage.sh`

Pull requests are checked in GitHub Actions with [`.github/workflows/pr-checks.yml`](/Users/yogesh/projects/muxy/.github/workflows/pr-checks.yml), which runs the same Swift lint/build/coverage flow plus the static website build.

Useful local entry points:

```bash
apps/macos/.build/debug/MuxyApp
apps/macos/.build/debug/muxy --help
```

### Website
Run from `apps/web`:

```bash
npm run dev
npm run build
```

## Deploys

### macOS release
Publish macOS releases to GitHub Releases with:

```bash
scripts/release-and-deploy.sh <version>
```

This workflow:
- builds the release binaries
- code-signs the app and CLI
- creates the DMG
- optionally notarizes it when `NOTARIZE=1`
- publishes the DMG to GitHub Releases

Important environment variables:
- `CODESIGN_IDENTITY`
- `NOTARIZE`
- `APPLE_ID`
- `TEAM_ID`
- `APP_PASSWORD`
- `GH_TOKEN`

### Website deploy
Firebase Hosting deploys from [`.github/workflows/firebase-hosting-merge.yml`](/Users/yogesh/projects/muxy/.github/workflows/firebase-hosting-merge.yml:1). It builds `apps/web` and deploys the static export on pushes to `main` that touch the site or on manual dispatch.

The workflow authenticates with GitHub OIDC through Google Workload Identity Federation, then deploys through the Firebase Hosting REST API. This avoids `firebase-tools` service-account-key assumptions while keeping the deploy keyless.

Required GitHub secret:
- `FIREBASE_PROJECT_ID`
- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_SERVICE_ACCOUNT_EMAIL`

## Additional Readmes
- `apps/macos/README.md` covers day-to-day development for the macOS app and CLI.
- `apps/web/README.md` covers the website-specific workflow.
