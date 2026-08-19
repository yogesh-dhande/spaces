#ifndef SPACES_GHOSTTYVTSHIM_H
#define SPACES_GHOSTTYVTSHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct SpacesGhosttyVtSession SpacesGhosttyVtSession;

// The keys `spaces_ghostty_vt_session_encode_key` can name. This is a Spaces-owned enum rather than
// ghostty's: `GhosttyKey` values are ordinals that shift whenever ghostty adds a key, so pinning
// callers to them would silently remap keys across a libghostty upgrade. The shim translates.
//
// Printable keys use `UNIDENTIFIED` and are carried by the call's `utf8` and `unshifted_codepoint`
// instead, which is what ghostty's encoder reads for them anyway (the control byte for a ctrl chord,
// the CSI-u code under the Kitty protocol).
typedef enum {
    SPACES_GHOSTTY_VT_KEY_UNIDENTIFIED = 0,
    SPACES_GHOSTTY_VT_KEY_ENTER = 1,
    SPACES_GHOSTTY_VT_KEY_TAB = 2,
    SPACES_GHOSTTY_VT_KEY_BACKSPACE = 3,
    SPACES_GHOSTTY_VT_KEY_ESCAPE = 4,
    SPACES_GHOSTTY_VT_KEY_ARROW_UP = 5,
    SPACES_GHOSTTY_VT_KEY_ARROW_DOWN = 6,
    SPACES_GHOSTTY_VT_KEY_ARROW_LEFT = 7,
    SPACES_GHOSTTY_VT_KEY_ARROW_RIGHT = 8,
    SPACES_GHOSTTY_VT_KEY_HOME = 9,
    SPACES_GHOSTTY_VT_KEY_END = 10,
    SPACES_GHOSTTY_VT_KEY_PAGE_UP = 11,
    SPACES_GHOSTTY_VT_KEY_PAGE_DOWN = 12,
    SPACES_GHOSTTY_VT_KEY_DELETE = 13,
    SPACES_GHOSTTY_VT_KEY_INSERT = 14,
    SPACES_GHOSTTY_VT_KEY_F1 = 15,
    SPACES_GHOSTTY_VT_KEY_F2 = 16,
    SPACES_GHOSTTY_VT_KEY_F3 = 17,
    SPACES_GHOSTTY_VT_KEY_F4 = 18,
    SPACES_GHOSTTY_VT_KEY_F5 = 19,
    SPACES_GHOSTTY_VT_KEY_F6 = 20,
    SPACES_GHOSTTY_VT_KEY_F7 = 21,
    SPACES_GHOSTTY_VT_KEY_F8 = 22,
    SPACES_GHOSTTY_VT_KEY_F9 = 23,
    SPACES_GHOSTTY_VT_KEY_F10 = 24,
    SPACES_GHOSTTY_VT_KEY_F11 = 25,
    SPACES_GHOSTTY_VT_KEY_F12 = 26,
} SpacesGhosttyVtKey;

// Modifier bits for `spaces_ghostty_vt_session_encode_key`, mirroring `GhosttyMods` for the four
// modifiers Spaces key specs carry.
enum {
    SPACES_GHOSTTY_VT_MODS_SHIFT = 1 << 0,
    SPACES_GHOSTTY_VT_MODS_CTRL = 1 << 1,
    SPACES_GHOSTTY_VT_MODS_ALT = 1 << 2,
    SPACES_GHOSTTY_VT_MODS_SUPER = 1 << 3,
};

// The mouse buttons `spaces_ghostty_vt_session_encode_mouse` can name, and the press/release actions
// it accepts. Spaces-owned for the same reason as the key enum above: ghostty's ordinals are free to
// shift across a libghostty upgrade. The values match `ghostty_input_mouse_button_e` on the macOS
// side so one wire value describes a button for both cores.
typedef enum {
    SPACES_GHOSTTY_VT_MOUSE_BUTTON_LEFT = 1,
    SPACES_GHOSTTY_VT_MOUSE_BUTTON_RIGHT = 2,
    SPACES_GHOSTTY_VT_MOUSE_BUTTON_MIDDLE = 3,
    SPACES_GHOSTTY_VT_MOUSE_BUTTON_FOUR = 4,
    SPACES_GHOSTTY_VT_MOUSE_BUTTON_FIVE = 5,
    SPACES_GHOSTTY_VT_MOUSE_BUTTON_SIX = 6,
    SPACES_GHOSTTY_VT_MOUSE_BUTTON_SEVEN = 7,
    SPACES_GHOSTTY_VT_MOUSE_BUTTON_EIGHT = 8,
    SPACES_GHOSTTY_VT_MOUSE_BUTTON_NINE = 9,
    SPACES_GHOSTTY_VT_MOUSE_BUTTON_TEN = 10,
    SPACES_GHOSTTY_VT_MOUSE_BUTTON_ELEVEN = 11,
} SpacesGhosttyVtMouseButton;

typedef enum {
    SPACES_GHOSTTY_VT_MOUSE_ACTION_PRESS = 0,
    SPACES_GHOSTTY_VT_MOUSE_ACTION_RELEASE = 1,
} SpacesGhosttyVtMouseAction;

// The most codepoints a snapshot cell's grapheme cluster can carry, base included. A cell whose
// cluster is longer (combining-mark spam, which no legitimate glyph needs) is exported as its base
// codepoint alone, which bounds both the copy the snapshot makes and the payload the render wire
// format accepts.
#define SPACES_GHOSTTY_VT_MAX_GRAPHEME_CODEPOINTS 16

typedef struct {
    uint32_t codepoint;
    uint32_t foreground_rgb;
    uint32_t background_rgb;
    uint16_t flags;
    // The cluster's codepoints beyond `codepoint` (combining marks, ZWJ members, variation selectors,
    // regional indicators). Zero and NULL for the overwhelming majority of cells, which hold a single
    // codepoint. Owned by the snapshot and released by `spaces_ghostty_vt_snapshot_free`.
    uint16_t grapheme_extra_len;
    uint32_t *grapheme_extras;
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

// A snapshot of the session's active selection. Coordinates are screen-space (row 0 = oldest
// scrollback row), matching what `spaces_ghostty_vt_session_set_selection` accepts.
typedef struct {
    // Whether the terminal currently has an active selection at all.
    bool present;
    // False when a scrollback trim garbaged one of the selection's tracked endpoint pins: the
    // terminal still reports a selection, but its coordinates have collapsed to a meaningless
    // position (typically the top-left of the active screen) rather than the original selection.
    // Meaningless (always false) whenever `present` is false.
    bool valid;
    bool rectangle;
    // Ordered so (start_y, start_x) <= (end_y, end_x). The terminal's own selection endpoints
    // preserve drag direction and may be reversed; this flattens that for callers that only need
    // the selected span, not which end the drag started from. Zeroed when `valid` is false.
    uint16_t start_x;
    uint32_t start_y;
    uint16_t end_x;
    uint32_t end_y;
} SpacesGhosttyVtSelectionState;

// One pending render scroll rect: a viewport region that scrolled by a row/column delta since the
// last `spaces_ghostty_vt_session_take_scroll_rects` call. Mirrors `GhosttyTerminalScrollRect` minus
// its leading ABI-versioning `size` field, which the shim handles internally.
typedef struct {
    uint16_t row_start;
    uint16_t row_count;
    uint16_t column_start;
    uint16_t column_count;
    int32_t delta_rows;
    int32_t delta_columns;
} SpacesGhosttyVtScrollRect;

// The Spaces terminal theme applied to a headless session's default colors, so the render frames
// a remote (Linux daemon) session streams to the client match the app's theme instead of
// libghostty-vt's built-in palette. Each color is packed 0x00RRGGBB. `palette_rgb` is the 16
// ANSI colors (0-15); the shim fills indices 16-255 with the standard xterm cube and grayscale.
// `is_dark` is kept with the palette so a live session can answer color-scheme queries from the same
// last-writer-wins appearance that supplied its colors.
typedef struct {
    uint32_t foreground_rgb;
    uint32_t background_rgb;
    uint32_t cursor_rgb;
    uint32_t palette_rgb[16];
    // The appearance these colors represent, reported to programs that query CSI ? 996 n.
    bool is_dark;
} SpacesGhosttyVtTheme;

// Upper bound on one turn's buffered OSC 52 payload. A clipboard write larger than this is dropped
// rather than buffered, so a runaway program cannot make the session's event sink grow without bound.
enum {
    SPACES_GHOSTTY_VT_MAX_CLIPBOARD_BYTES = 1 * 1024 * 1024,
};

// What the terminal's effect callbacks observed since the last drain. libghostty-vt invokes those
// callbacks synchronously inside `ghostty_terminal_vt_write`, so they only record here; the caller
// drains once per write turn and acts on the engine.
typedef struct {
    // TITLE_CHANGED fired this turn; the value is read back via `spaces_ghostty_vt_session_title`.
    // The flag is what distinguishes an explicit clear (the getter reports absent BECAUSE the program
    // emitted an empty OSC 2) from a value that was never set — the getter alone cannot say which.
    bool title_changed;
    // PWD_CHANGED fired this turn; the value is read back via `spaces_ghostty_vt_session_pwd`. Same
    // explicit-clear semantics as `title_changed`.
    bool pwd_changed;
    uint32_t bell_count;
    // The last standard-location `text/plain` write of this turn, malloc'd, NULL when none arrived.
    char *clipboard_text;
    size_t clipboard_len;
    // The program asked for the destination to be cleared (a write carrying no representations).
    bool clipboard_cleared;
    // A write was refused: over the byte cap, a non-standard destination, or no `text/plain`
    // representation.
    bool clipboard_dropped;
    // Query responses (DSR, DECRQM, color reports, XTVERSION) concatenated in emission order, malloc'd.
    char *pty_response;
    size_t pty_response_len;
} SpacesGhosttyVtSessionEvents;

// Registers the terminal's effect callbacks against this session, so subsequent writes accumulate
// events into the session's sink. Returns false when the library predates the option API or when any
// one of the registrations is refused — a session with only some of its callbacks installed silently
// loses whichever half of the contract below it did not get, so callers must treat false as fatal.
//
// Opt-in on purpose. A session that replays historical bytes — transcript rendering, scrollback for an
// ended run, trim preambles — must NEVER enable events: every bell and clipboard write the transcript
// ever carried would fire again, alerting on output the user already saw. Only a session driving a
// live PTY enables them, and only once its startup replay is complete.
bool spaces_ghostty_vt_session_enable_events(SpacesGhosttyVtSession *session);

// Moves the accumulated events out of the session and resets its sink. The caller takes ownership of
// the malloc'd buffers and must release them with `spaces_ghostty_vt_session_events_free`.
void spaces_ghostty_vt_session_drain_events(SpacesGhosttyVtSession *session, SpacesGhosttyVtSessionEvents *out_events);

// Releases the buffers a drained event record owns and zeroes it.
void spaces_ghostty_vt_session_events_free(SpacesGhosttyVtSessionEvents *events);

// `theme` is optional: pass NULL to keep libghostty-vt's built-in default palette.
SpacesGhosttyVtSession *spaces_ghostty_vt_session_new(
    uint16_t columns,
    uint16_t rows,
    // Ghostty measures scrollback in bytes, not rows.
    size_t max_scrollback,
    const SpacesGhosttyVtTheme *theme
);

void spaces_ghostty_vt_session_free(SpacesGhosttyVtSession *session);

// Re-applies a theme to an existing session (e.g. when an attaching client's light/dark appearance
// differs from the one the session was created with). Returns false when the library predates the
// color-configuration API, in which case the session keeps its current colors.
bool spaces_ghostty_vt_session_set_theme(SpacesGhosttyVtSession *session, const SpacesGhosttyVtTheme *theme);

bool spaces_ghostty_vt_session_write(
    SpacesGhosttyVtSession *session,
    const uint8_t *input,
    size_t input_len
);

// Resizes the live terminal in place to `columns` x `rows`, reflowing the primary screen's content
// (when wraparound is enabled) and preserving terminal state, modes, and scrollback. This is the
// alternative to recreating a session and replaying a preamble: it mutates the existing terminal so
// its grid and render state reflect the new size while keeping everything already written. Returns
// false when `columns` or `rows` is zero or the underlying resize fails.
bool spaces_ghostty_vt_session_resize(
    SpacesGhosttyVtSession *session,
    uint16_t columns,
    uint16_t rows
);

bool spaces_ghostty_vt_session_encode_paste(
    SpacesGhosttyVtSession *session,
    const uint8_t *input,
    size_t input_len,
    char **out_ptr,
    size_t *out_len
);

// Encodes one key press with ghostty's own key encoder, configured from this session's live terminal
// state, so the bytes match what ghostty would send: Kitty keyboard protocol sequences once the
// running program enables them, DECCKM-aware cursor keys, legacy sequences otherwise. `key` is a
// `SpacesGhosttyVtKey` and `mods` a `SPACES_GHOSTTY_VT_MODS_*` bitmask. `utf8` carries the text the key would type
// (NULL for keys that type nothing) and `unshifted_codepoint` its layout-independent codepoint;
// ghostty needs both to encode ctrl chords. The buffer is malloc'd and must be freed with
// `spaces_ghostty_vt_free_buffer`. A key that encodes to nothing succeeds with `*out_len == 0` and a
// NULL `*out_ptr`.
bool spaces_ghostty_vt_session_encode_key(
    SpacesGhosttyVtSession *session,
    uint32_t key,
    uint16_t mods,
    const char *utf8,
    size_t utf8_len,
    uint32_t unshifted_codepoint,
    char **out_ptr,
    size_t *out_len
);

// Encodes one mouse button press or release with ghostty's own mouse encoder, configured from this
// session's live terminal state, so the bytes match the tracking mode and format the running program
// asked for (X10 through any-event tracking; X10, UTF-8, SGR, urxvt, or SGR-pixels output). `action`
// is a `SpacesGhosttyVtMouseAction`, `button` a `SpacesGhosttyVtMouseButton`, and `mods` a
// `SPACES_GHOSTTY_VT_MODS_*` bitmask. The position is given in cells rather than pixels because a
// headless session has no rendered geometry; SGR-pixels consequently reports cell-granular pixel
// coordinates. The buffer is malloc'd and must be freed with `spaces_ghostty_vt_free_buffer`. An
// event the terminal's current mode does not report succeeds with `*out_len == 0` and a NULL
// `*out_ptr`.
bool spaces_ghostty_vt_session_encode_mouse(
    SpacesGhosttyVtSession *session,
    uint8_t action,
    uint8_t button,
    uint16_t mods,
    uint16_t cell_column,
    uint16_t cell_row,
    char **out_ptr,
    size_t *out_len
);

// Reports whether the session's terminal currently has any mouse tracking mode enabled. Returns
// false if the underlying query fails.
bool spaces_ghostty_vt_session_mouse_tracking_active(
    SpacesGhosttyVtSession *session,
    bool *out_active
);

bool spaces_ghostty_vt_session_copy_snapshot(
    SpacesGhosttyVtSession *session,
    SpacesGhosttyVtSnapshot *out_snapshot
);

// Erases a faint-styled text run that begins at the visible cursor. The caller must first establish
// that the replay belongs to an identified coding-agent session; faint style alone does not identify
// a suggestion. The run may continue only across Ghostty-marked soft wraps. This mutates only the
// supplied replay session.
bool spaces_ghostty_vt_session_erase_faint_run_at_cursor(SpacesGhosttyVtSession *session);

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

// Reads the current scrollbar (total row count, viewport offset, viewport row count) without
// scrolling. Unlike `spaces_ghostty_vt_session_scroll_viewport_with_info`, which only reports the
// scrollbar as a side effect of an actual delta, this is a pure query: a per-frame snapshot exporter
// calls it to fill in scrollbar state even when nothing scrolled this frame. Returns false only when
// the session/terminal is missing or the underlying query fails.
bool spaces_ghostty_vt_session_scrollbar(
    SpacesGhosttyVtSession *session,
    SpacesGhosttyVtScrollbar *out
);

bool spaces_ghostty_vt_session_format_plain(
    SpacesGhosttyVtSession *session,
    char **out_ptr,
    size_t *out_len
);

// Sets the session's active selection from two screen-space endpoints (row 0 = oldest scrollback
// row). Endpoints are clamped into the terminal's current screen extent (rows against the
// scrollbar's total row count, columns against the session's column count) before being resolved,
// so a caller tracking a drag that has moved past the edge of live content does not have to clamp
// itself. The terminal copies the endpoints into terminal-owned tracked state immediately, so the
// selection stays anchored to its cells across further writes until scrollback trimming discards
// the page an endpoint points into (see `spaces_ghostty_vt_session_selection_state`). Returns false
// only when the session/terminal is missing or the underlying set call fails.
bool spaces_ghostty_vt_session_set_selection(
    SpacesGhosttyVtSession *session,
    uint16_t start_x,
    uint32_t start_y,
    uint16_t end_x,
    uint32_t end_y,
    bool rectangle
);

// Clears the session's active selection. A no-op when there is none.
void spaces_ghostty_vt_session_clear_selection(SpacesGhosttyVtSession *session);

// Copies the terminal's active selection as plain text (soft wraps unwrapped, trailing whitespace
// on non-blank lines trimmed, matching Ghostty's own copy semantics) into a malloc'd buffer that
// must be freed with `spaces_ghostty_vt_session_selection_text_free`. Returns NULL (with `*out_len`
// left at 0, when `out_len` is non-NULL) when there is no active selection or the underlying format
// call fails.
char *spaces_ghostty_vt_session_selection_text_copy(SpacesGhosttyVtSession *session, size_t *out_len);

// Releases a buffer returned by `spaces_ghostty_vt_session_selection_text_copy`.
void spaces_ghostty_vt_session_selection_text_free(char *text);

// Reads the session's active selection. `out->present` is false when there is no selection at all
// (every other field is zeroed). When `present` is true, `out->valid` reports whether both tracked
// endpoint pins are still healthy: false means a scrollback trim garbaged one of them, so the
// coordinates in `out` are meaningless and left zero-filled rather than a stale-but-sensical
// position. Returns false only when the session/terminal is missing or an unexpected API failure
// occurs; a present-but-invalid selection is reported through `out`, not through the return value.
bool spaces_ghostty_vt_session_selection_state(SpacesGhosttyVtSession *session, SpacesGhosttyVtSelectionState *out);

// Copies out and clears the terminal's pending render scroll rects: viewport regions that scrolled
// by a row/column delta since the last call to this function. This is a render hint for consumers
// that want to shift already-rendered content instead of redrawing it from scratch; it is not
// authoritative and a consumer must still be able to render from the terminal's current state
// directly. Copies up to `capacity` rects into `out`, in the order they were recorded, and
// unconditionally clears the pending buffer, so a second call immediately after returns 0. If more
// rects accumulated than the terminal's internal buffer can track, they are discarded entirely,
// `*overflowed` (when non-NULL) is set to true, and this returns 0; a caller that observes overflow
// should treat its render state as needing a full redraw rather than an incremental scroll. Returns
// 0 (with `*overflowed` left false) when the session/terminal is missing.
size_t spaces_ghostty_vt_session_take_scroll_rects(
    SpacesGhosttyVtSession *session,
    SpacesGhosttyVtScrollRect *out,
    size_t capacity,
    bool *overflowed
);

// Serializes the session's current persistent terminal state as a self-contained escape-sequence
// preamble, so a replay that begins at the preamble restores the terminal state the bytes before it had
// established (alt-screen, mouse reporting, bracketed paste, DECCKM, Kitty keyboard flags, scrolling
// region, charset designations, cursor position) and repaints the active screen's visible grid (cell
// text, colors, and style flags) so cells the following bytes never redraw are not lost. The buffer is
// malloc'd and must be freed with `spaces_ghostty_vt_free_buffer`. Returns false (and leaves `*out_ptr`
// NULL) on failure.
bool spaces_ghostty_vt_session_state_preamble(
    SpacesGhosttyVtSession *session,
    char **out_ptr,
    size_t *out_len
);

// Reports whether a DEC private (ansi=false) or ANSI (ansi=true) mode is currently set on the
// session's terminal. Returns false if the underlying query fails. The submit path reads bracketed
// paste (2004) through this to decide whether a submit's carriage return needs temporal separation
// from its unframed text; trim tests use it to assert that a preamble round-trips terminal modes.
bool spaces_ghostty_vt_session_mode_is_set(
    SpacesGhosttyVtSession *session,
    uint16_t mode_value,
    bool ansi,
    bool *out_set
);

// Copies the terminal title the session's escape sequences last set (OSC 0/2) into a malloc'd
// buffer that must be freed with `spaces_ghostty_vt_free_buffer`. Returns false (and leaves
// `*out_ptr` NULL) when no title is set — the VT layer reports an unset and an explicitly cleared
// title identically, as an empty string.
bool spaces_ghostty_vt_session_title(
    SpacesGhosttyVtSession *session,
    char **out_ptr,
    size_t *out_len
);

// Copies the working directory the session's escape sequences last reported (OSC 7) into a malloc'd
// buffer that must be freed with `spaces_ghostty_vt_free_buffer`. The value is the RAW OSC 7
// payload (e.g. `file://host/path`); the VT layer stores it without parsing, so the caller decodes
// and host-validates the URI. Returns false (and leaves `*out_ptr` NULL) when none is set.
bool spaces_ghostty_vt_session_pwd(
    SpacesGhosttyVtSession *session,
    char **out_ptr,
    size_t *out_len
);

// Test-support: reports the session's current Kitty keyboard protocol flags. Returns false if the
// underlying query fails (e.g. the library predates the getter).
bool spaces_ghostty_vt_session_kitty_keyboard_flags(
    SpacesGhosttyVtSession *session,
    uint8_t *out_flags
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
