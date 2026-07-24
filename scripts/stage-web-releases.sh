#!/usr/bin/env bash
set -euo pipefail

# The GitHub release is the source of truth for Sparkle update artifacts, not
# the repo. apps/web/public/releases is gitignored (Firebase Hosting deploys
# replace the whole site, so committing generated artifacts would go stale),
# which means every website build must repopulate it from scratch or the
# deployed site silently loses its appcast. This runs on every build --
# merge deploy, PR preview, release, local -- so the website can never ship
# a blank/stale releases feed.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES_DIR="$REPO_ROOT/apps/web/public/releases"
LATEST_BASE="https://github.com/yogesh-dhande/spaces/releases/latest/download"
APPCAST_PATH="$RELEASES_DIR/appcast.xml"

mkdir -p "$RELEASES_DIR"
find "$RELEASES_DIR" -mindepth 1 ! -name ".gitkeep" -delete

if ! curl -fsSL "$LATEST_BASE/appcast.xml" -o "$APPCAST_PATH"; then
  echo "Error: failed to download $LATEST_BASE/appcast.xml. Does the latest GitHub release publish an appcast.xml asset?" >&2
  exit 1
fi

enclosure_url="$(perl -0ne 'print $1 if /<enclosure\b[^>]*\burl="([^"]+)"/' "$APPCAST_PATH")"

if [[ -z "$enclosure_url" ]]; then
  echo "Error: $APPCAST_PATH has no <enclosure url=\"...\"> entry. The latest GitHub release did not publish a usable appcast." >&2
  exit 1
fi

zip_basename="$(basename "$enclosure_url")"
zip_path="$RELEASES_DIR/$zip_basename"

if ! curl -fsSL "$LATEST_BASE/$zip_basename" -o "$zip_path"; then
  echo "Error: failed to download $LATEST_BASE/$zip_basename. Does the latest GitHub release publish this Sparkle archive?" >&2
  exit 1
fi

echo "✓ Staged $APPCAST_PATH and $zip_path from the latest GitHub release"
