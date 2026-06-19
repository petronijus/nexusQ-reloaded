/* userspace/nexusqd/src/keys.c */
#include "keys.h"
#include <string.h>
#include <stdio.h>
#include <glob.h>

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
