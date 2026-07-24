#define AIRSCAN_MACOS_COMPAT_IMPLEMENTATION
#include "airscan-macos-compat.h"

#ifdef __APPLE__
#undef socket
#undef pipe2
#undef memrchr

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

static int
airscan_macos_apply_fd_flags(int fd, int flags)
{
    if ((flags & SOCK_NONBLOCK) != 0) {
        int value = fcntl(fd, F_GETFL);
        if (value < 0 || fcntl(fd, F_SETFL, value | O_NONBLOCK) < 0) {
            return -1;
        }
    }

    if ((flags & SOCK_CLOEXEC) != 0 &&
        fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
        return -1;
    }

    return 0;
}

int
airscan_macos_socket(int domain, int type, int protocol)
{
    int flags = type & (SOCK_CLOEXEC | SOCK_NONBLOCK);
    int fd = socket(domain, type & ~(SOCK_CLOEXEC | SOCK_NONBLOCK), protocol);

    if (fd < 0) {
        return fd;
    }

    if (airscan_macos_apply_fd_flags(fd, flags) < 0) {
        int saved_errno = errno;
        close(fd);
        errno = saved_errno;
        return -1;
    }

#ifdef SO_NOSIGPIPE
    int yes = 1;
    (void) setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif

    return fd;
}

int
airscan_macos_pipe2(int fds[2], int flags)
{
    if (pipe(fds) < 0) {
        return -1;
    }

    int socket_flags = 0;
    if ((flags & O_NONBLOCK) != 0) {
        socket_flags |= SOCK_NONBLOCK;
    }
    if ((flags & O_CLOEXEC) != 0) {
        socket_flags |= SOCK_CLOEXEC;
    }

    if (airscan_macos_apply_fd_flags(fds[0], socket_flags) < 0 ||
        airscan_macos_apply_fd_flags(fds[1], socket_flags) < 0) {
        int saved_errno = errno;
        close(fds[0]);
        close(fds[1]);
        errno = saved_errno;
        return -1;
    }

    return 0;
}

void *
airscan_macos_memrchr(const void *bytes, int value, size_t length)
{
    const unsigned char *cursor = (const unsigned char *) bytes + length;
    const unsigned char wanted = (unsigned char) value;

    while (cursor != (const unsigned char *) bytes) {
        cursor--;
        if (*cursor == wanted) {
            return (void *) cursor;
        }
    }

    return NULL;
}
#endif
