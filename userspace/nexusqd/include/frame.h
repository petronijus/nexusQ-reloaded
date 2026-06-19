#ifndef NEXUSQD_FRAME_H
#define NEXUSQD_FRAME_H
#include <stdint.h>
#define RING 32
struct frame { uint8_t px[RING][3]; };
void frame_black(struct frame *f);
void frame_fill(struct frame *f, int r, int g, int b);
void frame_set(struct frame *f, int i, int r, int g, int b);
int  frame_set_range(struct frame *f, int start, int count, const uint8_t (*rgb)[3]);
void frame_blend(struct frame *f, const struct frame *other, double alpha);
void frame_pack(const struct frame *f, uint8_t out[RING*3]);
#endif
