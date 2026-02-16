#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <version> <dmg-file>"
  exit 1
fi

VERSION="$1"
DMG_FILE="$2"
BUCKET="muxy-dev"
APPCAST_FILE="appcast.xml"

# Authenticate with Firebase (use service account if provided, otherwise use local gcloud auth)
if [ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ]; then
  echo "Using FIREBASE_SERVICE_ACCOUNT for authentication"
else
  echo "Using local gcloud credentials"
  # Verify gcloud is authenticated
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
    echo "Error: No active gcloud authentication found. Run 'gcloud auth login' first." >&2
    exit 1
  fi
fi

# Calculate file size and signature
FILE_SIZE=$(stat -f%z "$DMG_FILE")
SIGNATURE=$(openssl dgst -sha256 -binary "$DMG_FILE" | openssl base64)

# Generate appcast.xml
cat > "$APPCAST_FILE" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Muxy</title>
    <link>https://storage.googleapis.com/$BUCKET/appcast.xml</link>
    <description>Muxy updates</description>
    <language>en</language>
    <item>
      <title>Muxy $VERSION</title>
      <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S %z")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <enclosure
        url="https://storage.googleapis.com/$BUCKET/releases/$VERSION/$DMG_FILE"
        length="$FILE_SIZE"
        type="application/octet-stream"
        sparkle:edSignature="$SIGNATURE"
      />
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
EOF

# Authenticate if service account provided
if [ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ]; then
  SERVICE_ACCOUNT_FILE=$(mktemp)
  trap "rm -f '$SERVICE_ACCOUNT_FILE'" EXIT
  echo "$FIREBASE_SERVICE_ACCOUNT" > "$SERVICE_ACCOUNT_FILE"
  gcloud auth activate-service-account --key-file="$SERVICE_ACCOUNT_FILE"
fi

# Upload appcast with no cache (updates should appear quickly)
gsutil -h "Cache-Control:no-cache, no-store, must-revalidate" \
  -h "Pragma:no-cache" \
  -h "Expires:0" \
  cp "$APPCAST_FILE" "gs://$BUCKET/appcast.xml"

# Set public read access
gsutil acl ch -u AllUsers:R "gs://$BUCKET/appcast.xml"

echo "✓ Generated and uploaded appcast.xml"
echo "  URL: https://storage.googleapis.com/$BUCKET/appcast.xml"
