/* userspace/nexusqd/tests/test_audio.c */
#include "test.h"
#include "audio.h"

static int near(double a, double b) { double d = a - b; return (d < 0 ? -d : d) < 1e-4; }

static void test_silence(void) {
    int16_t s[256] = {0};
    CHECK(audio_mean_abs(s, 256) == 0.0f);
    CHECK(audio_mean_abs(s, 0) == 0.0f);
    CHECK(audio_mean_abs(s, -1) == 0.0f);
}
static void test_full_scale(void) {
    int16_t s[4] = { 32767, -32768, 32767, -32768 };
    /* mean(|s|/32768): (32767+32768+32767+32768)/4/32768 ~= 0.99998 */
    CHECK(near(audio_mean_abs(s, 4), (32767.0/32768 + 1.0 + 32767.0/32768 + 1.0) / 4.0));
}
static void test_half(void) {
    int16_t s[2] = { 16384, -16384 };   /* 0.5 each */
    CHECK(near(audio_mean_abs(s, 2), 0.5));
}
int main(void) { RUN(test_silence); RUN(test_full_scale); RUN(test_half); return REPORT(); }
