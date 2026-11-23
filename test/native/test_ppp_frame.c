#include "../../android/app/src/main/cpp/ppp_wire.h"
#include "../../android/app/src/main/cpp/util_endian.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void build_ipv4_tcp_syn_with_mss(uint8_t *pkt, uint16_t mss, uint8_t flags, uint16_t checksum) {
  memset(pkt, 0, 44u);
  pkt[0] = 0x45u;
  util_write_be16(pkt + 2u, 44u);
  pkt[8] = 64u;
  pkt[9] = 6u;
  pkt[12] = 10u;
  pkt[15] = 2u;
  pkt[16] = 10u;
  pkt[19] = 1u;
  util_write_be16(pkt + 20u, 12345u);
  util_write_be16(pkt + 22u, 443u);
  pkt[32] = 0x60u;
  pkt[33] = flags;
  util_write_be16(pkt + 34u, 65535u);
  util_write_be16(pkt + 36u, checksum);
  pkt[40] = 2u;
  pkt[41] = 4u;
  util_write_be16(pkt + 42u, mss);
}

static int test_acfc_off_has_ff03_0021(void) {
  uint8_t ip[4] = {0x45, 0x00, 0x00, 0x14};
  uint8_t frame[32];
  int n = ppp_build_ip_frame(frame, sizeof(frame), ip, sizeof(ip), 0, 0);
  if (n != 8) return 1;
  if (frame[0] != 0xff || frame[1] != 0x03 || frame[2] != 0x00 || frame[3] != 0x21) return 2;
  if (memcmp(frame + 4, ip, 4) != 0) return 3;
  if (ppp_ip_frame_len(sizeof(ip), 0, 0) != 8u) return 4;
  return 0;
}

static int test_acfc_on_is_0021_only(void) {
  uint8_t ip[2] = {0x45, 0x00};
  uint8_t frame[16];
  int n = ppp_build_ip_frame(frame, sizeof(frame), ip, sizeof(ip), 1, 0);
  if (n != 4) return 1;
  if (frame[0] != 0x00 || frame[1] != 0x21) return 2;
  if (memcmp(frame + 2, ip, 2) != 0) return 3;
  if (ppp_ip_frame_len(sizeof(ip), 1, 0) != 4u) return 4;
  return 0;
}

static int test_pfc_without_acfc_keeps_ff03_and_compresses_protocol(void) {
  uint8_t ip[3] = {0x45, 0x00, 0x00};
  uint8_t frame[16];
  int n = ppp_build_ip_frame(frame, sizeof(frame), ip, sizeof(ip), 0, 1);
  if (n != 6) return 1;
  if (frame[0] != 0xff || frame[1] != 0x03 || frame[2] != 0x21) return 2;
  if (memcmp(frame + 3, ip, 3) != 0) return 3;
  if (ppp_ip_frame_len(sizeof(ip), 0, 1) != 6u) return 4;
  return 0;
}

static int test_pfc_with_acfc_is_single_protocol_octet(void) {
  uint8_t ip[2] = {0x45, 0x00};
  uint8_t frame[16];
  int n = ppp_build_ip_frame(frame, sizeof(frame), ip, sizeof(ip), 1, 1);
  if (n != 3) return 1;
  if (frame[0] != 0x21) return 2;
  if (memcmp(frame + 1, ip, 2) != 0) return 3;
  if (ppp_ip_frame_len(sizeof(ip), 1, 1) != 3u) return 4;
  return 0;
}

static int test_tcp_syn_mss_clamp_updates_option_and_checksum(void) {
  uint8_t pkt[44];
  build_ipv4_tcp_syn_with_mss(pkt, 1460u, 0x02u, 0x1234u);
  uint16_t old_mss = 0u;
  uint16_t new_mss = 0u;
  if (ppp_clamp_tcp_syn_mss(pkt, sizeof(pkt), 1410u, &old_mss, &new_mss) != 1) return 1;
  if (old_mss != 1460u || new_mss != 1410u) return 2;
  if (util_read_be16(pkt + 42u) != 1410u) return 3;
  if (util_read_be16(pkt + 36u) != 0u) return 4;
  (void)ppp_fix_tun_ipv4_checksums(pkt, sizeof(pkt), NULL);
  if (util_read_be16(pkt + 36u) == 0u) return 5;
  return 0;
}

static int test_tcp_syn_small_mss_is_unchanged(void) {
  uint8_t pkt[44];
  build_ipv4_tcp_syn_with_mss(pkt, 1380u, 0x02u, 0x2222u);
  if (ppp_clamp_tcp_syn_mss(pkt, sizeof(pkt), 1410u, NULL, NULL) != 0) return 1;
  if (util_read_be16(pkt + 42u) != 1380u) return 2;
  if (util_read_be16(pkt + 36u) != 0x2222u) return 3;
  return 0;
}

static int test_non_syn_packet_is_unchanged(void) {
  uint8_t pkt[44];
  build_ipv4_tcp_syn_with_mss(pkt, 1460u, 0x10u, 0x3333u);
  if (ppp_clamp_tcp_syn_mss(pkt, sizeof(pkt), 1410u, NULL, NULL) != 0) return 1;
  if (util_read_be16(pkt + 42u) != 1460u) return 2;
  if (util_read_be16(pkt + 36u) != 0x3333u) return 3;
  return 0;
}

static int test_lcp_echo_reply_zeroes_magic_and_keeps_data(void) {
  const uint8_t req_lcp[] = {
      0x09, 0x42, 0x00, 0x0b,
      0x12, 0x34, 0x56, 0x78,
      0xaa, 0xbb, 0xcc,
  };
  uint8_t reply[32];
  int n = ppp_build_lcp_echo_reply_frame(reply, sizeof(reply), req_lcp, sizeof(req_lcp), 0, 0);
  if (n != 15) return 1;
  if (reply[0] != 0xffu || reply[1] != 0x03u) return 2;
  if (util_read_be16(reply + 2u) != PPP_WIRE_PROTO_LCP) return 3;
  if (reply[4] != 10u || reply[5] != 0x42u) return 4;
  if (util_read_be16(reply + 6u) != sizeof(req_lcp)) return 5;
  if (util_read_be32(reply + 8u) != 0u) return 6;
  if (memcmp(reply + 12u, req_lcp + 8u, 3u) != 0) return 7;
  return 0;
}

static int test_lcp_echo_reply_honors_acfc(void) {
  const uint8_t req_lcp[] = {
      0x09, 0x07, 0x00, 0x08,
      0xde, 0xad, 0xbe, 0xef,
  };
  uint8_t reply[32];
  int n = ppp_build_lcp_echo_reply_frame(reply, sizeof(reply), req_lcp, sizeof(req_lcp), 1, 0);
  if (n != 10) return 1;
  if (util_read_be16(reply + 0u) != PPP_WIRE_PROTO_LCP) return 2;
  if (reply[2] != 10u || reply[3] != 0x07u) return 3;
  if (util_read_be16(reply + 4u) != sizeof(req_lcp)) return 4;
  if (util_read_be32(reply + 6u) != 0u) return 5;
  return 0;
}

int main(void) {
  int rc = test_acfc_off_has_ff03_0021();
  if (rc != 0) {
    fprintf(stderr, "test_acfc_off_has_ff03_0021 failed: %d\n", rc);
    return 1;
  }
  rc = test_acfc_on_is_0021_only();
  if (rc != 0) {
    fprintf(stderr, "test_acfc_on_is_0021_only failed: %d\n", rc);
    return 1;
  }
  rc = test_pfc_without_acfc_keeps_ff03_and_compresses_protocol();
  if (rc != 0) {
    fprintf(stderr, "test_pfc_without_acfc_keeps_ff03_and_compresses_protocol failed: %d\n", rc);
    return 1;
  }
  rc = test_pfc_with_acfc_is_single_protocol_octet();
  if (rc != 0) {
    fprintf(stderr, "test_pfc_with_acfc_is_single_protocol_octet failed: %d\n", rc);
    return 1;
  }
  rc = test_tcp_syn_mss_clamp_updates_option_and_checksum();
  if (rc != 0) {
    fprintf(stderr, "test_tcp_syn_mss_clamp_updates_option_and_checksum failed: %d\n", rc);
    return 1;
  }
  rc = test_tcp_syn_small_mss_is_unchanged();
  if (rc != 0) {
    fprintf(stderr, "test_tcp_syn_small_mss_is_unchanged failed: %d\n", rc);
    return 1;
  }
  rc = test_non_syn_packet_is_unchanged();
  if (rc != 0) {
    fprintf(stderr, "test_non_syn_packet_is_unchanged failed: %d\n", rc);
    return 1;
  }
  rc = test_lcp_echo_reply_zeroes_magic_and_keeps_data();
  if (rc != 0) {
    fprintf(stderr, "test_lcp_echo_reply_zeroes_magic_and_keeps_data failed: %d\n", rc);
    return 1;
  }
  rc = test_lcp_echo_reply_honors_acfc();
  if (rc != 0) {
    fprintf(stderr, "test_lcp_echo_reply_honors_acfc failed: %d\n", rc);
    return 1;
  }
  puts("test_ppp_frame: ok");
  return 0;
}
