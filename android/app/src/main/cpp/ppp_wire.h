#ifndef TUNNEL_FORGE_PPP_WIRE_H
#define TUNNEL_FORGE_PPP_WIRE_H

#include <stddef.h>
#include <stdint.h>

#define PPP_WIRE_PROTO_IP 0x0021u
#define PPP_WIRE_PROTO_LCP 0xc021u
#define PPP_WIRE_PROTO_PAP 0xc023u
#define PPP_WIRE_PROTO_CHAP 0xc223u
#define PPP_WIRE_PROTO_IPCP 0x8021u

#define PPP_LCP_CODE_ECHO_REQUEST 9u
#define PPP_LCP_CODE_ECHO_REPLY 10u

#define IPCP_OPT_IP_ADDRESS 3u
#define IPCP_OPT_PRIMARY_DNS 129u
#define IPCP_OPT_SECONDARY_DNS 131u

typedef enum {
  PPP_AUTH_PAP = 0,
  PPP_AUTH_MSCHAPV2,
  PPP_AUTH_CHAP_MD5,
} ppp_auth_kind_t;

int ppp_lcp_build_cr(uint8_t *out, size_t cap, uint8_t id, ppp_auth_kind_t auth, uint16_t mru,
                     int include_address_control, int include_accm, int include_auth, int include_mru);

void ppp_lcp_apply_conf_reject(const uint8_t *lcp, size_t lcp_len, int *include_accm, int *include_auth,
                               int *removed_accm, int *removed_auth, int *include_mru);

int ppp_ipcp_opts_first_ipv4_option(const uint8_t *ipcp, uint16_t ipcplen, uint8_t option_type, uint8_t ip_out[4]);

int ppp_ipcp_build_cr(uint8_t *out, size_t cap, uint8_t id, const uint8_t ip[4], int include_address_control,
                      int include_ip_opt, const uint8_t primary_dns[4], int include_primary_dns_opt,
                      const uint8_t secondary_dns[4], int include_secondary_dns_opt);

size_t ppp_write_frame_prefix(uint8_t *buf, size_t cap, uint16_t proto, int lcp_acfc, int lcp_pfc);

size_t ppp_ip_frame_len(size_t ip_len, int lcp_acfc, int lcp_pfc);

int ppp_build_ip_frame(uint8_t *out, size_t cap, const uint8_t *ip, size_t ip_len, int lcp_acfc, int lcp_pfc);

int ppp_build_lcp_echo_reply_frame(uint8_t *out, size_t cap, const uint8_t *req_lcp, size_t req_len, int lcp_acfc,
                                   int lcp_pfc);

int ppp_clamp_tcp_syn_mss(uint8_t *pkt, size_t len, uint16_t clamp_mss, uint16_t *old_mss_out, uint16_t *new_mss_out);

int ppp_fix_tun_ipv4_checksums(uint8_t *pkt, size_t len, uint8_t *fixed_proto_out);

#endif
