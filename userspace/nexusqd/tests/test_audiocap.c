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

/* Feed `frames` frames of a square wave of mean-abs `amp`, in chunks of
 * `chunk` frames (the bursts the tap delivers). */
static void feed_level(struct audio_state *a, float amp, int frames, int chunk) {
    static float buf[8192];
    for (int done = 0; done < frames; ) {
        int n = frames - done < chunk ? frames - done : chunk;
        for (int i = 0; i < n; i++) buf[i] = ((done + i) & 1) ? -amp : amp;
        audiocap_feed(a, buf, n);
        done += n;
    }
}

/* arecord -D pulse delivers ~130 ms bursts; one second of audio in eight
 * 6000-frame bursts, with no wall-clock time passing between them, is still
 * twenty segments: the cut follows the samples, not the wake-ups. */
static void test_segments_follow_the_sample_clock(void) {
    struct audio_state a; audiocap_init(&a);
    feed_level(&a, 0.1f, AUDIO_RATE, 6000);
    CHECK(audiocap_segments(&a) == SEGMENTS_PER_SECOND);
    audiocap_free(&a);
}

/* Quiet music (USB-audio input) whose raw level moves around -60 dBFS stays
 * present and keeps its gain on every segment. */
static void test_quiet_music_does_not_gate(void) {
    struct audio_state a; audiocap_init(&a);
    int flips = 0, gated = 0, prev = -1;
    for (int i = 0; i < 40; i++) {
        feed_level(&a, (i & 1) ? 0.0008f : 0.0015f, AUDIOCAP_HOP, AUDIOCAP_HOP);
        int p = audiocap_present(&a);
        if (prev >= 0 && p != prev) flips++;
        if (audiocap_volume(&a) <= 0.0f) gated++;
        prev = p;
    }
    CHECK(prev == 1);
    CHECK(flips == 0);
    CHECK(gated == 0);
    audiocap_free(&a);
}

/* A real stop is still seen: digital silence after music keeps audio present
 * through the hold, then releases it within one hop of the hold expiring. */
static void test_true_silence_releases_after_hold(void) {
    struct audio_state a; audiocap_init(&a);
    feed_level(&a, 0.02f, AUDIO_RATE, 4096);
    CHECK(audiocap_present(&a) == 1);
    int hold = AUDIOCAP_PRESENT_HOLD_FRAMES;
    feed_level(&a, 0.0f, hold - AUDIOCAP_HOP, 4096);
    CHECK(audiocap_present(&a) == 1);                  /* still inside the hold */
    feed_level(&a, 0.0f, 2 * AUDIOCAP_HOP, 4096);
    CHECK(audiocap_present(&a) == 0);                  /* released */
    audiocap_free(&a);
}

/* Inside the hold a fade tail below the presence threshold is still shown:
 * the AGC gain stays applied until the audio is declared absent. */
static void test_gain_stays_applied_during_the_hold(void) {
    struct audio_state a; audiocap_init(&a);
    feed_level(&a, 0.002f, AUDIO_RATE, 4096);
    feed_level(&a, 0.00005f, AUDIOCAP_HOP, AUDIOCAP_HOP);
    CHECK(audiocap_present(&a) == 1);
    CHECK(audiocap_volume(&a) > 0.0f);
    audiocap_free(&a);
}

/* Dither (~1 LSB) on an otherwise idle stream is not audio. */
static void test_dither_is_not_audio(void) {
    struct audio_state a; audiocap_init(&a);
    feed_level(&a, 1.0f / 32768.0f, AUDIO_RATE, 4096);
    CHECK(audiocap_present(&a) == 0);
    CHECK(audiocap_volume(&a) == 0.0f);
    audiocap_free(&a);
}

int main(void) {
    RUN(test_volume); RUN(test_beat_decay_on_silence); RUN(test_new_frame_latch);
    RUN(test_segments_follow_the_sample_clock); RUN(test_quiet_music_does_not_gate);
    RUN(test_true_silence_releases_after_hold); RUN(test_gain_stays_applied_during_the_hold);
    RUN(test_dither_is_not_audio);
    return REPORT();
}
