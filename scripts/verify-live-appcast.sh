#!/usr/bin/env bash
set -euo pipefail

# Confirms that a live Sparkle feed on usespaces.dev serves a given Spaces version and that the
# download it advertises resolves.
#
# The deploy step itself fails on a real deploy error, so this is not there to catch one. It is the
# end-to-end gate on a release: that the feed a release targets is live, and that the update it
# names can actually be downloaded. The enclosure URL points at usespaces.dev and Firebase redirects
# it to the GitHub release asset, so the check asserts the redirect hop itself -- its status and its
# exact destination -- and then that the asset that destination names exists. Asserting only that
# following the chain succeeds would pass on a broken redirect rule: the site's catch-all rewrite
# answers an unmatched path with index.html and HTTP 200, and every Mac would download that HTML
# and fail signature verification. Hosting propagation is not instant, so the version check
# retries; a cache-busting query keeps a CDN edge from answering with the pre-deploy copy.
#
# Usage: verify-live-appcast.sh <appcast-url> <version>

if [ $# -ne 2 ]; then
  echo "Usage: $0 <appcast-url> <version>" >&2
  exit 1
fi

APPCAST_URL="$1"
VERSION="$2"
REPO="yogesh-dhande/spaces"

for attempt in 1 2 3 4 5 6; do
  appcast="$(curl -fsSL "${APPCAST_URL}?cb=${GITHUB_RUN_ID:-local}-${attempt}" || true)"
  if printf '%s' "$appcast" | grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>"; then
    echo "✓ ${APPCAST_URL} serves ${VERSION}"

    enclosure_url="$(printf '%s' "$appcast" | perl -0ne 'print $1 if /<enclosure\b[^>]*\burl="([^"]+)"/')"
    if [ -z "$enclosure_url" ]; then
      echo "Error: ${APPCAST_URL} serves ${VERSION} with no <enclosure url=\"...\"> entry, so there is nothing to download." >&2
      exit 1
    fi

    expected_redirect="https://github.com/${REPO}/releases/download/v${VERSION}/Spaces-${VERSION}.zip"

    # The first hop is taken without following redirects, so the redirect itself is what is
    # asserted, and with no cache-busting query: Firebase forwards a query string onto the redirect
    # destination, and the destination has to match expected_redirect exactly. HEAD is enough,
    # because Firebase answers HEAD with the redirect.
    hop="$(curl -sS -o /dev/null -I -w '%{http_code} %{redirect_url}' "$enclosure_url")"
    hop_status="${hop%% *}"
    hop_redirect="${hop#* }"

    if [ "$hop_status" != "302" ] || [ "$hop_redirect" != "$expected_redirect" ]; then
      echo "Error: ${enclosure_url} answered ${hop_status} ${hop_redirect:-with no redirect} instead of a 302 to ${expected_redirect}, so ${APPCAST_URL} offers an update that cannot be downloaded. The site's catch-all rewrite answers every unmatched path with index.html, which is why a plain 200 here is not accepted: it means the release redirect did not match and Sparkle would download the website." >&2
      exit 1
    fi

    echo "✓ ${enclosure_url} redirects to ${expected_redirect}"

    if ! curl -fsSIL -o /dev/null "$expected_redirect"; then
      echo "Error: ${expected_redirect} does not resolve, so the redirect ${enclosure_url} serves would 404." >&2
      exit 1
    fi

    echo "✓ ${expected_redirect} resolves"
    exit 0
  fi
  echo "Attempt ${attempt}: ${APPCAST_URL} is not yet serving ${VERSION}; retrying in 10s…"
  sleep 10
done

echo "Error: ${APPCAST_URL} is not serving ${VERSION}." >&2
exit 1
