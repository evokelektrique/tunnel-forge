#include "../../android/app/src/main/cpp/pptp_gre.h"
#include "../../android/app/src/main/cpp/util_endian.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void test_build_and_extract_roundtrip(void) {
  pptp_gre_state_t client;
  pptp_gre_state_t server;
  pptp_gre_init(&client, 0x1234u, 0x5678u);
  pptp_gre_init(&server, 0x5678u, 0x1234u);

  const uint8_t ppp_in[] = {0xffu, 0x03u, 0xc0u, 0x21u, 0x01u, 0x01u, 0x00u, 0x04u};
  uint8_t gre[64];
  int glen = pptp_gre_build_data(&client, ppp_in, sizeof(ppp_in), gre, sizeof(gre));
  assert(glen == 12 + (int)sizeof(ppp_in));
  assert(gre[0] == 0x30u); /* K=1, S=1 */
  assert(gre[1] == 0x01u); /* A=0, version=1 */
  assert(util_read_be16(gre + 2u) == PPTP_GRE_PROTO_PPP);
  assert(util_read_be16(gre + 4u) == sizeof(ppp_in));
  assert(util_read_be16(gre + 6u) == 0x5678u);
  assert(util_read_be32(gre + 8u) == 0u);

  const uint8_t *ppp_out = NULL;
  size_t ppp_len = 0u;
  int rc = pptp_gre_extract_ppp(&server, gre, (size_t)glen, &ppp_out, &ppp_len);
  assert(rc == 1);
  assert(ppp_len == sizeof(ppp_in));
  assert(memcmp(ppp_out, ppp_in, sizeof(ppp_in)) == 0);
  assert(server.have_rx_seq == 1);
  assert(server.rx_seq == 0u);
  assert(server.ack_pending == 1);

  /* Duplicate sequence number is ignored (returns 0, not error). */
  rc = pptp_gre_extract_ppp(&server, gre, (size_t)glen, &ppp_out, &ppp_len);
  assert(rc == 0);

  /* Server piggybacks ACK=0 on its reply data frame. */
  const uint8_t reply_ppp[] = {0x00u, 0x21u, 0x45u, 0x00u};
  glen = pptp_gre_build_data(&server, reply_ppp, sizeof(reply_ppp), gre, sizeof(gre));
  assert(glen == 16 + (int)sizeof(reply_ppp));
  assert(gre[0] == 0x30u);
  assert(gre[1] == 0x81u); /* A=1, version=1 */
  assert(util_read_be16(gre + 6u) == 0x1234u);
  assert(util_read_be32(gre + 8u) == 0u);
  assert(util_read_be32(gre + 12u) == 0u);
  assert(server.ack_pending == 0);

  rc = pptp_gre_extract_ppp(&client, gre, (size_t)glen, &ppp_out, &ppp_len);
  assert(rc == 1);
  assert(ppp_len == sizeof(reply_ppp));
  assert(memcmp(ppp_out, reply_ppp, sizeof(reply_ppp)) == 0);
  assert(client.ack_pending == 1);

  /* Client flushes standalone ACK (12 bytes, S=0, A=1, payload_len=0). */
  int alen = pptp_gre_build_ack(&client, gre, sizeof(gre));
  assert(alen == 12);
  assert(gre[0] == 0x20u); /* K=1, S=0 */
  assert(gre[1] == 0x81u); /* A=1, version=1 */
  assert(util_read_be16(gre + 4u) == 0u);
  assert(util_read_be16(gre + 6u) == 0x5678u);
  assert(util_read_be32(gre + 8u) == 0u);
  assert(client.ack_pending == 0);
  assert(pptp_gre_build_ack(&client, gre, sizeof(gre)) == 0);

  /* Server accepts standalone ACK as valid non-payload control frame (returns 0). */
  rc = pptp_gre_extract_ppp(&server, gre, (size_t)alen, &ppp_out, &ppp_len);
  assert(rc == 0);
}

static void test_sequence_wrap_and_validation(void) {
  pptp_gre_state_t tx;
  pptp_gre_state_t rx;
  pptp_gre_init(&tx, 10u, 20u);
  pptp_gre_init(&rx, 20u, 10u);
  tx.tx_seq = 0xfffffffeu;

  const uint8_t payload[] = {0x00u, 0x21u, 0xaa};
  uint8_t gre[64];
  const uint8_t *out = NULL;
  size_t out_len = 0u;

  /* 0xfffffffe -> 0xffffffff -> 0x00000000 -> 0x00000001 must all be accepted in order. */
  for (int i = 0; i < 4; i++) {
    int glen = pptp_gre_build_data(&tx, payload, sizeof(payload), gre, sizeof(gre));
    assert(glen > 0);
    int rc = pptp_gre_extract_ppp(&rx, gre, (size_t)glen, &out, &out_len);
    assert(rc == 1 && out_len == sizeof(payload));
  }
  assert(rx.rx_seq == 1u);

  /* Wrong call ID is rejected. */
  int glen = pptp_gre_build_data(&tx, payload, sizeof(payload), gre, sizeof(gre));
  assert(glen > 0);
  util_write_be16(gre + 6u, 99u);
  assert(pptp_gre_extract_ppp(&rx, gre, (size_t)glen, &out, &out_len) == -1);

  /* Wrong GRE version is rejected. */
  util_write_be16(gre + 6u, 20u);
  gre[1] = 0x00u;
  assert(pptp_gre_extract_ppp(&rx, gre, (size_t)glen, &out, &out_len) == -1);

  /* Truncated payload is rejected. */
  gre[1] = 0x01u;
  assert(pptp_gre_extract_ppp(&rx, gre, (size_t)glen - 1u, &out, &out_len) == -1);
}

int main(void) {
  test_build_and_extract_roundtrip();
  test_sequence_wrap_and_validation();
  puts("test_pptp_gre: ok");
  return 0;
}
