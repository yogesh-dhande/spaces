#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <dmg-file> <version>"
  exit 1
fi

DMG_FILE="$1"
VERSION="$2"
BUCKET="muxy-dev"

# Authenticate with Firebase (use service account if provided, otherwise use local gcloud auth)
if [ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ]; then
  echo "Using FIREBASE_SERVICE_ACCOUNT for authentication"
  SERVICE_ACCOUNT_FILE=$(mktemp)
  trap "rm -f '$SERVICE_ACCOUNT_FILE'" EXIT
  echo "$FIREBASE_SERVICE_ACCOUNT" > "$SERVICE_ACCOUNT_FILE"
  gcloud auth activate-service-account --key-file="$SERVICE_ACCOUNT_FILE"
else
  echo "Using local gcloud credentials"
  # Verify gcloud is authenticated
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
    echo "Error: No active gcloud authentication found. Run 'gcloud auth login' first." >&2
    exit 1
  fi
fi

# Upload DMG with long cache (versioned files never change)
gsutil -h "Cache-Control:public, max-age=31536000, immutable" \
  cp "$DMG_FILE" "gs://$BUCKET/releases/$VERSION/$DMG_FILE"

# Set public read access
gsutil acl ch -u AllUsers:R "gs://$BUCKET/releases/$VERSION/$DMG_FILE"

echo "✓ Uploaded $DMG_FILE to Firebase Storage"
echo "  URL: https://storage.googleapis.com/$BUCKET/releases/$VERSION/$DMG_FILE"
