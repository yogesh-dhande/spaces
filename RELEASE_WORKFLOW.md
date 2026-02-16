# Release Workflow

Complete guide for releasing a new version of Muxy.

## Quick Release (Local)

```bash
# One command to build, package, and deploy
scripts/release-and-deploy.sh 0.2.0
```

This script will:
1. ✅ Build macOS app in release mode
2. ✅ Code sign `Muxy` and `mx` binaries
3. ✅ Create DMG installer
4. ✅ Optionally notarize (if `NOTARIZE=1`)
5. ✅ Build Next.js website
6. ✅ Deploy to Firebase Hosting (app + website)

## Prerequisites

### First Time Setup

```bash
# 1. Install Firebase CLI
npm install -g firebase-tools

# 2. Login to Firebase
firebase login

# 3. Verify you're authenticated
firebase projects:list
```

### Optional: Code Signing & Notarization

```bash
# Set environment variables for notarization
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTARIZE=1
export APPLE_ID="your@email.com"
export TEAM_ID="TEAMID"
export APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"

# Then run release
scripts/release-and-deploy.sh 0.2.0
```

## What Gets Deployed

### Firebase Hosting Structure
```
apps/web/public/
├── releases/
│   ├── appcast.xml              # No-cache (updates appear immediately)
│   ├── latest.html              # Smart redirect to latest DMG
│   └── 0.2.0/
│       └── Muxy-0.2.0.dmg      # Long cache (immutable)
└── [Next.js static site files]
```

### URLs After Deployment
- **Download**: `https://muxy-dev.web.app/releases/latest`
- **Appcast**: `https://muxy-dev.web.app/releases/appcast.xml`
- **Direct DMG**: `https://muxy-dev.web.app/releases/0.2.0/Muxy-0.2.0.dmg`
- **Website**: `https://muxy-dev.web.app/`

## Manual Steps (If Needed)

### 1. Build Only
```bash
scripts/swiftpm.sh build -c release
```

### 2. Create DMG Only
```bash
scripts/create-dmg.sh \
  apps/macos/.build/release/Muxy \
  apps/macos/.build/release/mx \
  0.2.0
```

### 3. Deploy to Firebase Only
```bash
scripts/deploy-to-firebase.sh Muxy-0.2.0.dmg 0.2.0
```

### 4. Build Next.js Only
```bash
cd apps/web
npm run build
```

## GitHub Release (Optional)

After deploying to Firebase, optionally create a GitHub release:

```bash
gh release create v0.2.0 Muxy-0.2.0.dmg \
  --title "Muxy 0.2.0" \
  --generate-notes
```

## Automated CI/CD (GitHub Actions)

Push a version tag to trigger automated release:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The GitHub Actions workflow will:
1. Build and sign binaries
2. Create DMG
3. Notarize (if secrets configured)
4. Deploy to Firebase Hosting
5. Create GitHub release

### Required GitHub Secrets
- `FIREBASE_TOKEN` - Generate with `firebase login:ci`
- `CODESIGN_IDENTITY` - Developer ID Application certificate
- `APPLE_ID`, `TEAM_ID`, `APP_PASSWORD` - For notarization

## Troubleshooting

### Firebase Authentication Failed
```bash
firebase login --reauth
```

### DMG Not Created
Check that binaries exist:
```bash
ls -la apps/macos/.build/release/
```

### Next.js Build Failed
```bash
cd apps/web
rm -rf .next out node_modules
npm install
npm run build
```

### Deployment Failed
Check Firebase project:
```bash
firebase projects:list
firebase use muxy-dev
```

## Cache Strategy

| Resource | Cache Headers | Why |
|----------|--------------|-----|
| `appcast.xml` | `no-cache, no-store, must-revalidate` | Updates must appear immediately |
| `*.dmg` files | `public, max-age=31536000, immutable` | Versioned files never change |
| `latest.html` | Default (short cache) | Redirect page, fetches appcast |

## Version Bumping

Before releasing, update version in:
- `apps/macos/Sources/streamctl/AppVersion.swift`

The release script will use this version to generate the appcast and DMG filename.
