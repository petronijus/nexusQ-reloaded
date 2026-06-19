/* userspace/nexusqd/src/nexusqd.c */
#define _POSIX_C_SOURCE 200809L   /* clock_gettime/CLOCK_MONOTONIC, AF_UNIX, poll under -std=c11 */
#include "frame.h"
#include "avr.h"
#include "compositor.h"
#include "keys.h"
#include "control.h"
#include "themes.h"
#include "reaction.h"
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

/* --- idle layer (priority 0): the dim default ring color #000F14 ----------- */
struct idle_ctx { int rgb[3]; };
static int idle_render(void *c, double t, struct frame *out) {
    (void)t; struct idle_ctx *ic = c;
    frame_fill(out, ic->rgb[0], ic->rgb[1], ic->rgb[2]); return 0;
}

/* --- reaction layer (priority 10): the volume overlay (Plan 2b) ------------ */
static int reaction_layer_render(void *c, double t, struct frame *out) {
    struct reaction *rx = c;
    if (!reaction_overlay_active(rx, t)) return -1;   /* no overlay -> fall through to idle */
    reaction_render(rx, t, out);
    return 0;
}

static double now_s(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec/1e9; }

/* apply the dedicated mute LED for the current muted state (#001E28 / #006B8E) */
static void apply_mute_led(int muted) {
    int r, g, b; reaction_mute_led(muted, &r, &g, &b); avr_set_mute(r, g, b);
}

int main(void) {
    struct idle_ctx idle;
    reaction_default_color(&idle.rgb[0], &idle.rgb[1], &idle.rgb[2]);   /* #000F14 */
    struct reaction rx = {0};
    int volume = 50;            /* virtual master volume (no audio path yet) */
    int muted = 0;

    struct compositor comp = {0};
    comp_add(&comp, (struct layer){ idle_render, &idle, 0, 1 });
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
        struct pollfd pfds[2]; int np = 0;
        if (kfd >= 0) { pfds[np].fd = kfd; pfds[np].events = POLLIN; np++; }
        pfds[np].fd = srv; pfds[np].events = POLLIN; int srvi = np; np++;
        /* tick at 16 ms (= the original frame time) while the fade-in plays */
        int to = reaction_overlay_active(&rx, now_s()) ? 16 : 50;
        poll(pfds, np, to);

        if (kfd >= 0 && (pfds[0].revents & POLLIN)) {
            uint8_t b[INPUT_EVENT_SIZE*64]; int r = (int)read(kfd, b, sizeof(b));
            struct keyev ev[64]; int n = r > 0 ? keys_decode(b, r, ev, 64) : 0;
            for (int i = 0; i < n; i++) {
                if (!ev[i].down) continue;
                if (ev[i].code == KEY_MUTE) {
                    muted = !muted; apply_mute_led(muted);
                } else if (ev[i].code == KEY_VOLUMEUP || ev[i].code == KEY_VOLUMEDOWN) {
                    volume += (ev[i].code == KEY_VOLUMEUP) ? VOL_STEP : -VOL_STEP;
                    if (volume > 100) volume = 100;
                    if (volume < 0) volume = 0;
                    reaction_on_volume(&rx, volume, now_s());
                    avr_set_mute(0, 0, 0);          /* mute LED off during the volume overlay */
                }
            }
        }
        if (pfds[srvi].revents & POLLIN) {
            int c = accept(srv, NULL, NULL);
            if (c >= 0) {
                char line[128] = {0}; int r = (int)read(c, line, sizeof(line)-1);
                struct ctl_cmd cmd;
                if (r > 0 && ctl_parse(line, &cmd) == 0) {
                    if (cmd.kind == CTL_SET) memcpy(idle.rgb, cmd.rgb, sizeof(idle.rgb));
                    else if (cmd.kind == CTL_OFF) { idle.rgb[0]=idle.rgb[1]=idle.rgb[2]=0; }
                    else if (cmd.kind == CTL_MUTE) avr_set_mute(cmd.rgb[0],cmd.rgb[1],cmd.rgb[2]);
                    else if (cmd.kind == CTL_MTOGGLE) { muted = !muted; apply_mute_led(muted); }
                    else if (cmd.kind == CTL_VOL) {
                        volume = cmd.value;
                        reaction_on_volume(&rx, volume, now_s());
                        avr_set_mute(0, 0, 0);
                    }
                    else if (cmd.kind == CTL_THEME) {
                        char path[256]; snprintf(path, sizeof(path), "%s/theme_%s", THEMES_DIR, cmd.name);
                        FILE *fp = fopen(path, "r");
                        if (fp) { char js[1024]; int m=(int)fread(js,1,sizeof(js)-1,fp); js[m]=0; fclose(fp);
                                  struct theme t; if (theme_parse(&t,cmd.name,js)==0 && t.n_colors>0) memcpy(idle.rgb,t.colors[0],3); }
                    }
                    if (write(c, "ok\n", 3) < 0) { /* client gone */ }
                } else { if (write(c, "err\n", 4) < 0) { /* client gone */ } }
                close(c);
            }
        }

        double now = now_s();
        int cur_overlay = reaction_overlay_active(&rx, now);
        if (prev_overlay && !cur_overlay) apply_mute_led(muted);  /* overlay timed out -> restore mute LED */
        prev_overlay = cur_overlay;

        struct frame f; comp_render(&comp, now, &f); frame_pack(&f, pk);
        if (memcmp(pk, lastpk, sizeof(pk)) != 0) { avr_write_frame(pk, 0); memcpy(lastpk, pk, sizeof(pk)); }
    }
}
