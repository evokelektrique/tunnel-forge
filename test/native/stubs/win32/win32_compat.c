#define TF_WIN32_COMPAT_IMPL 1

#include <sys/random.h>
#include <sys/socket.h>

#include <bcrypt.h>
#include <errno.h>
#include <limits.h>
#include <string.h>

#define TF_WIN32_SOCK_BASE 1000
#define TF_WIN32_MAX_SOCKETS 64

static SOCKET g_win32_sockets[TF_WIN32_MAX_SOCKETS];
static int g_win32_sockets_inited = 0;
static int g_win32_wsa_inited = 0;

static void tf_win32_init_table(void) {
  if (g_win32_sockets_inited) {
    return;
  }
  for (int i = 0; i < TF_WIN32_MAX_SOCKETS; i++) {
    g_win32_sockets[i] = INVALID_SOCKET;
  }
  g_win32_sockets_inited = 1;
}

static int tf_win32_ensure_wsa(void) {
  if (g_win32_wsa_inited) {
    return 0;
  }
  WSADATA wsa_data;
  if (WSAStartup(MAKEWORD(2, 2), &wsa_data) != 0) {
    errno = EIO;
    return -1;
  }
  g_win32_wsa_inited = 1;
  return 0;
}

static int tf_win32_map_wsa_error(int wsa_err) {
  switch (wsa_err) {
  case WSAEWOULDBLOCK:
    return EAGAIN;
  case WSAEINTR:
    return EINTR;
  case WSAEMSGSIZE:
    return EMSGSIZE;
  case WSAECONNREFUSED:
    return ECONNREFUSED;
  case WSAENOTCONN:
    return ENOTCONN;
  case WSAEADDRINUSE:
    return EADDRINUSE;
  case WSAEACCES:
    return EACCES;
  case WSAEINVAL:
    return EINVAL;
  case WSAENOTSOCK:
    return ENOTSOCK;
  default:
    return EIO;
  }
}

static int tf_win32_alloc_fd(SOCKET s) {
  tf_win32_init_table();
  for (int i = 0; i < TF_WIN32_MAX_SOCKETS; i++) {
    if (g_win32_sockets[i] == INVALID_SOCKET) {
      g_win32_sockets[i] = s;
      return TF_WIN32_SOCK_BASE + i;
    }
  }
  errno = EMFILE;
  return -1;
}

static SOCKET tf_win32_lookup_socket(int fd) {
  tf_win32_init_table();
  int idx = fd - TF_WIN32_SOCK_BASE;
  if (idx < 0 || idx >= TF_WIN32_MAX_SOCKETS) {
    return INVALID_SOCKET;
  }
  return g_win32_sockets[idx];
}

int tf_win32_socket(int domain, int type, int protocol) {
  if (tf_win32_ensure_wsa() != 0) {
    return -1;
  }
  SOCKET s = socket(domain, type, protocol);
  if (s == INVALID_SOCKET) {
    errno = tf_win32_map_wsa_error(WSAGetLastError());
    return -1;
  }
  int fd = tf_win32_alloc_fd(s);
  if (fd < 0) {
    closesocket(s);
    return -1;
  }
  return fd;
}

int tf_win32_socketpair(int domain, int type, int protocol, int sv[2]) {
  if (sv == NULL) {
    errno = EINVAL;
    return -1;
  }
  if (domain != AF_UNIX && domain != AF_INET) {
    errno = EAFNOSUPPORT;
    return -1;
  }
  if (type != SOCK_DGRAM) {
    errno = EPROTONOSUPPORT;
    return -1;
  }
  (void)protocol;
  if (tf_win32_ensure_wsa() != 0) {
    return -1;
  }

  SOCKET s0 = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  SOCKET s1 = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (s0 == INVALID_SOCKET || s1 == INVALID_SOCKET) {
    int err = tf_win32_map_wsa_error(WSAGetLastError());
    if (s0 != INVALID_SOCKET) {
      closesocket(s0);
    }
    if (s1 != INVALID_SOCKET) {
      closesocket(s1);
    }
    errno = err;
    return -1;
  }

  struct sockaddr_in addr0;
  struct sockaddr_in addr1;
  memset(&addr0, 0, sizeof(addr0));
  memset(&addr1, 0, sizeof(addr1));
  addr0.sin_family = AF_INET;
  addr0.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr1 = addr0;

  if (bind(s0, (struct sockaddr *)&addr0, sizeof(addr0)) != 0 ||
      bind(s1, (struct sockaddr *)&addr1, sizeof(addr1)) != 0) {
    int err = tf_win32_map_wsa_error(WSAGetLastError());
    closesocket(s0);
    closesocket(s1);
    errno = err;
    return -1;
  }

  int len0 = (int)sizeof(addr0);
  int len1 = (int)sizeof(addr1);
  if (getsockname(s0, (struct sockaddr *)&addr0, &len0) != 0 ||
      getsockname(s1, (struct sockaddr *)&addr1, &len1) != 0 || connect(s0, (struct sockaddr *)&addr1, len1) != 0 ||
      connect(s1, (struct sockaddr *)&addr0, len0) != 0) {
    int err = tf_win32_map_wsa_error(WSAGetLastError());
    closesocket(s0);
    closesocket(s1);
    errno = err;
    return -1;
  }

  int fd0 = tf_win32_alloc_fd(s0);
  int fd1 = fd0 >= 0 ? tf_win32_alloc_fd(s1) : -1;
  if (fd0 < 0 || fd1 < 0) {
    if (fd0 >= 0) {
      tf_win32_close(fd0);
    } else {
      closesocket(s0);
    }
    closesocket(s1);
    return -1;
  }
  sv[0] = fd0;
  sv[1] = fd1;
  return 0;
}

int tf_win32_bind(int fd, const struct sockaddr *addr, socklen_t addrlen) {
  SOCKET s = tf_win32_lookup_socket(fd);
  if (s == INVALID_SOCKET) {
    errno = EBADF;
    return -1;
  }
  if (bind(s, addr, (int)addrlen) != 0) {
    errno = tf_win32_map_wsa_error(WSAGetLastError());
    return -1;
  }
  return 0;
}

int tf_win32_connect(int fd, const struct sockaddr *addr, socklen_t addrlen) {
  SOCKET s = tf_win32_lookup_socket(fd);
  if (s == INVALID_SOCKET) {
    errno = EBADF;
    return -1;
  }
  if (connect(s, addr, (int)addrlen) != 0) {
    errno = tf_win32_map_wsa_error(WSAGetLastError());
    return -1;
  }
  return 0;
}

int tf_win32_getsockname(int fd, struct sockaddr *addr, socklen_t *addrlen) {
  SOCKET s = tf_win32_lookup_socket(fd);
  if (s == INVALID_SOCKET) {
    errno = EBADF;
    return -1;
  }
  int len = addrlen ? (int)(*addrlen) : 0;
  int rc = getsockname(s, addr, addrlen ? &len : NULL);
  if (rc != 0) {
    errno = tf_win32_map_wsa_error(WSAGetLastError());
    return -1;
  }
  if (addrlen) {
    *addrlen = (socklen_t)len;
  }
  return 0;
}

int tf_win32_getsockopt(int fd, int level, int optname, void *optval, socklen_t *optlen) {
  SOCKET s = tf_win32_lookup_socket(fd);
  if (s == INVALID_SOCKET) {
    errno = EBADF;
    return -1;
  }
  int len = optlen ? (int)(*optlen) : 0;
  int rc = getsockopt(s, level, optname, (char *)optval, optlen ? &len : NULL);
  if (rc != 0) {
    errno = tf_win32_map_wsa_error(WSAGetLastError());
    return -1;
  }
  if (optlen) {
    *optlen = (socklen_t)len;
  }
  if (level == SOL_SOCKET && optname == SO_ERROR && optval != NULL && len >= (int)sizeof(int)) {
    int wsa_err = 0;
    memcpy(&wsa_err, optval, sizeof(int));
    if (wsa_err != 0) {
      int mapped = tf_win32_map_wsa_error(wsa_err);
      memcpy(optval, &mapped, sizeof(int));
    }
  }
  return 0;
}

ssize_t tf_win32_send(int fd, const void *buf, size_t len, int flags) {
  SOCKET s = tf_win32_lookup_socket(fd);
  if (s == INVALID_SOCKET) {
    errno = EBADF;
    return -1;
  }
  if (len > (size_t)INT_MAX) {
    errno = EMSGSIZE;
    return -1;
  }
  int rc = send(s, (const char *)buf, (int)len, flags);
  if (rc == SOCKET_ERROR) {
    errno = tf_win32_map_wsa_error(WSAGetLastError());
    return -1;
  }
  return (ssize_t)rc;
}

ssize_t tf_win32_sendto(int fd, const void *buf, size_t len, int flags, const struct sockaddr *dest_addr,
                        socklen_t addrlen) {
  if (dest_addr == NULL || addrlen == 0) {
    return tf_win32_send(fd, buf, len, flags);
  }
  SOCKET s = tf_win32_lookup_socket(fd);
  if (s == INVALID_SOCKET) {
    errno = EBADF;
    return -1;
  }
  if (len > (size_t)INT_MAX) {
    errno = EMSGSIZE;
    return -1;
  }
  int rc = sendto(s, (const char *)buf, (int)len, flags, dest_addr, (int)addrlen);
  if (rc == SOCKET_ERROR) {
    errno = tf_win32_map_wsa_error(WSAGetLastError());
    return -1;
  }
  return (ssize_t)rc;
}

ssize_t tf_win32_recv(int fd, void *buf, size_t len, int flags) {
  SOCKET s = tf_win32_lookup_socket(fd);
  if (s == INVALID_SOCKET) {
    errno = EBADF;
    return -1;
  }
  if (len > (size_t)INT_MAX) {
    len = (size_t)INT_MAX;
  }
  if ((flags & MSG_DONTWAIT) != 0) {
    WSAPOLLFD pfd;
    pfd.fd = s;
    pfd.events = POLLIN;
    pfd.revents = 0;
    int pr = WSAPoll(&pfd, 1, 0);
    if (pr == SOCKET_ERROR) {
      errno = tf_win32_map_wsa_error(WSAGetLastError());
      return -1;
    }
    if (pr == 0) {
      errno = EAGAIN;
      return -1;
    }
    flags &= ~MSG_DONTWAIT;
  }
  int rc = recv(s, (char *)buf, (int)len, flags);
  if (rc == SOCKET_ERROR) {
    errno = tf_win32_map_wsa_error(WSAGetLastError());
    return -1;
  }
  return (ssize_t)rc;
}

int tf_win32_poll(struct pollfd *fds, unsigned long nfds, int timeout) {
  if (nfds == 0) {
    if (timeout > 0) {
      Sleep((DWORD)timeout);
    }
    return 0;
  }
  if (fds == NULL || nfds > TF_WIN32_MAX_SOCKETS) {
    errno = EINVAL;
    return -1;
  }
  WSAPOLLFD wsa_fds[TF_WIN32_MAX_SOCKETS];
  for (unsigned long i = 0; i < nfds; i++) {
    SOCKET s = tf_win32_lookup_socket((int)fds[i].fd);
    if (s == INVALID_SOCKET) {
      errno = EBADF;
      return -1;
    }
    wsa_fds[i].fd = s;
    wsa_fds[i].events = fds[i].events;
    wsa_fds[i].revents = 0;
  }
  int rc = WSAPoll(wsa_fds, (ULONG)nfds, timeout);
  if (rc == SOCKET_ERROR) {
    errno = tf_win32_map_wsa_error(WSAGetLastError());
    return -1;
  }
  for (unsigned long i = 0; i < nfds; i++) {
    fds[i].revents = wsa_fds[i].revents;
  }
  return rc;
}

int tf_win32_close(int fd) {
  tf_win32_init_table();
  int idx = fd - TF_WIN32_SOCK_BASE;
  if (idx >= 0 && idx < TF_WIN32_MAX_SOCKETS && g_win32_sockets[idx] != INVALID_SOCKET) {
    SOCKET s = g_win32_sockets[idx];
    g_win32_sockets[idx] = INVALID_SOCKET;
    if (closesocket(s) != 0) {
      errno = tf_win32_map_wsa_error(WSAGetLastError());
      return -1;
    }
    return 0;
  }
#ifdef _MSC_VER
  return _close(fd);
#else
  return close(fd);
#endif
}

ssize_t getrandom(void *buf, size_t buflen, unsigned int flags) {
  (void)flags;
  if (buf == NULL && buflen > 0) {
    errno = EFAULT;
    return -1;
  }
  if (buflen > (size_t)ULONG_MAX) {
    errno = EINVAL;
    return -1;
  }
  if (buflen == 0) {
    return 0;
  }
  NTSTATUS status = BCryptGenRandom(NULL, (PUCHAR)buf, (ULONG)buflen, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  if (status < 0) {
    errno = EIO;
    return -1;
  }
  return (ssize_t)buflen;
}
