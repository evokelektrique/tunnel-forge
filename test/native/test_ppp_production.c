#include <poll.h>
#include <sys/socket.h>
static int fake_poll(struct pollfd *fds, nfds_t n, int timeout);
static ssize_t fake_recv(int fd, void *buf, size_t n, int flags);
#define poll fake_poll
#define recv fake_recv
#include "../../android/app/src/main/cpp/ppp.c"
#undef poll
#undef recv
#include <assert.h>
/* Script the transport, keeping the real CHAP parser, MD5 and authentication loop. */
static unsigned received, sent;
static int test_mode;
static int failure[3];
void tunnel_set_failure(int kind, int code, int general_error) {
  failure[0] = kind;
  failure[1] = code;
  failure[2] = general_error;
}
static uint8_t response_ids[8];
static uint8_t response_hashes[8][16];
static int fake_poll(struct pollfd *fds, nfds_t n, int timeout) {
  (void)n;
  (void)timeout;
  fds[0].revents = POLLIN;
  return 1;
}
static ssize_t fake_recv(int fd, void *buf, size_t n, int flags) {
  (void)fd;
  (void)flags;
  uint8_t frame[31] = {0x40, 2};
  uint8_t *chap = frame + 8;
  util_write_be16(chap, PROTO_CHAP);
  chap[2] = received < 3 ? 1 : (test_mode == 1 ? 4 : 3);
  chap[3] = received == 0 ? 7 : 8;
  util_write_be16(chap + 4, received < 3 ? 21 : 4);
  chap[6] = 16;
  size_t length = received++ < 3 ? sizeof(frame) : 14;
  if (test_mode >= 2) {
    util_write_be16(chap, PROTO_PAP);
    chap[2] = 3;
    chap[3] = 1;
    util_write_be16(chap + 4, 5);
    chap[6] = test_mode == 3 ? 1 : 0; /* Mode 3 truncates the NAK message. */
    length = 15;
  }
  if (length > n)
    return -1;
  memcpy(buf, frame, length);
  return (ssize_t)length;
}
int tunnel_should_stop(void) { return 0; }
void tunnel_engine_log(int p, const char *tag, const char *fmt, ...) {
  (void)p;
  (void)tag;
  (void)fmt;
}
int esp_try_decrypt(esp_keys_t *k, const uint8_t *in, size_t n, uint8_t *out, size_t *len) {
  (void)k;
  (void)in;
  (void)n;
  (void)out;
  (void)len;
  return -1;
}
void esp_decrypt_last_fail_snprint(char *buf, size_t n) {
  if (n)
    buf[0] = 0;
}
int l2tp_data_extract_ppp(const uint8_t *in, size_t n, const l2tp_session_t *s, const uint8_t **out, size_t *len,
                          int diag) {
  (void)s;
  (void)diag;
  if (n < 8)
    return -1;
  *out = in + 8;
  *len = n - 8;
  return 0;
}
int l2tp_dispatch_incoming(int fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t plen, l2tp_session_t *s,
                           const uint8_t *in, size_t n, packet_endpoint_t *endpoint, ppp_session_t *ppp) {
  (void)fd;
  (void)esp;
  (void)peer;
  (void)plen;
  (void)s;
  (void)in;
  (void)n;
  (void)endpoint;
  (void)ppp;
  return -1;
}
int l2tp_send_ppp(int fd, esp_keys_t *esp, const struct sockaddr *peer, socklen_t plen, l2tp_session_t *s,
                  const uint8_t *in, size_t n) {
  (void)fd;
  (void)esp;
  (void)peer;
  (void)plen;
  (void)s;
  if (test_mode >= 2) {
    assert(n >= 8 && util_read_be16(in + 2) == PROTO_PAP);
    sent++;
    return (int)n;
  }
  assert(n >= 25 && in[4] == 2 && sent < sizeof(response_ids));
  memcpy(response_hashes[sent], in + 9, 16);
  response_ids[sent++] = in[5];
  return (int)n;
}

int main(void) {
  uint8_t packet[256];
  int mru = 1, accm = 1, auth = 0, removed_accm, removed_auth;
  const uint8_t reject[] = {4, 1, 0, 8, 1, 4, 5, 120};
  lcp_apply_conf_reject(reject, sizeof(reject), &accm, &auth, &removed_accm, &removed_auth, &mru);
  assert(mru == 0 && accm == 1 && auth == 0);
  int n = lcp_build_cr(packet, sizeof(packet), 1, PPP_AUTH_MSCHAPV2, 1400, 1, 0, 0, mru);
  assert(n == 8 && util_read_be16(packet + 6) == 4);
  /* pppd with plain `auth`: MRU 1410, ACCM, auth EAP, magic. EAP must be Nak'd with MS-CHAPv2, never acked. */
  const uint8_t eap_cr[] = {0xff, 0x03, 0xc0, 0x21, 1, 1, 0, 24, 1, 4, 0x05, 0x82, 2, 6, 0, 0, 0, 0,
                            3, 4, 0xc2, 0x27, 5, 6, 0x56, 0xef, 0x1e, 0x20};
  ppp_auth_kind_t peer_auth = PPP_AUTH_PAP;
  assert(lcp_parse_peer_auth(eap_cr + 4, sizeof(eap_cr) - 4, &peer_auth) == -1 && peer_auth == PPP_AUTH_PAP);
  assert(lcp_build_reject_for_unsupported(eap_cr, 2, eap_cr + 2, sizeof(eap_cr) - 2, packet, sizeof(packet)) == 0);
  n = lcp_build_nak_for_unsupported_auth(eap_cr, 2, eap_cr + 2, sizeof(eap_cr) - 2, packet, sizeof(packet));
  const uint8_t eap_nak[] = {0xff, 0x03, 0xc0, 0x21, 3, 1, 0, 9, 3, 5, 0xc2, 0x23, 0x81};
  assert(n == (int)sizeof(eap_nak) && memcmp(packet, eap_nak, sizeof(eap_nak)) == 0);
  /* MS-CHAPv1 (algorithm 0x80) is not implemented either. */
  uint8_t chap_cr[] = {0xc0, 0x21, 1, 2, 0, 9, 3, 5, 0xc2, 0x23, 0x80};
  assert(lcp_parse_peer_auth(chap_cr + 2, sizeof(chap_cr) - 2, &peer_auth) == -1);
  assert(lcp_build_nak_for_unsupported_auth(chap_cr, 0, chap_cr, sizeof(chap_cr), packet, sizeof(packet)) == 11);
  assert(packet[2] == 3 && packet[3] == 2 && packet[10] == 0x81);
  /* Supported protocols are acked and adopted. */
  chap_cr[10] = 0x81;
  assert(lcp_build_nak_for_unsupported_auth(chap_cr, 0, chap_cr, sizeof(chap_cr), packet, sizeof(packet)) == 0);
  assert(lcp_parse_peer_auth(chap_cr + 2, sizeof(chap_cr) - 2, &peer_auth) == 0 && peer_auth == PPP_AUTH_MSCHAPV2);
  chap_cr[10] = 0x05;
  assert(lcp_build_nak_for_unsupported_auth(chap_cr, 0, chap_cr, sizeof(chap_cr), packet, sizeof(packet)) == 0);
  assert(lcp_parse_peer_auth(chap_cr + 2, sizeof(chap_cr) - 2, &peer_auth) == 0 && peer_auth == PPP_AUTH_CHAP_MD5);
  const uint8_t pap_cr[] = {0xc0, 0x21, 1, 3, 0, 8, 3, 4, 0xc0, 0x23};
  assert(lcp_build_nak_for_unsupported_auth(pap_cr, 0, pap_cr, sizeof(pap_cr), packet, sizeof(packet)) == 0);
  assert(lcp_parse_peer_auth(pap_cr + 2, sizeof(pap_cr) - 2, &peer_auth) == 0 && peer_auth == PPP_AUTH_PAP);
  uint8_t challenge[23] = {0xc2, 0x23, 1, 7, 0, 21, 16};
  assert(chap_challenge_valid(challenge, sizeof(challenge), 1));
  assert(chap_challenge_valid(challenge, sizeof(challenge), 0));
  assert(!chap_challenge_valid(challenge, sizeof(challenge) - 1, 1));
  assert(chap_repeated_challenge(challenge, sizeof(challenge), 7));
  assert(!chap_repeated_challenge(challenge, sizeof(challenge), 8));
  assert(!chap_repeated_challenge(challenge, sizeof(challenge) - 1, 7));
  challenge[6] = 17;
  assert(!chap_challenge_valid(challenge, sizeof(challenge), 1));
  const uint8_t success[] = {0xc2, 0x23, 3, 1, 0, 4};
  assert(chap_result_code(success, sizeof(success)) == 3);
  assert(chap_result_code(success, sizeof(success) - 1) == 0);
  esp_keys_t esp = {0};
  l2tp_session_t session = {0};
  assert(ppp_auth_chap_md5(0, &esp, NULL, 0, &session, "fixture", "fixture") == 0);
  assert(received == 4 && sent == 3);
  assert(response_ids[0] == 7 && response_ids[1] == 8 && response_ids[2] == 8);
  assert(memcmp(response_hashes[0], response_hashes[1], 16) != 0);
  assert(memcmp(response_hashes[1], response_hashes[2], 16) == 0);
  received = sent = 0;
  test_mode = 1;
  assert(ppp_auth_chap_md5(0, &esp, NULL, 0, &session, "fixture", "fixture") == -1);
  assert(failure[0] == 4 && failure[1] == 4);
  received = sent = 0;
  test_mode = 2;
  assert(ppp_auth_pap(0, &esp, NULL, 0, &session, "fixture", "fixture") == -1);
  assert(failure[0] == 5 && failure[1] == 3);
  received = sent = 0;
  test_mode = 3;
  tunnel_set_failure(0, 0, 0);
  assert(ppp_auth_pap(0, &esp, NULL, 0, &session, "fixture", "fixture") == -1);
  assert(received == 12 && failure[0] == 0);
  return 0;
}
