/* userspace/nexusqd/src/keys.c */
#define _POSIX_C_SOURCE 200809L   /* O_CLOEXEC, glob() under -std=c11 */
#include "keys.h"
#include <string.h>
#include <stdio.h>
#include <glob.h>
#include <fcntl.h>
#include <unistd.h>

int keys_decode(const uint8_t *buf, int len, struct keyev *out, int max) {
    int n = 0;
    const int rec = INPUT_EVENT_SIZE, off_t_ = 2*(int)sizeof(long);
    for (int o = 0; o + rec <= len && n < max; o += rec) {
        uint16_t type, code; int32_t value;
        memcpy(&type, buf+o+off_t_, 2);
        memcpy(&code, buf+o+off_t_+2, 2);
        memcpy(&value, buf+o+off_t_+4, 4);
        if (type == EV_KEY && (value == 0 || value == 1)) {
            out[n].code = code; out[n].down = (value == 1); n++;
        }
    }
    return n;
}
int keys_find_node(char *path, int pathlen) {
    glob_t g;
    if (glob("/sys/class/input/event*/device/name", 0, NULL, &g) != 0) return -1;
    int rc = -1;
    for (size_t i = 0; i < g.gl_pathc; i++) {
        FILE *fp = fopen(g.gl_pathv[i], "r");
        if (!fp) continue;
        char nm[64] = {0};
        char *got = fgets(nm, sizeof(nm), fp);
        fclose(fp);
        if (!got) continue;
        char *nl = strchr(nm, '\n'); if (nl) *nl = 0;
        if (strcmp(nm, "steelhead-avr-keys") == 0) {
            /* /sys/class/input/eventN/device/name -> eventN is the path component */
            char *p = g.gl_pathv[i] + strlen("/sys/class/input/");
            char *slash = strchr(p, '/'); if (slash) *slash = 0;
            snprintf(path, pathlen, "/dev/input/%s", p);
            rc = 0; break;
        }
    }
    globfree(&g);
    return rc;
}

void keywatch_init(struct keywatch *kw) {
    kw->fd = -1; kw->retry_at = 0.0; kw->backoff = KEYS_RETRY_MIN_S;
}
int keywatch_tick(struct keywatch *kw, double now, keys_open_fn open_fn, void *ctx) {
    if (kw->fd >= 0 || now < kw->retry_at) return 0;
    kw->fd = open_fn(ctx);
    if (kw->fd >= 0) { kw->backoff = KEYS_RETRY_MIN_S; return 1; }
    kw->retry_at = now + kw->backoff;
    kw->backoff = kw->backoff * 2 > KEYS_RETRY_MAX_S ? KEYS_RETRY_MAX_S : kw->backoff * 2;
    return 0;
}
void keywatch_lost(struct keywatch *kw, double now) {
    if (kw->fd >= 0) close(kw->fd);
    kw->fd = -1;   /* backoff is at the minimum since the open that set fd */
    kw->retry_at = now + KEYS_RETRY_MIN_S;   /* the old node is still going away */
}
int keys_open_node(void *ctx) {
    (void)ctx;
    char node[64];
    if (keys_find_node(node, sizeof(node)) != 0) return -1;
    return open(node, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
}
