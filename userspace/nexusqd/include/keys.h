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

/* The front-panel keys are an input device that steelhead-avr registers when
 * it probes, and the AVR probes from udev coldplug, which nothing orders
 * nexusqd after; a reloaded or re-probed driver also takes the node away and
 * brings a new one. keywatch keeps looking for it: first at KEYS_RETRY_MIN_S,
 * doubling up to KEYS_RETRY_MAX_S while it stays absent, and again at the
 * minimum once a node it held is lost. */
#define KEYS_RETRY_MIN_S 0.5
#define KEYS_RETRY_MAX_S 8.0
typedef int (*keys_open_fn)(void *ctx);   /* an open fd, or -1 */
struct keywatch { int fd; double retry_at, backoff; };
void keywatch_init(struct keywatch *kw);
/* Opens the node when it is absent and a retry is due. Returns 1 when this call
 * opened it: the AVR has (re)appeared, and state it holds must be re-sent. */
int keywatch_tick(struct keywatch *kw, double now, keys_open_fn open_fn, void *ctx);
/* The node went away (POLLHUP/POLLERR, or a read error): close it and look for
 * the next one soon. */
void keywatch_lost(struct keywatch *kw, double now);
/* The real opener: keys_find_node() + open(O_RDONLY | O_NONBLOCK | O_CLOEXEC). */
int keys_open_node(void *ctx);
#endif
