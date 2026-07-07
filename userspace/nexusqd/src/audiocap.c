/* userspace/nexusqd/src/audiocap.c — see audiocap.h
 * Faithful port of DefaultAudioCapture (waveform/volume), BeatProcessor and Comb. */
#include "audiocap.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define PI 3.141592653589793

/* ---------- Comb (audio/capture/Comb.java) ---------------------------------- */

static float comb_gaussian(const struct comb *c, float x, float variance) {
    if (variance == c->peak_variance)
        return (1.0f / c->sqrt_double_var_pi) * (float)exp((-(x * x)) / (c->peak_variance * 2.0f));
    return (1.0f / (float)sqrt((variance * 2.0f) * PI)) * (float)exp((-(x * x)) / (2.0f * variance));
}

static float comb_value_at(const struct comb *c, float position, float variance) {
    while (position < 0.0f) position += c->period;
    float diff = c->peak_position - fmodf(position, c->period);
    float ad = fabsf(diff);
    return ad > c->period / 2.0f ? comb_gaussian(c, ad - c->period, variance)
                                 : comb_gaussian(c, diff, variance);
}

static float comb_offset_to_nearest_peak(const struct comb *c, float position) {
    while (position < 0.0f) position += c->period;
    float diff = c->peak_position - fmodf(position, c->period);
    float ad = fabsf(diff);
    if (ad <= c->period / 2.0f) return diff;
    if (diff > 0.0f) return ad - c->period;
    return c->period - ad;
}

static float comb_next_peak_location(const struct comb *c) {
    return ((float)floor(c->next_index / c->period)) * c->period + c->peak_position;
}

static void comb_init(struct comb *c, float peak_position, float peak_variance,
                      float period, const float *beat_train, int len) {
    c->beat_train = beat_train;
    c->beat_train_len = len;
    while (peak_position < 0.0f) peak_position += period;
    c->peak_position = fmodf(peak_position, period);
    c->peak_variance = peak_variance;
    c->sqrt_double_var_pi = (float)sqrt(2.0f * peak_variance * PI);
    c->period = period;
    c->comb = calloc((size_t)len, sizeof(float));
    c->comb_total = 0; c->beat_train_total = 0; c->comb_beat_product = 0; c->comb_index = 0;
    for (int i = 0; i < len; i++) {
        c->comb[i] = comb_value_at(c, (float)i, c->peak_variance);
        c->comb_total += c->comb[i];
        c->beat_train_total += c->beat_train[i];
        c->comb_beat_product += c->beat_train[i] * c->comb[i];
    }
    c->next_index = len;
    c->oldest_audio = beat_train[c->comb_index];
    c->dot_prod = 0;
}

static float comb_update(struct comb *c) {
    c->comb_total -= c->comb[c->comb_index];
    c->comb_beat_product -= c->comb[c->comb_index] * c->oldest_audio;
    c->beat_train_total -= c->oldest_audio;
    long long j = c->next_index;
    c->next_index = j + 1;
    c->comb[c->comb_index] = comb_value_at(c, (float)j, c->peak_variance);
    c->comb_total += c->comb[c->comb_index];
    c->beat_train_total += c->beat_train[c->comb_index];
    c->comb_beat_product += c->comb[c->comb_index] * c->beat_train[c->comb_index];
    c->comb_index = (c->comb_index + 1) % c->beat_train_len;
    c->oldest_audio = c->beat_train[c->comb_index];
    c->dot_prod = c->comb_beat_product - ((c->comb_total / c->beat_train_len) * c->beat_train_total);
    return c->dot_prod;
}

/* ---------- BeatProcessor (audio/capture/BeatProcessor.java) ---------------- */

static int beat_comb_count(int sps) {
    int count = 0;
    for (float bpm = 50.0f; bpm < 180.0f; bpm += 1.0f) {
        float period = (sps * 60) / bpm;
        float step = fmaxf(2.0f, period / 20.0f);
        for (float off = 0.0f; off < period; off += step) count++;
    }
    return count;
}

static void beat_init(struct audio_state *a) {
    int sps = SEGMENTS_PER_SECOND;
    a->ncombs = beat_comb_count(sps);
    a->combs = calloc((size_t)a->ncombs, sizeof(struct comb));
    int ci = 0;
    for (float bpm = 50.0f; bpm < 180.0f; bpm += 1.0f) {
        float period = (sps * 60) / bpm;
        float step = fmaxf(2.0f, period / 20.0f);
        float peak_variance = period / 20.0f;
        for (float off = 0.0f; off < period; off += step)
            comb_init(&a->combs[ci++], off, peak_variance, period, a->beat_values, BEAT_VALUES_LEN);
    }
    a->selected_comb = 0;
    a->selected_comb_confidence = 1.0f;
    a->nearest_peak_offset = 0.0;
    a->last_peak_index = 0;
    a->beat_index = 0;
    a->computed_beat = 0.0f;
    a->smoothed_beat_energy = 0.0f;
    a->peak_to_mean = 0.0f;
}

static void beat_on_segment(struct audio_state *a, float volume, const signed char *fft) {
    if (volume < 0.01f) {
        a->peak_to_mean = 0.0f;
        a->computed_beat = 0.0f;
        a->smoothed_beat_energy = 0.7f * a->smoothed_beat_energy;
        return;
    }
    int energy = 0;
    for (int li = 0; li < SAMPLES_PER_SEGMENT / 2; li++) {
        int realIdx = li * 2;
        int i = fft[realIdx] < 0 ? -fft[realIdx] : fft[realIdx];
        if (i > 1 && i > a->prev_abs_real_ft[li]) energy++;
        a->prev_abs_real_ft[li] = i;
    }
    a->beat_values[a->beat_index] = (float)energy;
    a->beat_index = (a->beat_index + 1) % BEAT_VALUES_LEN;

    float highest = -3.4028235e38f;
    int highest_idx = 0;
    float avg = 0.0f;
    for (int li = 0; li < a->ncombs; li++) {
        float score = comb_update(&a->combs[li]);
        avg += fmaxf(score, 0.0f);
        if (highest < score) { highest = score; highest_idx = li; }
    }
    avg /= a->ncombs;
    struct comb *hi = &a->combs[highest_idx];
    struct comb *sel = &a->combs[a->selected_comb];

    if (highest_idx == a->selected_comb) {
        a->selected_comb_confidence += hi->dot_prod / avg;
        a->selected_comb_confidence = fminf(a->selected_comb_confidence, 500.0f);
    } else {
        float peakGap = fmodf(fabsf(comb_next_peak_location(hi) - comb_next_peak_location(sel)), sel->period);
        if (peakGap > sel->period / 2.0f) peakGap = fabsf(peakGap - sel->period);
        if (fabsf(hi->period - sel->period) < 2.0f &&
            peakGap < 2.01 * fminf(2.0f, sel->period / 20.0f)) {
            a->selected_comb_confidence += hi->dot_prod / avg;
            a->selected_comb_confidence = fminf(a->selected_comb_confidence, 500.0f);
            a->selected_comb = highest_idx; sel = hi;
        } else {
            float newP = hi->dot_prod / avg;
            float oldP = sel->dot_prod / avg;
            a->selected_comb_confidence -= newP;
            if (fabsf(newP - oldP) > 2.5f || a->selected_comb_confidence < 0.0f) {
                a->selected_comb_confidence = 0.0f;
                a->selected_comb = highest_idx; sel = hi;
            }
        }
    }

    double distance = comb_offset_to_nearest_peak(sel, (float)sel->next_index);
    if (a->nearest_peak_offset >= 0.0 && distance < 0.0 &&
        (float)(sel->next_index - a->last_peak_index) > sel->period * 0.5f) {
        a->last_peak_index = sel->next_index;
        a->beat_next_frame = 1;
    }
    a->nearest_peak_offset = distance;

    float p2m = sel->dot_prod / avg;
    float variance = fmaxf(sel->period / 30.0f,
                           (1.0f / fmaxf(0.5f, p2m - 8.0f)) * sel->period);
    float adj = comb_value_at(sel, (float)sel->next_index, variance);
    a->computed_beat = fmaxf(60.0f * adj, 0.0f);
    a->smoothed_beat_energy = (0.7f * a->smoothed_beat_energy) + (0.3f * a->computed_beat);
    a->peak_to_mean = sel->dot_prod / avg;
}

/* ---------- real FFT (radix-2, 1024) --------------------------------------- */

static void fft_real(const float *x, signed char *out) {
    static double re[SAMPLES_PER_SEGMENT], im[SAMPLES_PER_SEGMENT];
    int n = SAMPLES_PER_SEGMENT;
    for (int i = 0; i < n; i++) { re[i] = x[i]; im[i] = 0.0; }
    /* bit-reversal */
    for (int i = 1, j = 0; i < n; i++) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { double t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
    }
    for (int len = 2; len <= n; len <<= 1) {
        double ang = -2.0 * PI / len;
        double wr = cos(ang), wi = sin(ang);
        for (int i = 0; i < n; i += len) {
            double cwr = 1.0, cwi = 0.0;
            for (int k = 0; k < len / 2; k++) {
                double ur = re[i + k],       ui = im[i + k];
                double vr = re[i + k + len/2] * cwr - im[i + k + len/2] * cwi;
                double vi = re[i + k + len/2] * cwi + im[i + k + len/2] * cwr;
                re[i + k] = ur + vr; im[i + k] = ui + vi;
                re[i + k + len/2] = ur - vr; im[i + k + len/2] = ui - vi;
                double nwr = cwr * wr - cwi * wi;
                cwi = cwr * wi + cwi * wr; cwr = nwr;
            }
        }
    }
    /* android Visualizer packing: out[0]=Rf[0], out[1]=Rf[n/2], out[2i]=Rf[i], out[2i+1]=If[i] */
    for (int i = 0; i < n; i++) out[i] = 0;
    int v0 = (int)floor(re[0] * AUDIOCAP_FFT_SCALE + 0.5);
    out[0] = (signed char)(v0 < -128 ? -128 : v0 > 127 ? 127 : v0);
    int vn = (int)floor(re[n/2] * AUDIOCAP_FFT_SCALE + 0.5);
    out[1] = (signed char)(vn < -128 ? -128 : vn > 127 ? 127 : vn);
    for (int i = 1; i < n/2; i++) {
        int rv = (int)floor(re[i] * AUDIOCAP_FFT_SCALE + 0.5);
        int iv = (int)floor(im[i] * AUDIOCAP_FFT_SCALE + 0.5);
        out[2*i]   = (signed char)(rv < -128 ? -128 : rv > 127 ? 127 : rv);
        out[2*i+1] = (signed char)(iv < -128 ? -128 : iv > 127 ? 127 : iv);
    }
}

/* ---------- public API ----------------------------------------------------- */

void audiocap_init(struct audio_state *a) {
    memset(a, 0, sizeof(*a));
    beat_init(a);
}

void audiocap_free(struct audio_state *a) {
    if (a->combs) {
        for (int i = 0; i < a->ncombs; i++) free(a->combs[i].comb);
        free(a->combs);
        a->combs = NULL;
    }
}

void audiocap_on_segment(struct audio_state *a, const float *segment) {
    int start = a->buffer_index;

    /* raw mean-abs level of this segment (before AGC) */
    float raw = 0.0f;
    for (int i = 0; i < SAMPLES_PER_SEGMENT; i++)
        raw += segment[i] < 0 ? -segment[i] : segment[i];
    raw /= SAMPLES_PER_SEGMENT;

    /* AGC (see audiocap.h): the PA-monitor tap is post-volume, so raw scales
     * with the listening volume. Track it (fast attack, slow release) and
     * normalize to AGC_TARGET so the visualizer reacts to the MUSIC regardless
     * of volume; gate true silence so it falls back to the breathing idle. */
    if (raw > a->agc_level) a->agc_level = raw;
    else a->agc_level = a->agc_level * AGC_RELEASE + raw * (1.0f - AGC_RELEASE);
    float gain;
    if (raw < AGC_NOISE_FLOOR || a->agc_level < 1e-6f) {
        gain = 0.0f;                                     /* silence gate */
    } else {
        gain = AGC_TARGET / a->agc_level;
        if (gain > AGC_MAX_GAIN) gain = AGC_MAX_GAIN;
        if (gain < 1.0f)         gain = 1.0f;            /* never attenuate a hot signal */
    }

    float vol = 0.0f;
    for (int i = 0; i < SAMPLES_PER_SEGMENT; i++) {
        float s = segment[i] * gain;
        if (s > 1.0f) s = 1.0f; else if (s < -1.0f) s = -1.0f;   /* clip to [-1,1] */
        a->waveform[a->buffer_index++] = s;
        vol += s < 0 ? -s : s;
    }
    a->volume = vol / SAMPLES_PER_SEGMENT;
    a->last_segment_index = start;
    if (a->buffer_index == AUDIO_BUF) a->buffer_index = 0;

    /* FFT/beat on the ORIGINAL segment — the beat detector is scale-robust
     * (counts bins over a threshold), so AGC gain would only shift the noise. */
    fft_real(segment, a->fft);
    beat_on_segment(a, a->volume, a->fft);
}

void audiocap_on_new_frame(struct audio_state *a) {
    if (a->beat_next_frame) { a->beat_this_frame = 1; a->beat_next_frame = 0; }
    else                    { a->beat_this_frame = 0; }
}

float audiocap_volume(const struct audio_state *a)          { return a->volume; }
float audiocap_smoothed_beat(const struct audio_state *a)   { return a->smoothed_beat_energy; }
int   audiocap_beat_this_frame(const struct audio_state *a) { return a->beat_this_frame; }
const float *audiocap_buffer(const struct audio_state *a)   { return a->waveform; }
int   audiocap_last_segment_index(const struct audio_state *a) { return a->last_segment_index; }
