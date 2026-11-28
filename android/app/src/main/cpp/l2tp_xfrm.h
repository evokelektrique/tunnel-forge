#ifndef TUNNEL_FORGE_L2TP_XFRM_H
#define TUNNEL_FORGE_L2TP_XFRM_H

/*
 * Linux NETLINK_XFRM serializer, ACK parser, and SA/SP lifecycle helpers for root L2TP/IPsec.
 * Binary Netlink builders stay portable so host tests on Windows/macOS verify exact framing;
 * kernel netlink socket execution compiles under __linux__.
 */

#include <stddef.h>
#include <stdint.h>

#define TF_L2TP_XFRM_WIRE_LEN 156u
#define TF_L2TP_XFRM_CIPHER_3DES 3u
#define TF_L2TP_XFRM_CIPHER_AES 12u
#define TF_XFRM_DIR_IN 0u
#define TF_XFRM_DIR_OUT 1u

typedef struct {
  uint8_t local_ipv4[4];
  uint8_t peer_ipv4[4];
  uint16_t l2tp_local_port_be;
  uint16_t ike_local_port_be;
  uint32_t spi_out_be;
  uint32_t spi_in_be;
  uint32_t reqid;
  uint8_t cipher;
  uint8_t enc_key_len;
  uint8_t auth_key_len;
  uint8_t use4500;
  uint8_t enc_key_out[32];
  uint8_t auth_key_out[32];
  uint8_t enc_key_in[32];
  uint8_t auth_key_in[32];
} tf_l2tp_xfrm_spec_t;

/** Pack @p spec into @p out[TF_L2TP_XFRM_WIRE_LEN] in canonical big-endian wire order. */
int tf_l2tp_xfrm_spec_pack(const tf_l2tp_xfrm_spec_t *spec, uint8_t *out, size_t cap);

/** Unpack @p in[len] into @p spec and validate key sizes and cipher ID. Returns 0 or -1. */
int tf_l2tp_xfrm_spec_unpack(const uint8_t *in, size_t len, tf_l2tp_xfrm_spec_t *spec);

/** Build XFRM_MSG_NEWSA Netlink request for outbound (inbound=0) or inbound (inbound=1) SA. Returns length or 0. */
size_t tf_xfrm_nl_build_newsa(uint8_t *buf, size_t cap, uint32_t seq, const tf_l2tp_xfrm_spec_t *spec, int inbound);

/** Build XFRM_MSG_DELSA Netlink request for exact (daddr, spi_be, ESP). Returns length or 0. */
size_t tf_xfrm_nl_build_delsa(uint8_t *buf, size_t cap, uint32_t seq, const uint8_t daddr[4], uint32_t spi_be);

/** Build XFRM_MSG_NEWPOLICY Netlink request for dir (TF_XFRM_DIR_IN/OUT). Returns length or 0. */
size_t tf_xfrm_nl_build_newpolicy(uint8_t *buf, size_t cap, uint32_t seq, const tf_l2tp_xfrm_spec_t *spec, int dir);

/** Build XFRM_MSG_DELPOLICY Netlink request for dir (TF_XFRM_DIR_IN/OUT). Returns length or 0. */
size_t tf_xfrm_nl_build_delpolicy(uint8_t *buf, size_t cap, uint32_t seq, const tf_l2tp_xfrm_spec_t *spec, int dir);

/**
 * Scan Netlink response datagram @p msg[msg_len] for NLMSG_ERROR matching @p expected_seq.
 * Returns 1 when matched (*out_err set to 0 or positive errno), 0 if not matching, -1 if malformed.
 */
int tf_xfrm_nl_parse_ack(const uint8_t *msg, size_t msg_len, uint32_t expected_seq, int *out_err);

#ifdef __linux__
/** Install outbound+inbound transport ESP SAs and scoped UDP/1701 SPs cleanly (rolls back on partial failure). */
int tf_xfrm_install_pair(const tf_l2tp_xfrm_spec_t *spec, int *out_errno);

/** Delete previously installed SPs and SAs matching exact spec (never flushes global XFRM state). */
void tf_xfrm_delete_pair(const tf_l2tp_xfrm_spec_t *spec);
#endif

#endif
