#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_ROOT="$APP_ROOT/.local/ghosttykit"
XCFRAMEWORK_ROOT="${1:-${SPACES_GHOSTTYKIT_XCFRAMEWORK:-$LOCAL_ROOT/GhosttyKit.xcframework}}"

HEADER_PATH="$XCFRAMEWORK_ROOT/macos-arm64_x86_64/Headers/ghostty.h"
MACOS_LIB_DIR="$XCFRAMEWORK_ROOT/macos-arm64_x86_64"
LIBRARY_PATH=""
REQUIRED_DECLARATIONS=(
    "ghostty_renderer_t"
    "ghostty_session_state_cb"
    "ghostty_session_t"
    "ghostty_mirror_t"
    "ghostty_render_frame_s"
    "ghostty_surface_io_backend_e"
    "ghostty_surface_receive_buffer_cb"
    "ghostty_surface_receive_resize_cb"
    "ghostty_surface_host_s"
    "ghostty_terminal_snapshot_s"
    "use_login_shell"
)
REQUIRED_SYMBOLS=(
    "ghostty_renderer_attach"
    "ghostty_renderer_detach"
    "ghostty_renderer_free"
    "ghostty_renderer_new"
    "ghostty_renderer_set_host"
    "ghostty_renderer_surface"
    "ghostty_session_config_new"
    "ghostty_session_export_render_frame"
    "ghostty_session_export_snapshot"
    "ghostty_session_foreground_pid"
    "ghostty_session_free"
    "ghostty_session_new"
    "ghostty_session_new_headless"
    "ghostty_session_process_output"
    "ghostty_session_refresh"
    "ghostty_session_send_input_raw"
    "ghostty_session_set_content_scale"
    "ghostty_session_set_data_callback"
    "ghostty_session_set_display_id"
    "ghostty_session_set_focus"
    "ghostty_session_set_grid_size"
    "ghostty_session_set_occlusion"
    "ghostty_session_set_size"
    "ghostty_session_set_state_callback"
    "ghostty_session_size"
    "ghostty_session_state_revision"
    "ghostty_session_surface"
    "ghostty_session_take_pending_state_flags"
    "ghostty_session_title"
    "ghostty_session_working_directory"
    "ghostty_mirror_apply_render_frame"
    "ghostty_mirror_free"
    "ghostty_mirror_new"
    "ghostty_mirror_set_host"
    "ghostty_mirror_surface"
    "ghostty_render_frame_free"
    "ghostty_surface_complete_clipboard_request"
    "ghostty_surface_export_snapshot"
    "ghostty_surface_free_text"
    "ghostty_surface_process_exit"
    "ghostty_surface_read_selection"
    "ghostty_surface_read_text"
    "ghostty_surface_set_data_callback"
    "ghostty_surface_set_host"
    "ghostty_surface_send_input_raw"
    "ghostty_surface_write_buffer"
    "ghostty_terminal_snapshot_free"
)

file_contains_fixed() {
    local needle="$1"
    local path="$2"
    if command -v rg >/dev/null 2>&1; then
        rg -Fq "$needle" "$path"
        return
    fi
    grep -Fq "$needle" "$path"
}

text_matches_regex() {
    local pattern="$1"
    local text="$2"
    if command -v rg >/dev/null 2>&1; then
        rg -q "$pattern" <<<"$text"
        return
    fi
    grep -Eq "$pattern" <<<"$text"
}

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

LIBRARY_SYMBOLS="$(nm -gU "$LIBRARY_PATH")"
MISSING_DECLARATIONS=()
MISSING_SYMBOLS=()

for declaration_name in "${REQUIRED_DECLARATIONS[@]}" "${REQUIRED_SYMBOLS[@]}"; do
    if ! file_contains_fixed "$declaration_name" "$HEADER_PATH"; then
        MISSING_DECLARATIONS+=("$declaration_name")
    fi
done

for symbol_name in "${REQUIRED_SYMBOLS[@]}"; do
    if ! text_matches_regex "_${symbol_name}$" "$LIBRARY_SYMBOLS"; then
        MISSING_SYMBOLS+=("$symbol_name")
    fi
done

if [[ "${#MISSING_DECLARATIONS[@]}" -gt 0 || "${#MISSING_SYMBOLS[@]}" -gt 0 ]]; then
    echo "GhosttyKit.xcframework is missing APIs required by the Spaces embedded terminal." >&2
    echo "  header:  $HEADER_PATH" >&2
    echo "  library: $LIBRARY_PATH" >&2
    if [[ "${#MISSING_DECLARATIONS[@]}" -gt 0 ]]; then
        echo "  missing declarations: ${MISSING_DECLARATIONS[*]}" >&2
    fi
    if [[ "${#MISSING_SYMBOLS[@]}" -gt 0 ]]; then
        echo "  missing exports: ${MISSING_SYMBOLS[*]}" >&2
    fi
    echo "Publish and pin a matching GhosttyKit release before running SwiftPM." >&2
    exit 1
fi

echo "Verified GhosttyKit embedded terminal API contract in $XCFRAMEWORK_ROOT"
