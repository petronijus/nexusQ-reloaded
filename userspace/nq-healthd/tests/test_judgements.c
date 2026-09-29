/* userspace/nq-healthd/tests/test_judgements.c
 *
 * Two judgements healthd makes every sample, and must not repeat every sample
 * (found reading the second overnight soak, 2026-09-29):
 *   - vdd_mismatch: one reading can straddle an OPP transition, because
 *     policy->cur moves only after the clock and the regulator have both
 *     changed. The soak logged 1.025 V "at 700 MHz" once in 23 h. A
 *     mismatching reading is now taken again after a pause; only a mismatch
 *     that is still there counts, and it is reported once per run.
 *   - led_static / led_frozen: a static frame all day (the screensaver) logged
 *     led_static every 5 min, ~190 times, and a hang would have logged
 *     led_frozen every 5 s. Both are now once per stretch.
 *
 * The source is #included so the statics are reachable, with main() renamed
 * out of the way. */
#define main healthd_main_unused
#include "nq-healthd.c"
#undef main

#include <stdio.h>

static int fails;
#define CHECK(cond) do { if (!(cond)) { fails++; \
    printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

/* A scripted sysfs: each call to freq() / vdd() returns the next value, and
 * settle() counts its calls. A transition is played by changing the values
 * between the first reading (freq, vdd, freq) and the second. */
static long long fq[8], vd[8];
static int fi, vi, settles;
static long long fake_freq(void) { return fq[fi++]; }
static long long fake_vdd(void) { return vd[vi++]; }
static void fake_settle(void) { settles++; }
static const struct vdd_io fake = { fake_freq, fake_vdd, fake_settle };

/* Two readings: (f1, v1, f1') then, if asked, (f2, v2, f2'). */
static int play(long long f1, long long v1, long long f1b, long long f2, long long v2, long long f2b,
                struct vdd_reading *r)
{
    fq[0] = f1; fq[1] = f1b; fq[2] = f2; fq[3] = f2b;
    vd[0] = v1; vd[1] = v2;
    fi = vi = settles = 0;
    return vdd_check(&fake, r);
}

/* Feed `n` samples of one stall state; count the verdicts. */
static void led_run(struct led_watch *w, long long *stall, int n, int frame_changes,
                    int distressed, int *nstatic, int *nfrozen)
{
    for (int i = 0; i < n; i++) {
        *stall = frame_changes ? 0 : *stall + 1;
        switch (led_judge(w, *stall, distressed)) {
        case LED_STATIC: (*nstatic)++; break;
        case LED_FROZEN: (*nfrozen)++; break;
        case LED_QUIET: break;
        }
    }
}

int main(void)
{
    /* --- the raw comparison --- */
    CHECK(vdd_raw_mismatch(1203000, 1203000, 700000, 700000) == 0);
    CHECK(vdd_raw_mismatch(1025000, 1203000, 700000, 700000) == 1); /* the soak's sample */
    CHECK(vdd_raw_mismatch(1203000, 1025000, 350000, 350000) == 1); /* the earlier boots' */
    CHECK(vdd_raw_mismatch(1220000, 1203000, 700000, 700000) == 0); /* within 20 mV */
    CHECK(vdd_raw_mismatch(1025000, 1203000, 700000, 350000) == 0); /* freq moved between reads */
    CHECK(vdd_raw_mismatch(1025000, 0, 800000, 800000) == 0);       /* no OPP for that freq */
    CHECK(vdd_raw_mismatch(0, 1203000, 700000, 700000) == 0);       /* no regulator reading */

    struct vdd_reading r;

    /* The right voltage: one reading, no pause. */
    CHECK(play(700000, 1203000, 700000, 0, 0, 0, &r) == 0);
    CHECK(settles == 0);

    /* The soak's race: stepping down, the regulator is already at 350's
     * 1.025 V while cur still says 700 MHz. 50 ms later it reads 350 MHz. */
    CHECK(play(700000, 1025000, 700000, 350000, 1025000, 350000, &r) == 0);
    CHECK(settles == 1);

    /* The earlier boots' race: stepping up, 700's 1.203 V is in first. */
    CHECK(play(350000, 1203000, 350000, 700000, 1203000, 700000, &r) == 0);

    /* A real undervolt at 700 MHz is still there after the pause. */
    CHECK(play(700000, 1025000, 700000, 700000, 1025000, 700000, &r) == 1);
    CHECK(r.freq == 700000 && r.vdd == 1025000 && r.vexp == 1203000);

    /* The dangerous one: a short burst at 1.2 GHz with the rail too low. A
     * rule that waited for the next 5 s sample would never see it. */
    CHECK(play(1200000, 1250000, 1200000, 1200000, 1250000, 1200000, &r) == 1);

    /* The frequency moved between the two reads: no evidence, no pause. */
    CHECK(play(700000, 1025000, 350000, 0, 0, 0, &r) == 0);
    CHECK(settles == 0);

    /* Once per run of mismatching samples. */
    int prev = 0, reports = 0;
    int run[] = {0, 1, 1, 1, 0, 0, 1, 1, 0};
    for (int i = 0; i < 9; i++)
        reports += vdd_onset(run[i], &prev);
    CHECK(reports == 2);

    /* --- the LED ring --- */
    struct led_watch w = {0, 0};
    long long stall = 0;
    int nstatic = 0, nfrozen = 0;

    /* The soak's day: the frame static for 11400 samples, nexusqd healthy. */
    led_run(&w, &stall, 11400, 0, 0, &nstatic, &nfrozen);
    CHECK(nstatic == 1 && nfrozen == 0);

    /* Not before 5 minutes: a short pause in the animation is not news. */
    w = (struct led_watch){0, 0}; stall = 0; nstatic = nfrozen = 0;
    led_run(&w, &stall, 59, 0, 0, &nstatic, &nfrozen);
    CHECK(nstatic == 0);
    led_run(&w, &stall, 1, 0, 0, &nstatic, &nfrozen);
    CHECK(nstatic == 1);

    /* The frame moves, then stalls again: a new stretch is reported again. */
    led_run(&w, &stall, 1, 1, 0, &nstatic, &nfrozen);
    led_run(&w, &stall, 120, 0, 0, &nstatic, &nfrozen);
    CHECK(nstatic == 2);

    /* A hang: frozen frame and a distressed nexusqd. crit once, after 6. */
    w = (struct led_watch){0, 0}; stall = 0; nstatic = nfrozen = 0;
    led_run(&w, &stall, 5, 0, 1, &nstatic, &nfrozen);
    CHECK(nfrozen == 0);
    led_run(&w, &stall, 500, 0, 1, &nstatic, &nfrozen);
    CHECK(nfrozen == 1);

    /* The distress passes (the ring stays static), then comes back: that is a
     * second episode, and the static stretch itself is still noted once. */
    led_run(&w, &stall, 10, 0, 0, &nstatic, &nfrozen);
    led_run(&w, &stall, 10, 0, 1, &nstatic, &nfrozen);
    CHECK(nfrozen == 2);
    CHECK(nstatic == 1);

    if (fails) {
        printf("test_judgements: %d failure(s)\n", fails);
        return 1;
    }
    printf("test_judgements: ok (0 failures)\n");
    return 0;
}
