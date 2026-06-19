/* userspace/nexusqd/include/ledcfg.h
 * Mirror of led/LedConfiguration + LedController.toByte. A per-frame ring
 * description: either a SOLID color (uniform) or a per-LED float buffer (0..1).
 * ledcfg_to_frame applies toByte = round(255*f) (linear, no gamma) exactly. */
#ifndef NEXUSQD_LEDCFG_H
#define NEXUSQD_LEDCFG_H
#include "frame.h"

struct ledcfg {
    int   solid;               /* 1 = FillType.SOLID, 0 = LED_BUFFER */
    float solid_color[3];
    float buf[RING * 3];
};

void   ledcfg_reset(struct ledcfg *c);        /* configureSolidBlack + zero the buffer */
float *ledcfg_solid(struct ledcfg *c);        /* configureSolidColor() -> solid_color */
float *ledcfg_buffer(struct ledcfg *c);       /* configureLedBuffer() -> buf */
void   ledcfg_to_frame(const struct ledcfg *c, struct frame *out);

/* Color.putRgbInBuffer(buffer, off, scaleByAlpha=true): buffer[off+k] = rgb[k]*alpha */
void   put_rgb_scaled(float *buffer, int off, const float rgb[3], float alpha);

#endif
