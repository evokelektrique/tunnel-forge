/* Socket failure classification and active dead-peer probe scheduler. */
#include "tunnel_liveness.h"

#include <errno.h>
#include <stddef.h>

void tunnel_liveness_init(tunnel_liveness_t *state, int64_t now_ms) {
  if (state == NULL)
    return;
  state->last_inbound_ms = now_ms;
  state->last_probe_ms = 0;
  state->probes_sent = 0;
  state->next_probe_id = 1u;
}

void tunnel_liveness_on_inbound(tunnel_liveness_t *state, int64_t now_ms) {
  if (state == NULL)
    return;
  state->last_inbound_ms = now_ms;
  state->last_probe_ms = 0;
  state->probes_sent = 0;
}

tunnel_liveness_action_t tunnel_liveness_check(tunnel_liveness_t *state, int64_t now_ms) {
  if (state == NULL)
    return TUNNEL_LIVENESS_OK;
  if (now_ms < state->last_inbound_ms)
    return TUNNEL_LIVENESS_OK;
  const int64_t silent_ms = now_ms - state->last_inbound_ms;
  if (silent_ms < TUNNEL_LIVENESS_PROBE_IDLE_MS)
    return TUNNEL_LIVENESS_OK;

  if (state->probes_sent == 0) {
    state->probes_sent = 1;
    state->last_probe_ms = now_ms;
    state->next_probe_id = (uint8_t)(state->next_probe_id + 1u);
    if (state->next_probe_id == 0u)
      state->next_probe_id = 1u;
    return TUNNEL_LIVENESS_SEND_PROBE;
  }

  const int64_t since_probe_ms = now_ms - state->last_probe_ms;
  if (silent_ms >= TUNNEL_LIVENESS_DEAD_TIMEOUT_MS && since_probe_ms >= TUNNEL_LIVENESS_PROBE_RETRY_MS) {
    return TUNNEL_LIVENESS_DEAD;
  }

  if (since_probe_ms >= TUNNEL_LIVENESS_PROBE_RETRY_MS) {
    state->probes_sent++;
    state->last_probe_ms = now_ms;
    state->next_probe_id = (uint8_t)(state->next_probe_id + 1u);
    if (state->next_probe_id == 0u)
      state->next_probe_id = 1u;
    return TUNNEL_LIVENESS_SEND_PROBE;
  }

  return TUNNEL_LIVENESS_OK;
}

int tunnel_is_fatal_socket_errno(int err) {
  switch (err) {
  case EBADF:
  case EPIPE:
#ifdef ENETUNREACH
  case ENETUNREACH:
#endif
#ifdef ENETDOWN
  case ENETDOWN:
#endif
#ifdef EHOSTUNREACH
  case EHOSTUNREACH:
#endif
#ifdef EHOSTDOWN
  case EHOSTDOWN:
#endif
#ifdef ENONET
  case ENONET:
#endif
#ifdef ECONNREFUSED
  case ECONNREFUSED:
#endif
#ifdef ENOTCONN
  case ENOTCONN:
#endif
#ifdef EADDRNOTAVAIL
  case EADDRNOTAVAIL:
#endif
#ifdef ESHUTDOWN
  case ESHUTDOWN:
#endif
#ifdef ECONNRESET
  case ECONNRESET:
#endif
#ifdef ECONNABORTED
  case ECONNABORTED:
#endif
    return 1;
  default:
    return 0;
  }
}

int tunnel_is_fatal_esp_poll_event(int is_hup_or_nval, int so_err) {
  if (is_hup_or_nval)
    return 1;
  return tunnel_is_fatal_socket_errno(so_err);
}
