#include "../../android/app/src/main/cpp/ppp_wire.h"
#include "../../android/app/src/main/cpp/util_endian.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int test_cr_contains_ip3(void) {
  uint8_t buf[32];
  uint8_t ip[4] = {192, 168, 1, 10};
  uint8_t primary_dns[4] = {1, 1, 1, 1};
  uint8_t secondary_dns[4] = {8, 8, 8, 8};
  int n = ppp_ipcp_build_cr(buf, sizeof(buf), 1, ip, 1, 1, primary_dns, 1, secondary_dns, 1);
  if (n < 14) return 1;
  if (buf[0] != 0xff || buf[1] != 0x03) return 2;
  if (util_read_be16(buf + 2) != PPP_WIRE_PROTO_IPCP) return 3;
  if (buf[4] != 1 || buf[5] != 1) return 4;
  uint16_t l = util_read_be16(buf + 6);
  if (l != (uint16_t)(n - 4)) return 5;
  if (buf[8] != IPCP_OPT_IP_ADDRESS || buf[9] != 6) return 6;
  if (memcmp(buf + 10, ip, 4) != 0) return 7;
  if (buf[14] != IPCP_OPT_PRIMARY_DNS || buf[15] != 6) return 8;
  if (memcmp(buf + 16, primary_dns, 4) != 0) return 9;
  if (buf[20] != IPCP_OPT_SECONDARY_DNS || buf[21] != 6) return 10;
  if (memcmp(buf + 22, secondary_dns, 4) != 0) return 11;
  return 0;
}

static int test_small_cap_rejects_ip_option(void) {
  uint8_t buf[32];
  uint8_t ip[4] = {10, 20, 30, 40};
  uint8_t dns[4] = {1, 1, 1, 1};

  if (ppp_ipcp_build_cr(buf, 25u, 1, ip, 1, 1, dns, 1, dns, 1) != -1) return 1;
  if (ppp_ipcp_build_cr(buf, 23u, 1, ip, 0, 1, dns, 1, dns, 1) != -1) return 2;
  if (ppp_ipcp_build_cr(buf, 7u, 1, ip, 1, 0, dns, 0, dns, 0) != -1) return 3;
  if (ppp_ipcp_build_cr(buf, 5u, 1, ip, 0, 0, dns, 0, dns, 0) != -1) return 4;
  if (ppp_ipcp_build_cr(buf, 26u, 1, ip, 1, 1, dns, 1, dns, 1) <= 0) return 5;
  if (ppp_ipcp_build_cr(buf, 24u, 1, ip, 0, 1, dns, 1, dns, 1) <= 0) return 6;

  return 0;
}

static int test_nak_updates_req_ip(void) {
  const uint8_t nak[] = {
      0x03, 0x01, 0x00, 0x0a, 0x03, 0x06, 10, 20, 30, 40,
  };
  uint8_t req[4] = {0, 0, 0, 0};
  if (ppp_ipcp_opts_first_ipv4_option(nak, sizeof(nak), IPCP_OPT_IP_ADDRESS, req) != 0) return 1;
  if (req[0] != 10 || req[1] != 20 || req[2] != 30 || req[3] != 40) return 2;
  return 0;
}

static int test_nak_updates_dns(void) {
  const uint8_t nak[] = {
      0x03, 0x01, 0x00, 0x10, IPCP_OPT_PRIMARY_DNS, 0x06, 1, 1, 1, 1, IPCP_OPT_SECONDARY_DNS, 0x06, 8, 8, 8, 8,
  };
  uint8_t primary_dns[4] = {0, 0, 0, 0};
  uint8_t secondary_dns[4] = {0, 0, 0, 0};
  if (ppp_ipcp_opts_first_ipv4_option(nak, sizeof(nak), IPCP_OPT_PRIMARY_DNS, primary_dns) != 0) return 1;
  if (ppp_ipcp_opts_first_ipv4_option(nak, sizeof(nak), IPCP_OPT_SECONDARY_DNS, secondary_dns) != 0) return 2;
  if (memcmp(primary_dns, (const uint8_t[]){1, 1, 1, 1}, 4) != 0) return 3;
  if (memcmp(secondary_dns, (const uint8_t[]){8, 8, 8, 8}, 4) != 0) return 4;
  return 0;
}

int main(void) {
  int rc = test_cr_contains_ip3();
  if (rc != 0) {
    fprintf(stderr, "test_cr_contains_ip3 failed: %d\n", rc);
    return 1;
  }
  rc = test_small_cap_rejects_ip_option();
  if (rc != 0) {
    fprintf(stderr, "test_small_cap_rejects_ip_option failed: %d\n", rc);
    return 1;
  }
  rc = test_nak_updates_req_ip();
  if (rc != 0) {
    fprintf(stderr, "test_nak_updates_req_ip failed: %d\n", rc);
    return 1;
  }
  rc = test_nak_updates_dns();
  if (rc != 0) {
    fprintf(stderr, "test_nak_updates_dns failed: %d\n", rc);
    return 1;
  }
  puts("test_ppp_ipcp: ok");
  return 0;
}
