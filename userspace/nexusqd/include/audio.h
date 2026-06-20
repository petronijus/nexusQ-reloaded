/* userspace/nexusqd/include/audio.h */
#ifndef NEXUSQD_AUDIO_H
#define NEXUSQD_AUDIO_H
#include <stdint.h>

/* Plan 3b audio tap. The original used android.media.audiofx.Visualizer (a system
 * service) to capture the output mix; on postmarketOS the equivalent is the ALSA
 * loopback (snd-aloop): play to hw:Loopback,0, capture the same PCM from
 * hw:Loopback,1. We spawn `arecord` (a system tool — keeps the daemon libc-only)
 * and read raw S16_LE stereo PCM from it.
 *
 * getVolume (DefaultAudioCapture.onWaveFormDataCapture): the mean absolute
 * amplitude of the waveform normalized to [-1,1]. We compute the same metric over
 * 16-bit samples (sample/32768). */

#define AUDIO_DEVICE   "hw:Loopback,1"
#define AUDIO_RATE     48000
#define AUDIO_CHANNELS 2
/* seconds to wait before re-spawning arecord after it exits (e.g. hw:Loopback,1
 * absent because snd-aloop is not loaded). Bounds the cost of a missing tap to one
 * short-lived arecord per interval instead of a busy-spin on the EOF'd pipe. */
#define AUDIO_RESPAWN_S 3.0

/* mean(|sample|/32768) over n S16 samples, in [0,1]; 0 if n<=0. (pure) */
float audio_mean_abs(const int16_t *samples, int n);
/* spawn arecord on AUDIO_DEVICE; return a non-blocking read fd for raw S16_LE
 * PCM, or -1 on failure. */
int   audio_open(void);

#endif
