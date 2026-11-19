/*
 * Spawns libpptp_gre_helper.so under su via posix_spawn and exchanges length-prefixed
 * raw GRE frames over pipes. Keeps raw socket privileges isolated inside the helper.
 */
#include "pptp_root.h"

#include "engine.h"
#include "pptp.h"
#include "util_endian.h"

#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define LOG_TAG "tunnel_engine"

#define HELPER_MAGIC_0 'T'
#define HELPER_MAGIC_1 'F'
#define HELPER_MAGIC_2 'G'
#define HELPER_MAGIC_3 '1'
#define HELPER_INIT_LEN 40u
#define HELPER_REPLY_LEN 12u
#define HELPER_MAX_FRAME 4096u
#define HELPER_FLAG_PROTECT_VPN 1u
#define ANDROID_FWMARK_PROTECT_FROM_VPN 0x00020000u

#define HELPER_STATUS_OK 0u

void pptp_root_init(pptp_root_t *r) {
  if (r == NULL)
    return;
  memset(r, 0, sizeof(*r));
  r->pid = -1;
  r->to_helper_fd = -1;
  r->from_helper_fd = -1;
  r->err_fd = -1;
}

static int set_cloexec(int fd) {
  int flags = fcntl(fd, F_GETFD, 0);
  if (flags < 0)
    return -1;
  return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int set_nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0)
    return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static const char *find_su_binary(char *buf, size_t cap) {
  static const char *const k_candidates[] = {
      "/debug_ramdisk/su", "/sbin/su", "/system/bin/su", "/system/xbin/su", "/su/bin/su", "/product/bin/su",
  };
  const char *path_env = getenv("PATH");
  if (path_env != NULL) {
    const char *p = path_env;
    while (*p != '\0') {
      const char *colon = strchr(p, ':');
      size_t dlen = colon != NULL ? (size_t)(colon - p) : strlen(p);
      if (dlen > 0u && dlen + 4u < cap) {
        memcpy(buf, p, dlen);
        memcpy(buf + dlen, "/su", 4u);
        if (access(buf, X_OK) == 0)
          return buf;
      }
      if (colon == NULL)
        break;
      p = colon + 1;
    }
  }
  for (size_t i = 0u; i < sizeof(k_candidates) / sizeof(k_candidates[0]); i++) {
    if (access(k_candidates[i], X_OK) == 0)
      return k_candidates[i];
  }
  return NULL;
}

static int write_all_fd(int fd, const uint8_t *buf, size_t len) {
  size_t off = 0u;
  while (off < len) {
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

static void drain_helper_stderr(int err_fd, char *out, size_t cap) {
  if (err_fd < 0 || out == NULL || cap < 2u)
    return;
  size_t cur = strlen(out);
  while (cur + 1u < cap) {
    ssize_t n = read(err_fd, out + cur, cap - 1u - cur);
    if (n <= 0)
      break;
    cur += (size_t)n;
    out[cur] = '\0';
  }
  for (size_t i = 0u; i < cur; i++) {
    if (out[i] == '\r' || out[i] == '\n')
      out[i] = ' ';
  }
}

static int64_t monotonic_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    return (int64_t)time(NULL) * 1000LL;
  return (int64_t)ts.tv_sec * 1000LL + (int64_t)(ts.tv_nsec / 1000000LL);
}

int pptp_root_start(pptp_root_t *r, const char *helper_path, const uint8_t peer_ipv4[4], int protect_vpn,
                    const char *bind_iface) {
  if (r == NULL || peer_ipv4 == NULL || !pptp_is_safe_helper_path(helper_path)) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp root: invalid helper path len=%zu",
                      helper_path != NULL ? strlen(helper_path) : 0u);
    return TUNNEL_EXIT_GRE_SOCKET_FAILED;
  }
  pptp_root_init(r);

  if (access(helper_path, X_OK) != 0) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp root: helper not executable errno=%d", errno);
    return TUNNEL_EXIT_GRE_SOCKET_FAILED;
  }

  char su_buf[256];
  const char *su_path = find_su_binary(su_buf, sizeof(su_buf));

  int in_pipe[2] = {-1, -1};
  int out_pipe[2] = {-1, -1};
  int err_pipe[2] = {-1, -1};
  if (pipe(in_pipe) != 0 || pipe(out_pipe) != 0 || pipe(err_pipe) != 0) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp root: pipe() failed errno=%d", errno);
    if (in_pipe[0] >= 0)
      close(in_pipe[0]);
    if (in_pipe[1] >= 0)
      close(in_pipe[1]);
    if (out_pipe[0] >= 0)
      close(out_pipe[0]);
    if (out_pipe[1] >= 0)
      close(out_pipe[1]);
    if (err_pipe[0] >= 0)
      close(err_pipe[0]);
    if (err_pipe[1] >= 0)
      close(err_pipe[1]);
    return TUNNEL_EXIT_GRE_SOCKET_FAILED;
  }

  (void)set_cloexec(in_pipe[0]);
  (void)set_cloexec(in_pipe[1]);
  (void)set_cloexec(out_pipe[0]);
  (void)set_cloexec(out_pipe[1]);
  (void)set_cloexec(err_pipe[0]);
  (void)set_cloexec(err_pipe[1]);

  posix_spawn_file_actions_t actions;
  if (posix_spawn_file_actions_init(&actions) != 0) {
    close(in_pipe[0]);
    close(in_pipe[1]);
    close(out_pipe[0]);
    close(out_pipe[1]);
    close(err_pipe[0]);
    close(err_pipe[1]);
    return TUNNEL_EXIT_GRE_SOCKET_FAILED;
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
    /* KernelSU / APatch may hook execve("su") even when access() does not see a file on disk. */
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
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp root: su spawn failed rc=%d", spawn_rc);
    if (spawn_rc == ENOENT || su_path == NULL)
      return TUNNEL_EXIT_ROOT_UNAVAILABLE;
    return TUNNEL_EXIT_ROOT_DENIED;
  }

  r->pid = child;
  r->to_helper_fd = in_pipe[1];
  r->from_helper_fd = out_pipe[0];
  r->err_fd = err_pipe[0];
  (void)set_nonblock(r->from_helper_fd);
  (void)set_nonblock(r->err_fd);

  uint8_t init[HELPER_INIT_LEN];
  memset(init, 0, sizeof(init));
  init[0] = HELPER_MAGIC_0;
  init[1] = HELPER_MAGIC_1;
  init[2] = HELPER_MAGIC_2;
  init[3] = HELPER_MAGIC_3;
  memcpy(init + 4u, peer_ipv4, 4u);
  util_write_be32(init + 8u, protect_vpn ? HELPER_FLAG_PROTECT_VPN : 0u);
  util_write_be32(init + 12u, protect_vpn ? ANDROID_FWMARK_PROTECT_FROM_VPN : 0u);
  if (bind_iface != NULL && bind_iface[0] != '\0') {
    snprintf((char *)(init + 16u), 24u, "%s", bind_iface);
  }

  if (write_all_fd(r->to_helper_fd, init, sizeof(init)) != 0) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp root: failed writing init frame errno=%d", errno);
    pptp_root_stop(r);
    return TUNNEL_EXIT_ROOT_DENIED;
  }

  uint8_t reply[HELPER_REPLY_LEN] = {0};
  size_t reply_got = 0u;
  char stderr_buf[256] = {0};
  const int64_t deadline = monotonic_ms() + 30000LL;

  while (reply_got < sizeof(reply)) {
    if (tunnel_should_stop()) {
      pptp_root_stop(r);
      return TUNNEL_EXIT_STOPPED;
    }
    int64_t rem = deadline - monotonic_ms();
    if (rem <= 0) {
      drain_helper_stderr(r->err_fd, stderr_buf, sizeof(stderr_buf));
      tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp root: timed out waiting for su helper stderr=%s",
                        stderr_buf[0] != '\0' ? stderr_buf : "(empty)");
      pptp_root_stop(r);
      return TUNNEL_EXIT_ROOT_DENIED;
    }
    int slice = rem > 150 ? 150 : (int)rem;
    struct pollfd fds[2];
    fds[0].fd = r->from_helper_fd;
    fds[0].events = POLLIN;
    fds[1].fd = r->err_fd;
    fds[1].events = POLLIN;
    int pr = poll(fds, 2u, slice);
    if (pr < 0) {
      if (errno == EINTR)
        continue;
      break;
    }
    if ((fds[1].revents & POLLIN) != 0)
      drain_helper_stderr(r->err_fd, stderr_buf, sizeof(stderr_buf));
    if ((fds[0].revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
      ssize_t n = read(r->from_helper_fd, reply + reply_got, sizeof(reply) - reply_got);
      if (n > 0) {
        reply_got += (size_t)n;
        continue;
      }
      if (n == 0) {
        drain_helper_stderr(r->err_fd, stderr_buf, sizeof(stderr_buf));
        int status = 0;
        pid_t w = waitpid(r->pid, &status, 0);
        if (w == r->pid)
          r->pid = -1;
        int exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp root: su helper exited before ready exit=%d stderr=%s",
                          exit_code, stderr_buf[0] != '\0' ? stderr_buf : "(empty)");
        pptp_root_stop(r);
        if (exit_code == 127 && su_path == NULL)
          return TUNNEL_EXIT_ROOT_UNAVAILABLE;
        return TUNNEL_EXIT_ROOT_DENIED;
      }
      if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
        pptp_root_stop(r);
        return TUNNEL_EXIT_ROOT_DENIED;
      }
    }
  }

  if (reply_got < sizeof(reply) || reply[0] != HELPER_MAGIC_0 || reply[1] != HELPER_MAGIC_1 ||
      reply[2] != HELPER_MAGIC_2 || reply[3] != HELPER_MAGIC_3) {
    drain_helper_stderr(r->err_fd, stderr_buf, sizeof(stderr_buf));
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp root: unexpected su stdout magic stderr=%s",
                      stderr_buf[0] != '\0' ? stderr_buf : "(empty)");
    pptp_root_stop(r);
    return TUNNEL_EXIT_ROOT_DENIED;
  }

  uint32_t helper_status = util_read_be32(reply + 4u);
  uint32_t helper_errno = util_read_be32(reply + 8u);
  if (helper_status != HELPER_STATUS_OK) {
    tunnel_engine_log(ANDROID_LOG_ERROR, LOG_TAG, "pptp root: raw GRE socket setup failed status=%u errno=%u",
                      helper_status, helper_errno);
    pptp_root_stop(r);
    if (helper_errno == EPERM || helper_errno == EACCES)
      return TUNNEL_EXIT_ROOT_DENIED;
    return TUNNEL_EXIT_GRE_SOCKET_FAILED;
  }

  tunnel_engine_log(ANDROID_LOG_INFO, LOG_TAG, "pptp root: GRE helper ready protect_vpn=%d bind_iface=%s",
                    protect_vpn ? 1 : 0, (bind_iface != NULL && bind_iface[0] != '\0') ? bind_iface : "(none)");
  return TUNNEL_EXIT_OK;
}

void pptp_root_stop(pptp_root_t *r) {
  if (r == NULL)
    return;
  if (r->to_helper_fd >= 0) {
    close(r->to_helper_fd);
    r->to_helper_fd = -1;
  }
  if (r->from_helper_fd >= 0) {
    close(r->from_helper_fd);
    r->from_helper_fd = -1;
  }
  if (r->err_fd >= 0) {
    close(r->err_fd);
    r->err_fd = -1;
  }
  if (r->pid > 0) {
    (void)kill(r->pid, SIGTERM);
    int status = 0;
    int reaped = 0;
    for (int i = 0; i < 20; i++) {
      pid_t w = waitpid(r->pid, &status, WNOHANG);
      if (w == r->pid || (w < 0 && errno == ECHILD)) {
        reaped = 1;
        break;
      }
      struct timespec ts = {.tv_sec = 0, .tv_nsec = 25000000L};
      (void)nanosleep(&ts, NULL);
    }
    if (!reaped) {
      (void)kill(r->pid, SIGKILL);
      (void)waitpid(r->pid, &status, 0);
    }
    r->pid = -1;
  }
  r->rx_len = 0u;
}

int pptp_root_send_gre(pptp_root_t *r, const uint8_t *gre, size_t gre_len) {
  if (r == NULL || r->to_helper_fd < 0 || gre == NULL || gre_len == 0u || gre_len > HELPER_MAX_FRAME) {
    errno = EINVAL;
    return -1;
  }
  uint8_t frame[2u + HELPER_MAX_FRAME];
  util_write_be16(frame, (uint16_t)gre_len);
  memcpy(frame + 2u, gre, gre_len);
  return write_all_fd(r->to_helper_fd, frame, 2u + gre_len);
}

int pptp_root_has_buffered_frame(const pptp_root_t *r) {
  if (r == NULL || r->rx_len < 2u)
    return 0;
  uint16_t flen = util_read_be16(r->rx_buf);
  return flen > 0u && flen <= HELPER_MAX_FRAME && r->rx_len >= 2u + (size_t)flen;
}

static int pop_buffered_frame(pptp_root_t *r, uint8_t *out, size_t cap) {
  if (r->rx_len < 2u)
    return 0;
  uint16_t flen = util_read_be16(r->rx_buf);
  if (flen == 0u || flen > HELPER_MAX_FRAME) {
    errno = EPROTO;
    return -1;
  }
  if (r->rx_len < 2u + (size_t)flen)
    return 0;
  if ((size_t)flen > cap) {
    /* Drop oversized frame while maintaining stream framing. */
    size_t consumed = 2u + (size_t)flen;
    r->rx_len -= consumed;
    if (r->rx_len > 0u)
      memmove(r->rx_buf, r->rx_buf + consumed, r->rx_len);
    return 0;
  }
  memcpy(out, r->rx_buf + 2u, (size_t)flen);
  size_t consumed = 2u + (size_t)flen;
  r->rx_len -= consumed;
  if (r->rx_len > 0u)
    memmove(r->rx_buf, r->rx_buf + consumed, r->rx_len);
  return (int)flen;
}

int pptp_root_read_gre(pptp_root_t *r, uint8_t *out, size_t cap) {
  if (r == NULL || out == NULL || cap == 0u) {
    errno = EINVAL;
    return -1;
  }
  int buffered = pop_buffered_frame(r, out, cap);
  if (buffered != 0)
    return buffered;

  if (r->from_helper_fd < 0) {
    errno = EBADF;
    return -1;
  }
  for (;;) {
    if (r->rx_len >= sizeof(r->rx_buf)) {
      errno = EMSGSIZE;
      return -1;
    }
    ssize_t n = read(r->from_helper_fd, r->rx_buf + r->rx_len, sizeof(r->rx_buf) - r->rx_len);
    if (n == 0) {
      errno = EPIPE;
      return -1;
    }
    if (n < 0) {
      if (errno == EINTR)
        continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK)
        return 0;
      return -1;
    }
    r->rx_len += (size_t)n;
    return pop_buffered_frame(r, out, cap);
  }
}
