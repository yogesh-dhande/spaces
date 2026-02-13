# spaceship monorepo

This repository is now structured to host multiple projects.

## Layout
- `apps/macos`: the `spaceship` macOS Swift app
- `apps/web`: static Next.js marketing + docs website
- `scripts`: root wrappers that delegate to `apps/macos/scripts`

## macOS app
- App docs: `apps/macos/README.md`
- Architecture: `apps/macos/docs/architecture.md`
- Spec: `apps/macos/spec.md`

## Build and test (from repo root)
```bash
scripts/swiftpm.sh build
scripts/swiftpm.sh test
scripts/lint.sh
scripts/coverage.sh
```

## Web app (from `apps/web`)
```bash
npm run dev
npm run build
```
