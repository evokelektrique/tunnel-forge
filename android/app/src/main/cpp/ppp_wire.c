/*
 * Pure C99 PPP framing, LCP/IPCP option builders, TCP MSS clamping, and IPv4/L4 checksum fixups.
 */
#include "ppp_wire.h"

#include "ipv4_dataplane.h"
#include "util_endian.h"

#include <string.h>

int ppp_lcp_build_cr(uint8_t *out, size_t cap, uint8_t id, ppp_auth_kind_t auth, uint16_t mru,
                     int include_address_control, int include_accm, int include_auth, int include_mru) {
  size_t o = 0;
  if (include_address_control) {
    if (cap < 40)
      return -1;
    out[o++] = 0xff;
    out[o++] = 0x03;
    util_write_be16(out + o, PPP_WIRE_PROTO_LCP);
    o += 2;
  } else {
    /* Peer LCP over L2TP often omits Address/Control (ACFC). */
    if (cap < 36)
      return -1;
    util_write_be16(out + o, PPP_WIRE_PROTO_LCP);
    o += 2;
  }
  size_t code_off = o;
  out[o++] = 1;
  out[o++] = id;
  size_t len_mark = o;
  o += 2;
  if (include_mru) {
    out[o++] = 1;
    out[o++] = 4;
    util_write_be16(out + o, mru);
    o += 2;
  }
  if (include_accm) {
    /* ACCM 00 00 00 00: keep this unless peer explicitly Configure-Rejects it. */
    out[o++] = 2;
    out[o++] = 6;
    util_write_be32(out + o, 0u);
    o += 4u;
  }
  if (include_auth) {
    out[o++] = 3;
    if (auth == PPP_AUTH_PAP) {
      out[o++] = 4;
      util_write_be16(out + o, PPP_WIRE_PROTO_PAP);
      o += 2;
    } else if (auth == PPP_AUTH_MSCHAPV2) {
      out[o++] = 5;
      out[o++] = 0xc2;
      out[o++] = 0x23;
      out[o++] = 0x81;
    } else {
      /* RFC 1994 CHAP: Authentication-Protocol 0xc223 + algorithm 0x05 (MD5-Challenge). */
      out[o++] = 5;
      out[o++] = 0xc2;
      out[o++] = 0x23;
      out[o++] = 0x05;
    }
  }
  util_write_be16(out + len_mark, (uint16_t)(o - code_off));
  return (int)o;
}

void ppp_lcp_apply_conf_reject(const uint8_t *lcp, size_t lcp_len, int *include_accm, int *include_auth,
                               int *removed_accm, int *removed_auth, int *include_mru) {
  if (removed_accm != NULL)
    *removed_accm = 0;
  if (removed_auth != NULL)
    *removed_auth = 0;
  if (lcp_len < 6u)
    return;
  const uint8_t *opt = lcp + 4u;
  size_t rem = lcp_len - 4u;
  size_t i = 0;
  while (i + 2u <= rem) {
    uint8_t t = opt[i];
    uint8_t ol = opt[i + 1u];
    if (ol < 2u || i + (size_t)ol > rem)
      break;
    if (t == 1u && include_mru != NULL)
      *include_mru = 0;
    if (t == 2u && include_accm != NULL && *include_accm) {
      *include_accm = 0;
      if (removed_accm != NULL)
        *removed_accm = 1;
    } else if (t == 3u && include_auth != NULL && *include_auth) {
      *include_auth = 0;
      if (removed_auth != NULL)
        *removed_auth = 1;
    }
    i += (size_t)ol;
  }
}

int ppp_ipcp_opts_first_ipv4_option(const uint8_t *ipcp, uint16_t ipcplen, uint8_t option_type, uint8_t ip_out[4]) {
  if (ipcplen < 4u)
    return -1;
  const uint8_t *opts = ipcp + 4u;
  size_t rem = (size_t)ipcplen - 4u;
  size_t i = 0;
  while (i + 2u <= rem) {
    uint8_t t = opts[i];
    uint8_t ol = opts[i + 1u];
    if (ol < 2u || i + (size_t)ol > rem)
      break;
    if (t == option_type && ol >= 6u) {
      memcpy(ip_out, opts + i + 2u, 4);
      return 0;
    }
    i += (size_t)ol;
  }
  return -1;
}

int ppp_ipcp_build_cr(uint8_t *out, size_t cap, uint8_t id, const uint8_t ip[4], int include_address_control,
                      int include_ip_opt, const uint8_t primary_dns[4], int include_primary_dns_opt,
                      const uint8_t secondary_dns[4], int include_secondary_dns_opt) {
  size_t o = 0;
  if (include_address_control) {
    if (cap < 8u)
      return -1;
    out[o++] = 0xff;
    out[o++] = 0x03;
    util_write_be16(out + o, PPP_WIRE_PROTO_IPCP);
    o += 2u;
  } else {
    if (cap < 6u)
      return -1;
    util_write_be16(out + o, PPP_WIRE_PROTO_IPCP);
    o += 2u;
  }
  size_t code_off = o;
  out[o++] = 1;
  out[o++] = id;
  size_t len_mark = o;
  o += 2u;
  if (include_ip_opt) {
    if (o + 6u > cap)
      return -1;
    out[o++] = IPCP_OPT_IP_ADDRESS;
    out[o++] = 6;
    memcpy(out + o, ip, 4);
    o += 4u;
  }
  if (include_primary_dns_opt) {
    if (o + 6u > cap)
      return -1;
    out[o++] = IPCP_OPT_PRIMARY_DNS;
    out[o++] = 6;
    memcpy(out + o, primary_dns, 4);
    o += 4u;
  }
  if (include_secondary_dns_opt) {
    if (o + 6u > cap)
      return -1;
    out[o++] = IPCP_OPT_SECONDARY_DNS;
    out[o++] = 6;
    memcpy(out + o, secondary_dns, 4);
    o += 4u;
  }
  util_write_be16(out + len_mark, (uint16_t)(o - code_off));
  return (int)o;
}

size_t ppp_write_frame_prefix(uint8_t *buf, size_t cap, uint16_t proto, int lcp_acfc, int lcp_pfc) {
  if (buf == NULL)
    return 0u;
  int compress_proto = lcp_pfc && proto <= 0x00ffu && (proto & 0x0001u) != 0u;
  if (lcp_acfc) {
    if (compress_proto) {
      if (cap < 1u)
        return 0u;
      buf[0] = (uint8_t)proto;
      return 1u;
    }
    if (cap < 2u)
      return 0u;
    util_write_be16(buf, proto);
    return 2u;
  }
  if (compress_proto) {
    if (cap < 3u)
      return 0u;
    buf[0] = 0xff;
    buf[1] = 0x03;
    buf[2] = (uint8_t)proto;
    return 3u;
  }
  if (cap < 4u)
    return 0u;
  buf[0] = 0xff;
  buf[1] = 0x03;
  util_write_be16(buf + 2u, proto);
  return 4u;
}

size_t ppp_ip_frame_len(size_t ip_len, int lcp_acfc, int lcp_pfc) {
  if (lcp_acfc)
    return (lcp_pfc ? 1u : 2u) + ip_len;
  return (lcp_pfc ? 3u : 4u) + ip_len;
}

int ppp_build_ip_frame(uint8_t *out, size_t cap, const uint8_t *ip, size_t ip_len, int lcp_acfc, int lcp_pfc) {
  if (ip == NULL && ip_len > 0u)
    return -1;
  size_t prefix = ppp_write_frame_prefix(out, cap, PPP_WIRE_PROTO_IP, lcp_acfc, lcp_pfc);
  if (prefix == 0u || ip_len > cap - prefix)
    return -1;
  if (ip_len > 0u)
    memcpy(out + prefix, ip, ip_len);
  return (int)(prefix + ip_len);
}

int ppp_build_lcp_echo_reply_frame(uint8_t *out, size_t cap, const uint8_t *req_lcp, size_t req_len, int lcp_acfc,
                                   int lcp_pfc) {
  if (out == NULL || req_lcp == NULL || req_len < 4u)
    return -1;
  if (req_lcp[0] != (uint8_t)PPP_LCP_CODE_ECHO_REQUEST)
    return -1;
  uint16_t lcp_len = util_read_be16(req_lcp + 2u);
  if (lcp_len < 8u || (size_t)lcp_len > req_len)
    return -1;
  size_t ppp_prefix = ppp_write_frame_prefix(out, cap, PPP_WIRE_PROTO_LCP, lcp_acfc, lcp_pfc);
  if (ppp_prefix == 0u || (size_t)lcp_len > cap - ppp_prefix)
    return -1;
  out[ppp_prefix + 0u] = (uint8_t)PPP_LCP_CODE_ECHO_REPLY;
  out[ppp_prefix + 1u] = req_lcp[1];
  util_write_be16(out + ppp_prefix + 2u, lcp_len);
  /* We never negotiated Magic-Number, so the reply value stays zero per RFC 1661 section 5.8. */
  util_write_be32(out + ppp_prefix + 4u, 0u);
  if (lcp_len > 8u)
    memcpy(out + ppp_prefix + 8u, req_lcp + 8u, (size_t)lcp_len - 8u);
  return (int)(ppp_prefix + (size_t)lcp_len);
}

int ppp_clamp_tcp_syn_mss(uint8_t *pkt, size_t len, uint16_t clamp_mss, uint16_t *old_mss_out, uint16_t *new_mss_out) {
  if (pkt == NULL || len < 20u || clamp_mss == 0u)
    return 0;
  if ((pkt[0] >> 4) != 4u)
    return 0;
  unsigned ihl = (unsigned)(pkt[0] & 0x0fu) * 4u;
  if (ihl < 20u || ihl > len)
    return 0;
  uint16_t tot_len_be = util_read_be16(pkt + 2);
  if (tot_len_be < (uint16_t)ihl)
    return 0;
  size_t ip_len = (size_t)tot_len_be;
  if (ip_len > len)
    return 0;
  uint16_t frag = util_read_be16(pkt + 6);
  if ((frag & 0x3fffu) != 0u)
    return 0;
  if (pkt[9] != TF_IPPROTO_TCP)
    return 0;

  size_t l4_len = ip_len - ihl;
  if (l4_len < 20u || ihl + l4_len > len)
    return 0;
  uint8_t *l4 = pkt + ihl;
  unsigned tcp_hlen = (unsigned)(l4[12] >> 4) * 4u;
  if (tcp_hlen < 20u || tcp_hlen > l4_len)
    return 0;
  if ((l4[13] & 0x02u) == 0u)
    return 0;

  size_t opt = 20u;
  while (opt < tcp_hlen) {
    uint8_t kind = l4[opt];
    if (kind == 0u)
      break;
    if (kind == 1u) {
      opt++;
      continue;
    }
    if (opt + 1u >= tcp_hlen)
      break;
    uint8_t olen = l4[opt + 1u];
    if (olen < 2u || opt + (size_t)olen > tcp_hlen)
      break;
    /* TCP option kind 2: Maximum Segment Size (4 bytes). */
    if (kind == 2u && olen == 4u) {
      uint16_t old_mss = util_read_be16(l4 + opt + 2u);
      if (old_mss > clamp_mss) {
        util_write_be16(l4 + opt + 2u, clamp_mss);
        util_write_be16(l4 + 16u, 0u);
        if (old_mss_out != NULL)
          *old_mss_out = old_mss;
        if (new_mss_out != NULL)
          *new_mss_out = clamp_mss;
        return 1;
      }
      return 0;
    }
    opt += (size_t)olen;
  }
  return 0;
}

int ppp_fix_tun_ipv4_checksums(uint8_t *pkt, size_t len, uint8_t *fixed_proto_out) {
  if (len < 20u)
    return 0;
  if ((pkt[0] >> 4) != 4u)
    return 0;
  unsigned ihl = (unsigned)(pkt[0] & 0x0fu) * 4u;
  if (ihl < 20u || ihl > len)
    return 0;
  uint16_t tot_len_be = util_read_be16(pkt + 2);
  if (tot_len_be < (uint16_t)ihl)
    return 0;
  size_t ip_len = (size_t)tot_len_be;
  if (ip_len > len)
    return 0;
  int fixed = 0;

  if (util_read_be16(pkt + 10) == 0u) {
    util_write_be16(pkt + 10, 0);
    uint32_t sum = tf_csum_acc_bytes(0, pkt, ihl);
    util_write_be16(pkt + 10, tf_inet_checksum_fold(sum));
    fixed = 1;
  }

  uint16_t frag = util_read_be16(pkt + 6);
  unsigned frag_off = (unsigned)(frag & 0x1fffu);
  if (frag_off != 0u)
    return fixed;

  uint8_t proto = pkt[9];
  if (fixed && fixed_proto_out != NULL)
    *fixed_proto_out = proto;
  size_t l4_len = ip_len - ihl;
  if (l4_len < 8u || ihl + l4_len > len)
    return fixed;
  uint8_t *l4 = pkt + ihl;

  if (proto == TF_IPPROTO_UDP) {
    if (util_read_be16(l4 + 6) != 0u)
      return fixed;
    uint32_t sum = 0;
    sum = tf_csum_acc_bytes(sum, pkt + 12, 4);
    sum = tf_csum_acc_bytes(sum, pkt + 16, 4);
    sum += (uint32_t)TF_IPPROTO_UDP;
    sum += (uint32_t)l4_len;
    sum = tf_csum_acc_bytes(sum, l4, l4_len);
    uint16_t c = tf_inet_checksum_fold(sum);
    if (c == 0u)
      c = 0xffffu;
    util_write_be16(l4 + 6, c);
    fixed = 1;
    if (fixed_proto_out != NULL)
      *fixed_proto_out = proto;
  } else if (proto == TF_IPPROTO_TCP) {
    if (l4_len < 20u)
      return fixed;
    if (util_read_be16(l4 + 16) != 0u)
      return fixed;
    uint32_t sum = 0;
    sum = tf_csum_acc_bytes(sum, pkt + 12, 4);
    sum = tf_csum_acc_bytes(sum, pkt + 16, 4);
    sum += (uint32_t)TF_IPPROTO_TCP;
    sum += (uint32_t)l4_len;
    sum = tf_csum_acc_bytes(sum, l4, l4_len);
    util_write_be16(l4 + 16, tf_inet_checksum_fold(sum));
    fixed = 1;
    if (fixed_proto_out != NULL)
      *fixed_proto_out = proto;
  }
  return fixed;
}
