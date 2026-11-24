#ifndef TF_WIN32_SYS_SOCKET_H
#define TF_WIN32_SYS_SOCKET_H

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#elif _WIN32_WINNT < 0x0600
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <stddef.h>
#include <sys/types.h>
#ifdef _MSC_VER
#include <io.h>
#ifndef TF_WIN32_SSIZE_T_DEFINED
#define TF_WIN32_SSIZE_T_DEFINED
typedef ptrdiff_t ssize_t;
#endif
#else
#include <unistd.h>
#endif

#include <winsock2.h>
#include <ws2tcpip.h>

#ifndef AF_UNIX
#define AF_UNIX 1
#endif

#ifndef MSG_DONTWAIT
#define MSG_DONTWAIT 0x40000000
#endif

int tf_win32_socket(int domain, int type, int protocol);
int tf_win32_socketpair(int domain, int type, int protocol, int sv[2]);
int tf_win32_connect(int fd, const struct sockaddr *addr, socklen_t addrlen);
int tf_win32_getsockname(int fd, struct sockaddr *addr, socklen_t *addrlen);
ssize_t tf_win32_send(int fd, const void *buf, size_t len, int flags);
ssize_t tf_win32_sendto(int fd, const void *buf, size_t len, int flags, const struct sockaddr *dest_addr,
                        socklen_t addrlen);
ssize_t tf_win32_recv(int fd, void *buf, size_t len, int flags);
int tf_win32_poll(struct pollfd *fds, unsigned long nfds, int timeout);
int tf_win32_close(int fd);

#ifndef TF_WIN32_COMPAT_IMPL
#define socket tf_win32_socket
#define socketpair tf_win32_socketpair
#define connect tf_win32_connect
#define getsockname tf_win32_getsockname
#define send tf_win32_send
#define sendto tf_win32_sendto
#define recv tf_win32_recv
#define poll tf_win32_poll
#define close tf_win32_close
#endif

#endif
