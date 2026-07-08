/* userspace/nexusqd/src/nexusqd.c */
#define _POSIX_C_SOURCE 200809L   /* clock_gettime/CLOCK_MONOTONIC, AF_UNIX, poll under -std=c11 */
#include "frame.h"
#include "avr.h"
#include "compositor.h"
#include "keys.h"
#include "control.h"
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
 * play. The gate signal is the sink-input COUNT, never captured silence: a quiet
 * passage / paused-connected stream still has a sink-input, so the tap stays on
 * through it. To keep idle overhead near zero we run `pactl` only at a possible
 * transition — while the tap is OFF (watch for a stream starting) and while it is
 * ON but raw-silent for TAP_QUIET_S (watch for the stream ending); while music
 * actually flows we never poll. */
#define PA_POLL_S    1.5   /* min seconds between sink-input re-counts (at a transition) */
#define TAP_QUIET_S  4.0   /* raw-silent this long while tapping -> re-check if the stream ended */

/* Compositor layers, by priority (matches the original arbitration):
 *   10  reaction   — volume overlay (Plan 2b), active only during the overlay
 *    8  manual     — CLI/socket override (set/theme/off), off until used (our feature)
 *    7  music      — the audio-reactive scene (Plan 3b), shown while audio plays
 *    5  screensaver— the idle breathing screensaver (Plan 3), always on
 * The music scene fades in (childAlpha) when audio is present and the screensaver
 * fades out, mirroring BaseScreensaver; the volume overlay preempts everything. */

/* --- manual override layer (priority 8) ----------------------------------- */
struct manual_ctx { int rgb[3]; int breathe; };
static int manual_render(void *c, double t, struct frame *out) {
    struct manual_ctx *m = c;
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

/* --- music layer (priority 7): the audio-reactive scene ------------------- */
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

/* apply the dedicated mute LED for the current muted state (#001E28 / #006B8E) */
static void apply_mute_led(int muted) {
    int r, g, b; reaction_mute_led(muted, &r, &g, &b); avr_set_mute(r, g, b);
}

int main(void) {
    double start = now_s();
    struct reaction rx = {0};
    struct screensaver ss; screensaver_init(&ss, start);
    struct manual_ctx manual = { { 0, 0, 0 }, 0 };
    int volume = 50;            /* virtual master volume for the reaction overlay (volume keys) */
    int muted = 0;
    int brightness = 255;       /* global ring brightness 0..255, scales the packed frame
                                 * (companion `brightness N` over the control socket) */

    /* Plan 3b audio: spawn `arecord -D pulse` to tap PA's default source, feed PCM
     * segments to the AudioCapture port (volume/FFT/beat); the music scene reacts
     * and the screensaver fades when getVolume >= 0.01. The tap is NOT opened here:
     * it is gated on a live PA sink-input (see PA_POLL_S above) so it stays off at
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
    comp_add(&comp, (struct layer){ music_layer_render, &ml, 7, 1 });      /* renders only when alpha>0 */
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
    double afd_retry = 0.0;        /* next time to re-spawn arecord after it died */
    int    tap_should_run = 0;     /* a real PA playback stream (sink-input) exists -> tap on */
    double pa_poll = 0.0;          /* next PA sink-input re-count (gated; 0 = check now) */
    double quiet_since = -1.0;     /* when the raw capture went silent while tapping (-1 = not) */

    /* systemd watchdog: init done (AVR + control socket up), tell systemd we are
     * ready, then ping WATCHDOG=1 from the render loop below. A *hang* in that
     * loop (a wedged AVR i2c write, a stuck poll, an effect that never returns)
     * stops the pings and systemd restarts us — the crash path was already
     * covered by Restart=, the hang path was not. No-op outside systemd. */
    sdnotify_send("READY=1");
    double last_wd = 0.0;          /* last WATCHDOG=1 ping (rate-limited to 1/s) */
    double last_avr_push = 0.0;    /* last AVR frame commit — drives the keepalive re-push */
    for (;;) {
        /* PA sink-input gate (idle-CPU fix — see PA_POLL_S at the top). Re-count PA
         * playback streams only at a possible transition: while the tap is OFF (a
         * stream may have started) or while it is ON but has been raw-silent for
         * TAP_QUIET_S (the stream may have ended). While music flows we never poll. */
        {
            double nowg = now_s();
            int poll_due = 0;
            if (!tap_should_run)
                poll_due = nowg >= pa_poll;                       /* watch for a stream starting */
            else if (quiet_since >= 0.0 && nowg - quiet_since >= TAP_QUIET_S)
                poll_due = nowg >= pa_poll;                       /* raw-silent a while: ended? */
            if (poll_due) {
                tap_should_run = pa_sink_inputs_active() > 0;
                pa_poll = nowg + PA_POLL_S;
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

        struct pollfd pfds[3]; int np = 0;
        int ki = -1, ai = -1;
        if (kfd >= 0) { ki = np; pfds[np].fd = kfd; pfds[np].events = POLLIN; np++; }
        if (afd >= 0) { ai = np; pfds[np].fd = afd; pfds[np].events = POLLIN; np++; }
        pfds[np].fd = srv; pfds[np].events = POLLIN; int srvi = np; np++;
        /* Frame cadence: 16 ms during the volume fade, 30 ms (~33 fps) while a
         * music scene plays, else 50 ms (20 fps). The render is driven by the
         * `next_frame` monotonic deadline below, NOT by audio-pipe readability:
         * a continuously-fed ALSA loopback keeps `afd` readable, so polling on it
         * would return instantly and free-run the render loop (the old ~37% CPU
         * bug). poll() now only sleeps until the next frame is due; audio/input
         * that arrives sooner just wakes us to drain, then we loop and re-sleep. */
        double frame_int = reaction_overlay_active(&rx, now_s()) ? 0.016
                         : (child_alpha > 0.0f ? 0.030 : 0.050);
        int to = (int)((next_frame - now_s()) * 1000.0);
        if (to < 0) to = 0;
        poll(pfds, np, to);

        if (ki >= 0 && (pfds[ki].revents & POLLIN)) {
            uint8_t b[INPUT_EVENT_SIZE*64]; int r = (int)read(kfd, b, sizeof(b));
            struct keyev ev[64]; int n = r > 0 ? keys_decode(b, r, ev, 64) : 0;
            for (int i = 0; i < n; i++) {
                if (!ev[i].down) continue;
                double now = now_s();
                screensaver_on_activity(&ss, now);          /* wake the ring from blank */
                if (ev[i].code == KEY_MUTE) {
                    muted = !muted; apply_mute_led(muted);
                } else if (ev[i].code == KEY_VOLUMEUP || ev[i].code == KEY_VOLUMEDOWN) {
                    volume += (ev[i].code == KEY_VOLUMEUP) ? VOL_STEP : -VOL_STEP;
                    if (volume > 100) volume = 100;
                    if (volume < 0) volume = 0;
                    reaction_on_volume(&rx, volume, now);
                    avr_set_mute(0, 0, 0);                  /* mute LED off during the volume overlay */
                }
            }
        }
        if (pfds[srvi].revents & POLLIN) {
            int c = accept(srv, NULL, NULL);
            if (c >= 0) {
                char line[128] = {0}; int r = (int)read(c, line, sizeof(line)-1);
                struct ctl_cmd cmd;
                if (r > 0 && ctl_parse(line, &cmd) == 0) {
                    if (cmd.kind == CTL_SET) { memcpy(manual.rgb, cmd.rgb, sizeof(manual.rgb)); manual.breathe = 0; comp.layers[manual_idx].active = 1; }
                    else if (cmd.kind == CTL_OFF) { manual.rgb[0]=manual.rgb[1]=manual.rgb[2]=0; manual.breathe = 0; comp.layers[manual_idx].active = 1; }
                    else if (cmd.kind == CTL_AUTO) { comp.layers[manual_idx].active = 0; }   /* resume screensaver/music */
                    else if (cmd.kind == CTL_SCENE) { music_set_scene(&music, cmd.value); }
                    else if (cmd.kind == CTL_MUTE) avr_set_mute(cmd.rgb[0],cmd.rgb[1],cmd.rgb[2]);
                    else if (cmd.kind == CTL_MTOGGLE) { muted = !muted; apply_mute_led(muted); screensaver_on_activity(&ss, now_s()); }
                    else if (cmd.kind == CTL_SETMUTED) { muted = cmd.value; apply_mute_led(muted); screensaver_on_activity(&ss, now_s()); }
                    else if (cmd.kind == CTL_VOL) {
                        double now = now_s();
                        volume = cmd.value;
                        screensaver_on_activity(&ss, now);
                        reaction_on_volume(&rx, volume, now);
                        avr_set_mute(0, 0, 0);
                    }
                    else if (cmd.kind == CTL_BRIGHTNESS) {
                        brightness = cmd.value;
                        memset(lastpk, 0xFF, sizeof(lastpk));   /* force a re-push at the new brightness */
                    }
                    else if (cmd.kind == CTL_BREATHE) {
                        /* companion color theme: a BREATHING solid-color override at
                         * priority 8 — pulses gently in the hue and is ALWAYS visible
                         * (over the visualizer, over a blanked/idle screensaver), so
                         * picking a color always lights the ring. `auto` clears it. */
                        memcpy(manual.rgb, cmd.rgb, sizeof(manual.rgb));
                        manual.breathe = 1; comp.layers[manual_idx].active = 1;
                    }
                    else if (cmd.kind == CTL_THEME) {
                        char path[256]; snprintf(path, sizeof(path), "%s/theme_%s", THEMES_DIR, cmd.name);
                        FILE *fp = fopen(path, "r");
                        if (fp) { char js[1024]; int m=(int)fread(js,1,sizeof(js)-1,fp); js[m]=0; fclose(fp);
                                  struct theme t; if (theme_parse(&t,cmd.name,js)==0 && t.n_colors>0) { memcpy(manual.rgb,t.colors[0],3); manual.breathe = 0; comp.layers[manual_idx].active = 1; } }
                    }
                    if (write(c, "ok\n", 3) < 0) { /* client gone */ }
                } else { if (write(c, "err\n", 4) < 0) { /* client gone */ } }
                close(c);
            }
        }

        double now = now_s();

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
        next_frame += frame_int;
        if (next_frame < now) next_frame = now + frame_int;   /* fell behind -> resync */
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
        if (prev_overlay && !cur_overlay) apply_mute_led(muted);  /* overlay timed out -> restore mute LED */
        prev_overlay = cur_overlay;

        struct frame f; comp_render(&comp, now, &f); frame_pack(&f, pk);
        /* global ring brightness: scale the packed frame (255 = unchanged). The
         * dedicated mute LED is written separately and is not dimmed here. */
        if (brightness < 255)
            for (int i = 0; i < RING*3; i++) pk[i] = (uint8_t)(pk[i] * brightness / 255);
        /* Push to the AVR on any change, and additionally re-push the unchanged
         * frame every AVR_KEEPALIVE_S so the AVR never starves once the ring goes
         * idle/static (screensaver lock/blank) — see AVR_KEEPALIVE_S above. */
        if (memcmp(pk, lastpk, sizeof(pk)) != 0 || now - last_avr_push >= AVR_KEEPALIVE_S) {
            avr_write_frame(pk, 0); memcpy(lastpk, pk, sizeof(pk)); last_avr_push = now;
        }

        /* Heartbeat: reached the end of a frame tick, so the render path is
         * alive (this runs even when the frame is unchanged / the ring is idle).
         * Rate-limited to once a second; WatchdogSec in the unit is far larger. */
        if (now - last_wd >= 1.0) { sdnotify_send("WATCHDOG=1"); last_wd = now; }
    }
}
