/* userspace/nexusqd/include/compositor.h */
#ifndef NEXUSQD_COMPOSITOR_H
#define NEXUSQD_COMPOSITOR_H
#include "frame.h"
struct layer { int (*render)(void *ctx, double t, struct frame *out); void *ctx; int priority; int active; };
struct compositor { struct layer layers[8]; int n; };
void comp_add(struct compositor *c, struct layer l);
void comp_render(struct compositor *c, double t, struct frame *out);
/* comp_render restricted to layers with priority >= floor: everything below
 * the floor is treated as inactive, so if nothing at or above it draws, the
 * frame is black. This is the "ring off" gate — the floor sits at the music
 * layer, so the ring still reacts to music and to the volume knob but shows
 * nothing of its own (screensaver breath, theme, notifications). */
void comp_render_floor(struct compositor *c, double t, struct frame *out, int floor);
#endif
