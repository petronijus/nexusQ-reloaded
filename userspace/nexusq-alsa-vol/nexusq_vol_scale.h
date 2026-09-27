/*
 * nexusq_vol_scale.h -- the one conversion ctl_nexusq_vol rests on.
 *
 * PulseAudio's software volume is cubic in amplitude; the control's integer is
 * linear in amplitude (so its TLV is an exact DB_LINEAR):
 *
 *     raw = RAW_MAX * (v / NORM)^3          v = NORM * cbrt(raw / RAW_MAX)
 *
 * Header-only and free of ALSA/PulseAudio calls, so the round trip is tested
 * on any host (tests/test_scale.c).
 */
#ifndef NEXUSQ_VOL_SCALE_H
#define NEXUSQ_VOL_SCALE_H

#include <math.h>
#include <pulse/volume.h>

/* 2^30: fits a 32-bit long, and puts the smallest step at 20 log10(2^-30) =
 * -180.6 dB -- deep enough that librespot's cubic floor is ~1e-3. */
#define NQV_RAW_MAX (1L << 30)

/* A PulseAudio volume above 100 % (PulseAudio allows it) reads as the top of
 * the scale: this control never asks for more than 0 dB. */
static inline long nqv_pa_to_raw(pa_volume_t v)
{
	if (v == PA_VOLUME_MUTED)
		return 0;
	if (v >= PA_VOLUME_NORM)
		return NQV_RAW_MAX;
	double x = (double)v / PA_VOLUME_NORM;
	return lround(x * x * x * (double)NQV_RAW_MAX);
}

static inline pa_volume_t nqv_raw_to_pa(long raw)
{
	if (raw <= 0)
		return PA_VOLUME_MUTED;
	if (raw >= NQV_RAW_MAX)
		return PA_VOLUME_NORM;
	return (pa_volume_t)lround(cbrt((double)raw / (double)NQV_RAW_MAX) * PA_VOLUME_NORM);
}

#endif
