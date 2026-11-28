#ifndef TUNNEL_FORGE_L2TP_ROOT_H
#define TUNNEL_FORGE_L2TP_ROOT_H

/*
 * Unprivileged-side IPC client and shared frame constants for the root-spawned
 * libl2tp_root_helper.so process (root UDP 500/4500 sockets, Kernel XFRM, and raw ESP fallback).
 */

#include "l2tp_xfrm.h"

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
typedef int tf_l2tp_pid_t;
#else
#include <sys/types.h>
typedef pid_t tf_l2tp_pid_t;
#endif

#define TF_L2TP_FRAME_HDR_LEN 4u
#define TF_L2TP_MAX_FRAME 8192u
#define TF_L2TP_HELPER_MAGIC0 'T'
#define TF_L2TP_HELPER_MAGIC1 'F'
#define TF_L2TP_HELPER_MAGIC2 'L'
#define TF_L2TP_HELPER_MAGIC3 '2'
#define TF_L2TP_INIT_PAYLOAD_LEN 36u
#define TF_L2TP_FLAG_PROTECT_VPN 1u
#define TF_L2TP_ANDROID_FWMARK_PROTECT 0x00020000u

#define TF_L2TP_CMD_INIT 0x01u
#define TF_L2TP_CMD_OPEN_UDP 0x02u
#define TF_L2TP_CMD_CONNECT_UDP 0x03u
#define TF_L2TP_CMD_UDP_SEND 0x04u
#define TF_L2TP_CMD_UDP_RECV 0x05u
#define TF_L2TP_CMD_SET_ENCAP 0x06u
#define TF_L2TP_CMD_XFRM_INSTALL 0x07u
#define TF_L2TP_CMD_XFRM_DELETE 0x08u
#define TF_L2TP_CMD_OPEN_RAW_ESP 0x09u
#define TF_L2TP_CMD_START_STREAM 0x0au
#define TF_L2TP_CMD_STOP 0x0fu
#define TF_L2TP_MSG_REPLY 0x80u
#define TF_L2TP_MSG_DATA 0x10u
#define TF_L2TP_MSG_IKE_SEND 0x11u

#define TF_L2TP_STREAM_UDP4500 0u
#define TF_L2TP_STREAM_RAW_ESP 1u

typedef struct {
  int use_root;
  char helper_path[512];
  char bind_iface[24];
} l2tp_root_config_t;

typedef struct {
  tf_l2tp_pid_t pid;
  int to_helper_fd;
  int from_helper_fd;
  int err_fd;
  int xfrm_installed;
  int stream_active;
  uint8_t rx_buf[16384];
  size_t rx_len;
} l2tp_root_t;

void l2tp_root_init(l2tp_root_t *r);

/** Spawn libl2tp_root_helper.so via su and complete the binary init handshake. */
int l2tp_root_start(l2tp_root_t *r, const char *helper_path, int protect_vpn, const char *bind_iface);

/** Ask helper to remove XFRM SAs/SPs if installed, close pipes, and reap child cleanly. */
void l2tp_root_stop(l2tp_root_t *r);

int l2tp_root_open_udp(l2tp_root_t *r, const uint8_t peer_ipv4[4], uint16_t remote_port, uint16_t bind_local_port,
                       int allow_ephemeral_fallback, uint8_t local_ipv4_out[4], uint16_t *local_port_be_out,
                       int *out_errno);

int l2tp_root_connect_udp(l2tp_root_t *r, const uint8_t peer_ipv4[4], uint16_t remote_port, uint8_t local_ipv4_out[4],
                          uint16_t *local_port_be_out, int *out_errno);

int l2tp_root_udp_send(l2tp_root_t *r, const uint8_t *data, size_t len, int *out_errno);

int l2tp_root_udp_recv(l2tp_root_t *r, uint8_t *buf, size_t cap, int timeout_ms, int peek, int *out_errno);

int l2tp_root_set_encap(l2tp_root_t *r, int encap_type, int *out_errno);

int l2tp_root_xfrm_install(l2tp_root_t *r, const tf_l2tp_xfrm_spec_t *spec, int *out_errno);

void l2tp_root_xfrm_delete(l2tp_root_t *r);

int l2tp_root_open_raw_esp(l2tp_root_t *r, const uint8_t peer_ipv4[4], int *out_errno);

int l2tp_root_start_stream(l2tp_root_t *r, int mode, int *out_errno);

/** Send IKE informational packet during active stream mode (best-effort teardown). */
int l2tp_root_ike_send_async(l2tp_root_t *r, const uint8_t *data, size_t len, int nat_t);

int l2tp_root_stream_send(void *ctx, const uint8_t *data, size_t len);

int l2tp_root_stream_recv_wait(void *ctx, uint8_t *buf, size_t cap, int timeout_ms);

int l2tp_root_stream_read_nonblock(l2tp_root_t *r, uint8_t *buf, size_t cap);

int l2tp_root_has_buffered_frame(const l2tp_root_t *r);

int l2tp_root_is_stream_active(const l2tp_root_t *r);

int l2tp_root_stream_fd(const l2tp_root_t *r);

#endif
