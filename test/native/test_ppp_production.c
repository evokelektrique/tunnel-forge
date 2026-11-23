#include "../../android/app/src/main/cpp/ppp.c"
#include <assert.h>
#include <mbedtls/md4.h>
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
static int fake_recv(void *ctx, uint8_t *buf, size_t cap, int timeout_ms) {
  (void)ctx;
  (void)timeout_ms;
  uint8_t chap[23] = {0};
  util_write_be16(chap, PROTO_CHAP);
  chap[2] = received < 3 ? 1 : (test_mode == 1 ? 4 : 3);
  chap[3] = received == 0 ? 7 : 8;
  util_write_be16(chap + 4, received < 3 ? 21 : 4);
  chap[6] = 16;
  size_t length = received++ < 3 ? sizeof(chap) : 6;
  if (test_mode >= 2) {
    util_write_be16(chap, PROTO_PAP);
    chap[2] = 3;
    chap[3] = 1;
    util_write_be16(chap + 4, 5);
    chap[6] = test_mode == 3 ? 1 : 0; /* Mode 3 truncates the NAK message. */
    length = 7;
  }
  assert(length <= cap);
  memcpy(buf, chap, length);
  return (int)length;
}
int tunnel_should_stop(void) { return 0; }
void tunnel_engine_log(int p, const char *tag, const char *fmt, ...) {
  (void)p;
  (void)tag;
  (void)fmt;
}
static int fake_send(void *ctx, const uint8_t *in, size_t n) {
  (void)ctx;
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
  ppp_lcp_apply_conf_reject(reject, sizeof(reject), &accm, &auth, &removed_accm, &removed_auth, &mru);
  assert(mru == 0 && accm == 1 && auth == 0);
  int n = ppp_lcp_build_cr(packet, sizeof(packet), 1, PPP_AUTH_MSCHAPV2, 1400, 1, 0, 0, mru);
  assert(n == 8 && util_read_be16(packet + 6) == 4);
  /* pppd with plain `auth`: MRU 1410, ACCM, auth EAP, magic. EAP must be Nak'd with MS-CHAPv2, never acked. */
  const uint8_t eap_cr[] = {0xff, 0x03, 0xc0, 0x21, 1, 1, 0, 24, 1, 4, 0x05, 0x82, 2, 6, 0, 0, 0, 0,
                            3, 4, 0xc2, 0x27, 5, 6, 0x56, 0xef, 0x1e, 0x20};
  ppp_auth_kind_t peer_auth = PPP_AUTH_PAP;
  assert(lcp_parse_peer_auth_for_policy(eap_cr + 4, sizeof(eap_cr) - 4, -1, &peer_auth, NULL) == -1 &&
         peer_auth == PPP_AUTH_PAP);
  assert(lcp_build_reject_for_unsupported(eap_cr, 2, eap_cr + 2, sizeof(eap_cr) - 2, packet, sizeof(packet)) == 0);
  n = lcp_build_nak_for_disallowed_auth(eap_cr, 2, eap_cr + 2, sizeof(eap_cr) - 2, -1, packet, sizeof(packet));
  const uint8_t eap_nak[] = {0xff, 0x03, 0xc0, 0x21, 3, 1, 0, 9, 3, 5, 0xc2, 0x23, 0x81};
  assert(n == (int)sizeof(eap_nak) && memcmp(packet, eap_nak, sizeof(eap_nak)) == 0);
  /* MS-CHAPv1 (algorithm 0x80) is not implemented either. */
  uint8_t chap_cr[] = {0xc0, 0x21, 1, 2, 0, 9, 3, 5, 0xc2, 0x23, 0x80};
  assert(lcp_parse_peer_auth_for_policy(chap_cr + 2, sizeof(chap_cr) - 2, -1, &peer_auth, NULL) == -1);
  assert(lcp_build_nak_for_disallowed_auth(chap_cr, 0, chap_cr, sizeof(chap_cr), -1, packet, sizeof(packet)) == 11);
  assert(packet[2] == 3 && packet[3] == 2 && packet[10] == 0x81);
  /* Supported protocols are acked and adopted. */
  chap_cr[10] = 0x81;
  assert(lcp_build_nak_for_disallowed_auth(chap_cr, 0, chap_cr, sizeof(chap_cr), -1, packet, sizeof(packet)) == 0);
  assert(lcp_parse_peer_auth_for_policy(chap_cr + 2, sizeof(chap_cr) - 2, -1, &peer_auth, NULL) == 0 &&
         peer_auth == PPP_AUTH_MSCHAPV2);
  chap_cr[10] = 0x05;
  assert(lcp_build_nak_for_disallowed_auth(chap_cr, 0, chap_cr, sizeof(chap_cr), -1, packet, sizeof(packet)) == 0);
  assert(lcp_parse_peer_auth_for_policy(chap_cr + 2, sizeof(chap_cr) - 2, -1, &peer_auth, NULL) == 0 &&
         peer_auth == PPP_AUTH_CHAP_MD5);
  const uint8_t pap_cr[] = {0xc0, 0x21, 1, 3, 0, 8, 3, 4, 0xc0, 0x23};
  assert(lcp_build_nak_for_disallowed_auth(pap_cr, 0, pap_cr, sizeof(pap_cr), -1, packet, sizeof(packet)) == 0);
  assert(lcp_parse_peer_auth_for_policy(pap_cr + 2, sizeof(pap_cr) - 2, -1, &peer_auth, NULL) == 0 &&
         peer_auth == PPP_AUTH_PAP);
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
  ppp_transport_t transport = {.send_frame = fake_send, .recv_frame = fake_recv};
  assert(ppp_auth_chap_md5_transport(&transport, "fixture", "fixture") == 0);
  assert(received == 4 && sent == 3);
  assert(response_ids[0] == 7 && response_ids[1] == 8 && response_ids[2] == 8);
  assert(memcmp(response_hashes[0], response_hashes[1], 16) != 0);
  assert(memcmp(response_hashes[1], response_hashes[2], 16) == 0);
  received = sent = 0;
  test_mode = 1;
  assert(ppp_auth_chap_md5_transport(&transport, "fixture", "fixture") == -1);
  assert(failure[0] == 4 && failure[1] == 4);
  received = sent = 0;
  test_mode = 2;
  assert(ppp_auth_pap_transport(&transport, "fixture", "fixture") == -1);
  assert(failure[0] == 5 && failure[1] == 3);
  received = sent = 0;
  test_mode = 3;
  tunnel_set_failure(0, 0, 0);
  assert(ppp_auth_pap_transport(&transport, "fixture", "fixture") == -1);
  assert(received == 12 && failure[0] == 0);

  /* RFC 1994 CHAP-MD5 must support up to 255-byte usernames (matching RFC 1334 PAP). */
  char user255[256];
  memset(user255, 'a', 255);
  user255[255] = '\0';
  received = sent = 0;
  test_mode = 0;
  assert(ppp_auth_chap_md5_transport(&transport, user255, "fixture") == 0);

  /* RFC 2759 MS-CHAPv2 accepts 256 UTF-16LE chars and rejects > 256 UTF-16LE units. */
  char pw256[257];
  memset(pw256, 'p', 256);
  pw256[256] = '\0';
  char pw257[258];
  memset(pw257, 'p', 257);
  pw257[257] = '\0';
  uint8_t chal[16] = {1};
  uint8_t pchal[16] = {2};
  uint8_t val49[49];
  uint8_t hh[16];
  assert(ppp_mschapv2_response_value("user", pw256, chal, pchal, val49) == 0);
  assert(ppp_mschapv2_nt_password_hash_hash(pw256, hh) == 0);
  assert(ppp_mschapv2_response_value("user", pw257, chal, pchal, val49) == -1);
  assert(ppp_mschapv2_nt_password_hash_hash(pw257, hh) == -1);

  /* RFC 2759 UTF-8 to UTF-16LE: U+00E9 ("é") matches MD4(0xe9 0x00), and 129 U+1F600 (258 UTF-16 units) fail. */
  uint8_t hh_utf8[16];
  assert(ppp_mschapv2_nt_password_hash_hash("\xc3\xa9", hh_utf8) == 0);
  const uint8_t eacute_md4_md4[16] = {0x9d, 0x70, 0xf6, 0x6f, 0x42, 0xe8, 0x63, 0x62,
                                      0x7b, 0x82, 0x0c, 0x8f, 0xd8, 0x4d, 0x39, 0xf2};
  /* Compute reference dynamically using mbedtls_md4 on {0xe9, 0x00} instead of magic constant. */
  (void)eacute_md4_md4;
  uint8_t eacute_u16[2] = {0xe9, 0x00};
  uint8_t h1[16], h2[16];
  assert(mbedtls_md4_ret(eacute_u16, sizeof(eacute_u16), h1) == 0);
  assert(mbedtls_md4_ret(h1, sizeof(h1), h2) == 0);
  assert(memcmp(hh_utf8, h2, 16) == 0);

  char pw_emojis[129 * 4 + 1];
  for (int i = 0; i < 129; i++) {
    pw_emojis[i * 4 + 0] = (char)0xf0;
    pw_emojis[i * 4 + 1] = (char)0x9f;
    pw_emojis[i * 4 + 2] = (char)0x98;
    pw_emojis[i * 4 + 3] = (char)0x80;
  }
  pw_emojis[129 * 4] = '\0';
  assert(ppp_mschapv2_nt_password_hash_hash(pw_emojis, hh) == -1);

  /* Policy-aware LCP auth Nak & mismatch detection. */
  const uint8_t peer_pap_cr[] = {0xff, 0x03, 0xc0, 0x21, 1, 1, 0, 8, 3, 4, 0xc0, 0x23};
  assert(lcp_build_nak_for_disallowed_auth(peer_pap_cr, 2, peer_pap_cr + 2, sizeof(peer_pap_cr) - 2,
                                           (int)PPP_AUTH_MSCHAPV2, packet, sizeof(packet)) == 13);
  assert(packet[4] == 3 && packet[8] == 3 && packet[12] == 0x81);
  assert(lcp_build_nak_for_disallowed_auth(peer_pap_cr, 2, peer_pap_cr + 2, sizeof(peer_pap_cr) - 2,
                                           (int)PPP_AUTH_PAP, packet, sizeof(packet)) == 0);

  const uint8_t peer_chap_cr[] = {0xff, 0x03, 0xc0, 0x21, 1, 2, 0, 9, 3, 5, 0xc2, 0x23, 0x05};
  assert(lcp_build_nak_for_disallowed_auth(peer_chap_cr, 2, peer_chap_cr + 2, sizeof(peer_chap_cr) - 2,
                                           (int)PPP_AUTH_PAP, packet, sizeof(packet)) == 12);
  assert(packet[4] == 3 && packet[8] == 3 && packet[10] == 0xc0 && packet[11] == 0x23);

  /* LCP mismatch returns PPP_NEGOTIATE_AUTH_MISMATCH when peer refuses pinned auth. */
  {
    static const uint8_t lcp_term[] = {0xff, 0x03, 0xc0, 0x21, 5, 1, 0, 4};
    audit_ppp_mock_t mock_mismatch = {
        .frames = {peer_pap_cr, lcp_term},
        .lens = {sizeof(peer_pap_cr), sizeof(lcp_term)},
        .count = 2,
    };
    ppp_transport_t t_mm = {
        .ctx = &mock_mismatch,
        .send_frame = audit_ppp_mock_send,
        .recv_frame = audit_ppp_mock_recv,
        .enable_mppe = 1,
        .auth_policy = TUNNEL_PPP_AUTH_CHAP_MD5,
        .mppe_mode = TUNNEL_MPPE_AUTO,
    };
    ppp_session_t sess_mm;
    memset(&sess_mm, 0, sizeof(sess_mm));
    sess_mm.link_mtu = 1450;
    ppp_auth_kind_t out_auth = PPP_AUTH_PAP;
    assert(ppp_lcp_negotiate_transport(&t_mm, &out_auth, &sess_mm) == PPP_NEGOTIATE_AUTH_MISMATCH);
  }

  /* MPPE On fails when peer sends LCP Protocol-Reject for CCP. */
  {
    static const uint8_t ipcp_peer_cr[] = {0xff, 0x03, 0x80, 0x21, 1, 1, 0, 10, 3, 6, 10, 0, 0, 1};
    static const uint8_t ipcp_ack[] = {0xff, 0x03, 0x80, 0x21, 2, 1, 0, 10, 3, 6, 10, 0, 0, 2};
    static const uint8_t ccp_proto_rej[] = {0xff, 0x03, 0xc0, 0x21, 8, 1, 0, 8, 0x80, 0xfd};
    audit_ppp_mock_t mock_on_rej = {
        .frames = {ipcp_peer_cr, ipcp_ack, ccp_proto_rej},
        .lens = {sizeof(ipcp_peer_cr), sizeof(ipcp_ack), sizeof(ccp_proto_rej)},
        .count = 3,
    };
    ppp_transport_t t_on = {
        .ctx = &mock_on_rej,
        .send_frame = audit_ppp_mock_send,
        .recv_frame = audit_ppp_mock_recv,
        .enable_mppe = 1,
        .auth_policy = TUNNEL_PPP_AUTH_AUTO,
        .mppe_mode = TUNNEL_MPPE_ON,
    };
    ppp_session_t sess_on;
    memset(&sess_on, 0, sizeof(sess_on));
    sess_on.mppe_keys_ready = 1;
    assert(ppp_ipcp_negotiate_transport(&t_on, &sess_on) == PPP_NEGOTIATE_MPPE_FAILED);

    /* Same frames with Protocol-Reject before IPCP Ack in MPPE Auto succeed in cleartext. */
    audit_ppp_mock_t mock_auto_rej = {
        .frames = {ipcp_peer_cr, ccp_proto_rej, ipcp_ack},
        .lens = {sizeof(ipcp_peer_cr), sizeof(ccp_proto_rej), sizeof(ipcp_ack)},
        .count = 3,
    };
    t_on.ctx = &mock_auto_rej;
    t_on.mppe_mode = TUNNEL_MPPE_AUTO;
    memset(&sess_on, 0, sizeof(sess_on));
    sess_on.mppe_keys_ready = 1;
    assert(ppp_ipcp_negotiate_transport(&t_on, &sess_on) == 0);
    assert(sess_on.mppe.enabled == 0);
  }

  /* MPPE Off rejects peer MPPE CR and fails with PPP_NEGOTIATE_MPPE_REQUIRED_BY_PEER when peer terminates. */
  {
    static const uint8_t peer_mppe_cr[] = {0xff, 0x03, 0x80, 0xfd, 1, 1, 0, 10, 18, 6, 1, 0, 0, 0x40};
    static const uint8_t lcp_term[] = {0xff, 0x03, 0xc0, 0x21, 5, 1, 0, 4};
    audit_ppp_mock_t mock_off_req = {
        .frames = {peer_mppe_cr, lcp_term},
        .lens = {sizeof(peer_mppe_cr), sizeof(lcp_term)},
        .count = 2,
    };
    ppp_transport_t t_off = {
        .ctx = &mock_off_req,
        .send_frame = audit_ppp_mock_send,
        .recv_frame = audit_ppp_mock_recv,
        .enable_mppe = 1,
        .auth_policy = TUNNEL_PPP_AUTH_AUTO,
        .mppe_mode = TUNNEL_MPPE_OFF,
    };
    ppp_session_t sess_off;
    memset(&sess_off, 0, sizeof(sess_off));
    assert(ppp_ipcp_negotiate_transport(&t_off, &sess_off) == PPP_NEGOTIATE_MPPE_REQUIRED_BY_PEER);

    /* Empty CCP CR in MPPE Off succeeds in cleartext. */
    static const uint8_t empty_ccp_cr[] = {0xff, 0x03, 0x80, 0xfd, 1, 1, 0, 4};
    static const uint8_t ipcp_peer_cr[] = {0xff, 0x03, 0x80, 0x21, 1, 1, 0, 10, 3, 6, 10, 0, 0, 1};
    static const uint8_t ipcp_ack[] = {0xff, 0x03, 0x80, 0x21, 2, 1, 0, 10, 3, 6, 10, 0, 0, 2};
    audit_ppp_mock_t mock_off_ok = {
        .frames = {empty_ccp_cr, ipcp_peer_cr, ipcp_ack},
        .lens = {sizeof(empty_ccp_cr), sizeof(ipcp_peer_cr), sizeof(ipcp_ack)},
        .count = 3,
    };
    t_off.ctx = &mock_off_ok;
    memset(&sess_off, 0, sizeof(sess_off));
    assert(ppp_ipcp_negotiate_transport(&t_off, &sess_off) == 0);
    assert(sess_off.mppe.enabled == 0);
  }
  return 0;
}
