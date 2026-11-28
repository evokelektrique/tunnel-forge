/*
 * Minimal root helper executable (packaged as libl2tp_root_helper.so) invoked via su.
 * Handles privileged UDP 500/4500 sockets (SO_MARK + SO_BINDTODEVICE), Linux NETLINK_XFRM
 * transport-mode IPsec ESP setup/teardown, and SOCK_RAW IPPROTO_ESP or UDP4500 fallback streams.
 */
#define _GNU_SOURCE

#include "l2tp_root.h"
#include "l2tp_xfrm.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/udp.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef IPPROTO_ESP
#define IPPROTO_ESP 50
#endif

static volatile sig_atomic_t g_helper_stop;

static void helper_on_signal(int sig) {
  (void)sig;
  g_helper_stop = 1;
}

static uint16_t helper_read_be16(const uint8_t *p) { return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]); }

static uint32_t helper_read_be32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void helper_write_be16(uint8_t *p, uint16_t v) {
  p[0] = (uint8_t)(v >> 8);
  p[1] = (uint8_t)(v & 0xffu);
}

static void helper_write_be32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24);
  p[1] = (uint8_t)((v >> 16) & 0xffu);
  p[2] = (uint8_t)((v >> 8) & 0xffu);
  p[3] = (uint8_t)(v & 0xffu);
}

static int helper_read_exact(int fd, uint8_t *buf, size_t len) {
  size_t got = 0u;
  while (got < len && !g_helper_stop) {
    ssize_t n = read(fd, buf + got, len - got);
    if (n == 0)
      return -1;
    if (n < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    got += (size_t)n;
  }
  return got == len ? 0 : -1;
}

static int helper_write_all(int fd, const uint8_t *buf, size_t len) {
  size_t off = 0u;
  while (off < len && !g_helper_stop) {
    ssize_t n = write(fd, buf + off, len - off);
    if (n > 0) {
      off += (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR)
      continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      struct pollfd pfd = {.fd = fd, .events = POLLOUT};
      int pr = poll(&pfd, 1u, 1000);
      if (pr <= 0)
        return -1;
      continue;
    }
    return -1;
  }
  return off == len ? 0 : -1;
}

static int helper_write_frame_nonblock(int fd, const uint8_t *buf, size_t len) {
  size_t off = 0u;
  while (off < len && !g_helper_stop) {
    ssize_t n = write(fd, buf + off, len - off);
    if (n > 0) {
      off += (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR)
      continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      if (off == 0u)
        return 1;
      struct pollfd pfd = {.fd = fd, .events = POLLOUT};
      int pr = poll(&pfd, 1u, 200);
      if (pr <= 0)
        return -1;
      continue;
    }
    return -1;
  }
  return off == len ? 0 : -1;
}

static int helper_send_frame(int fd, uint8_t type, uint8_t status, const uint8_t *payload, size_t len) {
  if (len > TF_L2TP_MAX_FRAME)
    return -1;
  uint8_t frame[TF_L2TP_FRAME_HDR_LEN + TF_L2TP_MAX_FRAME];
  frame[0] = type;
  frame[1] = status;
  helper_write_be16(frame + 2u, (uint16_t)len);
  if (len > 0u && payload != NULL)
    memcpy(frame + TF_L2TP_FRAME_HDR_LEN, payload, len);
  return helper_write_all(fd, frame, TF_L2TP_FRAME_HDR_LEN + len);
}

static void helper_send_err_reply(uint8_t status, uint32_t err_no) {
  uint8_t body[4];
  helper_write_be32(body, err_no);
  (void)helper_send_frame(STDOUT_FILENO, TF_L2TP_MSG_REPLY, status, body, sizeof(body));
}

static int helper_is_safe_iface(const char *name) {
  size_t len = 0u;
  for (; name[len] != '\0'; len++) {
    char c = name[len];
    int ok =
        (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.';
    if (!ok)
      return 0;
  }
  return len > 0u && len < 24u;
}

static void helper_set_nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags >= 0)
    (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void helper_protect_socket(int fd, uint32_t flags, uint32_t fwmark, const char *bind_iface) {
  if ((flags & TF_L2TP_FLAG_PROTECT_VPN) == 0u)
    return;
  if (fwmark != 0u) {
    int mark = (int)fwmark;
    if (setsockopt(fd, SOL_SOCKET, SO_MARK, &mark, (socklen_t)sizeof(mark)) != 0)
      (void)dprintf(STDERR_FILENO, "l2tp SO_MARK errno=%d\n", errno);
  }
  if (helper_is_safe_iface(bind_iface) &&
      setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, bind_iface, (socklen_t)(strlen(bind_iface) + 1u)) != 0) {
    (void)dprintf(STDERR_FILENO, "l2tp SO_BINDTODEVICE errno=%d\n", errno);
  }
}

static void helper_fill_local_reply(int fd, uint8_t out[12]) {
  memset(out, 0, 12u);
  struct sockaddr_in laddr;
  socklen_t llen = (socklen_t)sizeof(laddr);
  if (getsockname(fd, (struct sockaddr *)&laddr, &llen) == 0 && laddr.sin_family == AF_INET) {
    memcpy(out + 4u, &laddr.sin_addr.s_addr, 4u);
    memcpy(out + 8u, &laddr.sin_port, 2u);
  }
}

static int helper_open_udp_once(const uint8_t peer_ip[4], uint16_t remote_port, uint16_t local_port, uint32_t flags,
                                uint32_t fwmark, const char *bind_iface, int *out_errno) {
  int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (fd < 0) {
    *out_errno = errno;
    return -1;
  }
  int pmtud = IP_PMTUDISC_DONT;
  (void)setsockopt(fd, IPPROTO_IP, IP_MTU_DISCOVER, &pmtud, (socklen_t)sizeof(pmtud));
  int reuse = 1;
  (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, (socklen_t)sizeof(reuse));
  int sock_buf = 524288;
  (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sock_buf, (socklen_t)sizeof(sock_buf));
  (void)setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sock_buf, (socklen_t)sizeof(sock_buf));
  helper_protect_socket(fd, flags, fwmark, bind_iface);

  if (local_port != 0u) {
    struct sockaddr_in laddr;
    memset(&laddr, 0, sizeof(laddr));
    laddr.sin_family = AF_INET;
    laddr.sin_port = htons(local_port);
    if (bind(fd, (const struct sockaddr *)&laddr, (socklen_t)sizeof(laddr)) != 0) {
      *out_errno = errno;
      close(fd);
      return -1;
    }
  }

  struct sockaddr_in peer;
  memset(&peer, 0, sizeof(peer));
  peer.sin_family = AF_INET;
  memcpy(&peer.sin_addr.s_addr, peer_ip, 4u);
  peer.sin_port = htons(remote_port);
  if (connect(fd, (const struct sockaddr *)&peer, (socklen_t)sizeof(peer)) != 0) {
    *out_errno = errno;
    close(fd);
    return -1;
  }
  *out_errno = 0;
  return fd;
}

static void helper_handle_ctrl(uint8_t cmd, uint8_t status, const uint8_t *payload, size_t len, uint32_t flags,
                               uint32_t fwmark, const char *bind_iface, int *ike_fd, int *raw_fd,
                               uint8_t raw_peer_ip[4], int *xfrm_installed, tf_l2tp_xfrm_spec_t *xfrm_spec,
                               int *stream_mode, int *active_data_fd) {
  switch (cmd) {
  case TF_L2TP_CMD_OPEN_UDP: {
    if (len < 12u) {
      helper_send_err_reply(1u, (uint32_t)EINVAL);
      return;
    }
    if (*ike_fd >= 0) {
      close(*ike_fd);
      *ike_fd = -1;
    }
    uint16_t remote_port = helper_read_be16(payload + 4u);
    uint16_t local_port = helper_read_be16(payload + 6u);
    int allow_ephemeral = payload[8] != 0u;
    int err = 0;
    int fd = helper_open_udp_once(payload, remote_port, local_port, flags, fwmark, bind_iface, &err);
    if (fd < 0 && local_port != 0u && allow_ephemeral) {
      (void)dprintf(STDERR_FILENO, "l2tp bind(%u) failed errno=%d; retrying ephemeral\n", (unsigned)local_port, err);
      fd = helper_open_udp_once(payload, remote_port, 0u, flags, fwmark, bind_iface, &err);
    }
    if (fd < 0) {
      helper_send_err_reply(1u, (uint32_t)err);
      return;
    }
    *ike_fd = fd;
    uint8_t rep[12];
    helper_fill_local_reply(fd, rep);
    (void)helper_send_frame(STDOUT_FILENO, TF_L2TP_MSG_REPLY, 0u, rep, sizeof(rep));
    return;
  }
  case TF_L2TP_CMD_CONNECT_UDP: {
    if (*ike_fd < 0 || len < 8u) {
      helper_send_err_reply(1u, (uint32_t)EINVAL);
      return;
    }
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof(peer));
    peer.sin_family = AF_INET;
    memcpy(&peer.sin_addr.s_addr, payload, 4u);
    peer.sin_port = htons(helper_read_be16(payload + 4u));
    if (connect(*ike_fd, (const struct sockaddr *)&peer, (socklen_t)sizeof(peer)) != 0) {
      helper_send_err_reply(1u, (uint32_t)errno);
      return;
    }
    uint8_t rep[12];
    helper_fill_local_reply(*ike_fd, rep);
    (void)helper_send_frame(STDOUT_FILENO, TF_L2TP_MSG_REPLY, 0u, rep, sizeof(rep));
    return;
  }
  case TF_L2TP_CMD_UDP_SEND: {
    if (*ike_fd < 0 || len == 0u) {
      helper_send_err_reply(1u, (uint32_t)EINVAL);
      return;
    }
    ssize_t sent = send(*ike_fd, payload, len, 0);
    if (sent != (ssize_t)len) {
      helper_send_err_reply(1u, (uint32_t)(errno != 0 ? errno : EIO));
      return;
    }
    helper_send_err_reply(0u, 0u);
    return;
  }
  case TF_L2TP_CMD_UDP_RECV: {
    if (*ike_fd < 0 || len < 8u) {
      helper_send_err_reply(1u, (uint32_t)EINVAL);
      return;
    }
    int timeout_ms = (int)helper_read_be32(payload);
    int peek = payload[4] != 0u;
    struct pollfd pfd = {.fd = *ike_fd, .events = POLLIN};
    int pr = poll(&pfd, 1u, timeout_ms < 0 ? 0 : timeout_ms);
    if (pr < 0) {
      helper_send_err_reply(1u, (uint32_t)errno);
      return;
    }
    if (pr == 0) {
      helper_send_err_reply(1u, (uint32_t)ETIMEDOUT);
      return;
    }
    if ((pfd.revents & POLLIN) == 0 && (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
      int so_err = 0;
      socklen_t so_len = (socklen_t)sizeof(so_err);
      if (getsockopt(*ike_fd, SOL_SOCKET, SO_ERROR, &so_err, &so_len) != 0)
        so_err = EIO;
      helper_send_err_reply(1u, (uint32_t)(so_err != 0 ? so_err : EIO));
      return;
    }
    uint8_t rx[TF_L2TP_MAX_FRAME];
    ssize_t n = recv(*ike_fd, rx, sizeof(rx), peek ? MSG_PEEK : 0);
    if (n <= 0) {
      helper_send_err_reply(1u, (uint32_t)(n < 0 ? errno : ECONNRESET));
      return;
    }
    (void)helper_send_frame(STDOUT_FILENO, TF_L2TP_MSG_REPLY, 0u, rx, (size_t)n);
    return;
  }
  case TF_L2TP_CMD_SET_ENCAP: {
    if (*ike_fd < 0 || len < 4u) {
      helper_send_err_reply(1u, (uint32_t)EINVAL);
      return;
    }
    int encap = (int)helper_read_be32(payload);
    if (setsockopt(*ike_fd, IPPROTO_UDP, UDP_ENCAP, &encap, (socklen_t)sizeof(encap)) != 0) {
      helper_send_err_reply(1u, (uint32_t)errno);
      return;
    }
    helper_send_err_reply(0u, 0u);
    return;
  }
  case TF_L2TP_CMD_XFRM_INSTALL: {
    tf_l2tp_xfrm_spec_t spec;
    if (tf_l2tp_xfrm_spec_unpack(payload, len, &spec) != 0) {
      helper_send_err_reply(1u, (uint32_t)EINVAL);
      return;
    }
    if (*xfrm_installed) {
      tf_xfrm_delete_pair(xfrm_spec);
      *xfrm_installed = 0;
    }
    int xfrm_err = 0;
    if (tf_xfrm_install_pair(&spec, &xfrm_err) != 0) {
      helper_send_err_reply(1u, (uint32_t)(xfrm_err != 0 ? xfrm_err : EIO));
      return;
    }
    *xfrm_spec = spec;
    *xfrm_installed = 1;
    helper_send_err_reply(0u, 0u);
    return;
  }
  case TF_L2TP_CMD_XFRM_DELETE:
    if (*xfrm_installed) {
      tf_xfrm_delete_pair(xfrm_spec);
      *xfrm_installed = 0;
    }
    helper_send_err_reply(0u, 0u);
    return;
  case TF_L2TP_CMD_OPEN_RAW_ESP: {
    if (len < 4u) {
      helper_send_err_reply(1u, (uint32_t)EINVAL);
      return;
    }
    if (*raw_fd >= 0) {
      close(*raw_fd);
      *raw_fd = -1;
    }
    int fd = socket(AF_INET, SOCK_RAW, IPPROTO_ESP);
    if (fd < 0) {
      helper_send_err_reply(1u, (uint32_t)errno);
      return;
    }
    helper_protect_socket(fd, flags, fwmark, bind_iface);
    struct sockaddr_in peer;
    memset(&peer, 0, sizeof(peer));
    peer.sin_family = AF_INET;
    memcpy(&peer.sin_addr.s_addr, payload, 4u);
    if (connect(fd, (const struct sockaddr *)&peer, (socklen_t)sizeof(peer)) != 0) {
      int err = errno;
      close(fd);
      helper_send_err_reply(1u, (uint32_t)err);
      return;
    }
    memcpy(raw_peer_ip, payload, 4u);
    *raw_fd = fd;
    helper_send_err_reply(0u, 0u);
    return;
  }
  case TF_L2TP_CMD_START_STREAM: {
    int want_raw = status != 0u;
    int dfd = want_raw ? *raw_fd : *ike_fd;
    if (dfd < 0) {
      helper_send_err_reply(1u, (uint32_t)EBADF);
      return;
    }
    helper_send_err_reply(0u, 0u);
    helper_set_nonblock(STDIN_FILENO);
    helper_set_nonblock(STDOUT_FILENO);
    helper_set_nonblock(dfd);
    *active_data_fd = dfd;
    *stream_mode = want_raw ? 2 : 1;
    return;
  }
  case TF_L2TP_CMD_STOP:
    if (*xfrm_installed) {
      tf_xfrm_delete_pair(xfrm_spec);
      *xfrm_installed = 0;
    }
    helper_send_err_reply(0u, 0u);
    g_helper_stop = 1;
    return;
  default:
    helper_send_err_reply(1u, (uint32_t)ENOSYS);
    return;
  }
}

int main(void) {
  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, helper_on_signal);
  signal(SIGINT, helper_on_signal);

  uint8_t hdr[TF_L2TP_FRAME_HDR_LEN];
  if (helper_read_exact(STDIN_FILENO, hdr, sizeof(hdr)) != 0 || hdr[0] != TF_L2TP_CMD_INIT) {
    helper_send_err_reply(1u, (uint32_t)EINVAL);
    return 2;
  }
  uint16_t init_len = helper_read_be16(hdr + 2u);
  uint8_t init_buf[TF_L2TP_INIT_PAYLOAD_LEN];
  if (init_len != sizeof(init_buf) || helper_read_exact(STDIN_FILENO, init_buf, sizeof(init_buf)) != 0) {
    helper_send_err_reply(1u, (uint32_t)EINVAL);
    return 2;
  }
  if (init_buf[0] != TF_L2TP_HELPER_MAGIC0 || init_buf[1] != TF_L2TP_HELPER_MAGIC1 ||
      init_buf[2] != TF_L2TP_HELPER_MAGIC2 || init_buf[3] != TF_L2TP_HELPER_MAGIC3) {
    helper_send_err_reply(1u, (uint32_t)EINVAL);
    return 2;
  }
  uint32_t flags = helper_read_be32(init_buf + 4u);
  uint32_t fwmark = helper_read_be32(init_buf + 8u);
  char bind_iface[24];
  memcpy(bind_iface, init_buf + 12u, sizeof(bind_iface));
  bind_iface[sizeof(bind_iface) - 1u] = '\0';
  helper_send_err_reply(0u, 0u);

  int ike_fd = -1;
  int raw_fd = -1;
  int active_data_fd = -1;
  int stream_mode = 0; /* 0 = ctrl RPC, 1 = UDP 4500 stream, 2 = SOCK_RAW ESP stream */
  int xfrm_installed = 0;
  tf_l2tp_xfrm_spec_t xfrm_spec;
  memset(&xfrm_spec, 0, sizeof(xfrm_spec));
  uint8_t raw_peer_ip[4] = {0, 0, 0, 0};

  uint8_t ctrl_buf[TF_L2TP_MAX_FRAME];
  while (!g_helper_stop && stream_mode == 0) {
    if (xfrm_installed && ike_fd >= 0) {
      struct pollfd cfds[2];
      cfds[0].fd = STDIN_FILENO;
      cfds[0].events = POLLIN;
      cfds[1].fd = ike_fd;
      cfds[1].events = POLLIN;
      int cpr = poll(cfds, 2u, 1000);
      if (cpr < 0) {
        if (errno == EINTR)
          continue;
        break;
      }
      if ((cfds[1].revents & POLLIN) != 0) {
        for (int drain = 0; drain < 32; drain++) {
          if (recv(ike_fd, ctrl_buf, sizeof(ctrl_buf), MSG_DONTWAIT) <= 0)
            break;
        }
      }
      if ((cfds[0].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) == 0)
        continue;
    }
    if (helper_read_exact(STDIN_FILENO, hdr, sizeof(hdr)) != 0)
      break;
    uint16_t plen = helper_read_be16(hdr + 2u);
    if (plen > sizeof(ctrl_buf)) {
      helper_send_err_reply(1u, (uint32_t)EMSGSIZE);
      break;
    }
    if (plen > 0u && helper_read_exact(STDIN_FILENO, ctrl_buf, (size_t)plen) != 0)
      break;
    helper_handle_ctrl(hdr[0], hdr[1], ctrl_buf, (size_t)plen, flags, fwmark, bind_iface, &ike_fd, &raw_fd, raw_peer_ip,
                       &xfrm_installed, &xfrm_spec, &stream_mode, &active_data_fd);
  }

  uint8_t pipe_rx[16384];
  size_t pipe_rx_len = 0u;
  uint8_t raw_buf[65536];
  uint8_t out_frame[TF_L2TP_FRAME_HDR_LEN + TF_L2TP_MAX_FRAME];

  while (!g_helper_stop && stream_mode != 0 && active_data_fd >= 0) {
    struct pollfd fds[2];
    fds[0].fd = STDIN_FILENO;
    fds[0].events = POLLIN;
    fds[1].fd = active_data_fd;
    fds[1].events = POLLIN;
    int pr = poll(fds, 2u, 500);
    if (pr < 0) {
      if (errno == EINTR)
        continue;
      break;
    }
    if (pr == 0)
      continue;
    if ((fds[0].revents & (POLLHUP | POLLERR | POLLNVAL)) != 0 && (fds[0].revents & POLLIN) == 0)
      break;

    if ((fds[0].revents & POLLIN) != 0) {
      for (;;) {
        if (pipe_rx_len >= sizeof(pipe_rx)) {
          g_helper_stop = 1;
          break;
        }
        ssize_t n = read(STDIN_FILENO, pipe_rx + pipe_rx_len, sizeof(pipe_rx) - pipe_rx_len);
        if (n == 0) {
          g_helper_stop = 1;
          break;
        }
        if (n < 0) {
          if (errno == EINTR)
            continue;
          if (errno == EAGAIN || errno == EWOULDBLOCK)
            break;
          g_helper_stop = 1;
          break;
        }
        pipe_rx_len += (size_t)n;
        while (pipe_rx_len >= TF_L2TP_FRAME_HDR_LEN) {
          uint16_t flen = helper_read_be16(pipe_rx + 2u);
          if (flen > TF_L2TP_MAX_FRAME) {
            g_helper_stop = 1;
            break;
          }
          size_t total = TF_L2TP_FRAME_HDR_LEN + (size_t)flen;
          if (pipe_rx_len < total)
            break;
          uint8_t ftype = pipe_rx[0];
          uint8_t fstat = pipe_rx[1];
          const uint8_t *fpay = pipe_rx + TF_L2TP_FRAME_HDR_LEN;
          if (ftype == TF_L2TP_MSG_DATA && flen > 0u) {
            (void)send(active_data_fd, fpay, (size_t)flen, 0);
          } else if (ftype == TF_L2TP_MSG_IKE_SEND && ike_fd >= 0 && flen > 0u) {
            if (fstat != 0u && flen + 4u <= TF_L2TP_MAX_FRAME) {
              uint8_t wrapped[4u + TF_L2TP_MAX_FRAME];
              memset(wrapped, 0, 4u);
              memcpy(wrapped + 4u, fpay, (size_t)flen);
              (void)send(ike_fd, wrapped, (size_t)flen + 4u, 0);
            } else {
              (void)send(ike_fd, fpay, (size_t)flen, 0);
            }
          } else if (ftype == TF_L2TP_CMD_STOP) {
            g_helper_stop = 1;
            break;
          }
          pipe_rx_len -= total;
          if (pipe_rx_len > 0u)
            memmove(pipe_rx, pipe_rx + total, pipe_rx_len);
        }
        if (g_helper_stop)
          break;
      }
      if (g_helper_stop)
        break;
    }

    if ((fds[1].revents & (POLLERR | POLLNVAL)) != 0) {
      int so_err = 0;
      socklen_t so_len = (socklen_t)sizeof(so_err);
      (void)getsockopt(active_data_fd, SOL_SOCKET, SO_ERROR, &so_err, &so_len);
      if (so_err == ENETDOWN || so_err == ENETUNREACH || so_err == ENODEV)
        break;
    }

    if ((fds[1].revents & POLLIN) != 0) {
      for (int burst = 0; burst < 64; burst++) {
        ssize_t n = recv(active_data_fd, raw_buf, sizeof(raw_buf), 0);
        if (n < 0) {
          if (errno == EINTR)
            continue;
          if (errno == EAGAIN || errno == EWOULDBLOCK)
            break;
          break;
        }
        const uint8_t *pkt_ptr = raw_buf;
        size_t pkt_len = (size_t)n;
        if (stream_mode == 2) {
          if (n < 20)
            continue;
          if ((raw_buf[0] >> 4) != 4u)
            continue;
          size_t ihl = (size_t)(raw_buf[0] & 0x0fu) * 4u;
          if (ihl < 20u || ihl >= (size_t)n)
            continue;
          if (raw_buf[9] != (uint8_t)IPPROTO_ESP)
            continue;
          if (memcmp(raw_buf + 12u, raw_peer_ip, 4u) != 0)
            continue;
          uint16_t ip_total = helper_read_be16(raw_buf + 2u);
          size_t packet_end = (size_t)n;
          if (ip_total >= ihl && (size_t)ip_total <= (size_t)n)
            packet_end = (size_t)ip_total;
          pkt_ptr = raw_buf + ihl;
          pkt_len = packet_end - ihl;
        }
        if (pkt_len == 0u || pkt_len > TF_L2TP_MAX_FRAME)
          continue;
        out_frame[0] = TF_L2TP_MSG_DATA;
        out_frame[1] = 0u;
        helper_write_be16(out_frame + 2u, (uint16_t)pkt_len);
        memcpy(out_frame + TF_L2TP_FRAME_HDR_LEN, pkt_ptr, pkt_len);
        int wrc = helper_write_frame_nonblock(STDOUT_FILENO, out_frame, TF_L2TP_FRAME_HDR_LEN + pkt_len);
        if (wrc < 0) {
          g_helper_stop = 1;
          break;
        }
        if (wrc > 0)
          break;
      }
    }
  }

  if (xfrm_installed)
    tf_xfrm_delete_pair(&xfrm_spec);
  if (raw_fd >= 0)
    close(raw_fd);
  if (ike_fd >= 0)
    close(ike_fd);
  return 0;
}
