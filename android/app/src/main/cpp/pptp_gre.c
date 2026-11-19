/*
 * RFC 2637 section 4 Enhanced GRE codec for PPTP data channel.
 */
#include "pptp_gre.h"

#include "util_endian.h"

#include <string.h>

#define GRE_FLAG_C 0x8000u
#define GRE_FLAG_R 0x4000u
#define GRE_FLAG_K 0x2000u
#define GRE_FLAG_S 0x1000u
#define GRE_FLAG_A 0x0080u
#define GRE_VER_MASK 0x0007u
#define GRE_VER_PPTP 0x0001u

void pptp_gre_init(pptp_gre_state_t *s, uint16_t local_call_id, uint16_t remote_call_id) {
  if (s == NULL)
    return;
  memset(s, 0, sizeof(*s));
  s->local_call_id = local_call_id;
  s->remote_call_id = remote_call_id;
}

int pptp_gre_build_data(pptp_gre_state_t *s, const uint8_t *ppp, size_t ppp_len, uint8_t *out, size_t cap) {
  if (s == NULL || ppp == NULL || out == NULL || ppp_len == 0u || ppp_len > 0xffffu)
    return -1;
  int include_ack = s->have_rx_seq && s->ack_pending;
  size_t hdr_len = include_ack ? 16u : 12u;
  if (hdr_len + ppp_len > cap)
    return -1;

  uint16_t flags_ver = (uint16_t)(GRE_FLAG_K | GRE_FLAG_S | GRE_VER_PPTP);
  if (include_ack)
    flags_ver = (uint16_t)(flags_ver | GRE_FLAG_A);

  util_write_be16(out + 0u, flags_ver);
  util_write_be16(out + 2u, PPTP_GRE_PROTO_PPP);
  util_write_be16(out + 4u, (uint16_t)ppp_len);
  util_write_be16(out + 6u, s->remote_call_id);
  util_write_be32(out + 8u, s->tx_seq);
  s->tx_seq++;

  if (include_ack) {
    util_write_be32(out + 12u, s->rx_seq);
    s->last_acked_rx_seq = s->rx_seq;
    s->ack_pending = 0;
  }

  memcpy(out + hdr_len, ppp, ppp_len);
  return (int)(hdr_len + ppp_len);
}

int pptp_gre_build_ack(pptp_gre_state_t *s, uint8_t *out, size_t cap) {
  if (s == NULL || out == NULL || cap < 12u)
    return -1;
  if (!s->have_rx_seq || !s->ack_pending)
    return 0;

  uint16_t flags_ver = (uint16_t)(GRE_FLAG_K | GRE_FLAG_A | GRE_VER_PPTP);
  util_write_be16(out + 0u, flags_ver);
  util_write_be16(out + 2u, PPTP_GRE_PROTO_PPP);
  util_write_be16(out + 4u, 0u);
  util_write_be16(out + 6u, s->remote_call_id);
  util_write_be32(out + 8u, s->rx_seq);
  s->last_acked_rx_seq = s->rx_seq;
  s->ack_pending = 0;
  return 12;
}

int pptp_gre_extract_ppp(pptp_gre_state_t *s, const uint8_t *gre, size_t gre_len, const uint8_t **ppp_out,
                         size_t *ppp_len_out) {
  if (s == NULL || gre == NULL || gre_len < 8u || ppp_out == NULL || ppp_len_out == NULL)
    return -1;
  *ppp_out = NULL;
  *ppp_len_out = 0u;

  uint16_t flags_ver = util_read_be16(gre + 0u);
  uint16_t proto = util_read_be16(gre + 2u);
  if ((flags_ver & GRE_VER_MASK) != GRE_VER_PPTP)
    return -1;
  if ((flags_ver & GRE_FLAG_K) == 0u)
    return -1;
  if ((flags_ver & (GRE_FLAG_C | GRE_FLAG_R)) != 0u)
    return -1;
  if (proto != PPTP_GRE_PROTO_PPP)
    return -1;

  uint16_t payload_len = util_read_be16(gre + 4u);
  uint16_t call_id = util_read_be16(gre + 6u);
  if (call_id != s->local_call_id)
    return -1;

  size_t off = 8u;
  int has_seq = (flags_ver & GRE_FLAG_S) != 0u;
  int has_ack = (flags_ver & GRE_FLAG_A) != 0u;
  uint32_t seq = 0u;
  if (has_seq) {
    if (off + 4u > gre_len)
      return -1;
    seq = util_read_be32(gre + off);
    off += 4u;
  }
  if (has_ack) {
    if (off + 4u > gre_len)
      return -1;
    off += 4u;
  }

  if (off + (size_t)payload_len > gre_len)
    return -1;

  if (!has_seq || payload_len == 0u)
    return 0;

  if (!s->have_rx_seq) {
    s->have_rx_seq = 1;
    s->rx_seq = seq;
    s->ack_pending = 1;
  } else {
    int32_t diff = (int32_t)(seq - s->rx_seq);
    if (diff > 0) {
      s->rx_seq = seq;
      s->ack_pending = 1;
    } else if (diff == 0) {
      /* Duplicate of latest sequence number: still re-ack in case our ACK was lost. */
      s->ack_pending = 1;
      return 0;
    } else {
      /* Out-of-order older packet: drop without moving rx_seq backwards. */
      return 0;
    }
  }

  *ppp_out = gre + off;
  *ppp_len_out = (size_t)payload_len;
  return 1;
}
