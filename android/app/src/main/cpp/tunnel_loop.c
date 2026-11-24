/*
 * Orchestrates IKE+ESP, L2TP, and PPP (tunnel_negotiate), then polls TUN and the ESP socket
 * (tunnel_run_loop). g_state holds the negotiated session between phases; g_stop is set from
 * JNI via tunnel_loop_stop for cooperative shutdown.
 */
#include "engine.h"
#include "packet_endpoint.h"

#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "esp_udp.h"
#include "ikev1.h"
#include "ipv4_dataplane.h"
#include "l2tp.h"
#include "nat_t_keepalive.h"
#include "ppp.h"
#include "pptp.h"
#include "tunnel_liveness.h"
#include "util_endian.h"

#define LOG_TAG "tunnel_engine"
#define VPN_DNS_PORT 53u
#define VPN_DNS_IPPROTO_TCP 6u
#define VPN_DNS_IPPROTO_UDP 17u
#define VPN_DNS_TCP_RST_LEN 40u

static atomic_int g_stop;

static pthread_mutex_t g_pptp_cfg_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_pptp_helper_path[512];
static char g_pptp_bind_iface[24];

static struct {
  int protocol;
  ike_session_t ike;
  esp_keys_t esp;
  l2tp_session_t l2tp;
  pptp_session_t pptp;
  ppp_session_t ppp;
  int ready;
} g_state;

void engine_set_pptp_runtime_config(const char *helper_path, const char *bind_iface) {
  pthread_mutex_lock(&g_pptp_cfg_lock);
  if (helper_path != NULL) {
    snprintf(g_pptp_helper_path, sizeof(g_pptp_helper_path), "%s", helper_path);
  } else {
    g_pptp_helper_path[0] = '\0';
  }
  if (bind_iface != NULL) {
    snprintf(g_pptp_bind_iface, sizeof(g_pptp_bind_iface), "%s", bind_iface);
  } else {
    g_pptp_bind_iface[0] = '\0';
  }
  pthread_mutex_unlock(&g_pptp_cfg_lock);
}

static proxy_packet_queue_ctx_t g_proxy_queue;
static atomic_int g_proxy_bridge_active;
static atomic_int g_proxy_bridge_users;
static proxy_packet_queue_ctx_t g_vpn_dns_queue;
static atomic_int g_vpn_dns_bridge_active;
static atomic_int g_vpn_dns_users;

static void tunnel_teardown_proxy_queue(atomic_int *active_flag, atomic_int *users_count,
                                        proxy_packet_queue_ctx_t *ctx) {
  atomic_store(active_flag, 0);
  packet_endpoint_close_proxy_queue(ctx);
  while (atomic_load(users_count) > 0) {
    struct timespec ts = {.tv_sec = 0, .tv_nsec = 1000000L};
    (void)nanosleep(&ts, NULL);
  }
  packet_endpoint_destroy_proxy_queue(ctx);
}
static atomic_int g_vpn_dns_tun_fd = ATOMIC_VAR_INIT(-1);
static uint8_t g_vpn_dns_ipv4[4];
static atomic_int g_vpn_dns_intercept_enabled;

void tunnel_loop_stop(void) { atomic_store(&g_stop, 1); }

int tunnel_should_stop(void) { return atomic_load(&g_stop) ? 1 : 0; }

static int parse_ipv4_literal(const char *ipv4, uint8_t out[4]) {
  if (ipv4 == NULL || out == NULL)
    return -1;
  unsigned int a, b, c, d;
  char tail;
  if (sscanf(ipv4, "%u.%u.%u.%u%c", &a, &b, &c, &d, &tail) != 4)
    return -1;
  if (a > 255u || b > 255u || c > 255u || d > 255u)
    return -1;
  out[0] = (uint8_t)a;
  out[1] = (uint8_t)b;
  out[2] = (uint8_t)c;
  out[3] = (uint8_t)d;
  return 0;
}

static uint16_t read_be16_u8(const uint8_t *p) { return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]); }

static uint32_t vpn_dns_csum_acc_bytes(uint32_t sum, const uint8_t *p, size_t n) {
  for (size_t i = 0; i < n; i += 2) {
    uint32_t w = (uint32_t)p[i] << 8;
    if (i + 1 < n)
      w |= p[i + 1];
    sum += w;
  }
  return sum;
}

static uint16_t vpn_dns_inet_checksum_fold(uint32_t sum) {
  while (sum >> 16) {
    sum = (sum & 0xffffu) + (sum >> 16);
  }
  return (uint16_t)~sum;
}

typedef enum {
  VPN_DNS_PACKET_NONE = 0,
  VPN_DNS_PACKET_UDP,
  VPN_DNS_PACKET_TCP,
} vpn_dns_packet_kind_t;

static vpn_dns_packet_kind_t vpn_dns_packet_kind(const uint8_t *packet, size_t len) {
  if (!atomic_load(&g_vpn_dns_intercept_enabled) || packet == NULL || len < 28u)
    return 0;
  const uint8_t version = packet[0] >> 4;
  const size_t ihl = (size_t)(packet[0] & 0x0fu) * 4u;
  if (version != 4u || ihl < 20u || len < ihl + 8u)
    return 0;
  const uint16_t total_len = read_be16_u8(packet + 2);
  if (total_len < ihl + 8u || total_len > len)
    return 0;
  if (memcmp(packet + 16, g_vpn_dns_ipv4, 4u) != 0)
    return 0;
  if (packet[9] == VPN_DNS_IPPROTO_UDP) {
    const uint8_t *udp = packet + ihl;
    const uint16_t udp_len = read_be16_u8(udp + 4);
    if (udp_len < 8u || ihl + (size_t)udp_len > (size_t)total_len)
      return VPN_DNS_PACKET_NONE;
    return read_be16_u8(udp + 2) == VPN_DNS_PORT ? VPN_DNS_PACKET_UDP : VPN_DNS_PACKET_NONE;
  }
  if (packet[9] == VPN_DNS_IPPROTO_TCP) {
    if ((size_t)total_len < ihl + 20u)
      return VPN_DNS_PACKET_NONE;
    const uint8_t *tcp = packet + ihl;
    const size_t tcp_len = (size_t)total_len - ihl;
    const size_t tcp_hlen = (size_t)(tcp[12] >> 4) * 4u;
    if (tcp_hlen < 20u || tcp_hlen > tcp_len)
      return VPN_DNS_PACKET_NONE;
    return read_be16_u8(tcp + 2) == VPN_DNS_PORT ? VPN_DNS_PACKET_TCP : VPN_DNS_PACKET_NONE;
  }
  return VPN_DNS_PACKET_NONE;
}

static int vpn_dns_build_tcp_rst(const uint8_t *packet, size_t len, uint8_t out[VPN_DNS_TCP_RST_LEN]) {
  if (packet == NULL || out == NULL || len < 40u)
    return -1;
  const size_t ihl = (size_t)(packet[0] & 0x0fu) * 4u;
  const uint16_t total_len = read_be16_u8(packet + 2);
  if ((packet[0] >> 4) != 4u || ihl < 20u || total_len < ihl + 20u || total_len > len)
    return -1;
  if (packet[9] != VPN_DNS_IPPROTO_TCP || memcmp(packet + 16, g_vpn_dns_ipv4, 4u) != 0)
    return -1;
  const uint8_t *tcp = packet + ihl;
  const size_t tcp_len = (size_t)total_len - ihl;
  const size_t tcp_hlen = (size_t)(tcp[12] >> 4) * 4u;
  if (tcp_hlen < 20u || tcp_hlen > tcp_len || read_be16_u8(tcp + 2) != VPN_DNS_PORT)
    return -1;
  const uint8_t flags = tcp[13];
  if ((flags & 0x02u) == 0u)
    return -1;

  memset(out, 0, VPN_DNS_TCP_RST_LEN);
  out[0] = 0x45u;
  util_write_be16(out + 2, VPN_DNS_TCP_RST_LEN);
  util_write_be16(out + 6, 0x4000u);
  out[8] = 64u;
  out[9] = VPN_DNS_IPPROTO_TCP;
  memcpy(out + 12, packet + 16, 4u);
  memcpy(out + 16, packet + 12, 4u);
  util_write_be16(out + 10, vpn_dns_inet_checksum_fold(vpn_dns_csum_acc_bytes(0, out, 20u)));

  uint8_t *rst_tcp = out + 20u;
  util_write_be16(rst_tcp + 0, VPN_DNS_PORT);
  util_write_be16(rst_tcp + 2, read_be16_u8(tcp + 0));
  util_write_be32(rst_tcp + 4, 0u);
  uint32_t ack = util_read_be32(tcp + 4);
  ack += 1u;
  util_write_be32(rst_tcp + 8, ack);
  rst_tcp[12] = 0x50u;
  rst_tcp[13] = 0x14u;

  uint32_t sum = 0;
  sum = vpn_dns_csum_acc_bytes(sum, out + 12, 4u);
  sum = vpn_dns_csum_acc_bytes(sum, out + 16, 4u);
  sum += VPN_DNS_IPPROTO_TCP;
  sum += 20u;
  sum = vpn_dns_csum_acc_bytes(sum, rst_tcp, 20u);
  util_write_be16(rst_tcp + 16, vpn_dns_inet_checksum_fold(sum));
  return 0;
}

static int vpn_dns_intercept_query(const uint8_t *packet, size_t len) {
  vpn_dns_packet_kind_t kind = vpn_dns_packet_kind(packet, len);
  if (kind == VPN_DNS_PACKET_NONE)
    return 0;
  if (!atomic_load(&g_vpn_dns_bridge_active)) {
    tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "vpn dns query dropped: bridge inactive");
    return 1;
  }
  if (kind == VPN_DNS_PACKET_UDP) {
    if (packet_endpoint_proxy_enqueue_inbound(&g_vpn_dns_queue, packet, len) != 0) {
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "vpn dns query dropped: enqueue errno=%d", errno);
    }
    return 1;
  }
  uint8_t rst[VPN_DNS_TCP_RST_LEN];
  if (vpn_dns_build_tcp_rst(packet, len, rst) == 0 &&
      packet_endpoint_proxy_enqueue_outbound(&g_vpn_dns_queue, rst, sizeof(rst)) != 0) {
    tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "vpn dns tcp reset dropped: enqueue errno=%d", errno);
  }
  return 1;
}

static void vpn_dns_try_write_pending_response(packet_endpoint_t *endpoint, uint8_t *pending, size_t *pending_len) {
  if (endpoint == NULL || pending == NULL || pending_len == NULL || *pending_len == 0u)
    return;
  if (packet_endpoint_write(endpoint, pending, *pending_len) == 0) {
    *pending_len = 0u;
    return;
  }
  if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
    return;
  tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "vpn dns response dropped: tun write errno=%d", errno);
  *pending_len = 0u;
}

static void vpn_dns_drain_responses(packet_endpoint_t *endpoint, packet_endpoint_t *dns_endpoint, uint8_t *pending,
                                    size_t *pending_len, uint8_t *scratch, size_t scratch_len) {
  vpn_dns_try_write_pending_response(endpoint, pending, pending_len);
  while (*pending_len == 0u) {
    ssize_t n = packet_endpoint_read(dns_endpoint, scratch, scratch_len);
    if (n <= 0)
      return;
    memcpy(pending, scratch, (size_t)n);
    *pending_len = (size_t)n;
    vpn_dns_try_write_pending_response(endpoint, pending, pending_len);
  }
}

static int64_t monotonic_ms(void);

static int pptp_ppp_send_cb(void *ctx, const uint8_t *ppp, size_t len) {
  pptp_session_t *s = (pptp_session_t *)ctx;
  return pptp_send_ppp(s, ppp, len);
}

static int pptp_ppp_recv_cb(void *ctx, uint8_t *out, size_t cap, int timeout_ms) {
  pptp_session_t *s = (pptp_session_t *)ctx;
  if (s == NULL)
    return -1;
  const int64_t deadline = monotonic_ms() + (int64_t)timeout_ms;
  uint8_t gre[4096];
  for (;;) {
    if (tunnel_should_stop())
      return -1;
    if (pptp_root_has_buffered_frame(&s->root)) {
      int n = pptp_root_read_gre(&s->root, gre, sizeof(gre));
      if (n < 0)
        return -2;
      if (n > 0) {
        const uint8_t *ppp_ptr = NULL;
        size_t ppp_len = 0u;
        int ex = pptp_gre_extract_ppp(&s->gre, gre, (size_t)n, &ppp_ptr, &ppp_len);
        if (ex == 1 && ppp_len <= cap) {
          memcpy(out, ppp_ptr, ppp_len);
          return (int)ppp_len;
        }
        continue;
      }
    }
    int64_t rem = deadline - monotonic_ms();
    if (rem <= 0)
      return -1;
    int slice = rem > 200 ? 200 : (int)rem;
    struct pollfd fds[2];
    fds[0].fd = s->root.from_helper_fd;
    fds[0].events = POLLIN;
    fds[1].fd = s->ctrl_fd;
    fds[1].events = POLLIN;
    int pr = poll(fds, 2u, slice);
    if (pr < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    if (pr == 0)
      continue;
    if ((fds[1].revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
      int crc = pptp_dispatch_control(s);
      if (crc == PPTP_DISPATCH_REMOTE_CLOSED || crc == PPTP_DISPATCH_ERROR)
        return -2;
    }
    if ((fds[0].revents & (POLLHUP | POLLERR | POLLNVAL)) != 0 && (fds[0].revents & POLLIN) == 0)
      return -2;
    if ((fds[0].revents & POLLIN) != 0) {
      int n = pptp_root_read_gre(&s->root, gre, sizeof(gre));
      if (n < 0)
        return -2;
      if (n > 0) {
        const uint8_t *ppp_ptr = NULL;
        size_t ppp_len = 0u;
        int ex = pptp_gre_extract_ppp(&s->gre, gre, (size_t)n, &ppp_ptr, &ppp_len);
        if (ex == 1 && ppp_len <= cap) {
          memcpy(out, ppp_ptr, ppp_len);
          return (int)ppp_len;
        }
      }
    }
  }
}

static void tunnel_close_active_session(const char *reason, int send_teardown) {
  ppp_session_clear_secrets(&g_state.ppp);
  if (g_state.protocol == TUNNEL_PROTOCOL_PPTP) {
    pptp_close(&g_state.pptp, send_teardown);
    esp_keys_cleanup(&g_state.esp);
    g_state.ready = 0;
    return;
  }
  if (g_state.ike.esp_fd < 0) {
    esp_keys_cleanup(&g_state.esp);
    return;
  }
  if (send_teardown && g_state.l2tp.tunnel_id != 0) {
    if (l2tp_send_teardown(g_state.ike.esp_fd, &g_state.esp, (struct sockaddr *)&g_state.ike.peer, g_state.ike.peer_len,
                           &g_state.l2tp) != 0) {
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "l2tp teardown failed during close reason=%s",
                        reason != NULL ? reason : "unknown");
    }
  }
  esp_keys_cleanup(&g_state.esp);
  close(g_state.ike.esp_fd);
  g_state.ike.esp_fd = -1;
  g_state.ready = 0;
}

static int set_nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0)
    return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int tunnel_sanitize_mtu(int tun_mtu) {
  if (tun_mtu <= 0)
    return 0;
  if (tun_mtu < 576)
    return 576;
  if (tun_mtu > 1500)
    return 1500;
  return tun_mtu;
}

static void tunnel_format_mtu_label(int tun_mtu, char *buf, size_t cap) {
  if (tun_mtu <= 0) {
    snprintf(buf, cap, "auto");
  } else {
    snprintf(buf, cap, "%d", tun_mtu);
  }
}

static _Thread_local int worker_failure[3];

void tunnel_set_failure(int kind, int code, int general_error) {
  worker_failure[0] = kind;
  worker_failure[1] = code;
  worker_failure[2] = general_error;
}

void tunnel_get_failure(int out[3]) { memcpy(out, worker_failure, sizeof(worker_failure)); }

static const char *tunnel_ppp_auth_name(int ppp_auth) {
  switch (ppp_auth) {
  case TUNNEL_PPP_AUTH_MSCHAPV2:
    return "mschapv2";
  case TUNNEL_PPP_AUTH_CHAP_MD5:
    return "chap-md5";
  case TUNNEL_PPP_AUTH_PAP:
    return "pap";
  case TUNNEL_PPP_AUTH_AUTO:
  default:
    return "auto";
  }
}

static const char *tunnel_mppe_mode_name(int mppe_mode) {
  switch (mppe_mode) {
  case TUNNEL_MPPE_ON:
    return "on";
  case TUNNEL_MPPE_OFF:
    return "off";
  case TUNNEL_MPPE_AUTO:
  default:
    return "auto";
  }
}

static int tunnel_map_ppp_error(int ppp_rc) {
  if (ppp_rc == PPP_NEGOTIATE_MPPE_FAILED)
    return TUNNEL_EXIT_MPPE_FAILED;
  if (ppp_rc == PPP_NEGOTIATE_MPPE_REQUIRED_BY_PEER)
    return TUNNEL_EXIT_MPPE_REQUIRED_BY_PEER;
  if (ppp_rc == PPP_NEGOTIATE_AUTH_MISMATCH)
    return TUNNEL_EXIT_PPP_AUTH_MISMATCH;
  return TUNNEL_EXIT_PPP_FAILED;
}

static int tunnel_negotiate_pptp(const char *server, const char *user, const char *password, int tun_mtu, int ppp_auth,
                                 int mppe_mode) {
  pptp_session_init(&g_state.pptp);
  g_state.protocol = TUNNEL_PROTOCOL_PPTP;

  char helper_path[512];
  char bind_iface[24];
  pthread_mutex_lock(&g_pptp_cfg_lock);
  snprintf(helper_path, sizeof(helper_path), "%s", g_pptp_helper_path);
  snprintf(bind_iface, sizeof(bind_iface), "%s", g_pptp_bind_iface);
  pthread_mutex_unlock(&g_pptp_cfg_lock);

  if (pptp_connect(server, &g_state.pptp) != 0) {
    if (tunnel_should_stop()) {
      tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "tunnel negotiate canceled during PPTP control");
      return TUNNEL_EXIT_STOPPED;
    }
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "PPTP control handshake failed");
    return TUNNEL_EXIT_PPTP_FAILED;
  }

  int protect_vpn = engine_is_socket_protection_enabled();
  int root_rc = pptp_start_gre_helper(&g_state.pptp, helper_path, protect_vpn, bind_iface);
  if (root_rc != TUNNEL_EXIT_OK) {
    pptp_close(&g_state.pptp, 1);
    return root_rc;
  }

  ppp_transport_t pptp_transport;
  memset(&pptp_transport, 0, sizeof(pptp_transport));
  pptp_transport.ctx = &g_state.pptp;
  pptp_transport.send_frame = pptp_ppp_send_cb;
  pptp_transport.recv_frame = pptp_ppp_recv_cb;
  pptp_transport.enable_mppe = 1;
  pptp_transport.auth_policy = ppp_auth;
  pptp_transport.mppe_mode = mppe_mode;

  memset(&g_state.ppp, 0, sizeof(g_state.ppp));
  int ppp_rc = ppp_negotiate_over_transport(&pptp_transport, user, password, tun_mtu, &g_state.ppp);
  if (ppp_rc != 0) {
    if (tunnel_should_stop()) {
      tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "tunnel negotiate canceled during PPTP PPP");
      tunnel_close_active_session("canceled during PPTP PPP", 1);
      return TUNNEL_EXIT_STOPPED;
    }
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "PPTP PPP negotiation failed rc=%d", ppp_rc);
    tunnel_close_active_session("PPTP PPP negotiation failed", 1);
    return tunnel_map_ppp_error(ppp_rc);
  }

  (void)pptp_flush_gre_ack(&g_state.pptp);
  g_state.ready = 1;
  tunnel_log("tunnel negotiate ok (PPTP+GRE+PPP mppe=%d negotiated_mtu=%d)", g_state.ppp.mppe.enabled ? 1 : 0,
             tunnel_negotiated_mtu());
  return TUNNEL_EXIT_OK;
}

int tunnel_negotiate(const char *server, const char *user, const char *password, const char *psk, int tun_mtu,
                     int protocol, int ppp_auth, int mppe_mode) {
  if (g_state.ready) {
    tunnel_close_active_session("new negotiation", 1);
  }
  g_state.ready = 0;
  tunnel_set_failure(0, 0, 0);
  atomic_store(&g_stop, 0);
  tun_mtu = tunnel_sanitize_mtu(tun_mtu);
  if (ppp_auth < TUNNEL_PPP_AUTH_AUTO || ppp_auth > TUNNEL_PPP_AUTH_PAP)
    return TUNNEL_EXIT_BAD_ARGS;
  if (mppe_mode < TUNNEL_MPPE_AUTO || mppe_mode > TUNNEL_MPPE_OFF)
    return TUNNEL_EXIT_BAD_ARGS;
  if (protocol == TUNNEL_PROTOCOL_PPTP && mppe_mode == TUNNEL_MPPE_ON &&
      (ppp_auth == TUNNEL_PPP_AUTH_PAP || ppp_auth == TUNNEL_PPP_AUTH_CHAP_MD5)) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "invalid PPTP policy: MPPE On incompatible with ppp_auth=%s",
                      tunnel_ppp_auth_name(ppp_auth));
    return TUNNEL_EXIT_BAD_ARGS;
  }
  char mtu_label[16];
  tunnel_format_mtu_label(tun_mtu, mtu_label, sizeof(mtu_label));
  tunnel_log("tunnel negotiate protocol=%s server=%s tun_mtu=%s ppp_auth=%s mppe=%s",
             protocol == TUNNEL_PROTOCOL_PPTP ? "pptp" : "l2tp", server, mtu_label, tunnel_ppp_auth_name(ppp_auth),
             tunnel_mppe_mode_name(mppe_mode));

  if (protocol == TUNNEL_PROTOCOL_PPTP) {
    return tunnel_negotiate_pptp(server, user, password, tun_mtu, ppp_auth, mppe_mode);
  }
  if (protocol != TUNNEL_PROTOCOL_L2TP) {
    return TUNNEL_EXIT_BAD_ARGS;
  }

  g_state.protocol = TUNNEL_PROTOCOL_L2TP;
  memset(&g_state.ike, 0, sizeof(g_state.ike));
  g_state.ike.esp_fd = -1;
  memset(&g_state.esp, 0, sizeof(g_state.esp));

  if (ikev1_connect(server, psk, &g_state.ike, &g_state.esp) != 0) {
    if (tunnel_should_stop()) {
      tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "tunnel negotiate canceled during IKE");
      return TUNNEL_EXIT_STOPPED;
    }
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                      "ikev1_connect failed (IPsec/IKE). Filter logcat: adb logcat -s tunnel_engine:V");
    return TUNNEL_EXIT_IKE_FAILED;
  }

  memset(&g_state.l2tp, 0, sizeof(g_state.l2tp));
  if (l2tp_handshake(g_state.ike.esp_fd, &g_state.esp, (struct sockaddr *)&g_state.ike.peer, g_state.ike.peer_len,
                     &g_state.l2tp) != 0) {
    if (tunnel_should_stop()) {
      tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "tunnel negotiate canceled during L2TP");
      tunnel_close_active_session("canceled during L2TP", 0);
      return TUNNEL_EXIT_STOPPED;
    }
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "L2TP handshake failed");
    tunnel_close_active_session("L2TP handshake failed", 0);
    return TUNNEL_EXIT_L2TP_FAILED;
  }

  memset(&g_state.ppp, 0, sizeof(g_state.ppp));
  int ppp_rc = ppp_negotiate(g_state.ike.esp_fd, &g_state.esp, (struct sockaddr *)&g_state.ike.peer,
                             g_state.ike.peer_len, &g_state.l2tp, user, password, tun_mtu, ppp_auth, &g_state.ppp);
  if (ppp_rc != 0) {
    if (tunnel_should_stop()) {
      tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "tunnel negotiate canceled during PPP");
      tunnel_close_active_session("canceled during PPP", 1);
      return TUNNEL_EXIT_STOPPED;
    }
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "PPP negotiation failed rc=%d", ppp_rc);
    tunnel_close_active_session("PPP negotiation failed", 1);
    return tunnel_map_ppp_error(ppp_rc);
  }

  g_state.ready = 1;
  tunnel_log("tunnel negotiate ok (IKE+L2TP+PPP negotiated_mtu=%d)", tunnel_negotiated_mtu());
  return TUNNEL_EXIT_OK;
}

void tunnel_negotiated_client_ipv4(uint8_t out[4]) {
  if (out == NULL)
    return;
  memcpy(out, g_state.ppp.local_ip, 4);
}

void tunnel_negotiated_dns_ipv4(uint8_t primary_out[4], uint8_t secondary_out[4]) {
  if (primary_out != NULL)
    memcpy(primary_out, g_state.ppp.primary_dns, 4);
  if (secondary_out != NULL)
    memcpy(secondary_out, g_state.ppp.secondary_dns, 4);
}

int tunnel_negotiated_mtu(void) {
  if (g_state.ppp.link_mtu < 576u || g_state.ppp.link_mtu > 1500u)
    return 1450;
  return (int)g_state.ppp.link_mtu;
}

/*
 * Run the negotiated tunnel data plane for one packet endpoint.
 *
 * Preconditions:
 * - tunnel_negotiate() completed successfully and set g_state.ready.
 * - endpoint is initialized and supports packet_endpoint_read/write/poll_fd.
 * - tun_fd is a valid TUN descriptor for TUN-backed mode, or < 0 for proxy-only mode.
 *
 * Main phases:
 * 1) Initialization: clear g_stop, optionally enable VPN DNS interception bridge state.
 * 2) Poll loop: wait on endpoint + ESP socket (+ DNS queue when enabled).
 * 3) Packet routing: endpoint->PPP/ESP egress, ESP->L2TP/PPP ingress, optional DNS intercept queueing.
 * 4) Shutdown: close active session, clear DNS bridge atomics, destroy DNS queue endpoint state.
 *
 * Stop and return behavior:
 * - Loop runs until g_stop is set, or peer teardown is reported by l2tp_dispatch_incoming().
 * - Returns TUNNEL_EXIT_BAD_ARGS when called before negotiation.
 * - Returns TUNNEL_EXIT_POLL_ERROR on poll failure paths.
 * - Returns TUNNEL_EXIT_OK after normal/remote-requested shutdown cleanup.
 *
 * Shared side effects:
 * - Uses atomics g_stop, g_vpn_dns_bridge_active, g_vpn_dns_tun_fd.
 * - May call tunnel_close_active_session(), which closes ESP fd and clears g_state.ready.
 */
static int64_t monotonic_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    return (int64_t)time(NULL) * 1000LL;
  return (int64_t)ts.tv_sec * 1000LL + (int64_t)(ts.tv_nsec / 1000000LL);
}

static int send_dead_peer_probes(int esp_fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t peer_len,
                                 l2tp_session_t *l2tp, ppp_session_t *ppp, uint8_t probe_id) {
  if (l2tp_send_hello(esp_fd, esp, peer, peer_len, l2tp) < 0 && tunnel_is_fatal_socket_errno(errno)) {
    return -1;
  }
  if (ppp_send_lcp_echo_request(esp_fd, esp, peer, peer_len, l2tp, ppp, probe_id) < 0 &&
      tunnel_is_fatal_socket_errno(errno)) {
    return -1;
  }
  return 0;
}

static int send_dead_peer_probes_pptp(pptp_session_t *pptp, ppp_transport_t *transport, ppp_session_t *ppp,
                                      uint8_t probe_id) {
  if (pptp_send_echo_request(pptp) < 0 && (errno == EPIPE || errno == EBADF || tunnel_is_fatal_socket_errno(errno))) {
    return -1;
  }
  if (ppp_send_lcp_echo_request_over_transport(transport, ppp, probe_id) < 0 &&
      (errno == EPIPE || errno == EBADF || tunnel_is_fatal_socket_errno(errno))) {
    return -1;
  }
  return 0;
}

static int tunnel_is_fatal_pptp_errno(int err) {
  return err == EPIPE || err == EBADF || tunnel_is_fatal_socket_errno(err);
}

static int tunnel_run_loop_with_endpoint(int tun_fd, packet_endpoint_t *endpoint) {
  /* Readiness guard: run loop is only valid after negotiation state is established. */
  if (!g_state.ready) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "tunnel_run_loop: not negotiated");
    return TUNNEL_EXIT_BAD_ARGS;
  }
  /* Each invocation starts with cooperative stop cleared. */
  atomic_store(&g_stop, 0);
  const int is_pptp = (g_state.protocol == TUNNEL_PROTOCOL_PPTP);
  int vpn_dns_enabled_for_loop = 0;
  packet_endpoint_t vpn_dns_endpoint;
  /* Activate DNS intercept bridge only when TUN exists and feature flag is enabled. */
  if (tun_fd >= 0 && atomic_load(&g_vpn_dns_intercept_enabled)) {
    if (packet_endpoint_init_proxy_queue(&vpn_dns_endpoint, &g_vpn_dns_queue) == 0) {
      atomic_store(&g_vpn_dns_tun_fd, tun_fd);
      atomic_store(&g_vpn_dns_bridge_active, 1);
      vpn_dns_enabled_for_loop = 1;
      tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "vpn dns intercept active");
    } else {
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "vpn dns intercept disabled: queue init errno=%d", errno);
    }
  }

  const int endpoint_fd = packet_endpoint_poll_fd(endpoint);
  const int vpn_dns_fd = vpn_dns_enabled_for_loop ? packet_endpoint_poll_fd(&vpn_dns_endpoint) : -1;
  /* Poll fds are prepared once; loop mutates only events/revents and pending state. */
  if ((endpoint_fd >= 0 && set_nonblock(endpoint_fd) != 0) || (!is_pptp && set_nonblock(g_state.ike.esp_fd) != 0)) {
    tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "nonblock failed: errno=%d", errno);
  }

  ppp_transport_t pptp_transport;
  memset(&pptp_transport, 0, sizeof(pptp_transport));
  if (is_pptp) {
    pptp_transport.ctx = &g_state.pptp;
    pptp_transport.send_frame = pptp_ppp_send_cb;
    pptp_transport.recv_frame = pptp_ppp_recv_cb;
    pptp_transport.lcp_opened = 1;
    pptp_transport.enable_mppe = 1;
    tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG,
                      "tunnel poll loop (pptp): endpoint=%s fd=%d gre_fd=%d ctrl_fd=%d mppe=%d",
                      endpoint != NULL && endpoint->name != NULL ? endpoint->name : "unknown", endpoint_fd,
                      g_state.pptp.root.from_helper_fd, g_state.pptp.ctrl_fd, g_state.ppp.mppe.enabled ? 1 : 0);
  } else {
    tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "tunnel poll loop: endpoint=%s fd=%d esp_fd=%d udp_encap=%d",
                      endpoint != NULL && endpoint->name != NULL ? endpoint->name : "unknown", endpoint_fd,
                      g_state.ike.esp_fd, g_state.esp.udp_encap ? 1 : 0);
  }
  if (tun_fd >= 0) {
    engine_notify_tunnel_ready("TUN interface ready; tunnel loop active");
  }

  uint8_t tun_buf[65536];
  uint8_t esp_buf[65536];
  uint8_t vpn_dns_response_buf[65536];
  uint8_t vpn_dns_pending_response[65536];
  size_t vpn_dns_pending_response_len = 0u;
  time_t last_outbound_to_peer = time(NULL);
  tunnel_liveness_t liveness;
  tunnel_liveness_init(&liveness, monotonic_ms());

  int exit_code = TUNNEL_EXIT_OK;
  int send_teardown = 1;
  const char *close_reason = "tunnel stopped";

  /* Data-plane loop: handle endpoint egress, ESP/GRE ingress, liveness probes, and DNS bridge traffic. */
  while (!atomic_load(&g_stop)) {
    if (vpn_dns_enabled_for_loop && vpn_dns_pending_response_len > 0u) {
      vpn_dns_try_write_pending_response(endpoint, vpn_dns_pending_response, &vpn_dns_pending_response_len);
    }
    struct pollfd fds[4];
    nfds_t nfds = 0u;
    int dns_idx = -1;
    fds[0].fd = endpoint_fd;
    fds[0].events = POLLIN | (vpn_dns_pending_response_len > 0u ? POLLOUT : 0);
    int poll_timeout = 500;
    if (is_pptp) {
      fds[1].fd = g_state.pptp.root.from_helper_fd;
      fds[1].events = POLLIN;
      fds[2].fd = g_state.pptp.ctrl_fd;
      fds[2].events = POLLIN;
      nfds = 3u;
      if (vpn_dns_enabled_for_loop) {
        dns_idx = 3;
        fds[3].fd = vpn_dns_fd;
        fds[3].events = POLLIN;
        nfds = 4u;
      }
      if (pptp_root_has_buffered_frame(&g_state.pptp.root))
        poll_timeout = 0;
    } else {
      fds[1].fd = g_state.ike.esp_fd;
      fds[1].events = POLLIN;
      nfds = 2u;
      if (vpn_dns_enabled_for_loop) {
        dns_idx = 2;
        fds[2].fd = vpn_dns_fd;
        fds[2].events = POLLIN;
        nfds = 3u;
      }
    }
    int pr = poll(fds, nfds, poll_timeout);
    if (pr < 0) {
      if (errno == EINTR)
        continue;
      tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "poll failed errno=%d, closing session", errno);
      exit_code = TUNNEL_EXIT_POLL_ERROR;
      close_reason = "poll error";
      send_teardown = 0;
      break;
    }

    if (!is_pptp && pr > 0 && (fds[1].revents & (POLLERR | POLLHUP | POLLNVAL))) {
      int so_err = 0;
      socklen_t so_len = sizeof(so_err);
      if (getsockopt(g_state.ike.esp_fd, SOL_SOCKET, SO_ERROR, &so_err, &so_len) != 0)
        so_err = errno;
      tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "esp socket error revents=0x%x so_error=%d", fds[1].revents,
                        so_err);
      exit_code = TUNNEL_EXIT_NETWORK_LOST;
      close_reason = "esp socket error";
      send_teardown = 0;
      break;
    }

    if (is_pptp && pr > 0 && (fds[1].revents & (POLLERR | POLLHUP | POLLNVAL)) && !(fds[1].revents & POLLIN)) {
      tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp gre helper pipe closed revents=0x%x", fds[1].revents);
      exit_code = TUNNEL_EXIT_NETWORK_LOST;
      close_reason = "pptp gre helper closed";
      send_teardown = 0;
      break;
    }

    if (is_pptp && pr > 0 && (fds[2].revents & (POLLIN | POLLERR | POLLHUP | POLLNVAL))) {
      int crc = pptp_dispatch_control(&g_state.pptp);
      if (crc == PPTP_DISPATCH_INBOUND_ACTIVITY) {
        tunnel_liveness_on_inbound(&liveness, monotonic_ms());
      } else if (crc == PPTP_DISPATCH_REMOTE_CLOSED) {
        tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "peer requested PPTP teardown");
        exit_code = TUNNEL_EXIT_PEER_CLOSED;
        close_reason = "pptp peer teardown";
        send_teardown = 0;
        break;
      } else if (crc == PPTP_DISPATCH_ERROR) {
        tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp control socket error errno=%d", errno);
        exit_code = TUNNEL_EXIT_NETWORK_LOST;
        close_reason = "pptp control error";
        send_teardown = 0;
        break;
      }
    }

    if (pr == 0) {
      /* Idle tick: send NAT-T keepalive when due. */
      if (!is_pptp && g_state.esp.udp_encap && g_state.esp.enc_key_len) {
        time_t now = time(NULL);
        if (nat_t_keepalive_is_due(now, last_outbound_to_peer, NAT_T_KEEPALIVE_INTERVAL_SECS)) {
          uint8_t keepalive[1];
          const size_t keepalive_len = nat_t_keepalive_write_probe(keepalive, sizeof(keepalive));
          if (keepalive_len != 0u) {
            ssize_t sent = send(g_state.ike.esp_fd, keepalive, keepalive_len, 0);
            if (sent == (ssize_t)keepalive_len) {
              last_outbound_to_peer = now;
            } else {
              int send_err = errno;
              tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "nat-t keepalive send failed sent=%zd want=%zu errno=%d",
                                sent, keepalive_len, send_err);
              if (tunnel_is_fatal_socket_errno(send_err)) {
                exit_code = TUNNEL_EXIT_NETWORK_LOST;
                close_reason = "nat-t keepalive network lost";
                send_teardown = 0;
                break;
              }
            }
          }
        }
      }
    }

    if (pr > 0 && vpn_dns_enabled_for_loop && dns_idx >= 0 && (fds[dns_idx].revents & POLLIN)) {
      vpn_dns_drain_responses(endpoint, &vpn_dns_endpoint, vpn_dns_pending_response, &vpn_dns_pending_response_len,
                              vpn_dns_response_buf, sizeof(vpn_dns_response_buf));
    }

    if (pr > 0 && vpn_dns_enabled_for_loop && (fds[0].revents & POLLOUT) && vpn_dns_pending_response_len > 0u) {
      vpn_dns_try_write_pending_response(endpoint, vpn_dns_pending_response, &vpn_dns_pending_response_len);
    }

    if (pr > 0 && (fds[0].revents & POLLIN)) {
      /* Endpoint->peer egress path, with optional DNS query interception before PPP encapsulation. */
      ssize_t n = packet_endpoint_read(endpoint, tun_buf, sizeof(tun_buf));
      if (n > 0) {
        if (vpn_dns_enabled_for_loop && vpn_dns_intercept_query(tun_buf, (size_t)n)) {
          continue;
        }
        int encap_rc;
        if (is_pptp) {
          encap_rc = ppp_encapsulate_and_send_over_transport(&pptp_transport, &g_state.ppp, tun_buf, (size_t)n);
        } else {
          encap_rc = ppp_encapsulate_and_send(g_state.ike.esp_fd, &g_state.esp, (struct sockaddr *)&g_state.ike.peer,
                                              g_state.ike.peer_len, &g_state.l2tp, &g_state.ppp, tun_buf, (size_t)n);
        }
        if (encap_rc < 0) {
          int send_err = errno;
          tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "egress failed errno=%d", send_err);
          if (is_pptp ? tunnel_is_fatal_pptp_errno(send_err) : tunnel_is_fatal_socket_errno(send_err)) {
            exit_code = TUNNEL_EXIT_NETWORK_LOST;
            close_reason = "egress network lost";
            send_teardown = 0;
            break;
          }
        } else {
          last_outbound_to_peer = time(NULL);
        }
      }
    }

    if (is_pptp && ((pr > 0 && (fds[1].revents & POLLIN)) || pptp_root_has_buffered_frame(&g_state.pptp.root))) {
      /* Peer->endpoint PPTP ingress path: drain GRE frames from helper pipe, strip GRE, dispatch PPP/MPPE. */
      int burst_failed = 0;
      for (int burst = 0; burst < 64; burst++) {
        int gn = pptp_root_read_gre(&g_state.pptp.root, esp_buf, sizeof(esp_buf));
        if (gn < 0) {
          tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp gre helper read failed errno=%d", errno);
          exit_code = TUNNEL_EXIT_NETWORK_LOST;
          close_reason = "pptp gre read failed";
          send_teardown = 0;
          burst_failed = 1;
          break;
        }
        if (gn == 0)
          break;
        const uint8_t *ppp_ptr = NULL;
        size_t ppp_len = 0u;
        int ex = pptp_gre_extract_ppp(&g_state.pptp.gre, esp_buf, (size_t)gn, &ppp_ptr, &ppp_len);
        if (ex == 1) {
          tunnel_liveness_on_inbound(&liveness, monotonic_ms());
          int drc = ppp_dispatch_ppp_frame_over_transport(&pptp_transport, &g_state.ppp, ppp_ptr, ppp_len, endpoint);
          if (drc < 0 && tunnel_is_fatal_pptp_errno(errno)) {
            tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp ppp reply send failed errno=%d", errno);
            exit_code = TUNNEL_EXIT_NETWORK_LOST;
            close_reason = "pptp ppp reply failed";
            send_teardown = 0;
            burst_failed = 1;
            break;
          }
        }
      }
      if (burst_failed)
        break;
      if (pptp_flush_gre_ack(&g_state.pptp) < 0 && tunnel_is_fatal_pptp_errno(errno)) {
        tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp gre ack flush failed errno=%d", errno);
        exit_code = TUNNEL_EXIT_NETWORK_LOST;
        close_reason = "pptp gre ack failed";
        send_teardown = 0;
        break;
      }
    } else if (!is_pptp && pr > 0 && (fds[1].revents & POLLIN)) {
      /* Peer->endpoint ingress path: ESP receive, decrypt, then L2TP/PPP dispatch. */
      ssize_t n = recv(g_state.ike.esp_fd, esp_buf, sizeof(esp_buf), 0);
      if (n == 0) {
        tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "esp socket closed (EOF)");
        exit_code = TUNNEL_EXIT_NETWORK_LOST;
        close_reason = "esp socket eof";
        send_teardown = 0;
        break;
      }
      if (n < 0) {
        int recv_err = errno;
        if (recv_err != EINTR && recv_err != EAGAIN && recv_err != EWOULDBLOCK) {
          tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "esp recv failed errno=%d", recv_err);
          if (tunnel_is_fatal_socket_errno(recv_err)) {
            exit_code = TUNNEL_EXIT_NETWORK_LOST;
            close_reason = "esp recv network lost";
            send_teardown = 0;
            break;
          }
        }
      } else {
        if (g_state.esp.udp_encap && esp_is_nat_keepalive_probe(esp_buf, (size_t)n)) {
          continue;
        }
        uint8_t plain[65536];
        size_t plain_len = sizeof(plain);
        if (esp_try_decrypt(&g_state.esp, esp_buf, (size_t)n, plain, &plain_len) == 0 && plain_len > 0) {
          tunnel_liveness_on_inbound(&liveness, monotonic_ms());
          int dispatch_rc =
              l2tp_dispatch_incoming(g_state.ike.esp_fd, &g_state.esp, (struct sockaddr *)&g_state.ike.peer,
                                     g_state.ike.peer_len, &g_state.l2tp, plain, plain_len, endpoint, &g_state.ppp);
          if (dispatch_rc == L2TP_DISPATCH_REMOTE_CLOSED) {
            tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "peer requested L2TP tunnel teardown");
            exit_code = TUNNEL_EXIT_PEER_CLOSED;
            close_reason = "peer teardown";
            send_teardown = 1;
            break;
          }
          if (dispatch_rc < 0 && tunnel_is_fatal_socket_errno(errno)) {
            tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "l2tp reply send failed errno=%d", errno);
            exit_code = TUNNEL_EXIT_NETWORK_LOST;
            close_reason = "l2tp reply network lost";
            send_teardown = 0;
            break;
          }
        } else {
          static time_t s_last_esp_plain_warn;
          time_t now = time(NULL);
          if (now - s_last_esp_plain_warn >= 3) {
            s_last_esp_plain_warn = now;
            char detail[160];
            esp_decrypt_last_fail_snprint(detail, sizeof(detail));
            tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "esp recv n=%zd no plaintext: %s", n, detail);
          }
        }
      }
    }

    tunnel_liveness_action_t action = tunnel_liveness_check(&liveness, monotonic_ms());
    if (action == TUNNEL_LIVENESS_SEND_PROBE) {
      tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "peer inbound silent >= 15s; sending liveness probe #%d",
                        liveness.probes_sent);
      int probe_rc;
      if (is_pptp) {
        probe_rc = send_dead_peer_probes_pptp(&g_state.pptp, &pptp_transport, &g_state.ppp, liveness.next_probe_id);
      } else {
        probe_rc = send_dead_peer_probes(g_state.ike.esp_fd, &g_state.esp, (struct sockaddr *)&g_state.ike.peer,
                                         g_state.ike.peer_len, &g_state.l2tp, &g_state.ppp, liveness.next_probe_id);
      }
      if (probe_rc < 0) {
        tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "liveness probe send failed errno=%d", errno);
        exit_code = TUNNEL_EXIT_NETWORK_LOST;
        close_reason = "probe send network lost";
        send_teardown = 0;
        break;
      }
      last_outbound_to_peer = time(NULL);
    } else if (action == TUNNEL_LIVENESS_DEAD) {
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "dead peer detected: no authenticated reply for 30s");
      exit_code = TUNNEL_EXIT_PEER_UNREACHABLE;
      close_reason = "dead peer timeout";
      send_teardown = 0;
      break;
    }
  }

  /* Unified shutdown path for stop flag, peer teardown, and network/liveness failures. */
  tunnel_close_active_session(close_reason, send_teardown);
  if (vpn_dns_enabled_for_loop) {
    atomic_store(&g_vpn_dns_tun_fd, -1);
    tunnel_teardown_proxy_queue(&g_vpn_dns_bridge_active, &g_vpn_dns_users, &g_vpn_dns_queue);
  }
  tunnel_log("tunnel stopped");
  return exit_code;
}

int tunnel_run_loop(int tun_fd) {
  tun_packet_endpoint_ctx_t tun_ctx;
  packet_endpoint_t endpoint;
  packet_endpoint_init_tun(&endpoint, &tun_ctx, tun_fd);
  return tunnel_run_loop_with_endpoint(tun_fd, &endpoint);
}

int tunnel_run_proxy_loop(void) {
  if (!g_state.ready) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "tunnel_run_proxy_loop: not negotiated");
    return TUNNEL_EXIT_BAD_ARGS;
  }
  packet_endpoint_t endpoint;
  if (packet_endpoint_init_proxy_queue(&endpoint, &g_proxy_queue) != 0) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "proxy queue init failed errno=%d", errno);
    tunnel_close_active_session("proxy queue init failed", 1);
    return TUNNEL_EXIT_PROXY_NOT_IMPLEMENTED;
  }
  atomic_store(&g_proxy_bridge_active, 1);
  tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "proxy-only mode negotiated; native packet bridge active on endpoint=%s",
                    endpoint.name != NULL ? endpoint.name : "unknown");
  const int rc = tunnel_run_loop_with_endpoint(-1, &endpoint);
  tunnel_teardown_proxy_queue(&g_proxy_bridge_active, &g_proxy_bridge_users, &g_proxy_queue);
  return rc;
}

int tunnel_loop_run(int tun_fd, const char *server, const char *user, const char *password, const char *psk,
                    int tun_mtu, int protocol, int ppp_auth, int mppe_mode) {
  atomic_store(&g_stop, 0);
  char mtu_label[16];
  tunnel_format_mtu_label(tunnel_sanitize_mtu(tun_mtu), mtu_label, sizeof(mtu_label));
  tunnel_log("tunnel start protocol=%s server=%s tun_mtu=%s", protocol == TUNNEL_PROTOCOL_PPTP ? "pptp" : "l2tp",
             server, mtu_label);
  int rc = tunnel_negotiate(server, user, password, psk, tun_mtu, protocol, ppp_auth, mppe_mode);
  if (rc != TUNNEL_EXIT_OK)
    return rc;
  return tunnel_run_loop(tun_fd);
}

int tunnel_proxy_is_bridge_active(void) { return atomic_load(&g_proxy_bridge_active) ? 1 : 0; }

int tunnel_proxy_enqueue_outbound_packet(const uint8_t *packet, size_t len) {
  atomic_fetch_add(&g_proxy_bridge_users, 1);
  if (!atomic_load(&g_proxy_bridge_active)) {
    atomic_fetch_sub(&g_proxy_bridge_users, 1);
    errno = ENOSYS;
    return -1;
  }
  int rc = packet_endpoint_proxy_enqueue_outbound(&g_proxy_queue, packet, len);
  atomic_fetch_sub(&g_proxy_bridge_users, 1);
  return rc;
}

ssize_t tunnel_proxy_dequeue_inbound_packet(uint8_t *packet, size_t len) {
  return tunnel_proxy_dequeue_inbound_packet_wait(packet, len, 0);
}

ssize_t tunnel_proxy_dequeue_inbound_packet_wait(uint8_t *packet, size_t len, int timeout_ms) {
  atomic_fetch_add(&g_proxy_bridge_users, 1);
  if (!atomic_load(&g_proxy_bridge_active)) {
    atomic_fetch_sub(&g_proxy_bridge_users, 1);
    errno = ENOSYS;
    return -1;
  }
  ssize_t rc = packet_endpoint_proxy_dequeue_inbound_wait(&g_proxy_queue, packet, len, timeout_ms);
  atomic_fetch_sub(&g_proxy_bridge_users, 1);
  return rc;
}

int tunnel_vpn_dns_set_intercept_ipv4(const char *ipv4) {
  if (ipv4 == NULL || ipv4[0] == '\0') {
    atomic_store(&g_vpn_dns_intercept_enabled, 0);
    return 0;
  }
  uint8_t parsed[4];
  if (parse_ipv4_literal(ipv4, parsed) != 0) {
    errno = EINVAL;
    return -1;
  }
  memcpy(g_vpn_dns_ipv4, parsed, sizeof(g_vpn_dns_ipv4));
  atomic_store(&g_vpn_dns_intercept_enabled, 1);
  return 0;
}

ssize_t tunnel_vpn_dns_dequeue_query_wait(uint8_t *packet, size_t len, int timeout_ms) {
  atomic_fetch_add(&g_vpn_dns_users, 1);
  if (!atomic_load(&g_vpn_dns_bridge_active)) {
    atomic_fetch_sub(&g_vpn_dns_users, 1);
    errno = ENOSYS;
    return -1;
  }
  ssize_t rc = packet_endpoint_proxy_dequeue_inbound_wait(&g_vpn_dns_queue, packet, len, timeout_ms);
  atomic_fetch_sub(&g_vpn_dns_users, 1);
  return rc;
}

int tunnel_vpn_dns_write_response_packet(const uint8_t *packet, size_t len) {
  atomic_fetch_add(&g_vpn_dns_users, 1);
  if (!atomic_load(&g_vpn_dns_bridge_active)) {
    atomic_fetch_sub(&g_vpn_dns_users, 1);
    errno = ENOSYS;
    return -1;
  }
  if (packet == NULL || len == 0) {
    atomic_fetch_sub(&g_vpn_dns_users, 1);
    errno = EINVAL;
    return -1;
  }
  int rc = packet_endpoint_proxy_enqueue_outbound(&g_vpn_dns_queue, packet, len);
  atomic_fetch_sub(&g_vpn_dns_users, 1);
  return rc;
}
