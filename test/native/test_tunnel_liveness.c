#include "../../android/app/src/main/cpp/tunnel_liveness.h"

#include <errno.h>
#include <stdio.h>

static int test_probe_after_15s_and_dead_at_30s(void) {
  tunnel_liveness_t state;
  tunnel_liveness_init(&state, 1000);

  if (tunnel_liveness_check(&state, 15999) != TUNNEL_LIVENESS_OK)
    return 1;
  if (tunnel_liveness_check(&state, 16000) != TUNNEL_LIVENESS_SEND_PROBE)
    return 2;
  if (state.probes_sent != 1)
    return 3;

  /* No second probe before 5s retry spacing. */
  if (tunnel_liveness_check(&state, 20999) != TUNNEL_LIVENESS_OK)
    return 4;
  if (tunnel_liveness_check(&state, 21000) != TUNNEL_LIVENESS_SEND_PROBE)
    return 5;
  if (tunnel_liveness_check(&state, 26000) != TUNNEL_LIVENESS_SEND_PROBE)
    return 6;
  if (tunnel_liveness_check(&state, 30999) != TUNNEL_LIVENESS_OK)
    return 7;
  if (tunnel_liveness_check(&state, 31000) != TUNNEL_LIVENESS_DEAD)
    return 8;
  return 0;
}

static int test_inbound_packet_resets_liveness_window(void) {
  tunnel_liveness_t state;
  tunnel_liveness_init(&state, 1000);

  if (tunnel_liveness_check(&state, 16000) != TUNNEL_LIVENESS_SEND_PROBE)
    return 1;
  tunnel_liveness_on_inbound(&state, 20000);
  if (state.probes_sent != 0)
    return 2;
  if (tunnel_liveness_check(&state, 34999) != TUNNEL_LIVENESS_OK)
    return 3;
  if (tunnel_liveness_check(&state, 35000) != TUNNEL_LIVENESS_SEND_PROBE)
    return 4;
  return 0;
}

static int test_doze_jump_probes_before_declaring_dead(void) {
  tunnel_liveness_t state;
  tunnel_liveness_init(&state, 1000);

  /* Jump >30s without prior probe (e.g. CPU sleep): send one probe before declaring dead. */
  if (tunnel_liveness_check(&state, 40000) != TUNNEL_LIVENESS_SEND_PROBE)
    return 1;
  if (tunnel_liveness_check(&state, 44999) != TUNNEL_LIVENESS_OK)
    return 2;
  if (tunnel_liveness_check(&state, 45000) != TUNNEL_LIVENESS_DEAD)
    return 3;
  return 0;
}

static int test_fatal_socket_errno_classification(void) {
  if (!tunnel_is_fatal_socket_errno(EBADF))
    return 1;
  if (!tunnel_is_fatal_socket_errno(EPIPE))
    return 2;
#ifdef ENETUNREACH
  if (!tunnel_is_fatal_socket_errno(ENETUNREACH))
    return 3;
#endif
#ifdef ENETDOWN
  if (!tunnel_is_fatal_socket_errno(ENETDOWN))
    return 4;
#endif
#ifdef EHOSTUNREACH
  if (!tunnel_is_fatal_socket_errno(EHOSTUNREACH))
    return 5;
#endif
#ifdef ECONNREFUSED
  if (!tunnel_is_fatal_socket_errno(ECONNREFUSED))
    return 6;
#endif
  if (tunnel_is_fatal_socket_errno(EAGAIN))
    return 7;
  if (tunnel_is_fatal_socket_errno(EINTR))
    return 8;
#ifdef EMSGSIZE
  if (tunnel_is_fatal_socket_errno(EMSGSIZE))
    return 9;
#endif
  return 0;
}

static int test_fatal_esp_poll_event_classification(void) {
  if (tunnel_is_fatal_esp_poll_event(0, 0))
    return 1;
  if (tunnel_is_fatal_esp_poll_event(0, EAGAIN))
    return 2;
#ifdef EMSGSIZE
  if (tunnel_is_fatal_esp_poll_event(0, EMSGSIZE))
    return 3;
#endif
#ifdef ENETUNREACH
  if (!tunnel_is_fatal_esp_poll_event(0, ENETUNREACH))
    return 4;
#endif
#ifdef ECONNREFUSED
  if (!tunnel_is_fatal_esp_poll_event(0, ECONNREFUSED))
    return 5;
#endif
  if (!tunnel_is_fatal_esp_poll_event(1, 0))
    return 6;
#ifdef EMSGSIZE
  if (!tunnel_is_fatal_esp_poll_event(1, EMSGSIZE))
    return 7;
#endif
  return 0;
}

int main(void) {
  int rc = test_probe_after_15s_and_dead_at_30s();
  if (rc != 0) {
    fprintf(stderr, "test_probe_after_15s_and_dead_at_30s failed: %d\n", rc);
    return 1;
  }
  rc = test_inbound_packet_resets_liveness_window();
  if (rc != 0) {
    fprintf(stderr, "test_inbound_packet_resets_liveness_window failed: %d\n", rc);
    return 1;
  }
  rc = test_doze_jump_probes_before_declaring_dead();
  if (rc != 0) {
    fprintf(stderr, "test_doze_jump_probes_before_declaring_dead failed: %d\n", rc);
    return 1;
  }
  rc = test_fatal_socket_errno_classification();
  if (rc != 0) {
    fprintf(stderr, "test_fatal_socket_errno_classification failed: %d\n", rc);
    return 1;
  }
  rc = test_fatal_esp_poll_event_classification();
  if (rc != 0) {
    fprintf(stderr, "test_fatal_esp_poll_event_classification failed: %d\n", rc);
    return 1;
  }
  puts("test_tunnel_liveness: ok");
  return 0;
}
