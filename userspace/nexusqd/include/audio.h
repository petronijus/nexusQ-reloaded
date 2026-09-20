/* userspace/nexusqd/include/audio.h */
#ifndef NEXUSQD_AUDIO_H
#define NEXUSQD_AUDIO_H
#include <stdint.h>
#include <sys/types.h>   /* pid_t */

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
 * PCM, or -1 on failure, and store the arecord child pid in *pid (or -1) so
 * audio_close() can terminate it. */
int   audio_open(pid_t *pid);
/* stop the tap: SIGTERM the arecord child (*pid) and close the read fd (*fd).
 * Closing the read end also makes arecord die on its next write (SIGPIPE) even
 * if the pid is stale/racy — arecord writes every capture period, so it exits
 * within ~one period regardless. Safe with *fd<0 / *pid<0. Resets *fd and *pid. */
void  audio_close(int *fd, pid_t *pid);

/* Sink-input gate (idle-CPU fix, see audio.c): return how many PA playback
 * streams are actually FEEDING the sink -- sink-inputs that are not corked -- or
 * 0 if pactl fails / PulseAudio is down (safe: no streams -> keep the tap off).
 *
 * Corked inputs are excluded deliberately. A corked stream still appears in
 * `pactl list short sink-inputs`, so the old line count kept this tap running
 * while nothing was being played, and the tap is exactly what holds the sink out
 * of suspend-on-idle. That cost 1.60 % of a core and left the amplifier powered
 * whenever the USB-audio watcher put its source to sleep, and equally for any
 * paused stream. */
int   pa_sink_inputs_active(void);

/* Streaming counter behind it, exposed for tests: the verbose listing arrives in
 * arbitrary read chunks and a "Corked: no" split across two of them must still
 * count exactly once. PA_CORK_WIN only has to exceed the needle; it is the
 * scratch window, not a limit on the listing. */
#define PA_CORK_WIN 512
struct pa_cork_scan {
    char   carry[PA_CORK_WIN];
    size_t clen;
    int    count;
};
void pa_cork_scan_init(struct pa_cork_scan *s);
void pa_cork_scan_feed(struct pa_cork_scan *s, const char *buf, size_t n);

/* Event feed for the sink-input gate (r13 idle-CPU fix): spawn a persistent
 * `pactl subscribe` child and return a non-blocking read fd on its stdout (or
 * -1), storing the child pid in *pid. The main loop watches the fd and re-counts
 * sink-inputs only when a membership event ("'new'/'remove' on sink-input")
 * arrives, replacing the 1.5 s pactl polling that forked ~0.67 procs/s around
 * the clock — and, worse, made every OTHER PA subscriber (nexusq-control's own
 * `pactl subscribe` bridge) wake for our poller's client-connect events.
 * Tear down with audio_close() (it is child-agnostic: SIGTERM + close). */
int   pa_subscribe_open(pid_t *pid);


/* --- the gate's timing policy ------------------------------------------------
 * The re-count is event-driven (pa_subscribe_open) with a TIMED SAFETY NET, and
 * the net has to be unconditional. It used to be skipped while the tap ran and
 * was not raw-silent, on the reasoning that "while music actually flows we never
 * poll" — the subscriber would tell us when it stopped. It does not always: the
 * subscriber only matches sink-input 'new'/'remove', and a stream ENDING on a
 * module-loopback input corks it instead, which is a 'change'. Meanwhile a tap on
 * a SUSPENDED sink's monitor delivers no samples at all, so quiet_since never
 * arms and the "raw-silent" branch never fires either -- so nothing could free
 * it. That combination is UNPROVEN in practice (a running tap holds the sink out
 * of suspend, so its monitor should keep producing zeros), but a safety net that
 * cannot fire is not a safety net, and this one also covers an arecord that dies
 * quietly. So: an event OR the deadline re-counts, whatever the tap is doing. */
#define PA_POLL_S       1.5   /* min seconds between re-counts (subscriber down/unproven) */
#define PA_SAFETY_ON_S  30.0  /* safety re-count while tapping (subscriber PROVEN) */
#define PA_SAFETY_OFF_S 60.0  /* safety re-count while the tap is off (subscriber PROVEN) */

/* When the next timed re-count is due, given the state just observed. (pure) */
double pa_gate_next_deadline(double now, int sub_proven, int tap_running);
/* Whether to re-count the sink-inputs now: a pending subscriber event, or the
 * deadline having passed. Deliberately blind to whether the tap is running or
 * silent — that is the conditionality which wedged the tap on. (pure) */
int    pa_gate_poll_due(int event_pending, double now, double poll_deadline);

#endif
