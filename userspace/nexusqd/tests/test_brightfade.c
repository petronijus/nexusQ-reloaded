/* userspace/nexusqd/tests/test_brightfade.c */
#include "test.h"
#include "brightfade.h"
#include <math.h>
#include <stdlib.h>

static double L(int level) { return pow(level / 255.0, 1.0 / 2.2); }

static void test_first_level_is_immediate(void) {
    /* the daemon starts at 255; the bridge's first level after a boot or a
     * restart must not fade down from it */
    struct brightfade bf; brightfade_init(&bf, 255);
    CHECK(brightfade_level(&bf, 0.0) == 255);
    CHECK(brightfade_set(&bf, 60, 3000, 10.0) == 1);
    CHECK(brightfade_level(&bf, 10.0) == 60);
    CHECK(!brightfade_active(&bf, 10.0));
}

static void test_fade_reaches_target(void) {
    struct brightfade bf; brightfade_init(&bf, 255);
    brightfade_set(&bf, 200, 0, 0.0);
    CHECK(brightfade_set(&bf, 50, 3000, 10.0) == 1);
    CHECK(brightfade_level(&bf, 10.0) == 200);          /* starts where it was */
    CHECK(brightfade_active(&bf, 11.5));
    int mid = brightfade_level(&bf, 11.5);
    CHECK(mid < 200 && mid > 50);
    CHECK(brightfade_level(&bf, 13.0) == 50);           /* lands exactly */
    CHECK(!brightfade_active(&bf, 13.0));
    CHECK(brightfade_level(&bf, 99.0) == 50);
}

static void test_monotonic(void) {
    struct brightfade bf; brightfade_init(&bf, 0);
    brightfade_set(&bf, 200, 0, 0.0);
    brightfade_set(&bf, 20, 3000, 1.0);
    int prev = 255;
    for (int i = 0; i <= 300; i++) {
        int l = brightfade_level(&bf, 1.0 + i * 0.01);
        CHECK(l <= prev);
        prev = l;
    }
}

static void test_perceptual_midpoint(void) {
    /* halfway in time is halfway in LIGHTNESS, not in duty: a duty-linear
     * 200 -> 50 fade would sit at 125 here, and look like a late drop */
    struct brightfade bf; brightfade_init(&bf, 0);
    brightfade_set(&bf, 200, 0, 0.0);
    brightfade_set(&bf, 50, 2000, 0.0);
    int mid = brightfade_level(&bf, 1.0);
    double want = 255.0 * pow((L(200) + L(50)) / 2.0, 2.2);
    CHECK(fabs(mid - want) <= 1.0);
    CHECK(mid < 115);
}

static void test_eased_ends(void) {
    /* smoothstep: the first and last 5 % of the time move far less than 5 %
     * of the way, so the transition has no visible start or stop */
    struct brightfade bf; brightfade_init(&bf, 0);
    brightfade_set(&bf, 255, 0, 0.0);
    brightfade_set(&bf, 10, 1000, 0.0);
    CHECK(255 - brightfade_level(&bf, 0.05) <= 5);
    CHECK(brightfade_level(&bf, 0.95) - 10 <= 2);
}

static void test_unchanged_target_is_noop(void) {
    struct brightfade bf; brightfade_init(&bf, 255);
    brightfade_set(&bf, 120, 0, 0.0);
    CHECK(brightfade_set(&bf, 120, 2000, 5.0) == 0);   /* the minute re-assert */
    CHECK(!brightfade_active(&bf, 5.0));
    /* nor does a re-assert of the target restart a fade in progress */
    brightfade_set(&bf, 40, 2000, 10.0);
    int at = brightfade_level(&bf, 11.0);
    CHECK(brightfade_set(&bf, 40, 2000, 11.0) == 0);
    CHECK(brightfade_level(&bf, 11.0) == at);
    CHECK(brightfade_level(&bf, 12.0) == 40);
}

static void test_reversal_never_jumps(void) {
    struct brightfade bf; brightfade_init(&bf, 0);
    brightfade_set(&bf, 200, 0, 0.0);
    brightfade_set(&bf, 30, 3000, 0.0);
    int at = brightfade_level(&bf, 1.2);
    brightfade_set(&bf, 200, 3000, 1.2);               /* switched back mid-fade */
    CHECK(abs(brightfade_level(&bf, 1.2) - at) <= 1);
    CHECK(brightfade_level(&bf, 4.2) == 200);
}

static void test_zero_ms_is_immediate(void) {
    struct brightfade bf; brightfade_init(&bf, 0);
    brightfade_set(&bf, 200, 0, 0.0);
    brightfade_set(&bf, 90, 0, 3.0);
    CHECK(brightfade_level(&bf, 3.0) == 90);
    CHECK(!brightfade_active(&bf, 3.0));
}

int main(void) {
    RUN(test_first_level_is_immediate); RUN(test_fade_reaches_target);
    RUN(test_monotonic); RUN(test_perceptual_midpoint); RUN(test_eased_ends);
    RUN(test_unchanged_target_is_noop); RUN(test_reversal_never_jumps);
    RUN(test_zero_ms_is_immediate);
    return REPORT();
}
