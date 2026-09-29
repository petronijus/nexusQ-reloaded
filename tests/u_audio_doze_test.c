/* tests/u_audio_doze_test.c -- the decisions of kernel patch 0059 (u_audio doze)
 *
 * Built and run by tests/test_u_audio_doze.py against the u_audio_doze.h that
 * the patch creates, extracted from the patch itself, so this tests exactly
 * what ships. The I/O around it (requests, timer, ALSA ring) is verified on the
 * unit; what is pinned here:
 *   - a stream dozes only after doze_idle of uninterrupted silence, never with
 *     the feature off, and any sound restarts the count;
 *   - a silent probe keeps it dozing, a probe with sound wakes it, and after a
 *     wake it takes a full idle stretch again;
 *   - the silence it synthesizes adds up to exactly the stream's rate, however
 *     the timer ticks fall. */
#include <stdio.h>

#include "u_audio_doze.h"

static int fails;
#define CHECK(cond) do { if (!(cond)) { fails++; \
    printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

#define MS 1000000ULL

int main(void)
{
	struct uac_doze d = {0};
	u64 t;
	u32 rem;
	u64 total;

	/* Off (idle 0): an hour of silence never dozes. */
	for (t = 0; t <= 3600000 * MS; t += MS)
		CHECK(uac_doze_on_packet(&d, 1, t, 0) == 0);
	CHECK(!d.dozing);

	/* 5 s idle: silent packets every 1 ms. Not at 4.999 s, yes at 5 s. */
	d = (struct uac_doze){0};
	for (t = 0; t < 5000 * MS; t += MS)
		CHECK(uac_doze_on_packet(&d, 1, t, 5000 * MS) == 0);
	CHECK(uac_doze_on_packet(&d, 1, 5000 * MS, 5000 * MS) == 1);
	CHECK(d.dozing);

	/* One packet of sound in the middle restarts the count. */
	d = (struct uac_doze){0};
	for (t = 0; t < 4000 * MS; t += MS)
		uac_doze_on_packet(&d, 1, t, 5000 * MS);
	CHECK(uac_doze_on_packet(&d, 0, 4000 * MS, 5000 * MS) == 0);
	for (t = 4001 * MS; t < 9001 * MS; t += MS)
		CHECK(uac_doze_on_packet(&d, 1, t, 5000 * MS) == 0);
	CHECK(uac_doze_on_packet(&d, 1, 9001 * MS, 5000 * MS) == 1);

	/* Dozing: silent probes keep it asleep, the first sound wakes it. */
	CHECK(uac_doze_on_probe(&d, 1) == 0 && d.dozing);
	CHECK(uac_doze_on_probe(&d, 1) == 0 && d.dozing);
	CHECK(uac_doze_on_probe(&d, 0) == 1 && !d.dozing);

	/* After a wake, it takes a whole idle stretch again, from the next
	 * silent packet: not the moment the old run began. */
	CHECK(uac_doze_on_packet(&d, 1, 20000 * MS, 5000 * MS) == 0);
	CHECK(uac_doze_on_packet(&d, 1, 24999 * MS, 5000 * MS) == 0);
	CHECK(uac_doze_on_packet(&d, 1, 25000 * MS, 5000 * MS) == 1);

	/* The synthesized silence: 48 kHz in 20 ms ticks is 960 frames each. */
	rem = 0;
	CHECK(uac_doze_frames(20 * MS, 48000, &rem) == 960 && rem == 0);

	/* Uneven ticks (a timer is never exact) still add up to the rate:
	 * 1 s of 7, 13 and 17 ms ticks, then the rest. */
	rem = 0;
	total = 0;
	{
		u64 elapsed = 0, steps[] = {7 * MS, 13 * MS, 17 * MS};
		int i = 0;

		while (elapsed + steps[i % 3] <= 1000 * MS) {
			total += uac_doze_frames(steps[i % 3], 44100, &rem);
			elapsed += steps[i % 3];
			i++;
		}
		total += uac_doze_frames(1000 * MS - elapsed, 44100, &rem);
	}
	CHECK(total == 44100);

	/* Sub-frame ticks lose nothing: 1000 ticks of 1 us at 48 kHz carry the
	 * remainder until whole frames are due (48 frames in 1 ms). */
	rem = 0;
	total = 0;
	for (int i = 0; i < 1000; i++)
		total += uac_doze_frames(1000, 48000, &rem);
	CHECK(total == 48);

	/* A tick the scheduler held back for a whole second is one second. */
	rem = 0;
	CHECK(uac_doze_frames(1000 * MS, 48000, &rem) == 48000);

	if (fails) {
		printf("u_audio_doze_test: %d failure(s)\n", fails);
		return 1;
	}
	printf("u_audio_doze_test: ok (0 failures)\n");
	return 0;
}
