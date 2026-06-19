/* userspace/nexusqd/src/screensaver.c */
#include "screensaver.h"
#include <math.h>

/* mColor = fromRgba(0.0, 0.6, 0.8); the LED path copies these channels verbatim
 * and LedController.toByte = Math.round(255 * channel) — linear, no gamma. */
static const float SS_R = 0.0f, SS_G = 0.6f, SS_B = 0.8f;

void screensaver_init(struct screensaver *ss, double now) {
    ss->sa = 0.0;                 /* mScreensaverAlpha defaults to 0 */
    ss->elapsed_no_audio = 5.0;   /* glInit: mElapsedSecondsWithoutAudio = 5 */
    ss->last_activity = -1.0;
    ss->t = now;
    ss->blank_timeout = SS_BLANK_S;
}

void screensaver_update(struct screensaver *ss, double now, double dt, float volume) {
    ss->t = now;
    if (volume < SS_AUDIO_THRESH) {
        ss->elapsed_no_audio += dt;
        if (ss->elapsed_no_audio > SS_PREFADEIN_S && ss->sa < 1.0) {
            ss->sa += dt / SS_FADEIN_S;
            if (ss->sa > 1.0) ss->sa = 1.0;
        }
    } else {
        ss->elapsed_no_audio = 0.0;       /* audio resets the no-audio timer */
        ss->sa -= dt / SS_FADEOUT_S;      /* screensaver fades out as music takes over */
        if (ss->sa < 0.0) ss->sa = 0.0;
    }
}

void screensaver_on_activity(struct screensaver *ss, double now) {
    ss->last_activity = now;
}

double screensaver_throb(double t) {
    double offset = fmod(t, SS_THROB_S) / SS_THROB_S;   /* (t_ms mod 10000)/10000 */
    return cos((double)SS_TWO_PI * offset);
}

double screensaver_brightness(const struct screensaver *ss) {
    int lock = ss->elapsed_no_audio > SS_LOCK_S;
    double ledAlpha = lock ? 0.1 : 0.1 + 0.35 * (1.0 - screensaver_throb(ss->t));

    /* secondsSinceLastActivity = min(elapsedWithoutAudio, now - lastVolumeChange) */
    double activity = ss->elapsed_no_audio;
    if (ss->last_activity >= 0.0) {
        double since = ss->t - ss->last_activity;
        if (since < activity) activity = since;
    }
    if (ss->blank_timeout >= 0.0 && activity > ss->blank_timeout) ledAlpha = 0.0;

    return ss->sa * ledAlpha;
}

void screensaver_render(const struct screensaver *ss, struct frame *out) {
    double A = screensaver_brightness(ss);
    /* mirror the original float pipeline: round(255 * (channel * A)) */
    int r = (int)lroundf(255.0f * (SS_R * (float)A));
    int g = (int)lroundf(255.0f * (SS_G * (float)A));
    int b = (int)lroundf(255.0f * (SS_B * (float)A));
    frame_fill(out, r, g, b);
}
