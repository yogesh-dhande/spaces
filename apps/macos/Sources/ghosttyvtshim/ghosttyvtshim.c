#include "ghosttyvtshim.h"

#include <dlfcn.h>
#include <ghostty/vt.h>
#include <limits.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef GhosttyResult (*GhosttyTerminalNewFn)(const GhosttyAllocator *, GhosttyTerminal *, GhosttyTerminalOptions);
typedef void (*GhosttyTerminalFreeFn)(GhosttyTerminal);
typedef void (*GhosttyTerminalVtWriteFn)(GhosttyTerminal, const uint8_t *, size_t);
typedef void (*GhosttyTerminalScrollViewportFn)(GhosttyTerminal, GhosttyTerminalScrollViewport);
typedef GhosttyResult (*GhosttyTerminalResizeFn)(GhosttyTerminal, uint16_t, uint16_t, uint32_t, uint32_t);
typedef GhosttyResult (*GhosttyTerminalGetFn)(GhosttyTerminal, GhosttyTerminalData, void *);
typedef GhosttyResult (*GhosttyTerminalModeGetFn)(GhosttyTerminal, GhosttyMode, bool *);
typedef GhosttyResult (*GhosttyTerminalSetFn)(GhosttyTerminal, GhosttyTerminalOption, const void *);
typedef GhosttyResult (*GhosttyPasteEncodeFn)(char *, size_t, bool, char *, size_t, size_t *);
typedef GhosttyResult (*GhosttyKeyEncoderNewFn)(const GhosttyAllocator *, GhosttyKeyEncoder *);
typedef void (*GhosttyKeyEncoderFreeFn)(GhosttyKeyEncoder);
typedef void (*GhosttyKeyEncoderSetoptFromTerminalFn)(GhosttyKeyEncoder, GhosttyTerminal);
typedef GhosttyResult (*GhosttyKeyEncoderEncodeFn)(GhosttyKeyEncoder, GhosttyKeyEvent, char *, size_t, size_t *);
typedef GhosttyResult (*GhosttyKeyEventNewFn)(const GhosttyAllocator *, GhosttyKeyEvent *);
typedef void (*GhosttyKeyEventFreeFn)(GhosttyKeyEvent);
typedef void (*GhosttyKeyEventSetActionFn)(GhosttyKeyEvent, GhosttyKeyAction);
typedef void (*GhosttyKeyEventSetKeyFn)(GhosttyKeyEvent, GhosttyKey);
typedef void (*GhosttyKeyEventSetModsFn)(GhosttyKeyEvent, GhosttyMods);
typedef void (*GhosttyKeyEventSetUtf8Fn)(GhosttyKeyEvent, const char *, size_t);
typedef void (*GhosttyKeyEventSetUnshiftedCodepointFn)(GhosttyKeyEvent, uint32_t);
typedef GhosttyResult (*GhosttyMouseEncoderNewFn)(const GhosttyAllocator *, GhosttyMouseEncoder *);
typedef void (*GhosttyMouseEncoderFreeFn)(GhosttyMouseEncoder);
typedef void (*GhosttyMouseEncoderSetoptFn)(GhosttyMouseEncoder, GhosttyMouseEncoderOption, const void *);
typedef void (*GhosttyMouseEncoderSetoptFromTerminalFn)(GhosttyMouseEncoder, GhosttyTerminal);
typedef GhosttyResult (*GhosttyMouseEncoderEncodeFn)(GhosttyMouseEncoder, GhosttyMouseEvent, char *, size_t, size_t *);
typedef GhosttyResult (*GhosttyMouseEventNewFn)(const GhosttyAllocator *, GhosttyMouseEvent *);
typedef void (*GhosttyMouseEventFreeFn)(GhosttyMouseEvent);
typedef void (*GhosttyMouseEventSetActionFn)(GhosttyMouseEvent, GhosttyMouseAction);
typedef void (*GhosttyMouseEventSetButtonFn)(GhosttyMouseEvent, GhosttyMouseButton);
typedef void (*GhosttyMouseEventSetModsFn)(GhosttyMouseEvent, GhosttyMods);
typedef void (*GhosttyMouseEventSetPositionFn)(GhosttyMouseEvent, GhosttyMousePosition);
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
    GhosttyTerminalResizeFn terminal_resize;
    GhosttyTerminalGetFn terminal_get;
    GhosttyTerminalModeGetFn terminal_mode_get;
    GhosttyTerminalSetFn terminal_set;
    GhosttyPasteEncodeFn paste_encode;
    GhosttyKeyEncoderNewFn key_encoder_new;
    GhosttyKeyEncoderFreeFn key_encoder_free;
    GhosttyKeyEncoderSetoptFromTerminalFn key_encoder_setopt_from_terminal;
    GhosttyKeyEncoderEncodeFn key_encoder_encode;
    GhosttyKeyEventNewFn key_event_new;
    GhosttyKeyEventFreeFn key_event_free;
    GhosttyKeyEventSetActionFn key_event_set_action;
    GhosttyKeyEventSetKeyFn key_event_set_key;
    GhosttyKeyEventSetModsFn key_event_set_mods;
    GhosttyKeyEventSetUtf8Fn key_event_set_utf8;
    GhosttyKeyEventSetUnshiftedCodepointFn key_event_set_unshifted_codepoint;
    GhosttyMouseEncoderNewFn mouse_encoder_new;
    GhosttyMouseEncoderFreeFn mouse_encoder_free;
    GhosttyMouseEncoderSetoptFn mouse_encoder_setopt;
    GhosttyMouseEncoderSetoptFromTerminalFn mouse_encoder_setopt_from_terminal;
    GhosttyMouseEncoderEncodeFn mouse_encoder_encode;
    GhosttyMouseEventNewFn mouse_event_new;
    GhosttyMouseEventFreeFn mouse_event_free;
    GhosttyMouseEventSetActionFn mouse_event_set_action;
    GhosttyMouseEventSetButtonFn mouse_event_set_button;
    GhosttyMouseEventSetModsFn mouse_event_set_mods;
    GhosttyMouseEventSetPositionFn mouse_event_set_position;
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
    symbols->terminal_resize = (GhosttyTerminalResizeFn)dlsym(handle, "ghostty_terminal_resize");
    symbols->terminal_get = (GhosttyTerminalGetFn)dlsym(handle, "ghostty_terminal_get");
    symbols->terminal_mode_get = (GhosttyTerminalModeGetFn)dlsym(handle, "ghostty_terminal_mode_get");
    // Optional: present in libghostty-vt builds that expose default-color configuration. Kept out
    // of the required-symbol check below so an older library still loads (theming is skipped).
    symbols->terminal_set = (GhosttyTerminalSetFn)dlsym(handle, "ghostty_terminal_set");
    symbols->paste_encode = (GhosttyPasteEncodeFn)dlsym(handle, "ghostty_paste_encode");
    symbols->key_encoder_new = (GhosttyKeyEncoderNewFn)dlsym(handle, "ghostty_key_encoder_new");
    symbols->key_encoder_free = (GhosttyKeyEncoderFreeFn)dlsym(handle, "ghostty_key_encoder_free");
    symbols->key_encoder_setopt_from_terminal =
        (GhosttyKeyEncoderSetoptFromTerminalFn)dlsym(handle, "ghostty_key_encoder_setopt_from_terminal");
    symbols->key_encoder_encode = (GhosttyKeyEncoderEncodeFn)dlsym(handle, "ghostty_key_encoder_encode");
    symbols->key_event_new = (GhosttyKeyEventNewFn)dlsym(handle, "ghostty_key_event_new");
    symbols->key_event_free = (GhosttyKeyEventFreeFn)dlsym(handle, "ghostty_key_event_free");
    symbols->key_event_set_action = (GhosttyKeyEventSetActionFn)dlsym(handle, "ghostty_key_event_set_action");
    symbols->key_event_set_key = (GhosttyKeyEventSetKeyFn)dlsym(handle, "ghostty_key_event_set_key");
    symbols->key_event_set_mods = (GhosttyKeyEventSetModsFn)dlsym(handle, "ghostty_key_event_set_mods");
    symbols->key_event_set_utf8 = (GhosttyKeyEventSetUtf8Fn)dlsym(handle, "ghostty_key_event_set_utf8");
    symbols->key_event_set_unshifted_codepoint =
        (GhosttyKeyEventSetUnshiftedCodepointFn)dlsym(handle, "ghostty_key_event_set_unshifted_codepoint");
    symbols->mouse_encoder_new = (GhosttyMouseEncoderNewFn)dlsym(handle, "ghostty_mouse_encoder_new");
    symbols->mouse_encoder_free = (GhosttyMouseEncoderFreeFn)dlsym(handle, "ghostty_mouse_encoder_free");
    symbols->mouse_encoder_setopt = (GhosttyMouseEncoderSetoptFn)dlsym(handle, "ghostty_mouse_encoder_setopt");
    symbols->mouse_encoder_setopt_from_terminal =
        (GhosttyMouseEncoderSetoptFromTerminalFn)dlsym(handle, "ghostty_mouse_encoder_setopt_from_terminal");
    symbols->mouse_encoder_encode = (GhosttyMouseEncoderEncodeFn)dlsym(handle, "ghostty_mouse_encoder_encode");
    symbols->mouse_event_new = (GhosttyMouseEventNewFn)dlsym(handle, "ghostty_mouse_event_new");
    symbols->mouse_event_free = (GhosttyMouseEventFreeFn)dlsym(handle, "ghostty_mouse_event_free");
    symbols->mouse_event_set_action = (GhosttyMouseEventSetActionFn)dlsym(handle, "ghostty_mouse_event_set_action");
    symbols->mouse_event_set_button = (GhosttyMouseEventSetButtonFn)dlsym(handle, "ghostty_mouse_event_set_button");
    symbols->mouse_event_set_mods = (GhosttyMouseEventSetModsFn)dlsym(handle, "ghostty_mouse_event_set_mods");
    symbols->mouse_event_set_position = (GhosttyMouseEventSetPositionFn)dlsym(handle, "ghostty_mouse_event_set_position");
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
        symbols->terminal_resize == NULL ||
        symbols->terminal_get == NULL ||
        symbols->terminal_mode_get == NULL ||
        symbols->paste_encode == NULL ||
        symbols->key_encoder_new == NULL ||
        symbols->key_encoder_free == NULL ||
        symbols->key_encoder_setopt_from_terminal == NULL ||
        symbols->key_encoder_encode == NULL ||
        symbols->key_event_new == NULL ||
        symbols->key_event_free == NULL ||
        symbols->key_event_set_action == NULL ||
        symbols->key_event_set_key == NULL ||
        symbols->key_event_set_mods == NULL ||
        symbols->key_event_set_utf8 == NULL ||
        symbols->key_event_set_unshifted_codepoint == NULL ||
        symbols->mouse_encoder_new == NULL ||
        symbols->mouse_encoder_free == NULL ||
        symbols->mouse_encoder_setopt == NULL ||
        symbols->mouse_encoder_setopt_from_terminal == NULL ||
        symbols->mouse_encoder_encode == NULL ||
        symbols->mouse_event_new == NULL ||
        symbols->mouse_event_free == NULL ||
        symbols->mouse_event_set_action == NULL ||
        symbols->mouse_event_set_button == NULL ||
        symbols->mouse_event_set_mods == NULL ||
        symbols->mouse_event_set_position == NULL ||
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

// Releases a cell buffer along with the per-cell grapheme clusters it owns. Every path that abandons
// a partially filled buffer must go through this, not a bare free(), or the clusters leak.
static void spaces_ghostty_vt_free_cells(SpacesGhosttyVtSnapshotCell *cells, size_t cell_count) {
    if (cells == NULL) return;
    for (size_t index = 0; index < cell_count; index++) {
        if (cells[index].grapheme_extras != NULL) free(cells[index].grapheme_extras);
    }
    free(cells);
}

static void spaces_ghostty_vt_snapshot_reset(SpacesGhosttyVtSnapshot *snapshot) {
    if (snapshot == NULL) return;
    spaces_ghostty_vt_free_cells(snapshot->cells, snapshot->cell_count);
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
    // Only ever called on cells the row iterator has not visited, so no cluster can be dropped here.
    if (cells == NULL || end <= start) return;
    for (size_t index = start; index < end; index++) {
        cells[index].codepoint = 0;
        cells[index].foreground_rgb = foreground_rgb;
        cells[index].background_rgb = background_rgb;
        cells[index].flags = 0;
        cells[index].grapheme_extra_len = 0;
        cells[index].grapheme_extras = NULL;
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

bool spaces_ghostty_vt_session_resize(SpacesGhosttyVtSession *session, uint16_t columns, uint16_t rows) {
    if (session == NULL || session->terminal == NULL || columns == 0 || rows == 0) return false;
    // Session creation leaves the pixel cell metrics unset (GhosttyTerminalOptions carries only
    // cols/rows/max_scrollback), so the in-place resize keeps that same convention and passes zero
    // pixel metrics. Only the cell grid is reflowed; image-protocol pixel geometry stays unset.
    return session->symbols.terminal_resize(session->terminal, columns, rows, 0, 0) == GHOSTTY_SUCCESS;
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

static GhosttyKey spaces_ghostty_vt_ghostty_key(uint32_t key) {
    switch ((SpacesGhosttyVtKey)key) {
        case SPACES_GHOSTTY_VT_KEY_ENTER: return GHOSTTY_KEY_ENTER;
        case SPACES_GHOSTTY_VT_KEY_TAB: return GHOSTTY_KEY_TAB;
        case SPACES_GHOSTTY_VT_KEY_BACKSPACE: return GHOSTTY_KEY_BACKSPACE;
        case SPACES_GHOSTTY_VT_KEY_ESCAPE: return GHOSTTY_KEY_ESCAPE;
        case SPACES_GHOSTTY_VT_KEY_ARROW_UP: return GHOSTTY_KEY_ARROW_UP;
        case SPACES_GHOSTTY_VT_KEY_ARROW_DOWN: return GHOSTTY_KEY_ARROW_DOWN;
        case SPACES_GHOSTTY_VT_KEY_ARROW_LEFT: return GHOSTTY_KEY_ARROW_LEFT;
        case SPACES_GHOSTTY_VT_KEY_ARROW_RIGHT: return GHOSTTY_KEY_ARROW_RIGHT;
        case SPACES_GHOSTTY_VT_KEY_HOME: return GHOSTTY_KEY_HOME;
        case SPACES_GHOSTTY_VT_KEY_END: return GHOSTTY_KEY_END;
        case SPACES_GHOSTTY_VT_KEY_PAGE_UP: return GHOSTTY_KEY_PAGE_UP;
        case SPACES_GHOSTTY_VT_KEY_PAGE_DOWN: return GHOSTTY_KEY_PAGE_DOWN;
        case SPACES_GHOSTTY_VT_KEY_DELETE: return GHOSTTY_KEY_DELETE;
        case SPACES_GHOSTTY_VT_KEY_INSERT: return GHOSTTY_KEY_INSERT;
        case SPACES_GHOSTTY_VT_KEY_F1: return GHOSTTY_KEY_F1;
        case SPACES_GHOSTTY_VT_KEY_F2: return GHOSTTY_KEY_F2;
        case SPACES_GHOSTTY_VT_KEY_F3: return GHOSTTY_KEY_F3;
        case SPACES_GHOSTTY_VT_KEY_F4: return GHOSTTY_KEY_F4;
        case SPACES_GHOSTTY_VT_KEY_F5: return GHOSTTY_KEY_F5;
        case SPACES_GHOSTTY_VT_KEY_F6: return GHOSTTY_KEY_F6;
        case SPACES_GHOSTTY_VT_KEY_F7: return GHOSTTY_KEY_F7;
        case SPACES_GHOSTTY_VT_KEY_F8: return GHOSTTY_KEY_F8;
        case SPACES_GHOSTTY_VT_KEY_F9: return GHOSTTY_KEY_F9;
        case SPACES_GHOSTTY_VT_KEY_F10: return GHOSTTY_KEY_F10;
        case SPACES_GHOSTTY_VT_KEY_F11: return GHOSTTY_KEY_F11;
        case SPACES_GHOSTTY_VT_KEY_F12: return GHOSTTY_KEY_F12;
        case SPACES_GHOSTTY_VT_KEY_UNIDENTIFIED: return GHOSTTY_KEY_UNIDENTIFIED;
    }
    return GHOSTTY_KEY_UNIDENTIFIED;
}

bool spaces_ghostty_vt_session_encode_key(
    SpacesGhosttyVtSession *session,
    uint32_t key,
    uint16_t mods,
    const char *utf8,
    size_t utf8_len,
    uint32_t unshifted_codepoint,
    char **out_ptr,
    size_t *out_len
) {
    if (out_ptr == NULL || out_len == NULL) return false;
    *out_ptr = NULL;
    *out_len = 0;
    if (session == NULL || session->terminal == NULL) return false;

    GhosttyKeyEncoder encoder = NULL;
    if (session->symbols.key_encoder_new(NULL, &encoder) != GHOSTTY_SUCCESS) return false;
    // Reading the options off the terminal is the whole point: it is what makes the encoding follow
    // the running program's Kitty keyboard flags, cursor-key mode, and modifyOtherKeys state.
    session->symbols.key_encoder_setopt_from_terminal(encoder, session->terminal);

    GhosttyKeyEvent event = NULL;
    if (session->symbols.key_event_new(NULL, &event) != GHOSTTY_SUCCESS) {
        session->symbols.key_encoder_free(encoder);
        return false;
    }
    session->symbols.key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS);
    session->symbols.key_event_set_key(event, spaces_ghostty_vt_ghostty_key(key));
    session->symbols.key_event_set_mods(event, (GhosttyMods)mods);
    session->symbols.key_event_set_unshifted_codepoint(event, unshifted_codepoint);
    if (utf8 != NULL && utf8_len > 0) session->symbols.key_event_set_utf8(event, utf8, utf8_len);

    size_t required = 0;
    GhosttyResult result = session->symbols.key_encoder_encode(encoder, event, NULL, 0, &required);
    if (result != GHOSTTY_OUT_OF_SPACE && result != GHOSTTY_SUCCESS) {
        session->symbols.key_event_free(event);
        session->symbols.key_encoder_free(encoder);
        return false;
    }
    // Modifier-only presses and keys the terminal ignores encode to nothing; that is success with an
    // empty payload, not an error.
    if (required == 0) {
        session->symbols.key_event_free(event);
        session->symbols.key_encoder_free(encoder);
        return true;
    }

    char *encoded = (char *)malloc(required);
    if (encoded == NULL) {
        session->symbols.key_event_free(event);
        session->symbols.key_encoder_free(encoder);
        return false;
    }

    size_t written = 0;
    result = session->symbols.key_encoder_encode(encoder, event, encoded, required, &written);
    session->symbols.key_event_free(event);
    session->symbols.key_encoder_free(encoder);
    if (result != GHOSTTY_SUCCESS) {
        free(encoded);
        return false;
    }

    *out_ptr = encoded;
    *out_len = written;
    return true;
}

bool spaces_ghostty_vt_session_mouse_tracking_active(SpacesGhosttyVtSession *session, bool *out_active) {
    if (out_active == NULL) return false;
    *out_active = false;
    if (session == NULL || session->terminal == NULL) return false;

    bool active = false;
    if (session->symbols.terminal_get(session->terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &active) != GHOSTTY_SUCCESS) {
        return false;
    }
    *out_active = active;
    return true;
}

bool spaces_ghostty_vt_session_encode_mouse(
    SpacesGhosttyVtSession *session,
    uint8_t action,
    uint8_t button,
    uint16_t mods,
    uint16_t cell_column,
    uint16_t cell_row,
    char **out_ptr,
    size_t *out_len
) {
    if (out_ptr == NULL || out_len == NULL) return false;
    *out_ptr = NULL;
    *out_len = 0;
    if (session == NULL || session->terminal == NULL) return false;
    if (button < SPACES_GHOSTTY_VT_MOUSE_BUTTON_LEFT || button > SPACES_GHOSTTY_VT_MOUSE_BUTTON_ELEVEN) return false;
    if (action != SPACES_GHOSTTY_VT_MOUSE_ACTION_PRESS && action != SPACES_GHOSTTY_VT_MOUSE_ACTION_RELEASE) return false;

    uint16_t columns = 0;
    uint16_t rows = 0;
    if (
        session->symbols.terminal_get(session->terminal, GHOSTTY_TERMINAL_DATA_COLS, &columns) != GHOSTTY_SUCCESS ||
        session->symbols.terminal_get(session->terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows) != GHOSTTY_SUCCESS
    ) {
        return false;
    }
    if (columns == 0 || rows == 0) return false;
    if (cell_column >= columns) cell_column = columns - 1;
    if (cell_row >= rows) cell_row = rows - 1;

    GhosttyMouseEncoder encoder = NULL;
    if (session->symbols.mouse_encoder_new(NULL, &encoder) != GHOSTTY_SUCCESS) return false;
    // Reading the options off the terminal is the whole point: it is what makes the encoding follow
    // the tracking mode and report format the running program enabled.
    session->symbols.mouse_encoder_setopt_from_terminal(encoder, session->terminal);
    // `setopt_from_terminal` deliberately leaves geometry alone, and a headless session has none: it
    // is resized in cells with zero cell pixel sizes, which the encoder rejects. Give it a synthetic
    // one-pixel-per-cell screen so the caller's cell coordinates pass straight through as
    // surface-space pixels. The only consequence is that SGR-pixels reports cell granularity, which
    // is the best a session with no rendered geometry can describe.
    GhosttyMouseEncoderSize size = {
        .size = sizeof(GhosttyMouseEncoderSize),
        .screen_width = columns,
        .screen_height = rows,
        .cell_width = 1,
        .cell_height = 1,
    };
    session->symbols.mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
    const bool any_button_pressed = action == SPACES_GHOSTTY_VT_MOUSE_ACTION_PRESS;
    session->symbols.mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &any_button_pressed);

    GhosttyMouseEvent event = NULL;
    if (session->symbols.mouse_event_new(NULL, &event) != GHOSTTY_SUCCESS) {
        session->symbols.mouse_encoder_free(encoder);
        return false;
    }
    session->symbols.mouse_event_set_action(
        event,
        action == SPACES_GHOSTTY_VT_MOUSE_ACTION_PRESS ? GHOSTTY_MOUSE_ACTION_PRESS : GHOSTTY_MOUSE_ACTION_RELEASE
    );
    session->symbols.mouse_event_set_button(event, (GhosttyMouseButton)button);
    session->symbols.mouse_event_set_mods(event, (GhosttyMods)mods);
    // Aim at the middle of the cell so the encoder's floor-to-cell lands on the requested one.
    GhosttyMousePosition position = { .x = (float)cell_column + 0.5f, .y = (float)cell_row + 0.5f };
    session->symbols.mouse_event_set_position(event, position);

    size_t required = 0;
    GhosttyResult result = session->symbols.mouse_encoder_encode(encoder, event, NULL, 0, &required);
    if (result != GHOSTTY_OUT_OF_SPACE && result != GHOSTTY_SUCCESS) {
        session->symbols.mouse_event_free(event);
        session->symbols.mouse_encoder_free(encoder);
        return false;
    }
    // An event the terminal's current tracking mode does not report encodes to nothing; that is
    // success with an empty payload, not an error.
    if (required == 0) {
        session->symbols.mouse_event_free(event);
        session->symbols.mouse_encoder_free(encoder);
        return true;
    }

    char *encoded = (char *)malloc(required);
    if (encoded == NULL) {
        session->symbols.mouse_event_free(event);
        session->symbols.mouse_encoder_free(encoder);
        return false;
    }

    size_t written = 0;
    result = session->symbols.mouse_encoder_encode(encoder, event, encoded, required, &written);
    session->symbols.mouse_event_free(event);
    session->symbols.mouse_encoder_free(encoder);
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
        spaces_ghostty_vt_free_cells(cells, cell_count);
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
            spaces_ghostty_vt_free_cells(cells, cell_count);
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
            uint32_t grapheme_len = 0;

            session->symbols.row_cells_get(session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw_cell);
            session->symbols.row_cells_get(session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
            session->symbols.cell_get(raw_cell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint);
            session->symbols.cell_get(raw_cell, GHOSTTY_CELL_DATA_WIDE, &wide);
            if (
                session->symbols.row_cells_get(
                    session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &grapheme_len
                ) != GHOSTTY_SUCCESS
            ) {
                grapheme_len = 0;
            }
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

            // GRAPHEMES_BUF writes the full reported graphemes_len elements (base first, then the
            // extras), so the buffer is sized from that exact count; the cap keeps it on the stack and
            // keeps one cell from driving an unbounded copy. A cluster the library reports but declines
            // to write leaves the cell at its base codepoint alone, the same degradation the preamble
            // painter takes.
            if (grapheme_len > 1 && grapheme_len <= SPACES_GHOSTTY_VT_MAX_GRAPHEME_CODEPOINTS) {
                uint32_t cluster[SPACES_GHOSTTY_VT_MAX_GRAPHEME_CODEPOINTS];
                if (
                    session->symbols.row_cells_get(
                        session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, cluster
                    ) == GHOSTTY_SUCCESS
                ) {
                    uint16_t extra_len = (uint16_t)(grapheme_len - 1);
                    uint32_t *extras = (uint32_t *)malloc((size_t)extra_len * sizeof(uint32_t));
                    if (extras == NULL) {
                        spaces_ghostty_vt_free_cells(cells, cell_count);
                        return false;
                    }
                    memcpy(extras, cluster + 1, (size_t)extra_len * sizeof(uint32_t));
                    codepoint = cluster[0];
                    cells[cell_index].grapheme_extra_len = extra_len;
                    cells[cell_index].grapheme_extras = extras;
                }
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

// The persistent DEC private / ANSI modes the state preamble round-trips. Each is diffed against a
// fresh reference terminal, so this list is the SET of modes we consider (not their defaults): a mode
// only produces a sequence when the live session disagrees with a brand-new terminal. Alt-screen
// modes (47/1047/1049) are part of this set and, because cursor positioning is emitted after every
// mode below, always land before the CUP so the cursor is placed on the active screen.
// {numeric value, ANSI flag}. Stored as raw pairs (not GHOSTTY_MODE_* macros) because those macros
// expand to the static-inline ghostty_mode_new(), which is not a compile-time constant and so cannot
// initialize a static array.
typedef struct {
    uint16_t value;
    bool ansi;
} SpacesGhosttyVtPreambleMode;

static const SpacesGhosttyVtPreambleMode kSpacesGhosttyVtPreambleModes[] = {
    {1, false},    // DECCKM cursor keys
    {4, true},     // INSERT mode (ANSI)
    {5, false},    // REVERSE_COLORS reverse video
    {6, false},    // ORIGIN mode
    {7, false},    // WRAPAROUND auto-wrap
    {12, false},   // CURSOR_BLINKING
    {25, false},   // CURSOR_VISIBLE (DECTCEM)
    {47, false},   // ALT_SCREEN_LEGACY
    {66, false},   // KEYPAD_KEYS application keypad
    {1000, false}, // NORMAL_MOUSE
    {1002, false}, // BUTTON_MOUSE
    {1003, false}, // ANY_MOUSE
    {1004, false}, // FOCUS_EVENT
    {1005, false}, // UTF8_MOUSE
    {1006, false}, // SGR_MOUSE
    {1007, false}, // ALT_SCROLL
    {1015, false}, // URXVT_MOUSE
    {1016, false}, // SGR_PIXELS_MOUSE
    {1047, false}, // ALT_SCREEN
    {1048, false}, // SAVE_CURSOR
    {1049, false}, // ALT_SCREEN_SAVE
    {2004, false}, // BRACKETED_PASTE
    {2027, false}, // GRAPHEME_CLUSTER
    {2048, false}, // IN_BAND_RESIZE
};

typedef struct {
    char *data;
    size_t len;
    size_t cap;
    bool ok;
} SpacesGhosttyVtPreambleBuffer;

static void spaces_ghostty_vt_preamble_append(SpacesGhosttyVtPreambleBuffer *buf, const char *fmt, ...) {
    if (buf == NULL || !buf->ok) return;

    va_list measure_args;
    va_start(measure_args, fmt);
    int needed = vsnprintf(NULL, 0, fmt, measure_args);
    va_end(measure_args);
    if (needed < 0) {
        buf->ok = false;
        return;
    }

    size_t required = buf->len + (size_t)needed + 1;
    if (required > buf->cap) {
        size_t new_cap = buf->cap == 0 ? 256 : buf->cap;
        while (new_cap < required) new_cap *= 2;
        char *new_data = (char *)realloc(buf->data, new_cap);
        if (new_data == NULL) {
            buf->ok = false;
            return;
        }
        buf->data = new_data;
        buf->cap = new_cap;
    }

    va_list write_args;
    va_start(write_args, fmt);
    vsnprintf(buf->data + buf->len, buf->cap - buf->len, fmt, write_args);
    va_end(write_args);
    buf->len += (size_t)needed;
}

// Appends a single Unicode scalar as UTF-8. Codepoint 0 renders as a space so an empty cell paints a
// blank glyph rather than nothing. The bytes are copied via "%.*s" (the '%' lives only in the format
// string, so a literal '%' glyph is copied verbatim), and they never contain a NUL to trip the
// precision-with-NUL behavior since the minimum emitted byte is 0x20.
static void spaces_ghostty_vt_preamble_append_utf8_codepoint(SpacesGhosttyVtPreambleBuffer *buf, uint32_t codepoint) {
    if (codepoint == 0) codepoint = 0x20;
    uint8_t bytes[4];
    size_t len = 0;
    if (codepoint < 0x80) {
        bytes[0] = (uint8_t)codepoint;
        len = 1;
    } else if (codepoint < 0x800) {
        bytes[0] = (uint8_t)(0xC0 | (codepoint >> 6));
        bytes[1] = (uint8_t)(0x80 | (codepoint & 0x3F));
        len = 2;
    } else if (codepoint < 0x10000) {
        bytes[0] = (uint8_t)(0xE0 | (codepoint >> 12));
        bytes[1] = (uint8_t)(0x80 | ((codepoint >> 6) & 0x3F));
        bytes[2] = (uint8_t)(0x80 | (codepoint & 0x3F));
        len = 3;
    } else if (codepoint <= 0x10FFFF) {
        bytes[0] = (uint8_t)(0xF0 | (codepoint >> 18));
        bytes[1] = (uint8_t)(0x80 | ((codepoint >> 12) & 0x3F));
        bytes[2] = (uint8_t)(0x80 | ((codepoint >> 6) & 0x3F));
        bytes[3] = (uint8_t)(0x80 | (codepoint & 0x3F));
        len = 4;
    } else {
        bytes[0] = 0x20;  // out-of-range scalar -> space
        len = 1;
    }
    spaces_ghostty_vt_preamble_append(buf, "%.*s", (int)len, (const char *)bytes);
}

// A resolved pen for one cell: the style flags plus the *tagged* foreground and background colors.
// Colors are kept in tagged form (none / palette index / RGB) rather than resolved to RGB so the
// preamble can re-emit palette-indexed colors as `38;5;n` / `48;5;n` (which the viewer resolves against
// its own Spaces theme, and which adapt to light/dark) and reserve truecolor `38;2` / `48;2` for
// genuinely RGB colors. Consequently a palette-1 cell and an RGB cell that happens to resolve to the
// same RGB are different pens: the run-length comparison and the blank-cell test compare tags, not RGB.
// The underline color is kept tagged for the same reason (palette `58:5:n` vs truecolor `58:2::r:g:b`).
//
// The pen also carries decorations that `spaces_ghostty_vt_flags_for_style` does NOT retain: blink,
// overline, and the underline *variant* (single/double/curly/dotted/dashed) and its color. That flags
// enum is the wire format for client render snapshots and deliberately renders only a subset; these
// extra fields exist solely for durable transcript fidelity in the preamble, which permanently rewrites
// the transcript and so must not silently drop these attributes.
typedef struct {
    uint16_t flags;             // SPACES_GHOSTTY_VT_FLAG_* style bits (never the spacer bit)
    GhosttyStyleColorTag fg_tag;
    GhosttyStyleColorTag bg_tag;
    uint32_t fg_value;          // palette index (PALETTE) or packed 0x00RRGGBB (RGB); 0 for NONE
    uint32_t bg_value;
    bool blink;
    bool overline;
    uint8_t underline_style;    // GHOSTTY_SGR_UNDERLINE_* (0 = none); drives the emitted `4[:n]` variant
    GhosttyStyleColorTag ul_tag;
    uint32_t ul_value;          // palette index (PALETTE) or packed 0x00RRGGBB (RGB); 0 for NONE
} SpacesGhosttyVtPen;

static uint32_t spaces_ghostty_vt_style_color_value(GhosttyStyleColor color) {
    if (color.tag == GHOSTTY_STYLE_COLOR_PALETTE) return (uint32_t)color.value.palette;
    if (color.tag == GHOSTTY_STYLE_COLOR_RGB) return spaces_ghostty_vt_pack_rgb(color.value.rgb);
    return 0;
}

static SpacesGhosttyVtPen spaces_ghostty_vt_pen_from_style(const GhosttyStyle *style) {
    SpacesGhosttyVtPen pen;
    memset(&pen, 0, sizeof(pen));
    pen.flags = spaces_ghostty_vt_flags_for_style(style, GHOSTTY_CELL_WIDE_NARROW);
    pen.fg_tag = style->fg_color.tag;
    pen.bg_tag = style->bg_color.tag;
    pen.fg_value = spaces_ghostty_vt_style_color_value(style->fg_color);
    pen.bg_value = spaces_ghostty_vt_style_color_value(style->bg_color);
    // memset above zeroed these; populate the decorations the flags enum does not carry.
    pen.blink = style->blink;
    pen.overline = style->overline;
    pen.underline_style = (uint8_t)style->underline;  // GHOSTTY_SGR_UNDERLINE_* fits in a byte
    pen.ul_tag = style->underline_color.tag;
    pen.ul_value = spaces_ghostty_vt_style_color_value(style->underline_color);
    return pen;
}

static bool spaces_ghostty_vt_pen_equal(const SpacesGhosttyVtPen *a, const SpacesGhosttyVtPen *b) {
    return a->flags == b->flags && a->fg_tag == b->fg_tag && a->bg_tag == b->bg_tag &&
           a->fg_value == b->fg_value && a->bg_value == b->bg_value &&
           a->blink == b->blink && a->overline == b->overline &&
           a->underline_style == b->underline_style &&
           a->ul_tag == b->ul_tag && a->ul_value == b->ul_value;
}

// Emits a full pen transition as `CSI 0 m` (reset) followed by only the non-default attributes of the
// target cell. Resetting first and reapplying is larger than a minimal diff but is unconditionally
// correct — the emitted pen depends on nothing but the target cell, so no attribute can leak forward.
// Palette-tagged colors emit `38;5;n` / `48;5;n`; RGB-tagged colors emit truecolor; NONE emits nothing
// (the default fg/bg stays in effect). Flags map to their SGR codes. Underline is driven by
// `underline_style` (not the generic underline flag bit) so the emitted variant can never disagree with
// it: single -> `4`, double/curly/dotted/dashed -> the colon subparameter forms `4:2`/`4:3`/`4:4`/`4:5`.
// Blink (`5`), overline (`53`), and the underline color (`58:5:n` palette / `58:2::r:g:b` truecolor,
// where the empty subparam is the colorspace Ghostty's SGR parser expects) round out the decorations
// that the snapshot flags enum does not carry.
static void spaces_ghostty_vt_preamble_append_pen(SpacesGhosttyVtPreambleBuffer *buf, const SpacesGhosttyVtPen *pen) {
    spaces_ghostty_vt_preamble_append(buf, "\x1b[0");
    if (pen->flags & SPACES_GHOSTTY_VT_FLAG_BOLD) spaces_ghostty_vt_preamble_append(buf, ";1");
    if (pen->flags & SPACES_GHOSTTY_VT_FLAG_FAINT) spaces_ghostty_vt_preamble_append(buf, ";2");
    if (pen->flags & SPACES_GHOSTTY_VT_FLAG_ITALIC) spaces_ghostty_vt_preamble_append(buf, ";3");
    switch (pen->underline_style) {
        case GHOSTTY_SGR_UNDERLINE_SINGLE: spaces_ghostty_vt_preamble_append(buf, ";4"); break;
        case GHOSTTY_SGR_UNDERLINE_DOUBLE: spaces_ghostty_vt_preamble_append(buf, ";4:2"); break;
        case GHOSTTY_SGR_UNDERLINE_CURLY: spaces_ghostty_vt_preamble_append(buf, ";4:3"); break;
        case GHOSTTY_SGR_UNDERLINE_DOTTED: spaces_ghostty_vt_preamble_append(buf, ";4:4"); break;
        case GHOSTTY_SGR_UNDERLINE_DASHED: spaces_ghostty_vt_preamble_append(buf, ";4:5"); break;
        default: break;  // GHOSTTY_SGR_UNDERLINE_NONE -> emit nothing
    }
    if (pen->blink) spaces_ghostty_vt_preamble_append(buf, ";5");
    if (pen->flags & SPACES_GHOSTTY_VT_FLAG_INVERSE) spaces_ghostty_vt_preamble_append(buf, ";7");
    if (pen->flags & SPACES_GHOSTTY_VT_FLAG_INVISIBLE) spaces_ghostty_vt_preamble_append(buf, ";8");
    if (pen->flags & SPACES_GHOSTTY_VT_FLAG_STRIKE) spaces_ghostty_vt_preamble_append(buf, ";9");
    if (pen->overline) spaces_ghostty_vt_preamble_append(buf, ";53");
    if (pen->fg_tag == GHOSTTY_STYLE_COLOR_PALETTE) {
        spaces_ghostty_vt_preamble_append(buf, ";38;5;%u", (unsigned)pen->fg_value);
    } else if (pen->fg_tag == GHOSTTY_STYLE_COLOR_RGB) {
        GhosttyColorRgb color = spaces_ghostty_vt_unpack_rgb(pen->fg_value);
        spaces_ghostty_vt_preamble_append(buf, ";38;2;%u;%u;%u", (unsigned)color.r, (unsigned)color.g, (unsigned)color.b);
    }
    if (pen->bg_tag == GHOSTTY_STYLE_COLOR_PALETTE) {
        spaces_ghostty_vt_preamble_append(buf, ";48;5;%u", (unsigned)pen->bg_value);
    } else if (pen->bg_tag == GHOSTTY_STYLE_COLOR_RGB) {
        GhosttyColorRgb color = spaces_ghostty_vt_unpack_rgb(pen->bg_value);
        spaces_ghostty_vt_preamble_append(buf, ";48;2;%u;%u;%u", (unsigned)color.r, (unsigned)color.g, (unsigned)color.b);
    }
    if (pen->ul_tag == GHOSTTY_STYLE_COLOR_PALETTE) {
        spaces_ghostty_vt_preamble_append(buf, ";58:5:%u", (unsigned)pen->ul_value);
    } else if (pen->ul_tag == GHOSTTY_STYLE_COLOR_RGB) {
        GhosttyColorRgb color = spaces_ghostty_vt_unpack_rgb(pen->ul_value);
        spaces_ghostty_vt_preamble_append(buf, ";58:2::%u:%u:%u", (unsigned)color.r, (unsigned)color.g, (unsigned)color.b);
    }
    spaces_ghostty_vt_preamble_append(buf, "m");
}

// A cell of the active screen as modeled for the grid repaint: its pen, whether it is a wide-char
// spacer, whether it carries content, and its grapheme cluster (base codepoint plus any combining
// marks / ZWJ codepoints).
typedef struct {
    SpacesGhosttyVtPen pen;
    bool spacer;             // wide-char spacer (head/tail): covered by the wide glyph, never content
    bool has_content;        // participates in last-column / last-row detection
    uint32_t base_codepoint; // first grapheme codepoint (0 = blank cell)
    uint16_t grapheme_len;   // total codepoints in the cluster (0 = no text)
    uint32_t *graphemes;     // heap cluster of grapheme_len codepoints when grapheme_len > 1, else NULL
} SpacesGhosttyVtGridCell;

// Repaints the active screen's visible grid into the preamble buffer so a from-zero replay restores
// cells that the retained tail never redraws (e.g. a static TUI header drawn once, followed by
// cursor-only updates elsewhere). The painter does its own render-state row/cell iteration (rather than
// going through the flat snapshot) so it can read each cell's *tagged* style color (to keep palette
// indices palette-indexed) and its full grapheme cluster (so multi-codepoint clusters are not collapsed
// to their base codepoint).
//
// Painting is top-down flow, NOT absolute addressing: home once (`CSI 1;1 H`), then paint rows in order
// up to the last row that carries content, separated by `\r\n`; a blank interior row contributes `CSI K`
// (it must not be skipped, or the row-to-line mapping desyncs). This is what makes a replay at a SMALLER
// size behave correctly: the excess rows wrap/scroll like ordinary content instead of clamping absolute
// CUPs onto the bottom row (which destructively overwrites rows). At the same size, home + N painted
// rows joined by N-1 newlines can never scroll, so the result is visually identical to before. No `\r\n`
// follows the last painted row. Painting a full-width row then `\r\n` is safe because CR/LF do not
// advance the deferred (pending) wrap, so no extra scroll happens.
//
// Per row: paint cells up to the last content column, emitting a pen transition only when the pen
// changes and the cell's grapheme cluster (base codepoint 0 -> space). Wide-cell spacers are skipped
// because the wide codepoint already advances the cursor two columns. A closing `CSI 0 m` resets the
// pen; `CSI K` then erases trailing default cells, but only when the content does not already fill the
// row (a full-width row leaves the cursor in the deferred-wrap state on the last column, where EL would
// erase the glyph just painted).
//
// Returns false when the render state cannot be read; the caller then fails the whole preamble.
static bool spaces_ghostty_vt_preamble_append_grid(SpacesGhosttyVtSession *session, SpacesGhosttyVtPreambleBuffer *buf) {
    if (session->symbols.render_state_update(session->render_state, session->terminal) != GHOSTTY_SUCCESS) {
        return false;
    }

    uint16_t columns = 0;
    uint16_t rows = 0;
    if (
        session->symbols.render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_COLS, &columns) != GHOSTTY_SUCCESS ||
        session->symbols.render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) != GHOSTTY_SUCCESS
    ) {
        return false;
    }

    size_t cell_count = (size_t)columns * (size_t)rows;
    if (cell_count == 0) return buf->ok;  // Nothing to paint.

    // calloc leaves each cell blank + default: pen all-zero (NONE tags, no flags), grapheme_len 0,
    // has_content false. Cells the iterator does not visit therefore stay a correct blank default.
    SpacesGhosttyVtGridCell *grid = (SpacesGhosttyVtGridCell *)calloc(cell_count, sizeof(SpacesGhosttyVtGridCell));
    if (grid == NULL) return false;

    bool ok = true;
    if (session->symbols.render_state_get(session->render_state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &session->row_iterator) != GHOSTTY_SUCCESS) {
        ok = false;
    }

    size_t cell_index = 0;
    while (ok && cell_index < cell_count && session->symbols.row_iterator_next(session->row_iterator)) {
        if (
            session->symbols.row_get(session->row_iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &session->row_cells) !=
            GHOSTTY_SUCCESS
        ) {
            ok = false;
            break;
        }

        size_t row_start = cell_index;
        size_t row_end = row_start + (size_t)columns;
        while (cell_index < row_end && session->symbols.row_cells_next(session->row_cells)) {
            GhosttyCell raw_cell = 0;
            GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
            GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
            uint32_t codepoint = 0;
            uint32_t grapheme_len = 0;

            session->symbols.row_cells_get(session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw_cell);
            session->symbols.row_cells_get(session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
            session->symbols.cell_get(raw_cell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint);
            session->symbols.cell_get(raw_cell, GHOSTTY_CELL_DATA_WIDE, &wide);
            if (
                session->symbols.row_cells_get(
                    session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &grapheme_len
                ) != GHOSTTY_SUCCESS
            ) {
                grapheme_len = 0;
            }

            SpacesGhosttyVtGridCell *model = &grid[cell_index];
            model->pen = spaces_ghostty_vt_pen_from_style(&style);
            model->spacer = (wide == GHOSTTY_CELL_WIDE_SPACER_HEAD || wide == GHOSTTY_CELL_WIDE_SPACER_TAIL);
            model->base_codepoint = codepoint;
            // GRAPHEMES_BUF writes the full reported graphemes_len elements (see render.h), so the buffer
            // must be sized from that exact count. A cluster over 0xFFFF codepoints cannot be stored in the
            // uint16_t model field and would also let output drive an arbitrarily large allocation, so such a
            // degenerate cell (combining-mark spam) falls back to its base codepoint alone.
            model->grapheme_len = grapheme_len > 0xFFFF ? 1 : (uint16_t)grapheme_len;

            // Only copy the cluster out when it holds more than the base codepoint; a single-codepoint
            // cell is emitted from base_codepoint alone. The buffer receives base first, then extras.
            if (model->grapheme_len > 1) {
                uint32_t *cluster = (uint32_t *)malloc((size_t)model->grapheme_len * sizeof(uint32_t));
                if (cluster == NULL) {
                    ok = false;
                    break;
                }
                if (
                    session->symbols.row_cells_get(
                        session->row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, cluster
                    ) != GHOSTTY_SUCCESS
                ) {
                    free(cluster);
                    model->grapheme_len = 1;  // Fall back to the base codepoint.
                } else {
                    model->graphemes = cluster;
                    model->base_codepoint = cluster[0];
                }
            }

            // A cell counts as content unless it is blank (no glyph or a space), keeps the default
            // background (tag NONE), and carries no visible decoration — all compared in tagged terms.
            // Beyond bg color and the style flag bits, the decorations `flags` does not carry are checked
            // explicitly so a trailing cell whose only attribute is blink, overline, or an underline color
            // is NOT folded into the EL erase (the underline *variant* is already reflected in the flag
            // bits). Foreground color is deliberately excluded: it is invisible on a blank cell. Spacer
            // cells never count on their own; the wide glyph they trail already carries the content.
            bool blank = model->base_codepoint == 0 || model->base_codepoint == 0x20;
            model->has_content = !model->spacer &&
                (!blank || model->pen.bg_tag != GHOSTTY_STYLE_COLOR_NONE || model->pen.flags != 0 ||
                 model->pen.blink || model->pen.overline || model->pen.ul_tag != GHOSTTY_STYLE_COLOR_NONE);
            cell_index++;
        }
        cell_index = row_end;
    }

    if (ok && buf->ok) {
        // Find the last row that carries content; nothing is painted if the grid is entirely default.
        int last_content_row = -1;
        for (int row = (int)rows - 1; row >= 0; row--) {
            const SpacesGhosttyVtGridCell *row_cells = grid + (size_t)row * (size_t)columns;
            for (uint16_t column = 0; column < columns; column++) {
                if (row_cells[column].has_content) {
                    last_content_row = row;
                    break;
                }
            }
            if (last_content_row >= 0) break;
        }

        if (last_content_row >= 0) {
            spaces_ghostty_vt_preamble_append(buf, "\x1b[1;1H");
            for (int row = 0; row <= last_content_row && buf->ok; row++) {
                if (row > 0) spaces_ghostty_vt_preamble_append(buf, "\r\n");
                const SpacesGhosttyVtGridCell *row_cells = grid + (size_t)row * (size_t)columns;

                int last_content_column = -1;
                for (int column = (int)columns - 1; column >= 0; column--) {
                    if (row_cells[column].has_content) {
                        last_content_column = column;
                        break;
                    }
                }

                if (last_content_column < 0) {
                    // Blank interior row: clear the line and let the loop's `\r\n` advance to the next.
                    spaces_ghostty_vt_preamble_append(buf, "\x1b[K");
                    continue;
                }

                SpacesGhosttyVtPen current_pen;
                memset(&current_pen, 0, sizeof(current_pen));  // Default pen (NONE tags, no flags).
                for (int column = 0; column <= last_content_column; column++) {
                    const SpacesGhosttyVtGridCell *cell = &row_cells[column];
                    if (cell->spacer) continue;  // The preceding wide glyph already advanced the cursor.
                    if (!spaces_ghostty_vt_pen_equal(&cell->pen, &current_pen)) {
                        spaces_ghostty_vt_preamble_append_pen(buf, &cell->pen);
                        current_pen = cell->pen;
                    }
                    if (cell->grapheme_len > 1 && cell->graphemes != NULL) {
                        for (uint16_t i = 0; i < cell->grapheme_len; i++) {
                            spaces_ghostty_vt_preamble_append_utf8_codepoint(buf, cell->graphemes[i]);
                        }
                    } else {
                        spaces_ghostty_vt_preamble_append_utf8_codepoint(buf, cell->base_codepoint);
                    }
                }

                spaces_ghostty_vt_preamble_append(buf, "\x1b[0m");
                // Spacer cells immediately after the last content cell belong to the wide glyph just
                // painted, which filled those columns. Skip past them before deciding on a trailing EL:
                // when the wide glyph ends at the right edge the cursor sits in deferred-wrap on the
                // last column, and a `CSI K` there would erase half the glyph, which terminals treat as
                // erasing the whole glyph. Only a genuinely blank non-spacer cell before end-of-row
                // needs clearing.
                int trailing = last_content_column + 1;
                while (trailing < (int)columns && row_cells[trailing].spacer) trailing++;
                if (trailing < (int)columns) spaces_ghostty_vt_preamble_append(buf, "\x1b[K");
            }
        }
    }

    for (size_t index = 0; index < cell_count; index++) {
        if (grid[index].graphemes != NULL) free(grid[index].graphemes);
    }
    free(grid);
    return ok && buf->ok;
}

// Serializes the session's current persistent terminal state as escape sequences, diffed against a
// fresh reference terminal created at the same cols/rows via the already-loaded symbols. Only state
// that differs from a brand-new terminal is emitted, so the library's own defaults define "emit
// nothing" and there is no hardcoded mode-default table to drift from the library.
//
// Emission order:
//   1. Modes (ANSI: CSI <n> h/l; DEC private: CSI ? <n> h/l), including alt-screen modes.
//   2. Kitty keyboard flags (CSI = <flags> ; 1 u) when nonzero.
//   3. Grid repaint of the active screen (top-down flow paint, per `spaces_ghostty_vt_preamble_append_grid`).
//      Emitted after the modes so it lands on the active (possibly alt) screen, and before the CUP so
//      the final cursor position wins over wherever painting left the cursor.
//   4. Cursor position (CSI <y+1> ; <x+1> H), after all mode/screen/grid changes so it lands on the
//      active screen.
//   5. SGR reset (CSI 0 m) so pen state is deterministic.
//
// RESTORED beyond modes/cursor: the ACTIVE screen's visible grid (cell text, colors, and style flags)
// via the grid repaint, so cells drawn before the cut that the retained tail never redraws survive a
// from-zero replay.
//
// ACCEPTED GAPS (intentionally NOT restored): the INACTIVE screen's grid (render state exposes only
// the active screen) and scrollback content above the grid (inherent to trimming — those bytes are
// dropped). Also not restored: scroll region, tab stops, charset designations, saved-cursor (DECSC),
// pending-wrap at the bottom-right corner (unrestorable — painting cannot re-arm it without
// scrolling), OSC color/title overrides, and the live pen's SGR (reset to default). In addition, the
// pinned libghostty-vt exposes no cursor-SHAPE getter (GHOSTTY_TERMINAL_DATA_CURSOR_STYLE returns the
// pen SGR style, not a block/underline/bar shape), so DECSCUSR is not emitted. These are acceptable
// because from-zero handoff replay only needs the mode/cursor/grid state that determines how the
// retained tail's bytes render.
bool spaces_ghostty_vt_session_state_preamble(SpacesGhosttyVtSession *session, char **out_ptr, size_t *out_len) {
    if (out_ptr == NULL || out_len == NULL) return false;
    *out_ptr = NULL;
    *out_len = 0;
    if (session == NULL || session->terminal == NULL) return false;

    uint16_t columns = 0;
    uint16_t rows = 0;
    if (
        session->symbols.terminal_get(session->terminal, GHOSTTY_TERMINAL_DATA_COLS, &columns) != GHOSTTY_SUCCESS ||
        session->symbols.terminal_get(session->terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows) != GHOSTTY_SUCCESS ||
        columns == 0 || rows == 0
    ) {
        return false;
    }

    // Fresh reference terminal at the same size: the diff baseline for every mode below.
    GhosttyTerminal reference = NULL;
    GhosttyTerminalOptions reference_options = {
        .cols = columns,
        .rows = rows,
        .max_scrollback = 0,
    };
    if (session->symbols.terminal_new(NULL, &reference, reference_options) != GHOSTTY_SUCCESS) {
        return false;
    }

    SpacesGhosttyVtPreambleBuffer buf = {0};
    buf.ok = true;

    // 1. Modes.
    for (size_t i = 0; i < sizeof(kSpacesGhosttyVtPreambleModes) / sizeof(kSpacesGhosttyVtPreambleModes[0]); i++) {
        SpacesGhosttyVtPreambleMode entry = kSpacesGhosttyVtPreambleModes[i];
        GhosttyMode mode = ghostty_mode_new(entry.value, entry.ansi);
        bool live_set = false;
        bool ref_set = false;
        if (session->symbols.terminal_mode_get(session->terminal, mode, &live_set) != GHOSTTY_SUCCESS) continue;
        if (session->symbols.terminal_mode_get(reference, mode, &ref_set) != GHOSTTY_SUCCESS) continue;
        if (live_set == ref_set) continue;
        spaces_ghostty_vt_preamble_append(
            &buf, "\x1b[%s%u%c", entry.ansi ? "" : "?", (unsigned)entry.value, live_set ? 'h' : 'l');
    }

    // 2. Kitty keyboard flags. A fresh terminal reports 0, so nonzero is the diff.
    uint8_t kitty_flags = 0;
    if (
        session->symbols.terminal_get(session->terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &kitty_flags) == GHOSTTY_SUCCESS &&
        kitty_flags != 0
    ) {
        spaces_ghostty_vt_preamble_append(&buf, "\x1b[=%u;1u", (unsigned)kitty_flags);
    }

    // 3. Grid repaint of the active screen. Emitted after the modes (so alt-screen entry has already
    //    happened) and before the cursor position (so the CUP below wins). A snapshot-read failure
    //    fails the whole preamble rather than emitting a partially painted grid.
    if (!spaces_ghostty_vt_preamble_append_grid(session, &buf)) {
        buf.ok = false;
    }

    // 4. Cursor position (0-indexed getters, 1-indexed CUP). Always emitted so the retained tail
    //    begins with a deterministic cursor location.
    uint16_t cursor_x = 0;
    uint16_t cursor_y = 0;
    if (
        session->symbols.terminal_get(session->terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cursor_x) == GHOSTTY_SUCCESS &&
        session->symbols.terminal_get(session->terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cursor_y) == GHOSTTY_SUCCESS
    ) {
        spaces_ghostty_vt_preamble_append(&buf, "\x1b[%u;%uH", (unsigned)cursor_y + 1, (unsigned)cursor_x + 1);
    }

    // 5. SGR reset.
    spaces_ghostty_vt_preamble_append(&buf, "\x1b[0m");

    session->symbols.terminal_free(reference);

    if (!buf.ok) {
        free(buf.data);
        return false;
    }
    if (buf.data == NULL) {
        // Every path above appends at least the SGR reset, so this only happens if the first
        // allocation failed. Report failure rather than hand back a NULL buffer.
        return false;
    }

    *out_ptr = buf.data;
    *out_len = buf.len;
    return true;
}

bool spaces_ghostty_vt_session_mode_is_set(SpacesGhosttyVtSession *session, uint16_t mode_value, bool ansi, bool *out_set) {
    if (session == NULL || session->terminal == NULL || out_set == NULL) return false;
    bool value = false;
    if (session->symbols.terminal_mode_get(session->terminal, ghostty_mode_new(mode_value, ansi), &value) != GHOSTTY_SUCCESS) {
        return false;
    }
    *out_set = value;
    return true;
}

// Copies one of the terminal's escape-sequence-set string values into a caller-owned buffer.
// libghostty-vt hands back a BORROWED pointer into terminal storage that is invalidated by the next
// `ghostty_terminal_vt_write` or reset, so the bytes must be copied here rather than handed across
// the C/Swift boundary. An unset value is reported by the library as an empty string, so "absent"
// and "explicitly cleared" are indistinguishable and both return false.
static bool spaces_ghostty_vt_session_copy_string_data(
    SpacesGhosttyVtSession *session,
    GhosttyTerminalData data,
    char **out_ptr,
    size_t *out_len
) {
    if (out_ptr == NULL || out_len == NULL) return false;
    *out_ptr = NULL;
    *out_len = 0;
    if (session == NULL || session->terminal == NULL) return false;

    GhosttyString value = {NULL, 0};
    if (session->symbols.terminal_get(session->terminal, data, &value) != GHOSTTY_SUCCESS) return false;
    if (value.ptr == NULL || value.len == 0) return false;

    char *copy = malloc(value.len);
    if (copy == NULL) return false;
    memcpy(copy, value.ptr, value.len);
    *out_ptr = copy;
    *out_len = value.len;
    return true;
}

bool spaces_ghostty_vt_session_title(SpacesGhosttyVtSession *session, char **out_ptr, size_t *out_len) {
    return spaces_ghostty_vt_session_copy_string_data(session, GHOSTTY_TERMINAL_DATA_TITLE, out_ptr, out_len);
}

bool spaces_ghostty_vt_session_pwd(SpacesGhosttyVtSession *session, char **out_ptr, size_t *out_len) {
    return spaces_ghostty_vt_session_copy_string_data(session, GHOSTTY_TERMINAL_DATA_PWD, out_ptr, out_len);
}

bool spaces_ghostty_vt_session_kitty_keyboard_flags(SpacesGhosttyVtSession *session, uint8_t *out_flags) {
    if (session == NULL || session->terminal == NULL || out_flags == NULL) return false;
    uint8_t flags = 0;
    if (session->symbols.terminal_get(session->terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags) != GHOSTTY_SUCCESS) {
        return false;
    }
    *out_flags = flags;
    return true;
}

void spaces_ghostty_vt_free_buffer(char *ptr) {
    free(ptr);
}
