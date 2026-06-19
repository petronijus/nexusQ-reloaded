#include "frame.h"
static uint8_t clamp(int v) { return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v; }
void frame_black(struct frame *f) {
    for (int i = 0; i < RING; i++) f->px[i][0] = f->px[i][1] = f->px[i][2] = 0;
}
void frame_fill(struct frame *f, int r, int g, int b) {
    for (int i = 0; i < RING; i++) {
        f->px[i][0] = clamp(r); f->px[i][1] = clamp(g); f->px[i][2] = clamp(b);
    }
}
void frame_set(struct frame *f, int i, int r, int g, int b) {
    if (i < 0 || i >= RING) return;
    f->px[i][0] = clamp(r); f->px[i][1] = clamp(g); f->px[i][2] = clamp(b);
}
int frame_set_range(struct frame *f, int start, int count, const uint8_t (*rgb)[3]) {
    if (start < 0 || count < 0 || start + count > RING) return -1;
    for (int k = 0; k < count; k++)
        for (int c = 0; c < 3; c++) f->px[start+k][c] = rgb[k][c];
    return 0;
}
void frame_blend(struct frame *f, const struct frame *o, double a) {
    if (a < 0) a = 0;
    if (a > 1) a = 1;
    for (int i = 0; i < RING; i++)
        for (int c = 0; c < 3; c++)
            f->px[i][c] = clamp((int)(f->px[i][c] + (o->px[i][c] - f->px[i][c]) * a));
}
void frame_pack(const struct frame *f, uint8_t out[RING*3]) {
    for (int i = 0; i < RING; i++)
        for (int c = 0; c < 3; c++) out[i*3+c] = f->px[i][c];
}
