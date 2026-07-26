#!/usr/bin/env bash
set -euo pipefail

# Builds the full content of the nightly Sparkle-update Firebase Hosting site
# (spaces-nightly.web.app) into deploy/nightly/site/. This site is deliberately
# separate from usespaces.dev: it has no rewrites, so a missing asset 404s
# instead of silently returning the marketing landing page with HTTP 200 (the
# failure mode that let the stable appcast go missing without anyone noticing).

if [ $# -ne 2 ]; then
  echo "Usage: $0 <version> <release-tag>" >&2
  exit 1
fi

VERSION="$1"
RELEASE_TAG="$2"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATES_DIR="$REPO_ROOT/dist/updates/nightly"
APPCAST_SRC="$UPDATES_DIR/appcast.xml"
ZIP_NAME="Spaces-${VERSION}.zip"
ZIP_SRC="$UPDATES_DIR/$ZIP_NAME"
SITE_DIR="$REPO_ROOT/deploy/nightly/site"
RELEASE_URL="https://github.com/yogesh-dhande/spaces/releases/tag/$RELEASE_TAG"

if [[ ! -f "$APPCAST_SRC" ]]; then
  echo "Error: nightly appcast not found at $APPCAST_SRC. Run scripts/publish-sparkle-appcast.sh nightly $VERSION first." >&2
  exit 1
fi

if [[ ! -f "$ZIP_SRC" ]]; then
  echo "Error: nightly Sparkle archive not found at $ZIP_SRC. Run scripts/publish-sparkle-appcast.sh nightly $VERSION first." >&2
  exit 1
fi

rm -rf "$SITE_DIR"
mkdir -p "$SITE_DIR/releases"

cp "$APPCAST_SRC" "$SITE_DIR/releases/appcast.xml"
cp "$ZIP_SRC" "$SITE_DIR/releases/$ZIP_NAME"

cat > "$SITE_DIR/robots.txt" <<'EOF'
User-agent: *
Disallow: /
EOF

cat > "$SITE_DIR/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="robots" content="noindex, nofollow">
<title>Spaces nightly builds</title>
</head>
<body>
<h1>Spaces nightly builds</h1>
<p>Serving version $VERSION from release $RELEASE_TAG.</p>
<p>Warning: nightly builds are untested pre-release builds of main. Expect breakage.</p>
<p><a href="$RELEASE_URL">Download the DMG from the GitHub prerelease</a></p>
<p>Installing the nightly DMG switches that Mac to the nightly update channel. Installing a stable DMG switches it back.</p>
</body>
</html>
EOF

echo "✓ Staged nightly site in $SITE_DIR"
