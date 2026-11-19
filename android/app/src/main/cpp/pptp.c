/*
 * RFC 2637 PPTP control channel over TCP 1723 and GRE transport helpers.
 */
#include "pptp.h"

#include "engine.h"
#include "util_endian.h"

#include <android/log.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define LOG_TAG "tunnel_engine"

#define PPTP_SCCRQ_LEN 156u
#define PPTP_SCCRP_LEN 156u
#define PPTP_STOPCCRQ_LEN 16u
#define PPTP_STOPCCRP_LEN 16u
#define PPTP_ECHORQ_LEN 16u
#define PPTP_ECHORP_LEN 20u
#define PPTP_OCRQ_LEN 168u
#define PPTP_OCRP_LEN 32u
#define PPTP_CCRQ_LEN 16u
#define PPTP_CDN_LEN 148u
#define PPTP_SLI_LEN 24u

static int64_t pptp_now_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    return (int64_t)time(NULL) * 1000LL;
  return (int64_t)ts.tv_sec * 1000LL + (int64_t)(ts.tv_nsec / 1000000LL);
}

static uint16_t pptp_random_u16_nonzero(void) {
  uint16_t v = 0u;
  int fd = open("/dev/urandom", O_RDONLY);
  if (fd >= 0) {
    (void)read(fd, &v, sizeof(v));
    close(fd);
  }
  if (v == 0u)
    v = (uint16_t)((time(NULL) & 0x7fffu) | 1u);
  return v;
}

void pptp_session_init(pptp_session_t *s) {
  if (s == NULL)
    return;
  memset(s, 0, sizeof(*s));
  s->ctrl_fd = -1;
  pptp_root_init(&s->root);
}

static int pptp_send_all_tcp(int fd, const uint8_t *buf, size_t len) {
  size_t off = 0u;
  while (off < len) {
    ssize_t n = send(fd, buf + off, len - off, MSG_NOSIGNAL);
    if (n > 0) {
      off += (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR)
      continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      struct pollfd pfd = {.fd = fd, .events = POLLOUT};
      int pr = poll(&pfd, 1, 2000);
      if (pr <= 0) {
        if (pr == 0)
          errno = ETIMEDOUT;
        return -1;
      }
      continue;
    }
    return -1;
  }
  return 0;
}

static int pptp_pop_control_message(pptp_session_t *s, uint8_t *msg_out, size_t cap, uint16_t *ctrl_type_out) {
  if (s->ctrl_rx_len < 12u)
    return 0;
  uint16_t msg_len = 0u;
  uint16_t ctrl_type = 0u;
  if (pptp_parse_control_header(s->ctrl_rx, s->ctrl_rx_len, &msg_len, &ctrl_type) < 0 || msg_len > sizeof(s->ctrl_rx)) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp ctrl: malformed control header len=%u", (unsigned)msg_len);
    errno = EPROTO;
    return -1;
  }
  if (s->ctrl_rx_len < (size_t)msg_len)
    return 0;
  if ((size_t)msg_len > cap) {
    errno = EMSGSIZE;
    return -1;
  }
  memcpy(msg_out, s->ctrl_rx, (size_t)msg_len);
  s->ctrl_rx_len -= (size_t)msg_len;
  if (s->ctrl_rx_len > 0u)
    memmove(s->ctrl_rx, s->ctrl_rx + msg_len, s->ctrl_rx_len);
  if (ctrl_type_out != NULL)
    *ctrl_type_out = ctrl_type;
  return (int)msg_len;
}

static int pptp_recv_control_message(pptp_session_t *s, uint8_t *msg_out, size_t cap, uint16_t *ctrl_type_out,
                                     int timeout_ms) {
  int64_t deadline = pptp_now_ms() + (int64_t)timeout_ms;
  for (;;) {
    int popped = pptp_pop_control_message(s, msg_out, cap, ctrl_type_out);
    if (popped != 0)
      return popped;
    if (tunnel_should_stop())
      return -1;
    int64_t rem = deadline - pptp_now_ms();
    if (rem <= 0) {
      errno = ETIMEDOUT;
      return -1;
    }
    int slice = rem > 200 ? 200 : (int)rem;
    struct pollfd pfd = {.fd = s->ctrl_fd, .events = POLLIN};
    int pr = poll(&pfd, 1, slice);
    if (pr < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    if (pr == 0)
      continue;
    if (s->ctrl_rx_len >= sizeof(s->ctrl_rx)) {
      errno = EMSGSIZE;
      return -1;
    }
    ssize_t n = recv(s->ctrl_fd, s->ctrl_rx + s->ctrl_rx_len, sizeof(s->ctrl_rx) - s->ctrl_rx_len, 0);
    if (n == 0) {
      errno = ECONNRESET;
      return -1;
    }
    if (n < 0) {
      if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
        continue;
      return -1;
    }
    s->ctrl_rx_len += (size_t)n;
  }
}

static int pptp_handle_runtime_msg(pptp_session_t *s, const uint8_t *msg, size_t msg_len, uint16_t ctrl_type) {
  if (ctrl_type == PPTP_CTRL_ECHORQ && msg_len >= PPTP_ECHORQ_LEN) {
    uint32_t id = util_read_be32(msg + 12u);
    uint8_t rsp[PPTP_ECHORP_LEN];
    int rlen = pptp_build_echo_reply(rsp, sizeof(rsp), id);
    if (rlen > 0 && pptp_send_all_tcp(s->ctrl_fd, rsp, (size_t)rlen) != 0)
      return PPTP_DISPATCH_ERROR;
    tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "pptp ctrl: answered Echo-Request id=%u", id);
    return PPTP_DISPATCH_INBOUND_ACTIVITY;
  }
  if (ctrl_type == PPTP_CTRL_ECHORP && msg_len >= PPTP_ECHORP_LEN) {
    tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "pptp ctrl: Echo-Reply id=%u result=%u", util_read_be32(msg + 12u),
                      (unsigned)msg[16]);
    return PPTP_DISPATCH_INBOUND_ACTIVITY;
  }
  if (ctrl_type == PPTP_CTRL_CDN && msg_len >= 18u) {
    uint8_t result = msg[14];
    uint8_t err = msg[15];
    tunnel_set_failure(TUNNEL_FAILURE_PPTP_CDN, (int)result, (int)err);
    tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "pptp ctrl: peer Call-Disconnect-Notify result=%u error=%u",
                      (unsigned)result, (unsigned)err);
    return PPTP_DISPATCH_REMOTE_CLOSED;
  }
  if (ctrl_type == PPTP_CTRL_STOPCCRQ && msg_len >= PPTP_STOPCCRQ_LEN) {
    uint8_t reason = msg[12];
    uint8_t rsp[PPTP_STOPCCRP_LEN];
    int rlen = pptp_build_stopccrp(rsp, sizeof(rsp));
    if (rlen > 0)
      (void)pptp_send_all_tcp(s->ctrl_fd, rsp, (size_t)rlen);
    tunnel_set_failure(TUNNEL_FAILURE_PPTP_CTRL, (int)reason, 0);
    tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "pptp ctrl: peer Stop-Control-Connection-Request reason=%u",
                      (unsigned)reason);
    return PPTP_DISPATCH_REMOTE_CLOSED;
  }
  if (ctrl_type == PPTP_CTRL_SLI || ctrl_type == PPTP_CTRL_WEN) {
    tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "pptp ctrl: ignored info msg type=%u len=%zu", (unsigned)ctrl_type,
                      msg_len);
    return PPTP_DISPATCH_OK;
  }
  tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "pptp ctrl: unhandled msg type=%u len=%zu", (unsigned)ctrl_type,
                    msg_len);
  return PPTP_DISPATCH_OK;
}

static int pptp_connect_tcp(const char *server, uint8_t peer_ipv4_out[4]) {
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;

  struct addrinfo *res = NULL;
  char portbuf[8];
  snprintf(portbuf, sizeof(portbuf), "%u", (unsigned)PPTP_CTRL_PORT);
  int r = getaddrinfo(server, portbuf, &hints, &res);
  if (r != 0 || res == NULL) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp: resolve failed host=%s err=%s", server,
                      r ? gai_strerror(r) : "null");
    return -1;
  }

  struct sockaddr_in peer_sin;
  memset(&peer_sin, 0, sizeof(peer_sin));
  if (res->ai_addrlen < sizeof(peer_sin) || res->ai_family != AF_INET) {
    freeaddrinfo(res);
    return -1;
  }
  memcpy(&peer_sin, res->ai_addr, sizeof(peer_sin));
  freeaddrinfo(res);

  memcpy(peer_ipv4_out, &peer_sin.sin_addr, 4u);

  int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (fd < 0) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp: socket() failed errno=%d", errno);
    return -1;
  }

  int one = 1;
  (void)setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, (socklen_t)sizeof(one));

  if (util_protect_fd(fd) != 0) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp: util_protect_fd failed for TCP control socket");
    close(fd);
    return -1;
  }

  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) {
    close(fd);
    return -1;
  }

  int cr = connect(fd, (const struct sockaddr *)&peer_sin, (socklen_t)sizeof(peer_sin));
  if (cr != 0 && errno != EINPROGRESS) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp: TCP 1723 connect failed errno=%d", errno);
    close(fd);
    return -1;
  }

  if (cr != 0) {
    int64_t deadline = pptp_now_ms() + 10000LL;
    for (;;) {
      if (tunnel_should_stop()) {
        close(fd);
        return -1;
      }
      int64_t rem = deadline - pptp_now_ms();
      if (rem <= 0) {
        tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp: TCP 1723 connect timed out");
        close(fd);
        return -1;
      }
      int slice = rem > 200 ? 200 : (int)rem;
      struct pollfd pfd = {.fd = fd, .events = POLLOUT};
      int pr = poll(&pfd, 1, slice);
      if (pr < 0) {
        if (errno == EINTR)
          continue;
        close(fd);
        return -1;
      }
      if (pr == 0)
        continue;
      int so_err = 0;
      socklen_t so_len = (socklen_t)sizeof(so_err);
      if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &so_len) != 0 || so_err != 0) {
        tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp: TCP 1723 connect error so_err=%d", so_err);
        close(fd);
        return -1;
      }
      break;
    }
  }

  tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "pptp: TCP 1723 connected");
  return fd;
}

int pptp_connect(const char *server, pptp_session_t *s) {
  if (server == NULL || s == NULL)
    return -1;
  pptp_session_init(s);

  int fd = pptp_connect_tcp(server, s->peer_ipv4);
  if (fd < 0)
    return -1;
  s->ctrl_fd = fd;

  /* 1. Start-Control-Connection-Request / Reply */
  uint8_t tx[256];
  int tlen = pptp_build_sccrq(tx, sizeof(tx));
  if (tlen < 0 || pptp_send_all_tcp(s->ctrl_fd, tx, (size_t)tlen) != 0) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp: failed sending SCCRQ errno=%d", errno);
    pptp_close(s, 0);
    return -1;
  }

  uint8_t rx[2048];
  uint16_t ctrl_type = 0u;
  int got_sccrp = 0;
  for (int i = 0; i < 8 && !got_sccrp; i++) {
    int n = pptp_recv_control_message(s, rx, sizeof(rx), &ctrl_type, 8000);
    if (n < 0) {
      tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp: failed waiting for SCCRP errno=%d", errno);
      pptp_close(s, 0);
      return -1;
    }
    if (ctrl_type == PPTP_CTRL_SCCRP && n >= (int)PPTP_SCCRP_LEN) {
      uint8_t result = rx[14];
      uint8_t err = rx[15];
      if (result != 1u) {
        tunnel_set_failure(TUNNEL_FAILURE_PPTP_CTRL, (int)result, (int)err);
        tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp: SCCRP rejected result=%u error=%u", (unsigned)result,
                          (unsigned)err);
        pptp_close(s, 0);
        return -1;
      }
      got_sccrp = 1;
      tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "pptp: SCCRP accepted");
    } else {
      int rc = pptp_handle_runtime_msg(s, rx, (size_t)n, ctrl_type);
      if (rc == PPTP_DISPATCH_REMOTE_CLOSED || rc == PPTP_DISPATCH_ERROR) {
        pptp_close(s, 0);
        return -1;
      }
    }
  }
  if (!got_sccrp) {
    pptp_close(s, 0);
    return -1;
  }

  /* 2. Outgoing-Call-Request / Reply */
  s->local_call_id = pptp_random_u16_nonzero();
  s->call_serial = 1u;
  tlen = pptp_build_ocrq(tx, sizeof(tx), s->local_call_id, s->call_serial);
  if (tlen < 0 || pptp_send_all_tcp(s->ctrl_fd, tx, (size_t)tlen) != 0) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp: failed sending OCRQ errno=%d", errno);
    pptp_close(s, 1);
    return -1;
  }

  int got_ocrp = 0;
  for (int i = 0; i < 8 && !got_ocrp; i++) {
    int n = pptp_recv_control_message(s, rx, sizeof(rx), &ctrl_type, 8000);
    if (n < 0) {
      tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp: failed waiting for OCRP errno=%d", errno);
      pptp_close(s, 1);
      return -1;
    }
    if (ctrl_type == PPTP_CTRL_OCRP && n >= (int)PPTP_OCRP_LEN) {
      uint16_t remote_cid = util_read_be16(rx + 12u);
      uint16_t peer_cid = util_read_be16(rx + 14u);
      uint8_t result = rx[16];
      uint8_t err = rx[17];
      if (peer_cid != s->local_call_id) {
        tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "pptp: OCRP peer_call_id mismatch got=%u want=%u",
                          (unsigned)peer_cid, (unsigned)s->local_call_id);
        continue;
      }
      if (result != 1u) {
        tunnel_set_failure(TUNNEL_FAILURE_PPTP_CALL, (int)result, (int)err);
        tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp: OCRP rejected result=%u error=%u", (unsigned)result,
                          (unsigned)err);
        pptp_close(s, 1);
        return -1;
      }
      s->remote_call_id = remote_cid;
      s->call_established = 1;
      got_ocrp = 1;
      tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "pptp: OCRP connected local_call=%u remote_call=%u",
                        (unsigned)s->local_call_id, (unsigned)s->remote_call_id);
    } else {
      int rc = pptp_handle_runtime_msg(s, rx, (size_t)n, ctrl_type);
      if (rc == PPTP_DISPATCH_REMOTE_CLOSED || rc == PPTP_DISPATCH_ERROR) {
        pptp_close(s, 0);
        return -1;
      }
    }
  }
  if (!got_ocrp) {
    pptp_close(s, 1);
    return -1;
  }

  /* 3. Initial Set-Link-Info + GRE state init */
  tlen = pptp_build_sli(tx, sizeof(tx), s->remote_call_id, 0xffffffffu, 0xffffffffu);
  if (tlen > 0)
    (void)pptp_send_all_tcp(s->ctrl_fd, tx, (size_t)tlen);

  pptp_gre_init(&s->gre, s->local_call_id, s->remote_call_id);
  return 0;
}

int pptp_start_gre_helper(pptp_session_t *s, const char *helper_path, int protect_vpn, const char *bind_iface) {
  if (s == NULL)
    return TUNNEL_EXIT_BAD_ARGS;
  return pptp_root_start(&s->root, helper_path, s->peer_ipv4, protect_vpn, bind_iface);
}

int pptp_send_ppp(pptp_session_t *s, const uint8_t *ppp, size_t ppp_len) {
  if (s == NULL || ppp == NULL || ppp_len == 0u) {
    errno = EINVAL;
    return -1;
  }
  uint8_t gre[4096];
  int glen = pptp_gre_build_data(&s->gre, ppp, ppp_len, gre, sizeof(gre));
  if (glen <= 0) {
    errno = EMSGSIZE;
    return -1;
  }
  return pptp_root_send_gre(&s->root, gre, (size_t)glen);
}

int pptp_flush_gre_ack(pptp_session_t *s) {
  if (s == NULL)
    return 0;
  uint8_t ack[PPTP_GRE_MAX_HEADER_LEN];
  int alen = pptp_gre_build_ack(&s->gre, ack, sizeof(ack));
  if (alen <= 0)
    return 0;
  return pptp_root_send_gre(&s->root, ack, (size_t)alen);
}

int pptp_dispatch_control(pptp_session_t *s) {
  if (s == NULL || s->ctrl_fd < 0)
    return PPTP_DISPATCH_ERROR;

  int saw_activity = 0;
  for (;;) {
    if (s->ctrl_rx_len < sizeof(s->ctrl_rx)) {
      ssize_t n = recv(s->ctrl_fd, s->ctrl_rx + s->ctrl_rx_len, sizeof(s->ctrl_rx) - s->ctrl_rx_len, 0);
      if (n == 0) {
        errno = ECONNRESET;
        return PPTP_DISPATCH_ERROR;
      }
      if (n < 0) {
        if (errno == EINTR)
          continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK)
          return PPTP_DISPATCH_ERROR;
      } else {
        s->ctrl_rx_len += (size_t)n;
      }
    }

    uint8_t msg[2048];
    uint16_t ctrl_type = 0u;
    int popped = pptp_pop_control_message(s, msg, sizeof(msg), &ctrl_type);
    if (popped < 0)
      return PPTP_DISPATCH_ERROR;
    if (popped == 0)
      break;
    int rc = pptp_handle_runtime_msg(s, msg, (size_t)popped, ctrl_type);
    if (rc == PPTP_DISPATCH_REMOTE_CLOSED || rc == PPTP_DISPATCH_ERROR)
      return rc;
    if (rc == PPTP_DISPATCH_INBOUND_ACTIVITY)
      saw_activity = 1;
  }
  return saw_activity ? PPTP_DISPATCH_INBOUND_ACTIVITY : PPTP_DISPATCH_OK;
}

int pptp_send_echo_request(pptp_session_t *s) {
  if (s == NULL || s->ctrl_fd < 0) {
    errno = EBADF;
    return -1;
  }
  uint8_t req[PPTP_ECHORQ_LEN];
  int len = pptp_build_echo_request(req, sizeof(req), ++s->echo_id);
  if (len <= 0)
    return -1;
  return pptp_send_all_tcp(s->ctrl_fd, req, (size_t)len);
}

void pptp_send_teardown(pptp_session_t *s) {
  if (s == NULL || s->ctrl_fd < 0)
    return;
  uint8_t pkt[32];
  if (s->call_established) {
    int len = pptp_build_ccrq(pkt, sizeof(pkt), s->local_call_id);
    if (len > 0)
      (void)pptp_send_all_tcp(s->ctrl_fd, pkt, (size_t)len);
    s->call_established = 0;
  }
  int slen = pptp_build_stopccrq(pkt, sizeof(pkt), 1u);
  if (slen > 0)
    (void)pptp_send_all_tcp(s->ctrl_fd, pkt, (size_t)slen);
}

void pptp_close(pptp_session_t *s, int send_teardown) {
  if (s == NULL)
    return;
  if (send_teardown && s->ctrl_fd >= 0)
    pptp_send_teardown(s);
  pptp_root_stop(&s->root);
  if (s->ctrl_fd >= 0) {
    close(s->ctrl_fd);
    s->ctrl_fd = -1;
  }
  s->call_established = 0;
  s->ctrl_rx_len = 0u;
}
