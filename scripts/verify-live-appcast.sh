#!/usr/bin/env bash
set -euo pipefail

# Confirms that a live Sparkle feed on usespaces.dev serves a given Spaces version.
#
# This is the gate on every deploy that publishes a release, so the deploy step itself is allowed
# to fail: `firebase deploy` to the live channel answers HTTP 400 "is the current active version"
# when the built site is byte-identical to what is already deployed, which is a no-op rather than
# a real failure. What matters is only whether the feed the release targets is live, and that is
# what this asserts. Hosting propagation is not instant, so the check retries; a cache-busting
# query keeps a CDN edge from answering with the pre-deploy copy.
#
# Usage: verify-live-appcast.sh <appcast-url> <version>

if [ $# -ne 2 ]; then
  echo "Usage: $0 <appcast-url> <version>" >&2
  exit 1
fi

APPCAST_URL="$1"
VERSION="$2"

for attempt in 1 2 3 4 5 6; do
  appcast="$(curl -fsSL "${APPCAST_URL}?cb=${GITHUB_RUN_ID:-local}-${attempt}" || true)"
  if printf '%s' "$appcast" | grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>"; then
    echo "✓ ${APPCAST_URL} serves ${VERSION}"
    exit 0
  fi
  echo "Attempt ${attempt}: ${APPCAST_URL} is not yet serving ${VERSION}; retrying in 10s…"
  sleep 10
done

echo "Error: ${APPCAST_URL} is not serving ${VERSION}." >&2
exit 1
