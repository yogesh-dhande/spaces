#!/bin/bash
# Regression test: the release DMG step must succeed when the bundle holds a sparse file
# (logical size far above allocated blocks), which overflows hdiutil's default image sizing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/spaces-release-helpers.sh"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaces-create-dmg-test.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT

fail() {
    echo "create dmg sparse file test failed: $*" >&2
    exit 1
}

staging="$WORK_ROOT/staging"
mkdir -p "$staging"
echo "ordinary file" > "$staging/ordinary.txt"
mkfile -n 64m "$staging/sparse"

dmg_path="$WORK_ROOT/test.dmg"
spaces_release_create_dmg "$staging" "Spaces-dmg-test" "$dmg_path" >/dev/null \
    || fail "DMG creation failed for a staging folder containing a sparse file"
hdiutil verify "$dmg_path" >/dev/null || fail "created DMG did not verify"

echo "create dmg sparse file test passed"
