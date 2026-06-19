/* userspace/nexusqd/tests/test_audiocap.c */
#include "test.h"
#include "audiocap.h"

static int near(float a, float b) { float d = a - b; return (d < 0 ? -d : d) < 1e-5f; }

static void test_volume(void) {
    struct audio_state a; audiocap_init(&a);
    float seg[SAMPLES_PER_SEGMENT];
    for (int i = 0; i < SAMPLES_PER_SEGMENT; i++) seg[i] = 0.0f;
    audiocap_on_segment(&a, seg);
    CHECK(near(audiocap_volume(&a), 0.0f));
    for (int i = 0; i < SAMPLES_PER_SEGMENT; i++) seg[i] = 0.5f;
    audiocap_on_segment(&a, seg);
    CHECK(near(audiocap_volume(&a), 0.5f));            /* mean(|0.5|) */
    for (int i = 0; i < SAMPLES_PER_SEGMENT; i++) seg[i] = (i & 1) ? -1.0f : 1.0f;
    audiocap_on_segment(&a, seg);
    CHECK(near(audiocap_volume(&a), 1.0f));            /* mean(|±1|) */
    audiocap_free(&a);
}

static void test_beat_decay_on_silence(void) {
    struct audio_state a; audiocap_init(&a);
    a.smoothed_beat_energy = 10.0f;
    float seg[SAMPLES_PER_SEGMENT];
    for (int i = 0; i < SAMPLES_PER_SEGMENT; i++) seg[i] = 0.0f;
    audiocap_on_segment(&a, seg);                       /* volume<0.01 -> *0.7 */
    CHECK(near(audiocap_smoothed_beat(&a), 7.0f));
    audiocap_on_segment(&a, seg);
    CHECK(near(audiocap_smoothed_beat(&a), 4.9f));
    audiocap_free(&a);
}

static void test_new_frame_latch(void) {
    struct audio_state a; audiocap_init(&a);
    a.beat_next_frame = 1;
    audiocap_on_new_frame(&a);
    CHECK(audiocap_beat_this_frame(&a) == 1);
    audiocap_on_new_frame(&a);
    CHECK(audiocap_beat_this_frame(&a) == 0);
    audiocap_free(&a);
}

int main(void) {
    RUN(test_volume); RUN(test_beat_decay_on_silence); RUN(test_new_frame_latch);
    return REPORT();
}
