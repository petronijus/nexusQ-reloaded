/* userspace/nexusqd/tests/test_audio_gate.c
 *
 * The sink-input gate's timing policy. These are the rules that decide when the
 * daemon re-counts PA sink-inputs, and therefore when the arecord tap is torn
 * down. The regression they exist for is the one measured on the device on
 * 2026-09-20: 0 uncorked sink-inputs, both sinks SUSPENDED, and arecord still
 * running — burning ~8.6 wakeups/s to capture a sink nothing was feeding.
 *
 * The wedge needed two independent exits to be closed at once, which is why it
 * survived review: the subscriber matches only sink-input 'new'/'remove' and a
 * loopback stream ending CORKS (a 'change'), while a tap on a suspended sink's
 * monitor delivers no samples, so the "raw-silent for TAP_QUIET_S" branch never
 * armed either. The timed net must therefore not be conditional on either. */
#include "test.h"
#include "audio.h"

/* --- pa_gate_poll_due ----------------------------------------------------- */

static void test_a_pending_event_always_recounts(void) {
    /* Even with the deadline far away: the subscriber saw something. */
    CHECK(pa_gate_poll_due(1, 100.0, 1e9) == 1);
}

static void test_before_the_deadline_nothing_happens(void) {
    CHECK(pa_gate_poll_due(0, 100.0, 130.0) == 0);
}

static void test_the_deadline_recounts(void) {
    CHECK(pa_gate_poll_due(0, 130.0, 130.0) == 1);   /* exactly due */
    CHECK(pa_gate_poll_due(0, 131.0, 130.0) == 1);   /* overdue */
}

/* THE REGRESSION. The caller's state here is precisely the wedged device: the
 * tap is running, no event will ever arrive (the loopbacks corked, which is not
 * a membership change), and the stream never reads raw-silent because a
 * suspended sink's monitor yields nothing at all. The only thing that can free
 * it is the deadline, so the deadline must not care about any of that. Note the
 * arguments: pa_gate_poll_due cannot even SEE the tap state — that is the fix,
 * expressed in the signature. */
static void test_a_running_but_never_silent_tap_still_gets_recounted(void) {
    double armed_at = 1000.0;
    double deadline = pa_gate_next_deadline(armed_at, /*sub_proven=*/1,
                                            /*tap_running=*/1);
    CHECK(deadline == armed_at + PA_SAFETY_ON_S);
    /* one second before: still tapping, correctly */
    CHECK(pa_gate_poll_due(0, deadline - 1.0, deadline) == 0);
    /* the net fires, and the caller will find 0 uncorked inputs and stop it */
    CHECK(pa_gate_poll_due(0, deadline, deadline) == 1);
}

/* --- pa_gate_next_deadline ------------------------------------------------ */

static void test_a_proven_subscriber_buys_the_long_horizon(void) {
    CHECK(pa_gate_next_deadline(0.0, 1, 1) == PA_SAFETY_ON_S);
    CHECK(pa_gate_next_deadline(0.0, 1, 0) == PA_SAFETY_OFF_S);
}

static void test_an_unproven_subscriber_buys_nothing(void) {
    /* fork+exec succeed with PulseAudio down, so a merely-live fd must not arm
     * the 30/60 s net — that blinded the gate for the whole respawn gap. */
    CHECK(pa_gate_next_deadline(0.0, 0, 1) == PA_POLL_S);
    CHECK(pa_gate_next_deadline(0.0, 0, 0) == PA_POLL_S);
}

static void test_the_deadline_is_relative_to_now(void) {
    CHECK(pa_gate_next_deadline(500.0, 1, 0) == 500.0 + PA_SAFETY_OFF_S);
}

/* An idle box must not be re-counted more often than the off-horizon: this is
 * the 0.67 forks/s regression that made the gate event-driven in the first
 * place, so the fix above must not quietly reintroduce it. */
static void test_the_idle_box_is_not_polled_faster_than_the_off_horizon(void) {
    double now = 0.0, deadline = pa_gate_next_deadline(now, 1, 0);
    int recounts = 0;
    for (double t = 0.0; t < 600.0; t += 0.05) {       /* 10 minutes of the loop */
        if (pa_gate_poll_due(0, t, deadline)) {
            recounts++;
            deadline = pa_gate_next_deadline(t, 1, 0);
        }
    }
    CHECK(recounts <= 600.0 / PA_SAFETY_OFF_S + 1);    /* ~10, not thousands */
    CHECK(recounts >= 600.0 / PA_SAFETY_OFF_S - 1);    /* and it really does run */
}

int main(void) {
    RUN(test_a_pending_event_always_recounts);
    RUN(test_before_the_deadline_nothing_happens);
    RUN(test_the_deadline_recounts);
    RUN(test_a_running_but_never_silent_tap_still_gets_recounted);
    RUN(test_a_proven_subscriber_buys_the_long_horizon);
    RUN(test_an_unproven_subscriber_buys_nothing);
    RUN(test_the_deadline_is_relative_to_now);
    RUN(test_the_idle_box_is_not_polled_faster_than_the_off_horizon);
    return REPORT();
}
