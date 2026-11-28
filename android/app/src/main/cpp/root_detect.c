/*
 * Shared superuser (su) discovery, startup root probe (`su -c id`), and POSIX helper process
 * utilities for native root backends.
 */
#include "root_detect.h"

#include "engine.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if !defined(__ANDROID__) && !defined(_GNU_SOURCE)
extern char **environ;
#endif

const char *tf_find_su_binary(char *buf, size_t cap) {
  static const char *const k_candidates[] = {
      "/debug_ramdisk/su", "/sbin/su", "/system/bin/su", "/system/xbin/su", "/su/bin/su", "/product/bin/su",
  };
  if (buf != NULL && cap > 0u) {
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
  }
  for (size_t i = 0u; i < sizeof(k_candidates) / sizeof(k_candidates[0]); i++) {
    if (access(k_candidates[i], X_OK) == 0)
      return k_candidates[i];
  }
  return NULL;
}

int tf_set_cloexec(int fd) {
  int flags = fcntl(fd, F_GETFD, 0);
  if (flags < 0)
    return -1;
  return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

int tf_set_nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0)
    return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

int64_t tf_monotonic_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    return (int64_t)time(NULL) * 1000LL;
  return (int64_t)ts.tv_sec * 1000LL + (int64_t)(ts.tv_nsec / 1000000LL);
}

int tf_write_all_fd(int fd, const uint8_t *buf, size_t len) {
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

void tf_reap_child_pid(pid_t pid) {
  if (pid <= 0)
    return;
  (void)kill(pid, SIGTERM);
  int status = 0;
  int reaped = 0;
  for (int i = 0; i < 20; i++) {
    pid_t w = waitpid(pid, &status, WNOHANG);
    if (w == pid || (w < 0 && errno == ECHILD)) {
      reaped = 1;
      break;
    }
    struct timespec ts = {.tv_sec = 0, .tv_nsec = 25000000L};
    (void)nanosleep(&ts, NULL);
  }
  if (!reaped) {
    (void)kill(pid, SIGKILL);
    for (int i = 0; i < 5; i++) {
      pid_t w = waitpid(pid, &status, WNOHANG);
      if (w == pid || (w < 0 && errno == ECHILD))
        break;
      struct timespec ts = {.tv_sec = 0, .tv_nsec = 10000000L};
      (void)nanosleep(&ts, NULL);
    }
  }
}

int tf_is_safe_helper_path(const char *path) {
  if (path == NULL || path[0] != '/')
    return 0;
  size_t len = 0u;
  for (; path[len] != '\0'; len++) {
    char c = path[len];
    int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '/' || c == '.' ||
             c == '_' || c == '-' || c == '~' || c == '=' || c == '+' || c == ',' || c == '@' || c == ':';
    if (!ok)
      return 0;
  }
  return len > 1u && len < 512u;
}

static int output_confirms_uid_zero(const char *buf) {
  if (buf == NULL)
    return 0;
  const char *p = buf;
  while ((p = strstr(p, "uid=0")) != NULL) {
    if (p == buf || p[-1] == ' ' || p[-1] == '\t' || p[-1] == '\n' || p[-1] == '\r') {
      char next = p[5];
      if (next == '\0' || next == '(' || next == ' ' || next == '\t' || next == '\r' || next == '\n')
        return 1;
    }
    p += 5;
  }
  return 0;
}

int tf_probe_root_with_su(const char *su_override, int timeout_ms) {
  if (timeout_ms <= 0)
    timeout_ms = 3000;

  char su_buf[256];
  const char *su_path = su_override;
  if (su_path == NULL) {
    su_path = tf_find_su_binary(su_buf, sizeof(su_buf));
  } else if (access(su_path, X_OK) != 0) {
    return 0;
  }

  int out_pipe[2] = {-1, -1};
  if (pipe(out_pipe) != 0)
    return 0;
  (void)tf_set_cloexec(out_pipe[0]);
  (void)tf_set_cloexec(out_pipe[1]);

  /* Isolate the probe from app input and capture only the command's stdout. */
  int devnull = open("/dev/null", O_RDWR);
  if (devnull >= 0)
    (void)tf_set_cloexec(devnull);

  posix_spawn_file_actions_t actions;
  if (posix_spawn_file_actions_init(&actions) != 0) {
    close(out_pipe[0]);
    close(out_pipe[1]);
    if (devnull >= 0)
      close(devnull);
    return 0;
  }
  if (devnull >= 0) {
    (void)posix_spawn_file_actions_adddup2(&actions, devnull, STDIN_FILENO);
    (void)posix_spawn_file_actions_adddup2(&actions, devnull, STDERR_FILENO);
  } else {
    (void)posix_spawn_file_actions_addclose(&actions, STDIN_FILENO);
    (void)posix_spawn_file_actions_addclose(&actions, STDERR_FILENO);
  }
  (void)posix_spawn_file_actions_adddup2(&actions, out_pipe[1], STDOUT_FILENO);

  char *argv[] = {(char *)"su", (char *)"-c", (char *)"id", NULL};
  pid_t child = -1;
  int spawn_rc;
  if (su_path != NULL) {
    spawn_rc = posix_spawn(&child, su_path, &actions, NULL, argv, environ);
  } else {
    /* KernelSU / APatch can intercept execve("su") even without a visible su binary on disk. */
    spawn_rc = posix_spawnp(&child, "su", &actions, NULL, argv, environ);
  }
  posix_spawn_file_actions_destroy(&actions);
  close(out_pipe[1]);
  if (devnull >= 0)
    close(devnull);

  if (spawn_rc != 0 || child <= 0) {
    close(out_pipe[0]);
    return 0;
  }

  /* Drain stdout without blocking while su waits for a permission decision. */
  (void)tf_set_nonblock(out_pipe[0]);
  char out_buf[256];
  size_t got = 0u;
  out_buf[0] = '\0';
  const int64_t deadline = tf_monotonic_ms() + (int64_t)timeout_ms;
  int timed_out = 0;

  for (;;) {
    int64_t rem = deadline - tf_monotonic_ms();
    if (rem <= 0) {
      timed_out = 1;
      break;
    }
    int slice = rem > 200 ? 200 : (int)rem;
    struct pollfd pfd = {.fd = out_pipe[0], .events = POLLIN};
    int pr = poll(&pfd, 1u, slice);
    if (pr < 0) {
      if (errno == EINTR)
        continue;
      break;
    }
    if (pr == 0)
      continue;
    if ((pfd.revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
      int eof = 0;
      for (;;) {
        if (got + 1u >= sizeof(out_buf))
          break;
        ssize_t n = read(out_pipe[0], out_buf + got, sizeof(out_buf) - 1u - got);
        if (n > 0) {
          got += (size_t)n;
          out_buf[got] = '\0';
          continue;
        }
        if (n == 0) {
          eof = 1;
          break;
        }
        if (errno == EINTR)
          continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK)
          break;
        eof = 1;
        break;
      }
      if (eof || got + 1u >= sizeof(out_buf))
        break;
    }
  }

  close(out_pipe[0]);
  if (timed_out) {
    tf_reap_child_pid(child);
    return 0;
  }

  /* Require both a successful command exit and an explicit UID of zero. */
  int status = 0;
  pid_t w;
  do {
    w = waitpid(child, &status, 0);
  } while (w < 0 && errno == EINTR);
  if (w != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
    return 0;

  return output_confirms_uid_zero(out_buf);
}

int engine_probe_root_access(int timeout_ms) { return tf_probe_root_with_su(NULL, timeout_ms); }
