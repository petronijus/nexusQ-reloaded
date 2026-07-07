/* userspace/nexusqd/include/audio.h */
#ifndef NEXUSQD_AUDIO_H
#define NEXUSQD_AUDIO_H
#include <stdint.h>

/* Plan 3b audio tap. The original used android.media.audiofx.Visualizer (a system
 * service) to capture the output mix; on postmarketOS the equivalent is a
 * PulseAudio MONITOR source. Audio is now PA-centric (PA is the hub; librespot and
 * every future input are PA clients, output = the PA default sink selectable via
 * the companion bridge). We spawn `arecord -D pulse` (the ALSA→PulseAudio plugin,
 * a system tool — keeps the daemon libc-only) which captures PA's DEFAULT SOURCE,
 * and read raw S16_LE stereo PCM from it. The companion bridge keeps the PA default
 * source pointed at the active sink's `<sink>.monitor`, so this tap follows the
 * selected output and reacts to WHATEVER is playing (Spotify now, BT/Tidal/cast
 * later), for ANY input.
 *
 * (The old design fanned librespot to an snd-aloop loopback and tapped
 * hw:Loopback,1; since librespot moved to PA that loopback is no longer fed. The
 * asound.conf `type multi` / snd-aloop loopback is now VESTIGIAL for the
 * visualizer — left installed for now, can be retired later.)
 *
 * getVolume (DefaultAudioCapture.onWaveFormDataCapture): the mean absolute
 * amplitude of the waveform normalized to [-1,1]. We compute the same metric over
 * 16-bit samples (sample/32768). */

#define AUDIO_DEVICE   "pulse"
#define AUDIO_RATE     48000
#define AUDIO_CHANNELS 2
/* seconds to wait before re-spawning arecord after it exits (e.g. `pulse` device
 * absent because PulseAudio is not up yet at boot — arecord just fails and we
 * retry until PA is up). Bounds the cost of a missing tap to one short-lived
 * arecord per interval instead of a busy-spin on the EOF'd pipe. */
#define AUDIO_RESPAWN_S 3.0

/* mean(|sample|/32768) over n S16 samples, in [0,1]; 0 if n<=0. (pure) */
float audio_mean_abs(const int16_t *samples, int n);
/* spawn arecord on AUDIO_DEVICE; return a non-blocking read fd for raw S16_LE
 * PCM, or -1 on failure. */
int   audio_open(void);

#endif
