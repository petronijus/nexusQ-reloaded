/* userspace/nexusqd/src/control.c */
#include "control.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
static int rgb3(const char *a, const char *b, const char *c, int out[3]) {
    char *e;
    long v[3]; const char *s[3] = { a, b, c };
    for (int i = 0; i < 3; i++) {
        if (!s[i]) return -1;
        v[i] = strtol(s[i], &e, 10);
        if (*e != 0 || v[i] < 0 || v[i] > 255) return -1;
        out[i] = (int)v[i];
    }
    return 0;
}
int ctl_parse(const char *line, struct ctl_cmd *out) {
    char buf[128]; snprintf(buf, sizeof(buf), "%s", line);
    char *tok[5] = {0}; int n = 0;
    for (char *p = strtok(buf, " \t\r\n"); p && n < 5; p = strtok(NULL, " \t\r\n")) tok[n++] = p;
    if (n == 0) return -1;
    if (!strcmp(tok[0], "theme") && n == 2) {
        out->kind = CTL_THEME; snprintf(out->name, sizeof(out->name), "%s", tok[1]); return 0;
    }
    if (!strcmp(tok[0], "set") && n == 4)  { out->kind = CTL_SET;  return rgb3(tok[1],tok[2],tok[3], out->rgb); }
    if (!strcmp(tok[0], "mute") && n == 4) { out->kind = CTL_MUTE; return rgb3(tok[1],tok[2],tok[3], out->rgb); }
    if (!strcmp(tok[0], "off") && n == 1)    { out->kind = CTL_OFF; return 0; }
    if (!strcmp(tok[0], "status") && n == 1) { out->kind = CTL_STATUS; return 0; }
    if (!strcmp(tok[0], "mtoggle") && n == 1){ out->kind = CTL_MTOGGLE; return 0; }
    if (!strcmp(tok[0], "auto") && n == 1)   { out->kind = CTL_AUTO; return 0; }
    if (!strcmp(tok[0], "vol") && n == 2) {
        char *e; long v = strtol(tok[1], &e, 10);
        if (*e != 0 || v < 0 || v > 100) return -1;
        out->kind = CTL_VOL; out->value = (int)v; return 0;
    }
    return -1;
}
