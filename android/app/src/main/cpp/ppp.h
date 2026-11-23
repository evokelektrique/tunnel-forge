#ifndef TUNNEL_FORGE_PPP_H
#define TUNNEL_FORGE_PPP_H

#include "esp_udp.h"
#include "l2tp.h"
#include "packet_endpoint.h"

#include <stddef.h>
#include <stdint.h>
#include <sys/socket.h>

/** Return value from ppp_negotiate_over_transport() when CCP/MPPE negotiation specifically failed. */
#define PPP_NEGOTIATE_MPPE_FAILED (-2)
#define PPP_NEGOTIATE_MPPE_REQUIRED_BY_PEER (-3)
#define PPP_NEGOTIATE_AUTH_MISMATCH (-4)

/** Transport adapter shared by L2TP (ESP/UDP) and PPTP (Enhanced GRE over root helper). */
typedef struct {
  void *ctx;
  int (*send_frame)(void *ctx, const uint8_t *ppp, size_t len);
  /** Returns PPP frame length (>0), -1 on timeout/error, -2 on remote peer teardown. */
  int (*recv_frame)(void *ctx, uint8_t *out, size_t cap, int timeout_ms);
  int lcp_opened;
  int enable_mppe;
  int auth_policy; /**< TUNNEL_PPP_AUTH_* (0 = AUTO) */
  int mppe_mode;   /**< TUNNEL_MPPE_* (0 = AUTO, 1 = ON, 2 = OFF) */
} ppp_transport_t;

/** LCP + auth + optional CCP/MPPE (PPTP) + IPCP over a generic PPP transport. */
int ppp_negotiate_over_transport(ppp_transport_t *transport, const char *user, const char *password, int tun_mtu,
                                 ppp_session_t *ppp);

/** TUN IPv4 packet -> optional MPPE -> PPP frame -> transport. */
int ppp_encapsulate_and_send_over_transport(ppp_transport_t *transport, ppp_session_t *ppp, const uint8_t *ip_packet,
                                            size_t len);

/** Inbound PPP frame from transport: MPPE decrypt (0x00FD), IPv4 to endpoint, CCP Reset, IPv6CP reject, LCP Echo. */
int ppp_dispatch_ppp_frame_over_transport(ppp_transport_t *transport, ppp_session_t *ppp, const uint8_t *frame,
                                          size_t len, packet_endpoint_t *endpoint);

/** Send an RFC 1661 LCP Echo-Request probe over transport; returns >= 0 or -1 with errno preserved. */
int ppp_send_lcp_echo_request_over_transport(ppp_transport_t *transport, ppp_session_t *ppp, uint8_t id);

/** Zero MPPE keys and MS-CHAPv2 secrets stored in @p ppp. */
void ppp_session_clear_secrets(ppp_session_t *ppp);

/** LCP + auth + IPCP on the L2TP session (recv/tx over esp_fd). */
int ppp_negotiate(int esp_fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t peer_len, l2tp_session_t *l2tp,
                  const char *user, const char *password, int tun_mtu, int auth_policy, ppp_session_t *ppp);

/** TUN IPv4 packet -> PPP/L2TP/ESP toward peer (checksum fix + MSS clamp per ppp_session_t). */
int ppp_encapsulate_and_send(int esp_fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t peer_len,
                             l2tp_session_t *l2tp, ppp_session_t *ppp, const uint8_t *ip_packet, size_t len);

/** Inbound PPP from peer: IPv4 to endpoint; IPv6CP/LCP handled per implementation in ppp.c. */
int ppp_dispatch_ppp_frame(int esp_fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t peer_len,
                           l2tp_session_t *l2tp, ppp_session_t *ppp, const uint8_t *frame, size_t len,
                           packet_endpoint_t *endpoint);

/** Send an RFC 1661 LCP Echo-Request probe over L2TP/ESP; returns >= 0 or -1 with errno preserved. */
int ppp_send_lcp_echo_request(int esp_fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t peer_len,
                              l2tp_session_t *l2tp, ppp_session_t *ppp, uint8_t id);

#endif
