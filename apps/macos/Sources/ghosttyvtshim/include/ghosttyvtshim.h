#ifndef SPACES_GHOSTTYVTSHIM_H
#define SPACES_GHOSTTYVTSHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct SpacesGhosttyVtSession SpacesGhosttyVtSession;

typedef struct {
    uint32_t codepoint;
    uint32_t foreground_rgb;
    uint32_t background_rgb;
    uint16_t flags;
} SpacesGhosttyVtSnapshotCell;

typedef struct {
    uint16_t columns;
    uint16_t rows;
    uint16_t cursor_column;
    uint16_t cursor_row;
    bool cursor_visible;
    uint32_t default_foreground_rgb;
    uint32_t default_background_rgb;
    size_t cell_count;
    SpacesGhosttyVtSnapshotCell *cells;
} SpacesGhosttyVtSnapshot;

typedef struct {
    uint64_t total;
    uint64_t offset;
    uint64_t len;
} SpacesGhosttyVtScrollbar;

// The Spaces terminal theme applied to a headless session's default colors, so the render frames
// a remote (Linux daemon) session streams to the client match the app's theme instead of
// libghostty-vt's built-in palette. Each color is packed 0x00RRGGBB. `palette_rgb` is the 16
// ANSI colors (0-15); the shim fills indices 16-255 with the standard xterm cube and grayscale.
typedef struct {
    uint32_t foreground_rgb;
    uint32_t background_rgb;
    uint32_t cursor_rgb;
    uint32_t palette_rgb[16];
} SpacesGhosttyVtTheme;

// `theme` is optional: pass NULL to keep libghostty-vt's built-in default palette.
SpacesGhosttyVtSession *spaces_ghostty_vt_session_new(
    uint16_t columns,
    uint16_t rows,
    // Ghostty measures scrollback in bytes, not rows.
    size_t max_scrollback,
    const SpacesGhosttyVtTheme *theme
);

void spaces_ghostty_vt_session_free(SpacesGhosttyVtSession *session);

bool spaces_ghostty_vt_session_write(
    SpacesGhosttyVtSession *session,
    const uint8_t *input,
    size_t input_len
);

bool spaces_ghostty_vt_session_copy_snapshot(
    SpacesGhosttyVtSession *session,
    SpacesGhosttyVtSnapshot *out_snapshot
);

bool spaces_ghostty_vt_session_scroll_viewport(
    SpacesGhosttyVtSession *session,
    intptr_t delta_rows
);

bool spaces_ghostty_vt_session_scroll_viewport_with_info(
    SpacesGhosttyVtSession *session,
    intptr_t delta_rows,
    SpacesGhosttyVtScrollbar *out_before,
    SpacesGhosttyVtScrollbar *out_after
);

bool spaces_ghostty_vt_session_format_plain(
    SpacesGhosttyVtSession *session,
    char **out_ptr,
    size_t *out_len
);

void spaces_ghostty_vt_snapshot_free(SpacesGhosttyVtSnapshot *snapshot);

bool spaces_ghostty_vt_render_plain(
    const uint8_t *input,
    size_t input_len,
    uint16_t columns,
    uint16_t rows,
    // Ghostty measures scrollback in bytes, not rows.
    size_t max_scrollback,
    char **out_ptr,
    size_t *out_len
);

void spaces_ghostty_vt_free_buffer(char *ptr);

#endif
