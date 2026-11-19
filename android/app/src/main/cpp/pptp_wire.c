/*
 * Pure RFC 2637 PPTP control message encoders and header validator.
 * Separated from socket I/O so host unit tests compile without POSIX socket headers.
 */
#include "pptp.h"

#include "util_endian.h"

#include <stdio.h>
#include <string.h>

#define PPTP_SCCRQ_LEN 156u
#define PPTP_STOPCCRQ_LEN 16u
#define PPTP_STOPCCRP_LEN 16u
#define PPTP_ECHORQ_LEN 16u
#define PPTP_ECHORP_LEN 20u
#define PPTP_OCRQ_LEN 168u
#define PPTP_CCRQ_LEN 16u
#define PPTP_SLI_LEN 24u

static void pptp_write_header(uint8_t *out, uint16_t length, uint16_t ctrl_type) {
  memset(out, 0, length);
  util_write_be16(out + 0u, length);
  util_write_be16(out + 2u, PPTP_MSG_TYPE_CONTROL);
  util_write_be32(out + 4u, PPTP_MAGIC_COOKIE);
  util_write_be16(out + 8u, ctrl_type);
  util_write_be16(out + 10u, 0u);
}

int pptp_build_sccrq(uint8_t *out, size_t cap) {
  if (out == NULL || cap < PPTP_SCCRQ_LEN)
    return -1;
  pptp_write_header(out, PPTP_SCCRQ_LEN, PPTP_CTRL_SCCRQ);
  util_write_be16(out + 12u, 0x0100u); /* Protocol version 1.0 */
  util_write_be16(out + 14u, 0u);      /* Reserved1 */
  util_write_be32(out + 16u, 3u);      /* Framing capabilities: async + sync */
  util_write_be32(out + 20u, 3u);      /* Bearer capabilities: analog + digital */
  util_write_be16(out + 24u, 0u);      /* Max channels */
  util_write_be16(out + 26u, 1u);      /* Firmware revision */
  snprintf((char *)(out + 28u), 64u, "%s", "TunnelForge");
  snprintf((char *)(out + 92u), 64u, "%s", "TunnelForge");
  return (int)PPTP_SCCRQ_LEN;
}

int pptp_build_ocrq(uint8_t *out, size_t cap, uint16_t call_id, uint16_t call_serial) {
  if (out == NULL || cap < PPTP_OCRQ_LEN)
    return -1;
  pptp_write_header(out, PPTP_OCRQ_LEN, PPTP_CTRL_OCRQ);
  util_write_be16(out + 12u, call_id);
  util_write_be16(out + 14u, call_serial);
  util_write_be32(out + 16u, 300u);       /* Minimum BPS */
  util_write_be32(out + 20u, 100000000u); /* Maximum BPS */
  util_write_be32(out + 24u, 3u);         /* Bearer type: analog + digital */
  util_write_be32(out + 28u, 3u);         /* Framing type: async + sync */
  util_write_be16(out + 32u, 64u);        /* Packet receive window size */
  util_write_be16(out + 34u, 0u);         /* Packet processing delay */
  util_write_be16(out + 36u, 0u);         /* Phone number length */
  util_write_be16(out + 38u, 0u);         /* Reserved1 */
  return (int)PPTP_OCRQ_LEN;
}

int pptp_build_sli(uint8_t *out, size_t cap, uint16_t peer_call_id, uint32_t send_accm, uint32_t recv_accm) {
  if (out == NULL || cap < PPTP_SLI_LEN)
    return -1;
  pptp_write_header(out, PPTP_SLI_LEN, PPTP_CTRL_SLI);
  util_write_be16(out + 12u, peer_call_id);
  util_write_be16(out + 14u, 0u);
  util_write_be32(out + 16u, send_accm);
  util_write_be32(out + 20u, recv_accm);
  return (int)PPTP_SLI_LEN;
}

int pptp_build_echo_request(uint8_t *out, size_t cap, uint32_t id) {
  if (out == NULL || cap < PPTP_ECHORQ_LEN)
    return -1;
  pptp_write_header(out, PPTP_ECHORQ_LEN, PPTP_CTRL_ECHORQ);
  util_write_be32(out + 12u, id);
  return (int)PPTP_ECHORQ_LEN;
}

int pptp_build_echo_reply(uint8_t *out, size_t cap, uint32_t id) {
  if (out == NULL || cap < PPTP_ECHORP_LEN)
    return -1;
  pptp_write_header(out, PPTP_ECHORP_LEN, PPTP_CTRL_ECHORP);
  util_write_be32(out + 12u, id);
  out[16] = 1u; /* Result: OK */
  out[17] = 0u; /* Error: None */
  util_write_be16(out + 18u, 0u);
  return (int)PPTP_ECHORP_LEN;
}

int pptp_build_stopccrq(uint8_t *out, size_t cap, uint8_t reason) {
  if (out == NULL || cap < PPTP_STOPCCRQ_LEN)
    return -1;
  pptp_write_header(out, PPTP_STOPCCRQ_LEN, PPTP_CTRL_STOPCCRQ);
  out[12] = reason;
  return (int)PPTP_STOPCCRQ_LEN;
}

int pptp_build_stopccrp(uint8_t *out, size_t cap) {
  if (out == NULL || cap < PPTP_STOPCCRP_LEN)
    return -1;
  pptp_write_header(out, PPTP_STOPCCRP_LEN, PPTP_CTRL_STOPCCRP);
  out[12] = 1u; /* Result: OK */
  out[13] = 0u;
  return (int)PPTP_STOPCCRP_LEN;
}

int pptp_build_ccrq(uint8_t *out, size_t cap, uint16_t call_id) {
  if (out == NULL || cap < PPTP_CCRQ_LEN)
    return -1;
  pptp_write_header(out, PPTP_CCRQ_LEN, PPTP_CTRL_CCRQ);
  util_write_be16(out + 12u, call_id);
  return (int)PPTP_CCRQ_LEN;
}

int pptp_parse_control_header(const uint8_t *buf, size_t len, uint16_t *msg_len_out, uint16_t *ctrl_type_out) {
  if (buf == NULL || len < 12u)
    return -1;
  uint16_t msg_len = util_read_be16(buf + 0u);
  uint16_t msg_type = util_read_be16(buf + 2u);
  uint32_t cookie = util_read_be32(buf + 4u);
  uint16_t ctrl_type = util_read_be16(buf + 8u);
  if (msg_len < 12u || msg_type != PPTP_MSG_TYPE_CONTROL || cookie != PPTP_MAGIC_COOKIE)
    return -1;
  if (msg_len_out != NULL)
    *msg_len_out = msg_len;
  if (ctrl_type_out != NULL)
    *ctrl_type_out = ctrl_type;
  return (int)ctrl_type;
}

int pptp_is_safe_helper_path(const char *path) {
  if (path == NULL || path[0] != '/')
    return 0;
  size_t len = 0u;
  for (; path[len] != '\0'; len++) {
    char c = path[len];
    /* Allow Android 11+ randomized /data/app/~~...==/<pkg>-...==/lib/... characters, never quotes or shell ops. */
    int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '/' || c == '.' ||
             c == '_' || c == '-' || c == '~' || c == '=' || c == '+' || c == ',' || c == '@' || c == ':';
    if (!ok)
      return 0;
  }
  return len > 1u && len < 512u;
}
