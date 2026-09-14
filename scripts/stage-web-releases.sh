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
# Both appcasts are served byte-for-byte as their release published them, and
# they are the only files this stages. The Sparkle archives they name are not
# copied onto the site: each one is about 116 MB, Firebase Hosting stores every
# deployed version of the site, and carrying both zips in every version
# exhausts the Hosting storage quota and blocks deploys outright. The site
# answers a zip request with a 302 to the GitHub release asset instead, from the
# `redirects` entry in apps/web/firebase.json. That rule captures the archive
# name as well as the version and rebuilds the filename from both, because a
# destination whose every capture reference sits mid-segment is emitted
# literally: the redirect engine only substitutes captures when the destination
# names one directly after a path separator, which `/:archive-:version.zip`
# does and `/v:version/Spaces-:version.zip` alone does not.
#
# The enclosure URLs still name usespaces.dev because publish-sparkle-appcast.sh
# bakes https://usespaces.dev/releases in as the enclosure prefix when the
# appcast is generated and EdDSA-signed, and no appcast is ever rewritten,
# re-signed, or moved afterwards -- that immutability is what makes promotion a
# pure GitHub flag flip. So the URL scheme stays and the redirect is what
# resolves it. Sparkle fetches the enclosure through NSURLSession, which follows
# the redirect, and verifies the EdDSA signature over the bytes it downloaded,
# so serving them from GitHub weakens nothing.
#
# Serving the pre-release appcast from a subdirectory while both feeds' enclosure
# URLs stay in the flat releases/ directory is what keeps a single redirect rule
# covering both. When nothing is awaiting promotion the two feeds name the same
# release and the same single zip.

REPO="yogesh-dhande/spaces"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES_DIR="$REPO_ROOT/apps/web/public/releases"
PRERELEASE_DIR="$RELEASES_DIR/prerelease"

mkdir -p "$RELEASES_DIR"
find "$RELEASES_DIR" -mindepth 1 ! -name ".gitkeep" -delete
mkdir -p "$PRERELEASE_DIR"

# Downloads one release's appcast to the given path and proves that the download it advertises
# will resolve: the enclosure URL has to be the exact form apps/web/firebase.json redirects, and
# the GitHub asset that redirect targets has to exist. A feed whose download 404s is worse than a
# missing feed, because Sparkle offers the update and then fails at the last step.
stage_feed() {
  local download_base="$1" appcast_path="$2" label="$3"

  if ! curl -fsSL "$download_base/appcast.xml" -o "$appcast_path"; then
    echo "Error: failed to download $download_base/appcast.xml. Does that GitHub release publish an appcast.xml asset?" >&2
    exit 1
  fi

  local enclosure_url version
  enclosure_url="$(perl -0ne 'print $1 if /<enclosure\b[^>]*\burl="([^"]+)"/' "$appcast_path")"
  version="$(perl -0ne 'print $1 if /<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/' "$appcast_path")"

  if [[ -z "$enclosure_url" ]]; then
    echo "Error: $appcast_path has no <enclosure url=\"...\"> entry. That GitHub release did not publish a usable appcast." >&2
    exit 1
  fi

  if [[ -z "$version" ]]; then
    echo "Error: $appcast_path has no <sparkle:shortVersionString> entry, so its download cannot be matched to a release." >&2
    exit 1
  fi

  local expected_url="https://usespaces.dev/releases/Spaces-$version.zip"
  if [[ "$enclosure_url" != "$expected_url" ]]; then
    echo "Error: $appcast_path advertises $enclosure_url, but the site only redirects $expected_url. Check the enclosure prefix publish-sparkle-appcast.sh baked into that release." >&2
    exit 1
  fi

  local asset_url="https://github.com/$REPO/releases/download/v$version/Spaces-$version.zip"
  if ! curl -fsSIL -o /dev/null "$asset_url"; then
    echo "Error: $asset_url does not exist, so the site's redirect for $enclosure_url would 404. Does that GitHub release publish this Sparkle archive?" >&2
    exit 1
  fi

  echo "✓ Staged the $label feed at $appcast_path; $enclosure_url redirects to $asset_url"
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
