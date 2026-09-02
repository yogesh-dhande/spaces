#!/usr/bin/env bash
set -euo pipefail

# Generates and EdDSA-signs the Sparkle appcast for one Spaces release. Every release publishes
# exactly one appcast, carrying one enclosure prefix baked in at signing time; the website serves
# that same file as both the stable and the pre-release feed (see scripts/stage-web-releases.sh),
# so promotion never has to rewrite or re-sign it.

if [ $# -ne 1 ]; then
  echo "Usage: $0 <version>" >&2
  exit 1
fi

VERSION="$1"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE_PATH="$REPO_ROOT/dist/releases/$VERSION/Spaces-${VERSION}.zip"
UPDATES_DIR="$REPO_ROOT/dist/updates"
APPCAST_TOOL="$REPO_ROOT/apps/macos/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
APPCAST_PATH="$UPDATES_DIR/appcast.xml"

: "${SPARKLE_PRIVATE_ED_KEY:?Set SPARKLE_PRIVATE_ED_KEY to the private Sparkle EdDSA key.}"
: "${SPARKLE_DOWNLOAD_URL_PREFIX:=https://usespaces.dev/releases}"
export SPARKLE_DOWNLOAD_URL_PREFIX

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "Error: Sparkle archive not found at $ARCHIVE_PATH" >&2
  exit 1
fi

if [[ ! -x "$APPCAST_TOOL" ]]; then
  echo "Error: generate_appcast not found at $APPCAST_TOOL. Run scripts/swiftpm.sh build first." >&2
  exit 1
fi

mkdir -p "$UPDATES_DIR"
cp "$ARCHIVE_PATH" "$UPDATES_DIR/"

archive_basename="Spaces-${VERSION}"
for extension in html md txt; do
  notes_path="$REPO_ROOT/dist/releases/$VERSION/${archive_basename}.${extension}"
  if [[ -f "$notes_path" ]]; then
    cp "$notes_path" "$UPDATES_DIR/"
  fi
done

generate_args=(
  --ed-key-file -
  --download-url-prefix "$SPARKLE_DOWNLOAD_URL_PREFIX"
)

if [[ -n "${SPARKLE_RELEASE_NOTES_URL_PREFIX:-}" ]]; then
  generate_args+=(--release-notes-url-prefix "$SPARKLE_RELEASE_NOTES_URL_PREFIX")
fi
if [[ -n "${SPARKLE_FULL_RELEASE_NOTES_URL:-}" ]]; then
  generate_args+=(--full-release-notes-url "$SPARKLE_FULL_RELEASE_NOTES_URL")
fi
if [[ -n "${SPARKLE_LINK:-}" ]]; then
  generate_args+=(--link "$SPARKLE_LINK")
fi

printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$APPCAST_TOOL" "${generate_args[@]}" "$UPDATES_DIR"

# generate_appcast reuses existing items when re-running a release. Normalize
# enclosure URLs so retries cannot preserve a stale path from an older feed.
perl -0pi -e '
  my $prefix = $ENV{SPARKLE_DOWNLOAD_URL_PREFIX};
  $prefix =~ s{/+$}{};
  s{(<enclosure\b[^>]*\burl=")([^"]+)(")}{
    my ($start, $url, $end) = ($1, $2, $3);
    my $normalized = $url =~ m{^\Q$prefix/\E}
      ? $url
      : $prefix . "/" . ($url =~ m{/([^/?#]+)$} ? $1 : $url);
    $start . $normalized . $end;
  }ge;
' "$APPCAST_PATH"

if ! perl -0ne '
  my $prefix = $ENV{SPARKLE_DOWNLOAD_URL_PREFIX};
  $prefix =~ s{/+$}{};
  my $invalid = 0;
  while (/<enclosure\b[^>]*\burl="([^"]+)"/g) {
    if (index($1, "$prefix/") != 0) {
      $invalid = 1;
      last;
    }
  }
  END { exit($invalid) }
' "$APPCAST_PATH"; then
  echo "Error: appcast contains enclosure URLs outside $SPARKLE_DOWNLOAD_URL_PREFIX" >&2
  exit 1
fi

echo "✓ Generated Sparkle updates in $UPDATES_DIR"
