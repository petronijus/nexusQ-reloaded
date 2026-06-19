/* userspace/nexusqd/src/themes.c */
#include "themes.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

static int hexpair(const char *p) {
    char b[3] = { p[0], p[1], 0 }; return (int)strtol(b, NULL, 16);
}
/* find substring key then the next number after ':' */
static int int_after(const char *json, const char *key, int dflt) {
    const char *k = strstr(json, key);
    if (!k) return dflt;
    const char *c = strchr(k, ':');
    if (!c) return dflt;
    return (int)strtol(c + 1, NULL, 10);
}
int theme_parse(struct theme *out, const char *name, const char *json) {
    memset(out, 0, sizeof(*out));
    snprintf(out->name, sizeof(out->name), "%s", name);
    out->led  = int_after(json, "\"led\"", 1);
    out->mode = int_after(json, "\"mode\"", 1);
    const char *col = strstr(json, "\"colors\"");
    if (!col) return -1;
    const char *lb = strchr(col, '[');
    const char *rb = lb ? strchr(lb, ']') : NULL;
    if (!lb || !rb) return -1;
    int n = 0;
    for (const char *p = lb; p < rb && n < 16; p++) {
        if (*p == '#') {
            if (p + 7 > rb) return -1;
            out->colors[n][0] = (uint8_t)hexpair(p+1);
            out->colors[n][1] = (uint8_t)hexpair(p+3);
            out->colors[n][2] = (uint8_t)hexpair(p+5);
            n++;
        }
    }
    out->n_colors = n;
    return n > 0 ? 0 : -1;
}
