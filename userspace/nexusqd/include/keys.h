/* userspace/nexusqd/include/keys.h */
#ifndef NEXUSQD_KEYS_H
#define NEXUSQD_KEYS_H
#include <stdint.h>
#define KEY_MUTE 113
#define KEY_VOLUMEDOWN 114
#define KEY_VOLUMEUP 115
#define EV_KEY 1
#define INPUT_EVENT_SIZE ((int)(2*sizeof(long) + 8))
struct keyev { int code; int down; };
int keys_decode(const uint8_t *buf, int len, struct keyev *out, int max);
int keys_find_node(char *path, int pathlen);
#endif
