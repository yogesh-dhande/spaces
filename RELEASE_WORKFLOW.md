# Release Workflow

Complete guide for releasing a new version of Muxy.

## Quick Release (Local)

```bash
# One command to build, package, and deploy
scripts/release-and-deploy.sh 0.2.0
```

This script will:
1. ✅ Build macOS app in release mode
2. ✅ Code sign `Muxy` and `muxy` binaries
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

Add the following to `.env` file:
```[.env]
# Set environment variables for notarization
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
NOTARIZE=1
APPLE_ID="your@email.com"
TEAM_ID="TEAMID"
APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

```bash
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
