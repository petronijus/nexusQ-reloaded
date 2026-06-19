# nexusqd Daemon — Implementation Plan (Plan 2 of 3) — C / postmarketOS aport

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A C daemon `nexusqd` that owns the Nexus Q LED ring via the
`leds-steelhead-avr` kernel driver and gives it living behavior — idle glow,
theme palettes, manual control (a `nexusled` CLI + a control socket), and the
plumbing for key-driven reactions — packaged the proper postmarketOS way as a
musl **aport** with a systemd unit.

**Architecture:** Plain C11, no external libraries (musl + the device's stdlib
only). Pure modules (`frame`, `themes`, `keys`, `control`) are unit-tested on
the host (gcc); I/O modules (`avr`, `compositor` wiring, the daemon loop) are
verified on the device. A priority **compositor** renders one 32-RGB frame and
writes it to the kernel **frame channel**. Built for the device by **pmbootstrap**
via a real aport (`pmos/nexusqd/APKBUILD`), not ad-hoc scp.

**Tech Stack:** C11; POSIX (`poll`, AF_UNIX sockets, `fcntl`); a tiny hand-rolled
JSON reader for the fixed theme shape (no JSON lib dependency); a minimal
assert-based host test runner; systemd; postmarketOS/Alpine aport (abuild).

## Global Constraints

- Language **C11, no third-party libs** — musl/Alpine target; the daemon must build with `$(CC)` against musl and link only libc. (Rationale: consistency with the kernel driver, shared structure with the Plan-3 visualizer hot-loop, and proper platform packaging — chosen over Python deliberately; do NOT reintroduce a scripting shortcut.)
- LED output is the Plan-1 kernel driver sysfs ONLY: write 96 bytes (32×RGB, ring index 0..31, R,G,B order) to `…/1-0020/frame`; `…/commit_mode` = `0` immediate / `1` interpolate; `…/mute` = `"R G B"`. Never touch `/dev/i2c` (the driver owns it).
- Ring = **32 LEDs**; mute LED is separate (driver `mute` attr).
- Keys via evdev: `KEY_MUTE`=113, `KEY_VOLUMEUP`=115, `KEY_VOLUMEDOWN`=114, on the input device named `steelhead-avr-keys`. input_event on this 32-bit ARM kernel is 16 bytes: `struct { long sec; long usec; u16 type; u16 code; s32 value; }` (`EV_KEY`=1).
- **Theme palettes are Google-proprietary** (in gitignored `private/nexusq-original/themes/`): NOT committed. The daemon loads them from `/etc/nexusqd/themes/` at runtime; the aport's deploy installs them from the private overlay (mirrors the firmware-blob pattern). The repo ships only a non-proprietary `default.json`.
- Idle/default color: subdued blue **`0x00385c`** (the original `lights.c` fallback) — until the RE doc refines it.
- Device for on-device tests: `root@192.168.20.179` (key installed; password `147147`).
- Packaging: a postmarketOS aport at `pmos/nexusqd/`, built by pmbootstrap for armv7/musl (same pipeline as the kernel/firmware aports).

## Scope of THIS plan vs follow-ons

THIS plan delivers the **daemon framework + idle glow + theme/manual control +
CLI + aport + key event plumbing** — a working, shippable increment (ring shows
idle, CLI/socket changes it, themes load, the daemon receives the mute/volume
keys and exposes them to a pluggable "reaction" layer interface). It is fully
concrete; no behavior is faked.

Deferred to **Plan 2b** (after the in-flight volume/mute reverse-engineering,
`docs/2026-06-19-volume-mute-RE.md`): the **pixel-perfect** volume-ring + mute
rendering, implemented as a compositor layer against the documented exact
algorithm (no baseline/approximation). Deferred to **Plan 3**: the music
visualizer (audio tap + FFT + ported shaders), the performance hot-loop.

## File Structure

Repo `userspace/nexusqd/`:
- `include/frame.h`, `src/frame.c` — `struct frame { uint8_t px[32][3]; }`; `frame_fill/set/set_range/blend/pack`. Pure.
- `include/themes.h`, `src/themes.c` — parse the theme JSON shape into `struct theme { char name[32]; uint8_t colors[16][3]; int n_colors; int led; int mode; }`. Pure (tiny reader, no lib).
- `include/avr.h`, `src/avr.c` — `avr_open/avr_write_frame/avr_set_mute/avr_set_commit`. Thin sysfs I/O.
- `include/compositor.h`, `src/compositor.c` — priority layer stack → one frame.
- `include/keys.h`, `src/keys.c` — `keys_decode` (buffer → events), `keys_find_node`. Pure decode + sysfs scan.
- `include/control.h`, `src/control.c` — `ctl_parse` (line → command struct). Pure.
- `src/nexusqd.c` — daemon main: poll loop wiring avr+compositor+keys+control, idle layer, a `reaction` layer hook (the seam Plan 2b fills).
- `src/nexusled.c` — CLI.
- `tests/test.h` — minimal `CHECK`/`RUN` macros; `tests/test_*.c` — host unit tests.
- `Makefile` — `make` (daemon+cli), `make test` (host tests), `make CC=… CFLAGS=…` for cross.
- `nexusqd.service` — systemd unit.
- `default.json` — non-proprietary fallback theme.

Repo `pmos/nexusqd/`:
- `APKBUILD` — aport that builds the C sources for the target and installs binary + CLI symlink + service + `default.json`; theme palettes staged separately from the private overlay.

---

### Task 1: `frame` — pure 32-RGB model + 96-byte packing (+ host test harness)

**Files:**
- Create: `userspace/nexusqd/include/frame.h`, `userspace/nexusqd/src/frame.c`
- Create: `userspace/nexusqd/tests/test.h`, `userspace/nexusqd/tests/test_frame.c`
- Create: `userspace/nexusqd/Makefile`

**Interfaces:**
- Produces: `#define RING 32`; `struct frame { uint8_t px[RING][3]; };`
  `void frame_black(struct frame*)`, `frame_fill(struct frame*, int r,int g,int b)`,
  `frame_set(struct frame*, int i,int r,int g,int b)`,
  `int frame_set_range(struct frame*, int start,int count,const uint8_t (*rgb)[3])` (returns 0, or -1 if start+count>RING),
  `void frame_blend(struct frame*, const struct frame *other, double alpha)`,
  `void frame_pack(const struct frame*, uint8_t out[RING*3])`. Channels clamped 0..255.

- [ ] **Step 1: Write the test harness + failing test**

```c
/* userspace/nexusqd/tests/test.h */
#ifndef TEST_H
#define TEST_H
#include <stdio.h>
static int _fails;
#define CHECK(cond) do { if (!(cond)) { _fails++; \
    printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define RUN(fn) do { printf("== %s\n", #fn); fn(); } while (0)
#define REPORT() (printf(_fails ? "FAILED (%d)\n" : "OK\n", _fails), _fails ? 1 : 0)
#endif
```

```c
/* userspace/nexusqd/tests/test_frame.c */
#include "test.h"
#include "frame.h"

static void test_pack_len_and_order(void) {
    struct frame f; frame_black(&f); frame_fill(&f, 1, 2, 3);
    uint8_t b[RING*3]; frame_pack(&f, b);
    CHECK(b[0] == 1 && b[1] == 2 && b[2] == 3);
    CHECK(b[RING*3-1] == 3);
}
static void test_set_and_clamp(void) {
    struct frame f; frame_black(&f); frame_set(&f, 5, 999, -5, 256);
    uint8_t b[RING*3]; frame_pack(&f, b);
    CHECK(b[15] == 255 && b[16] == 0 && b[17] == 255);
    CHECK(b[0] == 0);
}
static void test_set_range_bounds(void) {
    struct frame f; frame_black(&f);
    uint8_t rgb[5][3] = {{1,1,1},{1,1,1},{1,1,1},{1,1,1},{1,1,1}};
    CHECK(frame_set_range(&f, 30, 5, rgb) == -1);   /* 30+5 > 32 */
    CHECK(frame_set_range(&f, 0, 2, rgb) == 0);
}
static void test_blend_half(void) {
    struct frame a, b; frame_black(&a); frame_black(&b); frame_fill(&b, 100, 200, 0);
    frame_blend(&a, &b, 0.5);
    uint8_t o[RING*3]; frame_pack(&a, o);
    CHECK(o[0] == 50 && o[1] == 100 && o[2] == 0);
}
int main(void) {
    RUN(test_pack_len_and_order); RUN(test_set_and_clamp);
    RUN(test_set_range_bounds); RUN(test_blend_half);
    return REPORT();
}
```

```make
# userspace/nexusqd/Makefile
CC      ?= cc
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -Iinclude
SRC      = src/frame.c src/themes.c src/avr.c src/compositor.c src/keys.c src/control.c
DAEMON   = src/nexusqd.c $(SRC)
CLI      = src/nexusled.c src/avr.c src/frame.c
TESTS    = $(wildcard tests/test_*.c)

all: nexusqd nexusled
nexusqd: $(DAEMON); $(CC) $(CFLAGS) -o $@ $(DAEMON)
nexusled: $(CLI); $(CC) $(CFLAGS) -o $@ $(CLI)

test: $(patsubst tests/test_%.c,build/test_%,$(TESTS))
	@fail=0; for t in $^; do echo "### $$t"; ./$$t || fail=1; done; exit $$fail
build/test_%: tests/test_%.c $(SRC) | build
	$(CC) $(CFLAGS) -Itests -o $@ $< $(SRC)
build:; mkdir -p build
clean:; rm -rf build nexusqd nexusled
.PHONY: all test clean
```

- [ ] **Step 2: Run the test, verify it fails to build**

Run: `cd userspace/nexusqd && make test`
Expected: compile error — `frame.h` / `frame.c` missing.

- [ ] **Step 3: Implement `frame.h` + `frame.c`**

```c
/* userspace/nexusqd/include/frame.h */
#ifndef NEXUSQD_FRAME_H
#define NEXUSQD_FRAME_H
#include <stdint.h>
#define RING 32
struct frame { uint8_t px[RING][3]; };
void frame_black(struct frame *f);
void frame_fill(struct frame *f, int r, int g, int b);
void frame_set(struct frame *f, int i, int r, int g, int b);
int  frame_set_range(struct frame *f, int start, int count, const uint8_t (*rgb)[3]);
void frame_blend(struct frame *f, const struct frame *other, double alpha);
void frame_pack(const struct frame *f, uint8_t out[RING*3]);
#endif
```

```c
/* userspace/nexusqd/src/frame.c */
#include "frame.h"
static uint8_t clamp(int v) { return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v; }
void frame_black(struct frame *f) {
    for (int i = 0; i < RING; i++) f->px[i][0] = f->px[i][1] = f->px[i][2] = 0;
}
void frame_fill(struct frame *f, int r, int g, int b) {
    for (int i = 0; i < RING; i++) {
        f->px[i][0] = clamp(r); f->px[i][1] = clamp(g); f->px[i][2] = clamp(b);
    }
}
void frame_set(struct frame *f, int i, int r, int g, int b) {
    if (i < 0 || i >= RING) return;
    f->px[i][0] = clamp(r); f->px[i][1] = clamp(g); f->px[i][2] = clamp(b);
}
int frame_set_range(struct frame *f, int start, int count, const uint8_t (*rgb)[3]) {
    if (start < 0 || count < 0 || start + count > RING) return -1;
    for (int k = 0; k < count; k++)
        for (int c = 0; c < 3; c++) f->px[start+k][c] = rgb[k][c];
    return 0;
}
void frame_blend(struct frame *f, const struct frame *o, double a) {
    if (a < 0) a = 0; if (a > 1) a = 1;
    for (int i = 0; i < RING; i++)
        for (int c = 0; c < 3; c++)
            f->px[i][c] = clamp((int)(f->px[i][c] + (o->px[i][c] - f->px[i][c]) * a));
}
void frame_pack(const struct frame *f, uint8_t out[RING*3]) {
    for (int i = 0; i < RING; i++)
        for (int c = 0; c < 3; c++) out[i*3+c] = f->px[i][c];
}
```

- [ ] **Step 4: Run the test, verify pass**

Run (host gcc; use WSL if on Windows): `cd userspace/nexusqd && make test`
Expected: `### build/test_frame` … `OK`, overall exit 0.

- [ ] **Step 5: Commit**

```bash
git add userspace/nexusqd/include/frame.h userspace/nexusqd/src/frame.c \
        userspace/nexusqd/tests/test.h userspace/nexusqd/tests/test_frame.c userspace/nexusqd/Makefile
git commit -m "nexusqd: pure frame model + 96-byte packing + host test harness"
```

---

### Task 2: `themes` — parse theme JSON (no JSON lib)

**Files:**
- Create: `userspace/nexusqd/include/themes.h`, `userspace/nexusqd/src/themes.c`
- Create: `userspace/nexusqd/default.json`
- Create: `userspace/nexusqd/tests/test_themes.c`

**Interfaces:**
- Produces: `struct theme { char name[32]; uint8_t colors[16][3]; int n_colors; int led; int mode; };`
  `int theme_parse(struct theme *out, const char *name, const char *json)` (returns 0 ok / -1 malformed; reads the `options.colors[]` `#RRGGBB` array (≤16), `options.led`, `metaOption.mode`).

- [ ] **Step 1: Write failing test**

```c
/* userspace/nexusqd/tests/test_themes.c */
#include "test.h"
#include "themes.h"
static const char *SPEC =
  "{\"engine\":{},\"options\":{\"display\":1,\"led\":1,"
  "\"colors\":[\"#AA66CC\",\"#FF4444\",\"#0099cc\"]},\"metaOption\":{\"mode\":1}}";
static const char *OFF =
  "{\"options\":{\"display\":0,\"led\":0,\"colors\":[\"#000000\"]},\"metaOption\":{\"mode\":1}}";
static void test_parse(void) {
    struct theme t;
    CHECK(theme_parse(&t, "spectrum", SPEC) == 0);
    CHECK(t.n_colors == 3);
    CHECK(t.colors[0][0]==0xAA && t.colors[0][1]==0x66 && t.colors[0][2]==0xCC);
    CHECK(t.colors[2][2]==0xcc);
    CHECK(t.led == 1 && t.mode == 1);
}
static void test_off(void) {
    struct theme t;
    CHECK(theme_parse(&t, "off", OFF) == 0);
    CHECK(t.led == 0 && t.n_colors == 1 && t.colors[0][0]==0);
}
int main(void){ RUN(test_parse); RUN(test_off); return REPORT(); }
```

- [ ] **Step 2: Run, verify fail** — `cd userspace/nexusqd && make test` → themes.h missing.

- [ ] **Step 3: Implement `themes.h` + `themes.c` + `default.json`**

```c
/* userspace/nexusqd/include/themes.h */
#ifndef NEXUSQD_THEMES_H
#define NEXUSQD_THEMES_H
#include <stdint.h>
struct theme { char name[32]; uint8_t colors[16][3]; int n_colors; int led; int mode; };
int theme_parse(struct theme *out, const char *name, const char *json);
#endif
```

```c
/* userspace/nexusqd/src/themes.c */
#include "themes.h"
#include <string.h>
#include <stdlib.h>

static int hexpair(const char *p) {
    char b[3] = { p[0], p[1], 0 }; return (int)strtol(b, NULL, 16);
}
/* find substring key then the next number after ':' */
static int int_after(const char *json, const char *key, int dflt) {
    const char *k = strstr(json, key);
    if (!k) return dflt;
    const char *c = strchr(k, ':');
    if (!c) return dflt;
    return (int)strtol(c + 1, NULL, 10);
}
int theme_parse(struct theme *out, const char *name, const char *json) {
    memset(out, 0, sizeof(*out));
    snprintf(out->name, sizeof(out->name), "%s", name);
    out->led  = int_after(json, "\"led\"", 1);
    out->mode = int_after(json, "\"mode\"", 1);
    const char *col = strstr(json, "\"colors\"");
    if (!col) return -1;
    const char *lb = strchr(col, '[');
    const char *rb = lb ? strchr(lb, ']') : NULL;
    if (!lb || !rb) return -1;
    int n = 0;
    for (const char *p = lb; p < rb && n < 16; p++) {
        if (*p == '#') {
            if (p + 7 > rb) return -1;
            out->colors[n][0] = (uint8_t)hexpair(p+1);
            out->colors[n][1] = (uint8_t)hexpair(p+3);
            out->colors[n][2] = (uint8_t)hexpair(p+5);
            n++;
        }
    }
    out->n_colors = n;
    return n > 0 ? 0 : -1;
}
```

`default.json`:
```json
{"options":{"display":0,"led":1,"colors":["#00385c"]},"metaOption":{"mode":1}}
```

- [ ] **Step 4: Run, verify pass** — `make test` → test_themes OK.

- [ ] **Step 5: Commit**

```bash
git add userspace/nexusqd/include/themes.h userspace/nexusqd/src/themes.c \
        userspace/nexusqd/default.json userspace/nexusqd/tests/test_themes.c
git commit -m "nexusqd: theme JSON parser (no deps) + default theme"
```

---

### Task 3: `keys` — evdev input_event decode + node discovery

**Files:**
- Create: `userspace/nexusqd/include/keys.h`, `userspace/nexusqd/src/keys.c`
- Create: `userspace/nexusqd/tests/test_keys.c`

**Interfaces:**
- Produces: `#define KEY_MUTE 113`, `KEY_VOLUMEDOWN 114`, `KEY_VOLUMEUP 115`, `EV_KEY 1`, `INPUT_EVENT_SIZE 16`;
  `struct keyev { int code; int down; };`
  `int keys_decode(const uint8_t *buf, int len, struct keyev *out, int max)` (returns count; only EV_KEY with value 0/1; down = value==1);
  `int keys_find_node(char *path, int pathlen)` (scans `/sys/class/input/event*/device/name` for `steelhead-avr-keys`; writes `/dev/input/eventN`; returns 0/-1).

- [ ] **Step 1: Write failing test**

```c
/* userspace/nexusqd/tests/test_keys.c */
#include "test.h"
#include "keys.h"
#include <string.h>
static void put(uint8_t *b, int type, int code, int value) {
    long s = 1, u = 2; memcpy(b, &s, sizeof(long)); memcpy(b+sizeof(long), &u, sizeof(long));
    uint16_t t = type, c = code; int32_t v = value;
    memcpy(b+2*sizeof(long), &t, 2); memcpy(b+2*sizeof(long)+2, &c, 2);
    memcpy(b+2*sizeof(long)+4, &v, 4);
}
static void test_decode(void) {
    uint8_t buf[INPUT_EVENT_SIZE*3];
    put(buf, EV_KEY, KEY_MUTE, 1); put(buf+16, EV_KEY, KEY_MUTE, 0);
    put(buf+32, EV_KEY, KEY_VOLUMEUP, 2);   /* autorepeat -> ignored */
    struct keyev ev[8];
    int n = keys_decode(buf, sizeof(buf), ev, 8);
    CHECK(n == 2);
    CHECK(ev[0].code == KEY_MUTE && ev[0].down == 1);
    CHECK(ev[1].code == KEY_MUTE && ev[1].down == 0);
}
int main(void){ RUN(test_decode); return REPORT(); }
```
(Note: this test assumes the host `sizeof(long)` matches the record layout it writes — it builds the buffer with the same `long` size it decodes, so it is self-consistent on any host. On the 32-bit ARM target `sizeof(long)`=4 → 16-byte records, which the daemon reads natively.)

- [ ] **Step 2: Run, verify fail** — `make test` → keys.h missing.

- [ ] **Step 3: Implement `keys.h` + `keys.c`**

```c
/* userspace/nexusqd/include/keys.h */
#ifndef NEXUSQD_KEYS_H
#define NEXUSQD_KEYS_H
#include <stdint.h>
#define KEY_MUTE 113
#define KEY_VOLUMEDOWN 114
#define KEY_VOLUMEUP 115
#define EV_KEY 1
#define INPUT_EVENT_SIZE ((int)(2*sizeof(long) + 8))
struct keyev { int code; int down; };
int keys_decode(const uint8_t *buf, int len, struct keyev *out, int max);
int keys_find_node(char *path, int pathlen);
#endif
```

```c
/* userspace/nexusqd/src/keys.c */
#include "keys.h"
#include <string.h>
#include <stdio.h>
#include <glob.h>

int keys_decode(const uint8_t *buf, int len, struct keyev *out, int max) {
    int n = 0;
    const int rec = INPUT_EVENT_SIZE, off_t_ = 2*(int)sizeof(long);
    for (int o = 0; o + rec <= len && n < max; o += rec) {
        uint16_t type, code; int32_t value;
        memcpy(&type, buf+o+off_t_, 2);
        memcpy(&code, buf+o+off_t_+2, 2);
        memcpy(&value, buf+o+off_t_+4, 4);
        if (type == EV_KEY && (value == 0 || value == 1)) {
            out[n].code = code; out[n].down = (value == 1); n++;
        }
    }
    return n;
}
int keys_find_node(char *path, int pathlen) {
    glob_t g;
    if (glob("/sys/class/input/event*/device/name", 0, NULL, &g) != 0) return -1;
    int rc = -1;
    for (size_t i = 0; i < g.gl_pathc; i++) {
        FILE *fp = fopen(g.gl_pathv[i], "r");
        if (!fp) continue;
        char nm[64] = {0}; fgets(nm, sizeof(nm), fp); fclose(fp);
        char *nl = strchr(nm, '\n'); if (nl) *nl = 0;
        if (strcmp(nm, "steelhead-avr-keys") == 0) {
            /* /sys/class/input/eventN/device/name -> eventN is field [4] */
            char *p = g.gl_pathv[i] + strlen("/sys/class/input/");
            char *slash = strchr(p, '/'); if (slash) *slash = 0;
            snprintf(path, pathlen, "/dev/input/%s", p);
            rc = 0; break;
        }
    }
    globfree(&g);
    return rc;
}
```

- [ ] **Step 4: Run, verify pass** — `make test` → test_keys OK.

- [ ] **Step 5: Commit**

```bash
git add userspace/nexusqd/include/keys.h userspace/nexusqd/src/keys.c userspace/nexusqd/tests/test_keys.c
git commit -m "nexusqd: evdev input_event decode + node discovery"
```

---

### Task 4: `control` — command parser

**Files:**
- Create: `userspace/nexusqd/include/control.h`, `userspace/nexusqd/src/control.c`
- Create: `userspace/nexusqd/tests/test_control.c`

**Interfaces:**
- Produces: `enum ctl_kind { CTL_THEME, CTL_SET, CTL_MUTE, CTL_OFF, CTL_STATUS };`
  `struct ctl_cmd { enum ctl_kind kind; char name[32]; int rgb[3]; };`
  `int ctl_parse(const char *line, struct ctl_cmd *out)` (returns 0 ok / -1 malformed). Grammar: `theme <name>` | `set R G B` | `mute R G B` | `off` | `status` (rgb 0..255).

- [ ] **Step 1: Write failing test**

```c
/* userspace/nexusqd/tests/test_control.c */
#include "test.h"
#include "control.h"
#include <string.h>
static void test_ok(void) {
    struct ctl_cmd c;
    CHECK(ctl_parse("theme spectrum", &c) == 0 && c.kind == CTL_THEME && !strcmp(c.name,"spectrum"));
    CHECK(ctl_parse("set 255 0 128", &c) == 0 && c.kind == CTL_SET && c.rgb[0]==255 && c.rgb[2]==128);
    CHECK(ctl_parse("mute 0 64 0", &c) == 0 && c.kind == CTL_MUTE && c.rgb[1]==64);
    CHECK(ctl_parse("off", &c) == 0 && c.kind == CTL_OFF);
    CHECK(ctl_parse("status", &c) == 0 && c.kind == CTL_STATUS);
}
static void test_bad(void) {
    struct ctl_cmd c;
    const char *bad[] = {"", "set 1 2", "set 1 2 999", "theme", "bogus", NULL};
    for (int i = 0; bad[i]; i++) CHECK(ctl_parse(bad[i], &c) == -1);
}
int main(void){ RUN(test_ok); RUN(test_bad); return REPORT(); }
```

- [ ] **Step 2: Run, verify fail** — `make test` → control.h missing.

- [ ] **Step 3: Implement `control.h` + `control.c`**

```c
/* userspace/nexusqd/include/control.h */
#ifndef NEXUSQD_CONTROL_H
#define NEXUSQD_CONTROL_H
enum ctl_kind { CTL_THEME, CTL_SET, CTL_MUTE, CTL_OFF, CTL_STATUS };
struct ctl_cmd { enum ctl_kind kind; char name[32]; int rgb[3]; };
int ctl_parse(const char *line, struct ctl_cmd *out);
#endif
```

```c
/* userspace/nexusqd/src/control.c */
#include "control.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
static int rgb3(const char *a, const char *b, const char *c, int out[3]) {
    char *e;
    long v[3]; const char *s[3] = { a, b, c };
    for (int i = 0; i < 3; i++) {
        if (!s[i]) return -1;
        v[i] = strtol(s[i], &e, 10);
        if (*e != 0 || v[i] < 0 || v[i] > 255) return -1;
        out[i] = (int)v[i];
    }
    return 0;
}
int ctl_parse(const char *line, struct ctl_cmd *out) {
    char buf[128]; snprintf(buf, sizeof(buf), "%s", line);
    char *tok[5] = {0}; int n = 0;
    for (char *p = strtok(buf, " \t\r\n"); p && n < 5; p = strtok(NULL, " \t\r\n")) tok[n++] = p;
    if (n == 0) return -1;
    if (!strcmp(tok[0], "theme") && n == 2) {
        out->kind = CTL_THEME; snprintf(out->name, sizeof(out->name), "%s", tok[1]); return 0;
    }
    if (!strcmp(tok[0], "set") && n == 4)  { out->kind = CTL_SET;  return rgb3(tok[1],tok[2],tok[3], out->rgb); }
    if (!strcmp(tok[0], "mute") && n == 4) { out->kind = CTL_MUTE; return rgb3(tok[1],tok[2],tok[3], out->rgb); }
    if (!strcmp(tok[0], "off") && n == 1)    { out->kind = CTL_OFF; return 0; }
    if (!strcmp(tok[0], "status") && n == 1) { out->kind = CTL_STATUS; return 0; }
    return -1;
}
```

- [ ] **Step 4: Run, verify pass** — `make test` → test_control OK (all four test files now pass).

- [ ] **Step 5: Commit**

```bash
git add userspace/nexusqd/include/control.h userspace/nexusqd/src/control.c userspace/nexusqd/tests/test_control.c
git commit -m "nexusqd: control command parser"
```

---

### Task 5: `avr` + `compositor` — sysfs output + priority layers

**Files:**
- Create: `userspace/nexusqd/include/avr.h`, `userspace/nexusqd/src/avr.c`
- Create: `userspace/nexusqd/include/compositor.h`, `userspace/nexusqd/src/compositor.c`
- Test: on-device for `avr`; `compositor` is exercised via the daemon (Task 6). (Both are thin; the pure picking logic of the compositor is trivial and covered by the daemon smoke test.)

**Interfaces:**
- Produces:
  `avr.h`: `#define AVR_SYSFS "/sys/bus/i2c/devices/1-0020"`; `int avr_write_frame(const uint8_t pk[RING*3], int commit)`; `int avr_set_mute(int r,int g,int b)`. (Open/write/close each call; returns 0/-1.)
  `compositor.h`: `struct layer { int (*render)(void *ctx, double t, struct frame *out); void *ctx; int priority; int active; };` `struct compositor { struct layer layers[8]; int n; };` `void comp_add(struct compositor*, struct layer)`; `void comp_render(struct compositor*, double t, struct frame *out)` (highest-priority active layer whose render returns 0 wins; else black).

- [ ] **Step 1: Implement `avr.c`**

```c
/* userspace/nexusqd/include/avr.h */
#ifndef NEXUSQD_AVR_H
#define NEXUSQD_AVR_H
#include "frame.h"
#define AVR_SYSFS "/sys/bus/i2c/devices/1-0020"
int avr_write_frame(const uint8_t pk[RING*3], int commit);
int avr_set_mute(int r, int g, int b);
#endif
```

```c
/* userspace/nexusqd/src/avr.c */
#include "avr.h"
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
static int write_file(const char *path, const void *buf, int len) {
    int fd = open(path, O_WRONLY); if (fd < 0) return -1;
    int w = (int)write(fd, buf, len); close(fd);
    return w == len ? 0 : -1;
}
int avr_write_frame(const uint8_t pk[RING*3], int commit) {
    char m[2] = { commit ? '1' : '0', 0 };
    write_file(AVR_SYSFS "/commit_mode", m, 1);
    return write_file(AVR_SYSFS "/frame", pk, RING*3);
}
int avr_set_mute(int r, int g, int b) {
    char s[16]; int n = snprintf(s, sizeof(s), "%d %d %d", r, g, b);
    return write_file(AVR_SYSFS "/mute", s, n);
}
```

- [ ] **Step 2: Implement `compositor.c`**

```c
/* userspace/nexusqd/include/compositor.h */
#ifndef NEXUSQD_COMPOSITOR_H
#define NEXUSQD_COMPOSITOR_H
#include "frame.h"
struct layer { int (*render)(void *ctx, double t, struct frame *out); void *ctx; int priority; int active; };
struct compositor { struct layer layers[8]; int n; };
void comp_add(struct compositor *c, struct layer l);
void comp_render(struct compositor *c, double t, struct frame *out);
#endif
```

```c
/* userspace/nexusqd/src/compositor.c */
#include "compositor.h"
void comp_add(struct compositor *c, struct layer l) {
    if (c->n < 8) c->layers[c->n++] = l;
}
void comp_render(struct compositor *c, double t, struct frame *out) {
    int best = -1, bestpri = -1;
    for (int i = 0; i < c->n; i++)
        if (c->layers[i].active && c->layers[i].priority > bestpri) { best = i; bestpri = c->layers[i].priority; }
    /* try from highest priority downward until one renders */
    while (best >= 0) {
        struct frame tmp;
        if (c->layers[best].active && c->layers[best].render(c->layers[best].ctx, t, &tmp) == 0) { *out = tmp; return; }
        /* find next lower active */
        int nb = -1, npri = -1;
        for (int i = 0; i < c->n; i++)
            if (c->layers[i].active && c->layers[i].priority < bestpri && c->layers[i].priority > npri) { nb = i; npri = c->layers[i].priority; }
        best = nb; bestpri = npri;
    }
    frame_black(out);
}
```

- [ ] **Step 3: Build for host (compile sanity)** — `cd userspace/nexusqd && make test` (still green; avr/compositor compile into the test link). Expected: all tests OK, no warnings.

- [ ] **Step 4: Commit**

```bash
git add userspace/nexusqd/include/avr.h userspace/nexusqd/src/avr.c \
        userspace/nexusqd/include/compositor.h userspace/nexusqd/src/compositor.c
git commit -m "nexusqd: sysfs frame output + priority compositor"
```

---

### Task 6: `nexusqd.c` daemon — idle layer, control socket, key plumbing (on-device)

**Files:**
- Create: `userspace/nexusqd/src/nexusqd.c`

**Interfaces:**
- Consumes: all modules above.
- Produces: a daemon that builds a compositor with an idle `SolidLayer(0x00,0x38,0x5c)` at priority 0 and a **reaction layer hook** at priority 10 (a function pointer + ctx the Plan-2b volume/mute layer will fill — for now a layer with `active=0`); reads the evdev node via `poll`; on mute key toggles the mute LED; on volume keys logs + forwards to the reaction hook; serves `/run/nexusqd.sock`. Idle color and mute color settable via control.

- [ ] **Step 1: Implement `nexusqd.c`**

```c
/* userspace/nexusqd/src/nexusqd.c */
#include "frame.h"
#include "avr.h"
#include "compositor.h"
#include "keys.h"
#include "control.h"
#include "themes.h"
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

struct idle_ctx { int rgb[3]; };
static int idle_render(void *c, double t, struct frame *out) {
    (void)t; struct idle_ctx *ic = c; frame_black(out); frame_fill(out, ic->rgb[0], ic->rgb[1], ic->rgb[2]); return 0;
}

static double now_s(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec/1e9; }

int main(void) {
    struct idle_ctx idle = { { 0x00, 0x38, 0x5c } };
    struct compositor comp = {0};
    comp_add(&comp, (struct layer){ idle_render, &idle, 0, 1 });
    /* reaction layer (Plan 2b fills render/ctx); inactive for now */
    comp_add(&comp, (struct layer){ NULL, NULL, 10, 0 });

    int muted = 0;
    avr_set_mute(0, 0, 0);

    char node[64]; int kfd = -1;
    if (keys_find_node(node, sizeof(node)) == 0) kfd = open(node, O_RDONLY | O_NONBLOCK);

    unlink(SOCK);
    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un sa = { .sun_family = AF_UNIX }; strcpy(sa.sun_path, SOCK);
    bind(srv, (struct sockaddr*)&sa, sizeof(sa)); listen(srv, 4);

    struct frame last; frame_black(&last); uint8_t lastpk[RING*3] = {0}, pk[RING*3];
    for (;;) {
        struct pollfd pfds[2]; int np = 0;
        if (kfd >= 0) { pfds[np].fd = kfd; pfds[np].events = POLLIN; np++; }
        pfds[np].fd = srv; pfds[np].events = POLLIN; int srvi = np; np++;
        poll(pfds, np, 50);

        if (kfd >= 0 && (pfds[0].revents & POLLIN)) {
            uint8_t b[INPUT_EVENT_SIZE*64]; int r = (int)read(kfd, b, sizeof(b));
            struct keyev ev[64]; int n = r > 0 ? keys_decode(b, r, ev, 64) : 0;
            for (int i = 0; i < n; i++) {
                if (!ev[i].down) continue;
                if (ev[i].code == KEY_MUTE) { muted = !muted; avr_set_mute(muted?80:0, 0, 0); }
                /* KEY_VOLUMEUP/DOWN -> reaction hook (Plan 2b) */
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
                    else if (cmd.kind == CTL_THEME) {
                        char path[256]; snprintf(path, sizeof(path), "%s/theme_%s", THEMES_DIR, cmd.name);
                        FILE *fp = fopen(path, "r");
                        if (fp) { char js[1024]; int m=(int)fread(js,1,sizeof(js)-1,fp); js[m]=0; fclose(fp);
                                  struct theme t; if (theme_parse(&t,cmd.name,js)==0 && t.n_colors>0) memcpy(idle.rgb,t.colors[0],3); }
                    }
                    write(c, "ok\n", 3);
                } else write(c, "err\n", 4);
                close(c);
            }
        }
        struct frame f; comp_render(&comp, now_s(), &f); frame_pack(&f, pk);
        if (memcmp(pk, lastpk, sizeof(pk)) != 0) { avr_write_frame(pk, 0); memcpy(lastpk, pk, sizeof(pk)); }
    }
}
```

- [ ] **Step 2: Cross-build via the aport (Task 8) OR a quick on-device build check**

Since the device has no compiler, build with the cross toolchain or the aport. For a quick smoke before the aport exists, cross-compile statically-ish with the ARM toolchain and run on device:
Run: `cd userspace/nexusqd && make CC=/home/petronijus/nexusq-build/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-gcc CFLAGS="-std=c11 -O2 -Iinclude -static"` (in WSL).
Expected: `nexusqd` + `nexusled` ELF ARM binaries. (`-static` sidesteps the glibc-toolchain-vs-musl mismatch for a smoke test; the real build is the musl aport in Task 8.)

- [ ] **Step 3: On-device smoke test**

```bash
scp userspace/nexusqd/nexusqd root@192.168.20.179:/tmp/
ssh root@192.168.20.179 '(/tmp/nexusqd &) ; sleep 2;
  printf "set 255 0 0" | (exec 3<>/dev/unix? ) ' # use a tiny client:
ssh root@192.168.20.179 'python3 - <<EOF
import socket,time
for cmd in [b"set 0 255 0", b"off", b"set 0 0 80"]:
    s=socket.socket(socket.AF_UNIX); s.connect("/run/nexusqd.sock"); s.sendall(cmd); print(cmd, s.recv(16)); s.close(); time.sleep(1)
EOF'
```
Expected: ring shows idle blue on start; `set 0 255 0` → green; `off` → off; mute key toggles the mute LED. (Visual confirmation.)

- [ ] **Step 4: Commit**

```bash
git add userspace/nexusqd/src/nexusqd.c
git commit -m "nexusqd: daemon — idle layer, control socket, mute key, reaction hook"
```

---

### Task 7: `nexusled` CLI + systemd unit

**Files:**
- Create: `userspace/nexusqd/src/nexusled.c`
- Create: `userspace/nexusqd/nexusqd.service`

**Interfaces:**
- Produces: `nexusled set R G B | theme NAME | off | mute R G B | all R G B` — connects to `/run/nexusqd.sock`; if connect fails, falls back to writing the kernel sysfs directly via `avr_write_frame`.

- [ ] **Step 1: Implement `nexusled.c`**

```c
/* userspace/nexusqd/src/nexusled.c */
#include "avr.h"
#include "frame.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define SOCK "/run/nexusqd.sock"

static int send_sock(const char *line) {
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un sa = { .sun_family = AF_UNIX }; strcpy(sa.sun_path, SOCK);
    if (connect(s, (struct sockaddr*)&sa, sizeof(sa)) != 0) { close(s); return -1; }
    write(s, line, strlen(line));
    char r[64]; int n = (int)read(s, r, sizeof(r)-1); if (n > 0) { r[n]=0; fputs(r, stdout); }
    close(s); return 0;
}
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: nexusled set R G B | theme NAME | off | mute R G B | all R G B\n"); return 2; }
    char line[128] = {0};
    const char *verb = strcmp(argv[1], "all") == 0 ? "set" : argv[1];
    int p = snprintf(line, sizeof(line), "%s", verb);
    for (int i = 2; i < argc; i++) p += snprintf(line+p, sizeof(line)-p, " %s", argv[i]);
    if (send_sock(line) == 0) return 0;
    /* fallback: direct sysfs for set/all/off */
    struct frame f; frame_black(&f);
    if ((!strcmp(verb,"set")) && argc == 5) frame_fill(&f, atoi(argv[2]), atoi(argv[3]), atoi(argv[4]));
    uint8_t pk[RING*3]; frame_pack(&f, pk); avr_write_frame(pk, 0);
    printf("ok (direct)\n"); return 0;
}
```

- [ ] **Step 2: systemd unit**

```ini
# userspace/nexusqd/nexusqd.service
[Unit]
Description=Nexus Q LED ring daemon
After=multi-user.target
Requires=systemd-modules-load.service

[Service]
ExecStart=/usr/bin/nexusqd
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Build + on-device test**

Run (WSL cross, static smoke): `cd userspace/nexusqd && make CC=…arm-none-linux-gnueabihf-gcc CFLAGS="-std=c11 -O2 -Iinclude -static" nexusled`
```bash
scp userspace/nexusqd/nexusled root@192.168.20.179:/usr/local/bin/
ssh root@192.168.20.179 'nexusled set 0 0 255; sleep 1; nexusled off'
```
Expected: with daemon running → socket path; without → "ok (direct)" and the ring changes.

- [ ] **Step 4: Commit**

```bash
git add userspace/nexusqd/src/nexusled.c userspace/nexusqd/nexusqd.service
git commit -m "nexusqd: nexusled CLI + systemd unit"
```

---

### Task 8: postmarketOS aport — proper musl build + install

**Files:**
- Create: `pmos/nexusqd/APKBUILD`
- Modify: `docker-build.sh` (stage the aport into pmaports, like the kernel/device aports) — add a copy step mirroring the existing ones.

**Interfaces:**
- Produces: an apk built by pmbootstrap for armv7/musl that installs `/usr/bin/nexusqd`, `/usr/bin/nexusled`, the systemd unit, and `/etc/nexusqd/themes/default.json`.

- [ ] **Step 1: Write `APKBUILD`**

```sh
# pmos/nexusqd/APKBUILD
# Maintainer: nexusQ-reloaded
pkgname=nexusqd
pkgver=0.1.0
pkgrel=0
pkgdesc="Nexus Q LED ring daemon (steelhead-avr)"
url="https://github.com/petronijus/nexusQ-reloaded"
arch="armv7"
license="GPL-2.0-only"
options="!check"   # tests run on host CI, not in the cross build
source="
	frame.c frame.h themes.c themes.h avr.c avr.h compositor.c compositor.h
	keys.c keys.h control.c control.h nexusqd.c nexusled.c
	Makefile nexusqd.service default.json
"
builddir="$srcdir"

build() {
	make CC="${CC:-cc}" CFLAGS="-std=c11 -O2 -Wall -Iinclude"
}

package() {
	install -Dm755 nexusqd "$pkgdir"/usr/bin/nexusqd
	install -Dm755 nexusled "$pkgdir"/usr/bin/nexusled
	install -Dm644 nexusqd.service "$pkgdir"/usr/lib/systemd/system/nexusqd.service
	install -Dm644 default.json "$pkgdir"/etc/nexusqd/themes/default.json
}
sha512sums="SKIP"
```
(Note: the `source=` files are flat; the build step's `make` expects `include/` and `src/` — adjust the Makefile or the APKBUILD `prepare()` to lay the tree out, OR keep the sources flat and point `-Iinclude` accordingly. Simplest: in `prepare()`, `mkdir -p include src && mv *.h include/ && mv *.c src/`. Add that prepare().)

- [ ] **Step 2: Add `prepare()` to lay out the tree**

```sh
prepare() {
	default_prepare
	mkdir -p include src
	cp "$srcdir"/*.h include/ 2>/dev/null || true
	cp "$srcdir"/*.c src/ 2>/dev/null || true
}
```

- [ ] **Step 3: Stage + build via pmbootstrap (Docker pipeline or local pmbootstrap)**

Add to `docker-build.sh` (near the kernel/device aport staging) a step copying `pmos/nexusqd` → the pmaports tree and the `userspace/nexusqd/{src,include,Makefile,...}` files into the aport srcdir. Then `pmbootstrap build nexusqd --arch armv7` produces the apk.
Expected: a `nexusqd-0.1.0-r0.apk` for armv7/musl.

- [ ] **Step 4: Install on device + verify autostart**

```bash
scp <built>/nexusqd-*.apk root@192.168.20.179:/tmp/
ssh root@192.168.20.179 'apk add --allow-untrusted /tmp/nexusqd-*.apk;
  # install proprietary themes from the private overlay (done from the build host):
  systemctl enable --now nexusqd; sleep 2; systemctl is-active nexusqd; nexusled theme spectrum'
```
Then `scp private/nexusq-original/themes/theme_* root@…:/etc/nexusqd/themes/` (from the build host; not in the apk). Reboot once → `systemctl is-active nexusqd` = active, ring idle blue at boot.
Expected: service active across reboot; CLI controls the ring; musl-linked binary runs natively (no static hack).

- [ ] **Step 5: Commit**

```bash
git add pmos/nexusqd/APKBUILD docker-build.sh
git commit -m "nexusqd: postmarketOS aport (musl build) + pipeline staging"
```

---

## Self-Review

**Spec coverage (daemon framework):** compositor/priority layers (T5) ✅; control API mirroring ILedService — theme/set/mute/off/status (T4+T6) ✅; nexusled CLI mirroring avrlights (T7) ✅; systemd autostart + idle `0x00385c` (T6/T7) ✅; theme palettes loaded from extracted JSON, installed from the private overlay (T2/T8) ✅; evdev key input plumbed with a reaction-layer seam (T3/T6) ✅; output via the Plan-1 frame channel only (T5) ✅; **proper musl aport packaging** (T8) ✅ — no scripting/scp shortcut. C11, no external libs ✅.

**Placeholder scan:** none. The reaction layer is an explicit, inactive seam (a real function-pointer interface), not a fake behavior — its implementation is Plan 2b, which depends on the in-flight RE doc. The volume/mute *behavior* is intentionally NOT faked here (no baseline) per the no-shortcuts rule.

**Type consistency:** `frame_pack`→`uint8_t[96]` consumed by `avr_write_frame`; `keys_decode`→`struct keyev` consumed in daemon; `ctl_parse`→`struct ctl_cmd` consumed in daemon; `struct layer` render signature consistent between compositor and daemon layers.

## Follow-ons (proper, not shortcuts)

- **Plan 2b — pixel-perfect volume ring + mute:** implement a compositor `layer` (priority 10, the seam above) using the EXACT algorithm from `docs/2026-06-19-volume-mute-RE.md` (in-flight deodex of `VolumePanel.setVolumeLeds` + `LedController`): exact LED-count mapping, origin/arc, colors, fade/timing, mute color. No approximation.
- **Plan 3 — music visualizer:** audio tap (PipeWire/ALSA monitor) → Android-compatible FFT → ported GLSL LED shaders → frame channel, golden-test harness; the C hot-loop.
