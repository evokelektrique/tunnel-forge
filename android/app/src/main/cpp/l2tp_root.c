/*
 * Unprivileged-side IPC client for the root-spawned libl2tp_root_helper.so process.
 * Handles su discovery (Magisk/KernelSU/APatch), binary control RPC, and framed Tier 2a/2b streams.
 */
#include "l2tp_root.h"

#include "engine.h"
#include "root_detect.h"
#include "util_endian.h"

#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LOG_TAG "tunnel_engine"

#if !defined(__ANDROID__) && !defined(_GNU_SOURCE)
extern char **environ;
#endif

void l2tp_root_init(l2tp_root_t *r) {
  if (r == NULL)
    return;
  memset(r, 0, sizeof(*r));
  r->pid = -1;
  r->to_helper_fd = -1;
  r->from_helper_fd = -1;
  r->err_fd = -1;
}

static void drain_helper_stderr(int err_fd, char *out, size_t cap) {
  if (out == NULL || cap == 0u)
    return;
  out[0] = '\0';
  if (err_fd < 0)
    return;
  size_t off = 0u;
  while (off + 1u < cap) {
    ssize_t n = read(err_fd, out + off, cap - 1u - off);
    if (n <= 0)
      break;
    off += (size_t)n;
  }
  out[off] = '\0';
  while (off > 0u && (out[off - 1u] == '\n' || out[off - 1u] == '\r')) {
    out[--off] = '\0';
  }
}

static int l2tp_root_write_frame(int fd, uint8_t type, uint8_t status, const uint8_t *payload, size_t len) {
  if (fd < 0 || len > TF_L2TP_MAX_FRAME) {
    errno = EINVAL;
    return -1;
  }
  uint8_t frame[TF_L2TP_FRAME_HDR_LEN + TF_L2TP_MAX_FRAME];
  frame[0] = type;
  frame[1] = status;
  util_write_be16(frame + 2u, (uint16_t)len);
  if (len > 0u && payload != NULL)
    memcpy(frame + TF_L2TP_FRAME_HDR_LEN, payload, len);
  return tf_write_all_fd(fd, frame, TF_L2TP_FRAME_HDR_LEN + len);
}

static int l2tp_root_read_reply_frame(l2tp_root_t *r, uint8_t *status_out, uint8_t *payload_out, size_t cap,
                                      size_t *len_out, int timeout_ms, int check_stop) {
  if (r == NULL || r->from_helper_fd < 0)
    return -1;
  const int64_t deadline = tf_monotonic_ms() + (int64_t)timeout_ms;
  for (;;) {
    if (r->rx_len >= TF_L2TP_FRAME_HDR_LEN) {
      uint16_t flen = util_read_be16(r->rx_buf + 2u);
      if (flen > TF_L2TP_MAX_FRAME) {
        errno = EPROTO;
        return -1;
      }
      size_t total = TF_L2TP_FRAME_HDR_LEN + (size_t)flen;
      if (r->rx_len >= total) {
        uint8_t type = r->rx_buf[0];
        uint8_t st = r->rx_buf[1];
        if (type == TF_L2TP_MSG_REPLY) {
          if (status_out != NULL)
            *status_out = st;
          if (len_out != NULL)
            *len_out = (size_t)flen;
          if (payload_out != NULL && (size_t)flen > 0u) {
            if ((size_t)flen > cap) {
              errno = EMSGSIZE;
              return -1;
            }
            memcpy(payload_out, r->rx_buf + TF_L2TP_FRAME_HDR_LEN, (size_t)flen);
          }
          r->rx_len -= total;
          if (r->rx_len > 0u)
            memmove(r->rx_buf, r->rx_buf + total, r->rx_len);
          return 0;
        }
        r->rx_len -= total;
        if (r->rx_len > 0u)
          memmove(r->rx_buf, r->rx_buf + total, r->rx_len);
        continue;
      }
    }

    if (check_stop && tunnel_should_stop()) {
      errno = ECANCELED;
      return -1;
    }
    int64_t rem = deadline - tf_monotonic_ms();
    if (rem <= 0) {
      errno = ETIMEDOUT;
      return -1;
    }
    int slice = rem > 150 ? 150 : (int)rem;
    struct pollfd pfd = {.fd = r->from_helper_fd, .events = POLLIN};
    int pr = poll(&pfd, 1u, slice);
    if (pr < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    if (pr == 0)
      continue;
    if ((pfd.revents & POLLIN) == 0 && (pfd.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
      errno = EPIPE;
      return -1;
    }
    if (r->rx_len >= sizeof(r->rx_buf)) {
      errno = ENOBUFS;
      return -1;
    }
    ssize_t n = read(r->from_helper_fd, r->rx_buf + r->rx_len, sizeof(r->rx_buf) - r->rx_len);
    if (n == 0) {
      errno = EPIPE;
      return -1;
    }
    if (n < 0) {
      if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
        continue;
      return -1;
    }
    r->rx_len += (size_t)n;
  }
}

static int l2tp_root_rpc_ex(l2tp_root_t *r, uint8_t cmd, uint8_t flag, const uint8_t *req, size_t req_len,
                            uint8_t *reply_buf, size_t reply_cap, size_t *reply_len_out, int timeout_ms, int check_stop,
                            int *out_errno) {
  if (out_errno != NULL)
    *out_errno = 0;
  if (r == NULL || r->to_helper_fd < 0 || r->stream_active) {
    if (out_errno != NULL)
      *out_errno = EINVAL;
    return -1;
  }
  if (l2tp_root_write_frame(r->to_helper_fd, cmd, flag, req, req_len) != 0) {
    int err = errno != 0 ? errno : EPIPE;
    if (out_errno != NULL)
      *out_errno = err;
    return -1;
  }
  uint8_t st = 0u;
  uint8_t local_buf[TF_L2TP_MAX_FRAME];
  uint8_t *dst = reply_buf != NULL ? reply_buf : local_buf;
  size_t dst_cap = reply_buf != NULL ? reply_cap : sizeof(local_buf);
  size_t rlen = 0u;
  if (l2tp_root_read_reply_frame(r, &st, dst, dst_cap, &rlen, timeout_ms, check_stop) != 0) {
    int err = errno != 0 ? errno : EIO;
    if (out_errno != NULL)
      *out_errno = err;
    return -1;
  }
  if (reply_len_out != NULL)
    *reply_len_out = rlen;
  if (st != 0u) {
    int err = (rlen >= 4u) ? (int)util_read_be32(dst) : EIO;
    if (err == 0)
      err = EIO;
    if (out_errno != NULL)
      *out_errno = err;
    return -1;
  }
  return 0;
}

static int l2tp_root_rpc(l2tp_root_t *r, uint8_t cmd, uint8_t flag, const uint8_t *req, size_t req_len,
                         uint8_t *reply_buf, size_t reply_cap, size_t *reply_len_out, int timeout_ms, int *out_errno) {
  return l2tp_root_rpc_ex(r, cmd, flag, req, req_len, reply_buf, reply_cap, reply_len_out, timeout_ms, 1, out_errno);
}

int l2tp_root_start(l2tp_root_t *r, const char *helper_path, int protect_vpn, const char *bind_iface) {
  if (r == NULL || !tf_is_safe_helper_path(helper_path))
    return TUNNEL_EXIT_BAD_ARGS;
  l2tp_root_init(r);

  if (tunnel_should_stop())
    return TUNNEL_EXIT_STOPPED;

  char su_buf[256];
  const char *su_override = getenv("TF_TEST_L2TP_SU");
  const char *su_path =
      (su_override != NULL && su_override[0] != '\0') ? su_override : tf_find_su_binary(su_buf, sizeof(su_buf));

  int in_pipe[2] = {-1, -1};
  int out_pipe[2] = {-1, -1};
  int err_pipe[2] = {-1, -1};
  if (pipe(in_pipe) != 0 || pipe(out_pipe) != 0 || pipe(err_pipe) != 0) {
    for (int i = 0; i < 2; i++) {
      if (in_pipe[i] >= 0)
        close(in_pipe[i]);
      if (out_pipe[i] >= 0)
        close(out_pipe[i]);
      if (err_pipe[i] >= 0)
        close(err_pipe[i]);
    }
    return TUNNEL_EXIT_ROOT_UNAVAILABLE;
  }
  (void)tf_set_cloexec(in_pipe[0]);
  (void)tf_set_cloexec(in_pipe[1]);
  (void)tf_set_cloexec(out_pipe[0]);
  (void)tf_set_cloexec(out_pipe[1]);
  (void)tf_set_cloexec(err_pipe[0]);
  (void)tf_set_cloexec(err_pipe[1]);

  posix_spawn_file_actions_t actions;
  if (posix_spawn_file_actions_init(&actions) != 0) {
    close(in_pipe[0]);
    close(in_pipe[1]);
    close(out_pipe[0]);
    close(out_pipe[1]);
    close(err_pipe[0]);
    close(err_pipe[1]);
    return TUNNEL_EXIT_ROOT_UNAVAILABLE;
  }
  (void)posix_spawn_file_actions_adddup2(&actions, in_pipe[0], STDIN_FILENO);
  (void)posix_spawn_file_actions_adddup2(&actions, out_pipe[1], STDOUT_FILENO);
  (void)posix_spawn_file_actions_adddup2(&actions, err_pipe[1], STDERR_FILENO);

  char helper_cmd[540];
  snprintf(helper_cmd, sizeof(helper_cmd), "exec '%s'", helper_path);
  char *argv[] = {(char *)"su", (char *)"-c", helper_cmd, NULL};

  pid_t child = -1;
  int spawn_rc;
  if (su_path != NULL) {
    spawn_rc = posix_spawn(&child, su_path, &actions, NULL, argv, environ);
  } else {
    spawn_rc = posix_spawnp(&child, "su", &actions, NULL, argv, environ);
  }
  posix_spawn_file_actions_destroy(&actions);

  close(in_pipe[0]);
  close(out_pipe[1]);
  close(err_pipe[1]);

  if (spawn_rc != 0 || child <= 0) {
    close(in_pipe[1]);
    close(out_pipe[0]);
    close(err_pipe[0]);
    tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "l2tp root: su spawn failed rc=%d", spawn_rc);
    return (spawn_rc == ENOENT || su_path == NULL) ? TUNNEL_EXIT_ROOT_UNAVAILABLE : TUNNEL_EXIT_ROOT_DENIED;
  }

  r->pid = child;
  r->to_helper_fd = in_pipe[1];
  r->from_helper_fd = out_pipe[0];
  r->err_fd = err_pipe[0];
  (void)tf_set_nonblock(r->from_helper_fd);
  (void)tf_set_nonblock(r->err_fd);

  uint8_t init[TF_L2TP_INIT_PAYLOAD_LEN];
  memset(init, 0, sizeof(init));
  init[0] = TF_L2TP_HELPER_MAGIC0;
  init[1] = TF_L2TP_HELPER_MAGIC1;
  init[2] = TF_L2TP_HELPER_MAGIC2;
  init[3] = TF_L2TP_HELPER_MAGIC3;
  util_write_be32(init + 4u, protect_vpn ? TF_L2TP_FLAG_PROTECT_VPN : 0u);
  util_write_be32(init + 8u, protect_vpn ? TF_L2TP_ANDROID_FWMARK_PROTECT : 0u);
  if (bind_iface != NULL && bind_iface[0] != '\0')
    snprintf((char *)(init + 12u), 24u, "%s", bind_iface);

  if (l2tp_root_write_frame(r->to_helper_fd, TF_L2TP_CMD_INIT, 0u, init, sizeof(init)) != 0) {
    tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "l2tp root: failed writing init frame errno=%d", errno);
    l2tp_root_stop(r);
    return TUNNEL_EXIT_ROOT_DENIED;
  }
  (void)tf_set_nonblock(r->to_helper_fd);

  uint8_t st = 0u;
  uint8_t rep[16];
  size_t rlen = 0u;
  if (l2tp_root_read_reply_frame(r, &st, rep, sizeof(rep), &rlen, 10000, 1) != 0) {
    int cancelled = tunnel_should_stop();
    char err_msg[256];
    drain_helper_stderr(r->err_fd, err_msg, sizeof(err_msg));
    tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "l2tp root: init reply failed errno=%d stderr=%s", errno,
                      err_msg[0] != '\0' ? err_msg : "(empty)");
    l2tp_root_stop(r);
    return cancelled ? TUNNEL_EXIT_STOPPED : TUNNEL_EXIT_ROOT_DENIED;
  }
  if (st != 0u) {
    char err_msg[256];
    drain_helper_stderr(r->err_fd, err_msg, sizeof(err_msg));
    tunnel_engine_log(ANDROID_LOG_WARN, LOG_TAG, "l2tp root: helper init rejected status=%u stderr=%s", (unsigned)st,
                      err_msg[0] != '\0' ? err_msg : "(empty)");
    l2tp_root_stop(r);
    return TUNNEL_EXIT_ROOT_DENIED;
  }
  return TUNNEL_EXIT_OK;
}

void l2tp_root_xfrm_delete(l2tp_root_t *r) {
  if (r == NULL || !r->xfrm_installed)
    return;
  if (!r->stream_active && r->to_helper_fd >= 0) {
    /* Must still delete XFRM state after g_stop is set during tunnel teardown. */
    (void)l2tp_root_rpc_ex(r, TF_L2TP_CMD_XFRM_DELETE, 0u, NULL, 0u, NULL, 0u, NULL, 1000, 0, NULL);
  }
  r->xfrm_installed = 0;
}

void l2tp_root_stop(l2tp_root_t *r) {
  if (r == NULL)
    return;
  if (r->xfrm_installed && !r->stream_active && r->to_helper_fd >= 0) {
    l2tp_root_xfrm_delete(r);
  }
  if (r->to_helper_fd >= 0) {
    (void)l2tp_root_write_frame(r->to_helper_fd, TF_L2TP_CMD_STOP, 0u, NULL, 0u);
    close(r->to_helper_fd);
    r->to_helper_fd = -1;
  }
  if (r->err_fd >= 0) {
    char err_msg[256];
    drain_helper_stderr(r->err_fd, err_msg, sizeof(err_msg));
    if (err_msg[0] != '\0')
      tunnel_engine_log(ANDROID_LOG_DEBUG, LOG_TAG, "l2tp root stderr: %s", err_msg);
    close(r->err_fd);
    r->err_fd = -1;
  }
  if (r->from_helper_fd >= 0) {
    close(r->from_helper_fd);
    r->from_helper_fd = -1;
  }
  if (r->pid > 0) {
    tf_reap_child_pid(r->pid);
    r->pid = -1;
  }
  r->xfrm_installed = 0;
  r->stream_active = 0;
  r->rx_len = 0u;
}

int l2tp_root_open_udp(l2tp_root_t *r, const uint8_t peer_ipv4[4], uint16_t remote_port, uint16_t bind_local_port,
                       int allow_ephemeral_fallback, uint8_t local_ipv4_out[4], uint16_t *local_port_be_out,
                       int *out_errno) {
  if (peer_ipv4 == NULL)
    return -1;
  uint8_t req[12];
  memset(req, 0, sizeof(req));
  memcpy(req, peer_ipv4, 4u);
  util_write_be16(req + 4u, remote_port);
  util_write_be16(req + 6u, bind_local_port);
  req[8] = allow_ephemeral_fallback ? 1u : 0u;

  uint8_t rep[16];
  size_t rlen = 0u;
  if (l2tp_root_rpc(r, TF_L2TP_CMD_OPEN_UDP, 0u, req, sizeof(req), rep, sizeof(rep), &rlen, 5000, out_errno) != 0)
    return -1;
  if (rlen < 12u)
    return -1;
  if (local_ipv4_out != NULL)
    memcpy(local_ipv4_out, rep + 4u, 4u);
  if (local_port_be_out != NULL)
    memcpy(local_port_be_out, rep + 8u, 2u);
  return 0;
}

int l2tp_root_connect_udp(l2tp_root_t *r, const uint8_t peer_ipv4[4], uint16_t remote_port, uint8_t local_ipv4_out[4],
                          uint16_t *local_port_be_out, int *out_errno) {
  if (peer_ipv4 == NULL)
    return -1;
  uint8_t req[8];
  memset(req, 0, sizeof(req));
  memcpy(req, peer_ipv4, 4u);
  util_write_be16(req + 4u, remote_port);

  uint8_t rep[16];
  size_t rlen = 0u;
  if (l2tp_root_rpc(r, TF_L2TP_CMD_CONNECT_UDP, 0u, req, sizeof(req), rep, sizeof(rep), &rlen, 5000, out_errno) != 0)
    return -1;
  if (rlen < 12u)
    return -1;
  if (local_ipv4_out != NULL)
    memcpy(local_ipv4_out, rep + 4u, 4u);
  if (local_port_be_out != NULL)
    memcpy(local_port_be_out, rep + 8u, 2u);
  return 0;
}

int l2tp_root_udp_send(l2tp_root_t *r, const uint8_t *data, size_t len, int *out_errno) {
  if (data == NULL || len == 0u || len > TF_L2TP_MAX_FRAME) {
    if (out_errno != NULL)
      *out_errno = EINVAL;
    return -1;
  }
  uint8_t rep[8];
  size_t rlen = 0u;
  return l2tp_root_rpc(r, TF_L2TP_CMD_UDP_SEND, 0u, data, len, rep, sizeof(rep), &rlen, 3000, out_errno);
}

int l2tp_root_udp_recv(l2tp_root_t *r, uint8_t *buf, size_t cap, int timeout_ms, int peek, int *out_errno) {
  if (buf == NULL || cap == 0u) {
    if (out_errno != NULL)
      *out_errno = EINVAL;
    return -1;
  }
  const int64_t deadline = tf_monotonic_ms() + (timeout_ms > 0 ? (int64_t)timeout_ms : 0LL);
  for (;;) {
    if (tunnel_should_stop()) {
      if (out_errno != NULL)
        *out_errno = ECANCELED;
      return -1;
    }
    int64_t rem = deadline - tf_monotonic_ms();
    int slice = 0;
    if (timeout_ms > 0) {
      if (rem <= 0) {
        if (out_errno != NULL)
          *out_errno = ETIMEDOUT;
        return -1;
      }
      slice = rem > 200 ? 200 : (int)rem;
    }
    uint8_t req[8];
    memset(req, 0, sizeof(req));
    util_write_be32(req, (uint32_t)slice);
    req[4] = peek ? 1u : 0u;
    uint8_t rep[TF_L2TP_MAX_FRAME];
    size_t rlen = 0u;
    int rpc_err = 0;
    if (l2tp_root_rpc(r, TF_L2TP_CMD_UDP_RECV, 0u, req, sizeof(req), rep, sizeof(rep), &rlen, slice + 2000, &rpc_err) ==
        0) {
      if (rlen > cap) {
        if (out_errno != NULL)
          *out_errno = EMSGSIZE;
        return -1;
      }
      memcpy(buf, rep, rlen);
      return (int)rlen;
    }
    if ((rpc_err == ETIMEDOUT || rpc_err == EAGAIN || rpc_err == EWOULDBLOCK) && timeout_ms > 0)
      continue;
    if (out_errno != NULL)
      *out_errno = rpc_err;
    return -1;
  }
}

int l2tp_root_set_encap(l2tp_root_t *r, int encap_type, int *out_errno) {
  uint8_t req[4];
  util_write_be32(req, (uint32_t)encap_type);
  uint8_t rep[8];
  size_t rlen = 0u;
  return l2tp_root_rpc(r, TF_L2TP_CMD_SET_ENCAP, 0u, req, sizeof(req), rep, sizeof(rep), &rlen, 3000, out_errno);
}

int l2tp_root_xfrm_install(l2tp_root_t *r, const tf_l2tp_xfrm_spec_t *spec, int *out_errno) {
  uint8_t req[TF_L2TP_XFRM_WIRE_LEN];
  if (tf_l2tp_xfrm_spec_pack(spec, req, sizeof(req)) != 0) {
    if (out_errno != NULL)
      *out_errno = EINVAL;
    return -1;
  }
  uint8_t rep[8];
  size_t rlen = 0u;
  int rc = l2tp_root_rpc(r, TF_L2TP_CMD_XFRM_INSTALL, 0u, req, sizeof(req), rep, sizeof(rep), &rlen, 5000, out_errno);
  if (rc == 0 && r != NULL)
    r->xfrm_installed = 1;
  return rc;
}

int l2tp_root_open_raw_esp(l2tp_root_t *r, const uint8_t peer_ipv4[4], int *out_errno) {
  if (peer_ipv4 == NULL) {
    if (out_errno != NULL)
      *out_errno = EINVAL;
    return -1;
  }
  uint8_t rep[8];
  size_t rlen = 0u;
  return l2tp_root_rpc(r, TF_L2TP_CMD_OPEN_RAW_ESP, 0u, peer_ipv4, 4u, rep, sizeof(rep), &rlen, 5000, out_errno);
}

int l2tp_root_start_stream(l2tp_root_t *r, int mode, int *out_errno) {
  uint8_t rep[8];
  size_t rlen = 0u;
  int rc = l2tp_root_rpc(r, TF_L2TP_CMD_START_STREAM, (uint8_t)(mode ? 1u : 0u), NULL, 0u, rep, sizeof(rep), &rlen,
                         3000, out_errno);
  if (rc == 0 && r != NULL)
    r->stream_active = 1;
  return rc;
}

int l2tp_root_ike_send_async(l2tp_root_t *r, const uint8_t *data, size_t len, int nat_t) {
  if (r == NULL || r->to_helper_fd < 0 || data == NULL || len == 0u || len > TF_L2TP_MAX_FRAME)
    return -1;
  if (!r->stream_active) {
    int err = 0;
    if (nat_t) {
      uint8_t wrapped[4u + TF_L2TP_MAX_FRAME];
      if (len + 4u > sizeof(wrapped))
        return -1;
      memset(wrapped, 0, 4u);
      memcpy(wrapped + 4u, data, len);
      /* Teardown calls this with g_stop=1, so skip cancellation checks while awaiting send ACK. */
      return l2tp_root_rpc_ex(r, TF_L2TP_CMD_UDP_SEND, 0u, wrapped, len + 4u, NULL, 0u, NULL, 1000, 0, &err);
    }
    return l2tp_root_rpc_ex(r, TF_L2TP_CMD_UDP_SEND, 0u, data, len, NULL, 0u, NULL, 1000, 0, &err);
  }
  return l2tp_root_write_frame(r->to_helper_fd, TF_L2TP_MSG_IKE_SEND, nat_t ? 1u : 0u, data, len);
}

int l2tp_root_stream_send(void *ctx, const uint8_t *data, size_t len) {
  l2tp_root_t *r = (l2tp_root_t *)ctx;
  if (r == NULL || !r->stream_active || r->to_helper_fd < 0 || data == NULL || len == 0u || len > TF_L2TP_MAX_FRAME) {
    errno = EINVAL;
    return -1;
  }
  if (l2tp_root_write_frame(r->to_helper_fd, TF_L2TP_MSG_DATA, 0u, data, len) != 0)
    return -1;
  return (int)len;
}

int l2tp_root_has_buffered_frame(const l2tp_root_t *r) {
  if (r == NULL || !r->stream_active || r->rx_len < TF_L2TP_FRAME_HDR_LEN)
    return 0;
  uint16_t flen = util_read_be16(r->rx_buf + 2u);
  if (flen == 0u || flen > TF_L2TP_MAX_FRAME)
    return 1;
  return r->rx_len >= TF_L2TP_FRAME_HDR_LEN + (size_t)flen;
}

static int l2tp_root_pop_data_frame(l2tp_root_t *r, uint8_t *out, size_t cap) {
  while (r->rx_len >= TF_L2TP_FRAME_HDR_LEN) {
    uint16_t flen = util_read_be16(r->rx_buf + 2u);
    if (flen == 0u || flen > TF_L2TP_MAX_FRAME) {
      errno = EPROTO;
      return -1;
    }
    size_t total = TF_L2TP_FRAME_HDR_LEN + (size_t)flen;
    if (r->rx_len < total)
      return 0;
    uint8_t type = r->rx_buf[0];
    if (type == TF_L2TP_MSG_DATA) {
      if ((size_t)flen > cap) {
        errno = EMSGSIZE;
        return -1;
      }
      memcpy(out, r->rx_buf + TF_L2TP_FRAME_HDR_LEN, (size_t)flen);
      r->rx_len -= total;
      if (r->rx_len > 0u)
        memmove(r->rx_buf, r->rx_buf + total, r->rx_len);
      return (int)flen;
    }
    r->rx_len -= total;
    if (r->rx_len > 0u)
      memmove(r->rx_buf, r->rx_buf + total, r->rx_len);
  }
  return 0;
}

int l2tp_root_stream_read_nonblock(l2tp_root_t *r, uint8_t *buf, size_t cap) {
  if (r == NULL || !r->stream_active || r->from_helper_fd < 0 || buf == NULL || cap == 0u) {
    errno = EINVAL;
    return -1;
  }
  int pop = l2tp_root_pop_data_frame(r, buf, cap);
  if (pop != 0)
    return pop;

  while (r->rx_len < sizeof(r->rx_buf)) {
    ssize_t n = read(r->from_helper_fd, r->rx_buf + r->rx_len, sizeof(r->rx_buf) - r->rx_len);
    if (n == 0) {
      errno = EPIPE;
      return -1;
    }
    if (n < 0) {
      if (errno == EINTR)
        continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK)
        break;
      return -1;
    }
    r->rx_len += (size_t)n;
    pop = l2tp_root_pop_data_frame(r, buf, cap);
    if (pop != 0)
      return pop;
  }
  return 0;
}

int l2tp_root_stream_recv_wait(void *ctx, uint8_t *buf, size_t cap, int timeout_ms) {
  l2tp_root_t *r = (l2tp_root_t *)ctx;
  if (r == NULL || !r->stream_active || r->from_helper_fd < 0 || buf == NULL || cap == 0u)
    return -1;
  const int64_t deadline = tf_monotonic_ms() + (timeout_ms > 0 ? (int64_t)timeout_ms : 0LL);
  for (;;) {
    int n = l2tp_root_stream_read_nonblock(r, buf, cap);
    if (n != 0)
      return n;
    if (tunnel_should_stop()) {
      errno = ECANCELED;
      return -1;
    }
    int64_t rem = deadline - tf_monotonic_ms();
    if (rem <= 0)
      return 0;
    int slice = rem > 200 ? 200 : (int)rem;
    struct pollfd pfd = {.fd = r->from_helper_fd, .events = POLLIN};
    int pr = poll(&pfd, 1u, slice);
    if (pr < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    if (pr > 0 && (pfd.revents & POLLIN) == 0 && (pfd.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
      errno = EPIPE;
      return -1;
    }
  }
}

int l2tp_root_is_stream_active(const l2tp_root_t *r) { return (r != NULL && r->stream_active) ? 1 : 0; }

int l2tp_root_stream_fd(const l2tp_root_t *r) { return r != NULL ? r->from_helper_fd : -1; }
