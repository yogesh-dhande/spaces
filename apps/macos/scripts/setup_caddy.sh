#!/usr/bin/env bash
# Fetch a pinned, universal (arm64+x86_64) Caddy binary into apps/macos/.local/caddy/caddy.
#
# Caddy (Apache-2.0) is the workspace service router. We download the official prebuilt release
# binaries for both architectures, verify them against the release's published checksums, and
# lipo-create a single universal binary so the app bundle is architecture-agnostic. The binary is
# not committed; this mirrors the Ghostty artifact fetch so a fresh worktree can become buildable
# without vendoring a ~45 MB binary in git.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_ROOT="$APP_ROOT/.local"
CADDY_ROOT="$LOCAL_ROOT/caddy"
OUTPUT="$CADDY_ROOT/caddy"

CADDY_VERSION="${SPACES_CADDY_VERSION:-2.8.4}"
RELEASE_BASE="https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}"
CHECKSUMS_FILE="caddy_${CADDY_VERSION}_checksums.txt"

binary_has_arch() {
  local archs="$1" arch="$2"
  case " $archs " in
    *" $arch "*) return 0 ;;
    *) return 1 ;;
  esac
}

is_universal() {
  local archs
  archs="$(lipo -archs "$1" 2>/dev/null || true)"
  binary_has_arch "$archs" arm64 && binary_has_arch "$archs" x86_64
}

if [[ -x "$OUTPUT" ]] && is_universal "$OUTPUT"; then
  echo "==> Caddy already present and universal at $OUTPUT"
  exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Downloading Caddy ${CADDY_VERSION} checksums"
curl -fsSL "$RELEASE_BASE/$CHECKSUMS_FILE" -o "$WORK_DIR/$CHECKSUMS_FILE"

fetch_arch() {
  local goarch="$1" out_binary="$2"
  local archive="caddy_${CADDY_VERSION}_mac_${goarch}.tar.gz"
  echo "==> Downloading $archive"
  curl -fsSL "$RELEASE_BASE/$archive" -o "$WORK_DIR/$archive"

  echo "==> Verifying $archive checksum"
  local expected
  expected="$(grep " $archive\$" "$WORK_DIR/$CHECKSUMS_FILE" | awk '{print $1}')"
  if [[ -z "$expected" ]]; then
    echo "Error: no checksum for $archive in $CHECKSUMS_FILE" >&2
    exit 1
  fi
  local actual
  actual="$(shasum -a 512 "$WORK_DIR/$archive" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Error: checksum mismatch for $archive (expected $expected, got $actual)" >&2
    exit 1
  fi

  tar -xzf "$WORK_DIR/$archive" -C "$WORK_DIR" caddy
  mv "$WORK_DIR/caddy" "$out_binary"
}

fetch_arch arm64 "$WORK_DIR/caddy-arm64"
fetch_arch amd64 "$WORK_DIR/caddy-amd64"

mkdir -p "$CADDY_ROOT"
echo "==> Creating universal binary at $OUTPUT"
lipo -create -output "$OUTPUT" "$WORK_DIR/caddy-arm64" "$WORK_DIR/caddy-amd64"
chmod +x "$OUTPUT"

if ! is_universal "$OUTPUT"; then
  echo "Error: produced caddy binary is not universal" >&2
  exit 1
fi
echo "==> Caddy ${CADDY_VERSION} ready at $OUTPUT"
