#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <dmg-file> <version>"
  exit 1
fi

DMG_FILE="$1"
VERSION="$2"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES_DIR="$REPO_ROOT/apps/web/public/releases"

# Verify DMG exists (it should already be in public/releases/<version>/)
if [ ! -f "$DMG_FILE" ]; then
  echo "Error: DMG file not found at $DMG_FILE" >&2
  exit 1
fi
echo "✓ DMG found at $DMG_FILE"

# Generate appcast.xml
FILE_SIZE=$(stat -f%z "$DMG_FILE")
SIGNATURE=$(openssl dgst -sha256 -binary "$DMG_FILE" | openssl base64)
DMG_FILENAME=$(basename "$DMG_FILE")

cat > "$RELEASES_DIR/appcast.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Muxy</title>
    <link>https://muxy-dev.web.app/releases/appcast.xml</link>
    <description>Muxy updates</description>
    <language>en</language>
    <item>
      <title>Muxy $VERSION</title>
      <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S %z")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <enclosure
        url="https://muxy-dev.web.app/releases/$VERSION/$DMG_FILENAME"
        length="$FILE_SIZE"
        type="application/octet-stream"
        sparkle:edSignature="$SIGNATURE"
      />
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
EOF

# Generate latest.html redirect (without GitHub fallback)
cat > "$RELEASES_DIR/latest.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Downloading Muxy...</title>
  <script>
    // Fetch appcast and redirect to latest DMG
    fetch('/releases/appcast.xml')
      .then(response => response.text())
      .then(xml => {
        const urlMatch = xml.match(/url="([^"]*\.dmg)"/);
        if (urlMatch && urlMatch[1]) {
          window.location.href = urlMatch[1];
        } else {
          document.body.innerHTML = '<p>Error: Could not find download URL</p>';
        }
      })
      .catch(err => {
        document.body.innerHTML = '<p>Error loading release information</p>';
      });
  </script>
</head>
<body>
  <p>Redirecting to download...</p>
</body>
</html>
EOF

echo "✓ Generated appcast.xml and latest.html"

# Copy releases directory to out/ for deployment
if [ -d "$REPO_ROOT/apps/web/public/releases" ]; then
  echo "Copying releases to out/ for deployment..."
  mkdir -p "$REPO_ROOT/apps/web/out/releases"
  rsync -av "$REPO_ROOT/apps/web/public/releases/" "$REPO_ROOT/apps/web/out/releases/"
  echo "✓ Releases copied to out/"
fi

# Deploy to Firebase Hosting
if [ -n "${FIREBASE_TOKEN:-}" ]; then
  echo "Using FIREBASE_TOKEN for authentication"
  firebase deploy --only hosting --token "$FIREBASE_TOKEN"
elif [ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ]; then
  echo "Using FIREBASE_SERVICE_ACCOUNT for authentication"
  SERVICE_ACCOUNT_FILE=$(mktemp)
  trap "rm -f '$SERVICE_ACCOUNT_FILE'" EXIT
  echo "$FIREBASE_SERVICE_ACCOUNT" > "$SERVICE_ACCOUNT_FILE"
  export GOOGLE_APPLICATION_CREDENTIALS="$SERVICE_ACCOUNT_FILE"
  firebase deploy --only hosting
else
  echo "Using local Firebase credentials"
  # Verify firebase is authenticated
  if ! firebase projects:list >/dev/null 2>&1; then
    echo "Error: Not logged into Firebase. Run 'firebase login' first." >&2
    exit 1
  fi
  firebase deploy --only hosting
fi

echo "✓ Deployed to Firebase Hosting"
echo "  Appcast: https://muxy-dev.web.app/releases/appcast.xml"
echo "  Latest:  https://muxy-dev.web.app/releases/latest"
echo "  DMG:     https://muxy-dev.web.app/releases/$VERSION/$(basename "$DMG_FILE")"
