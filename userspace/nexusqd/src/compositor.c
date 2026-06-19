/* userspace/nexusqd/src/compositor.c */
#include "compositor.h"
void comp_add(struct compositor *c, struct layer l) {
    if (c->n < 8) c->layers[c->n++] = l;
}
void comp_render(struct compositor *c, double t, struct frame *out) {
    int best = -1, bestpri = -1;
    for (int i = 0; i < c->n; i++)
        if (c->layers[i].active && c->layers[i].priority > bestpri) { best = i; bestpri = c->layers[i].priority; }
    /* try from highest priority downward until one renders */
    while (best >= 0) {
        struct frame tmp;
        if (c->layers[best].active && c->layers[best].render(c->layers[best].ctx, t, &tmp) == 0) { *out = tmp; return; }
        /* find next lower active */
        int nb = -1, npri = -1;
        for (int i = 0; i < c->n; i++)
            if (c->layers[i].active && c->layers[i].priority < bestpri && c->layers[i].priority > npri) { nb = i; npri = c->layers[i].priority; }
        best = nb; bestpri = npri;
    }
    frame_black(out);
}
