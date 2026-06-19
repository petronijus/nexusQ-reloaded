/* userspace/nexusqd/src/avr.c */
#include "avr.h"
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
static int write_file(const char *path, const void *buf, int len) {
    int fd = open(path, O_WRONLY); if (fd < 0) return -1;
    int w = (int)write(fd, buf, len); close(fd);
    return w == len ? 0 : -1;
}
int avr_write_frame(const uint8_t pk[RING*3], int commit) {
    char m[2] = { commit ? '1' : '0', 0 };
    write_file(AVR_SYSFS "/commit_mode", m, 1);
    return write_file(AVR_SYSFS "/frame", pk, RING*3);
}
int avr_set_mute(int r, int g, int b) {
    char s[16]; int n = snprintf(s, sizeof(s), "%d %d %d", r, g, b);
    return write_file(AVR_SYSFS "/mute", s, n);
}
