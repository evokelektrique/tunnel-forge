#ifndef TUNNEL_FORGE_PPTP_ROOT_H
#define TUNNEL_FORGE_PPTP_ROOT_H

/* Unprivileged-side IPC client for the root-spawned libpptp_gre_helper.so process. */

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct {
  pid_t pid;
  int to_helper_fd;
  int from_helper_fd;
  int err_fd;
  uint8_t rx_buf[8192];
  size_t rx_len;
} pptp_root_t;

void pptp_root_init(pptp_root_t *r);

/**
 * Spawn libpptp_gre_helper.so via su and complete the binary init handshake.
 *
 * @return TUNNEL_EXIT_OK on success, or TUNNEL_EXIT_ROOT_UNAVAILABLE / TUNNEL_EXIT_ROOT_DENIED /
 *         TUNNEL_EXIT_GRE_SOCKET_FAILED / TUNNEL_EXIT_STOPPED on failure.
 */
int pptp_root_start(pptp_root_t *r, const char *helper_path, const uint8_t peer_ipv4[4], int protect_vpn,
                    const char *bind_iface);

/** Stop helper process, close pipes, and reap child cleanly. */
void pptp_root_stop(pptp_root_t *r);

/** Send one raw GRE packet (length-prefixed over stdin pipe). Returns 0 or -1 with errno. */
int pptp_root_send_gre(pptp_root_t *r, const uint8_t *gre, size_t gre_len);

/** Non-zero when rx_buf already holds at least one complete framed GRE packet. */
int pptp_root_has_buffered_frame(const pptp_root_t *r);

/**
 * Read one framed GRE packet from the helper (draining buffered bytes first, then non-blocking read).
 * @return >0 packet length, 0 if no complete frame ready (EAGAIN), -1 on EOF or fatal pipe error.
 */
int pptp_root_read_gre(pptp_root_t *r, uint8_t *out, size_t cap);

#endif
