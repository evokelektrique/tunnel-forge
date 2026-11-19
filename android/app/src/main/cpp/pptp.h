#ifndef TUNNEL_FORGE_PPTP_H
#define TUNNEL_FORGE_PPTP_H

/* RFC 2637 PPTP control channel (TCP 1723) + GRE session wrapper. */

#include "pptp_gre.h"
#include "pptp_root.h"

#include <stddef.h>
#include <stdint.h>

#define PPTP_MAGIC_COOKIE 0x1a2b3c4du
#define PPTP_MSG_TYPE_CONTROL 1u

#define PPTP_CTRL_SCCRQ 1u
#define PPTP_CTRL_SCCRP 2u
#define PPTP_CTRL_STOPCCRQ 3u
#define PPTP_CTRL_STOPCCRP 4u
#define PPTP_CTRL_ECHORQ 5u
#define PPTP_CTRL_ECHORP 6u
#define PPTP_CTRL_OCRQ 7u
#define PPTP_CTRL_OCRP 8u
#define PPTP_CTRL_CCRQ 12u
#define PPTP_CTRL_CDN 13u
#define PPTP_CTRL_WEN 14u
#define PPTP_CTRL_SLI 15u

#define PPTP_DISPATCH_ERROR (-1)
#define PPTP_DISPATCH_OK 0
#define PPTP_DISPATCH_REMOTE_CLOSED 1
#define PPTP_DISPATCH_INBOUND_ACTIVITY 2

typedef struct {
  int ctrl_fd;
  uint8_t peer_ipv4[4];
  uint16_t local_call_id;
  uint16_t remote_call_id;
  uint16_t call_serial;
  uint32_t echo_id;
  uint8_t ctrl_rx[2048];
  size_t ctrl_rx_len;
  pptp_gre_state_t gre;
  pptp_root_t root;
  int call_established;
} pptp_session_t;

void pptp_session_init(pptp_session_t *s);

/** Resolve @p server IPv4, connect TCP 1723, and run SCCRQ/SCCRP + OCRQ/OCRP + SLI. */
int pptp_connect(const char *server, pptp_session_t *s);

/** Start the root GRE helper using the resolved peer_ipv4 from pptp_connect(). */
int pptp_start_gre_helper(pptp_session_t *s, const char *helper_path, int protect_vpn, const char *bind_iface);

/** Send one PPP frame encapsulated in Enhanced GRE via the root helper. */
int pptp_send_ppp(pptp_session_t *s, const uint8_t *ppp, size_t ppp_len);

/** Send a standalone GRE ACK if a peer sequence number is pending acknowledgement. */
int pptp_flush_gre_ack(pptp_session_t *s);

/** Process available bytes on TCP control socket (Echo-Request, Echo-Reply, CDN, StopCCRQ). */
int pptp_dispatch_control(pptp_session_t *s);

/** Send PPTP Echo-Request on TCP control channel for liveness checks. */
int pptp_send_echo_request(pptp_session_t *s);

/** Best-effort graceful Call-Clear-Request + Stop-Control-Connection-Request. */
void pptp_send_teardown(pptp_session_t *s);

/** Close TCP control socket and stop root GRE helper cleanly. */
void pptp_close(pptp_session_t *s, int send_teardown);

/* Pure wire codecs exposed for host unit tests. */
int pptp_build_sccrq(uint8_t *out, size_t cap);
int pptp_build_ocrq(uint8_t *out, size_t cap, uint16_t call_id, uint16_t call_serial);
int pptp_build_sli(uint8_t *out, size_t cap, uint16_t peer_call_id, uint32_t send_accm, uint32_t recv_accm);
int pptp_build_echo_request(uint8_t *out, size_t cap, uint32_t id);
int pptp_build_echo_reply(uint8_t *out, size_t cap, uint32_t id);
int pptp_build_stopccrq(uint8_t *out, size_t cap, uint8_t reason);
int pptp_build_stopccrp(uint8_t *out, size_t cap);
int pptp_build_ccrq(uint8_t *out, size_t cap, uint16_t call_id);

/** Validate PPTP control frame header and return control_message_type (>0) or -1. */
int pptp_parse_control_header(const uint8_t *buf, size_t len, uint16_t *msg_len_out, uint16_t *ctrl_type_out);

/** Return 1 if @p path is a safe absolute path for single-quoted shell exec, else 0. */
int pptp_is_safe_helper_path(const char *path);

#endif
