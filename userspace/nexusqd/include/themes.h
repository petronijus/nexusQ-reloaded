/* userspace/nexusqd/include/themes.h */
#ifndef NEXUSQD_THEMES_H
#define NEXUSQD_THEMES_H
#include <stdint.h>
struct theme { char name[32]; uint8_t colors[16][3]; int n_colors; int led; int mode; };
int theme_parse(struct theme *out, const char *name, const char *json);
#endif
