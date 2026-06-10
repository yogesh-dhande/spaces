#include <openssl/err.h>
#include <openssl/ssl.h>

static inline long spaces_SSL_CTX_set_min_proto_version(SSL_CTX *ctx, int version) {
    return SSL_CTX_set_min_proto_version(ctx, version);
}

static inline long spaces_SSL_CTX_set_max_proto_version(SSL_CTX *ctx, int version) {
    return SSL_CTX_set_max_proto_version(ctx, version);
}
