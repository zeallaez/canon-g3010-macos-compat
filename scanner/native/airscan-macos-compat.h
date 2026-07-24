#ifndef AIRSCAN_MACOS_COMPAT_H
#define AIRSCAN_MACOS_COMPAT_H

#ifdef __APPLE__
#include <stddef.h>
#include <sys/socket.h>

#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC 0x10000000
#endif

#ifndef SOCK_NONBLOCK
#define SOCK_NONBLOCK 0x20000000
#endif

int airscan_macos_socket(int domain, int type, int protocol);
int airscan_macos_pipe2(int fds[2], int flags);
void *airscan_macos_memrchr(const void *bytes, int value, size_t length);

#ifndef AIRSCAN_MACOS_COMPAT_IMPLEMENTATION
#define socket(domain, type, protocol) \
    airscan_macos_socket((domain), (type), (protocol))
#define pipe2(fds, flags) airscan_macos_pipe2((fds), (flags))
#define memrchr(bytes, value, length) \
    airscan_macos_memrchr((bytes), (value), (length))
#endif
#endif

#endif
