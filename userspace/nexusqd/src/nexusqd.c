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

/* Compositor layers, by priority:
 *   10  reaction   — volume overlay (Plan 2b), active only during the overlay
 *    6  manual     — CLI/socket override (set/theme/off), off until used (our feature)
 *    5  screensaver— the idle breathing screensaver (Plan 3), always on
 * When nothing higher renders, the screensaver owns the ring (matching the
 * original Visualizer at priority 5). */

/* --- manual override layer (priority 6) ----------------------------------- */
struct manual_ctx { int rgb[3]; };
static int manual_render(void *c, double t, struct frame *out) {
    (void)t; struct manual_ctx *m = c;
    frame_fill(out, m->rgb[0], m->rgb[1], m->rgb[2]); return 0;
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
    struct manual_ctx manual = { { 0, 0, 0 } };
    int volume = 50;            /* virtual master volume for the reaction overlay (volume keys) */
    int muted = 0;

    /* Plan 3b audio tap: spawn arecord on the ALSA loopback; the screensaver fades
     * when the captured output mix has signal (getVolume >= 0.01). */
    signal(SIGCHLD, SIG_IGN);   /* reap arecord automatically if it exits */
    int afd = audio_open();
    float audio_vol = 0.0f;
    double last_pcm = -1.0, prev_now = start;
    int prev_audio = 0;

    struct compositor comp = {0};
    comp_add(&comp, (struct layer){ screensaver_layer_render, &ss, 5, 1 });
    int manual_idx = comp.n;
    comp_add(&comp, (struct layer){ manual_render, &manual, 6, 0 });   /* override, off by default */
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
    for (;;) {
        struct pollfd pfds[3]; int np = 0;
        int ki = -1, ai = -1;
        if (kfd >= 0) { ki = np; pfds[np].fd = kfd; pfds[np].events = POLLIN; np++; }
        if (afd >= 0) { ai = np; pfds[np].fd = afd; pfds[np].events = POLLIN; np++; }
        pfds[np].fd = srv; pfds[np].events = POLLIN; int srvi = np; np++;
        /* 16 ms during the volume fade; otherwise 50 ms is smooth for the 10 s breath */
        int to = reaction_overlay_active(&rx, now_s()) ? 16 : 50;
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
                    if (cmd.kind == CTL_SET) { memcpy(manual.rgb, cmd.rgb, sizeof(manual.rgb)); comp.layers[manual_idx].active = 1; }
                    else if (cmd.kind == CTL_OFF) { manual.rgb[0]=manual.rgb[1]=manual.rgb[2]=0; comp.layers[manual_idx].active = 1; }
                    else if (cmd.kind == CTL_AUTO) { comp.layers[manual_idx].active = 0; }   /* resume screensaver */
                    else if (cmd.kind == CTL_MUTE) avr_set_mute(cmd.rgb[0],cmd.rgb[1],cmd.rgb[2]);
                    else if (cmd.kind == CTL_MTOGGLE) { muted = !muted; apply_mute_led(muted); screensaver_on_activity(&ss, now_s()); }
                    else if (cmd.kind == CTL_VOL) {
                        double now = now_s();
                        volume = cmd.value;
                        screensaver_on_activity(&ss, now);
                        reaction_on_volume(&rx, volume, now);
                        avr_set_mute(0, 0, 0);
                    }
                    else if (cmd.kind == CTL_THEME) {
                        char path[256]; snprintf(path, sizeof(path), "%s/theme_%s", THEMES_DIR, cmd.name);
                        FILE *fp = fopen(path, "r");
                        if (fp) { char js[1024]; int m=(int)fread(js,1,sizeof(js)-1,fp); js[m]=0; fclose(fp);
                                  struct theme t; if (theme_parse(&t,cmd.name,js)==0 && t.n_colors>0) { memcpy(manual.rgb,t.colors[0],3); comp.layers[manual_idx].active = 1; } }
                    }
                    if (write(c, "ok\n", 3) < 0) { /* client gone */ }
                } else { if (write(c, "err\n", 4) < 0) { /* client gone */ } }
                close(c);
            }
        }

        double now = now_s();
        double dt = now - prev_now; prev_now = now;

        /* drain captured PCM -> getVolume; hold ~150 ms so brief gaps aren't silence */
        if (ai >= 0 && (pfds[ai].revents & POLLIN)) {
            static int16_t pcm[8192];
            ssize_t rr = read(afd, pcm, sizeof pcm);
            if (rr > 0) {
                audio_vol = audio_mean_abs(pcm, (int)(rr / (ssize_t)sizeof pcm[0]));
                last_pcm = now;
                char junk[4096]; while (read(afd, junk, sizeof junk) > 0) { }   /* keep latency low */
            }
        }
        if (last_pcm >= 0.0 && now - last_pcm > 0.15) audio_vol = 0.0f;

        screensaver_update(&ss, now, dt, audio_vol);
        int audio_on = audio_vol >= SS_AUDIO_THRESH;
        if (audio_on != prev_audio) {
            fprintf(stderr, "[nexusqd] audio %s (vol=%.3f)\n", audio_on ? "DETECTED" : "silent", audio_vol);
            prev_audio = audio_on;
        }

        int cur_overlay = reaction_overlay_active(&rx, now);
        if (prev_overlay && !cur_overlay) apply_mute_led(muted);  /* overlay timed out -> restore mute LED */
        prev_overlay = cur_overlay;

        struct frame f; comp_render(&comp, now, &f); frame_pack(&f, pk);
        if (memcmp(pk, lastpk, sizeof(pk)) != 0) { avr_write_frame(pk, 0); memcpy(lastpk, pk, sizeof(pk)); }
    }
}
