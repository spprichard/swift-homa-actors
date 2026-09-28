#ifndef CHOMA_H
#define CHOMA_H
#include <stdint.h>
#include <stddef.h>

typedef struct choma_socket choma_socket;

/* Returns NULL with errno=ENOTSUP on non-Linux platforms. */
choma_socket *choma_open(const char *host, uint16_t port, int server);
/* id=0 initiates a request; nonzero id sends a response to the last sender. */
int choma_send(choma_socket *socket, const void *bytes, size_t length,
               uint64_t id, uint64_t cookie, const void *peer, uint32_t peer_length);
/* Copies the received message before recycling Homa buffer pages. Caller frees bytes. */
int choma_receive(choma_socket *socket, void **bytes, size_t *length,
                  uint64_t *id, uint64_t *cookie, void *peer, uint32_t *peer_length);
void choma_free(void *bytes);
void choma_shutdown(choma_socket *socket);
void choma_close(choma_socket *socket);
#endif
