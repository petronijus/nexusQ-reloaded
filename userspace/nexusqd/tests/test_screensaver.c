/* userspace/nexusqd/tests/test_screensaver.c */
#include "test.h"
#include "screensaver.h"

static int near(double a, double b) { double d = a - b; return (d < 0 ? -d : d) < 1e-6; }

static void px(const struct screensaver *ss, uint8_t *p) {
    struct frame f; screensaver_render(ss, &f); frame_pack(&f, p);
}

static void test_throb(void) {
    CHECK(near(screensaver_throb(0.0), 1.0));    /* cos(0) */
    CHECK(near(screensaver_throb(5.0), -1.0));   /* cos(pi) */
    CHECK(near(screensaver_throb(10.0), 1.0));   /* period 10 s */
    CHECK(near(screensaver_throb(2.5), 0.0));    /* cos(pi/2) */
}

static void test_fade_in_no_audio(void) {
    struct screensaver ss; screensaver_init(&ss, 0.0);   /* sa=0, elapsed=5 */
    CHECK(ss.sa == 0.0);
    /* integrate 6 s of silence in 0.1 s steps: elapsed 5->11, sa ramps after 5 -> 1 */
    double t = 0.0;
    for (int i = 0; i < 60; i++) { t += 0.1; screensaver_update(&ss, t, 0.1, 0.0f); }
    CHECK(ss.sa > 0.999);
    CHECK(ss.elapsed_no_audio > 10.9);
}

static void test_fade_out_on_audio(void) {
    struct screensaver ss; screensaver_init(&ss, 0.0);
    ss.sa = 1.0;                       /* settled */
    double t = 0.0;
    /* 1 s of audio in 0.1 s steps -> sa fades to 0, elapsed resets */
    for (int i = 0; i < 10; i++) { t += 0.1; screensaver_update(&ss, t, 0.1, 0.5f); }
    CHECK(ss.sa < 0.001);
    CHECK(ss.elapsed_no_audio == 0.0);
}

static void test_breath_colors(void) {
    struct screensaver ss; screensaver_init(&ss, 0.0);
    ss.sa = 1.0; ss.elapsed_no_audio = 10.0; ss.last_activity = -1.0; ss.blank_timeout = SS_BLANK_S;
    uint8_t p[RING*3];
    /* dim: throb=1 (t=10) -> A=0.1 -> #000F14 */
    ss.t = 10.0; px(&ss, p);
    CHECK(p[0]==0 && p[1]==15 && p[2]==20);
    /* peak: throb=-1 (t=5) -> ledAlpha 0.8 -> (0,122,163) */
    ss.t = 5.0; px(&ss, p);
    CHECK(p[0]==0 && p[1]==122 && p[2]==163);
    CHECK(p[RING*3-3]==0 && p[RING*3-2]==122 && p[RING*3-1]==163);   /* uniform */
}

static void test_lock(void) {
    struct screensaver ss; screensaver_init(&ss, 0.0);
    ss.sa = 1.0; ss.elapsed_no_audio = 400.0; ss.t = 5.0;   /* >300 -> locked 0.1 despite throb=-1 */
    CHECK(near(screensaver_brightness(&ss), 0.1));
}

static void test_blank(void) {
    struct screensaver ss; screensaver_init(&ss, 0.0);
    ss.sa = 1.0; ss.elapsed_no_audio = 700.0; ss.last_activity = -1.0; ss.t = 10.0;
    CHECK(near(screensaver_brightness(&ss), 0.0));          /* blank */
    uint8_t p[RING*3]; px(&ss, p);
    CHECK(p[0]==0 && p[1]==0 && p[2]==0);
    ss.last_activity = 5.0;                                  /* activity 5 s ago (t=10) -> not blank */
    CHECK(near(screensaver_brightness(&ss), 0.1));          /* locked dim, sa=1 */
}

int main(void) {
    RUN(test_throb); RUN(test_fade_in_no_audio); RUN(test_fade_out_on_audio);
    RUN(test_breath_colors); RUN(test_lock); RUN(test_blank);
    return REPORT();
}
