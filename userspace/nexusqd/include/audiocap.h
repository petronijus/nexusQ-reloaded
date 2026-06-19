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

#define SAMPLES_PER_SEGMENT   1024   /* Visualizer.getCaptureSizeRange()[1] (ICS) */
#define SEGMENTS_PER_SECOND   20     /* Visualizer.getMaxCaptureRate()/1000 (ICS) */
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
/* feed one captured segment of SAMPLES_PER_SEGMENT normalized samples [-1,1] */
void  audiocap_on_segment(struct audio_state *a, const float *segment);
/* call once per render frame (latches beat_this_frame) */
void  audiocap_on_new_frame(struct audio_state *a);

float audiocap_volume(const struct audio_state *a);
float audiocap_smoothed_beat(const struct audio_state *a);
int   audiocap_beat_this_frame(const struct audio_state *a);
const float *audiocap_buffer(const struct audio_state *a);
int   audiocap_last_segment_index(const struct audio_state *a);

#endif
