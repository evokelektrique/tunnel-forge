/*
 * PPP over L2TP data channel: LCP, authentication (PAP, MS-CHAPv2, CHAP-MD5), IPCP for IPv4,
 * then IP frames (0x0021) to/from the TUN fd. recv_ppp loops on the ESP socket until a PPP frame
 * for the current L2TP session is available.
 */
#include "ppp.h"

#include "engine.h"
#include "esp_udp.h"
#include "ipv4_dataplane.h"
#include "nat_t_keepalive.h"
#include "ppp_mppe.h"
#include "ppp_mschap.h"
#include "ppp_wire.h"

#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <mbedtls/md5.h>
#include <mbedtls/platform_util.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define LOG_TAG "tunnel_engine"
#define PROTO_IP PPP_WIRE_PROTO_IP
#define PROTO_LCP PPP_WIRE_PROTO_LCP
#define PROTO_PAP PPP_WIRE_PROTO_PAP
#define PROTO_CHAP PPP_WIRE_PROTO_CHAP
#define PROTO_IPCP PPP_WIRE_PROTO_IPCP
#define PROTO_CCP PPP_PROTO_CCP
#define PROTO_MPPE_DATA PPP_PROTO_MPPE_DATA
/** IPv6CP (IANA / RFC 5072); gateway may offer after IPv4 IPCP - we send LCP Protocol-Reject. */
#define PROTO_IPV6CP 0x8057u
#define LCP_CODE_PROTOCOL_REJECT 8u
#define LCP_CODE_ECHO_REQUEST PPP_LCP_CODE_ECHO_REQUEST
#define LCP_CODE_ECHO_REPLY PPP_LCP_CODE_ECHO_REPLY
#define CCP_CODE_RESET_REQUEST 14u
#define CCP_CODE_RESET_ACK 15u

static const char *ppp_auth_name(ppp_auth_kind_t auth) {
  switch (auth) {
  case PPP_AUTH_PAP:
    return "pap";
  case PPP_AUTH_MSCHAPV2:
    return "mschapv2";
  case PPP_AUTH_CHAP_MD5:
    return "chap-md5";
  default:
    return "unknown";
  }
}

static int ppp_read_protocol(const uint8_t *frame, size_t frame_len, uint16_t *proto_out, size_t *proto_len_out) {
  if (frame == NULL || proto_out == NULL || proto_len_out == NULL || frame_len == 0u)
    return -1;
  if ((frame[0] & 0x01u) != 0u) {
    *proto_out = frame[0];
    *proto_len_out = 1u;
    return 0;
  }
  if (frame_len < 2u)
    return -1;
  *proto_out = util_read_be16(frame);
  *proto_len_out = 2u;
  return 0;
}

static void ppp_log_rx_summary(const uint8_t *p, size_t len, const char *stage) {
  uint16_t proto = 0u;
  size_t proto_len = 0u;
  if (ppp_read_protocol(p, len, &proto, &proto_len) != 0 || len < proto_len + 2u)
    return;
  uint8_t code = p[proto_len + 0u];
  uint8_t id = p[proto_len + 1u];
  tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp rx stage=%s proto=0x%04x code=%u id=%u len=%zu", stage,
                    (unsigned)proto, (unsigned)code, (unsigned)id, len);
}

static int lcp_build_reject_for_unsupported(const uint8_t *frame, size_t prefix, const uint8_t *body, size_t body_len,
                                            uint8_t *out, size_t cap);
static int lcp_build_nak_for_disallowed_auth(const uint8_t *frame, size_t prefix, const uint8_t *body, size_t body_len,
                                             int required_auth, uint8_t *out, size_t cap);

static int ppp_effective_required_auth(const ppp_transport_t *transport) {
  if (transport == NULL)
    return -1;
  switch (transport->auth_policy) {
  case TUNNEL_PPP_AUTH_MSCHAPV2:
    return (int)PPP_AUTH_MSCHAPV2;
  case TUNNEL_PPP_AUTH_CHAP_MD5:
    return (int)PPP_AUTH_CHAP_MD5;
  case TUNNEL_PPP_AUTH_PAP:
    return (int)PPP_AUTH_PAP;
  case TUNNEL_PPP_AUTH_AUTO:
  default:
    if (transport->enable_mppe && transport->mppe_mode == TUNNEL_MPPE_ON)
      return (int)PPP_AUTH_MSCHAPV2;
    return -1;
  }
}

static int ppp_auth_mismatch_rc(const ppp_transport_t *transport) {
  if (transport != NULL && transport->auth_policy == TUNNEL_PPP_AUTH_AUTO && transport->enable_mppe &&
      transport->mppe_mode == TUNNEL_MPPE_ON) {
    return PPP_NEGOTIATE_MPPE_FAILED;
  }
  return PPP_NEGOTIATE_AUTH_MISMATCH;
}

static long long ppp_now_ms(void) {
  struct timeval now;
  gettimeofday(&now, NULL);
  return ((long long)now.tv_sec * 1000ll) + ((long long)now.tv_usec / 1000ll);
}

/**
 * Receive one PPP frame from the L2TP data channel within a deadline.
 *
 * Polls @p esp_fd in short slices, decrypts ESP when configured, strips L2TP data header via
 * l2tp_data_extract_ppp(), and copies the PPP payload into @p out.
 *
 * @return PPP payload length on success; -1 on cancel, timeout, socket error, or oversize payload.
 */
static int recv_ppp(int esp_fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t peer_len, l2tp_session_t *l2tp,
                    uint8_t *out, size_t cap, int ms) {
  struct timeval start;
  gettimeofday(&start, NULL);
  for (;;) {
    if (tunnel_should_stop()) {
      tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "ppp recv canceled before poll");
      return -1;
    }
    struct timeval now;
    gettimeofday(&now, NULL);
    int elapsed_ms = (int)((now.tv_sec - start.tv_sec) * 1000 + (now.tv_usec - start.tv_usec) / 1000);
    if (elapsed_ms >= ms) {
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp recv deadline elapsed=%d budget_ms=%d", elapsed_ms, ms);
      return -1;
    }
    int slice_ms = ms - elapsed_ms;
    if (slice_ms <= 0)
      return -1;
    struct pollfd pfd = {.fd = esp_fd, .events = POLLIN};
    int waited = 0;
    int pr = 0;
    while (waited < slice_ms) {
      if (tunnel_should_stop()) {
        tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "ppp recv canceled while waiting for frame");
        return -1;
      }
      int poll_slice_ms = slice_ms - waited;
      if (poll_slice_ms > 200)
        poll_slice_ms = 200;
      pr = poll(&pfd, 1, poll_slice_ms);
      waited += poll_slice_ms;
      if (pr != 0)
        break;
    }
    if (pr <= 0) {
      if (pr < 0 && errno == EINTR && tunnel_should_stop()) {
        tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "ppp recv canceled after poll interruption");
        return -1;
      }
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp recv timeout/poll failure slice_ms=%d pr=%d", slice_ms, pr);
      return -1;
    }

    uint8_t raw[4096];
    ssize_t n = recv(esp_fd, raw, sizeof(raw), 0);
    if (n <= 0) {
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp recv socket failure n=%zd errno=%d", n, errno);
      return -1;
    }

    if (esp->udp_encap && (nat_t_keepalive_is_probe(raw, (size_t)n) || (n >= 4 && util_read_be32(raw) == 0u)))
      continue;

    uint8_t plain[4096];
    size_t plen = sizeof(plain);
    if (esp->enc_key_len == 0) {
      if ((size_t)n > plen)
        continue;
      memcpy(plain, raw, (size_t)n);
      plen = (size_t)n;
    } else {
      /* Decrypt failures are non-fatal: peer may send IKE/NAT-T noise on same socket. */
      if (esp_try_decrypt(esp, raw, (size_t)n, plain, &plen) != 0) {
        char detail[160];
        esp_decrypt_last_fail_snprint(detail, sizeof(detail));
        tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp recv decrypt failed raw_len=%zd %s", n, detail);
        continue;
      }
    }

    if (plen < 6u) {
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp recv short decap plen=%zu", plen);
      continue;
    }
    const uint8_t *ppp_ptr = NULL;
    size_t ppp_len = 0;
    if ((util_read_be16(plain + 0) & 0x8000u) != 0) {
      /* L2TP control message during PPP setup (HELLO, StopCCN, CDN, retransmits): ack it with a ZLB so the
       * LNS stops retransmitting, log result/error text, and abort immediately on remote teardown instead of
       * waiting for the LCP timeout. */
      int dr = l2tp_dispatch_incoming(esp_fd, esp, peer, peer_len, l2tp, plain, plen, NULL, NULL);
      if (dr == L2TP_DISPATCH_REMOTE_CLOSED) {
        tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp recv: L2TP peer closed tunnel/session during PPP setup");
        return -2;
      }
      continue;
    }
    if (l2tp_data_extract_ppp(plain, plen, l2tp, &ppp_ptr, &ppp_len, 0) != 0) {
      uint16_t flags = util_read_be16(plain + 0);
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp recv l2tp not-ppp-data flags=0x%04x plen=%zu", (unsigned)flags,
                        plen);
      continue;
    }
    if (ppp_len > cap)
      return -1;
    memcpy(out, ppp_ptr, ppp_len);
    tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp recv payload ok len=%zu", ppp_len);
    return (int)ppp_len;
  }
}

static int send_ppp(int esp_fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t peer_len, l2tp_session_t *l2tp,
                    const uint8_t *ppp, size_t len) {
  return l2tp_send_ppp(esp_fd, esp, peer, peer_len, l2tp, ppp, len);
}

typedef struct {
  int esp_fd;
  esp_keys_t *esp;
  const struct sockaddr *peer;
  socklen_t peer_len;
  l2tp_session_t *l2tp;
} ppp_l2tp_ctx_t;

static int ppp_l2tp_transport_send(void *ctx, const uint8_t *ppp, size_t len) {
  ppp_l2tp_ctx_t *l = (ppp_l2tp_ctx_t *)ctx;
  if (l == NULL || l->esp == NULL || l->l2tp == NULL) {
    errno = EINVAL;
    return -1;
  }
  return send_ppp(l->esp_fd, l->esp, l->peer, l->peer_len, l->l2tp, ppp, len);
}

static int ppp_l2tp_transport_recv(void *ctx, uint8_t *out, size_t cap, int timeout_ms) {
  ppp_l2tp_ctx_t *l = (ppp_l2tp_ctx_t *)ctx;
  if (l == NULL || l->esp == NULL || l->l2tp == NULL)
    return -1;
  return recv_ppp(l->esp_fd, l->esp, l->peer, l->peer_len, l->l2tp, out, cap, timeout_ms);
}

static void ppp_init_l2tp_transport(ppp_transport_t *transport, ppp_l2tp_ctx_t *ctx, int esp_fd, esp_keys_t *esp,
                                    const struct sockaddr *peer, socklen_t peer_len, l2tp_session_t *l2tp,
                                    int auth_policy) {
  ctx->esp_fd = esp_fd;
  ctx->esp = esp;
  ctx->peer = peer;
  ctx->peer_len = peer_len;
  ctx->l2tp = l2tp;
  memset(transport, 0, sizeof(*transport));
  transport->ctx = ctx;
  transport->send_frame = ppp_l2tp_transport_send;
  transport->recv_frame = ppp_l2tp_transport_recv;
  transport->lcp_opened = l2tp != NULL ? l2tp->lcp_opened : 0;
  transport->enable_mppe = 0;
  transport->auth_policy = auth_policy;
  transport->mppe_mode = TUNNEL_MPPE_OFF;
}

static int ppp_transport_send(ppp_transport_t *transport, const uint8_t *ppp, size_t len) {
  if (transport == NULL || transport->send_frame == NULL) {
    errno = EINVAL;
    return -1;
  }
  return transport->send_frame(transport->ctx, ppp, len);
}

static int ppp_transport_recv(ppp_transport_t *transport, uint8_t *out, size_t cap, int timeout_ms) {
  if (transport == NULL || transport->recv_frame == NULL)
    return -1;
  for (;;) {
    int n = transport->recv_frame(transport->ctx, out, cap, timeout_ms);
    if (n <= 0)
      return n;
    if (transport->lcp_opened) {
      const uint8_t *lb = out;
      size_t ll = (size_t)n;
      size_t pre = 0u;
      if (ll >= 2u && lb[0] == 0xff && lb[1] == 0x03)
        pre = 2u;
      if (ll >= pre + 6u && util_read_be16(lb + pre) == PROTO_LCP && lb[pre + 2u] == 1u) {
        uint8_t rsp[256];
        int rl = lcp_build_reject_for_unsupported(lb, pre, lb + pre, ll - pre, rsp, sizeof(rsp));
        if (rl == 0) {
          rl = lcp_build_nak_for_disallowed_auth(lb, pre, lb + pre, ll - pre, ppp_effective_required_auth(transport),
                                                 rsp, sizeof(rsp));
        }
        if (rl == 0 && ll <= sizeof(rsp)) {
          memcpy(rsp, lb, ll);
          rsp[pre + 2u] = 2u; /* Configure-Ack */
          rl = (int)ll;
        }
        if (rl > 0) {
          (void)ppp_transport_send(transport, rsp, (size_t)rl);
          tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "ppp: answered late LCP Configure-Request id=%u (%s)",
                            (unsigned)lb[pre + 3u],
                            rsp[pre + 2u] == 2u ? "ack" : (rsp[pre + 2u] == 3u ? "nak auth" : "reject"));
        }
        continue;
      }
    }
    return n;
  }
}

static void ppp_strip(const uint8_t *frame, size_t frame_len, const uint8_t **body, size_t *body_len) {
  *body = frame;
  *body_len = frame_len;
  if (*body_len >= 2 && (*body)[0] == 0xff && (*body)[1] == 0x03) {
    *body += 2;
    *body_len -= 2;
  }
}

static int urandom_bytes(uint8_t *b, size_t n) {
  int fd = open("/dev/urandom", O_RDONLY);
  if (fd < 0)
    return -1;
  ssize_t r = read(fd, b, n);
  close(fd);
  return r == (ssize_t)n ? 0 : -1;
}

/** Authentication-Protocol option (type 3, [opt] = type byte) this client implements: PAP, CHAP-MD5, MS-CHAPv2. */
static int lcp_auth_option_supported(const uint8_t *opt, uint8_t ol) {
  if (ol < 4u)
    return 0;
  uint16_t proto = util_read_be16(opt + 2u);
  if (proto == PROTO_PAP)
    return 1;
  return proto == PROTO_CHAP && ol >= 5u && (opt[4] == 0x05u || opt[4] == 0x81u);
}

static int lcp_auth_option_allowed(const uint8_t *opt, uint8_t ol, int required_auth) {
  if (!lcp_auth_option_supported(opt, ol))
    return 0;
  if (required_auth < 0)
    return 1;
  uint16_t proto = util_read_be16(opt + 2u);
  ppp_auth_kind_t kind =
      proto == PROTO_PAP ? PPP_AUTH_PAP : (opt[4] == 0x81u ? PPP_AUTH_MSCHAPV2 : PPP_AUTH_CHAP_MD5);
  return (int)kind == required_auth;
}

/* Read Authentication-Protocol from peer LCP Configure-Request ([lcp] = first byte is code). */
static int lcp_parse_peer_auth_for_policy(const uint8_t *lcp, size_t lcp_len, int required_auth,
                                          ppp_auth_kind_t *out, int *saw_auth_opt_out) {
  if (saw_auth_opt_out != NULL)
    *saw_auth_opt_out = 0;
  if (lcp_len < 6u || out == NULL)
    return -1;
  const uint8_t *opts = lcp + 4u;
  size_t rem = lcp_len - 4u;
  size_t i = 0;
  while (i + 2u <= rem) {
    uint8_t t = opts[i];
    uint8_t ol = opts[i + 1u];
    if (ol < 2u || i + (size_t)ol > rem)
      break;
    if (t == 3u && saw_auth_opt_out != NULL)
      *saw_auth_opt_out = 1;
    /* Unsupported or policy-disallowed protocols are Configure-Nak'd, never adopted. */
    if (t == 3u && lcp_auth_option_allowed(opts + i, ol, required_auth)) {
      uint16_t proto = util_read_be16(opts + i + 2u);
      if (proto == PROTO_PAP)
        *out = PPP_AUTH_PAP;
      else
        *out = opts[i + 4u] == 0x81u ? PPP_AUTH_MSCHAPV2 : PPP_AUTH_CHAP_MD5;
      return 0;
    }
    i += (size_t)ol;
  }
  return -1;
}

static int lcp_nak_wants_pap(const uint8_t *opt, size_t opt_len) {
  size_t i = 0;
  while (i + 2 <= opt_len) {
    uint8_t t = opt[i];
    uint8_t l = opt[i + 1];
    if (l < 2 || i + l > opt_len)
      break;
    if (t == 3 && l >= 4 && opt[i + 2] == 0xc0 && opt[i + 3] == 0x23)
      return 1;
    i += l;
  }
  return 0;
}

/* Applies RFC1661 Configure-Reject payload to our outgoing Configure-Request option set. */
/** Peer LCP Configure-Request: option type 8 = Address-and-Control-Field-Compression (RFC 1661). */
static void lcp_peer_cr_note_acfc(const uint8_t *lcp, size_t lcp_len, int *lcp_acfc_out) {
  if (lcp_len < 6u || lcp_acfc_out == NULL)
    return;
  const uint8_t *opts = lcp + 4u;
  size_t rem = lcp_len - 4u;
  size_t i = 0;
  while (i + 2u <= rem) {
    uint8_t t = opts[i];
    uint8_t ol = opts[i + 1u];
    if (ol < 2u || i + (size_t)ol > rem)
      break;
    if (t == 8u) {
      *lcp_acfc_out = 1;
      return;
    }
    i += (size_t)ol;
  }
}

/** Peer LCP Configure-Request: option type 7 = Protocol-Field-Compression (RFC 1661). */
static void lcp_peer_cr_note_pfc(const uint8_t *lcp, size_t lcp_len, int *lcp_pfc_out) {
  if (lcp_len < 6u || lcp_pfc_out == NULL)
    return;
  const uint8_t *opts = lcp + 4u;
  size_t rem = lcp_len - 4u;
  size_t i = 0;
  while (i + 2u <= rem) {
    uint8_t t = opts[i];
    uint8_t ol = opts[i + 1u];
    if (ol < 2u || i + (size_t)ol > rem)
      break;
    if (t == 7u) {
      *lcp_pfc_out = 1;
      return;
    }
    i += (size_t)ol;
  }
}

/**
 * Build an LCP Configure-Reject for peer Configure-Request options this client does not implement:
 * Callback (13), Multilink MRRU (17) and Multilink Short Sequence Number Header (18). Acking MRRU would
 * enable Multilink PPP on the server (mpd5 on pfSense proposes it), after which it may wrap data in MP headers.
 * @param frame full PPP frame as received (optional ff 03 + 2-byte protocol + LCP), @param body points at protocol.
 * @return reject frame length (>0) when something must be rejected, 0 when the request can be acked, -1 on error.
 */
static int lcp_build_reject_for_unsupported(const uint8_t *frame, size_t prefix, const uint8_t *body, size_t body_len,
                                            uint8_t *out, size_t cap) {
  if (body_len < 6u)
    return -1;
  uint16_t lcp_len = util_read_be16(body + 4);
  if (lcp_len < 4u || 2u + (size_t)lcp_len > body_len || prefix + 6u > cap)
    return -1;
  memcpy(out, frame, prefix + 2u); /* address/control (if any) + protocol */
  size_t o = prefix + 2u;
  out[o++] = 4; /* Configure-Reject */
  out[o++] = body[3];
  size_t len_pos = o;
  o += 2u;
  const uint8_t *opts = body + 6u;
  size_t rem = (size_t)lcp_len - 4u;
  size_t i = 0;
  int rejected = 0;
  while (i + 2u <= rem) {
    uint8_t t = opts[i];
    uint8_t ol = opts[i + 1u];
    if (ol < 2u || i + (size_t)ol > rem)
      return -1;
    if (t == 13u || t == 17u || t == 18u) {
      if (o + ol > cap)
        return -1;
      memcpy(out + o, opts + i, ol);
      o += ol;
      rejected = 1;
    }
    i += (size_t)ol;
  }
  if (!rejected)
    return 0;
  util_write_be16(out + len_pos, (uint16_t)(o - prefix - 2u));
  return (int)o;
}

/**
 * Build an LCP Configure-Nak suggesting MS-CHAPv2 when the peer Configure-Request asks us to authenticate with a
 * protocol this client does not implement. pppd without require-* options (plain `auth`) proposes
 * EAP first and falls back on a Nak; acking EAP leaves the server's EAP Identity requests unanswered.
 * Same framing contract as lcp_build_reject_for_unsupported(); call it only when nothing needs rejecting (RFC 1661).
 * @return nak frame length (>0) when the auth option must be refused, 0 when the request can be acked, -1 on error.
 */
static int lcp_build_nak_for_disallowed_auth(const uint8_t *frame, size_t prefix, const uint8_t *body, size_t body_len,
                                             int required_auth, uint8_t *out, size_t cap) {
  if (body_len < 6u)
    return -1;
  uint16_t lcp_len = util_read_be16(body + 4);
  if (lcp_len < 4u || 2u + (size_t)lcp_len > body_len || prefix + 11u > cap)
    return -1;
  const uint8_t *opts = body + 6u;
  size_t rem = (size_t)lcp_len - 4u;
  size_t i = 0;
  int disallowed = 0;
  while (i + 2u <= rem) {
    uint8_t t = opts[i];
    uint8_t ol = opts[i + 1u];
    if (ol < 2u || i + (size_t)ol > rem)
      return -1;
    if (t == 3u && !lcp_auth_option_allowed(opts + i, ol, required_auth))
      disallowed = 1;
    i += (size_t)ol;
  }
  if (!disallowed)
    return 0;
  memcpy(out, frame, prefix + 2u); /* address/control (if any) + protocol */
  size_t o = prefix + 2u;
  out[o++] = 3; /* Configure-Nak */
  out[o++] = body[3];
  if (required_auth == (int)PPP_AUTH_PAP) {
    util_write_be16(out + o, 8u);
    o += 2u;
    out[o++] = 3; /* Authentication-Protocol: PAP (0xc023) */
    out[o++] = 4;
    out[o++] = 0xc0;
    out[o++] = 0x23;
    return (int)o;
  }
  util_write_be16(out + o, 9u);
  o += 2u;
  out[o++] = 3; /* Authentication-Protocol: CHAP (0xc223) */
  out[o++] = 5;
  out[o++] = 0xc2;
  out[o++] = 0x23;
  out[o++] = (required_auth == (int)PPP_AUTH_CHAP_MD5) ? 0x05u : 0x81u;
  return (int)o;
}

/* Set once LCP is negotiated: late peer Configure-Requests (retransmits that crossed our Ack) are acked
 * inside recv_ppp() so the server does not time out LCP while we wait for CHAP/IPCP. */

#define PPP_DEFAULT_LINK_MTU 1450u

static uint16_t ppp_clamp_mtu(uint16_t mtu) {
  if (mtu < 576u)
    return 576u;
  if (mtu > 1500u)
    return 1500u;
  return mtu;
}

static uint16_t ppp_sanitize_link_mtu(int tun_mtu) {
  if (tun_mtu <= 0)
    return PPP_DEFAULT_LINK_MTU;
  if (tun_mtu < 576)
    return 576u;
  if (tun_mtu > 1500)
    return 1500u;
  return (uint16_t)tun_mtu;
}

static uint16_t ppp_tcp_mss_for_link_mtu(uint16_t link_mtu) {
  return link_mtu > 40u ? (uint16_t)(link_mtu - 40u) : 536u;
}

/**
 * Negotiate LCP open state for the PPP link on the current L2TP session.
 *
 * The routine drives only the LCP Configure-Request handshake phase:
 * - send local Configure-Request,
 * - process peer Configure-Request / Configure-Ack / Configure-Nak / Configure-Reject,
 * - adapt future Configure-Requests until our request id is acknowledged or retries are exhausted.
 *
 * Runtime LCP data-plane messages such as Echo-Request replies and Protocol-Reject generation are handled later in
 * ppp_dispatch_ppp_frame(), not in this handshake helper.
 *
 * @param esp_fd     ESP UDP socket fd used for PPP-over-L2TP transport.
 * @param esp        Active ESP keys/state for send/receive helpers.
 * @param peer       Remote UDP endpoint.
 * @param peer_len   Length of @p peer.
 * @param l2tp       Active L2TP session descriptor.
 * @param auth_out   Negotiated authentication kind on success.
 * @param ppp        PPP session state (for negotiated framing hints and MTU selection).
 *
 * @return 0 when LCP reaches open/acknowledged state, -1 on timeout, parse, or send/receive failure.
 */
static int ppp_lcp_negotiate_transport(ppp_transport_t *transport, ppp_auth_kind_t *auth_out, ppp_session_t *ppp) {
  /* Local state for our Configure-Request sequence and adaptive option set. */
  uint8_t id = 1;
  int required_auth = ppp_effective_required_auth(transport);
  ppp_auth_kind_t auth = required_auth >= 0 ? (ppp_auth_kind_t)required_auth : PPP_AUTH_MSCHAPV2;
  uint8_t pkt[64];
  uint16_t mtu_cap =
      (ppp != NULL && ppp->link_mtu >= 576u && ppp->link_mtu <= 1500u) ? ppp->link_mtu : PPP_DEFAULT_LINK_MTU;
  uint16_t cr_mru = mtu_cap;
  uint16_t peer_mru = 1500u;
  int lcp_out_include_ac = 1;
  int lcp_peer_framing_seen = 0;
  int lcp_mru_in_cr = 1;
  int lcp_accm_in_cr = 1;
  /* Client side must not ask the server to authenticate itself: the auth protocol is chosen by the server's own
   * Configure-Request (pppd on EdgeOS/USG Naks or ignores a client-proposed MS-CHAPv2). */
  int lcp_auth_in_cr = 0;
  /* Phase 1: send initial Configure-Request. */
  int plen = ppp_lcp_build_cr(pkt, sizeof(pkt), id, auth, cr_mru, 1, lcp_accm_in_cr, lcp_auth_in_cr, lcp_mru_in_cr);
  if (plen < 0)
    return -1;
  tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp lcp: send Configure-Request id=%u auth=%s mru=%u", (unsigned)id,
                    ppp_auth_name(auth), (unsigned)cr_mru);
  if (ppp_transport_send(transport, pkt, (size_t)plen) < 0) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp lcp: send Configure-Request failed id=%u", (unsigned)id);
    return -1;
  }

  uint8_t in[4096];
  int got_ack = 0;
  int peer_cr_hex_done = 0;
  int peer_cr_acked = 0;
  int peer_saw_auth = 0;
  int auth_nak_count = 0;
  transport->lcp_opened = 0;
  /* Phase 2: bounded receive/process loop until BOTH our Configure-Request is acked and we have acked the peer's
   * (RFC 1661 Opened state). Stopping after our own Ack drops the server's CR (e.g. mpd5 on pfSense) and the
   * server then tears the call down after its LCP retries while we already wait for CHAP. */
  for (int round = 0; round < 24 && !(got_ack && peer_cr_acked); round++) {
    int n = ppp_transport_recv(transport, in, sizeof(in), 3000);
    if (tunnel_should_stop())
      return -1;
    if (n == -2) {
      if (required_auth >= 0 && auth_nak_count > 0) {
        tunnel_set_failure(0, 0, 0);
        return ppp_auth_mismatch_rc(transport);
      }
      return -1;
    }
    if (n < 6) {
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp lcp: recv below minimum n=%d round=%d", n, round);
      if (tunnel_should_stop())
        return -1;
      /* RFC 1661 Restart timer: our CR may have been sent before the server's pppd was attached to the session. */
      if (!got_ack) {
        if (ppp_transport_send(transport, pkt, (size_t)plen) < 0)
          return -1;
        tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "ppp lcp: timeout, retransmit Configure-Request id=%u",
                          (unsigned)id);
      }
      continue;
    }
    const uint8_t *p = in;
    size_t len = (size_t)n;
    ppp_strip(in, (size_t)n, &p, &len);
    if (len < 6 || util_read_be16(p) != PROTO_LCP)
      continue;
    ppp_log_rx_summary(p, len, "lcp");
    uint8_t code = p[2];
    uint8_t rid = p[3];
    if (code == 5) {
      if (required_auth >= 0 && auth_nak_count > 0) {
        tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                          "ppp lcp: peer sent Terminate-Request after auth Configure-Nak (required=%s)",
                          ppp_auth_name((ppp_auth_kind_t)required_auth));
        tunnel_set_failure(0, 0, 0);
        return ppp_auth_mismatch_rc(transport);
      }
      return -1;
    }
    if (code == 1) {
      peer_cr_acked = 0;
      /* Peer Configure-Request: observe framing/options, send Configure-Ack, optionally realign auth request. */
      if (!lcp_peer_framing_seen) {
        lcp_peer_framing_seen = 1;
        lcp_out_include_ac = (in[0] == 0xff && in[1] == 0x03) ? 1 : 0;
        tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp lcp peer raw addr_ctl=%d in0=%02x in1=%02x",
                          lcp_out_include_ac, in[0], in[1]);
      }
      if (!peer_cr_hex_done) {
        peer_cr_hex_done = 1;
        char hx[80];
        size_t lim = len < 22u ? len : 22u;
        for (size_t zi = 0; zi < lim; zi++)
          snprintf(hx + zi * 3, 4, "%02x ", p[zi]);
        tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp lcp peer-cr first-bytes len=%zu lim=%zu: %s", len, lim, hx);
      }
      uint8_t ackbuf[256];
      uint16_t lcp_len = util_read_be16(p + 4);
      if (lcp_len < 4u || 2u + (size_t)lcp_len > len)
        continue;
      if (ppp != NULL) {
        lcp_peer_cr_note_acfc(p + 2u, (size_t)lcp_len, &ppp->lcp_acfc);
        lcp_peer_cr_note_pfc(p + 2u, (size_t)lcp_len, &ppp->lcp_pfc);
      }
      /* The peer's request selects how we authenticate; our request is unchanged. */
      ppp_auth_kind_t peer_auth = auth;
      int saw_auth_opt = 0;
      if (lcp_parse_peer_auth_for_policy(p + 2u, (size_t)lcp_len, required_auth, &peer_auth, &saw_auth_opt) == 0) {
        auth = peer_auth;
        peer_saw_auth = 1;
      }
      {
        uint8_t rejbuf[256];
        int rl = lcp_build_reject_for_unsupported(in, (size_t)(p - in), p, len, rejbuf, sizeof(rejbuf));
        if (rl < 0)
          continue;
        if (rl > 0) {
          if (ppp_transport_send(transport, rejbuf, (size_t)rl) < 0)
            return -1;
          tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG,
                            "ppp lcp: rejected unsupported options (Multilink/Callback) in peer CR id=%u",
                            (unsigned)rid);
          continue;
        }
        rl = lcp_build_nak_for_disallowed_auth(in, (size_t)(p - in), p, len, required_auth, rejbuf, sizeof(rejbuf));
        if (rl < 0)
          continue;
        if (rl > 0) {
          if (required_auth >= 0 && ++auth_nak_count > 5) {
            tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                              "ppp lcp: peer refused required auth=%s after %d Configure-Naks",
                              ppp_auth_name((ppp_auth_kind_t)required_auth), auth_nak_count - 1);
            tunnel_set_failure(0, 0, 0);
            return ppp_auth_mismatch_rc(transport);
          }
          if (ppp_transport_send(transport, rejbuf, (size_t)rl) < 0)
            return -1;
          tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG,
                            "ppp lcp: nak'd auth in peer CR id=%u, suggested %s", (unsigned)rid,
                            ppp_auth_name(required_auth >= 0 ? (ppp_auth_kind_t)required_auth : PPP_AUTH_MSCHAPV2));
          continue;
        }
      }
      size_t ack_ppp_len = 2u + (size_t)lcp_len;
      size_t prefix = (size_t)(p - in);
      size_t total_ack = prefix + ack_ppp_len;
      if (total_ack > (size_t)n || total_ack > sizeof(ackbuf))
        continue;
      memcpy(ackbuf, in, total_ack);
      if (util_read_be16(ackbuf + prefix) != PROTO_LCP)
        continue;
      ackbuf[prefix + 2u] = 2;
      if (ppp_transport_send(transport, ackbuf, total_ack) < 0)
        return -1;
      uint16_t parsed_peer_mru = 0u;
      if (ppp_lcp_parse_mru(p + 2u, (size_t)lcp_len, &parsed_peer_mru) == 0) {
        peer_mru = ppp_clamp_mtu(parsed_peer_mru);
      } else {
        peer_mru = 1500u;
      }
      peer_cr_acked = 1;
      /* Peer re-sending its CR while ours is not acked yet means it has not seen ours: (re)send it, otherwise
       * both sides wait forever. Once ours is acked, resending would restart negotiation on the server. */
      if (!got_ack && ppp_transport_send(transport, pkt, (size_t)plen) < 0)
        return -1;
      tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "ppp lcp: acked peer CR id=%u, sent our Configure-Request id=%u",
                        (unsigned)rid, (unsigned)id);
      continue;
    }
    if (code == 2 && rid == id) {
      /* Our current Configure-Request is acknowledged; loop ends once the peer's CR is acked too. */
      got_ack = 1;
      continue;
    }
    if (code == 4 && rid == id) {
      /* Configure-Reject: remove rejected options and resend with next id. */
      {
        char hx[128];
        size_t lim = len < 40u ? len : 40u;
        for (size_t zi = 0; zi < lim; zi++)
          snprintf(hx + zi * 3, 4, "%02x ", p[zi]);
        tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp lcp: Configure-Reject id=%u len=%zu hex_prefix=%s",
                          (unsigned)rid, len, hx);
      }
      uint16_t lcp_len = util_read_be16(p + 4);
      if (lcp_len >= 4u && 2u + (size_t)lcp_len <= len) {
        int removed_accm = 0;
        int removed_auth = 0;
        ppp_lcp_apply_conf_reject(p + 2u, (size_t)lcp_len, &lcp_accm_in_cr, &lcp_auth_in_cr, &removed_accm,
                                  &removed_auth, &lcp_mru_in_cr);
        if (removed_accm || removed_auth) {
          tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG,
                            "ppp lcp: Configure-Reject removed opts accm=%d auth=%d (next CR accm=%d auth=%d mru=%d)",
                            removed_accm, removed_auth, lcp_accm_in_cr, lcp_auth_in_cr, lcp_mru_in_cr);
        }
      }
      got_ack = 0;
      id++;
      plen = ppp_lcp_build_cr(pkt, sizeof(pkt), id, auth, cr_mru, lcp_out_include_ac, lcp_accm_in_cr, lcp_auth_in_cr,
                              lcp_mru_in_cr);
      if (plen < 0)
        return -1;
      tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp lcp: resend after Configure-Reject id=%u bytes=%d",
                        (unsigned)id, plen);
      if (ppp_transport_send(transport, pkt, (size_t)plen) < 0)
        return -1;
      continue;
    }
    if (code == 3 && rid == id) {
      /* Configure-Nak: adopt suggested MRU and/or auth family and resend with next id. */
      uint16_t lcp_len = util_read_be16(p + 4);
      int has_mru_nak = 0;
      int has_auth_nak = 0;
      if (lcp_len >= 4u && 2u + (size_t)lcp_len <= len) {
        uint16_t nak_mru = 0u;
        if (ppp_lcp_parse_mru(p + 2u, (size_t)lcp_len, &nak_mru) == 0) {
          cr_mru = ppp_clamp_mtu(nak_mru);
          has_mru_nak = 1;
          tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "ppp lcp: Configure-Nak suggested mru=%u (adopted=%u)",
                            (unsigned)nak_mru, (unsigned)cr_mru);
        }
        has_auth_nak = ppp_lcp_has_option(p + 2u, (size_t)lcp_len, 3u);
        if (has_auth_nak)
          lcp_auth_in_cr = 0; /* auth is decided by the server's CR, never by ours */
      }
      if (required_auth < 0 && (!has_mru_nak || has_auth_nak)) {
        if (lcp_len >= 4u && 2u + (size_t)lcp_len <= len) {
          if (lcp_nak_wants_pap(p + 6, (size_t)lcp_len - 4u)) {
            auth = PPP_AUTH_PAP;
          } else {
            auth = PPP_AUTH_CHAP_MD5;
          }
        } else {
          auth = PPP_AUTH_CHAP_MD5;
        }
      }
      got_ack = 0;
      id++;
      plen = ppp_lcp_build_cr(pkt, sizeof(pkt), id, auth, cr_mru, lcp_out_include_ac, lcp_accm_in_cr, lcp_auth_in_cr,
                              lcp_mru_in_cr);
      if (plen < 0)
        return -1;
      tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp lcp: received NAK, resend Configure-Request id=%u auth=%s mru=%u",
                        (unsigned)id, ppp_auth_name(auth), (unsigned)cr_mru);
      if (ppp_transport_send(transport, pkt, (size_t)plen) < 0)
        return -1;
    }
  }
  if (!(got_ack && peer_cr_acked)) {
    /* Round budget exhausted without Configure-Ack for our request id. */
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp: LCP timeout");
    if (required_auth >= 0 && auth_nak_count > 0) {
      tunnel_set_failure(0, 0, 0);
      return ppp_auth_mismatch_rc(transport);
    }
    return -1;
  }
  if (required_auth >= 0 && !peer_saw_auth)
    auth = (ppp_auth_kind_t)required_auth;
  uint16_t our_mru = lcp_mru_in_cr ? cr_mru : 1500u;
  uint16_t effective_mtu = our_mru < peer_mru ? our_mru : peer_mru;
  if (effective_mtu > mtu_cap)
    effective_mtu = mtu_cap;
  effective_mtu = ppp_clamp_mtu(effective_mtu);
  if (ppp != NULL) {
    ppp->link_mtu = effective_mtu;
    ppp->tcp_mss = ppp_tcp_mss_for_link_mtu(effective_mtu);
  }
  tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG,
                    "ppp lcp: acked final auth=%s acfc=%d pfc=%d our_mru=%u peer_mru=%u link_mtu=%u tcp_mss=%u",
                    ppp_auth_name(auth), ppp != NULL ? ppp->lcp_acfc : -1, ppp != NULL ? ppp->lcp_pfc : -1,
                    (unsigned)our_mru, (unsigned)peer_mru, (unsigned)effective_mtu,
                    (unsigned)ppp_tcp_mss_for_link_mtu(effective_mtu));
  *auth_out = auth;
  transport->lcp_opened = 1;
  return 0;
}

static int chap_md5_response(const uint8_t chap_id, const char *password, const uint8_t *chal, size_t chal_len,
                             uint8_t hash16[16]) {
  unsigned char dig[16];
  mbedtls_md5_context ctx;
  mbedtls_md5_init(&ctx);
  if (mbedtls_md5_starts_ret(&ctx) != 0) {
    mbedtls_md5_free(&ctx);
    return -1;
  }
  if (mbedtls_md5_update_ret(&ctx, &chap_id, 1) != 0) {
    mbedtls_md5_free(&ctx);
    return -1;
  }
  if (mbedtls_md5_update_ret(&ctx, (const unsigned char *)password, strlen(password)) != 0) {
    mbedtls_md5_free(&ctx);
    return -1;
  }
  if (mbedtls_md5_update_ret(&ctx, chal, chal_len) != 0) {
    mbedtls_md5_free(&ctx);
    return -1;
  }
  if (mbedtls_md5_finish_ret(&ctx, dig) != 0) {
    mbedtls_md5_free(&ctx);
    return -1;
  }
  mbedtls_md5_free(&ctx);
  memcpy(hash16, dig, 16);
  return 0;
}

/**
 * Complete MS-CHAPv2 authentication after LCP (CHAP challenge/response/success or failure).
 *
 * Waits for CHAP Challenge (code 1), builds Response (code 2) with MS-CHAPv2 response blob, then polls for
 * Success (3) or Failure (4). Failure parses optional peer text for diagnostics.
 *
 * @return 0 on Success; -1 on I/O error, timeout, or Failure.
 */
static int chap_result_code(const uint8_t *p, size_t len) {
  if (len < 6 || util_read_be16(p) != PROTO_CHAP)
    return 0;
  size_t n = util_read_be16(p + 4);
  if (n < 4 || n + 2 > len)
    return 0;
  return p[2] == 3 || p[2] == 4 ? p[2] : 0;
}

static int chap_challenge_valid(const uint8_t *p, size_t len, int mschap) {
  if (len < 7)
    return 0;
  size_t n = util_read_be16(p + 4);
  size_t value = p[6];
  return n >= 5 + value && n + 2 <= len && value > 0 && (!mschap || value == 16);
}

static int chap_repeated_challenge(const uint8_t *p, size_t len, uint8_t id) {
  return len >= 7 && util_read_be16(p) == PROTO_CHAP && p[2] == 1 && p[3] == id && chap_challenge_valid(p, len, 0);
}

static int ppp_auth_mschapv2_transport(ppp_transport_t *transport, const char *user, const char *password,
                                       ppp_session_t *ppp) {
  uint8_t in[4096];
  const long long deadline = ppp_now_ms() + 80000;
  unsigned challenges = 0;
  tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp auth: start mschapv2");
  for (int i = 0; i < 16; i++) {
    if (ppp_now_ms() >= deadline)
      return -1;
    int n = ppp_transport_recv(transport, in, sizeof(in), 5000);
    if (n == -2 || tunnel_should_stop())
      return -1;
    if (n < 10)
      continue;
    const uint8_t *p = in;
    size_t len = (size_t)n;
    ppp_strip(in, (size_t)n, &p, &len);
    if (len < 8 || util_read_be16(p) != PROTO_CHAP || p[2] != 1)
      continue;
  handle_challenge:
    if (++challenges > 16 || ppp_now_ms() >= deadline)
      return -1;
    ppp_log_rx_summary(p, len, "auth-mschapv2-challenge");
    uint8_t chap_id = p[3];
    /* plen is the CHAP Length field (code+id+length+value-size+value+name); it excludes the 2-byte PPP protocol.
     * The old check (7 + vs) silently dropped challenges without a Name field, which mpd5 (pfSense) sends. */
    if (!chap_challenge_valid(p, len, 1))
      continue;
    const uint8_t *auth_chal = p + 7;
    uint8_t peer_chal[16];
    if (urandom_bytes(peer_chal, sizeof(peer_chal)) != 0)
      return -1;
    uint8_t val49[49];
    if (ppp_mschapv2_response_value(user, password, auth_chal, peer_chal, val49) != 0) {
      mbedtls_platform_zeroize(val49, sizeof(val49));
      tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                        "ppp: MS-CHAPv2 rejected password (exceeds RFC 2759 256 UTF-16LE char limit or invalid)");
      return -1;
    }

    uint8_t hash_hash[16];
    int have_hash_hash = (transport->enable_mppe && transport->mppe_mode != TUNNEL_MPPE_OFF && ppp != NULL &&
                          ppp_mschapv2_nt_password_hash_hash(password, hash_hash) == 0);

    uint8_t out[512];
    size_t o = 0;
    out[o++] = 0xff;
    out[o++] = 0x03;
    util_write_be16(out + o, PROTO_CHAP);
    o += 2;
    size_t chap_start = o;
    out[o++] = 2;
    out[o++] = chap_id;
    size_t lenpos = o;
    o += 2;
    out[o++] = 49;
    memcpy(out + o, val49, 49);
    o += 49;
    size_t ulen = user != NULL ? strlen(user) : 0u;
    if (user == NULL || o + ulen > sizeof(out)) {
      mbedtls_platform_zeroize(val49, sizeof(val49));
      mbedtls_platform_zeroize(hash_hash, sizeof(hash_hash));
      tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp: MS-CHAPv2 username exceeds response packet limit (%zu bytes)",
                        ulen);
      return -1;
    }
    memcpy(out + o, user, ulen);
    o += ulen;
    util_write_be16(out + lenpos, (uint16_t)(o - chap_start));
    if (ppp_transport_send(transport, out, o) < 0) {
      mbedtls_platform_zeroize(hash_hash, sizeof(hash_hash));
      return -1;
    }

    /* Wait for CHAP Success (3) or Failure (4) after MS-CHAPv2 Response. */
    for (int j = 0; j < 16; j++) {
      if (ppp_now_ms() >= deadline) {
        mbedtls_platform_zeroize(hash_hash, sizeof(hash_hash));
        return -1;
      }
      n = ppp_transport_recv(transport, in, sizeof(in), 3000);
      if (n == -2 || tunnel_should_stop()) {
        mbedtls_platform_zeroize(hash_hash, sizeof(hash_hash));
        return -1;
      }
      if (n < 0) {
        if (ppp_transport_send(transport, out, o) < 0) {
          mbedtls_platform_zeroize(hash_hash, sizeof(hash_hash));
          return -1;
        }
        continue;
      }
      if (n < 6)
        continue;
      ppp_strip(in, (size_t)n, &p, &len);
      ppp_log_rx_summary(p, len, "auth-result");
      if (len >= 7 && util_read_be16(p) == PROTO_CHAP && p[2] == 1 && chap_challenge_valid(p, len, 0) &&
          p[3] != chap_id) {
        mbedtls_platform_zeroize(hash_hash, sizeof(hash_hash));
        goto handle_challenge;
      }
      if (chap_repeated_challenge(p, len, chap_id)) {
        if (ppp_transport_send(transport, out, o) < 0) {
          mbedtls_platform_zeroize(hash_hash, sizeof(hash_hash));
          return -1;
        }
        continue;
      }
      if (chap_result_code(p, len) == 3) {
        ppp_log_rx_summary(p, len, "auth-mschapv2-success");
        if (have_hash_hash && ppp != NULL) {
          memcpy(ppp->mschapv2_hash_hash, hash_hash, 16u);
          memcpy(ppp->mschapv2_nt_response, val49 + 24u, 24u);
          ppp->mppe_keys_ready = 1;
        }
        mbedtls_platform_zeroize(hash_hash, sizeof(hash_hash));
        return 0;
      }
      if (chap_result_code(p, len) == 4) {
        mbedtls_platform_zeroize(hash_hash, sizeof(hash_hash));
        tunnel_set_failure(4, 4, 0);
        uint16_t chap_len = len >= 6 ? util_read_be16(p + 4) : 0u;
        ppp_mschapv2_failure_info_t failure;
        if (chap_len >= 4u && (size_t)chap_len + 2u <= len &&
            ppp_mschapv2_parse_failure(p + 6, (size_t)chap_len - 4u, &failure) == 0) {
          char err[16];
          char retry[16];
          char version[16];
          snprintf(err, sizeof(err), failure.has_error_code ? "%d" : "-", failure.error_code);
          if (failure.has_error_code)
            tunnel_set_failure(1, failure.error_code, 0);
          snprintf(retry, sizeof(retry), failure.has_retry ? "%d" : "-", failure.retry);
          snprintf(version, sizeof(version), failure.has_version ? "%d" : "-", failure.version);
          tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp: MS-CHAPv2 failure E=%s R=%s V=%s M=%s", err, retry,
                            version, failure.has_message ? failure.message : "-");
        } else {
          tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp: MS-CHAPv2 failure");
        }
        return -1;
      }
    }
    mbedtls_platform_zeroize(hash_hash, sizeof(hash_hash));
    return -1;
  }
  return -1;
}

static int ppp_auth_chap_md5_transport(ppp_transport_t *transport, const char *user, const char *password) {
  uint8_t in[4096];
  const long long deadline = ppp_now_ms() + 80000;
  unsigned challenges = 0;
  tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp auth: start chap-md5");
  for (int i = 0; i < 16; i++) {
    if (ppp_now_ms() >= deadline)
      return -1;
    int n = ppp_transport_recv(transport, in, sizeof(in), 5000);
    if (n == -2 || tunnel_should_stop())
      return -1;
    if (n < 10)
      continue;
    const uint8_t *p = in;
    size_t len = (size_t)n;
    ppp_strip(in, (size_t)n, &p, &len);
    if (len < 8 || util_read_be16(p) != PROTO_CHAP || p[2] != 1)
      continue;
  handle_challenge:
    if (++challenges > 16 || ppp_now_ms() >= deadline)
      return -1;
    ppp_log_rx_summary(p, len, "auth-chap-md5-challenge");
    uint8_t chap_id = p[3];
    uint8_t vs = p[6];
    if (!chap_challenge_valid(p, len, 0)) {
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "CHAP malformed challenge length=%u value_size=%u frame=%zu",
                        (unsigned)util_read_be16(p + 4), (unsigned)vs, len);
      continue;
    }
    const uint8_t *chal = p + 7;
    uint8_t md[16];
    if (chap_md5_response(chap_id, password, chal, vs, md) != 0)
      return -1;

    uint8_t out[512];
    size_t o = 0;
    out[o++] = 0xff;
    out[o++] = 0x03;
    util_write_be16(out + o, PROTO_CHAP);
    o += 2;
    size_t chap_start = o;
    out[o++] = 2;
    out[o++] = chap_id;
    size_t lenpos = o;
    o += 2;
    out[o++] = 16;
    memcpy(out + o, md, 16);
    o += 16;
    size_t ulen = user != NULL ? strlen(user) : 0u;
    if (user == NULL || o + ulen > sizeof(out)) {
      tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp: CHAP-MD5 username exceeds response packet limit (%zu bytes)",
                        ulen);
      return -1;
    }
    memcpy(out + o, user, ulen);
    o += ulen;
    util_write_be16(out + lenpos, (uint16_t)(o - chap_start));
    if (ppp_transport_send(transport, out, o) < 0)
      return -1;

    for (int j = 0; j < 16; j++) {
      if (ppp_now_ms() >= deadline)
        return -1;
      n = ppp_transport_recv(transport, in, sizeof(in), 3000);
      if (n == -2 || tunnel_should_stop())
        return -1;
      if (n < 0) {
        if (ppp_transport_send(transport, out, o) < 0)
          return -1;
        continue;
      }
      if (n < 6)
        continue;
      ppp_strip(in, (size_t)n, &p, &len);
      ppp_log_rx_summary(p, len, "auth-result");
      if (len >= 7 && util_read_be16(p) == PROTO_CHAP && p[2] == 1 && chap_challenge_valid(p, len, 0) &&
          p[3] != chap_id)
        goto handle_challenge;
      if (chap_repeated_challenge(p, len, chap_id)) {
        if (ppp_transport_send(transport, out, o) < 0)
          return -1;
        continue;
      }
      if (chap_result_code(p, len) == 3) {
        ppp_log_rx_summary(p, len, "auth-chap-md5-success");
        return 0;
      }
      if (chap_result_code(p, len) == 4) {
        ppp_log_rx_summary(p, len, "auth-chap-md5-failure");
        tunnel_set_failure(4, 4, 0);
        return -1;
      }
    }
    return -1;
  }
  return -1;
}

static int ppp_auth_pap_transport(ppp_transport_t *transport, const char *user, const char *password) {
  if (user == NULL || password == NULL)
    return -1;
  uint8_t pap[528];
  size_t o = 0;
  pap[o++] = 0xff;
  pap[o++] = 0x03;
  util_write_be16(pap + o, PROTO_PAP);
  o += 2;
  size_t codepos = o;
  pap[o++] = 1;
  pap[o++] = 1;
  size_t lenpos = o;
  o += 2;
  size_t ulen = strlen(user);
  size_t pwlen = strlen(password);
  if (ulen > 255u || pwlen > 255u) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                      "ppp: PAP credentials exceed RFC 1334 255-byte limit (user=%zu password=%zu)", ulen, pwlen);
    mbedtls_platform_zeroize(pap, sizeof(pap));
    return -1;
  }
  pap[o++] = (uint8_t)ulen;
  memcpy(pap + o, user, ulen);
  o += ulen;
  pap[o++] = (uint8_t)pwlen;
  memcpy(pap + o, password, pwlen);
  o += pwlen;
  util_write_be16(pap + lenpos, (uint16_t)(o - codepos));
  tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp auth: start pap");
  int rc = -1;
  if (ppp_transport_send(transport, pap, o) < 0)
    goto out;

  uint8_t in[4096];
  for (int i = 0; i < 12; i++) {
    int n = ppp_transport_recv(transport, in, sizeof(in), 5000);
    if (n == -2 || tunnel_should_stop())
      goto out;
    if (n < 7)
      continue;
    const uint8_t *p = in;
    size_t len = (size_t)n;
    ppp_strip(in, (size_t)n, &p, &len);
    /* Only a complete Authenticate-Nak for our request proves rejection. */
    if (len >= 7 && util_read_be16(p) == PROTO_PAP && p[2] == 3 && p[3] == 1) {
      uint16_t pap_len = util_read_be16(p + 4);
      if (pap_len >= 5 && (size_t)pap_len + 2 <= len && p[6] <= pap_len - 5) {
        tunnel_set_failure(5, 3, 0);
        goto out;
      }
    }
    if (len >= 4 && util_read_be16(p) == PROTO_PAP && p[2] == 2) {
      ppp_log_rx_summary(p, len, "auth-pap-ack");
      rc = 0;
      goto out;
    }
  }
out:
  mbedtls_platform_zeroize(pap, sizeof(pap));
  return rc;
}

static int ipcp_ipv4_is_zero(const uint8_t ip[4]) { return ip[0] == 0 && ip[1] == 0 && ip[2] == 0 && ip[3] == 0; }

/** [ipcp] starts at IPCP Code byte; [ipcplen] is RFC 1661 Length field (Code+Id+Len+Options). */
static void ipcp_apply_conf_reject_opts(const uint8_t *ipcp, uint16_t ipcplen, int *include_ip_opt,
                                        int *include_primary_dns_opt, int *include_secondary_dns_opt) {
  if (ipcplen < 4u)
    return;
  const uint8_t *opts = ipcp + 4u;
  size_t rem = (size_t)ipcplen - 4u;
  size_t i = 0;
  while (i + 2u <= rem) {
    uint8_t t = opts[i];
    uint8_t ol = opts[i + 1u];
    if (ol < 2u || i + (size_t)ol > rem)
      break;
    if (t == IPCP_OPT_IP_ADDRESS && include_ip_opt != NULL)
      *include_ip_opt = 0;
    if (t == IPCP_OPT_PRIMARY_DNS && include_primary_dns_opt != NULL)
      *include_primary_dns_opt = 0;
    if (t == IPCP_OPT_SECONDARY_DNS && include_secondary_dns_opt != NULL)
      *include_secondary_dns_opt = 0;
    i += (size_t)ol;
  }
}

/**
 * Negotiate IPCP parameters (IPv4 address and optional DNS servers) after LCP/auth complete.
 *
 * The local side starts with zero-valued requests ("please assign") and iteratively adapts based on peer
 * Configure-Nak / Configure-Reject responses. While awaiting final Configure-Ack for our id, non-IPCP traffic
 * (including LCP chatter) is skipped rather than treated as fatal.
 *
 * Retry behavior:
 * - Resend the current Configure-Request when recv times out/returns short.
 * - Also resend after servicing a peer Configure-Request when resend_after_ms elapsed.
 *
 * On successful Configure-Ack, requested values are committed into @p ppp. If the negotiated local IPv4 remains
 * zero/missing, the code applies a compatibility fallback of 10.0.0.2.
 *
 * @return 0 on success, -1 on timeout or transport/build errors.
 */
static int ccp_build_mppe_cr(uint8_t *out, size_t cap, uint8_t id, uint32_t mppe_bits, int include_address_control) {
  size_t o = 0u;
  if (include_address_control) {
    if (cap < 14u)
      return -1;
    out[o++] = 0xff;
    out[o++] = 0x03;
  } else {
    if (cap < 12u)
      return -1;
  }
  util_write_be16(out + o, PROTO_CCP);
  o += 2u;
  out[o++] = 1u; /* Configure-Request */
  out[o++] = id;
  util_write_be16(out + o, 10u); /* 4B CCP hdr + 6B MPPE opt */
  o += 2u;
  out[o++] = MPPE_CCP_OPT_TYPE;
  out[o++] = MPPE_CCP_OPT_LEN;
  util_write_be32(out + o, mppe_bits);
  o += 4u;
  return (int)o;
}

static int ccp_build_mppe_nak(uint8_t *out, size_t cap, uint8_t id, uint32_t mppe_bits, int include_address_control) {
  int n = ccp_build_mppe_cr(out, cap, id, mppe_bits, include_address_control);
  if (n > 0)
    out[(include_address_control ? 2u : 0u) + 2u] = 3u; /* Configure-Nak */
  return n;
}

static int ccp_parse_mppe_bits(const uint8_t *ccp_msg, uint16_t ccp_len, int *has_mppe_out, uint32_t *bits_out,
                               int *has_other_opts_out) {
  if (has_mppe_out != NULL)
    *has_mppe_out = 0;
  if (bits_out != NULL)
    *bits_out = 0u;
  if (has_other_opts_out != NULL)
    *has_other_opts_out = 0;
  if (ccp_msg == NULL || ccp_len < 4u)
    return -1;
  const uint8_t *opts = ccp_msg + 4u;
  size_t rem = (size_t)ccp_len - 4u;
  size_t i = 0u;
  while (i + 2u <= rem) {
    uint8_t t = opts[i];
    uint8_t ol = opts[i + 1u];
    if (ol < 2u || i + (size_t)ol > rem)
      return -1;
    if (t == MPPE_CCP_OPT_TYPE && ol == MPPE_CCP_OPT_LEN) {
      if (has_mppe_out != NULL)
        *has_mppe_out = 1;
      if (bits_out != NULL)
        *bits_out = util_read_be32(opts + i + 2u);
    } else {
      if (has_other_opts_out != NULL)
        *has_other_opts_out = 1;
    }
    i += (size_t)ol;
  }
  return 0;
}

static int ccp_build_reject_non_mppe(const uint8_t *frame, size_t prefix, const uint8_t *ccp_msg, uint16_t ccp_len,
                                     int reject_all, uint8_t *out, size_t cap) {
  if (ccp_len < 4u || prefix + 6u > cap)
    return -1;
  memcpy(out, frame, prefix + 2u);
  size_t o = prefix + 2u;
  out[o++] = 4u; /* Configure-Reject */
  out[o++] = ccp_msg[1];
  size_t len_pos = o;
  o += 2u;
  const uint8_t *opts = ccp_msg + 4u;
  size_t rem = (size_t)ccp_len - 4u;
  size_t i = 0u;
  int rejected = 0;
  while (i + 2u <= rem) {
    uint8_t t = opts[i];
    uint8_t ol = opts[i + 1u];
    if (ol < 2u || i + (size_t)ol > rem)
      return -1;
    if (reject_all || t != MPPE_CCP_OPT_TYPE || ol != MPPE_CCP_OPT_LEN) {
      if (o + (size_t)ol > cap)
        return -1;
      memcpy(out + o, opts + i, (size_t)ol);
      o += (size_t)ol;
      rejected = 1;
    }
    i += (size_t)ol;
  }
  if (!rejected)
    return 0;
  util_write_be16(out + len_pos, (uint16_t)(o - prefix - 2u));
  return (int)o;
}

static int ppp_ipcp_negotiate_transport(ppp_transport_t *transport, ppp_session_t *ppp) {
  /* Re-transmit cadence when no useful IPCP progress is observed. */
  const long long resend_after_ms = 1500ll;
  /* Current outbound Configure-Request id and requested values (0.0.0.0 means "suggest/assign"). */
  uint8_t id = 1;
  uint8_t req_ip[4] = {0, 0, 0, 0};
  uint8_t req_primary_dns[4] = {0, 0, 0, 0};
  uint8_t req_secondary_dns[4] = {0, 0, 0, 0};
  /* PPP framing mode and per-option include flags adapt to peer behavior. */
  int ipcp_out_include_ac = 1;
  int ipcp_peer_framing_seen = 0;
  int include_ip_opt = 1;
  int include_primary_dns_opt = 1;
  int include_secondary_dns_opt = 1;

  /* Optional CCP/MPPE-128 state for PPTP (Auto / On / Off policy). */
  int mppe_mode = transport->enable_mppe ? transport->mppe_mode : TUNNEL_MPPE_OFF;
  int mppe_required_by_local = (transport->enable_mppe && mppe_mode == TUNNEL_MPPE_ON) ? 1 : 0;
  int mppe_forbidden_by_local = (transport->enable_mppe && mppe_mode == TUNNEL_MPPE_OFF) ? 1 : 0;
  int ccp_enabled = (transport->enable_mppe && mppe_mode != TUNNEL_MPPE_OFF && ppp->mppe_keys_ready) ? 1 : 0;
  uint8_t ccp_id = 1;
  uint32_t our_ccp_bits = MPPE_BIT_STATELESS | MPPE_BIT_128;
  uint8_t ccp_pkt[32];
  int ccp_plen = 0;
  int ccp_peer_acked = 0;
  int ccp_we_acked_peer = 0;
  int ccp_required_by_peer = 0;
  int ccp_rejected = 0;
  int ccp_stateful = 0;
  int ccp_unsupported_naks = 0;
  int peer_requested_mppe = 0;
  int mppe_reject_count = 0;
  long long last_ccp_send_ms = 0ll;
  long long ipcp_acked_ms = 0ll;

  if (ccp_enabled) {
    ccp_plen = ccp_build_mppe_cr(ccp_pkt, sizeof(ccp_pkt), ccp_id, our_ccp_bits, 1);
    if (ccp_plen > 0 && ppp_transport_send(transport, ccp_pkt, (size_t)ccp_plen) < 0)
      return -1;
    last_ccp_send_ms = ppp_now_ms();
    tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ccp: send Configure-Request id=%u bits=0x%08x", (unsigned)ccp_id,
                      our_ccp_bits);
  }

  uint8_t pkt[64];
  /* Phase 1: send initial IPCP Configure-Request. */
  int plen = ppp_ipcp_build_cr(pkt, sizeof(pkt), id, req_ip, ipcp_out_include_ac, include_ip_opt, req_primary_dns,
                               include_primary_dns_opt, req_secondary_dns, include_secondary_dns_opt);
  if (plen < 0)
    return -1;
  tunnel_engine_log(
      ANDROID_LOG_DEBUG, LOG_TAG,
      "ppp ipcp: send Configure-Request id=%u ip=%u.%u.%u.%u primary_dns=%u.%u.%u.%u secondary_dns=%u.%u.%u.%u",
      (unsigned)id, (unsigned)req_ip[0], (unsigned)req_ip[1], (unsigned)req_ip[2], (unsigned)req_ip[3],
      (unsigned)req_primary_dns[0], (unsigned)req_primary_dns[1], (unsigned)req_primary_dns[2],
      (unsigned)req_primary_dns[3], (unsigned)req_secondary_dns[0], (unsigned)req_secondary_dns[1],
      (unsigned)req_secondary_dns[2], (unsigned)req_secondary_dns[3]);
  if (ppp_transport_send(transport, pkt, (size_t)plen) < 0)
    return -1;
  long long last_cr_send_ms = ppp_now_ms();

  uint8_t in[4096];
  int got_ack = 0;
  /* Phase 2: process IPCP (and concurrent CCP/MPPE on PPTP) until IPCP is acked and any active CCP converges. */
  for (int round = 0; round < 40 && !(got_ack && ((!ccp_required_by_peer && !mppe_required_by_local) || ppp->mppe.enabled));
       round++) {
    int recv_timeout_ms = (got_ack && mppe_required_by_local && !ppp->mppe.enabled) ? 1500 : 5000;
    int n = ppp_transport_recv(transport, in, sizeof(in), recv_timeout_ms);
    if (tunnel_should_stop())
      return -1;
    if (n == -2) {
      if (mppe_forbidden_by_local && peer_requested_mppe) {
        tunnel_set_failure(0, 0, 0);
        return PPP_NEGOTIATE_MPPE_REQUIRED_BY_PEER;
      }
      if (mppe_required_by_local && !ppp->mppe.enabled) {
        tunnel_set_failure(0, 0, 0);
        return PPP_NEGOTIATE_MPPE_FAILED;
      }
      return -1;
    }
    if (n < 6) {
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp ipcp: recv short/timeout n=%d round=%d", n, round);
      if (got_ack && mppe_required_by_local && !ppp->mppe.enabled && ppp_now_ms() - ipcp_acked_ms >= 6000ll) {
        tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp ccp: timed out waiting for required MPPE-128");
        tunnel_set_failure(0, 0, 0);
        return PPP_NEGOTIATE_MPPE_FAILED;
      }
      if (!got_ack && ppp_now_ms() - last_cr_send_ms >= resend_after_ms) {
        tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: resend current Configure-Request id=%u reason=timeout",
                          (unsigned)id);
        if (ppp_transport_send(transport, pkt, (size_t)plen) < 0)
          return -1;
        last_cr_send_ms = ppp_now_ms();
      }
      if (ccp_enabled && !ccp_rejected && !ccp_peer_acked && ppp_now_ms() - last_ccp_send_ms >= resend_after_ms) {
        if (ccp_plen > 0 && ppp_transport_send(transport, ccp_pkt, (size_t)ccp_plen) < 0)
          return -1;
        last_ccp_send_ms = ppp_now_ms();
      }
      continue;
    }
    const uint8_t *p = in;
    size_t len = (size_t)n;
    ppp_strip(in, (size_t)n, &p, &len);
    uint16_t proto = 0u;
    size_t proto_len = 0u;
    if (ppp_read_protocol(p, len, &proto, &proto_len) != 0) {
      tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: skip malformed frame len=%zu", len);
      continue;
    }
    if (proto == PROTO_LCP && proto_len == 2u && len >= 6u && p[2] == 5u) {
      if (mppe_forbidden_by_local && peer_requested_mppe) {
        tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                          "ppp ccp: peer sent LCP Terminate-Request after MPPE was rejected");
        tunnel_set_failure(0, 0, 0);
        return PPP_NEGOTIATE_MPPE_REQUIRED_BY_PEER;
      }
      if (mppe_required_by_local && !ppp->mppe.enabled) {
        tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                          "ppp ccp: peer sent LCP Terminate-Request while MPPE was required");
        tunnel_set_failure(0, 0, 0);
        return PPP_NEGOTIATE_MPPE_FAILED;
      }
    }
    if (proto == PROTO_LCP && proto_len == 2u && len >= 8u && p[2] == LCP_CODE_PROTOCOL_REJECT) {
      uint16_t rejected_proto = util_read_be16(p + 6u);
      if (rejected_proto == PROTO_CCP) {
        if (mppe_required_by_local) {
          tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                            "ppp ccp: peer sent LCP Protocol-Reject for CCP while MPPE is required");
          tunnel_set_failure(0, 0, 0);
          return PPP_NEGOTIATE_MPPE_FAILED;
        }
        ccp_rejected = 1;
        ccp_required_by_peer = 0;
        tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "ppp ccp: peer sent LCP Protocol-Reject for CCP; using cleartext");
      }
      continue;
    }
    if (proto == PROTO_MPPE_DATA && mppe_forbidden_by_local) {
      tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp ccp: peer sent encrypted MPPE frame while MPPE is Off");
      tunnel_set_failure(0, 0, 0);
      return PPP_NEGOTIATE_MPPE_REQUIRED_BY_PEER;
    }
    if (proto == PROTO_CCP && proto_len == 2u && len >= 6u) {
      uint8_t ccp_code = p[2];
      uint8_t ccp_rid = p[3];
      uint16_t ccp_len = util_read_be16(p + 4u);
      if (ccp_len < 4u || 2u + (size_t)ccp_len > len)
        continue;
      const uint8_t *ccp_msg = p + 2u;
      int peer_ac = (in[0] == 0xff && in[1] == 0x03) ? 1 : 0;
      size_t prefix = (size_t)(p - in);
      if (ccp_code == 1u) {
        int has_mppe = 0;
        uint32_t peer_bits = 0u;
        int has_other = 0;
        if (ccp_parse_mppe_bits(ccp_msg, ccp_len, &has_mppe, &peer_bits, &has_other) != 0)
          continue;
        if (!ccp_enabled) {
          if (has_mppe || has_other) {
            if (has_mppe && mppe_forbidden_by_local)
              peer_requested_mppe = 1;
            uint8_t rejbuf[256];
            int rlen = ccp_build_reject_non_mppe(in, prefix, ccp_msg, ccp_len, 1, rejbuf, sizeof(rejbuf));
            if (rlen > 0 && ppp_transport_send(transport, rejbuf, (size_t)rlen) < 0)
              return -1;
            tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "ppp ccp: rejected peer CCP CR id=%u (%s)",
                              (unsigned)ccp_rid, mppe_forbidden_by_local ? "MPPE disabled" : "MPPE unavailable");
            if (has_mppe && mppe_forbidden_by_local && ++mppe_reject_count > 5) {
              tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                                "ppp ccp: peer insisted on MPPE after %d Configure-Rejects while MPPE is Off",
                                mppe_reject_count - 1);
              tunnel_set_failure(0, 0, 0);
              return PPP_NEGOTIATE_MPPE_REQUIRED_BY_PEER;
            }
          } else {
            /* Empty CCP CR (no compression): ack cleanly without activating MPPE. */
            uint8_t ackbuf[64];
            size_t total_ack = prefix + 2u + (size_t)ccp_len;
            if (total_ack <= sizeof(ackbuf) && total_ack <= (size_t)n) {
              memcpy(ackbuf, in, total_ack);
              ackbuf[prefix + 2u] = 2u;
              if (ppp_transport_send(transport, ackbuf, total_ack) < 0)
                return -1;
            }
          }
          continue;
        }
        if (has_other) {
          uint8_t rejbuf[256];
          int rlen = ccp_build_reject_non_mppe(in, prefix, ccp_msg, ccp_len, 0, rejbuf, sizeof(rejbuf));
          if (rlen > 0 && ppp_transport_send(transport, rejbuf, (size_t)rlen) < 0)
            return -1;
          continue;
        }
        if (!has_mppe) {
          if (mppe_required_by_local) {
            if (++ccp_unsupported_naks > 3) {
              tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                                "ppp ccp: peer offered empty CCP without MPPE while MPPE is On");
              tunnel_set_failure(0, 0, 0);
              return PPP_NEGOTIATE_MPPE_FAILED;
            }
            uint8_t nakbuf[32];
            int nlen = ccp_build_mppe_nak(nakbuf, sizeof(nakbuf), ccp_rid, MPPE_BIT_STATELESS | MPPE_BIT_128, peer_ac);
            if (nlen > 0 && ppp_transport_send(transport, nakbuf, (size_t)nlen) < 0)
              return -1;
            continue;
          }
          /* Empty CCP CR (no compression): ack cleanly without activating MPPE. */
          uint8_t ackbuf[64];
          size_t total_ack = prefix + 2u + (size_t)ccp_len;
          if (total_ack <= sizeof(ackbuf) && total_ack <= (size_t)n) {
            memcpy(ackbuf, in, total_ack);
            ackbuf[prefix + 2u] = 2u;
            if (ppp_transport_send(transport, ackbuf, total_ack) < 0)
              return -1;
          }
          continue;
        }
        ccp_required_by_peer = 1;
        uint32_t exact_stateless = MPPE_BIT_STATELESS | MPPE_BIT_128;
        uint32_t exact_stateful = MPPE_BIT_128;
        if (peer_bits == exact_stateless || peer_bits == exact_stateful) {
          uint8_t ackbuf[64];
          size_t total_ack = prefix + 2u + (size_t)ccp_len;
          if (total_ack <= sizeof(ackbuf) && total_ack <= (size_t)n) {
            memcpy(ackbuf, in, total_ack);
            ackbuf[prefix + 2u] = 2u;
            if (ppp_transport_send(transport, ackbuf, total_ack) < 0)
              return -1;
            ccp_we_acked_peer = 1;
            ccp_stateful = (peer_bits == exact_stateful) ? 1 : 0;
            tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "ppp ccp: acked peer MPPE-128 CR id=%u mode=%s",
                              (unsigned)ccp_rid, ccp_stateful ? "stateful" : "stateless");
          }
        } else if ((peer_bits & MPPE_BIT_128) != 0u) {
          uint32_t narrowed = (peer_bits & MPPE_BIT_STATELESS) | MPPE_BIT_128;
          uint8_t nakbuf[32];
          int nlen = ccp_build_mppe_nak(nakbuf, sizeof(nakbuf), ccp_rid, narrowed, peer_ac);
          if (nlen > 0 && ppp_transport_send(transport, nakbuf, (size_t)nlen) < 0)
            return -1;
          tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ccp: nak peer MPPE CR id=%u bits=0x%08x -> 0x%08x",
                            (unsigned)ccp_rid, peer_bits, narrowed);
        } else {
          if (++ccp_unsupported_naks > 3) {
            tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                              "ppp ccp: peer offered unsupported MPPE bits=0x%08x (128-bit required)", peer_bits);
            return PPP_NEGOTIATE_MPPE_FAILED;
          }
          uint8_t nakbuf[32];
          int nlen = ccp_build_mppe_nak(nakbuf, sizeof(nakbuf), ccp_rid, MPPE_BIT_STATELESS | MPPE_BIT_128, peer_ac);
          if (nlen > 0 && ppp_transport_send(transport, nakbuf, (size_t)nlen) < 0)
            return -1;
        }
      } else if (ccp_code == 2u && ccp_enabled && ccp_rid == ccp_id) {
        ccp_peer_acked = 1;
        ccp_required_by_peer = 1;
        tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ccp: Configure-Ack id=%u", (unsigned)ccp_id);
      } else if (ccp_code == 3u && ccp_enabled && ccp_rid == ccp_id) {
        int has_mppe = 0;
        uint32_t nak_bits = 0u;
        if (ccp_parse_mppe_bits(ccp_msg, ccp_len, &has_mppe, &nak_bits, NULL) != 0 || !has_mppe ||
            (nak_bits & MPPE_BIT_128) == 0u) {
          tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp ccp: peer NAK did not offer MPPE-128 bits=0x%08x",
                            nak_bits);
          return PPP_NEGOTIATE_MPPE_FAILED;
        }
        our_ccp_bits = (nak_bits & MPPE_BIT_STATELESS) | MPPE_BIT_128;
        ccp_stateful = (our_ccp_bits & MPPE_BIT_STATELESS) == 0u ? 1 : 0;
        ccp_id++;
        ccp_plen = ccp_build_mppe_cr(ccp_pkt, sizeof(ccp_pkt), ccp_id, our_ccp_bits, peer_ac);
        if (ccp_plen < 0 || ppp_transport_send(transport, ccp_pkt, (size_t)ccp_plen) < 0)
          return -1;
        last_ccp_send_ms = ppp_now_ms();
        tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ccp: resend CR after NAK id=%u bits=0x%08x",
                          (unsigned)ccp_id, our_ccp_bits);
      } else if (ccp_code == 4u && ccp_enabled && ccp_rid == ccp_id) {
        if (mppe_required_by_local) {
          tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                            "ppp ccp: peer Configure-Reject for MPPE while MPPE is On");
          tunnel_set_failure(0, 0, 0);
          return PPP_NEGOTIATE_MPPE_FAILED;
        }
        ccp_rejected = 1;
        ccp_required_by_peer = 0;
        tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "ppp ccp: peer Configure-Reject for MPPE; using cleartext");
      } else if (ccp_code == 5u) {
        uint8_t tack[16];
        size_t total_tack = prefix + 6u;
        if (total_tack <= sizeof(tack)) {
          memcpy(tack, in, prefix + 2u);
          tack[prefix + 2u] = 6u; /* Terminate-Ack */
          tack[prefix + 3u] = ccp_rid;
          util_write_be16(tack + prefix + 4u, 4u);
          (void)ppp_transport_send(transport, tack, total_tack);
        }
        if (mppe_required_by_local) {
          tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                            "ppp ccp: peer sent CCP Terminate-Request while MPPE is On");
          tunnel_set_failure(0, 0, 0);
          return PPP_NEGOTIATE_MPPE_FAILED;
        }
      }

      if (ccp_enabled && ccp_peer_acked && ccp_we_acked_peer && !ppp->mppe.enabled) {
        if (ppp_mppe_init_client(&ppp->mppe, ppp->mschapv2_hash_hash, ppp->mschapv2_nt_response, ccp_stateful) != 0) {
          tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp ccp: failed initializing MPPE-128 cipher");
          return PPP_NEGOTIATE_MPPE_FAILED;
        }
        tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "ppp ccp: MPPE-128 active mode=%s",
                          ccp_stateful ? "stateful" : "stateless");
        if (!got_ack) {
          if (ppp_transport_send(transport, pkt, (size_t)plen) < 0)
            return -1;
          last_cr_send_ms = ppp_now_ms();
        }
      }
      continue;
    }
    if (proto != PROTO_IPCP) {
      /* LCP and unrelated protocols are expected while waiting; skip and continue. */
      if (proto == PROTO_LCP && len >= proto_len + 1u) {
        tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: skip LCP code=%u while awaiting Configure-Ack",
                          (unsigned)p[proto_len]);
      } else {
        tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: skip proto=0x%04x len=%zu", (unsigned)proto, len);
      }
      continue;
    }
    ppp_log_rx_summary(p, len, "ipcp");
    if (proto_len != 2u || len < 6u) {
      tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: skip unexpected protocol-field-len=%zu", proto_len);
      continue;
    }
    uint8_t code = p[2];
    uint8_t rid = p[3];
    uint16_t ipcplen = util_read_be16(p + 4);
    if (ipcplen < 4u || 2u + (size_t)ipcplen > len) {
      tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: skip invalid-length code=%u id=%u ipcplen=%u len=%zu",
                        (unsigned)code, (unsigned)rid, (unsigned)ipcplen, len);
      continue;
    }
    const uint8_t *ipcp_msg = p + 2u;

    if (code == 1) {
      /* Peer Configure-Request: capture hints, send Configure-Ack, maybe re-send our current request. */
      if (!ipcp_peer_framing_seen) {
        ipcp_peer_framing_seen = 1;
        ipcp_out_include_ac = (in[0] == 0xff && in[1] == 0x03) ? 1 : 0;
        tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp peer framing addr_ctl=%d", ipcp_out_include_ac);
      }
      uint8_t peer_gw[4];
      if (ppp_ipcp_opts_first_ipv4_option(ipcp_msg, ipcplen, IPCP_OPT_IP_ADDRESS, peer_gw) == 0) {
        memcpy(ppp->peer_ip, peer_gw, 4);
        tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: peer Configure-Request IP=%u.%u.%u.%u",
                          (unsigned)peer_gw[0], (unsigned)peer_gw[1], (unsigned)peer_gw[2], (unsigned)peer_gw[3]);
      }
      uint8_t ackbuf[256];
      size_t ack_ppp_len = 2u + (size_t)ipcplen;
      size_t prefix = (size_t)(p - in);
      size_t total_ack = prefix + ack_ppp_len;
      if (total_ack > (size_t)n || total_ack > sizeof(ackbuf))
        continue;
      memcpy(ackbuf, in, total_ack);
      if (util_read_be16(ackbuf + prefix) != PROTO_IPCP)
        continue;
      ackbuf[prefix + 2u] = 2;
      tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: sending Configure-Ack for peer id=%u", (unsigned)rid);
      if (ppp_transport_send(transport, ackbuf, total_ack) < 0)
        return -1;
      if (!got_ack && ppp_now_ms() - last_cr_send_ms >= resend_after_ms) {
        tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG,
                          "ppp ipcp: resend current Configure-Request id=%u reason=peer-configure-request",
                          (unsigned)id);
        if (ppp_transport_send(transport, pkt, (size_t)plen) < 0)
          return -1;
        last_cr_send_ms = ppp_now_ms();
      }
      continue;
    }

    if (code == 2 && rid == id) {
      /* Our Configure-Ack: commit negotiated addressing and DNS values. */
      if (ppp_ipcp_opts_first_ipv4_option(ipcp_msg, ipcplen, IPCP_OPT_IP_ADDRESS, ppp->local_ip) != 0) {
        memcpy(ppp->local_ip, req_ip, 4);
      }
      /* Compatibility fallback for peers that acknowledge but leave local IP unset/zero. */
      if (ipcp_ipv4_is_zero(ppp->local_ip)) {
        ppp->local_ip[0] = 10;
        ppp->local_ip[1] = 0;
        ppp->local_ip[2] = 0;
        ppp->local_ip[3] = 2;
      }
      ppp->have_ip = 1;
      if (include_primary_dns_opt &&
          ppp_ipcp_opts_first_ipv4_option(ipcp_msg, ipcplen, IPCP_OPT_PRIMARY_DNS, ppp->primary_dns) != 0) {
        memcpy(ppp->primary_dns, req_primary_dns, 4);
      }
      if (!ipcp_ipv4_is_zero(ppp->primary_dns)) {
        ppp->have_primary_dns = 1;
      }
      if (include_secondary_dns_opt &&
          ppp_ipcp_opts_first_ipv4_option(ipcp_msg, ipcplen, IPCP_OPT_SECONDARY_DNS, ppp->secondary_dns) != 0) {
        memcpy(ppp->secondary_dns, req_secondary_dns, 4);
      }
      if (!ipcp_ipv4_is_zero(ppp->secondary_dns)) {
        ppp->have_secondary_dns = 1;
      }
      tunnel_engine_log(
          ANDROID_LOG_DEBUG, LOG_TAG,
          "ppp ipcp: Configure-Ack id=%u local=%u.%u.%u.%u primary_dns=%u.%u.%u.%u secondary_dns=%u.%u.%u.%u",
          (unsigned)id, (unsigned)ppp->local_ip[0], (unsigned)ppp->local_ip[1], (unsigned)ppp->local_ip[2],
          (unsigned)ppp->local_ip[3], (unsigned)ppp->primary_dns[0], (unsigned)ppp->primary_dns[1],
          (unsigned)ppp->primary_dns[2], (unsigned)ppp->primary_dns[3], (unsigned)ppp->secondary_dns[0],
          (unsigned)ppp->secondary_dns[1], (unsigned)ppp->secondary_dns[2], (unsigned)ppp->secondary_dns[3]);
      got_ack = 1;
      ipcp_acked_ms = ppp_now_ms();
      continue;
    }
    if (code == 2) {
      tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: skip unexpected Configure-Ack id=%u want=%u",
                        (unsigned)rid, (unsigned)id);
      continue;
    }

    if (code == 3 && rid == id) {
      /* Configure-Nak: adopt peer-suggested values and resend next Configure-Request. */
      if (ppp_ipcp_opts_first_ipv4_option(ipcp_msg, ipcplen, IPCP_OPT_IP_ADDRESS, req_ip) == 0) {
        tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: Configure-Nak id=%u suggested=%u.%u.%u.%u",
                          (unsigned)rid, (unsigned)req_ip[0], (unsigned)req_ip[1], (unsigned)req_ip[2],
                          (unsigned)req_ip[3]);
      }
      if (ppp_ipcp_opts_first_ipv4_option(ipcp_msg, ipcplen, IPCP_OPT_PRIMARY_DNS, req_primary_dns) == 0) {
        tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: Configure-Nak id=%u primary_dns=%u.%u.%u.%u",
                          (unsigned)rid, (unsigned)req_primary_dns[0], (unsigned)req_primary_dns[1],
                          (unsigned)req_primary_dns[2], (unsigned)req_primary_dns[3]);
      }
      if (ppp_ipcp_opts_first_ipv4_option(ipcp_msg, ipcplen, IPCP_OPT_SECONDARY_DNS, req_secondary_dns) == 0) {
        tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: Configure-Nak id=%u secondary_dns=%u.%u.%u.%u",
                          (unsigned)rid, (unsigned)req_secondary_dns[0], (unsigned)req_secondary_dns[1],
                          (unsigned)req_secondary_dns[2], (unsigned)req_secondary_dns[3]);
      }
      id++;
      plen = ppp_ipcp_build_cr(pkt, sizeof(pkt), id, req_ip, ipcp_out_include_ac, include_ip_opt, req_primary_dns,
                               include_primary_dns_opt, req_secondary_dns, include_secondary_dns_opt);
      if (plen < 0)
        return -1;
      if (ppp_transport_send(transport, pkt, (size_t)plen) < 0)
        return -1;
      last_cr_send_ms = ppp_now_ms();
      continue;
    }
    if (code == 3) {
      tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: skip unexpected Configure-Nak id=%u want=%u",
                        (unsigned)rid, (unsigned)id);
      continue;
    }

    if (code == 4 && rid == id) {
      /* Configure-Reject: disable rejected options and resend with next id. */
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp ipcp: Configure-Reject id=%u", (unsigned)rid);
      ipcp_apply_conf_reject_opts(ipcp_msg, ipcplen, &include_ip_opt, &include_primary_dns_opt,
                                  &include_secondary_dns_opt);
      id++;
      plen = ppp_ipcp_build_cr(pkt, sizeof(pkt), id, req_ip, ipcp_out_include_ac, include_ip_opt, req_primary_dns,
                               include_primary_dns_opt, req_secondary_dns, include_secondary_dns_opt);
      if (plen < 0)
        return -1;
      if (ppp_transport_send(transport, pkt, (size_t)plen) < 0)
        return -1;
      last_cr_send_ms = ppp_now_ms();
      continue;
    }
    if (code == 4) {
      tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: skip unexpected Configure-Reject id=%u want=%u",
                        (unsigned)rid, (unsigned)id);
      continue;
    }
    tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp ipcp: skip unsupported code=%u id=%u", (unsigned)code,
                      (unsigned)rid);
  }

  if ((ccp_required_by_peer || mppe_required_by_local) && !ppp->mppe.enabled) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp ccp: MPPE negotiation did not complete");
    tunnel_set_failure(0, 0, 0);
    return PPP_NEGOTIATE_MPPE_FAILED;
  }
  if (!got_ack) {
    /* IPCP did not reach Configure-Ack for our request within retry budget. */
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp ipcp: timeout without Configure-Ack");
    if (mppe_forbidden_by_local && peer_requested_mppe) {
      tunnel_set_failure(0, 0, 0);
      return PPP_NEGOTIATE_MPPE_REQUIRED_BY_PEER;
    }
    return -1;
  }
  return 0;
}

/**
 * TCP SYN MSS clamping and IPv4/L4 checksum fixups live in ppp_wire.c so host unit tests execute
 * the exact same production framing logic.
 */

/* --- Exported PPP API (negotiate, TUN egress, inbound dispatch) --- */

static size_t ppp_session_frame_prefix(uint8_t *buf, size_t cap, uint16_t proto, const ppp_session_t *ppp) {
  return ppp_write_frame_prefix(buf, cap, proto, ppp != NULL && ppp->lcp_acfc, ppp != NULL && ppp->lcp_pfc);
}

void ppp_session_clear_secrets(ppp_session_t *ppp) {
  if (ppp == NULL)
    return;
  ppp_mppe_zero(&ppp->mppe);
  mbedtls_platform_zeroize(ppp->mschapv2_hash_hash, sizeof(ppp->mschapv2_hash_hash));
  mbedtls_platform_zeroize(ppp->mschapv2_nt_response, sizeof(ppp->mschapv2_nt_response));
  ppp->mppe_keys_ready = 0;
}

int ppp_negotiate_over_transport(ppp_transport_t *transport, const char *user, const char *password, int tun_mtu,
                                 ppp_session_t *ppp) {
  if (transport == NULL || ppp == NULL)
    return -1;
  memset(ppp, 0, sizeof(*ppp));
  ppp->link_mtu = ppp_sanitize_link_mtu(tun_mtu);
  ppp->tcp_mss = ppp_tcp_mss_for_link_mtu(ppp->link_mtu);
  tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp negotiate: start link_mtu=%u advertised_mru=%u tcp_mss=%u mppe=%d",
                    (unsigned)ppp->link_mtu, (unsigned)ppp->link_mtu, (unsigned)ppp->tcp_mss,
                    transport->enable_mppe ? 1 : 0);
  ppp_auth_kind_t auth = PPP_AUTH_PAP;
  int lcp_rc = ppp_lcp_negotiate_transport(transport, &auth, ppp);
  if (lcp_rc != 0) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp negotiate: failed during LCP rc=%d", lcp_rc);
    return lcp_rc;
  }

  if (auth == PPP_AUTH_MSCHAPV2) {
    if (ppp_auth_mschapv2_transport(transport, user, password, ppp) != 0) {
      tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp negotiate: auth failure method=mschapv2");
      return -1;
    }
  } else if (auth == PPP_AUTH_CHAP_MD5) {
    if (ppp_auth_chap_md5_transport(transport, user, password) != 0) {
      tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp negotiate: auth failure method=chap-md5");
      return -1;
    }
  } else {
    if (ppp_auth_pap_transport(transport, user, password) != 0) {
      tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp negotiate: auth failure method=pap");
      return -1;
    }
  }

  if (transport->enable_mppe && transport->mppe_mode == TUNNEL_MPPE_ON && !ppp->mppe_keys_ready) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG,
                      "ppp negotiate: MPPE is On but MS-CHAPv2 keys are unavailable (auth=%s)", ppp_auth_name(auth));
    tunnel_set_failure(0, 0, 0);
    return PPP_NEGOTIATE_MPPE_FAILED;
  }

  int ipcp_rc = ppp_ipcp_negotiate_transport(transport, ppp);
  if (ipcp_rc != 0) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "ppp negotiate: IPCP/CCP failed rc=%d", ipcp_rc);
    ppp_session_clear_secrets(ppp);
    return ipcp_rc;
  }

  /* Clear MS-CHAPv2 intermediate hashes once MPPE (if any) has derived its session keys. */
  mbedtls_platform_zeroize(ppp->mschapv2_hash_hash, sizeof(ppp->mschapv2_hash_hash));
  mbedtls_platform_zeroize(ppp->mschapv2_nt_response, sizeof(ppp->mschapv2_nt_response));
  ppp->mppe_keys_ready = 0;
  return 0;
}

int ppp_negotiate(int esp_fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t peer_len, l2tp_session_t *l2tp,
                  const char *user, const char *password, int tun_mtu, int auth_policy, ppp_session_t *ppp) {
  ppp_l2tp_ctx_t ctx;
  ppp_transport_t transport;
  ppp_init_l2tp_transport(&transport, &ctx, esp_fd, esp, peer, peer_len, l2tp, auth_policy);
  int rc = ppp_negotiate_over_transport(&transport, user, password, tun_mtu, ppp);
  if (l2tp != NULL)
    l2tp->lcp_opened = transport.lcp_opened;
  return rc;
}

int ppp_encapsulate_and_send_over_transport(ppp_transport_t *transport, ppp_session_t *ppp, const uint8_t *ip_packet,
                                            size_t len) {
  if (transport == NULL || ip_packet == NULL || len == 0u || len > 3900u)
    return -1;
  uint8_t ip_copy[4000];
  memcpy(ip_copy, ip_packet, len);
  tf_ipv4_info_t ipv4_info;
  int ipv4_valid = tf_ipv4_parse(ip_copy, len, &ipv4_info) == 0;
  if (ipv4_valid) {
    tf_l4_checksum_result_t checksum_status = tf_ipv4_l4_checksum_status(ip_copy, len, &ipv4_info);
    if (checksum_status == TF_L4_CHECKSUM_INVALID) {
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp outbound invalid l4 checksum proto=%u len=%zu total_len=%zu",
                        (unsigned)ipv4_info.protocol, len, ipv4_info.total_len);
    }
  } else {
    tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp outbound malformed ipv4 len=%zu", len);
  }
  if (ppp != NULL && ppp->tcp_mss >= 536u) {
    uint16_t old_mss = 0u;
    uint16_t new_mss = 0u;
    if (ppp_clamp_tcp_syn_mss(ip_copy, len, ppp->tcp_mss, &old_mss, &new_mss) > 0 && !ppp->tcp_mss_clamp_logged) {
      ppp->tcp_mss_clamp_logged = 1;
      tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp tcp syn mss clamp old=%u new=%u link_mtu=%u",
                        (unsigned)old_mss, (unsigned)new_mss, (unsigned)ppp->link_mtu);
    }
  }
  uint8_t fixed_proto = 0u;
  (void)ppp_fix_tun_ipv4_checksums(ip_copy, len, &fixed_proto);

  uint8_t buf[4096];
  if (ppp != NULL && ppp->mppe.enabled) {
    uint8_t plain[4010];
    util_write_be16(plain, PROTO_IP);
    memcpy(plain + 2u, ip_copy, len);
    size_t prefix = ppp_session_frame_prefix(buf, sizeof(buf), PROTO_MPPE_DATA, ppp);
    if (prefix == 0u)
      return -1;
    int elen = ppp_mppe_encrypt(&ppp->mppe, plain, 2u + len, buf + prefix, sizeof(buf) - prefix);
    if (elen <= 0)
      return -1;
    return ppp_transport_send(transport, buf, prefix + (size_t)elen);
  }

  size_t prefix = ppp_session_frame_prefix(buf, sizeof(buf), PROTO_IP, ppp);
  if (prefix == 0u || len + prefix > sizeof(buf))
    return -1;
  memcpy(buf + prefix, ip_copy, len);
  return ppp_transport_send(transport, buf, len + prefix);
}

int ppp_encapsulate_and_send(int esp_fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t peer_len,
                             l2tp_session_t *l2tp, ppp_session_t *ppp, const uint8_t *ip_packet, size_t len) {
  ppp_l2tp_ctx_t ctx;
  ppp_transport_t transport;
  ppp_init_l2tp_transport(&transport, &ctx, esp_fd, esp, peer, peer_len, l2tp, TUNNEL_PPP_AUTH_AUTO);
  return ppp_encapsulate_and_send_over_transport(&transport, ppp, ip_packet, len);
}

/** RFC 1661 LCP Code 8 Protocol-Reject: peer used a network protocol we do not implement. */
static int ppp_send_lcp_protocol_reject_transport(ppp_transport_t *transport, ppp_session_t *ppp,
                                                  uint16_t rejected_proto, const uint8_t *rejected_info,
                                                  size_t rejected_info_len) {
  if (transport == NULL)
    return -1;
  uint8_t buf[256];
  const size_t lcp_fixed = 6; /* code + id + length + rejected_protocol */
  const size_t ppp_prefix = ppp_session_frame_prefix(buf, sizeof(buf), PROTO_LCP, ppp);
  if (ppp_prefix == 0u)
    return -1;
  size_t ilen = rejected_info_len;
  if (ilen > sizeof(buf) - ppp_prefix - lcp_fixed)
    ilen = sizeof(buf) - ppp_prefix - lcp_fixed;

  static uint8_t s_proto_reject_id = 200;
  uint8_t id = ++s_proto_reject_id;
  if (id == 0)
    id = 1;

  const size_t lcp_len = lcp_fixed + ilen;
  if (ppp_prefix + lcp_len > sizeof(buf))
    return -1;

  buf[ppp_prefix + 0u] = (uint8_t)LCP_CODE_PROTOCOL_REJECT;
  buf[ppp_prefix + 1u] = id;
  util_write_be16(buf + ppp_prefix + 2u, (uint16_t)lcp_len);
  util_write_be16(buf + ppp_prefix + 4u, rejected_proto);
  if (ilen != 0 && rejected_info != NULL)
    memcpy(buf + ppp_prefix + 6u, rejected_info, ilen);
  return ppp_transport_send(transport, buf, ppp_prefix + lcp_len);
}

/** RFC 1661 LCP Echo-Reply: answer peer keepalive on the data channel. */
static int ppp_send_lcp_echo_reply_transport(ppp_transport_t *transport, ppp_session_t *ppp, const uint8_t *req_lcp,
                                             size_t req_len) {
  if (transport == NULL)
    return -1;
  uint8_t buf[256];
  int total = ppp_build_lcp_echo_reply_frame(buf, sizeof(buf), req_lcp, req_len, ppp != NULL && ppp->lcp_acfc,
                                             ppp != NULL && ppp->lcp_pfc);
  if (total <= 0)
    return -1;
  return ppp_transport_send(transport, buf, (size_t)total);
}

static int ppp_send_ccp_reset_transport(ppp_transport_t *transport, ppp_session_t *ppp, uint8_t code, uint8_t id) {
  if (transport == NULL)
    return -1;
  uint8_t buf[16];
  const size_t ppp_prefix = ppp_session_frame_prefix(buf, sizeof(buf), PROTO_CCP, ppp);
  if (ppp_prefix == 0u || ppp_prefix + 4u > sizeof(buf))
    return -1;
  buf[ppp_prefix + 0u] = code;
  buf[ppp_prefix + 1u] = id;
  util_write_be16(buf + ppp_prefix + 2u, 4u);
  return ppp_transport_send(transport, buf, ppp_prefix + 4u);
}

int ppp_send_lcp_echo_request_over_transport(ppp_transport_t *transport, ppp_session_t *ppp, uint8_t id) {
  if (transport == NULL) {
    errno = EINVAL;
    return -1;
  }
  uint8_t buf[32];
  const size_t ppp_prefix = ppp_session_frame_prefix(buf, sizeof(buf), PROTO_LCP, ppp);
  if (ppp_prefix == 0u || ppp_prefix + 8u > sizeof(buf))
    return -1;
  buf[ppp_prefix + 0u] = (uint8_t)LCP_CODE_ECHO_REQUEST;
  buf[ppp_prefix + 1u] = id;
  util_write_be16(buf + ppp_prefix + 2u, 8u);
  /* We never negotiated Magic-Number, so request magic stays zero per RFC 1661 section 5.8. */
  util_write_be32(buf + ppp_prefix + 4u, 0u);
  return ppp_transport_send(transport, buf, ppp_prefix + 8u);
}

int ppp_send_lcp_echo_request(int esp_fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t peer_len,
                              l2tp_session_t *l2tp, ppp_session_t *ppp, uint8_t id) {
  if (esp == NULL || peer == NULL || l2tp == NULL) {
    errno = EINVAL;
    return -1;
  }
  ppp_l2tp_ctx_t ctx;
  ppp_transport_t transport;
  ppp_init_l2tp_transport(&transport, &ctx, esp_fd, esp, peer, peer_len, l2tp, TUNNEL_PPP_AUTH_AUTO);
  return ppp_send_lcp_echo_request_over_transport(&transport, ppp, id);
}

static int ppp_deliver_ipv4_payload(const uint8_t *p, size_t len, packet_endpoint_t *endpoint) {
  tf_ipv4_info_t ipv4_info;
  if (tf_ipv4_parse(p, len, &ipv4_info) != 0) {
    tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp inbound malformed ipv4 dropped len=%zu", len);
    return 0;
  }
  /*
   * PPP frames may carry padding after the IPv4 payload. Deliver only the declared IPv4 length
   * to TUN/gVisor so trailing bytes do not become part of the packet stream.
   */
  size_t write_len = ipv4_info.total_len;
  if (write_len < len) {
    tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "ppp inbound ipv4 trimmed original_len=%zu total_len=%zu", len,
                      write_len);
  }
  if (packet_endpoint_write(endpoint, p, write_len) != 0) {
    static time_t s_last_tun_write_warn;
    time_t now = time(NULL);
    if (now - s_last_tun_write_warn >= 3) {
      s_last_tun_write_warn = now;
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "ppp ip write endpoint=%s failed errno=%d len=%zu",
                        endpoint != NULL && endpoint->name != NULL ? endpoint->name : "unknown", errno, write_len);
    }
    return -1;
  }
  return 0;
}

int ppp_dispatch_ppp_frame_over_transport(ppp_transport_t *transport, ppp_session_t *ppp, const uint8_t *frame,
                                          size_t len, packet_endpoint_t *endpoint) {
  if (len < 2)
    return -1;
  const uint8_t log_b0 = frame[0];
  const uint8_t log_b1 = frame[1];
  const size_t log_frame_len = len;
  const uint8_t *p = frame;
  if (p[0] == 0xff && p[1] == 0x03) {
    p += 2;
    len -= 2;
  }
  uint16_t proto = 0u;
  size_t proto_len = 0u;
  if (ppp_read_protocol(p, len, &proto, &proto_len) != 0 || len < proto_len)
    return -1;
  p += proto_len;
  len -= proto_len;

  /* 0x00fd: MPPE-encrypted PPP frame -> decrypt then dispatch inner IPv4. */
  if (proto == PROTO_MPPE_DATA) {
    if (ppp == NULL || !ppp->mppe.enabled)
      return 0;
    uint8_t decrypted[4096];
    size_t dec_len = 0u;
    int drc = ppp_mppe_decrypt(&ppp->mppe, p, len, decrypted, sizeof(decrypted), &dec_len);
    if (drc == PPP_MPPE_DECRYPT_NEED_RESET) {
      if (transport != NULL) {
        uint8_t rid = ++ppp->mppe.ccp_reset_id;
        (void)ppp_send_ccp_reset_transport(transport, ppp, CCP_CODE_RESET_REQUEST, rid);
      }
      return 0;
    }
    if (drc != PPP_MPPE_DECRYPT_OK || dec_len < 2u)
      return 0;
    uint16_t inner_proto = 0u;
    size_t inner_plen = 0u;
    if (ppp_read_protocol(decrypted, dec_len, &inner_proto, &inner_plen) != 0 || dec_len < inner_plen)
      return 0;
    if (inner_proto == PROTO_IP)
      return ppp_deliver_ipv4_payload(decrypted + inner_plen, dec_len - inner_plen, endpoint);
    return 0;
  }

  /* 0x80fd: runtime CCP Reset-Request / Reset-Ack for stateful MPPE resync. */
  if (proto == PROTO_CCP) {
    if (len >= 4u && p[0] == CCP_CODE_RESET_REQUEST && ppp != NULL && ppp->mppe.enabled) {
      ppp_mppe_note_tx_reset(&ppp->mppe);
      if (transport != NULL)
        (void)ppp_send_ccp_reset_transport(transport, ppp, CCP_CODE_RESET_ACK, p[1]);
    }
    return 0;
  }

  /* 0x0021: deliver IPv4 datagram to TUN (or proxy endpoint) only when MPPE is not active. */
  if (proto == PROTO_IP) {
    if (ppp != NULL && ppp->mppe.enabled)
      return 0;
    return ppp_deliver_ipv4_payload(p, len, endpoint);
  }
  /* 0x8057: IPv6CP not supported; signal with LCP Protocol-Reject. */
  if (proto == PROTO_IPV6CP) {
    static int s_ipv6cp_info_once;
    if (transport != NULL) {
      if (ppp_send_lcp_protocol_reject_transport(transport, ppp, PROTO_IPV6CP, p, len) >= 0) {
        if (!s_ipv6cp_info_once) {
          s_ipv6cp_info_once = 1;
          tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "IPv6CP: sent LCP Protocol-Reject (IPv4-only link)");
        }
      }
    }
    return 0;
  }
  /* 0xc021: post-negotiation LCP (Echo-Request / Echo-Reply keepalives). */
  if (proto == PROTO_LCP) {
    if (len >= 4 && p[0] == (uint8_t)LCP_CODE_ECHO_REPLY) {
      return 0;
    }
    if (len >= 4 && p[0] == (uint8_t)LCP_CODE_ECHO_REQUEST && transport != NULL) {
      if (ppp_send_lcp_echo_reply_transport(transport, ppp, p, len) >= 0)
        return 0;
      return -1;
    }
    static time_t s_last_lcp_dataplane_warn;
    time_t now_lcp = time(NULL);
    if (now_lcp - s_last_lcp_dataplane_warn >= 5) {
      s_last_lcp_dataplane_warn = now_lcp;
      tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG,
                        "ppp dispatch LCP on data channel code=%u inner_len=%zu (echo handled if code=9)",
                        len >= 1 ? (unsigned)p[0] : 0u, len);
    }
    return 0;
  }
  static time_t s_last_nonip_warn;
  time_t now = time(NULL);
  /* IPv6CP is expected in IPv4-only mode and is too noisy to warn for every peer retry. */
  if (proto != 0x8281u && now - s_last_nonip_warn >= 3) {
    s_last_nonip_warn = now;
    tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG,
                      "ppp dispatch non-ip proto=0x%04x frame_prefix=%02x%02x ppp_len=%zu (IPv4 0x0021 only)",
                      (unsigned)proto, (unsigned)log_b0, (unsigned)log_b1, log_frame_len);
  }
  return 0;
}

int ppp_dispatch_ppp_frame(int esp_fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t peer_len,
                           l2tp_session_t *l2tp, ppp_session_t *ppp, const uint8_t *frame, size_t len,
                           packet_endpoint_t *endpoint) {
  ppp_l2tp_ctx_t ctx;
  ppp_transport_t transport;
  ppp_transport_t *transport_ptr = NULL;
  if (esp != NULL && peer != NULL && l2tp != NULL) {
    ppp_init_l2tp_transport(&transport, &ctx, esp_fd, esp, peer, peer_len, l2tp, TUNNEL_PPP_AUTH_AUTO);
    transport_ptr = &transport;
  }
  return ppp_dispatch_ppp_frame_over_transport(transport_ptr, ppp, frame, len, endpoint);
}

typedef struct {
  const uint8_t *frames[8];
  size_t lens[8];
  size_t count;
  size_t idx;
  size_t tx_count;
} audit_ppp_mock_t;

static int audit_ppp_mock_send(void *ctx, const uint8_t *ppp, size_t len) {
  (void)ppp;
  (void)len;
  audit_ppp_mock_t *m = (audit_ppp_mock_t *)ctx;
  m->tx_count++;
  return 0;
}

static int audit_ppp_mock_recv(void *ctx, uint8_t *out, size_t cap, int timeout_ms) {
  (void)timeout_ms;
  audit_ppp_mock_t *m = (audit_ppp_mock_t *)ctx;
  if (m->idx >= m->count)
    return -1;
  size_t flen = m->lens[m->idx];
  if (flen > cap)
    return -1;
  memcpy(out, m->frames[m->idx], flen);
  m->idx++;
  return (int)flen;
}

typedef struct {
  size_t write_count;
} audit_ep_ctx_t;

static int audit_ep_write(void *ctx, const uint8_t *buf, size_t len) {
  (void)buf;
  (void)len;
  audit_ep_ctx_t *ep = (audit_ep_ctx_t *)ctx;
  ep->write_count++;
  return 0;
}

int ppp_run_audit_check(int item_id, char *err_buf, size_t err_cap) {
  if (item_id == 2) {
    static const uint8_t peer_cr[] = {0xff, 0x03, 0xc0, 0x21, 0x01, 0x01, 0x00, 0x04};
    static const uint8_t peer_nak_pap[] = {0xff, 0x03, 0xc0, 0x21, 0x03, 0x01, 0x00, 0x08, 0x03, 0x04, 0xc0, 0x23};
    static const uint8_t peer_ack[] = {0xff, 0x03, 0xc0, 0x21, 0x02, 0x02, 0x00, 0x04};
    audit_ppp_mock_t mock = {
        .frames = {peer_cr, peer_nak_pap, peer_ack},
        .lens = {sizeof(peer_cr), sizeof(peer_nak_pap), sizeof(peer_ack)},
        .count = 3,
    };
    ppp_transport_t t = {.ctx = &mock, .send_frame = audit_ppp_mock_send, .recv_frame = audit_ppp_mock_recv};
    ppp_session_t sess;
    memset(&sess, 0, sizeof(sess));
    sess.link_mtu = 1500;
    ppp_auth_kind_t auth = PPP_AUTH_MSCHAPV2;
    if (ppp_lcp_negotiate_transport(&t, &auth, &sess) != 0) {
      snprintf(err_buf, err_cap, "ppp_lcp_negotiate_transport failed");
      return -1;
    }
    if (auth != PPP_AUTH_PAP) {
      snprintf(err_buf, err_cap, "8-byte PAP Configure-Nak yielded auth=%d (%s), expected PPP_AUTH_PAP(%d)", (int)auth,
               ppp_auth_name(auth), (int)PPP_AUTH_PAP);
      return -1;
    }
    /* Empty 4-byte Configure-Nak must not underflow. */
    static const uint8_t empty_nak[] = {0xff, 0x03, 0xc0, 0x21, 0x03, 0x01, 0x00, 0x04};
    audit_ppp_mock_t mock2 = {
        .frames = {peer_cr, empty_nak, peer_ack},
        .lens = {sizeof(peer_cr), sizeof(empty_nak), sizeof(peer_ack)},
        .count = 3,
    };
    ppp_transport_t t2 = {.ctx = &mock2, .send_frame = audit_ppp_mock_send, .recv_frame = audit_ppp_mock_recv};
    ppp_auth_kind_t auth2 = PPP_AUTH_MSCHAPV2;
    if (ppp_lcp_negotiate_transport(&t2, &auth2, &sess) != 0 || auth2 != PPP_AUTH_CHAP_MD5) {
      snprintf(err_buf, err_cap, "4-byte empty Configure-Nak failed auth2=%d", (int)auth2);
      return -1;
    }
    /* Oversized username/password must be rejected without overflow or send. */
    char big_user[500];
    memset(big_user, 'u', sizeof(big_user) - 1u);
    big_user[sizeof(big_user) - 1u] = '\0';
    audit_ppp_mock_t mock_pap = {.count = 0};
    ppp_transport_t t_pap = {.ctx = &mock_pap, .send_frame = audit_ppp_mock_send, .recv_frame = audit_ppp_mock_recv};
    if (ppp_auth_pap_transport(&t_pap, big_user, "pw") != -1 || mock_pap.tx_count != 0u) {
      snprintf(err_buf, err_cap, "PAP accepted oversized username tx=%zu", mock_pap.tx_count);
      return -1;
    }
    if (ppp_auth_pap_transport(&t_pap, "user", big_user) != -1 || mock_pap.tx_count != 0u) {
      snprintf(err_buf, err_cap, "PAP accepted oversized password tx=%zu", mock_pap.tx_count);
      return -1;
    }
    static const uint8_t chap_chal[28] = {0xff, 0x03, 0xc2, 0x23, 0x01, 0x01, 0x00, 0x18, 0x10, 1,  2,  3,   4,   5,
                                          6,    7,    8,    9,    10,   11,   12,   13,   14,   15, 16, 's', 'r', 'v'};
    audit_ppp_mock_t mock_chap = {.frames = {chap_chal}, .lens = {sizeof(chap_chal)}, .count = 1};
    ppp_transport_t t_chap = {.ctx = &mock_chap, .send_frame = audit_ppp_mock_send, .recv_frame = audit_ppp_mock_recv};
    if (ppp_auth_chap_md5_transport(&t_chap, big_user, "pw") != -1 || mock_chap.tx_count != 0u) {
      snprintf(err_buf, err_cap, "CHAP-MD5 accepted oversized username tx=%zu", mock_chap.tx_count);
      return -1;
    }
    audit_ppp_mock_t mock_ms = {.frames = {chap_chal}, .lens = {sizeof(chap_chal)}, .count = 1};
    ppp_transport_t t_ms = {.ctx = &mock_ms, .send_frame = audit_ppp_mock_send, .recv_frame = audit_ppp_mock_recv};
    if (ppp_auth_mschapv2_transport(&t_ms, big_user, "pw", NULL) != -1 || mock_ms.tx_count != 0u) {
      snprintf(err_buf, err_cap, "MS-CHAPv2 accepted oversized username tx=%zu", mock_ms.tx_count);
      return -1;
    }
    /* RFC 1994 CHAP-MD5 must accept 255-byte username (matching RFC 1334 PAP). */
    char user255[256];
    memset(user255, 'u', 255);
    user255[255] = '\0';
    static const uint8_t chap_success[] = {0xff, 0x03, 0xc2, 0x23, 0x03, 0x01, 0x00, 0x04};
    audit_ppp_mock_t mock_chap255 = {
        .frames = {chap_chal, chap_success},
        .lens = {sizeof(chap_chal), sizeof(chap_success)},
        .count = 2,
    };
    ppp_transport_t t_chap255 = {
        .ctx = &mock_chap255, .send_frame = audit_ppp_mock_send, .recv_frame = audit_ppp_mock_recv};
    if (ppp_auth_chap_md5_transport(&t_chap255, user255, "pw") != 0 || mock_chap255.tx_count != 1u) {
      snprintf(err_buf, err_cap, "CHAP-MD5 rejected valid 255-byte username tx=%zu", mock_chap255.tx_count);
      return -1;
    }
    /* RFC 2759 MS-CHAPv2 accepts <= 256 UTF-16LE code units and rejects > 256 without silent truncation. */
    char pw257[258];
    memset(pw257, 'p', 257);
    pw257[257] = '\0';
    audit_ppp_mock_t mock_ms_pw = {.frames = {chap_chal}, .lens = {sizeof(chap_chal)}, .count = 1};
    ppp_transport_t t_ms_pw = {
        .ctx = &mock_ms_pw, .send_frame = audit_ppp_mock_send, .recv_frame = audit_ppp_mock_recv};
    if (ppp_auth_mschapv2_transport(&t_ms_pw, "user", pw257, NULL) != -1 || mock_ms_pw.tx_count != 0u) {
      snprintf(err_buf, err_cap, "MS-CHAPv2 accepted 257-char password tx=%zu", mock_ms_pw.tx_count);
      return -1;
    }
    uint8_t chal16[16] = {1}, pchal16[16] = {2}, val49[49], hh16[16];
    if (ppp_mschapv2_response_value("user", pw257, chal16, pchal16, val49) != -1 ||
        ppp_mschapv2_nt_password_hash_hash(pw257, hh16) != -1) {
      snprintf(err_buf, err_cap, "MS-CHAPv2 primitive truncated >256-char password instead of rejecting");
      return -1;
    }
    return 0;
  }
  if (item_id == 4) {
    audit_ep_ctx_t ep_ctx = {0};
    packet_endpoint_t ep = {.ctx = &ep_ctx, .write_packet = audit_ep_write, .name = "audit"};
    static const uint8_t cleartext_ip_frame[] = {
        0xff, 0x03, 0x00, 0x21, 0x45, 0x00, 0x00, 0x14, 0x00, 0x01, 0x00, 0x00,
        0x40, 0x11, 0x00, 0x00, 10,   0,    0,    1,    10,   0,    0,    2,
    };
    ppp_session_t sess;
    memset(&sess, 0, sizeof(sess));
    uint8_t hh[16] = {1};
    uint8_t ntr[24] = {2};
    if (ppp_mppe_init_client(&sess.mppe, hh, ntr, 0) != 0) {
      snprintf(err_buf, err_cap, "ppp_mppe_init_client failed");
      return -1;
    }
    (void)ppp_dispatch_ppp_frame_over_transport(NULL, &sess, cleartext_ip_frame, sizeof(cleartext_ip_frame), &ep);
    if (ep_ctx.write_count != 0u) {
      ppp_mppe_zero(&sess.mppe);
      snprintf(err_buf, err_cap, "cleartext PROTO_IP delivered while mppe.enabled=1 (inbound_count=%zu)",
               ep_ctx.write_count);
      return -1;
    }
    ppp_mppe_zero(&sess.mppe);
    /* Verify cleartext PROTO_IP still delivers when MPPE is disabled. */
    memset(&sess, 0, sizeof(sess));
    if (ppp_dispatch_ppp_frame_over_transport(NULL, &sess, cleartext_ip_frame, sizeof(cleartext_ip_frame), &ep) != 0 ||
        ep_ctx.write_count != 1u) {
      snprintf(err_buf, err_cap, "cleartext PROTO_IP failed when mppe.enabled=0 (inbound_count=%zu)",
               ep_ctx.write_count);
      return -1;
    }
    return 0;
  }
  snprintf(err_buf, err_cap, "unsupported ppp audit item=%d", item_id);
  return -1;
}
