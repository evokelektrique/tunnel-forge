#ifndef TUNNEL_FORGE_PPTP_GRE_H
#define TUNNEL_FORGE_PPTP_GRE_H

/* RFC 2637 section 4 Enhanced GRE framing and sequence/ACK tracking for PPTP. */

#include <stddef.h>
#include <stdint.h>

#define PPTP_GRE_PROTO_PPP 0x880bu
#define PPTP_GRE_MAX_HEADER_LEN 16u

typedef struct {
  uint16_t local_call_id;
  uint16_t remote_call_id;
  uint32_t tx_seq;
  uint32_t rx_seq;
  uint32_t last_acked_rx_seq;
  int have_rx_seq;
  int ack_pending;
} pptp_gre_state_t;

void pptp_gre_init(pptp_gre_state_t *s, uint16_t local_call_id, uint16_t remote_call_id);

/**
 * Build an outbound Enhanced GRE data packet carrying @p ppp_len PPP bytes.
 * Piggybacks an ACK if a new peer sequence number has not yet been acknowledged.
 * @return total GRE packet length on success, -1 on error.
 */
int pptp_gre_build_data(pptp_gre_state_t *s, const uint8_t *ppp, size_t ppp_len, uint8_t *out, size_t cap);

/**
 * Build an outbound ACK-only Enhanced GRE packet (S=0, A=1, payload_len=0).
 * @return total GRE packet length (12) on success, 0 if no ACK is pending, -1 on error.
 */
int pptp_gre_build_ack(pptp_gre_state_t *s, uint8_t *out, size_t cap);

/**
 * Parse an inbound Enhanced GRE packet (outer IPv4 header already stripped).
 * Validates version=1, K=1, protocol=0x880B, call_id == local_call_id, and payload bounds.
 * Updates peer sequence tracking when S=1.
 *
 * @return 1 if a PPP payload was extracted (*ppp_out / *ppp_len_out populated),
 *         0 if packet was a valid ACK-only or duplicate/out-of-order control GRE frame,
 *        -1 if packet is malformed or for another call ID.
 */
int pptp_gre_extract_ppp(pptp_gre_state_t *s, const uint8_t *gre, size_t gre_len, const uint8_t **ppp_out,
                         size_t *ppp_len_out);

#endif
