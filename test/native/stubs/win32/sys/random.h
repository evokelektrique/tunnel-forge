#ifndef TF_WIN32_SYS_RANDOM_H
#define TF_WIN32_SYS_RANDOM_H

#include <stddef.h>
#include <sys/types.h>
#ifdef _MSC_VER
#ifndef TF_WIN32_SSIZE_T_DEFINED
#define TF_WIN32_SSIZE_T_DEFINED
typedef ptrdiff_t ssize_t;
#endif
#endif

ssize_t getrandom(void *buf, size_t buflen, unsigned int flags);

#endif
