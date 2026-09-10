#include <zlib.h>

// zlib exposes deflateInit2/inflateInit2 only as macros that fill in ZLIB_VERSION and the caller's
// z_stream size, so Swift cannot call them. Both wrappers pass windowBits -15, which selects a raw
// DEFLATE stream with no zlib header, no trailer, and no Adler-32: byte-for-byte the format Darwin's
// Compression framework produces and consumes under COMPRESSION_ZLIB. That is what lets a Linux
// daemon's render frames inflate on an iPhone.
static inline int spaces_deflate_init_raw(z_streamp stream, int level) {
    return deflateInit2(stream, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY);
}

static inline int spaces_inflate_init_raw(z_streamp stream) {
    return inflateInit2(stream, -15);
}
