/* userspace/nexusqd/src/screensaver.c */
#include "screensaver.h"
#include <math.h>

/* mColor = fromRgba(0.0, 0.6, 0.8); the LED path copies these channels verbatim
 * and LedController.toByte = Math.round(255 * channel) — linear, no gamma. */
static const float SS_R = 0.0f, SS_G = 0.6f, SS_B = 0.8f;

void screensaver_init(struct screensaver *ss, double now) {
    /* glInit sets mElapsedSecondsWithoutAudio = 5 → as if audio ended 5 s ago */
    ss->last_audio = now - 5.0;
    ss->last_activity = -1.0;
    ss->blank_timeout = SS_BLANK_S;
}

void screensaver_on_audio(struct screensaver *ss, double now) {
    ss->last_audio = now;                 /* elapsedSecondsWithoutAudio -> 0 */
}

void screensaver_on_activity(struct screensaver *ss, double now) {
    ss->last_activity = now;              /* resets the blank timer */
}

double screensaver_alpha(const struct screensaver *ss, double now) {
    /* screensaverAlpha ramps once elapsedSecondsWithoutAudio > 5, over 5 s */
    double elapsed = now - ss->last_audio;
    double sa = (elapsed - 5.0) / SS_FADEIN_S;
    if (sa < 0.0) sa = 0.0;
    if (sa > 1.0) sa = 1.0;
    return sa;
}

double screensaver_throb(double now) {
    double offset = fmod(now, SS_THROB_S) / SS_THROB_S;   /* (t_ms mod 10000)/10000 */
    return cos((double)SS_TWO_PI * offset);
}

double screensaver_brightness(const struct screensaver *ss, double now) {
    double elapsed = now - ss->last_audio;                /* elapsedSecondsWithoutAudio */
    double sa = screensaver_alpha(ss, now);

    int lock = elapsed > SS_LOCK_S;
    double ledAlpha = lock ? 0.1 : 0.1 + 0.35 * (1.0 - screensaver_throb(now));

    /* secondsSinceLastActivity = min(elapsedWithoutAudio, now - lastVolumeChange) */
    double activity = elapsed;
    if (ss->last_activity >= 0.0) {
        double since = now - ss->last_activity;
        if (since < activity) activity = since;
    }
    if (ss->blank_timeout >= 0.0 && activity > ss->blank_timeout) ledAlpha = 0.0;

    return sa * ledAlpha;
}

void screensaver_render(const struct screensaver *ss, double now, struct frame *out) {
    double A = screensaver_brightness(ss, now);
    /* mirror the original float pipeline: round(255 * (channel * A)) */
    int r = (int)lroundf(255.0f * (SS_R * (float)A));
    int g = (int)lroundf(255.0f * (SS_G * (float)A));
    int b = (int)lroundf(255.0f * (SS_B * (float)A));
    frame_fill(out, r, g, b);
}
