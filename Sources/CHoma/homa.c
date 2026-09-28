#include "CHoma.h"
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>

#ifdef __linux__
#include <arpa/inet.h>
#include <netdb.h>
#include <pthread.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

/* Layout and constants from PlatformLab/HomaModule homa.h, main branch,
 * reviewed 2026-09-28. Keep in sync with the installed kernel module. */
#define CHOMA_PROTOCOL 146
#define CHOMA_MAX_MESSAGE 1000000
#define CHOMA_PAGE_SIZE 65536
#define CHOMA_MAX_PAGES 16
#define CHOMA_RCVBUF 10
#define CHOMA_POOL_SIZE (32 * 1024 * 1024)

struct choma_send_args { uint64_t id, completion_cookie; uint32_t flags, reserved; };
struct choma_recv_args {
    uint64_t id, completion_cookie;
    uint32_t num_bpages, reserved;
    uint32_t bpage_offsets[CHOMA_MAX_PAGES];
};
struct choma_pool_args { uint64_t start, length; };

_Static_assert(sizeof(struct choma_send_args) == 24, "Homa send UAPI layout changed");
_Static_assert(sizeof(struct choma_recv_args) == 88, "Homa receive UAPI layout changed");
_Static_assert(sizeof(struct choma_pool_args) == 16, "Homa pool UAPI layout changed");

struct choma_socket {
    int fd;
    uint8_t *pool;
    size_t pool_size;
    struct sockaddr_storage destination;
    socklen_t destination_length;
    pthread_mutex_t receive_lock;
    struct choma_recv_args recycle;
};

choma_socket *choma_open(const char *host, uint16_t port, int server) {
    if (server && (port == 0 || port >= 32768)) { errno = EINVAL; return NULL; }
    choma_socket *handle = calloc(1, sizeof(*handle));
    if (!handle) return NULL;
    handle->fd = -1;
    pthread_mutex_init(&handle->receive_lock, NULL);
    struct addrinfo hints = {0}, *result = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    /* Resolve an IPv4 datagram address without asking libc to recognize Homa. */
    hints.ai_protocol = 0;
    hints.ai_flags = server ? AI_PASSIVE : 0;
    char port_text[8];
    snprintf(port_text, sizeof(port_text), "%u", port);
    int status = getaddrinfo(host, port_text, &hints, &result);
    if (status != 0 || !result) { errno = EINVAL; goto fail; }
    handle->fd = socket(AF_INET, SOCK_DGRAM, CHOMA_PROTOCOL);
    if (handle->fd < 0) goto fail;
    if (server) {
        if (bind(handle->fd, result->ai_addr, result->ai_addrlen) < 0) goto fail;
    } else {
        memcpy(&handle->destination, result->ai_addr, result->ai_addrlen);
        handle->destination_length = result->ai_addrlen;
    }
    freeaddrinfo(result);
    result = NULL;
    handle->pool_size = CHOMA_POOL_SIZE;
    handle->pool = mmap(NULL, handle->pool_size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (handle->pool == MAP_FAILED) { handle->pool = NULL; goto fail; }
    struct choma_pool_args pool = {(uint64_t)(uintptr_t)handle->pool, handle->pool_size};
    if (setsockopt(handle->fd, CHOMA_PROTOCOL, CHOMA_RCVBUF, &pool, sizeof(pool)) < 0) goto fail;
    return handle;
fail:
    { int saved = errno;
      if (result) freeaddrinfo(result);
      choma_close(handle);
      errno = saved;
      return NULL; }
}

int choma_send(choma_socket *socket, const void *bytes, size_t length,
               uint64_t id, uint64_t cookie, const void *peer, uint32_t peer_length) {
    if (!socket || !bytes || length == 0 || length > CHOMA_MAX_MESSAGE) { errno = EINVAL; return -1; }
    struct choma_send_args args = {id, cookie, 0, 0};
    struct iovec iov = {(void *)bytes, length};
    struct msghdr msg = {0};
    if (id) { msg.msg_name = (void *)peer; msg.msg_namelen = peer_length; }
    else { msg.msg_name = &socket->destination; msg.msg_namelen = socket->destination_length; }
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = &args;
    msg.msg_controllen = 0; /* Required by Homa sendmsg. */
    return sendmsg(socket->fd, &msg, 0) < 0 ? -1 : 0;
}

int choma_receive(choma_socket *socket, void **bytes, size_t *length,
                  uint64_t *id, uint64_t *cookie, void *peer, uint32_t *peer_length) {
    if (!socket || !bytes || !length || !id || !cookie || !peer || !peer_length) { errno = EINVAL; return -1; }
    *bytes = NULL; *length = 0; *id = 0; *cookie = 0;
    pthread_mutex_lock(&socket->receive_lock);
    struct choma_recv_args args = socket->recycle;
    args.id = 0;
    args.completion_cookie = 0;
    struct msghdr msg = {0};
    msg.msg_name = peer;
    msg.msg_namelen = *peer_length;
    msg.msg_control = &args;
    msg.msg_controllen = sizeof(args);
    ssize_t n = recvmsg(socket->fd, &msg, 0);
    /* When recvmsg returns an error, input pages may still be ours. */
    if (n < 0) {
        socket->recycle = args;
        *id = args.id;
        *cookie = args.completion_cookie;
        pthread_mutex_unlock(&socket->receive_lock);
        return -1;
    }
    socket->recycle = args;
    *id = args.id;
    *cookie = args.completion_cookie;
    *peer_length = msg.msg_namelen;
    if (n > CHOMA_MAX_MESSAGE || args.num_bpages > CHOMA_MAX_PAGES) {
        errno = EMSGSIZE; pthread_mutex_unlock(&socket->receive_lock); return -1;
    }
    uint8_t *copy = malloc(n ? (size_t)n : 1);
    if (!copy) { errno = ENOMEM; pthread_mutex_unlock(&socket->receive_lock); return -1; }
    size_t remaining = (size_t)n, offset = 0;
    for (uint32_t i = 0; i < args.num_bpages && remaining; ++i) {
        size_t chunk = remaining < CHOMA_PAGE_SIZE ? remaining : CHOMA_PAGE_SIZE;
        if ((size_t)args.bpage_offsets[i] + chunk > socket->pool_size) {
            free(copy); errno = EFAULT; pthread_mutex_unlock(&socket->receive_lock); return -1;
        }
        memcpy(copy + offset, socket->pool + args.bpage_offsets[i], chunk);
        remaining -= chunk; offset += chunk;
    }
    if (remaining) { free(copy); errno = EFAULT; pthread_mutex_unlock(&socket->receive_lock); return -1; }
    *bytes = copy; *length = (size_t)n;
    pthread_mutex_unlock(&socket->receive_lock);
    return 0;
}

void choma_free(void *bytes) { free(bytes); }
void choma_shutdown(choma_socket *socket) {
    if (socket && socket->fd >= 0) shutdown(socket->fd, SHUT_RDWR);
}
void choma_close(choma_socket *socket) {
    if (!socket) return;
    if (socket->fd >= 0) { shutdown(socket->fd, SHUT_RDWR); close(socket->fd); }
    if (socket->pool) munmap(socket->pool, socket->pool_size);
    pthread_mutex_destroy(&socket->receive_lock);
    free(socket);
}
#else
struct choma_socket { int unused; };
choma_socket *choma_open(const char *host, uint16_t port, int server) {
    (void)host; (void)port; (void)server; errno = ENOTSUP; return NULL;
}
int choma_send(choma_socket *socket, const void *bytes, size_t length,
               uint64_t id, uint64_t cookie, const void *peer, uint32_t peer_length) {
    (void)socket; (void)bytes; (void)length; (void)id; (void)cookie; (void)peer; (void)peer_length;
    errno = ENOTSUP; return -1;
}
int choma_receive(choma_socket *socket, void **bytes, size_t *length,
                  uint64_t *id, uint64_t *cookie, void *peer, uint32_t *peer_length) {
    (void)socket; (void)bytes; (void)length; (void)id; (void)cookie; (void)peer; (void)peer_length;
    errno = ENOTSUP; return -1;
}
void choma_free(void *bytes) { free(bytes); }
void choma_shutdown(choma_socket *socket) { (void)socket; }
void choma_close(choma_socket *socket) { free(socket); }
#endif
