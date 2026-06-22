#include <openssl/err.h>
#include <openssl/ssl.h>
#include <string.h>

static inline long spaces_SSL_CTX_set_min_proto_version(SSL_CTX *ctx, int version) {
    return SSL_CTX_set_min_proto_version(ctx, version);
}

static inline long spaces_SSL_CTX_set_max_proto_version(SSL_CTX *ctx, int version) {
    return SSL_CTX_set_max_proto_version(ctx, version);
}

static inline unsigned char *spaces_device_api_psk_storage(void) {
    static unsigned char value[128];
    return value;
}

static inline unsigned int *spaces_device_api_psk_len_storage(void) {
    static unsigned int value = 0;
    return &value;
}

static inline char *spaces_device_api_psk_identity_storage(void) {
    static char value[128];
    return value;
}

static inline unsigned int spaces_device_api_psk_server_callback(
    SSL *ssl,
    const char *identity,
    unsigned char *psk,
    unsigned int max_psk_len
) {
    (void)ssl;
    unsigned int psk_len = *spaces_device_api_psk_len_storage();
    if (psk_len == 0 || psk_len > max_psk_len) {
        return 0;
    }
    if (identity == NULL || strcmp(identity, spaces_device_api_psk_identity_storage()) != 0) {
        return 0;
    }
    memcpy(psk, spaces_device_api_psk_storage(), psk_len);
    return psk_len;
}

static inline int spaces_SSL_CTX_configure_device_api_psk(
    SSL_CTX *ctx,
    const unsigned char *psk,
    unsigned int psk_len,
    const char *identity
) {
    if (psk == NULL || identity == NULL || psk_len == 0 || psk_len > 128) {
        return 0;
    }
    unsigned char *stored_psk = spaces_device_api_psk_storage();
    char *stored_identity = spaces_device_api_psk_identity_storage();
    memset(stored_psk, 0, 128);
    memcpy(stored_psk, psk, psk_len);
    *spaces_device_api_psk_len_storage() = psk_len;
    snprintf(stored_identity, 128, "%s", identity);
    SSL_CTX_set_psk_server_callback(ctx, spaces_device_api_psk_server_callback);
    SSL_CTX_use_psk_identity_hint(ctx, stored_identity);
    return SSL_CTX_set_cipher_list(
        ctx,
        "PSK-AES256-GCM-SHA384:PSK-AES128-GCM-SHA256:PSK-AES256-CBC-SHA:PSK-AES128-CBC-SHA"
    );
}
