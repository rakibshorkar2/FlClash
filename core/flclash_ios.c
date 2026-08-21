#include "ios/flclash_ios.h"
#include "bride.h"

// The Swift side registers these function pointers at startup. They are all
// NULL until then; calls made before registration are dropped.

static flclash_ios_write_packet_cb g_write_packet_cb;

// --- packet flow (outbound) ---

void flclash_ios_write_packet(const uint8_t *data, size_t len, int family) {
    if (g_write_packet_cb != NULL) {
        g_write_packet_cb(data, len, family);
    }
}

void flclash_ios_set_write_packet_cb(flclash_ios_write_packet_cb cb) {
    g_write_packet_cb = cb;
}

// --- bridge (bride.c) wiring ---

// On iOS there is no VpnService to protect sockets from: the Network
// Extension sandbox already exempts the extension's own sockets from the
// tunnel, so protect is a no-op and process resolution returns an empty
// string. The Go side calls these through bride.c wrappers.
static void ios_protect(void *tun_interface, int fd) {
    (void)tun_interface;
    (void)fd;
}

static char *ios_resolve_process(void *tun_interface, int protocol,
                                 const char *source, const char *target, int uid) {
    (void)tun_interface;
    (void)protocol;
    (void)source;
    (void)target;
    (void)uid;
    return strdup("");
}

void flclash_ios_install_bridge(void) {
    protect_func = ios_protect;
    resolve_process_func = ios_resolve_process;
}

void flclash_ios_set_result_cb(void (*cb)(void *, const char *)) {
    result_func = cb;
}

void flclash_ios_set_release_object_cb(void (*cb)(void *)) {
    release_object_func = cb;
}

void flclash_ios_set_free_string_cb(void (*cb)(char *)) {
    free_string_func = cb;
}