// phoros_core.h
// The C ABI of the Phoros realtime core. Kept tiny on purpose: handles, bytes, a clock the
// caller passes in, and a status code. See Core/phoros-core/src/lib.rs for the contract.
#ifndef PHOROS_CORE_H
#define PHOROS_CORE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PhorosCore PhorosCore;

enum { PHOROS_OK = 0, PHOROS_ERR_NULL = 1, PHOROS_ERR_TOO_LARGE = 2, PHOROS_ERR_PANIC = 3, PHOROS_ERR_POISONED = 4, PHOROS_ERR_DESTROYED = 5, PHOROS_ERR_BUSY = 6 };
enum { PHOROS_MAX_DATAGRAM = 65535 };
enum { PHOROS_EVENT_FED = 1, PHOROS_EVENT_DESTROYING = 2 };

typedef enum PhorosPollKind { PhorosPollIdle = 0, PhorosPollTransmit = 1, PhorosPollTimeout = 2 } PhorosPollKind;

typedef struct PhorosPoll {
    PhorosPollKind kind;
    const uint8_t *buffer;   /* owned by the core, valid until the next call on this handle */
    size_t len;
    int64_t at_us;
} PhorosPoll;

typedef void (*PhorosEventCallback)(void *user, uint32_t kind, int64_t value);

const char *phoros_core_version(void);
size_t phoros_core_live_handles(void);
PhorosCore *phoros_core_create(void *user, PhorosEventCallback on_event);
void phoros_core_destroy(PhorosCore *core);
int32_t phoros_core_feed(PhorosCore *core, const uint8_t *bytes, size_t len, int64_t now_us);
int32_t phoros_core_poll(PhorosCore *core, int64_t now_us, PhorosPoll *out);
int32_t phoros_core_test_panic(PhorosCore *core);
int32_t phoros_core_test_poison(PhorosCore *core);

/* Peer: a str0m session (ICE, DTLS, SCTP, two data channels) behind the same rules. */
typedef struct PhorosPeer PhorosPeer;
enum { PHOROS_PEER_EVENT_CONNECTED = 10, PHOROS_PEER_EVENT_CHANNEL_OPEN = 11, PHOROS_PEER_EVENT_ICE_STATE = 12, PHOROS_PEER_EVENT_DISCONNECTED = 13 };
enum { PHOROS_CHANNEL_RELIABLE = 0, PHOROS_CHANNEL_REALTIME = 1 };
typedef void (*PhorosDataCallback)(void *user, uint32_t channel, const uint8_t *bytes, size_t len);

PhorosPeer *phoros_peer_create(void *user, PhorosEventCallback on_event, PhorosDataCallback on_data, bool is_host, const char *local_addr);
void phoros_peer_destroy(PhorosPeer *peer);
int32_t phoros_peer_local_info(PhorosPeer *peer, char *out, size_t capacity);
int32_t phoros_peer_set_remote(PhorosPeer *peer, const char *info, const char *remote_addr, int64_t now_us);
int32_t phoros_peer_feed(PhorosPeer *peer, const uint8_t *bytes, size_t len, const char *source, int64_t now_us);
int32_t phoros_peer_poll(PhorosPeer *peer, int64_t now_us, PhorosPoll *out);
int32_t phoros_peer_send(PhorosPeer *peer, uint32_t channel, const uint8_t *bytes, size_t len);
int32_t phoros_peer_run_own_socket(PhorosPeer *peer);

#ifdef __cplusplus
}
#endif
#endif
