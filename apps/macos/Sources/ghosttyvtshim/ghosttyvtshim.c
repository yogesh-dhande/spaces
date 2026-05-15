#include "ghosttyvtshim.h"

#include <dlfcn.h>
#include <ghostty/vt.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef GhosttyResult (*GhosttyTerminalNewFn)(const GhosttyAllocator *, GhosttyTerminal *, GhosttyTerminalOptions);
typedef void (*GhosttyTerminalFreeFn)(GhosttyTerminal);
typedef void (*GhosttyTerminalVtWriteFn)(GhosttyTerminal, const uint8_t *, size_t);
typedef GhosttyResult (*GhosttyFormatterTerminalNewFn)(
    const GhosttyAllocator *,
    GhosttyFormatter *,
    GhosttyTerminal,
    GhosttyFormatterTerminalOptions
);
typedef GhosttyResult (*GhosttyFormatterFormatAllocFn)(GhosttyFormatter, const GhosttyAllocator *, uint8_t **, size_t *);
typedef void (*GhosttyFormatterFreeFn)(GhosttyFormatter);
typedef void (*GhosttyFreeFn)(const GhosttyAllocator *, uint8_t *, size_t);

typedef struct {
    void *handle;
    GhosttyTerminalNewFn terminal_new;
    GhosttyTerminalFreeFn terminal_free;
    GhosttyTerminalVtWriteFn terminal_vt_write;
    GhosttyFormatterTerminalNewFn formatter_terminal_new;
    GhosttyFormatterFormatAllocFn formatter_format_alloc;
    GhosttyFormatterFreeFn formatter_free;
    GhosttyFreeFn ghostty_free;
} SpacesGhosttyVtSymbols;

static bool spaces_ghostty_vt_load_symbols(SpacesGhosttyVtSymbols *symbols) {
    if (symbols == NULL) return false;
    memset(symbols, 0, sizeof(*symbols));

    void *handle = NULL;
    const char *env_path = getenv("SPACES_GHOSTTY_VT_DYLIB_PATH");
    if (env_path != NULL && env_path[0] != '\0') {
        handle = dlopen(env_path, RTLD_NOW | RTLD_LOCAL);
    }

    if (handle == NULL) {
        const char *cwd_candidates[] = {
            "apps/macos/.local/ghosttyvt/src/zig-out/lib/libghostty-vt.dylib",
            ".local/ghosttyvt/src/zig-out/lib/libghostty-vt.dylib",
            NULL,
        };
        for (size_t i = 0; cwd_candidates[i] != NULL; i++) {
            handle = dlopen(cwd_candidates[i], RTLD_NOW | RTLD_LOCAL);
            if (handle != NULL) break;
        }
    }

    if (handle == NULL) {
        uint32_t executable_path_size = 0;
        _NSGetExecutablePath(NULL, &executable_path_size);
        if (executable_path_size > 0) {
            char *executable_path = (char *)malloc(executable_path_size);
            if (executable_path != NULL && _NSGetExecutablePath(executable_path, &executable_path_size) == 0) {
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
                            "%s/apps/macos/.local/ghosttyvt/src/zig-out/lib/libghostty-vt.dylib",
                            resolved_path
                        );
                        handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL);
                        if (handle != NULL) break;
                        snprintf(
                            candidate,
                            sizeof(candidate),
                            "%s/.local/ghosttyvt/src/zig-out/lib/libghostty-vt.dylib",
                            resolved_path
                        );
                        handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL);
                    }
                }
            }
            free(executable_path);
        }
    }

    if (handle == NULL) {
        const char *fallback_name = "libghostty-vt.dylib";
        handle = dlopen(fallback_name, RTLD_NOW | RTLD_LOCAL);
    }

    if (handle == NULL) {
        const char *fallback_name = "libghostty-vt.0.dylib";
        handle = dlopen(fallback_name, RTLD_NOW | RTLD_LOCAL);
    }
    if (handle == NULL) return false;

    symbols->handle = handle;
    symbols->terminal_new = (GhosttyTerminalNewFn)dlsym(handle, "ghostty_terminal_new");
    symbols->terminal_free = (GhosttyTerminalFreeFn)dlsym(handle, "ghostty_terminal_free");
    symbols->terminal_vt_write = (GhosttyTerminalVtWriteFn)dlsym(handle, "ghostty_terminal_vt_write");
    symbols->formatter_terminal_new = (GhosttyFormatterTerminalNewFn)dlsym(handle, "ghostty_formatter_terminal_new");
    symbols->formatter_format_alloc = (GhosttyFormatterFormatAllocFn)dlsym(handle, "ghostty_formatter_format_alloc");
    symbols->formatter_free = (GhosttyFormatterFreeFn)dlsym(handle, "ghostty_formatter_free");
    symbols->ghostty_free = (GhosttyFreeFn)dlsym(handle, "ghostty_free");

    if (
        symbols->terminal_new == NULL ||
        symbols->terminal_free == NULL ||
        symbols->terminal_vt_write == NULL ||
        symbols->formatter_terminal_new == NULL ||
        symbols->formatter_format_alloc == NULL ||
        symbols->formatter_free == NULL ||
        symbols->ghostty_free == NULL
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

    SpacesGhosttyVtSymbols symbols;
    if (!spaces_ghostty_vt_load_symbols(&symbols)) return false;

    GhosttyTerminal terminal = NULL;
    GhosttyTerminalOptions terminal_options = {
        .cols = columns,
        .rows = rows,
        .max_scrollback = max_scrollback,
    };
    if (symbols.terminal_new(NULL, &terminal, terminal_options) != GHOSTTY_SUCCESS) {
        spaces_ghostty_vt_unload_symbols(&symbols);
        return false;
    }

    if (input != NULL && input_len > 0) {
        symbols.terminal_vt_write(terminal, input, input_len);
    }

    GhosttyFormatter formatter = NULL;
    GhosttyFormatterTerminalOptions formatter_options = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
    formatter_options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    formatter_options.trim = true;
    if (symbols.formatter_terminal_new(NULL, &formatter, terminal, formatter_options) != GHOSTTY_SUCCESS) {
        symbols.terminal_free(terminal);
        spaces_ghostty_vt_unload_symbols(&symbols);
        return false;
    }

    uint8_t *formatted = NULL;
    size_t formatted_len = 0;
    if (symbols.formatter_format_alloc(formatter, NULL, &formatted, &formatted_len) != GHOSTTY_SUCCESS) {
        symbols.formatter_free(formatter);
        symbols.terminal_free(terminal);
        spaces_ghostty_vt_unload_symbols(&symbols);
        return false;
    }

    char *result = (char *)malloc(formatted_len + 1);
    if (result == NULL) {
        symbols.ghostty_free(NULL, formatted, formatted_len);
        symbols.formatter_free(formatter);
        symbols.terminal_free(terminal);
        spaces_ghostty_vt_unload_symbols(&symbols);
        return false;
    }

    if (formatted_len > 0) memcpy(result, formatted, formatted_len);
    result[formatted_len] = '\0';

    symbols.ghostty_free(NULL, formatted, formatted_len);
    symbols.formatter_free(formatter);
    symbols.terminal_free(terminal);
    spaces_ghostty_vt_unload_symbols(&symbols);

    *out_ptr = result;
    *out_len = formatted_len;
    return true;
}

void spaces_ghostty_vt_free_buffer(char *ptr) {
    free(ptr);
}
