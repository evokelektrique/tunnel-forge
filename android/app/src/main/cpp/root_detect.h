#ifndef TUNNEL_FORGE_ROOT_DETECT_H
#define TUNNEL_FORGE_ROOT_DETECT_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/** Locate `su` via PATH or common Android superuser directories; returns NULL when absent. */
const char *tf_find_su_binary(char *buf, size_t cap);

/** Set FD_CLOEXEC on @p fd. Returns 0 on success or -1 with errno. */
int tf_set_cloexec(int fd);

/** Set O_NONBLOCK on @p fd. Returns 0 on success or -1 with errno. */
int tf_set_nonblock(int fd);

/** Monotonic clock in milliseconds (fallback to wall time on clock_gettime error). */
int64_t tf_monotonic_ms(void);

/** Write all @p len bytes to @p fd, handling EINTR and short EAGAIN waits. Returns 0 or -1. */
int tf_write_all_fd(int fd, const uint8_t *buf, size_t len);

/** Terminate and reap @p pid cleanly (SIGTERM, short wait, then SIGKILL fallback). */
void tf_reap_child_pid(pid_t pid);

/**
 * Probe root access via `su -c id` with a bounded timeout.
 * If @p su_override is non-NULL, invokes that executable directly instead of searching for `su`.
 * Returns 1 if UID 0 is confirmed, 0 otherwise.
 */
int tf_probe_root_with_su(const char *su_override, int timeout_ms);

/** Validate helper executable path under nativeLibraryDir (no shell metacharacters). */
int tf_is_safe_helper_path(const char *path);

#endif
