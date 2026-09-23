/* userspace/nexusqd/src/nexusled.c */
#define _POSIX_C_SOURCE 200809L   /* AF_UNIX/sockaddr_un, read/write under -std=c11 */
#include "avr.h"
#include "frame.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define SOCK "/run/nexusqd.sock"

static int send_sock(const char *line) {
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) return -1;
    struct sockaddr_un sa = { .sun_family = AF_UNIX }; strcpy(sa.sun_path, SOCK);
    if (connect(s, (struct sockaddr*)&sa, sizeof(sa)) != 0) { close(s); return -1; }
    if (write(s, line, strlen(line)) < 0) { close(s); return -1; }
    /* Drain to EOF rather than one short read: `debug` answers with a state
     * line far longer than the "ok\n" every other verb returns, and a fixed
     * 64-byte read would silently truncate it mid-field. */
    char r[256]; int n;
    while ((n = (int)read(s, r, sizeof(r)-1)) > 0) { r[n] = 0; fputs(r, stdout); }
    close(s); return 0;
}
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: nexusled set R G B | theme NAME | off | mute R G B | all R G B | dark 0|1 | attend 0|1 | status | debug\n"); return 2; }
    char line[128] = {0};
    const char *verb = strcmp(argv[1], "all") == 0 ? "set" : argv[1];
    int p = snprintf(line, sizeof(line), "%s", verb);
    for (int i = 2; i < argc; i++) p += snprintf(line+p, sizeof(line)-p, " %s", argv[i]);
    if (send_sock(line) == 0) return 0;
    /* fallback: direct sysfs for set/all/off */
    struct frame f; frame_black(&f);
    if ((!strcmp(verb,"set")) && argc == 5) frame_fill(&f, atoi(argv[2]), atoi(argv[3]), atoi(argv[4]));
    uint8_t pk[RING*3]; frame_pack(&f, pk); avr_write_frame(pk, 0);
    printf("ok (direct)\n"); return 0;
}
