#!/usr/bin/env bash
set -euo pipefail

# The GitHub release is the source of truth for Sparkle update artifacts, not
# the repo. apps/web/public/releases is gitignored (Firebase Hosting deploys
# replace the whole site, so committing generated artifacts would go stale),
# which means every website build must repopulate it from scratch or the
# deployed site silently loses its appcast. This runs on every build --
# merge deploy, PR preview, release, promotion, local -- so the website can
# never ship a blank/stale releases feed.
#
# One site serves two Sparkle feeds:
#   releases/appcast.xml            the stable feed, from GitHub's `latest`
#                                   release, which is the newest promoted
#                                   (non-prerelease) release.
#   releases/prerelease/appcast.xml the pre-release feed, from the newest
#                                   release of any kind.
#
# Both appcasts are served byte-for-byte as their release published them.
# publish-sparkle-appcast.sh bakes one enclosure prefix -- https://usespaces.dev/releases
# -- into every appcast when it is generated and signed, so both feeds point
# their downloads at releases/, and both feeds' zips are staged there. Serving
# the pre-release appcast from a subdirectory while its zip sits alongside the
# stable one is what makes promotion a pure GitHub flag flip: no appcast is
# ever rewritten, re-signed, or moved, and an EdDSA-signed feed is never
# mutated after the fact. When nothing is awaiting promotion the two feeds
# name the same release and the same single zip.

REPO="yogesh-dhande/spaces"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES_DIR="$REPO_ROOT/apps/web/public/releases"
PRERELEASE_DIR="$RELEASES_DIR/prerelease"

mkdir -p "$RELEASES_DIR"
find "$RELEASES_DIR" -mindepth 1 ! -name ".gitkeep" -delete
mkdir -p "$PRERELEASE_DIR"

# Downloads one release's appcast to the given path and the Sparkle zip that appcast
# names into RELEASES_DIR, where every feed's baked enclosure prefix resolves.
stage_feed() {
  local download_base="$1" appcast_path="$2" label="$3"

  if ! curl -fsSL "$download_base/appcast.xml" -o "$appcast_path"; then
    echo "Error: failed to download $download_base/appcast.xml. Does that GitHub release publish an appcast.xml asset?" >&2
    exit 1
  fi

  local enclosure_url
  enclosure_url="$(perl -0ne 'print $1 if /<enclosure\b[^>]*\burl="([^"]+)"/' "$appcast_path")"

  if [[ -z "$enclosure_url" ]]; then
    echo "Error: $appcast_path has no <enclosure url=\"...\"> entry. That GitHub release did not publish a usable appcast." >&2
    exit 1
  fi

  local zip_basename
  zip_basename="$(basename "$enclosure_url")"

  if ! curl -fsSL "$download_base/$zip_basename" -o "$RELEASES_DIR/$zip_basename"; then
    echo "Error: failed to download $download_base/$zip_basename. Does that GitHub release publish this Sparkle archive?" >&2
    exit 1
  fi

  echo "✓ Staged the $label feed at $appcast_path with $RELEASES_DIR/$zip_basename"
}

# The newest release of any kind, promoted or not. Tags are filtered to the three-component
# version form so the ghostty-artifacts-<sha> releases -- prereleases in this same repo -- and
# any other non-version tag can never be mistaken for a Spaces release. Ordering is by creation
# time, which is what "the newest candidate" means here: a patch cut after a larger version is
# the build the pre-release feed should be serving.
newest_tag="$(gh release list --repo "$REPO" --limit 200 --json tagName,createdAt,isDraft \
  --jq '[.[] | select(.isDraft | not) | select(.tagName | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))] | sort_by(.createdAt) | last | .tagName')"

if [[ -z "$newest_tag" ]]; then
  echo "Error: no Spaces release tagged v<major>.<minor>.<patch> found in $REPO; the pre-release feed has nothing to serve." >&2
  exit 1
fi

stage_feed "https://github.com/$REPO/releases/latest/download" "$RELEASES_DIR/appcast.xml" "stable"
stage_feed "https://github.com/$REPO/releases/download/$newest_tag" "$PRERELEASE_DIR/appcast.xml" "pre-release ($newest_tag)"
