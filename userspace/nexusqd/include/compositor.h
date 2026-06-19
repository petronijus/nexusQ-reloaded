/* userspace/nexusqd/include/compositor.h */
#ifndef NEXUSQD_COMPOSITOR_H
#define NEXUSQD_COMPOSITOR_H
#include "frame.h"
struct layer { int (*render)(void *ctx, double t, struct frame *out); void *ctx; int priority; int active; };
struct compositor { struct layer layers[8]; int n; };
void comp_add(struct compositor *c, struct layer l);
void comp_render(struct compositor *c, double t, struct frame *out);
#endif
