#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_ROOT="$APP_ROOT/.local/ghosttykit"
XCFRAMEWORK_ROOT="${1:-${SPACES_GHOSTTYKIT_XCFRAMEWORK:-$LOCAL_ROOT/GhosttyKit.xcframework}}"

HEADER_PATH="$XCFRAMEWORK_ROOT/macos-arm64_x86_64/Headers/ghostty.h"
MACOS_LIB_DIR="$XCFRAMEWORK_ROOT/macos-arm64_x86_64"
LIBRARY_PATH=""
REQUIRED_EXPORTS=(
    "ghostty_surface_set_data_callback"
    "ghostty_surface_send_input_raw"
)

if [[ ! -d "$XCFRAMEWORK_ROOT" ]]; then
    echo "GhosttyKit.xcframework not found: $XCFRAMEWORK_ROOT" >&2
    exit 1
fi

if [[ ! -f "$HEADER_PATH" ]]; then
    echo "GhosttyKit header missing: $HEADER_PATH" >&2
    exit 1
fi

if [[ -f "$MACOS_LIB_DIR/libghostty-internal.a" ]]; then
    LIBRARY_PATH="$MACOS_LIB_DIR/libghostty-internal.a"
elif [[ -f "$MACOS_LIB_DIR/ghostty-internal.a" ]]; then
    LIBRARY_PATH="$MACOS_LIB_DIR/ghostty-internal.a"
else
    echo "GhosttyKit static library missing under: $MACOS_LIB_DIR" >&2
    exit 1
fi

for export_name in "${REQUIRED_EXPORTS[@]}"; do
    if ! rg -q "\\b${export_name}\\b" "$HEADER_PATH"; then
        echo "Missing GhosttyKit declaration for ${export_name} in $HEADER_PATH" >&2
        exit 1
    fi

    if ! nm -gU "$LIBRARY_PATH" | rg -q "_${export_name}$"; then
        echo "Missing GhosttyKit export for ${export_name} in $LIBRARY_PATH" >&2
        exit 1
    fi
done

echo "Verified GhosttyKit additive PTY I/O exports in $XCFRAMEWORK_ROOT"
