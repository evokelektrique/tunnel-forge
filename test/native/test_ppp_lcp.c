#include "../../android/app/src/main/cpp/ppp_wire.h"
#include "../../android/app/src/main/cpp/util_endian.h"

#include <stdint.h>
#include <stdio.h>

static int lcp_has_option(const uint8_t *ppp, size_t len, uint8_t want_type) {
  size_t p = 0;
  if (len >= 2u && ppp[0] == 0xffu && ppp[1] == 0x03u) p += 2u;
  if (p + 6u > len) return 0;
  if (util_read_be16(ppp + p) != PPP_WIRE_PROTO_LCP) return 0;
  p += 2u;
  uint16_t lcp_len = util_read_be16(ppp + p + 2u);
  if (lcp_len < 4u || p + (size_t)lcp_len > len) return 0;
  size_t i = p + 4u;
  size_t end = p + (size_t)lcp_len;
  while (i + 2u <= end) {
    uint8_t t = ppp[i];
    uint8_t ol = ppp[i + 1u];
    if (ol < 2u || i + (size_t)ol > end) break;
    if (t == want_type) return 1;
    i += (size_t)ol;
  }
  return 0;
}

static int lcp_read_mru(const uint8_t *ppp, size_t len, uint16_t *mru_out) {
  size_t p = 0;
  if (len >= 2u && ppp[0] == 0xffu && ppp[1] == 0x03u) p += 2u;
  if (p + 10u > len) return -1;
  if (util_read_be16(ppp + p) != PPP_WIRE_PROTO_LCP) return -1;
  p += 2u;
  uint16_t lcp_len = util_read_be16(ppp + p + 2u);
  if (lcp_len < 8u || p + (size_t)lcp_len > len) return -1;
  size_t i = p + 4u;
  size_t end = p + (size_t)lcp_len;
  while (i + 4u <= end) {
    uint8_t t = ppp[i];
    uint8_t ol = ppp[i + 1u];
    if (ol < 2u || i + (size_t)ol > end) break;
    if (t == 1u && ol >= 4u) {
      if (mru_out != NULL) *mru_out = util_read_be16(ppp + i + 2u);
      return 0;
    }
    i += (size_t)ol;
  }
  return -1;
}

static int test_selected_mru_is_preserved(void) {
  uint8_t cr[128];
  uint16_t parsed_mru = 0;
  const uint16_t selected_mru = 1450u;

  int n = ppp_lcp_build_cr(cr, sizeof(cr), 1, PPP_AUTH_MSCHAPV2, selected_mru, 1, 1, 1, 1);
  if (n <= 0) return 1;
  if (lcp_read_mru(cr, (size_t)n, &parsed_mru) != 0) return 2;
  if (parsed_mru != selected_mru) return 3;

  n = ppp_lcp_build_cr(cr, sizeof(cr), 2, PPP_AUTH_CHAP_MD5, selected_mru, 1, 1, 0, 1);
  if (n <= 0) return 4;
  if (lcp_read_mru(cr, (size_t)n, &parsed_mru) != 0) return 5;
  if (parsed_mru != selected_mru) return 6;
  return 0;
}

static int test_reject_accm_and_auth_strips_future_cr(void) {
  uint8_t cr[128];
  int include_accm = 1;
  int include_auth = 1;
  int removed_accm = 0;
  int removed_auth = 0;

  int n = ppp_lcp_build_cr(cr, sizeof(cr), 1, PPP_AUTH_MSCHAPV2, 1500, 1, include_accm, include_auth, 1);
  if (n <= 0) return 1;
  if (!lcp_has_option(cr, (size_t)n, 1) || !lcp_has_option(cr, (size_t)n, 2) || !lcp_has_option(cr, (size_t)n, 3)) return 2;

  const uint8_t conf_reject[] = {
      0x04, 0x01, 0x00, 0x0f,
      0x02, 0x06, 0x00, 0x00, 0x00, 0x00,
      0x03, 0x05, 0xc2, 0x23, 0x81,
  };
  ppp_lcp_apply_conf_reject(conf_reject, sizeof(conf_reject), &include_accm, &include_auth, &removed_accm,
                            &removed_auth, NULL);
  if (include_accm != 0 || include_auth != 0 || removed_accm != 1 || removed_auth != 1) return 3;

  n = ppp_lcp_build_cr(cr, sizeof(cr), 2, PPP_AUTH_MSCHAPV2, 1500, 1, include_accm, include_auth, 1);
  if (n <= 0) return 4;
  if (!lcp_has_option(cr, (size_t)n, 1)) return 5;
  if (lcp_has_option(cr, (size_t)n, 2)) return 6;
  if (lcp_has_option(cr, (size_t)n, 3)) return 7;
  return 0;
}

static int test_reject_unrelated_option_keeps_accm_and_auth(void) {
  int include_accm = 1;
  int include_auth = 1;
  int removed_accm = 1;
  int removed_auth = 1;
  const uint8_t conf_reject[] = {
      0x04, 0x05, 0x00, 0x08,
      0x05, 0x04, 0x12, 0x34,
  };
  ppp_lcp_apply_conf_reject(conf_reject, sizeof(conf_reject), &include_accm, &include_auth, &removed_accm,
                            &removed_auth, NULL);
  if (include_accm != 1 || include_auth != 1 || removed_accm != 0 || removed_auth != 0) return 1;
  return 0;
}

static int test_small_caps_reject_truncated_lcp_frames(void) {
  uint8_t cr[64];

  if (ppp_lcp_build_cr(cr, 39u, 1, PPP_AUTH_MSCHAPV2, 1500, 1, 1, 1, 1) != -1) return 1;
  if (ppp_lcp_build_cr(cr, 35u, 1, PPP_AUTH_MSCHAPV2, 1500, 0, 1, 1, 1) != -1) return 2;
  if (ppp_lcp_build_cr(cr, 40u, 1, PPP_AUTH_MSCHAPV2, 1500, 1, 1, 1, 1) <= 0) return 3;
  if (ppp_lcp_build_cr(cr, 36u, 1, PPP_AUTH_MSCHAPV2, 1500, 0, 1, 1, 1) <= 0) return 4;

  return 0;
}

static int test_lcp_mru_and_option_helpers(void) {
  const uint8_t lcp_with_mru_and_auth[] = {
      0x01, 0x01, 0x00, 0x0d,
      0x01, 0x04, 0x05, 0x78, /* MRU 1400 */
      0x03, 0x05, 0xc2, 0x23, 0x81,
  };
  uint16_t mru = 0;
  if (ppp_lcp_parse_mru(lcp_with_mru_and_auth, sizeof(lcp_with_mru_and_auth), &mru) != 0) return 1;
  if (mru != 1400u) return 2;
  if (!ppp_lcp_has_option(lcp_with_mru_and_auth, sizeof(lcp_with_mru_and_auth), 3u)) return 3;
  if (ppp_lcp_has_option(lcp_with_mru_and_auth, sizeof(lcp_with_mru_and_auth), 2u)) return 4;

  const uint8_t lcp_no_mru[] = {0x03, 0x01, 0x00, 0x08, 0x03, 0x04, 0xc0, 0x23};
  if (ppp_lcp_parse_mru(lcp_no_mru, sizeof(lcp_no_mru), &mru) != -1) return 5;
  if (!ppp_lcp_has_option(lcp_no_mru, sizeof(lcp_no_mru), 3u)) return 6;

  const uint8_t lcp_bad_mru_len[] = {0x01, 0x01, 0x00, 0x09, 0x01, 0x05, 0x05, 0x78, 0x00};
  if (ppp_lcp_parse_mru(lcp_bad_mru_len, sizeof(lcp_bad_mru_len), &mru) != -1) return 7;
  return 0;
}

int main(void) {
  int rc = test_selected_mru_is_preserved();
  if (rc != 0) {
    fprintf(stderr, "test_selected_mru_is_preserved failed: %d\n", rc);
    return 1;
  }
  rc = test_reject_accm_and_auth_strips_future_cr();
  if (rc != 0) {
    fprintf(stderr, "test_reject_accm_and_auth_strips_future_cr failed: %d\n", rc);
    return 1;
  }
  rc = test_reject_unrelated_option_keeps_accm_and_auth();
  if (rc != 0) {
    fprintf(stderr, "test_reject_unrelated_option_keeps_accm_and_auth failed: %d\n", rc);
    return 1;
  }
  rc = test_small_caps_reject_truncated_lcp_frames();
  if (rc != 0) {
    fprintf(stderr, "test_small_caps_reject_truncated_lcp_frames failed: %d\n", rc);
    return 1;
  }
  rc = test_lcp_mru_and_option_helpers();
  if (rc != 0) {
    fprintf(stderr, "test_lcp_mru_and_option_helpers failed: %d\n", rc);
    return 1;
  }
  puts("test_ppp_lcp: ok");
  return 0;
}
