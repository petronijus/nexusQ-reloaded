/* userspace/nexusqd/src/sdnotify.c
 *
 * Minimal sd_notify(3) implementation (no libsystemd). Sends a single datagram
 * to the AF_UNIX socket named by $NOTIFY_SOCKET, supporting both filesystem and
 * Linux abstract ("@"-prefixed) socket names. Enough to drive the systemd
 * watchdog (WATCHDOG=1) and report readiness (READY=1).
 */
#define _GNU_SOURCE              /* musl: SOCK_CLOEXEC, MSG_NOSIGNAL */
#include "sdnotify.h"

#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

void sdnotify_send(const char *state)
{
    const char *path = getenv("NOTIFY_SOCKET");
    if (!path || !path[0] || !state || !state[0])
        return;                 /* not under systemd, or nothing to say */

    size_t plen = strlen(path);
    if (plen >= sizeof(((struct sockaddr_un *)0)->sun_path))
        return;                 /* pathological socket name */

    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return;

    struct sockaddr_un sa;
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    memcpy(sa.sun_path, path, plen + 1);

    socklen_t salen;
    if (sa.sun_path[0] == '@') {            /* abstract namespace */
        sa.sun_path[0] = '\0';
        salen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + plen);
    } else {
        salen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + plen + 1);
    }

    (void)sendto(fd, state, strlen(state), MSG_NOSIGNAL,
                 (struct sockaddr *)&sa, salen);
    close(fd);
}
