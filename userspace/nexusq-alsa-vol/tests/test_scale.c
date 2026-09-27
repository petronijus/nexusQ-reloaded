/* The scale ctl_nexusq_vol rests on: PulseAudio volume <-> the control's
 * amplitude-linear integer. Every volume the app, the knob or Home Assistant
 * can set (whole percents, as pactl sets them) must survive the round trip,
 * or a player reading the control and writing it back would move the volume
 * by itself. */
#include <stdio.h>
#include "nexusq_vol_scale.h"

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

int main(void)
{
	/* endpoints */
	CHECK(nqv_pa_to_raw(PA_VOLUME_MUTED) == 0);
	CHECK(nqv_raw_to_pa(0) == PA_VOLUME_MUTED);
	CHECK(nqv_pa_to_raw(PA_VOLUME_NORM) == NQV_RAW_MAX);
	CHECK(nqv_raw_to_pa(NQV_RAW_MAX) == PA_VOLUME_NORM);
	/* above 100 % reads as the top; never beyond it */
	CHECK(nqv_pa_to_raw(PA_VOLUME_NORM * 3 / 2) == NQV_RAW_MAX);
	CHECK(nqv_raw_to_pa(NQV_RAW_MAX + 5) == PA_VOLUME_NORM);
	CHECK(nqv_raw_to_pa(-3) == PA_VOLUME_MUTED);

	/* every whole percent, the way pactl turns "N%" into a volume */
	for (int p = 0; p <= 100; p++) {
		pa_volume_t v = (pa_volume_t)((double)PA_VOLUME_NORM * p / 100.0 + 0.5);
		CHECK(nqv_raw_to_pa(nqv_pa_to_raw(v)) == v);
	}
	/* every PulseAudio volume from 1 % up round-trips exactly (below that the
	 * steps are closer than one integer: -120 dB and under, inaudible) */
	int lost = 0;
	for (pa_volume_t v = PA_VOLUME_NORM / 100; v <= PA_VOLUME_NORM; v++)
		lost += nqv_raw_to_pa(nqv_pa_to_raw(v)) != v;
	CHECK(lost == 0);
	/* monotonic both ways */
	long prev = -1;
	for (pa_volume_t v = 0; v <= PA_VOLUME_NORM; v += 7) {
		long r = nqv_pa_to_raw(v);
		CHECK(r >= prev);
		prev = r;
	}
	/* the dB the TLV claims is PulseAudio's own dB for that volume */
	for (int p = 1; p <= 100; p++) {
		pa_volume_t v = (pa_volume_t)((double)PA_VOLUME_NORM * p / 100.0 + 0.5);
		double tlv_db = 20.0 * log10((double)nqv_pa_to_raw(v) / NQV_RAW_MAX);
		double pa_db = pa_sw_volume_to_dB(v);
		CHECK(fabs(tlv_db - pa_db) < 0.001);
	}
	printf("test_scale: %s (%d failure%s)\n", fails ? "FAIL" : "ok", fails, fails == 1 ? "" : "s");
	return fails != 0;
}
