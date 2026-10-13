#ifndef OVERNET_BRIDGE_IO_H
#define OVERNET_BRIDGE_IO_H
#include <stddef.h>
/* Returns a checked, complete response only after a successful child exit.
 * The caller frees *response. Paths and environment belong to the trusted local
 * harness, never to the IMAP client. Linux/glibc development harness only. */
int overnet_bridge_request(const char *helper, const char *config,
                          const char *request, size_t limit,
                          unsigned char **response, size_t *length);
#endif
