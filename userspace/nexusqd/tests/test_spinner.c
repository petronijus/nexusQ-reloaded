/* Host test for the spin animation: pure math, no AVR/hardware. */
#include "spinner.h"
#include "frame.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static int brightest(const struct frame *f) {
    int best = 0, sum = -1;
    for (int i = 0; i < RING; i++) {
        int s = f->px[i][0] + f->px[i][1] + f->px[i][2];
        if (s > sum) { sum = s; best = i; }
    }
    return best;
}

int main(void) {
    struct frame f;
    const int rgb[3] = { 0, 153, 204 };

    /* t=0: head at LED 0 with the full color (0 speed -> default rate) */
    spinner_render(rgb, 0.0, 0.0, &f);
    assert(brightest(&f) == 0);
    assert(f.px[0][0] == 0 && f.px[0][1] == 153 && f.px[0][2] == 204);

    /* the tail behind the head decays: LED 31 (one behind) dimmer than LED 0 */
    assert(f.px[31][1] < f.px[0][1] && f.px[31][1] > 0);

    /* LEDs outside the 8-LED tail are dark */
    assert(f.px[16][0] == 0 && f.px[16][1] == 0 && f.px[16][2] == 0);

    /* rotation: default 0.75 rev/s, t=1/3 s -> 0.25 rev -> head at LED 8 */
    spinner_render(rgb, 1.0 / 3.0, 0.0, &f);
    assert(brightest(&f) == 8);

    /* full revolution wraps: t = 4/3 s -> head back at LED 0 */
    spinner_render(rgb, 4.0 / 3.0, 0.0, &f);
    assert(brightest(&f) == 0);

    /* explicit speed: at 1.5 rev/s, t=1/6 s -> 0.25 rev -> head at LED 8 */
    spinner_render(rgb, 1.0 / 6.0, 1.5, &f);
    assert(brightest(&f) == 8);

    /* a negative/zero speed must fall back to the default, not divide/wrap oddly */
    struct frame f0, fdef;
    spinner_render(rgb, 0.4, 0.0, &f0);
    spinner_render(rgb, 0.4, SPIN_REV_PER_S, &fdef);
    assert(brightest(&f0) == brightest(&fdef));

    printf("test_spinner: OK\n");
    return 0;
}
