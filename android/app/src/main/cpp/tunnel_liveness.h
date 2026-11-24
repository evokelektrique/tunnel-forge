#ifndef TUNNEL_FORGE_TUNNEL_LIVENESS_H
#define TUNNEL_FORGE_TUNNEL_LIVENESS_H

/*
 * Socket error classification and idle peer liveness tracking for the data-plane loop.
 */

#include <stdint.h>

#define TUNNEL_LIVENESS_PROBE_IDLE_MS 15000LL
#define TUNNEL_LIVENESS_PROBE_RETRY_MS 5000LL
#define TUNNEL_LIVENESS_DEAD_TIMEOUT_MS 30000LL

typedef enum {
  TUNNEL_LIVENESS_OK = 0,
  TUNNEL_LIVENESS_SEND_PROBE = 1,
  TUNNEL_LIVENESS_DEAD = 2,
} tunnel_liveness_action_t;

typedef struct {
  int64_t last_inbound_ms;
  int64_t last_probe_ms;
  int probes_sent;
  uint8_t next_probe_id;
} tunnel_liveness_t;

/** Initialize liveness window using monotonic millisecond timestamp [now_ms]. */
void tunnel_liveness_init(tunnel_liveness_t *state, int64_t now_ms);

/** Reset silence and probe counters when an authenticated packet arrives from peer. */
void tunnel_liveness_on_inbound(tunnel_liveness_t *state, int64_t now_ms);

/** Advance liveness state at [now_ms]; returns probe/dead-peer action when due. */
tunnel_liveness_action_t tunnel_liveness_check(tunnel_liveness_t *state, int64_t now_ms);

/** @return 1 if errno [err] indicates dead socket, lost route, or down interface. */
int tunnel_is_fatal_socket_errno(int err);

/** @return 1 if ESP poll error/hangup event should tear down the tunnel. */
int tunnel_is_fatal_esp_poll_event(int is_hup_or_nval, int so_err);

#endif
