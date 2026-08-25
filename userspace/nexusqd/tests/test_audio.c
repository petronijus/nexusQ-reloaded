/* userspace/nexusqd/tests/test_audio.c */
#include "test.h"
#include "audio.h"
#include <string.h>


/* --- the sink-input gate's "Corked: no" counter (see audio.h) -------------
 * Real `pactl list sink-inputs` output, trimmed to the fields that matter. The
 * gate turns the LED tap on or off from this number, so an undercount blanks the
 * visualiser during real playback and an overcount keeps the amplifier powered
 * through silence. */
static const char TWO_LIVE_ONE_CORKED[] =
    "Sink Input #1\n"
    "\tDriver: module-loopback.c\n"
    "\tSink: 1\n"
    "\tMute: no\n"
    "\tCorked: no\n"
    "\tproperties:\n"
    "\t\tmedia.name = \"Loopback from USBAudio\"\n"
    "Sink Input #2\n"
    "\tDriver: protocol-native.c\n"
    "\tSink: 1\n"
    "\tMute: no\n"
    "\tCorked: yes\n"
    "\tproperties:\n"
    "\t\tmedia.name = \"Spotify\"\n"
    "Sink Input #3\n"
    "\tDriver: protocol-native.c\n"
    "\tSink: 1\n"
    "\tCorked: no\n";

static int scan_all(const char *text, size_t chunk) {
    struct pa_cork_scan s;
    pa_cork_scan_init(&s);
    size_t n = strlen(text);
    for (size_t i = 0; i < n; i += chunk) {
        size_t take = n - i < chunk ? n - i : chunk;
        pa_cork_scan_feed(&s, text + i, take);
    }
    return s.count;
}

static void test_counts_only_uncorked(void) {
    CHECK(scan_all(TWO_LIVE_ONE_CORKED, strlen(TWO_LIVE_ONE_CORKED)) == 2);
}

static void test_a_corked_only_listing_is_zero(void) {
    /* USB audio asleep: module-loopback is corked because its source is
     * suspended. The tap MUST go off, or the amp never powers down. */
    const char *only_corked =
        "Sink Input #1\n\tDriver: module-loopback.c\n\tCorked: yes\n";
    CHECK(scan_all(only_corked, strlen(only_corked)) == 0);
}

static void test_empty_and_failed_pactl_are_zero(void) {
    CHECK(scan_all("", 8) == 0);
    CHECK(scan_all("Failure: Connection refused\n", 8) == 0);
}

static void test_every_chunk_boundary_gives_the_same_count(void) {
    /* The whole reason this is a streaming scanner: a needle split across two
     * reads must still count once, and must never count twice. Feeding the same
     * text one byte at a time, two at a time, and so on must never change the
     * answer. */
    for (size_t chunk = 1; chunk <= 64; chunk++)
        CHECK(scan_all(TWO_LIVE_ONE_CORKED, chunk) == 2);
}

static void test_a_needle_split_across_reads_counts_once(void) {
    struct pa_cork_scan s;
    pa_cork_scan_init(&s);
    pa_cork_scan_feed(&s, "\tCorked: n", 10);   /* cut mid-needle */
    CHECK(s.count == 0);
    pa_cork_scan_feed(&s, "o\n", 2);
    CHECK(s.count == 1);
}

static void test_corked_yes_never_counts(void) {
    /* "Corked: no" is not a prefix of "Corked: not-a-field", but the guard that
     * matters is that "yes" can never be read as "no" by a sloppy compare. */
    const char *tricky = "Corked: yes\nCorked: no\nCorked: yes\n";
    for (size_t chunk = 1; chunk <= 16; chunk++)
        CHECK(scan_all(tricky, chunk) == 1);
}

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
int main(void) {
    RUN(test_silence); RUN(test_full_scale); RUN(test_half);
    RUN(test_counts_only_uncorked);
    RUN(test_a_corked_only_listing_is_zero);
    RUN(test_empty_and_failed_pactl_are_zero);
    RUN(test_every_chunk_boundary_gives_the_same_count);
    RUN(test_a_needle_split_across_reads_counts_once);
    RUN(test_corked_yes_never_counts);
    return REPORT();
}
