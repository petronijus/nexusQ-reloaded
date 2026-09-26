/* userspace/nexusqd/src/compositor.c */
#include "compositor.h"
#include <limits.h>
void comp_add(struct compositor *c, struct layer l) {
    if (c->n < 8) c->layers[c->n++] = l;
}
static int eligible(const struct layer *l, int floor) { return l->active && l->priority >= floor; }
void comp_render_floor(struct compositor *c, double t, struct frame *out, int floor) {
    int best = -1, bestpri = INT_MIN;
    for (int i = 0; i < c->n; i++)
        if (eligible(&c->layers[i], floor) && (best < 0 || c->layers[i].priority > bestpri)) { best = i; bestpri = c->layers[i].priority; }
    /* try from highest priority downward until one renders */
    while (best >= 0) {
        struct frame tmp;
        if (c->layers[best].render(c->layers[best].ctx, t, &tmp) == 0) { *out = tmp; return; }
        /* find next lower eligible */
        int nb = -1, npri = INT_MIN;
        for (int i = 0; i < c->n; i++)
            if (eligible(&c->layers[i], floor) && c->layers[i].priority < bestpri && (nb < 0 || c->layers[i].priority > npri)) { nb = i; npri = c->layers[i].priority; }
        best = nb; bestpri = npri;
    }
    frame_black(out);
}
void comp_render(struct compositor *c, double t, struct frame *out) {
    comp_render_floor(c, t, out, INT_MIN);
}
