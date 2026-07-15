/* userspace/nexusqd/src/spinner.c */
#include "spinner.h"
#include <math.h>

void spinner_render(const int rgb[3], double t, double rev_per_s, struct frame *out) {
    if (!(rev_per_s > 0.0)) rev_per_s = SPIN_REV_PER_S;
    frame_black(out);
    double pos = fmod(t * rev_per_s, 1.0);
    if (pos < 0) pos += 1.0;
    int head = (int)(pos * RING) % RING;
    double a = 1.0;
    for (int k = 0; k < SPIN_TAIL; k++) {
        int idx = (head - k + RING) % RING;
        frame_set(out, idx,
                  (int)(rgb[0] * a + 0.5),
                  (int)(rgb[1] * a + 0.5),
                  (int)(rgb[2] * a + 0.5));
        a *= 0.65;
    }
}
