/* userspace/nexusqd/include/screensaver.h */
#ifndef NEXUSQD_SCREENSAVER_H
#define NEXUSQD_SCREENSAVER_H
#include "frame.h"

/* Idle LED screensaver (Plan 3) — pixel-perfect port of the factory ICS
 * ParticleScreensaver LED path (docs/2026-06-19-particle-screensaver-RE.md),
 * with the BaseScreensaver audio-driven fade (Plan 3b).
 *
 * The ring renders a uniform solid mColor=#0099CC that BREATHES:
 *   A        = screensaverAlpha * ledAlpha
 *   ledAlpha = lock ? 0.1 : 0.1 + 0.35*(1 - throb),  throb = cos(2*PI*fmod(t,10)/10)
 *   ring     = round(255 * channel * A), channel = (0, 0.6, 0.8); linear, no gamma
 *
 * screensaverAlpha is integrated frame-by-frame (BaseScreensaver.updateEffect):
 *   volume >= 0.01  -> elapsedWithoutAudio = 0; screensaverAlpha -= dt/1   (fade out)
 *   volume <  0.01  -> elapsedWithoutAudio += dt; once >5 s, screensaverAlpha += dt/5
 * lock after 300 s without audio; blank after `blank_timeout` s without activity. */

#define SS_TWO_PI      6.2831855f   /* matches the original float 2*PI constant */
#define SS_FADEIN_S    5.0          /* screensaverAlpha 0->1 ramp (mScreensaverFadeInSeconds) */
#define SS_FADEOUT_S   1.0          /* screensaverAlpha fade-out on audio (mSceneFadeSeconds) */
#define SS_PREFADEIN_S 5.0          /* mSecondsBeforeScreensaverFadeIn */
#define SS_LOCK_S      300.0        /* ledAlpha locks to 0.1 after this without audio */
#define SS_THROB_S     10.0         /* breath period */
#define SS_BLANK_S     600.0        /* default aah:blank_screensaver_timeout_s */
#define SS_AUDIO_THRESH 0.01f       /* AudioCapture volume gate */

struct screensaver {
    double sa;             /* screensaverAlpha, integrated 0..1 */
    double elapsed_no_audio;/* seconds since volume >= threshold (lock timer) */
    double last_activity;  /* monotonic s of last volume/mute key activity; <0 = none */
    double t;              /* last update timestamp (for throb + activity calc) */
    double blank_timeout;  /* seconds; <0 = never blank */
};

/* start the screensaver at `now` (elapsedSecondsWithoutAudio starts at 5, sa=0) */
void   screensaver_init(struct screensaver *ss, double now);
/* advance one frame: integrate screensaverAlpha + elapsedWithoutAudio from `volume` */
void   screensaver_update(struct screensaver *ss, double now, double dt, float volume);
/* volume/mute key activity at `now` — resets the blank timer */
void   screensaver_on_activity(struct screensaver *ss, double now);
/* breath value cos(2*PI*fmod(t,10)/10), range [-1,1] */
double screensaver_throb(double t);
/* total ring brightness A = screensaverAlpha*ledAlpha (0 when blanked) */
double screensaver_brightness(const struct screensaver *ss);
/* fill `out` with the uniform breathing ring color at the last update time */
void   screensaver_render(const struct screensaver *ss, struct frame *out);
#endif
