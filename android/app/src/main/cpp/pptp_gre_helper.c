/*
 * Minimal root helper executable (packaged as libpptp_gre_helper.so) invoked via su.
 * Opens a raw IPPROTO_GRE socket (CAP_NET_RAW), optionally applies VPN-bypass socket
 * options (SO_MARK + SO_BINDTODEVICE), and bridges length-prefixed GRE frames over
 * stdin/stdout pipes with the unprivileged TunnelForge app process.
 */
#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef IPPROTO_GRE
#define IPPROTO_GRE 47
#endif

#define HELPER_MAGIC_0 'T'
#define HELPER_MAGIC_1 'F'
#define HELPER_MAGIC_2 'G'
#define HELPER_MAGIC_3 '1'

#define HELPER_INIT_LEN 40u
#define HELPER_REPLY_LEN 12u
#define HELPER_MAX_FRAME 4096u
#define HELPER_FLAG_PROTECT_VPN 1u

#define HELPER_STATUS_OK 0u
#define HELPER_STATUS_SOCKET_FAIL 1u
#define HELPER_STATUS_CONNECT_FAIL 2u
#define HELPER_STATUS_BAD_INIT 3u

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
      int pr = poll(&pfd, 1, 1000);
      if (pr <= 0)
        return -1;
      continue;
    }
    return -1;
  }
  return off == len ? 0 : -1;
}

/* Non-blocking frame write for data plane: returns 0 written, 1 dropped (pipe full before any byte), -1 fatal. */
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
      int pr = poll(&pfd, 1, 200);
      if (pr <= 0)
        return -1;
      continue;
    }
    return -1;
  }
  return off == len ? 0 : -1;
}

static void helper_send_reply(uint32_t status, uint32_t err_no) {
  uint8_t reply[HELPER_REPLY_LEN];
  reply[0] = HELPER_MAGIC_0;
  reply[1] = HELPER_MAGIC_1;
  reply[2] = HELPER_MAGIC_2;
  reply[3] = HELPER_MAGIC_3;
  helper_write_be32(reply + 4u, status);
  helper_write_be32(reply + 8u, err_no);
  (void)helper_write_all(STDOUT_FILENO, reply, sizeof(reply));
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

int main(void) {
  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, helper_on_signal);
  signal(SIGINT, helper_on_signal);

  uint8_t init[HELPER_INIT_LEN];
  if (helper_read_exact(STDIN_FILENO, init, sizeof(init)) != 0) {
    helper_send_reply(HELPER_STATUS_BAD_INIT, (uint32_t)errno);
    return 2;
  }
  if (init[0] != HELPER_MAGIC_0 || init[1] != HELPER_MAGIC_1 || init[2] != HELPER_MAGIC_2 ||
      init[3] != HELPER_MAGIC_3) {
    helper_send_reply(HELPER_STATUS_BAD_INIT, (uint32_t)EINVAL);
    return 2;
  }

  uint8_t peer_ipv4[4];
  memcpy(peer_ipv4, init + 4u, 4u);
  uint32_t flags = helper_read_be32(init + 8u);
  uint32_t fwmark = helper_read_be32(init + 12u);
  char bind_iface[24];
  memcpy(bind_iface, init + 16u, sizeof(bind_iface));
  bind_iface[sizeof(bind_iface) - 1u] = '\0';

  int gre_fd = socket(AF_INET, SOCK_RAW, IPPROTO_GRE);
  if (gre_fd < 0) {
    helper_send_reply(HELPER_STATUS_SOCKET_FAIL, (uint32_t)errno);
    return 3;
  }

  if ((flags & HELPER_FLAG_PROTECT_VPN) != 0u) {
    if (fwmark != 0u) {
      int mark = (int)fwmark;
      if (setsockopt(gre_fd, SOL_SOCKET, SO_MARK, &mark, (socklen_t)sizeof(mark)) != 0)
        (void)dprintf(STDERR_FILENO, "SO_MARK errno=%d\n", errno);
    }
    if (helper_is_safe_iface(bind_iface) &&
        setsockopt(gre_fd, SOL_SOCKET, SO_BINDTODEVICE, bind_iface, (socklen_t)(strlen(bind_iface) + 1u)) != 0)
      (void)dprintf(STDERR_FILENO, "SO_BINDTODEVICE errno=%d\n", errno);
  }

  struct sockaddr_in peer;
  memset(&peer, 0, sizeof(peer));
  peer.sin_family = AF_INET;
  memcpy(&peer.sin_addr, peer_ipv4, 4u);
  if (connect(gre_fd, (const struct sockaddr *)&peer, (socklen_t)sizeof(peer)) != 0) {
    int err = errno;
    close(gre_fd);
    helper_send_reply(HELPER_STATUS_CONNECT_FAIL, (uint32_t)err);
    return 4;
  }

  helper_send_reply(HELPER_STATUS_OK, 0u);

  helper_set_nonblock(STDIN_FILENO);
  helper_set_nonblock(STDOUT_FILENO);
  helper_set_nonblock(gre_fd);

  uint8_t pipe_rx[8192];
  size_t pipe_rx_len = 0u;
  uint8_t raw_buf[65536];
  uint8_t out_frame[2u + HELPER_MAX_FRAME];

  while (!g_helper_stop) {
    struct pollfd fds[2];
    fds[0].fd = STDIN_FILENO;
    fds[0].events = POLLIN;
    fds[1].fd = gre_fd;
    fds[1].events = POLLIN;

    int pr = poll(fds, 2u, 500);
    if (pr < 0) {
      if (errno == EINTR)
        continue;
      break;
    }
    if (pr == 0)
      continue;

    if ((fds[0].revents & (POLLHUP | POLLERR | POLLNVAL)) != 0 && (fds[0].revents & POLLIN) == 0) {
      break;
    }

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
        while (pipe_rx_len >= 2u) {
          uint16_t flen = helper_read_be16(pipe_rx);
          if (flen == 0u || flen > HELPER_MAX_FRAME) {
            g_helper_stop = 1;
            break;
          }
          if (pipe_rx_len < 2u + (size_t)flen)
            break;
          (void)send(gre_fd, pipe_rx + 2u, (size_t)flen, 0);
          size_t consumed = 2u + (size_t)flen;
          pipe_rx_len -= consumed;
          if (pipe_rx_len > 0u)
            memmove(pipe_rx, pipe_rx + consumed, pipe_rx_len);
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
      (void)getsockopt(gre_fd, SOL_SOCKET, SO_ERROR, &so_err, &so_len);
      if (so_err == ENETDOWN || so_err == ENETUNREACH || so_err == ENODEV)
        break;
    }

    if ((fds[1].revents & POLLIN) != 0) {
      for (int burst = 0; burst < 64; burst++) {
        ssize_t n = recv(gre_fd, raw_buf, sizeof(raw_buf), 0);
        if (n < 0) {
          if (errno == EINTR)
            continue;
          if (errno == EAGAIN || errno == EWOULDBLOCK)
            break;
          break;
        }
        if (n < 20)
          continue;
        if ((raw_buf[0] >> 4) != 4u)
          continue;
        size_t ihl = (size_t)(raw_buf[0] & 0x0fu) * 4u;
        if (ihl < 20u || ihl >= (size_t)n)
          continue;
        if (raw_buf[9] != (uint8_t)IPPROTO_GRE)
          continue;
        if (memcmp(raw_buf + 12u, peer_ipv4, 4u) != 0)
          continue;
        uint16_t ip_total = helper_read_be16(raw_buf + 2u);
        size_t packet_end = (size_t)n;
        if (ip_total >= ihl && (size_t)ip_total <= (size_t)n)
          packet_end = (size_t)ip_total;
        size_t gre_len = packet_end - ihl;
        if (gre_len == 0u || gre_len > HELPER_MAX_FRAME)
          continue;
        helper_write_be16(out_frame, (uint16_t)gre_len);
        memcpy(out_frame + 2u, raw_buf + ihl, gre_len);
        int wrc = helper_write_frame_nonblock(STDOUT_FILENO, out_frame, 2u + gre_len);
        if (wrc < 0) {
          g_helper_stop = 1;
          break;
        }
        if (wrc > 0) {
          break;
        }
      }
    }
  }

  close(gre_fd);
  return 0;
}
