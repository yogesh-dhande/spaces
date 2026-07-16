#include "ghosttyvtshim.h"

#include <dlfcn.h>
#include <ghostty/vt.h>
#include <limits.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef GhosttyResult (*GhosttyTerminalNewFn)(const GhosttyAllocator *, GhosttyTerminal *, GhosttyTerminalOptions);
typedef void (*GhosttyTerminalFreeFn)(GhosttyTerminal);
typedef void (*GhosttyTerminalVtWriteFn)(GhosttyTerminal, const uint8_t *, size_t);
typedef void (*GhosttyTerminalScrollViewportFn)(GhosttyTerminal, GhosttyTerminalScrollViewport);
typedef GhosttyResult (*GhosttyTerminalGetFn)(GhosttyTerminal, GhosttyTerminalData, void *);
typedef GhosttyResult (*GhosttyTerminalModeGetFn)(GhosttyTerminal, GhosttyMode, bool *);
typedef GhosttyResult (*GhosttyTerminalSetFn)(GhosttyTerminal, GhosttyTerminalOption, const void *);
typedef GhosttyResult (*GhosttyPasteEncodeFn)(char *, size_t, bool, char *, size_t, size_t *);
typedef GhosttyResult (*GhosttyFormatterTerminalNewFn)(
    const GhosttyAllocator *,
    GhosttyFormatter *,
    GhosttyTerminal,
    GhosttyFormatterTerminalOptions
);
typedef GhosttyResult (*GhosttyFormatterFormatAllocFn)(GhosttyFormatter, const GhosttyAllocator *, uint8_t **, size_t *);
typedef void (*GhosttyFormatterFreeFn)(GhosttyFormatter);
typedef void (*GhosttyFreeFn)(const GhosttyAllocator *, uint8_t *, size_t);
typedef GhosttyResult (*GhosttyRenderStateNewFn)(const GhosttyAllocator *, GhosttyRenderState *);
typedef void (*GhosttyRenderStateFreeFn)(GhosttyRenderState);
typedef GhosttyResult (*GhosttyRenderStateUpdateFn)(GhosttyRenderState, GhosttyTerminal);
typedef GhosttyResult (*GhosttyRenderStateGetFn)(GhosttyRenderState, GhosttyRenderStateData, void *);
typedef GhosttyResult (*GhosttyRenderStateColorsGetFn)(GhosttyRenderState, GhosttyRenderStateColors *);
typedef GhosttyResult (*GhosttyRenderStateRowIteratorNewFn)(const GhosttyAllocator *, GhosttyRenderStateRowIterator *);
typedef void (*GhosttyRenderStateRowIteratorFreeFn)(GhosttyRenderStateRowIterator);
typedef bool (*GhosttyRenderStateRowIteratorNextFn)(GhosttyRenderStateRowIterator);
typedef GhosttyResult (*GhosttyRenderStateRowGetFn)(GhosttyRenderStateRowIterator, GhosttyRenderStateRowData, void *);
typedef GhosttyResult (*GhosttyRenderStateRowCellsNewFn)(const GhosttyAllocator *, GhosttyRenderStateRowCells *);
typedef void (*GhosttyRenderStateRowCellsFreeFn)(GhosttyRenderStateRowCells);
typedef bool (*GhosttyRenderStateRowCellsNextFn)(GhosttyRenderStateRowCells);
typedef GhosttyResult (*GhosttyRenderStateRowCellsGetFn)(GhosttyRenderStateRowCells, GhosttyRenderStateRowCellsData, void *);
typedef GhosttyResult (*GhosttyCellGetFn)(GhosttyCell, GhosttyCellData, void *);
typedef GhosttyResult (*GhosttyRowGetFn)(GhosttyRow, GhosttyRowData, void *);

typedef struct {
    void *handle;
    GhosttyTerminalNewFn terminal_new;
    GhosttyTerminalFreeFn terminal_free;
    GhosttyTerminalVtWriteFn terminal_vt_write;
    GhosttyTerminalScrollViewportFn terminal_scroll_viewport;
    GhosttyTerminalGetFn terminal_get;
    GhosttyTerminalModeGetFn terminal_mode_get;
    GhosttyTerminalSetFn terminal_set;
    GhosttyPasteEncodeFn paste_encode;
    GhosttyFormatterTerminalNewFn formatter_terminal_new;
    GhosttyFormatterFormatAllocFn formatter_format_alloc;
    GhosttyFormatterFreeFn formatter_free;
    GhosttyFreeFn ghostty_free;
    GhosttyRenderStateNewFn render_state_new;
    GhosttyRenderStateFreeFn render_state_free;
    GhosttyRenderStateUpdateFn render_state_update;
    GhosttyRenderStateGetFn render_state_get;
    GhosttyRenderStateColorsGetFn render_state_colors_get;
    GhosttyRenderStateRowIteratorNewFn row_iterator_new;
    GhosttyRenderStateRowIteratorFreeFn row_iterator_free;
    GhosttyRenderStateRowIteratorNextFn row_iterator_next;
    GhosttyRenderStateRowGetFn row_get;
    GhosttyRenderStateRowCellsNewFn row_cells_new;
    GhosttyRenderStateRowCellsFreeFn row_cells_free;
    GhosttyRenderStateRowCellsNextFn row_cells_next;
    GhosttyRenderStateRowCellsGetFn row_cells_get;
    GhosttyCellGetFn cell_get;
    GhosttyRowGetFn grid_row_get;
} SpacesGhosttyVtSymbols;

struct SpacesGhosttyVtSession {
    SpacesGhosttyVtSymbols symbols;
    GhosttyTerminal terminal;
    GhosttyRenderState render_state;
    GhosttyRenderStateRowIterator row_iterator;
    GhosttyRenderStateRowCells row_cells;
};

void spaces_ghostty_vt_session_free(SpacesGhosttyVtSession *session);

enum {
    SPACES_GHOSTTY_VT_FLAG_BOLD = 1 << 0,
    SPACES_GHOSTTY_VT_FLAG_ITALIC = 1 << 1,
    SPACES_GHOSTTY_VT_FLAG_FAINT = 1 << 2,
    SPACES_GHOSTTY_VT_FLAG_INVERSE = 1 << 4,
    SPACES_GHOSTTY_VT_FLAG_INVISIBLE = 1 << 5,
    SPACES_GHOSTTY_VT_FLAG_STRIKE = 1 << 6,
    SPACES_GHOSTTY_VT_FLAG_UNDERLINE = 1 << 7,
    SPACES_GHOSTTY_VT_FLAG_SPACER = 1 << 10,
};

static void *spaces_ghostty_vt_dlopen_path(const char *path) {
    if (path == NULL || path[0] == '\0') return NULL;
    return dlopen(path, RTLD_NOW | RTLD_LOCAL);
}

static void *spaces_ghostty_vt_dlopen_in_directory(const char *directory) {
    if (directory == NULL || directory[0] == '\0') return NULL;
    const char *names[] = {
#if defined(__APPLE__)
        "libghostty-vt.dylib",
        "libghostty-vt.0.dylib",
        "libghostty-vt.0.1.0.dylib",
#else
        "libghostty-vt.so",
        "libghostty-vt.so.0",
        "libghostty-vt.so.0.1.0",
#endif
        NULL,
    };

    for (size_t i = 0; names[i] != NULL; i++) {
        char candidate[PATH_MAX];
        int written = snprintf(candidate, sizeof(candidate), "%s/%s", directory, names[i]);
        if (written < 0 || (size_t)written >= sizeof(candidate)) continue;
        void *handle = spaces_ghostty_vt_dlopen_path(candidate);
        if (handle != NULL) return handle;
    }

    return NULL;
}

static bool spaces_ghostty_vt_parent_directory(char *path) {
    if (path == NULL) return false;
    size_t length = strlen(path);
    while (length > 1 && path[length - 1] == '/') {
        path[length - 1] = '\0';
        length--;
    }

    char *slash = strrchr(path, '/');
    if (slash == NULL) return false;
    if (slash == path) {
        path[1] = '\0';
    } else {
        *slash = '\0';
    }
    return true;
}

static bool spaces_ghostty_vt_current_executable_path(char *buffer, size_t buffer_size) {
    if (buffer == NULL || buffer_size == 0) return false;
#if defined(__APPLE__)
    uint32_t executable_path_size = (uint32_t)buffer_size;
    return _NSGetExecutablePath(buffer, &executable_path_size) == 0;
#elif defined(__linux__)
    ssize_t count = readlink("/proc/self/exe", buffer, buffer_size - 1);
    if (count < 0 || (size_t)count >= buffer_size) return false;
    buffer[count] = '\0';
    return true;
#else
    return false;
#endif
}

static void *spaces_ghostty_vt_dlopen_near_executable(void) {
    char executable_path[PATH_MAX];
    void *handle = NULL;

    if (spaces_ghostty_vt_current_executable_path(executable_path, sizeof(executable_path))) {
        char resolved_path[PATH_MAX];
        const char *source_path = executable_path;
        if (realpath(executable_path, resolved_path) != NULL) source_path = resolved_path;

        char executable_directory[PATH_MAX];
        int written = snprintf(executable_directory, sizeof(executable_directory), "%s", source_path);
        if (written >= 0 && (size_t)written < sizeof(executable_directory) && spaces_ghostty_vt_parent_directory(executable_directory)) {
            handle = spaces_ghostty_vt_dlopen_in_directory(executable_directory);
            if (handle == NULL) {
                char framework_directory[PATH_MAX];
                written = snprintf(framework_directory, sizeof(framework_directory), "%s/../Frameworks", executable_directory);
                if (written >= 0 && (size_t)written < sizeof(framework_directory)) {
                    handle = spaces_ghostty_vt_dlopen_in_directory(framework_directory);
                }
            }
        }
    }

    return handle;
}

static bool spaces_ghostty_vt_load_symbols(SpacesGhosttyVtSymbols *symbols) {
    if (symbols == NULL) return false;
    memset(symbols, 0, sizeof(*symbols));

    void *handle = NULL;
    const char *env_path = getenv("SPACES_GHOSTTY_VT_DYLIB_PATH");
    if (env_path != NULL && env_path[0] != '\0') {
        handle = spaces_ghostty_vt_dlopen_path(env_path);
    }

    if (handle == NULL) {
        handle = spaces_ghostty_vt_dlopen_near_executable();
    }

    if (handle == NULL) {
        const char *cwd_candidates[] = {
#if defined(__APPLE__)
            "apps/macos/.local/ghosttyvt/lib/libghostty-vt.dylib",
            ".local/ghosttyvt/lib/libghostty-vt.dylib",
#else
            "apps/macos/.local/ghosttyvt/lib/libghostty-vt.so",
            ".local/ghosttyvt/lib/libghostty-vt.so",
#endif
            NULL,
        };
        for (size_t i = 0; cwd_candidates[i] != NULL; i++) {
            handle = dlopen(cwd_candidates[i], RTLD_NOW | RTLD_LOCAL);
            if (handle != NULL) break;
        }
    }

    if (handle == NULL) {
        char executable_path[PATH_MAX];
        if (spaces_ghostty_vt_current_executable_path(executable_path, sizeof(executable_path))) {
            char resolved_path[PATH_MAX];
            if (realpath(executable_path, resolved_path) != NULL) {
                char candidate[PATH_MAX];
                size_t length = strlen(resolved_path);
                for (int depth = 0; depth < 8 && length > 1 && handle == NULL; depth++) {
                    while (length > 1 && resolved_path[length - 1] != '/') length--;
                    if (length > 1) resolved_path[length - 1] = '\0';
                    snprintf(
                        candidate,
                        sizeof(candidate),
#if defined(__APPLE__)
                        "%s/apps/macos/.local/ghosttyvt/lib/libghostty-vt.dylib",
#else
                        "%s/apps/macos/.local/ghosttyvt/lib/libghostty-vt.so",
#endif
                        resolved_path
                    );
                    handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL);
                    if (handle != NULL) break;
                    snprintf(
                        candidate,
                        sizeof(candidate),
#if defined(__APPLE__)
                        "%s/.local/ghosttyvt/lib/libghostty-vt.dylib",
#else
                        "%s/.local/ghosttyvt/lib/libghostty-vt.so",
#endif
                        resolved_path
                    );
                    handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL);
                }
            }
        }
    }

    if (handle == NULL) {
#if defined(__APPLE__)
        handle = dlopen("libghostty-vt.dylib", RTLD_NOW | RTLD_LOCAL);
#else
        handle = dlopen("libghostty-vt.so", RTLD_NOW | RTLD_LOCAL);
#endif
    }

    if (handle == NULL) {
#if defined(__APPLE__)
        handle = dlopen("libghostty-vt.0.dylib", RTLD_NOW | RTLD_LOCAL);
#else
        handle = dlopen("libghostty-vt.so.0", RTLD_NOW | RTLD_LOCAL);
#endif
    }

    if (handle == NULL) return false;

    symbols->handle = handle;
    symbols->terminal_new = (GhosttyTerminalNewFn)dlsym(handle, "ghostty_terminal_new");
    symbols->terminal_free = (GhosttyTerminalFreeFn)dlsym(handle, "ghostty_terminal_free");
    symbols->terminal_vt_write = (GhosttyTerminalVtWriteFn)dlsym(handle, "ghostty_terminal_vt_write");
    symbols->terminal_scroll_viewport = (GhosttyTerminalScrollViewportFn)dlsym(handle, "ghostty_terminal_scroll_viewport");
    symbols->terminal_get = (GhosttyTerminalGetFn)dlsym(handle, "ghostty_terminal_get");
    symbols->terminal_mode_get = (GhosttyTerminalModeGetFn)dlsym(handle, "ghostty_terminal_mode_get");
    // Optional: present in libghostty-vt builds that expose default-color configuration. Kept out
    // of the required-symbol check below so an older library still loads (theming is skipped).
    symbols->terminal_set = (GhosttyTerminalSetFn)dlsym(handle, "ghostty_terminal_set");
    symbols->paste_encode = (GhosttyPasteEncodeFn)dlsym(handle, "ghostty_paste_encode");
    symbols->formatter_terminal_new = (GhosttyFormatterTerminalNewFn)dlsym(handle, "ghostty_formatter_terminal_new");
    symbols->formatter_format_alloc = (GhosttyFormatterFormatAllocFn)dlsym(handle, "ghostty_formatter_format_alloc");
    symbols->formatter_free = (GhosttyFormatterFreeFn)dlsym(handle, "ghostty_formatter_free");
    symbols->ghostty_free = (GhosttyFreeFn)dlsym(handle, "ghostty_free");
    symbols->render_state_new = (GhosttyRenderStateNewFn)dlsym(handle, "ghostty_render_state_new");
    symbols->render_state_free = (GhosttyRenderStateFreeFn)dlsym(handle, "ghostty_render_state_free");
    symbols->render_state_update = (GhosttyRenderStateUpdateFn)dlsym(handle, "ghostty_render_state_update");
    symbols->render_state_get = (GhosttyRenderStateGetFn)dlsym(handle, "ghostty_render_state_get");
    symbols->render_state_colors_get = (GhosttyRenderStateColorsGetFn)dlsym(handle, "ghostty_render_state_colors_get");
    symbols->row_iterator_new = (GhosttyRenderStateRowIteratorNewFn)dlsym(handle, "ghostty_render_state_row_iterator_new");
    symbols->row_iterator_free = (GhosttyRenderStateRowIteratorFreeFn)dlsym(handle, "ghostty_render_state_row_iterator_free");
    symbols->row_iterator_next = (GhosttyRenderStateRowIteratorNextFn)dlsym(handle, "ghostty_render_state_row_iterator_next");
    symbols->row_get = (GhosttyRenderStateRowGetFn)dlsym(handle, "ghostty_render_state_row_get");
    symbols->row_cells_new = (GhosttyRenderStateRowCellsNewFn)dlsym(handle, "ghostty_render_state_row_cells_new");
    symbols->row_cells_free = (GhosttyRenderStateRowCellsFreeFn)dlsym(handle, "ghostty_render_state_row_cells_free");
    symbols->row_cells_next = (GhosttyRenderStateRowCellsNextFn)dlsym(handle, "ghostty_render_state_row_cells_next");
    symbols->row_cells_get = (GhosttyRenderStateRowCellsGetFn)dlsym(handle, "ghostty_render_state_row_cells_get");
    symbols->cell_get = (GhosttyCellGetFn)dlsym(handle, "ghostty_cell_get");
    symbols->grid_row_get = (GhosttyRowGetFn)dlsym(handle, "ghostty_row_get");

    if (
        symbols->terminal_new == NULL ||
        symbols->terminal_free == NULL ||
        symbols->terminal_vt_write == NULL ||
        symbols->terminal_scroll_viewport == NULL ||
        symbols->terminal_get == NULL ||
        symbols->terminal_mode_get == NULL ||
        symbols->paste_encode == NULL ||
        symbols->formatter_terminal_new == NULL ||
        symbols->formatter_format_alloc == NULL ||
        symbols->formatter_free == NULL ||
        symbols->ghostty_free == NULL ||
        symbols->render_state_new == NULL ||
        symbols->render_state_free == NULL ||
        symbols->render_state_update == NULL ||
        symbols->render_state_get == NULL ||
        symbols->render_state_colors_get == NULL ||
        symbols->row_iterator_new == NULL ||
        symbols->row_iterator_free == NULL ||
        symbols->row_iterator_next == NULL ||
        symbols->row_get == NULL ||
        symbols->row_cells_new == NULL ||
        symbols->row_cells_free == NULL ||
        symbols->row_cells_next == NULL ||
        symbols->row_cells_get == NULL ||
        symbols->cell_get == NULL ||
        symbols->grid_row_get == NULL
    ) {
        dlclose(handle);
        memset(symbols, 0, sizeof(*symbols));
        return false;
    }

    return true;
}

static void spaces_ghostty_vt_unload_symbols(SpacesGhosttyVtSymbols *symbols) {
    if (symbols == NULL || symbols->handle == NULL) return;
    dlclose(symbols->handle);
    memset(symbols, 0, sizeof(*symbols));
}

static uint32_t spaces_ghostty_vt_pack_rgb(GhosttyColorRgb color) {
    return ((uint32_t)color.r << 16) | ((uint32_t)color.g << 8) | (uint32_t)color.b;
}

static GhosttyColorRgb spaces_ghostty_vt_unpack_rgb(uint32_t packed) {
    GhosttyColorRgb color = {
        .r = (uint8_t)((packed >> 16) & 0xFF),
        .g = (uint8_t)((packed >> 8) & 0xFF),
        .b = (uint8_t)(packed & 0xFF),
    };
    return color;
}

// Builds a full 256-color palette from the theme's 16 ANSI colors: indices 0-15 come from the
// theme, and 16-255 use the standard xterm 6x6x6 color cube (16-231) and 24-step grayscale ramp
// (232-255), so themed ANSI output and default 256-color output stay consistent.
static void spaces_ghostty_vt_build_palette_256(GhosttyColorRgb out[256], const uint32_t ansi16[16]) {
    for (size_t i = 0; i < 16; i++) out[i] = spaces_ghostty_vt_unpack_rgb(ansi16[i]);
    for (size_t i = 0; i < 216; i++) {
        size_t r = i / 36;
        size_t g = (i / 6) % 6;
        size_t b = i % 6;
        out[16 + i].r = (uint8_t)(r == 0 ? 0 : 55 + r * 40);
        out[16 + i].g = (uint8_t)(g == 0 ? 0 : 55 + g * 40);
        out[16 + i].b = (uint8_t)(b == 0 ? 0 : 55 + b * 40);
    }
    for (size_t i = 0; i < 24; i++) {
        uint8_t level = (uint8_t)(8 + i * 10);
        out[232 + i].r = level;
        out[232 + i].g = level;
        out[232 + i].b = level;
    }
}

// Applies the Spaces theme to a freshly created terminal's default colors via ghostty_terminal_set.
// A no-op when the library predates the color-configuration API (terminal_set unresolved).
static void spaces_ghostty_vt_apply_theme(SpacesGhosttyVtSession *session, const SpacesGhosttyVtTheme *theme) {
    if (session == NULL || theme == NULL || session->symbols.terminal_set == NULL) return;
    GhosttyColorRgb foreground = spaces_ghostty_vt_unpack_rgb(theme->foreground_rgb);
    GhosttyColorRgb background = spaces_ghostty_vt_unpack_rgb(theme->background_rgb);
    GhosttyColorRgb cursor = spaces_ghostty_vt_unpack_rgb(theme->cursor_rgb);
    GhosttyColorRgb palette[256];
    spaces_ghostty_vt_build_palette_256(palette, theme->palette_rgb);
    session->symbols.terminal_set(session->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground);
    session->symbols.terminal_set(session->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background);
    session->symbols.terminal_set(session->terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor);
    session->symbols.terminal_set(session->terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette);
}

static void spaces_ghostty_vt_snapshot_reset(SpacesGhosttyVtSnapshot *snapshot) {
    if (snapshot == NULL) return;
    if (snapshot->cells != NULL) free(snapshot->cells);
    memset(snapshot, 0, sizeof(*snapshot));
}

static bool spaces_ghostty_vt_format_plain_for_terminal(
    const SpacesGhosttyVtSymbols *symbols,
    GhosttyTerminal terminal,
    char **out_ptr,
    size_t *out_len
) {
    if (symbols == NULL || terminal == NULL || out_ptr == NULL || out_len == NULL) return false;

    *out_ptr = NULL;
    *out_len = 0;

    GhosttyFormatter formatter = NULL;
    GhosttyFormatterTerminalOptions formatter_options = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
    formatter_options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    formatter_options.trim = true;
    if (symbols->formatter_terminal_new(NULL, &formatter, terminal, formatter_options) != GHOSTTY_SUCCESS) {
        return false;
    }

    uint8_t *formatted = NULL;
    size_t formatted_len = 0;
    if (symbols->formatter_format_alloc(formatter, NULL, &formatted, &formatted_len) != GHOSTTY_SUCCESS) {
        symbols->formatter_free(formatter);
        return false;
    }

    char *result = (char *)malloc(formatted_len + 1);
    if (result == NULL) {
        symbols->ghostty_free(NULL, formatted, formatted_len);
        symbols->formatter_free(formatter);
        return false;
    }

    if (formatted_len > 0) memcpy(result, formatted, formatted_len);
    result[formatted_len] = '\0';

    symbols->ghostty_free(NULL, formatted, formatted_len);
    symbols->formatter_free(formatter);

    *out_ptr = result;
    *out_len = formatted_len;
    return true;
}

static uint16_t spaces_ghostty_vt_flags_for_style(const GhosttyStyle *style, GhosttyCellWide wide) {
    uint16_t flags = 0;
    if (style != NULL) {
        if (style->bold) flags |= SPACES_GHOSTTY_VT_FLAG_BOLD;
        if (style->italic) flags |= SPACES_GHOSTTY_VT_FLAG_ITALIC;
        if (style->faint) flags |= SPACES_GHOSTTY_VT_FLAG_FAINT;
        if (style->inverse) flags |= SPACES_GHOSTTY_VT_FLAG_INVERSE;
        if (style->invisible) flags |= SPACES_GHOSTTY_VT_FLAG_INVISIBLE;
        if (style->strikethrough) flags |= SPACES_GHOSTTY_VT_FLAG_STRIKE;
        if (style->underline != 0) flags |= SPACES_GHOSTTY_VT_FLAG_UNDERLINE;
    }
    if (wide == GHOSTTY_CELL_WIDE_SPACER_HEAD || wide == GHOSTTY_CELL_WIDE_SPACER_TAIL) {
        flags |= SPACES_GHOSTTY_VT_FLAG_SPACER;
    }
    return flags;
}

static void spaces_ghostty_vt_fill_default_cells(
    SpacesGhosttyVtSnapshotCell *cells,
    size_t start,
    size_t end,
    uint32_t foreground_rgb,
    uint32_t background_rgb
) {
    if (cells == NULL || end <= start) return;
    for (size_t index = start; index < end; index++) {
        cells[index].codepoint = 0;
        cells[index].foreground_rgb = foreground_rgb;
        cells[index].background_rgb = background_rgb;
        cells[index].flags = 0;
    }
}

SpacesGhosttyVtSession *spaces_ghostty_vt_session_new(
    uint16_t columns, uint16_t rows, size_t max_scrollback, const SpacesGhosttyVtTheme *theme
) {
    if (columns == 0 || rows == 0) return NULL;

    SpacesGhosttyVtSession *session = (SpacesGhosttyVtSession *)calloc(1, sizeof(SpacesGhosttyVtSession));
    if (session == NULL) return NULL;

    if (!spaces_ghostty_vt_load_symbols(&session->symbols)) {
        free(session);
        return NULL;
    }

    GhosttyTerminalOptions terminal_options = {
        .cols = columns,
        .rows = rows,
        .max_scrollback = max_scrollback,
    };
    if (session->symbols.terminal_new(NULL, &session->terminal, terminal_options) != GHOSTTY_SUCCESS) {
        spaces_ghostty_vt_session_free(session);
        return NULL;
    }

    if (session->symbols.render_state_new(NULL, &session->render_state) != GHOSTTY_SUCCESS) {
        spaces_ghostty_vt_session_free(session);
        return NULL;
    }

    if (session->symbols.row_iterator_new(NULL, &session->row_iterator) != GHOSTTY_SUCCESS) {
        spaces_ghostty_vt_session_free(session);
        return NULL;
    }

    if (session->symbols.row_cells_new(NULL, &session->row_cells) != GHOSTTY_SUCCESS) {
        spaces_ghostty_vt_session_free(session);
        return NULL;
    }

    spaces_ghostty_vt_apply_theme(session, theme);

    return session;
}

bool spaces_ghostty_vt_session_set_theme(SpacesGhosttyVtSession *session, const SpacesGhosttyVtTheme *theme) {
    if (session == NULL || theme == NULL || session->symbols.terminal_set == NULL) return false;
    spaces_ghostty_vt_apply_theme(session, theme);
    return true;
}

void spaces_ghostty_vt_session_free(SpacesGhosttyVtSession *session) {
    if (session == NULL) return;

    if (session->row_cells != NULL && session->symbols.row_cells_free != NULL) {
        session->symbols.row_cells_free(session->row_cells);
    }
    if (session->row_iterator != NULL && session->symbols.row_iterator_free != NULL) {
        session->symbols.row_iterator_free(session->row_iterator);
    }
    if (session->render_state != NULL && session->symbols.render_state_free != NULL) {
        session->symbols.render_state_free(session->render_state);
    }
    if (session->terminal != NULL && session->symbols.terminal_free != NULL) {
        session->symbols.terminal_free(session->terminal);
    }

    spaces_ghostty_vt_unload_symbols(&session->symbols);
    free(session);
}

bool spaces_ghostty_vt_session_write(SpacesGhosttyVtSession *session, const uint8_t *input, size_t input_len) {
    if (session == NULL || session->terminal == NULL) return false;
    if (input == NULL || input_len == 0) return true;
    session->symbols.terminal_vt_write(session->terminal, input, input_len);
    return true;
}

bool spaces_ghostty_vt_session_encode_paste(
    SpacesGhosttyVtSession *session,
    const uint8_t *input,
    size_t input_len,
    char **out_ptr,
    size_t *out_len
) {
    if (out_ptr == NULL || out_len == NULL) return false;
    *out_ptr = NULL;
    *out_len = 0;
    if (session == NULL || session->terminal == NULL) return false;
    if (input_len == 0) return true;
    if (input == NULL) return false;

    bool bracketed = false;
    if (session->symbols.terminal_mode_get(session->terminal, GHOSTTY_MODE_BRACKETED_PASTE, &bracketed) != GHOSTTY_SUCCESS) {
        return false;
    }

    char *mutable_input = (char *)malloc(input_len);
    if (mutable_input == NULL) return false;
    memcpy(mutable_input, input, input_len);

    size_t required = 0;
    GhosttyResult result = session->symbols.paste_encode(mutable_input, input_len, bracketed, NULL, 0, &required);
    if (result != GHOSTTY_OUT_OF_SPACE && result != GHOSTTY_SUCCESS) {
        free(mutable_input);
        return false;
    }
    if (required == 0) {
        free(mutable_input);
        return true;
    }

    char *encoded = (char *)malloc(required);
    if (encoded == NULL) {
        free(mutable_input);
        return false;
    }

    size_t written = 0;
    result = session->symbols.paste_encode(mutable_input, input_len, bracketed, encoded, required, &written);
    free(mutable_input);
    if (result != GHOSTTY_SUCCESS) {
        free(encoded);
        return false;
    }

    *out_ptr = encoded;
    *out_len = written;
    return true;
}

bool spaces_ghostty_vt_session_copy_snapshot(SpacesGhosttyVtSession *session, SpacesGhosttyVtSnapshot *out_snapshot) {
    if (session == NULL || out_snapshot == NULL) return false;

    spaces_ghostty_vt_snapshot_reset(out_snapshot);

    if (session->symbols.render_state_update(session->render_state, session->terminal) != GHOSTTY_SUCCESS) {
        return false;
    }

    uint16_t columns = 0;
    uint16_t rows = 0;
    bool cursor_visible = false;
    bool cursor_has_position = false;
    uint16_t cursor_column = 0;
    uint16_t cursor_row = 0;
    size_t cell_count = 0;

    if (
        session->symbols.render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_COLS, &columns) != GHOSTTY_SUCCESS ||
        session->symbols.render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) != GHOSTTY_SUCCESS ||
        session->symbols.render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursor_visible) != GHOSTTY_SUCCESS ||
        session->symbols.render_state_get(
            session->render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
            &cursor_has_position
        ) != GHOSTTY_SUCCESS
    ) {
        return false;
    }

    if (cursor_has_position) {
        if (
            session->symbols.render_state_get(
                session->render_state,
                GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X,
                &cursor_column
            ) != GHOSTTY_SUCCESS ||
            session->symbols.render_state_get(
                session->render_state,
                GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y,
                &cursor_row
            ) != GHOSTTY_SUCCESS
        ) {
            return false;
        }
    }

    GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
    if (session->symbols.render_state_colors_get(session->render_state, &colors) != GHOSTTY_SUCCESS) {
        return false;
    }

    cell_count = (size_t)columns * (size_t)rows;
    SpacesGhosttyVtSnapshotCell *cells = NULL;
    if (cell_count > 0) {
        cells = (SpacesGhosttyVtSnapshotCell *)calloc(cell_count, sizeof(SpacesGhosttyVtSnapshotCell));
        if (cells == NULL) return false;
        spaces_ghostty_vt_fill_default_cells(
            cells,
            0,
            cell_count,
            spaces_ghostty_vt_pack_rgb(colors.foreground),
            spaces_ghostty_vt_pack_rgb(colors.background)
        );
    }

    if (session->symbols.render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &session->row_iterator) != GHOSTTY_SUCCESS) {
        free(cells);
        return false;
    }

    size_t cell_index = 0;
    while (cell_index < cell_count && session->symbols.row_iterator_next(session->row_iterator)) {
        if (
            session->symbols.row_get(
                session->row_iterator,
                GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                &session->row_cells
            ) != GHOSTTY_SUCCESS
        ) {
            free(cells);
            return false;
        }

        size_t row_start = cell_index;
        size_t row_end = row_start + (size_t)columns;
        while (cell_index < row_end && session->symbols.row_cells_next(session->row_cells)) {
            GhosttyCell raw_cell = 0;
            GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
            GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
            GhosttyColorRgb foreground = colors.foreground;
            GhosttyColorRgb background = colors.background;
            uint32_t codepoint = 0;

            session->symbols.row_cells_get(session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw_cell);
            session->symbols.row_cells_get(session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
            session->symbols.cell_get(raw_cell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint);
            session->symbols.cell_get(raw_cell, GHOSTTY_CELL_DATA_WIDE, &wide);
            if (
                session->symbols.row_cells_get(session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &foreground) !=
                GHOSTTY_SUCCESS
            ) {
                foreground = colors.foreground;
            }
            if (
                session->symbols.row_cells_get(session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &background) !=
                GHOSTTY_SUCCESS
            ) {
                background = colors.background;
            }

            cells[cell_index].codepoint = codepoint;
            cells[cell_index].foreground_rgb = spaces_ghostty_vt_pack_rgb(foreground);
            cells[cell_index].background_rgb = spaces_ghostty_vt_pack_rgb(background);
            cells[cell_index].flags = spaces_ghostty_vt_flags_for_style(&style, wide);
            cell_index++;
        }

        if (cell_index < row_end) {
            spaces_ghostty_vt_fill_default_cells(
                cells,
                cell_index,
                row_end,
                spaces_ghostty_vt_pack_rgb(colors.foreground),
                spaces_ghostty_vt_pack_rgb(colors.background)
            );
            cell_index = row_end;
        }
    }

    out_snapshot->columns = columns;
    out_snapshot->rows = rows;
    out_snapshot->cursor_column = cursor_column;
    out_snapshot->cursor_row = cursor_row;
    out_snapshot->cursor_visible = cursor_visible;
    out_snapshot->default_foreground_rgb = spaces_ghostty_vt_pack_rgb(colors.foreground);
    out_snapshot->default_background_rgb = spaces_ghostty_vt_pack_rgb(colors.background);
    out_snapshot->cell_count = cell_count;
    out_snapshot->cells = cells;
    return true;
}

typedef struct {
    uint16_t length;
} SpacesGhosttyVtEraseSpan;

bool spaces_ghostty_vt_session_erase_faint_run_at_cursor(SpacesGhosttyVtSession *session) {
    if (session == NULL || session->terminal == NULL) return false;
    if (session->symbols.render_state_update(session->render_state, session->terminal) != GHOSTTY_SUCCESS) return false;

    uint16_t columns = 0;
    uint16_t rows = 0;
    uint16_t cursor_column = 0;
    uint16_t cursor_row = 0;
    bool cursor_visible = false;
    bool cursor_has_position = false;
    if (
        session->symbols.render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_COLS, &columns) != GHOSTTY_SUCCESS ||
        session->symbols.render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) != GHOSTTY_SUCCESS ||
        session->symbols.render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursor_visible) != GHOSTTY_SUCCESS ||
        session->symbols.render_state_get(
            session->render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
            &cursor_has_position
        ) != GHOSTTY_SUCCESS
    ) {
        return false;
    }
    if (!cursor_visible || !cursor_has_position) return true;
    if (
        session->symbols.render_state_get(
            session->render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X,
            &cursor_column
        ) != GHOSTTY_SUCCESS ||
        session->symbols.render_state_get(
            session->render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y,
            &cursor_row
        ) != GHOSTTY_SUCCESS
    ) {
        return false;
    }
    if (columns == 0 || rows == 0 || cursor_column >= columns || cursor_row >= rows) return false;

    SpacesGhosttyVtEraseSpan *spans = (SpacesGhosttyVtEraseSpan *)calloc(rows, sizeof(SpacesGhosttyVtEraseSpan));
    if (spans == NULL) return false;

    if (session->symbols.render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &session->row_iterator) != GHOSTTY_SUCCESS) {
        free(spans);
        return false;
    }

    size_t span_count = 0;
    bool contains_text = false;
    bool preceding_row_wraps = false;
    uint16_t row_index = 0;
    while (row_index < rows && session->symbols.row_iterator_next(session->row_iterator)) {
        GhosttyRow raw_row = 0;
        if (
            session->symbols.row_get(session->row_iterator, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &raw_row) != GHOSTTY_SUCCESS ||
            raw_row == 0
        ) {
            free(spans);
            return false;
        }

        bool row_wraps = false;
        bool row_is_wrap_continuation = false;
        if (
            session->symbols.grid_row_get(raw_row, GHOSTTY_ROW_DATA_WRAP, &row_wraps) != GHOSTTY_SUCCESS ||
            session->symbols.grid_row_get(raw_row, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &row_is_wrap_continuation) != GHOSTTY_SUCCESS
        ) {
            free(spans);
            return false;
        }

        if (row_index >= cursor_row) {
            if (row_index > cursor_row && (!preceding_row_wraps || !row_is_wrap_continuation)) break;
            if (
                session->symbols.row_get(
                    session->row_iterator,
                    GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                    &session->row_cells
                ) != GHOSTTY_SUCCESS
            ) {
                free(spans);
                return false;
            }

            uint16_t start_column = row_index == cursor_row ? cursor_column : 0;
            uint16_t column = 0;
            uint16_t run_length = 0;
            bool run_ended = false;
            while (column < columns && session->symbols.row_cells_next(session->row_cells)) {
                GhosttyCell raw_cell = 0;
                GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
                if (
                    session->symbols.row_cells_get(
                        session->row_cells,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
                        &raw_cell
                    ) != GHOSTTY_SUCCESS ||
                    session->symbols.row_cells_get(
                        session->row_cells,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
                        &style
                    ) != GHOSTTY_SUCCESS
                ) {
                    free(spans);
                    return false;
                }

                if (column >= start_column) {
                    if (!style.faint) {
                        run_ended = true;
                        break;
                    }
                    bool has_text = false;
                    if (session->symbols.cell_get(raw_cell, GHOSTTY_CELL_DATA_HAS_TEXT, &has_text) != GHOSTTY_SUCCESS) {
                        free(spans);
                        return false;
                    }
                    contains_text = contains_text || has_text;
                    run_length++;
                }
                column++;
            }

            if (run_length == 0) break;
            spans[span_count].length = run_length;
            span_count++;
            if (run_ended || start_column + run_length < columns) break;
            preceding_row_wraps = row_wraps;
            if (!preceding_row_wraps) break;
        }
        row_index++;
    }

    if (span_count == 0 || !contains_text) {
        free(spans);
        return true;
    }

    size_t erase_capacity = 8 + span_count * 32;
    char *erase_sequence = (char *)malloc(erase_capacity);
    if (erase_sequence == NULL) {
        free(spans);
        return false;
    }

    size_t erase_length = 0;
    int written = snprintf(erase_sequence, erase_capacity, "\x1b" "7\x1b[%uX", spans[0].length);
    if (written < 0 || (size_t)written >= erase_capacity) {
        free(erase_sequence);
        free(spans);
        return false;
    }
    erase_length = (size_t)written;
    for (size_t index = 1; index < span_count; index++) {
        written = snprintf(
            erase_sequence + erase_length,
            erase_capacity - erase_length,
            "\x1b[1B\x1b[1G\x1b[%uX",
            spans[index].length
        );
        if (written < 0 || (size_t)written >= erase_capacity - erase_length) {
            free(erase_sequence);
            free(spans);
            return false;
        }
        erase_length += (size_t)written;
    }
    if (erase_capacity - erase_length < 3) {
        free(erase_sequence);
        free(spans);
        return false;
    }
    erase_sequence[erase_length++] = '\x1b';
    erase_sequence[erase_length++] = '8';

    bool succeeded = spaces_ghostty_vt_session_write(
        session,
        (const uint8_t *)erase_sequence,
        erase_length
    );
    free(erase_sequence);
    free(spans);
    return succeeded;
}

static SpacesGhosttyVtScrollbar spaces_ghostty_vt_scrollbar_from_ghostty(GhosttyTerminalScrollbar scrollbar) {
    SpacesGhosttyVtScrollbar result = {0};
    result.total = scrollbar.total;
    result.offset = scrollbar.offset;
    result.len = scrollbar.len;
    return result;
}

bool spaces_ghostty_vt_session_scroll_viewport_with_info(
    SpacesGhosttyVtSession *session,
    intptr_t delta_rows,
    SpacesGhosttyVtScrollbar *out_before,
    SpacesGhosttyVtScrollbar *out_after
) {
    if (session == NULL || session->terminal == NULL || delta_rows == 0) return false;

    GhosttyTerminalScrollbar before = {0};
    GhosttyTerminalScrollbar after = {0};
    if (session->symbols.terminal_get(session->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &before) != GHOSTTY_SUCCESS) {
        return false;
    }

    GhosttyTerminalScrollViewport behavior = {0};
    behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA;
    behavior.value.delta = delta_rows;
    session->symbols.terminal_scroll_viewport(session->terminal, behavior);

    if (session->symbols.terminal_get(session->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &after) != GHOSTTY_SUCCESS) {
        return false;
    }
    if (out_before != NULL) *out_before = spaces_ghostty_vt_scrollbar_from_ghostty(before);
    if (out_after != NULL) *out_after = spaces_ghostty_vt_scrollbar_from_ghostty(after);
    return true;
}

bool spaces_ghostty_vt_session_scroll_viewport(SpacesGhosttyVtSession *session, intptr_t delta_rows) {
    SpacesGhosttyVtScrollbar before = {0};
    SpacesGhosttyVtScrollbar after = {0};
    if (!spaces_ghostty_vt_session_scroll_viewport_with_info(session, delta_rows, &before, &after)) return false;
    return before.offset != after.offset;
}

bool spaces_ghostty_vt_session_format_plain(SpacesGhosttyVtSession *session, char **out_ptr, size_t *out_len) {
    if (session == NULL) return false;
    return spaces_ghostty_vt_format_plain_for_terminal(&session->symbols, session->terminal, out_ptr, out_len);
}

void spaces_ghostty_vt_snapshot_free(SpacesGhosttyVtSnapshot *snapshot) {
    spaces_ghostty_vt_snapshot_reset(snapshot);
}

bool spaces_ghostty_vt_render_plain(
    const uint8_t *input,
    size_t input_len,
    uint16_t columns,
    uint16_t rows,
    size_t max_scrollback,
    char **out_ptr,
    size_t *out_len
) {
    if (out_ptr == NULL || out_len == NULL || columns == 0 || rows == 0) {
        return false;
    }

    *out_ptr = NULL;
    *out_len = 0;

    // Plain-text rendering produces no colors, so it needs no theme.
    SpacesGhosttyVtSession *session = spaces_ghostty_vt_session_new(columns, rows, max_scrollback, NULL);
    if (session == NULL) return false;

    if (!spaces_ghostty_vt_session_write(session, input, input_len)) {
        spaces_ghostty_vt_session_free(session);
        return false;
    }

    bool succeeded = spaces_ghostty_vt_session_format_plain(session, out_ptr, out_len);
    spaces_ghostty_vt_session_free(session);
    return succeeded;
}

void spaces_ghostty_vt_free_buffer(char *ptr) {
    free(ptr);
}
