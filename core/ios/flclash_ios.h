#ifndef FLCLASH_IOS_H
#define FLCLASH_IOS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Callbacks provided by the Swift side (the Network Extension process).

// flclash_ios_write_packet_cb delivers one outbound IP packet to the packet
// flow. family is AF_INET (2) or AF_INET6 (30).
typedef void (*flclash_ios_write_packet_cb)(const uint8_t *data, size_t len, int family);

// Setters, called once by Swift at core startup.
void flclash_ios_set_write_packet_cb(flclash_ios_write_packet_cb cb);

// Called by Go (core/tun/bridge_ios.go) to hand an outbound packet to Swift.
void flclash_ios_write_packet(const uint8_t *data, size_t len, int family);

// Install no-op protect/resolve_process callbacks into the generic bridge
// (bride.c). Must be called before the core runs.
void flclash_ios_install_bridge(void);

// Wire the generic bridge result callbacks to Swift. Called once at startup.
void flclash_ios_set_result_cb(void (*cb)(void *invoke_interface, const char *data));
void flclash_ios_set_release_object_cb(void (*cb)(void *obj));
void flclash_ios_set_free_string_cb(void (*cb)(char *data));

#ifdef __cplusplus
}
#endif

#endif // FLCLASH_IOS_H