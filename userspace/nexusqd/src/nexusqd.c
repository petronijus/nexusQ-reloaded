/* userspace/nexusqd/src/nexusqd.c */
#define _GNU_SOURCE               /* ppoll(2) — see the frame deadline below. Implies
                                   * _POSIX_C_SOURCE: clock_gettime/CLOCK_MONOTONIC,
                                   * AF_UNIX, poll under -std=c11. */
#include "frame.h"
#include "avr.h"
#include "compositor.h"
#include "keys.h"
#include "control.h"
#include "spinner.h"
#include "themes.h"
#include "reaction.h"
#include "screensaver.h"
#include "audio.h"
#include "audiocap.h"
#include "music.h"
#include "sdnotify.h"
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <poll.h>
#include <glob.h>
#include <sys/socket.h>
#include <sys/un.h>

#define SOCK "/run/nexusqd.sock"
#define THEMES_DIR "/etc/nexusqd/themes"
#define VOL_STEP 2          /* master-volume % per rotary detent (the ring emits many events/turn) */
#define MUTE_BLINK_S 0.5    /* mute-LED blink half-period for "update available" (CTL_MBLINK) */
#define VOL_APPLY_S  0.05   /* min seconds between nq-vol applies — coalesces a detent's
                             * event burst into one step and caps a fast turn's rate */

/* AVR keepalive: the AVR firmware stops lighting the ring if the host stops
 * sending frame commits for too long. That happens once the idle screensaver
 * locks (SS_LOCK_S) / blanks (SS_BLANK_S) to a *static* frame and the per-frame
 * memcmp gate in the render loop suppresses all further AVR writes — the AVR
 * then starves and the ring goes dark until nexusqd restarts. Re-commit the
 * current frame at this cadence even when unchanged so the AVR never starves.
 * Cheap: one 96-byte i2c write per interval, and only while the ring is idle
 * (an actively animating frame already writes on every tick via the memcmp). */
#define AVR_KEEPALIVE_S 1.0

/* PA sink-input gate (idle-CPU fix). The arecord visualizer tap is an UNCORKED
 * PA source-output on the active sink's `.monitor`; while it runs it keeps that
 * sink out of suspend-on-idle, so at SILENCE the tas5713 sink stays IDLE
 * (clocked) instead of SUSPENDED and PA+arecord burn ~10% CPU on this weak
 * OMAP4 doing nothing (top idle-heat contributor). Fix: only run the tap while a
 * real playback stream (a PA *sink-input*) exists — then PA suspends the sink at
 * true idle (CPU -> ~0, like the untapped spdif) yet the LED still reacts on
 * play. The gate signal is the count of UNCORKED sink-inputs, never captured
 * silence: a quiet passage still has an uncorked input, so the tap stays on
 * through it, while a corked one (paused stream, or module-loopback whose source
 * nq-uac2-silence has suspended) does not — that last case is why corked inputs
 * stopped counting, since otherwise this tap kept the amplifier powered through
 * every silence. To keep idle overhead near zero the re-count is event-driven,
 * with a TIMED safety net on top (PA_SAFETY_ON_S/OFF_S in audio.h). That net used
 * to be skipped while music flowed — "while music actually flows we never poll" —
 * leaving nothing to catch a stream that ends by CORKING (not a membership event)
 * if the capture also never reads raw-silent. It is now unconditional; see
 * pa_gate_poll_due. */
#define TAP_QUIET_S  4.0   /* raw-silent this long while tapping -> re-check if the stream ended */

/* r13: the gate is EVENT-DRIVEN. A persistent `pactl subscribe` child (see
 * pa_subscribe_open) feeds PA events into the poll loop, and a sink-input
 * membership event ("'new'/'remove' on sink-input") triggers the re-count —
 * the timed PA_POLL_S polling above becomes the FALLBACK for when the
 * subscriber is down (PA restarting / not up yet at boot). While the
 * subscriber is healthy the timed re-count degrades to a slow safety net
 * bounding the staleness of a missed event. Why it matters: the 1.5 s poll
 * forked a pactl ~0.67x/s around the clock (2026-08-13 idle attribution), and
 * every one of those short-lived clients also woke every OTHER PA subscriber
 * on the box (nexusq-control's bridge) with client-connect events. */
#define PA_SUB_RESPAWN_S 10.0  /* retry a dead `pactl subscribe` this often */
/* A just-forked subscriber is NOT yet evidence that PA is reachable: fork+exec
 * succeed even when PulseAudio is down (the child only EOFs afterwards). Trusting
 * a live fd alone let a doomed child arm the 30/60 s safety deadline, and the
 * 1.5 s degraded polling then never ran — the gate went blind for the whole
 * respawn gap. A subscriber earns the long horizon only after surviving this
 * long; until then the timed fallback stays at PA_POLL_S. */
#define PA_SUB_PROVEN_S  2.0

/* r13 idle render cadence. The ring's content is fingerprinted per tick anyway
 * (the AVR memcmp gate); once it has been bit-identical for IDLE_AFTER_TICKS
 * consecutive renders and nothing animated is active, the render deadline
 * stretches to IDLE_FRAME_S — matching the 1 Hz AVR keepalive, so a locked/
 * blanked screensaver costs one render+write per second instead of 20 wakeups/s
 * (measured 22 wake/s, ~4.4 % of a core, 2026-08-13 attribution). Any key
 * event, mutating control command, tap start, or frame change snaps it back.
 * While the tap runs but is silent (a PAUSED stream keeps its sink-input), the
 * cap is 0.25 s so un-pause shows on the ring without a visible hiccup; while
 * the update-available blink is live the cap is MUTE_BLINK_S to keep its 2 Hz. */
#define IDLE_FRAME_S     1.0
#define IDLE_TAP_FRAME_S 0.25
#define IDLE_AFTER_TICKS 40

/* Compositor layers, by priority:
 *   10  reaction   — volume overlay (Plan 2b), active only during the overlay
 *    9  music      — the audio-reactive scene (Plan 3b), shown while audio plays
 *    8  manual     — CLI/socket override (theme breathe, set/off, spin, progress)
 *    5  screensaver— the idle breathing screensaver (Plan 3), always on
 * The music scene fades in (childAlpha) when audio is present and the screensaver
 * fades out, mirroring BaseScreensaver; the volume overlay preempts everything.
 *
 * RING OFF (`dark 1`, the app's LED ring switch and its schedule): render with
 * the floor at RING_DARK_FLOOR, so only the layers that answer the user — music
 * and the volume overlay — can light the ring; the screensaver, the theme and
 * every notification on the manual layer stay dark, and so does the
 * update-available blink on the mute LED. `attend 1` (setup mode) lifts it. */
#define RING_DARK_FLOOR 9

/* --- manual override layer (priority 8) ----------------------------------- */
struct manual_ctx { int rgb[3]; int breathe; int spin; double spin_speed; int progress; };
static int manual_render(void *c, double t, struct frame *out) {
    struct manual_ctx *m = c;
    if (m->progress >= 0) {
        /* determinate bar: the first pct% of the ring bright, the rest a dim track */
        int k = (m->progress * RING + 50) / 100;
        for (int i = 0; i < RING; i++) {
            if (i < k) frame_set(out, i, m->rgb[0], m->rgb[1], m->rgb[2]);
            else       frame_set(out, i, m->rgb[0]/12, m->rgb[1]/12, m->rgb[2]/12);
        }
        return 0;
    }
    if (m->spin) { spinner_render(m->rgb, t, m->spin_speed, out); return 0; }
    if (m->breathe) {
        /* companion color theme: pulse in the hue using the SAME throb envelope
         * as the idle screensaver breathe (A in 0.1..0.8), but at priority 8 it is
         * always visible — even when music plays or the screensaver has blanked. */
        double A = 0.1 + 0.35 * (1.0 - screensaver_throb(t));
        frame_fill(out, (int)(m->rgb[0]*A + 0.5), (int)(m->rgb[1]*A + 0.5), (int)(m->rgb[2]*A + 0.5));
    } else {
        frame_fill(out, m->rgb[0], m->rgb[1], m->rgb[2]);
    }
    return 0;
}

/* --- music layer (priority 9): the audio-reactive scene ------------------- */
struct music_layer { struct music *m; float alpha; };
static int music_layer_render(void *c, double t, struct frame *out) {
    (void)t; struct music_layer *ml = c;
    if (ml->alpha <= 0.0f) return -1;          /* no music -> fall through to screensaver */
    music_render(ml->m, ml->alpha, out);
    return 0;
}

/* --- screensaver layer (priority 5): the idle breathing screensaver -------- */
static int screensaver_layer_render(void *c, double t, struct frame *out) {
    (void)t; screensaver_render((struct screensaver *)c, out); return 0;   /* updated in the main loop */
}

/* --- reaction layer (priority 10): the volume overlay (Plan 2b) ------------ */
static int reaction_layer_render(void *c, double t, struct frame *out) {
    struct reaction *rx = c;
    if (!reaction_overlay_active(rx, t)) return -1;   /* no overlay -> fall through to lower layer */
    reaction_render(rx, t, out);
    return 0;
}

static double now_s(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec/1e9; }

/* Name the process on the other end of a control connection: SO_PEERCRED is
 * kernel-supplied, so a client cannot misreport itself. Best-effort — an empty
 * answer costs nothing but a "-" in the debug line. */
static void peer_name(int fd, int *pid_out, char *comm, size_t n)
{
    snprintf(comm, n, "-");
    *pid_out = -1;
    struct ucred uc;
    socklen_t ul = sizeof uc;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &uc, &ul) != 0 || uc.pid <= 0)
        return;
    *pid_out = (int)uc.pid;
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/comm", (int)uc.pid);
    FILE *f = fopen(path, "re");
    if (!f)
        return;
    if (fgets(comm, (int)n, f)) {
        char *nl = strchr(comm, '\n');
        if (nl) *nl = '\0';
    }
    fclose(f);
}

/* apply the dedicated mute LED for the current muted state (#001E28 / #006B8E) */
static void apply_mute_led(int muted) {
    int r, g, b; reaction_mute_led(muted, &r, &g, &b); avr_set_mute(r, g, b);
}

/* Apply a front-panel volume/mute action to PulseAudio via nq-vol, run in the
 * appliance user's session (uid 10000). Fire-and-forget: SIGCHLD is SIG_IGN, so
 * the child is auto-reaped and we never block the render loop. This makes the
 * touch ring work HEADLESS — nexusqd is always running, whereas the labwc keybind
 * that used to run nq-vol needs the desktop compositor (labwc), which only starts
 * with an HDMI display. arg is "up" | "down" | "mute". */
static void nqvol_apply(const char *arg) {
    pid_t p = fork();
    if (p != 0) return;                     /* parent (or fork failed): carry on */
    int nul = open("/dev/null", O_RDWR);    /* detach stdio so pactl can't stall us */
    if (nul >= 0) { dup2(nul, 0); dup2(nul, 1); dup2(nul, 2); if (nul > 2) close(nul); }
    execlp("runuser", "runuser", "-u", "user", "--",
           "env", "XDG_RUNTIME_DIR=/run/user/10000", "/usr/bin/nq-vol", arg,
           (char *)NULL);
    _exit(127);
}

int main(void) {
    double start = now_s();
    struct reaction rx = {0};
    struct screensaver ss; screensaver_init(&ss, start);
    struct manual_ctx manual = { { 0, 0, 0 }, 0, 0, 0.0, -1 };
    int volume = 50;            /* virtual master volume for the reaction overlay (volume keys) */
    int muted = 0;
    /* autonomous mute-LED blink (CTL_MBLINK): "software update available". The daemon
     * toggles the mute LED on/off every MUTE_BLINK_S; any real mute/volume action
     * clears it so the physical mute state always wins. */
    int mute_blink = 0, mute_blink_on = 0, mute_blink_rgb[3] = { 0, 0, 0 };
    double mute_blink_next = 0.0;
    /* front-panel volume ring -> PulseAudio (via nq-vol). vol_dir holds the latest
     * turn direction; the main loop applies it at most once per VOL_APPLY_S, which
     * coalesces a detent's event burst and rate-limits a fast continuous turn. */
    int vol_dir = 0; double vol_apply_next = 0.0;
    int brightness = 255;       /* global ring brightness 0..255, scales the packed frame
                                 * (companion `brightness N` over the control socket) */
    int dark = 0, attend = 0;   /* ring-off gate + setup's hold on it (CTL_DARK/CTL_ATTEND);
                                 * the gate is effective while dark && !attend */

    /* Plan 3b audio: spawn `arecord -D pulse` to tap PA's default source, feed PCM
     * segments to the AudioCapture port (volume/FFT/beat); the music scene reacts
     * and the screensaver fades when getVolume >= 0.01. The tap is NOT opened here:
     * it is gated on a live PA sink-input (see the gate in audio.h) so it stays off at
     * idle and PA can suspend the sink. */
    signal(SIGCHLD, SIG_IGN);   /* reap arecord/pactl automatically when they exit */
    int afd = -1; pid_t apid = -1;
    struct audio_state ac; audiocap_init(&ac);
    struct music music; music_init(&music, (uint64_t)(start * 1e9));
    struct music_layer ml = { &music, 0.0f };
    float child_alpha = 0.0f;    /* mChildAlpha: the music scene's fade level */
    double no_audio_t = 0.0;     /* seconds since audio (for the scene fade-out delay) */
    double last_pcm = -1.0, prev_now = start, last_seg = -1.0;
    int prev_audio = 0;
    static float monoacc[SAMPLES_PER_SEGMENT]; int monofill = 0;

    struct compositor comp = {0};
    comp_add(&comp, (struct layer){ screensaver_layer_render, &ss, 5, 1 });
    /* 9, ABOVE the manual override at 8. A colour theme is the ring's IDLE
     * mood; the music scene is what it does while something plays, and the app
     * offers both as separate settings. With music below the override the
     * visualiser could never be seen at all once a theme was set — which went
     * unnoticed only because the theme used to be forgotten on every boot.
     * Making it persistent (control r37) made the ring permanently blue and the
     * visualiser permanently invisible; Petr, 2026-09-07: "prstenec ted neni
     * videt nikdy, musis to prehodit, vizualizace musi bejt nad tematem".
     *
     * Safe because this layer already yields: alpha <= 0 returns -1 and the
     * compositor falls through to the override, so the theme owns the ring
     * whenever nothing is playing. The volume overlay stays above both at 10. */
    comp_add(&comp, (struct layer){ music_layer_render, &ml, 9, 1 });      /* renders only when alpha>0 */
    int manual_idx = comp.n;
    comp_add(&comp, (struct layer){ manual_render, &manual, 8, 0 });       /* override, off by default */
    comp_add(&comp, (struct layer){ reaction_layer_render, &rx, 10, 1 });

    apply_mute_led(muted);      /* idle mute LED = unmuted #006B8E */

    char node[64]; int kfd = -1;
    if (keys_find_node(node, sizeof(node)) == 0) kfd = open(node, O_RDONLY | O_NONBLOCK);

    unlink(SOCK);
    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un sa = { .sun_family = AF_UNIX }; strcpy(sa.sun_path, SOCK);
    bind(srv, (struct sockaddr*)&sa, sizeof(sa)); listen(srv, 4);

    int prev_overlay = 0;
    uint8_t lastpk[RING*3] = {0}, pk[RING*3];
    double next_frame = now_s();   /* monotonic render deadline (decouples fps from audio) */
    double frame_int = 0.050;      /* current render interval; re-chosen at the END of each
                                    * tick from the state that tick produced (see there) */
    double afd_retry = 0.0;        /* next time to re-spawn arecord after it died */
    int    tap_should_run = 0;     /* a real PA playback stream (sink-input) exists -> tap on */
    double pa_poll = 0.0;          /* next timed/safety sink-input re-count deadline */
    double quiet_since = -1.0;     /* when the raw capture went silent while tapping (-1 = not) */
    int    sfd = -1;               /* `pactl subscribe` stdout (event feed), -1 = down */
    pid_t  spid = -1;
    double sfd_retry = 0.0;        /* next subscribe respawn attempt */
    double sfd_since = 0.0;        /* when the current subscriber was spawned (PA_SUB_PROVEN_S) */
    int    pa_check = 1;           /* re-count sink-inputs NOW (start with one to sync) */
    char   sline[256]; int slen = 0;   /* line assembly for the subscribe feed */
    int    static_ticks = 0;       /* consecutive renders with a bit-identical frame */

    /* --- cadence instrumentation (read out by `nexusled debug`) -------------
     * Free-running counters, never reset. The interesting quantity is a RATE,
     * so the reader samples twice and divides; that also means a wrapped or
     * restarted daemon cannot lie about an interval it did not observe.
     * `loops` vs `renders` is the diagnosis in one line: equal means the render
     * deadline drives the loop, loops >> renders means something else keeps
     * waking it. */
    unsigned long n_loops = 0, n_renders = 0, n_ctl = 0, n_keys = 0, n_rearm = 0;
    /* `spin` counts iterations that reached the wait with the deadline already
     * gone. It is the regression canary for the truncation bug fixed below: a
     * healthy daemon keeps loops ~= renders and spin ~= 0. */
    unsigned long n_spin = 0, n_ready = 0;
    /* `vol_cmds` counts every CTL_VOL that ARRIVES, not every one that re-arms
     * the overlay, and vol_from names the process that sent the last one. The
     * two are separate on purpose: the guard below makes a repeated set
     * harmless, and a harmless bug is one nobody ever finds again. A client
     * pushing the same volume in a loop still shows up here. */
    unsigned long n_vol = 0;
    int vol_pid = -1; char vol_comm[24] = "-";
    int    last_animating = 0;     /* the intent gate, as of the last cadence choice */

    /* systemd watchdog: init done (AVR + control socket up), tell systemd we are
     * ready, then ping WATCHDOG=1 from the render loop below. A *hang* in that
     * loop (a wedged AVR i2c write, a stuck poll, an effect that never returns)
     * stops the pings and systemd restarts us — the crash path was already
     * covered by Restart=, the hang path was not. No-op outside systemd. */
    sdnotify_send("READY=1");
    double last_wd = 0.0;          /* last WATCHDOG=1 ping (rate-limited to 1/s) */
    double last_avr_push = 0.0;    /* last AVR frame commit — drives the keepalive re-push */
    for (;;) {
        n_loops++;
        /* PA sink-input gate (idle-CPU fix — see PA_POLL_S / PA_SUB_* at the top).
         * Event-driven: `pactl subscribe` membership events set pa_check; the timed
         * re-count runs only as a slow safety net (subscriber proven) or at
         * PA_POLL_S (subscriber down/unproven — PA restarting / early boot). The
         * TIMED path fires whatever the tap is doing: it is the backstop for an
         * end-of-stream the subscriber cannot see (a cork is a 'change', not a
         * membership event), and at 30 s while tapping it costs one pactl per
         * half-minute of playback. An EVENT re-counts whenever it arrives,
         * including mid-playback: a membership change is exactly what the count
         * tracks, and it is bounded by real PA activity rather than by a clock. */
        {
            double nowg = now_s();
            if (sfd < 0 && nowg >= sfd_retry) {
                sfd = pa_subscribe_open(&spid);
                sfd_retry = nowg + PA_SUB_RESPAWN_S;
                sfd_since = nowg;
                if (sfd >= 0) { pa_check = 1; slen = 0; }   /* (re)spawned: resync the count */
            }
            int sub_proven = (sfd >= 0) && (nowg - sfd_since >= PA_SUB_PROVEN_S);
            /* An event, or the deadline — and NOT conditional on what the tap is
             * doing. Gating the timed net on "tap off, or tap on and raw-silent"
             * wedged the tap permanently on: see pa_gate_poll_due in audio.h. */
            if (pa_gate_poll_due(pa_check, nowg, pa_poll)) {
                int was = tap_should_run;
                tap_should_run = pa_sink_inputs_active() > 0;
                pa_check = 0;
                pa_poll = pa_gate_next_deadline(nowg, sub_proven, tap_should_run);
                if (tap_should_run && !was) {
                    /* a stream appeared: leave idle cadence NOW so the
                     * visualizer fade-in starts on the next iteration */
                    static_ticks = 0; next_frame = 0.0;
                }
            }
            if (tap_should_run) {
                /* (re)spawn arecord if it should be tapping but isn't yet
                 * (intentionally stopped, died, or PA was late at boot) — bounded
                 * to one short-lived arecord per AUDIO_RESPAWN_S, never a busy-spin. */
                if (afd < 0 && nowg >= afd_retry) {
                    afd = audio_open(&apid);
                    afd_retry = nowg + AUDIO_RESPAWN_S;
                }
            } else if (afd >= 0) {
                /* no stream -> stop the tap so PA suspends the sink (CPU -> ~0) */
                audio_close(&afd, &apid);
                monofill = 0; quiet_since = -1.0;
            }
        }

        struct pollfd pfds[4]; int np = 0;
        int ki = -1, ai = -1, pi = -1;
        if (kfd >= 0) { ki = np; pfds[np].fd = kfd; pfds[np].events = POLLIN; np++; }
        if (afd >= 0) { ai = np; pfds[np].fd = afd; pfds[np].events = POLLIN; np++; }
        if (sfd >= 0) { pi = np; pfds[np].fd = sfd; pfds[np].events = POLLIN; np++; }
        pfds[np].fd = srv; pfds[np].events = POLLIN; int srvi = np; np++;
        /* Frame cadence is chosen AFTER the event drains, just above the render
         * gate — never here. It is consumed only by the deadline advance
         * (`next_frame += frame_int`), and a handler that runs between this
         * point and there (a key, a control command, a PA event) changes which
         * cadence is correct. Computing it pre-poll made the post-event render
         * schedule its successor at the PRE-event interval: from idle cadence
         * that was a full 1 s, so a single volume detent rendered the overlay's
         * black first frame (eased=0, RX_COLOR_R=0) and the next render landed
         * after RX_TIMEOUT_S had already expired — a 1 s black ring instead of
         * the volume flash. poll()'s timeout derives from `next_frame` alone,
         * so it needs nothing from here. */
        /* Wait to the deadline in NANOSECONDS, via ppoll. poll(2) takes whole
         * milliseconds and this conversion used to truncate, so the last
         * sub-millisecond of every frame asked poll for 0 ms: it returned
         * instantly, the deadline had not arrived, the loop continued, and the
         * next iteration asked for 0 ms again — a busy-spin that ended only when
         * the clock caught up. Measured on the device at 20 fps: 380 of every
         * 400 iterations, 94.9 %, were that spin. It never looked like a bug
         * from outside, because the ring kept rendering its exact 20.0 fps; it
         * showed up only as CPU, which is how it survived the whole r13 idle
         * diet. A timespec has the resolution the deadline is expressed in, so
         * the remainder is simply waited out. */
        double rem = next_frame - now_s();
        if (rem <= 0.0) { rem = 0.0; n_spin++; }
        time_t rem_s = (time_t)rem;
        long rem_ns = (long)((rem - (double)rem_s) * 1e9);
        if (rem_ns < 0) rem_ns = 0;
        if (rem_ns > 999999999L) rem_ns = 999999999L;
        struct timespec tmo = { .tv_sec = rem_s, .tv_nsec = rem_ns };
        if (ppoll(pfds, np, &tmo, NULL) > 0) n_ready++;

        if (ki >= 0 && (pfds[ki].revents & POLLIN)) {
            uint8_t b[INPUT_EVENT_SIZE*64]; int r = (int)read(kfd, b, sizeof(b));
            struct keyev ev[64]; int n = r > 0 ? keys_decode(b, r, ev, 64) : 0;
            /* physical interaction: leave idle cadence and render immediately
             * (the volume overlay must appear at its full 16 ms cadence) */
            if (n > 0) { n_keys += (unsigned long)n; static_ticks = 0; next_frame = 0.0; }
            for (int i = 0; i < n; i++) {
                if (!ev[i].down) continue;
                double now = now_s();
                screensaver_on_activity(&ss, now);          /* wake the ring from blank */
                if (ev[i].code == KEY_MUTE) {
                    muted = !muted; apply_mute_led(muted);
                    if (!muted && mute_blink) { mute_blink_next = 0; mute_blink_on = 0; }   /* unmuted -> resume the update blink */
                    nqvol_apply("mute");                    /* toggle the real PA mute */
                } else if (ev[i].code == KEY_VOLUMEUP || ev[i].code == KEY_VOLUMEDOWN) {
                    volume += (ev[i].code == KEY_VOLUMEUP) ? VOL_STEP : -VOL_STEP;
                    if (volume > 100) volume = 100;
                    if (volume < 0) volume = 0;
                    reaction_on_volume(&rx, volume, now); n_rearm++;   /* LED overlay */
                    avr_set_mute(0, 0, 0);                  /* mute LED off during the volume overlay */
                    vol_dir = (ev[i].code == KEY_VOLUMEUP) ? 1 : -1;  /* apply (debounced) below */
                }
            }
        }
        if (pfds[srvi].revents & POLLIN) {
            int c = accept(srv, NULL, NULL);
            if (c >= 0) {
                char line[128] = {0}; int r = (int)read(c, line, sizeof(line)-1);
                struct ctl_cmd cmd;
                if (r > 0 && ctl_parse(line, &cmd) == 0) {
                    int quiet = 0;   /* a command that changed nothing (see CTL_DARK) */
                    if (cmd.kind == CTL_SET) { memcpy(manual.rgb, cmd.rgb, sizeof(manual.rgb)); manual.breathe = 0; manual.spin = 0; manual.progress = -1; comp.layers[manual_idx].active = 1; }
                    else if (cmd.kind == CTL_OFF) { manual.rgb[0]=manual.rgb[1]=manual.rgb[2]=0; manual.breathe = 0; manual.spin = 0; manual.progress = -1; comp.layers[manual_idx].active = 1; }
                    else if (cmd.kind == CTL_PROGRESS) { memcpy(manual.rgb, cmd.rgb, sizeof(manual.rgb)); manual.breathe = 0; manual.spin = 0; manual.progress = cmd.value; comp.layers[manual_idx].active = 1; }
                    else if (cmd.kind == CTL_AUTO) { comp.layers[manual_idx].active = 0; }   /* resume screensaver/music */
                    else if (cmd.kind == CTL_SCENE) { music_set_scene(&music, cmd.value); }
                    else if (cmd.kind == CTL_MUTE) { mute_blink = 0; avr_set_mute(cmd.rgb[0],cmd.rgb[1],cmd.rgb[2]); }  /* explicit LED override wins */
                    else if (cmd.kind == CTL_MTOGGLE) { muted = !muted; apply_mute_led(muted); if (!muted && mute_blink) { mute_blink_next = 0; mute_blink_on = 0; } screensaver_on_activity(&ss, now_s()); }
                    else if (cmd.kind == CTL_SETMUTED) { muted = cmd.value; apply_mute_led(muted); if (!muted && mute_blink) { mute_blink_next = 0; mute_blink_on = 0; } screensaver_on_activity(&ss, now_s()); }
                    else if (cmd.kind == CTL_MBLINK) {
                        if (cmd.value) {
                            mute_blink = 1; memcpy(mute_blink_rgb, cmd.rgb, sizeof(mute_blink_rgb));
                            mute_blink_on = 0; mute_blink_next = 0.0;   /* fire immediately on the next tick */
                        } else {
                            mute_blink = 0; apply_mute_led(muted);      /* restore the real mute state */
                        }
                    }
                    else if (cmd.kind == CTL_VOL) {
                        /* A set that does not MOVE the volume is a state sync,
                         * not an interaction, and re-arms nothing.
                         *
                         * Why this matters: the overlay relinquishes the ring
                         * RX_TIMEOUT_S (1 s) after the last change, so a client
                         * re-sending the current volume even once a second pins
                         * it on forever. That is not hypothetical — it is how
                         * the Q was found on 2026-09-16 after 2 d 21 h of
                         * uptime: the ring held a uniform #00516C, which is
                         * RX_COLOR at reaction_end_brightness(48), the cadence
                         * sat at the overlay's 16 ms, and `animating` stayed
                         * true, so the r13 idle stretch could never engage. The
                         * frame never changed, so nothing downstream saw a
                         * fault — it looked exactly like a healthy static ring.
                         *
                         * The KEY path deliberately keeps re-arming on every
                         * event, unchanged value or not: holding the detent at
                         * 0 or 100 is a person still turning the ring, and the
                         * overlay belongs on screen while they do. A command on
                         * a socket carries no such intent. */
                        int moved = (cmd.value != volume);
                        volume = cmd.value;
                        n_vol++;
                        peer_name(c, &vol_pid, vol_comm, sizeof vol_comm);
                        if (moved) {
                            double now = now_s();
                            screensaver_on_activity(&ss, now);
                            reaction_on_volume(&rx, volume, now); n_rearm++;
                            avr_set_mute(0, 0, 0);
                        }
                    }
                    else if (cmd.kind == CTL_BRIGHTNESS) {
                        /* nexusq-control re-asserts the level every minute (ambient
                         * brightness, and to restore it after a nexusqd restart);
                         * an unchanged one is a no-op, like an unchanged `dark`. */
                        if (cmd.value == brightness) quiet = 1;
                        else {
                            brightness = cmd.value;
                            memset(lastpk, 0xFF, sizeof(lastpk));   /* force a re-push at the new brightness */
                        }
                    }
                    else if (cmd.kind == CTL_BREATHE) {
                        /* companion color theme: a BREATHING solid-color override at
                         * priority 8 — pulses gently in the hue and is ALWAYS visible
                         * (over the visualizer, over a blanked/idle screensaver), so
                         * picking a color always lights the ring. `auto` clears it. */
                        memcpy(manual.rgb, cmd.rgb, sizeof(manual.rgb));
                        manual.breathe = 1; manual.spin = 0; manual.progress = -1; comp.layers[manual_idx].active = 1;
                    }
                    else if (cmd.kind == CTL_SPIN) {
                        /* setup-mode rotating dot (stock "starting up" visual):
                         * an ANIMATED manual override at priority 8. Cleared by
                         * auto/set/breathe/off like every manual mode. cmd.speed
                         * (rev/s, 0 = default) lets setupd vary the rate per
                         * phase — slower while joining, faster on success. */
                        memcpy(manual.rgb, cmd.rgb, sizeof(manual.rgb));
                        manual.breathe = 0; manual.spin = 1; manual.progress = -1;
                        manual.spin_speed = cmd.speed;
                        comp.layers[manual_idx].active = 1;
                    }
                    else if (cmd.kind == CTL_DARK || cmd.kind == CTL_ATTEND) {
                        /* nexusq-control re-asserts `dark` every half minute so a
                         * restarted nexusqd picks the setting back up. A re-assert
                         * that changes nothing is therefore the COMMON case and
                         * must not count as activity — it would pull the idle
                         * cadence back to 20 fps twice a minute. */
                        int was = dark && !attend;
                        if (cmd.kind == CTL_DARK) dark = cmd.value; else attend = cmd.value;
                        int gated = dark && !attend;
                        if (gated == was) quiet = 1;
                        else if (gated) {
                            /* going dark mid-blink: leave the mute LED on its real
                             * job (the steady mute state), never frozen amber */
                            if (mute_blink && !muted && !reaction_overlay_active(&rx, now_s())) apply_mute_led(muted);
                        } else if (mute_blink) { mute_blink_next = 0; mute_blink_on = 0; }   /* resume it */
                    }
                    else if (cmd.kind == CTL_THEME) {
                        char path[256]; snprintf(path, sizeof(path), "%s/theme_%s", THEMES_DIR, cmd.name);
                        FILE *fp = fopen(path, "r");
                        if (fp) { char js[1024]; int m=(int)fread(js,1,sizeof(js)-1,fp); js[m]=0; fclose(fp);
                                  struct theme t; if (theme_parse(&t,cmd.name,js)==0 && t.n_colors>0) { memcpy(manual.rgb,t.colors[0],3); manual.breathe = 0; manual.spin = 0; comp.layers[manual_idx].active = 1; } }
                    }
                    n_ctl++;
                    /* any mutating command leaves idle cadence and renders on this
                     * very iteration (volume overlay wants its 16 ms immediately).
                     * CTL_STATUS is the exception: healthd's `nexusled status`
                     * probe fires every 5 s and must not keep cadence fast.
                     * CTL_DEBUG is read-only and must be the same, or reading the
                     * cadence would be what breaks it. */
                    if (cmd.kind != CTL_STATUS && cmd.kind != CTL_DEBUG && !quiet) { static_ticks = 0; next_frame = 0.0; }
                    if (cmd.kind == CTL_DEBUG) {
                        /* One key=value line: the whole render-cadence state
                         * machine, plus the free-running counters. Every term of
                         * `animating` is reported SEPARATELY and live, because the
                         * gate is an OR — knowing it is true says nothing about
                         * which input made it true, and that was exactly the
                         * question that could not be answered from outside. */
                        double dnow = now_s();
                        double rx_age = rx.last_event > 0 ? dnow - rx.last_event : -1.0;
                        char db[512];
                        int dn = snprintf(db, sizeof db,
                            "up=%.1f loops=%lu renders=%lu spin=%lu ready=%lu "
                            "ctl=%lu keys=%lu rearm=%lu vol_cmds=%lu vol_from=%d:%s "
                            "frame_int=%.3f static_ticks=%d animating=%d "
                            "ovl=%d rx_age=%.3f child_alpha=%.3f "
                            "manual_active=%d manual_breathe=%d manual_spin=%d "
                            "ss_noaudio=%.1f ss_bright=%.4f "
                            "tap_fd=%d tap_should=%d quiet_since=%.1f vol=%d muted=%d "
                            "dark=%d attend=%d\n",
                            dnow - start, n_loops, n_renders, n_spin, n_ready,
                            n_ctl, n_keys, n_rearm, n_vol, vol_pid, vol_comm,
                            frame_int, static_ticks, last_animating,
                            reaction_overlay_active(&rx, dnow), rx_age, (double)child_alpha,
                            comp.layers[manual_idx].active, manual.breathe, manual.spin,
                            ss.elapsed_no_audio, screensaver_brightness(&ss),
                            afd, tap_should_run,
                            quiet_since >= 0.0 ? dnow - quiet_since : -1.0,
                            volume, muted, dark, attend);
                        if (dn > 0 && write(c, db, (size_t)dn) < 0) { /* client gone */ }
                    }
                    else if (write(c, "ok\n", 3) < 0) { /* client gone */ }
                } else { if (write(c, "err\n", 4) < 0) { /* client gone */ } }
                close(c);
            }
        }

        /* PA subscribe feed: assemble lines, flag a sink-input event for the gate
         * at the top of the loop.
         *
         * 'new'/'remove' always count. 'change' is admitted ONLY while nothing is
         * actually playing — the tap is off, or it is on but the captured audio
         * has gone quiet. Corking is a 'change', and since the gate now counts
         * uncorked inputs (see audio.h) a cork/uncork really does move the count:
         * ignoring it outright would leave the tap running through a sleeping USB
         * source until the 30 s safety re-count, and would take up to 60 s to
         * light the visualizer again after unpausing. Admitting it unconditionally
         * is what the original code rightly refused: 'change' fires constantly
         * during playback and every one would fork a `pactl`. The quiet test
         * keeps r12's "while music flows we never poll" intact. EOF/HUP =
         * subscriber (or PA) died:
         * close and let the gate respawn it after PA_SUB_RESPAWN_S, with timed
         * polling covering the gap. */
        if (pi >= 0 && (pfds[pi].revents & (POLLIN | POLLHUP | POLLERR))) {
            char sb[512]; ssize_t sr; int sdead = 0;
            while ((sr = read(sfd, sb, sizeof sb)) > 0) {
                for (ssize_t si = 0; si < sr; si++) {
                    if (sb[si] == '\n') {
                        sline[slen] = 0; slen = 0;
                        if (strstr(sline, "on sink-input")) {
                            if (strstr(sline, "'new'") || strstr(sline, "'remove'"))
                                pa_check = 1;
                            else if (strstr(sline, "'change'") &&
                                     (!tap_should_run || quiet_since >= 0.0))
                                pa_check = 1;   /* cork/uncork, and nothing playing */
                        }
                    } else if (slen < (int)sizeof(sline) - 1) {
                        sline[slen++] = (char)sb[si];
                    }
                }
            }
            if (sr == 0) sdead = 1;   /* EOF: pactl exited */
            if (sdead || (pfds[pi].revents & (POLLHUP | POLLERR))) {
                /* child already gone or pipe broken — auto-reaped (SIGCHLD=IGN),
                 * so just drop the fd; never kill spid (pid may be reused) */
                close(sfd); sfd = -1; spid = -1; pi = -1; slen = 0;
                double nowd = now_s();
                sfd_retry = nowd + PA_SUB_RESPAWN_S;
                /* Re-arm the timed fallback: without this the deadline armed
                 * while the subscriber was alive (up to 60 s out) survives its
                 * death, so neither events nor polling would re-count for the
                 * whole respawn gap — a stream started right after a PA restart
                 * would leave the visualizer dark for ~10 s. */
                if (pa_poll > nowd + PA_POLL_S) pa_poll = nowd + PA_POLL_S;
            }
        }

        double now = now_s();

        /* autonomous mute-LED blink ("update available"): a PERSISTENT indicator that
         * survives everything on the ring (theme/colour change, music visualiser,
         * screensaver — none of which touch the mute LED). It is only SUPPRESSED while
         * the mute LED is needed for its real job (actual mute, or a volume overlay
         * that borrows the LED) and resumes the moment that ends. Toggles every
         * MUTE_BLINK_S; the deadline gate keeps AVR writes to ~2x/s. Only `mblink stop`
         * (or an explicit `mute R G B` override) clears the flag. */
        int ring_dark = dark && !attend;   /* the ring-off gate, for this whole tick */
        if (mute_blink && !muted && !ring_dark && !reaction_overlay_active(&rx, now) && now >= mute_blink_next) {
            mute_blink_on = !mute_blink_on;
            if (mute_blink_on) avr_set_mute(mute_blink_rgb[0], mute_blink_rgb[1], mute_blink_rgb[2]);
            else               avr_set_mute(0, 0, 0);
            mute_blink_next = now + MUTE_BLINK_S;
        }

        /* front-panel volume ring -> PulseAudio, debounced: apply the pending turn
         * direction at most once per VOL_APPLY_S. One nq-vol step per apply coalesces
         * a detent's event burst; a held fast turn steps at ~1/VOL_APPLY_S. Makes the
         * ring work with the desktop OFF (nexusqd is always up; labwc is not). */
        if (vol_dir != 0 && now >= vol_apply_next) {
            nqvol_apply(vol_dir > 0 ? "up" : "down");
            vol_dir = 0;
            vol_apply_next = now + VOL_APPLY_S;
        }

        /* drain captured PCM -> mono -> 1024-sample segments at ~SEGMENTS_PER_SECOND.
         * Runs on every wake (cheap: copy + rate-limited segment hand-off) so the
         * pipe never backs up, regardless of whether this wake is a frame tick. */
        if (ai >= 0 && (pfds[ai].revents & (POLLIN | POLLHUP | POLLERR))) {
            static int16_t pcm[8192];
            ssize_t rr;
            int got = 0, dead = 0;
            for (;;) {
                rr = read(afd, pcm, sizeof pcm);
                if (rr == 0) { dead = 1; break; }   /* EOF: arecord exited, pipe closed */
                if (rr < 0)  break;                  /* EAGAIN: drained for now */
                int frames = (int)(rr / (ssize_t)sizeof(int16_t)) / AUDIO_CHANNELS;
                for (int fr = 0; fr < frames; fr++) {
                    int l = pcm[fr*AUDIO_CHANNELS], r2 = pcm[fr*AUDIO_CHANNELS + 1];
                    monoacc[monofill++] = (l + r2) / 2.0f / 32768.0f;
                    if (monofill == SAMPLES_PER_SEGMENT) {
                        if (last_seg < 0.0 || now - last_seg >= 1.0 / SEGMENTS_PER_SECOND) {
                            audiocap_on_segment(&ac, monoacc);
                            last_seg = now;
                        }
                        monofill = 0;
                    }
                }
                got = 1;
            }
            if (got) last_pcm = now;
            /* If arecord died (EOF) or the fd errored, stop polling the dead pipe:
             * a HUP/ERR fd keeps poll() returning instantly, which free-runs the
             * loop at ~90% CPU. Close it; the top-of-loop re-spawn retries later. */
            if (dead || (pfds[ai].revents & (POLLHUP | POLLERR))) {
                /* arecord already exited (auto-reaped by SIGCHLD=SIG_IGN), so just
                 * drop the fd — do NOT kill apid (its pid may already be reused). */
                close(afd); afd = -1; apid = -1; ai = -1; monofill = 0;
                afd_retry = now + AUDIO_RESPAWN_S;
            }
        }

        /* Frame tick: skip the heavy per-frame work (FFT, fades, compositor,
         * AVR write) on early audio/input-driven wakes; only run it once the
         * monotonic deadline is due. dt is measured render-to-render, not
         * wake-to-wake, so the fades advance at real time. */
        if (now < next_frame) continue;
        n_renders++;
        double tick_base = next_frame;   /* the deadline is advanced at the END of
                                          * this tick, once the cadence the just-
                                          * rendered state implies is known */
        double dt = now - prev_now; prev_now = now;

        audiocap_on_new_frame(&ac);
        float vol = audiocap_volume(&ac);
        if (last_pcm < 0.0 || now - last_pcm > 0.15) vol = 0.0f;   /* no data -> silence */

        /* BaseScreensaver fade split: music scene (childAlpha) vs idle breathing */
        if (vol >= SS_AUDIO_THRESH) {
            no_audio_t = 0.0;
            child_alpha += (float)(dt / 1.0);                 /* mSceneFadeSeconds = 1 */
            if (child_alpha > 1.0f) child_alpha = 1.0f;
        } else {
            no_audio_t += dt;
            if (no_audio_t > 2.0) {                            /* mSecondsBeforeSceneFadeOut = 2 */
                child_alpha -= (float)(dt / 1.0);
                if (child_alpha < 0.0f) child_alpha = 0.0f;
            }
        }
        screensaver_update(&ss, now, dt, vol);
        if (child_alpha > 0.0f) music_update(&music, &ac, (float)dt);
        ml.alpha = child_alpha;

        int audio_on = vol >= SS_AUDIO_THRESH;
        /* Track how long the raw capture has been silent WHILE the tap runs, so the
         * gate above knows when to re-count sink-inputs. `vol` here is post-noise-
         * gate (audiocap zeroes it below AGC_NOISE_FLOOR), so vol==0 means true raw
         * silence, not a quiet-but-present passage (AGC amplifies that to ~target).
         * This is only a re-check TRIGGER — the authoritative stop signal remains the
         * sink-input count, so a quiet passage never actually stops the tap. */
        if (tap_should_run && afd >= 0 && !audio_on) {
            if (quiet_since < 0.0) quiet_since = now;
        } else {
            quiet_since = -1.0;
        }
        if (audio_on != prev_audio) {
            fprintf(stderr, "[nexusqd] audio %s (vol=%.3f) scene=%d\n",
                    audio_on ? "DETECTED" : "silent", vol, music_scene(&music));
            prev_audio = audio_on;
        }

        int cur_overlay = reaction_overlay_active(&rx, now);
        if (prev_overlay && !cur_overlay) {
            /* overlay timed out -> hand the mute LED back: resume the update blink if
             * one is pending (and we're not muted), else restore the steady mute state */
            if (mute_blink && !muted && !ring_dark) { mute_blink_next = 0; mute_blink_on = 0; }
            else apply_mute_led(muted);
        }
        prev_overlay = cur_overlay;

        struct frame f;
        if (ring_dark) comp_render_floor(&comp, now, &f, RING_DARK_FLOOR);
        else           comp_render(&comp, now, &f);
        frame_pack(&f, pk);
        /* global ring brightness: scale the packed frame (255 = unchanged). The
         * dedicated mute LED is written separately and is not dimmed here. */
        if (brightness < 255)
            for (int i = 0; i < RING*3; i++) pk[i] = (uint8_t)(pk[i] * brightness / 255);
        /* Push to the AVR on any change, and additionally re-push the unchanged
         * frame every AVR_KEEPALIVE_S so the AVR never starves once the ring goes
         * idle/static (screensaver lock/blank) — see AVR_KEEPALIVE_S above. */
        int frame_changed = memcmp(pk, lastpk, sizeof(pk)) != 0;
        if (frame_changed) static_ticks = 0;
        else if (static_ticks < IDLE_AFTER_TICKS) static_ticks++;   /* saturate; no overflow */
        if (frame_changed || now - last_avr_push >= AVR_KEEPALIVE_S) {
            avr_write_frame(pk, 0); memcpy(lastpk, pk, sizeof(pk)); last_avr_push = now;
        }

        /* Heartbeat: reached the end of a frame tick, so the render path is
         * alive (this runs even when the frame is unchanged / the ring is idle).
         * Rate-limited to once a second; WatchdogSec in the unit is far larger. */
        if (now - last_wd >= 1.0) { sdnotify_send("WATCHDOG=1"); last_wd = now; }

        /* --- next deadline: cadence chosen from the state this tick produced ---
         * Base: 16 ms during the volume fade, 30 ms (~33 fps) while a music scene
         * plays, else 50 ms (20 fps). The render is driven by this monotonic
         * deadline, NOT by audio-pipe readability: a continuously-fed ALSA
         * loopback keeps `afd` readable, so polling on it would return instantly
         * and free-run the loop (the old ~37 % CPU bug). poll() only sleeps until
         * the next frame is due; audio/input arriving sooner just wakes us to
         * drain, then we loop and re-sleep. */
        int ovl = reaction_overlay_active(&rx, now);
        frame_int = ovl ? 0.016
                  : ((child_alpha > 0.0f || (!ring_dark && comp.layers[manual_idx].active && manual.spin)) ? 0.030 : 0.050);
        /* r13 idle stretch (see IDLE_FRAME_S at the top). Two conditions must BOTH
         * hold, because neither alone is sound:
         *   - INTENT: nothing on the ring is meant to be animating — no volume
         *     overlay, no music scene/fade, no breathe/spin override, and the
         *     screensaver itself is locked (constant ledAlpha past SS_LOCK_S) or
         *     blanked. Bytes alone are NOT enough: near its cosine trough the
         *     breathing screensaver quantizes to an identical frame for seconds
         *     at low global brightness, so a bytes-only test would back off
         *     mid-animation and the breath would visibly freeze, then step.
         *   - BYTES: the frame has actually been identical for IDLE_AFTER_TICKS
         *     renders, so we never stretch across a still-settling transition.
         * Caps: the update-available blink keeps its 2 Hz; an open tap (a PAUSED
         * stream still holds a sink-input) keeps 4 Hz so un-pause shows promptly —
         * but only while that tap could still produce something. A tap that has
         * been RAW-SILENT for TAP_QUIET_S gets the full 1 Hz stretch: the USB-DAC
         * bridge holds a sink-input open forever and streams digital silence
         * whenever the host box is on, so the 4 Hz cap otherwise applied 24/7 and
         * the ring rendered 4 fps for a blanked screensaver (measured 2.1 % of a
         * core over the 2026-08-24 USB-audio idle run, 13x nexusqd's r13 budget).
         * Dropping the cap costs no responsiveness: afd is in the poll set, so the
         * first non-silent period WAKES the loop to drain and the very next
         * iteration renders — the cap was only ever belt-and-braces for a
         * paused->playing transition, which arrives as audio data too. */
        /* A dark ring hides the manual layer and the screensaver, so neither
         * can be "meant to animate" — the ring-off state idles at 1 Hz. */
        int animating = ovl || child_alpha > 0.0f
                     || (!ring_dark && comp.layers[manual_idx].active && (manual.breathe || manual.spin))
                     || (!ring_dark && !(ss.elapsed_no_audio > SS_LOCK_S || screensaver_brightness(&ss) <= 0.0));
        last_animating = animating;
        int tap_silent = quiet_since >= 0.0 && (now - quiet_since) >= TAP_QUIET_S;
        if (!animating && static_ticks >= IDLE_AFTER_TICKS && frame_int < IDLE_FRAME_S) {
            double cap = IDLE_FRAME_S;
            if (afd >= 0 && !tap_silent && cap > IDLE_TAP_FRAME_S) cap = IDLE_TAP_FRAME_S;
            if (mute_blink && !muted && !ring_dark && cap > MUTE_BLINK_S) cap = MUTE_BLINK_S;
            if (frame_int < cap) frame_int = cap;
        }
        next_frame = tick_base + frame_int;
        if (next_frame < now) next_frame = now + frame_int;   /* fell behind -> resync */
    }
}
