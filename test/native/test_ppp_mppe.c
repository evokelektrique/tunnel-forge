#include "../../android/app/src/main/cpp/ppp_mppe.h"
#include "../../android/app/src/main/cpp/ppp_mschap.h"

#include <assert.h>
#include <mbedtls/md4.h>
#include <mbedtls/sha1.h>
#include <stdio.h>
#include <string.h>

static void init_server_peer_state(ppp_mppe_state_t *server, const uint8_t hash_hash[16],
                                   const uint8_t nt_response[24], int stateful) {
  ppp_mppe_zero(server);
  uint8_t master[16];
  assert(ppp_mppe_get_master_key(hash_hash, nt_response, master) == 0);
  /* Server TX == client RX; server RX == client TX. */
  assert(ppp_mppe_get_asymmetric_start_key(master, 1, 1, server->tx_start_key) == 0);
  assert(ppp_mppe_get_asymmetric_start_key(master, 0, 1, server->rx_start_key) == 0);
  assert(ppp_mppe_get_new_key_from_sha(server->tx_start_key, server->tx_start_key, server->tx_session_key) == 0);
  assert(ppp_mppe_get_new_key_from_sha(server->rx_start_key, server->rx_start_key, server->rx_session_key) == 0);
  mbedtls_arc4_init(&server->tx_rc4);
  mbedtls_arc4_init(&server->rx_rc4);
  mbedtls_arc4_setup(&server->tx_rc4, server->tx_session_key, 16u);
  mbedtls_arc4_setup(&server->rx_rc4, server->rx_session_key, 16u);
  server->enabled = 1;
  server->stateful = stateful;
}

static void test_key_derivation_and_symmetry(void) {
  uint8_t hh[16];
  assert(ppp_mschapv2_nt_password_hash_hash("clientPass", hh) == 0);
  /* RFC 2759 section 9.2 known NTPasswordHashHash("clientPass"). */
  const uint8_t expected_hh[16] = {
      0x41u, 0xc0u, 0x0cu, 0x58u, 0x4bu, 0xd2u, 0xd9u, 0x1cu,
      0x40u, 0x17u, 0xa2u, 0xa1u, 0x2fu, 0xa5u, 0x9fu, 0x3fu,
  };
  assert(memcmp(hh, expected_hh, 16u) == 0);

  uint8_t nt_resp[24];
  for (size_t i = 0u; i < sizeof(nt_resp); i++)
    nt_resp[i] = (uint8_t)(0x10u + i);

  uint8_t master[16];
  assert(ppp_mppe_get_master_key(hh, nt_resp, master) == 0);

  uint8_t client_tx[16], client_rx[16], server_tx[16], server_rx[16];
  assert(ppp_mppe_get_asymmetric_start_key(master, 1, 0, client_tx) == 0);
  assert(ppp_mppe_get_asymmetric_start_key(master, 0, 0, client_rx) == 0);
  assert(ppp_mppe_get_asymmetric_start_key(master, 1, 1, server_tx) == 0);
  assert(ppp_mppe_get_asymmetric_start_key(master, 0, 1, server_rx) == 0);
  assert(memcmp(client_tx, server_rx, 16u) == 0);
  assert(memcmp(client_rx, server_tx, 16u) == 0);
  assert(memcmp(client_tx, client_rx, 16u) != 0);
}

static void test_stateless_roundtrip_and_drop_recovery(void) {
  uint8_t hh[16];
  uint8_t nt_resp[24];
  assert(ppp_mschapv2_nt_password_hash_hash("secret123", hh) == 0);
  for (size_t i = 0u; i < sizeof(nt_resp); i++)
    nt_resp[i] = (uint8_t)(i * 7u);

  ppp_mppe_state_t client;
  ppp_mppe_state_t server;
  assert(ppp_mppe_init_client(&client, hh, nt_resp, 0) == 0);
  init_server_peer_state(&server, hh, nt_resp, 0);

  for (int i = 0; i < 300; i++) {
    uint8_t plain[40];
    plain[0] = 0x00u;
    plain[1] = 0x21u;
    for (size_t j = 2u; j < sizeof(plain); j++)
      plain[j] = (uint8_t)((i + (int)j) & 0xff);

    uint8_t enc[64];
    int elen = ppp_mppe_encrypt(&client, plain, sizeof(plain), enc, sizeof(enc));
    assert(elen == (int)(sizeof(plain) + 2u));
    /* Stateless packets always have FLUSHED + ENCRYPTED set. */
    assert((enc[0] & (MPPE_HDR_FLAG_FLUSHED | MPPE_HDR_FLAG_ENCRYPTED)) ==
           (MPPE_HDR_FLAG_FLUSHED | MPPE_HDR_FLAG_ENCRYPTED));

    /* Drop 5 packets in the middle to verify stateless key-roll resync. */
    if (i >= 100 && i < 105)
      continue;

    uint8_t dec[64];
    size_t dlen = 0u;
    int drc = ppp_mppe_decrypt(&server, enc, (size_t)elen, dec, sizeof(dec), &dlen);
    assert(drc == PPP_MPPE_DECRYPT_OK);
    assert(dlen == sizeof(plain));
    assert(memcmp(dec, plain, sizeof(plain)) == 0);
  }

  ppp_mppe_zero(&client);
  ppp_mppe_zero(&server);
}

static void test_stateful_rekey_and_reset_recovery(void) {
  uint8_t hh[16];
  uint8_t nt_resp[24];
  assert(ppp_mschapv2_nt_password_hash_hash("statefulPass", hh) == 0);
  memset(nt_resp, 0x5au, sizeof(nt_resp));

  ppp_mppe_state_t client;
  ppp_mppe_state_t server;
  assert(ppp_mppe_init_client(&client, hh, nt_resp, 1) == 0);
  init_server_peer_state(&server, hh, nt_resp, 1);

  /* Exercise across multiple 256-packet FLUSHED rekey boundaries (0x0FF, 0x1FF). */
  for (int i = 0; i < 600; i++) {
    uint8_t plain[24];
    plain[0] = 0x00u;
    plain[1] = 0x21u;
    for (size_t j = 2u; j < sizeof(plain); j++)
      plain[j] = (uint8_t)((i * 3 + (int)j) & 0xff);

    uint8_t enc[64];
    int elen = ppp_mppe_encrypt(&client, plain, sizeof(plain), enc, sizeof(enc));
    assert(elen == (int)(sizeof(plain) + 2u));

    /* Simulate one lost packet at i == 300; next packet must trigger NEED_RESET. */
    if (i == 300)
      continue;

    uint8_t dec[64];
    size_t dlen = 0u;
    int drc = ppp_mppe_decrypt(&server, enc, (size_t)elen, dec, sizeof(dec), &dlen);
    if (i == 301) {
      assert(drc == PPP_MPPE_DECRYPT_NEED_RESET);
      /* Peer sends CCP Reset-Request; sender marks TX reset for next packet. */
      ppp_mppe_note_tx_reset(&client);
      continue;
    }
    assert(drc == PPP_MPPE_DECRYPT_OK);
    assert(dlen == sizeof(plain));
    assert(memcmp(dec, plain, sizeof(plain)) == 0);
  }

  /* Malformed short/unencrypted frame must fail. */
  uint8_t bad[4] = {0x00u, 0x00u, 0x01u, 0x02u};
  uint8_t dec[16];
  size_t dlen = 0u;
  assert(ppp_mppe_decrypt(&server, bad, 2u, dec, sizeof(dec), &dlen) == PPP_MPPE_DECRYPT_ERR);
  assert(ppp_mppe_decrypt(&server, bad, sizeof(bad), dec, sizeof(dec), &dlen) == PPP_MPPE_DECRYPT_ERR);

  ppp_mppe_zero(&client);
  ppp_mppe_zero(&server);
}

static void test_mschapv2_parse_failure(void) {
  const uint8_t failure[] = "E=691 R=1 C=0123456789ABCDEF0123456789ABCDEF V=3 M=Authentication failed";
  ppp_mschapv2_failure_info_t info;
  assert(ppp_mschapv2_parse_failure(failure, sizeof(failure) - 1u, &info) == 0);
  assert(info.has_error_code && info.error_code == 691);
  assert(info.has_retry && info.retry == 1);
  assert(info.has_version && info.version == 3);
  assert(info.has_message && strcmp(info.message, "Authentication failed") == 0);

  const uint8_t partial[] = "E=648 R=0";
  assert(ppp_mschapv2_parse_failure(partial, sizeof(partial) - 1u, &info) == 0);
  assert(info.has_error_code && info.error_code == 648);
  assert(info.has_retry && info.retry == 0);
  assert(!info.has_version && !info.has_message);

  const uint8_t invalid[] = "not an mschap failure";
  assert(ppp_mschapv2_parse_failure(invalid, sizeof(invalid) - 1u, &info) != 0);
}

/*
 * Verify stateless packet 0 uses a 1x-rekeyed session key (RFC 3078 / Linux
 * ppp_mppe.ko behaviour).  Before the fix, encrypt/decrypt rekeyed AFTER
 * arc4_crypt, leaving TunnelForge one rekey behind Linux on every packet.
 */
static void test_stateless_packet0_rekey(void) {
  uint8_t hh[16];
  uint8_t nt_resp[24];
  assert(ppp_mschapv2_nt_password_hash_hash("pkt0test", hh) == 0);
  memset(nt_resp, 0xabu, sizeof(nt_resp));

  ppp_mppe_state_t client;
  ppp_mppe_state_t server;
  assert(ppp_mppe_init_client(&client, hh, nt_resp, 0) == 0);
  init_server_peer_state(&server, hh, nt_resp, 0);

  /* Packet 0: encrypt with client, decrypt with server. */
  uint8_t plain[6] = {0x00u, 0x21u, 0xCAu, 0xFEu, 0xBAu, 0xBEu};
  uint8_t enc[16];
  int elen = ppp_mppe_encrypt(&client, plain, sizeof(plain), enc, sizeof(enc));
  assert(elen == (int)(sizeof(plain) + 2u));

  /* Header must have ENCRYPTED|FLUSHED set and ccount == 0. */
  uint16_t hdr = (uint16_t)((enc[0] << 8) | enc[1]);
  assert((hdr & 0x9000u) == 0x9000u);     /* E=1 F=1 */
  assert((hdr & 0x0FFFu) == 0x0000u);     /* ccount 0 */

  /* Ciphertext must NOT equal plaintext (rekey happened before encrypt). */
  assert(memcmp(enc + 2u, plain, sizeof(plain)) != 0);

  uint8_t dec[16];
  size_t dlen = 0u;
  int drc = ppp_mppe_decrypt(&server, enc, (size_t)elen, dec, sizeof(dec), &dlen);
  assert(drc == PPP_MPPE_DECRYPT_OK);
  assert(dlen == sizeof(plain));
  assert(memcmp(dec, plain, sizeof(plain)) == 0);

  /* Manually verify: initial session_key rekeyed once (non-initial) must
   * equal what ppp_mppe_encrypt used.  Derive from scratch. */
  uint8_t master[16];
  assert(ppp_mppe_get_master_key(hh, nt_resp, master) == 0);
  uint8_t send_start[16], initial_sess[16], interim[16], rekeyed_sess[16];
  assert(ppp_mppe_get_asymmetric_start_key(master, 1, 0, send_start) == 0);
  assert(ppp_mppe_get_new_key_from_sha(send_start, send_start, initial_sess) == 0);
  /* Non-initial rekey: SHA then RC4-encrypt interim into session_key. */
  assert(ppp_mppe_get_new_key_from_sha(send_start, initial_sess, interim) == 0);
  mbedtls_arc4_context rekey_rc4;
  mbedtls_arc4_init(&rekey_rc4);
  mbedtls_arc4_setup(&rekey_rc4, interim, 16u);
  assert(mbedtls_arc4_crypt(&rekey_rc4, 16u, interim, rekeyed_sess) == 0);
  mbedtls_arc4_free(&rekey_rc4);

  /* Encrypt plaintext with the 1x-rekeyed key; must match what encrypt produced. */
  mbedtls_arc4_context verify_rc4;
  mbedtls_arc4_init(&verify_rc4);
  mbedtls_arc4_setup(&verify_rc4, rekeyed_sess, 16u);
  uint8_t verify_ct[6];
  assert(mbedtls_arc4_crypt(&verify_rc4, sizeof(plain), plain, verify_ct) == 0);
  assert(memcmp(enc + 2u, verify_ct, sizeof(plain)) == 0);
  mbedtls_arc4_free(&verify_rc4);

  ppp_mppe_zero(&client);
  ppp_mppe_zero(&server);
}

int main(void) {
  test_mschapv2_parse_failure();
  test_key_derivation_and_symmetry();
  test_stateless_roundtrip_and_drop_recovery();
  test_stateful_rekey_and_reset_recovery();
  test_stateless_packet0_rekey();
  puts("test_ppp_mppe: ok");
  return 0;
}
