#!/usr/bin/env bash
set -euo pipefail

# Code-sign muxy binaries with a Developer ID Application certificate.
#
# Usage:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/codesign.sh <binary> [<binary2> ...]
#
# If CODESIGN_IDENTITY is unset, ad-hoc signing ("-") is used instead.

IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ $# -lt 1 ]]; then
  echo "Usage: CODESIGN_IDENTITY=\"...\" $0 <binary> [<binary2> ...]" >&2
  exit 1
fi

for binary in "$@"; do
  echo "Signing $binary with identity: $IDENTITY"
  codesign --force --options runtime --sign "$IDENTITY" "$binary"
done

echo "Done."
