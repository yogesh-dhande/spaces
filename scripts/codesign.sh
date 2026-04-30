#!/usr/bin/env bash
set -euo pipefail

# Code-sign spaces binaries with a Developer ID Application certificate.
#
# Usage:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/codesign.sh <binary> [<binary2> ...]
#
# If CODESIGN_IDENTITY is unset, ad-hoc signing ("-") is used instead.

IDENTITY="${CODESIGN_IDENTITY:--}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

if [[ $# -lt 1 ]]; then
  echo "Usage: CODESIGN_IDENTITY=\"...\" $0 <binary> [<binary2> ...]" >&2
  exit 1
fi

for binary in "$@"; do
  echo "Signing $binary with identity: $IDENTITY"
  codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$binary"
done

echo "Done."
