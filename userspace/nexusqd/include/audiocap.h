/* userspace/nexusqd/include/audiocap.h
 * Port of audio/capture/{AudioCapture,DefaultAudioCapture,BeatProcessor,Comb}.
 *
 * Contract the effects read (all from DefaultAudioCapture):
 *   - waveform: rolling float buffer, length SAMPLES_PER_SEGMENT*5, samples [-1,1]
 *   - last_segment_index: start offset of the newest segment in `waveform`
 *   - volume: mean(|waveform|) of the newest segment (getVolume)
 *   - smoothed_beat: BeatProcessor.getSmoothedBeatValue()
 *   - beat_this_frame: BeatProcessor.isNewBeat() latched per render frame
 *
 * FIDELITY: the original FFT came from android.media.audiofx.Visualizer (a
 * fixed-point AudioFlinger engine) — not bit-reproducible. We compute a real FFT
 * of each PCM segment and pack the real parts to signed 8-bit (the exact layout
 * BeatProcessor consumes: byte[2*li] = real part of bin li). The byte scale
 * (AUDIOCAP_FFT_SCALE) is an approximation of the unrecoverable android scaling;
 * BeatProcessor's tempo logic is scale-robust (energy = COUNT of bins whose
 * |real| rose vs the previous segment; comb scores are relative). */
#ifndef NEXUSQD_AUDIOCAP_H
#define NEXUSQD_AUDIOCAP_H
#include "audio.h"   /* AUDIO_RATE: the sample clock segments are cut by */

#define SAMPLES_PER_SEGMENT   1024   /* Visualizer.getCaptureSizeRange()[1] (ICS) */
#define SEGMENTS_PER_SECOND   20     /* Visualizer.getMaxCaptureRate()/1000 (ICS) */

/* Segments are cut by the SAMPLE CLOCK, not the wall clock: one every
 * AUDIOCAP_HOP input frames (2400 = 50 ms at 48 kHz), holding the newest
 * SAMPLES_PER_SEGMENT frames of that hop — the Visualizer's own decimation
 * (1024 samples captured at 20 Hz). The tap is `arecord -D pulse`, which
 * delivers PCM in ~130 ms bursts; a wall-clock rate limit (one segment per
 * 50 ms of `now`, with one `now` per wake) analysed only the first segment of
 * each burst, ~7.7 segments/s instead of the 20 the beat tracker's combs are
 * built for, and dropped ~83 % of the audio. */
#define AUDIOCAP_HOP          (AUDIO_RATE / SEGMENTS_PER_SECOND)
_Static_assert(AUDIOCAP_HOP >= SAMPLES_PER_SEGMENT, "a hop must hold a whole segment");

/* AGC (auto-gain) for the PulseAudio-monitor tap. The tap reads the active
 * sink's .monitor, which is AFTER PA volume/mute, so the raw level scales with
 * the listening volume (~0.01-0.03 mean-abs at normal volume vs ~0.1-0.2
 * full-scale). Normalize to AGC_TARGET so the visualizer reacts to the MUSIC
 * independent of volume (matching the old pre-volume loopback tap). Fast attack,
 * slow release (beats/dynamics still show). Gain is zeroed only while audio is
 * not PRESENT (below): true silence stays silent and falls back to the
 * breathing screensaver. */
#define AGC_TARGET       0.15f   /* desired mean-abs when music is playing */
#define AGC_RELEASE      0.95f   /* per-segment EMA (~1.5 s at 20 seg/s) tracking down */
#define AGC_MAX_GAIN     50.0f   /* cap so we never blow up the noise floor */

/* "Audio present" — what the music scene, the screensaver and the tap's quiet
 * timer key on — is decided from the RAW level (mean-abs before AGC) over every
 * sample received, independently of the AGC, with hysteresis and a hold:
 * present at once when a hop reaches AUDIOCAP_PRESENT_ON, absent only after the
 * raw level has stayed below AUDIOCAP_PRESENT_OFF for AUDIOCAP_PRESENT_HOLD_S of
 * sample clock. It used to be `volume >= 0.01` behind a -60 dBFS AGC noise gate
 * (0.001): quiet music (USB-audio input, raw ~0.001-0.003) straddled that gate,
 * so volume alternated 0 / >=0.05 and the scene flapped DETECTED/silent.
 * The thresholds sit just above digital silence: an idle PA monitor and the
 * USB-audio bridge's idle stream are exact zeros, librespot's dither is ~1 LSB
 * (3e-5); 1.5e-4 is ~5 LSB (-76 dBFS), 1e-4 ~3.3 LSB (-80 dBFS). */
#define AUDIOCAP_PRESENT_ON     1.5e-4f
#define AUDIOCAP_PRESENT_OFF    1.0e-4f
#define AUDIOCAP_PRESENT_HOLD_S 0.75
#define AUDIOCAP_PRESENT_HOLD_FRAMES ((int)(AUDIO_RATE * AUDIOCAP_PRESENT_HOLD_S))
#define AUDIO_BUF             (SAMPLES_PER_SEGMENT * 5)
#define BEAT_VALUES_LEN       120
#define AUDIOCAP_FFT_SCALE    (127.0 / 512.0)   /* real-FFT -> int8 (approx; documented) */

struct comb {
    const float *beat_train;
    int   beat_train_len;
    float beat_train_total;
    float *comb;            /* length beat_train_len */
    float comb_total;
    float comb_beat_product;
    int   comb_index;
    float dot_prod;
    long long next_index;
    float oldest_audio;
    float peak_position;
    float peak_variance;
    float period;
    float sqrt_double_var_pi;
};

struct audio_state {
    /* waveform / volume */
    float waveform[AUDIO_BUF];
    int   buffer_index;
    int   last_segment_index;
    float volume;
    float agc_level;   /* AGC: slow-tracked level of the raw capture (see on_segment) */
    /* sample-clock feed (audiocap_feed) */
    float hop_win[SAMPLES_PER_SEGMENT];   /* the newest SAMPLES_PER_SEGMENT frames of the hop */
    int   hop_pos;                        /* frames received in the current hop */
    float hop_sum;                        /* sum(|x|) over the current hop (raw level) */
    unsigned long segments;               /* segments analysed, free-running */
    /* audio presence (see AUDIOCAP_PRESENT_*) */
    int   present;
    int   quiet_frames;                   /* frames continuously below AUDIOCAP_PRESENT_OFF */
    float raw_level;                      /* raw mean-abs of the last hop/segment */
    /* FFT scratch (signed 8-bit packed, android Visualizer layout) */
    signed char fft[SAMPLES_PER_SEGMENT];
    /* BeatProcessor */
    int   prev_abs_real_ft[SAMPLES_PER_SEGMENT / 2];
    float beat_values[BEAT_VALUES_LEN];
    int   beat_index;
    struct comb *combs;
    int   ncombs;
    int   selected_comb;          /* index into combs */
    float selected_comb_confidence;
    double nearest_peak_offset;
    long long last_peak_index;
    float computed_beat;
    float smoothed_beat_energy;
    float peak_to_mean;
    int   beat_next_frame;
    int   beat_this_frame;
};

void  audiocap_init(struct audio_state *a);    /* allocates the comb bank */
void  audiocap_free(struct audio_state *a);
/* feed n captured mono frames [-1,1], in whatever bursts the tap delivers them:
 * analyses one segment per AUDIOCAP_HOP frames received (see AUDIOCAP_HOP) and
 * updates audio presence from all of them */
void  audiocap_feed(struct audio_state *a, const float *mono, int n);
/* the sample clock broke (tap closed, or delivery stalled for longer than the
 * presence hold): drop the partial hop and start absent */
void  audiocap_feed_reset(struct audio_state *a);
/* analyse one segment of SAMPLES_PER_SEGMENT normalized samples [-1,1] directly,
 * counting it as the only samples received since the previous one */
void  audiocap_on_segment(struct audio_state *a, const float *segment);
/* call once per render frame (latches beat_this_frame) */
void  audiocap_on_new_frame(struct audio_state *a);

float audiocap_volume(const struct audio_state *a);
float audiocap_smoothed_beat(const struct audio_state *a);
int   audiocap_beat_this_frame(const struct audio_state *a);
const float *audiocap_buffer(const struct audio_state *a);
int   audiocap_last_segment_index(const struct audio_state *a);
int   audiocap_present(const struct audio_state *a);         /* audio present (hysteresis + hold) */
float audiocap_raw_level(const struct audio_state *a);       /* raw mean-abs of the last hop */
unsigned long audiocap_segments(const struct audio_state *a); /* segments analysed so far */

#endif
