# Onboarding (Step 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App-driven WiFi onboarding for the display-less Nexus Q: NFC tap → BT RFCOMM provisioning → WiFi join → name/room/theme → outro, with the original stock imagery.

**Architecture:** Approach A from the spec (`docs/superpowers/specs/2026-07-13-onboarding-and-companion-phase-design.md`): a new device daemon `nexusq-setupd` (Python, BlueZ D-Bus Profile1 RFCOMM + nmcli), a new `spin` LED command in `nexusqd`, a dynamic NFC connection-info payload in `nexusq-nfc-send`, a `startSetupMode` method in `nexusq-control`, and a Flutter setup wizard with a Kotlin BT RFCOMM platform channel. Protocol = the existing newline-JSON envelope (PROTOCOL.md v1) over RFCOMM.

**Tech Stack:** C11/musl (nexusqd), Python 3 + dbus-python + PyGObject (setupd), Python 3 stdlib (bridge/NFC), systemd, BlueZ 5, NetworkManager (nmcli), Flutter/Dart + Kotlin (app), Alpine APKBUILD packaging.

## Global Constraints

- **No shortcuts** — always the most correct, robust path (user's standing rule).
- `nexusq-control` and `nexusq-nfc-send` stay **Python stdlib-only**. `nexusq-setupd` may additionally use `py3-dbus` + `py3-gobject3` (needed for BlueZ Profile1/Agent1).
- Setup RFCOMM service UUID (both ends, PROTOCOL.md): **`8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a`**.
- Device identity file (both daemons + wrappers): **`/etc/nexusq/device.json`**, shape `{"name": "Nexus Q", "room": "livingroom"}`.
- WiFi NM profile name created by setup: **`wifi`** (mirrors the baked `wifi.nmconnection`).
- Stock imagery is Google copyright: extracted to `companion/app/assets/stock/`, which is **gitignored**; builds without it must fall back gracefully, never break.
- WiFi credentials must never be logged (no psk in any `log()`/print/journal path).
- Error codes over the wire (PROTOCOL.md): `bad_request`, `unknown_method`, `unavailable`, `internal` + new setup codes `wrong_password`, `not_found`, `timeout`.
- Repo gotcha: any kernel DTS change must go via `kernel/patches/` — **not needed in this plan** (no kernel changes).
- Commit style: `feat(scope): …` / `fix(scope): …`, imperative, as in `git log`.
- Host test runners: C via dockerized Alpine gcc (exact command in Task 1), Python via `python -m unittest`, Dart via `flutter test` in `companion/app/`.

---

### Task 1: nexusqd `spin R G B` command (setup LED animation)

The setup mode needs the stock "rotating blue dot" on the 32-LED ring. `nexusqd` owns the ring; we add a `spin` variant to the manual override layer (priority 8), next to the existing `set`/`breathe`.

**Files:**
- Create: `userspace/nexusqd/src/spinner.c`
- Create: `userspace/nexusqd/include/spinner.h`
- Create: `userspace/nexusqd/tests/test_spinner.c`
- Modify: `userspace/nexusqd/include/control.h` (add `CTL_SPIN`)
- Modify: `userspace/nexusqd/src/control.c` (parse `spin R G B`)
- Modify: `userspace/nexusqd/src/nexusqd.c` (manual layer spin mode)
- Modify: `userspace/nexusqd/Makefile` (add `spinner.c` to the object list — match the existing style)
- Modify: `pmos/nexusqd/APKBUILD` (pkgrel bump)
- Modify: `docker-build.sh` (no change needed — it already stages `userspace/nexusqd/src/*.c` + `include/*.h`; verify only)

**Interfaces:**
- Produces: `void spinner_render(const int rgb[3], double t, struct frame *out)` — deterministic pure function; a head dot at `fmod(t * SPIN_REV_PER_S, 1.0) * RING` with an 8-LED exponential tail (factor 0.65). `SPIN_REV_PER_S = 0.75`.
- Produces: nexusqd socket command **`spin R G B`** (e.g. `spin 0 153 204`), cleared by `auto`/`set`/`breathe`/`off`.

- [ ] **Step 1: Write the failing host test**

`userspace/nexusqd/tests/test_spinner.c`:

```c
/* Host test for the spin animation: pure math, no AVR/hardware. */
#include "spinner.h"
#include "frame.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static int brightest(const struct frame *f) {
    int best = 0, sum = -1;
    for (int i = 0; i < RING; i++) {
        int s = f->px[i][0] + f->px[i][1] + f->px[i][2];
        if (s > sum) { sum = s; best = i; }
    }
    return best;
}

int main(void) {
    struct frame f;
    const int rgb[3] = { 0, 153, 204 };

    /* t=0: head at LED 0 with the full color */
    spinner_render(rgb, 0.0, &f);
    assert(brightest(&f) == 0);
    assert(f.px[0][0] == 0 && f.px[0][1] == 153 && f.px[0][2] == 204);

    /* the tail behind the head decays: LED 31 (one behind) dimmer than LED 0 */
    assert(f.px[31][1] < f.px[0][1] && f.px[31][1] > 0);

    /* LEDs outside the 8-LED tail are dark */
    assert(f.px[16][0] == 0 && f.px[16][1] == 0 && f.px[16][2] == 0);

    /* rotation: at 0.75 rev/s, t=1/3 s -> 0.25 rev -> head at LED 8 */
    spinner_render(rgb, 1.0 / 3.0, &f);
    assert(brightest(&f) == 8);

    /* full revolution wraps: t = 4/3 s -> head back at LED 0 */
    spinner_render(rgb, 4.0 / 3.0, &f);
    assert(brightest(&f) == 0);

    printf("test_spinner: OK\n");
    return 0;
}
```

- [ ] **Step 2: Run the test to verify it fails (does not compile — spinner.h missing)**

Run (from the repo root, Git Bash):
```bash
docker run --rm -v "$PWD":/src -w /src alpine:3.20 sh -c \
  "apk add -q build-base && gcc -std=c11 -Iuserspace/nexusqd/include \
   userspace/nexusqd/tests/test_spinner.c userspace/nexusqd/src/spinner.c \
   userspace/nexusqd/src/frame.c -lm -o /tmp/t && /tmp/t"
```
Expected: FAIL — `spinner.c: No such file or directory`.

- [ ] **Step 3: Implement spinner.h + spinner.c**

`userspace/nexusqd/include/spinner.h`:
```c
/* userspace/nexusqd/include/spinner.h */
#ifndef NEXUSQD_SPINNER_H
#define NEXUSQD_SPINNER_H
#include "frame.h"
/* Setup-mode "rotating dot": a single head LED in the given color with an
 * 8-LED exponential tail, revolving at SPIN_REV_PER_S. Pure function of t
 * (monotonic seconds) so it is host-testable and stateless. */
#define SPIN_REV_PER_S 0.75
#define SPIN_TAIL 8
void spinner_render(const int rgb[3], double t, struct frame *out);
#endif
```

`userspace/nexusqd/src/spinner.c`:
```c
/* userspace/nexusqd/src/spinner.c */
#include "spinner.h"
#include <math.h>

void spinner_render(const int rgb[3], double t, struct frame *out) {
    frame_black(out);
    double pos = fmod(t * SPIN_REV_PER_S, 1.0);
    if (pos < 0) pos += 1.0;
    int head = (int)(pos * RING) % RING;
    double a = 1.0;
    for (int k = 0; k < SPIN_TAIL; k++) {
        int idx = (head - k + RING) % RING;
        frame_set(out, idx,
                  (int)(rgb[0] * a + 0.5),
                  (int)(rgb[1] * a + 0.5),
                  (int)(rgb[2] * a + 0.5));
        a *= 0.65;
    }
}
```

- [ ] **Step 4: Re-run the Step 2 command**

Expected: PASS — `test_spinner: OK`.

- [ ] **Step 5: Wire the command through control.h / control.c / nexusqd.c**

`control.h` — extend the enum (append, do not reorder):
```c
enum ctl_kind { CTL_THEME, CTL_SET, CTL_MUTE, CTL_OFF, CTL_STATUS, CTL_VOL, CTL_MTOGGLE, CTL_AUTO, CTL_SCENE, CTL_BRIGHTNESS, CTL_BREATHE, CTL_SETMUTED, CTL_SPIN };
```

`control.c` — add next to the `breathe` parse line:
```c
    if (!strcmp(tok[0], "spin") && n == 4) { out->kind = CTL_SPIN; return rgb3(tok[1],tok[2],tok[3], out->rgb); }
```

`nexusqd.c` — three changes:
1. `#include "spinner.h"` with the other includes.
2. `struct manual_ctx { int rgb[3]; int breathe; int spin; };` and in `manual_render`, before the breathe branch:
```c
    if (m->spin) { spinner_render(m->rgb, t, out); return 0; }
```
3. In the socket command dispatch: every existing assignment of the manual layer (`CTL_SET`, `CTL_OFF`, `CTL_BREATHE`, `CTL_THEME`) must also set `manual.spin = 0;`, and add:
```c
                    else if (cmd.kind == CTL_SPIN) {
                        /* setup-mode rotating dot (stock "starting up" visual):
                         * an ANIMATED manual override at priority 8. Cleared by
                         * auto/set/breathe/off like every manual mode. */
                        memcpy(manual.rgb, cmd.rgb, sizeof(manual.rgb));
                        manual.breathe = 0; manual.spin = 1;
                        comp.layers[manual_idx].active = 1;
                    }
```
Also: the render loop's frame cadence (`frame_int`) uses 50 ms when idle — an active spin must animate smoothly. Extend the cadence expression:
```c
        double frame_int = reaction_overlay_active(&rx, now_s()) ? 0.016
                         : ((child_alpha > 0.0f || (comp.layers[manual_idx].active && manual.spin)) ? 0.030 : 0.050);
```
Also init update: `struct manual_ctx manual = { { 0, 0, 0 }, 0, 0 };`

Add `spinner.c` to the Makefile object list (same pattern as `fx_*.c` entries).

- [ ] **Step 6: Re-run the host test + compile-check the daemon**

Run the Step 2 command (still PASS), then a whole-daemon compile check:
```bash
docker run --rm -v "$PWD":/src -w /src/userspace/nexusqd alpine:3.20 sh -c \
  "apk add -q build-base alsa-lib-dev && make"
```
Expected: builds clean (link needs alsa; if the Makefile needs more dev packages, install what its README/APKBUILD makedepends lists).

- [ ] **Step 7: Bump `pmos/nexusqd/APKBUILD` pkgrel by 1, update the command list in `userspace/nexusqd/include/control.h` header comment if present, and commit**

```bash
git add userspace/nexusqd pmos/nexusqd/APKBUILD
git commit -m "feat(nexusqd): spin R G B - rotating-dot setup animation (manual layer)"
```

---

### Task 2: Device identity config + bridge `startSetupMode` + name/room

**Files:**
- Modify: `userspace/nexusq-control/nexusq-control` (load `/etc/nexusq/device.json`; add `startSetupMode`; add `room` to mDNS TXT + `getDeviceInfo`)
- Create: `userspace/nexusq-control/tests/test_identity.py`
- Modify: `pmos/nexusq-control/APKBUILD` (pkgrel bump)
- Modify: `pmos/device-google-steelhead/librespot-nexusq` (read the name from device.json)
- Modify: `companion/PROTOCOL.md` (document `startSetupMode`, `room`)

**Interfaces:**
- Produces: `load_identity(path="/etc/nexusq/device.json") -> dict` returning `{"name": str, "room": str}` with fallbacks (env `NEXUSQ_NAME`, default `"Nexus Q"`, room default `""`).
- Produces: LAN method `startSetupMode` → `{"started": true}` or error `unavailable`.
- Produces: `getDeviceInfo` result gains `"room": "<room>"`; mDNS TXT gains `room=<room>`.
- Consumes (Task 6 provides the unit): `systemctl start nexusq-setupd.service` + flag file `/run/nexusq-setup.force`.

- [ ] **Step 1: Write the failing test**

`userspace/nexusq-control/tests/test_identity.py`:
```python
import importlib.util
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")

def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

class TestIdentity(unittest.TestCase):
    def test_load_identity_from_file(self):
        mod = load_daemon()
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "device.json")
            with open(p, "w") as f:
                json.dump({"name": "Obývák Q", "room": "livingroom"}, f)
            ident = mod.load_identity(p)
        self.assertEqual(ident["name"], "Obývák Q")
        self.assertEqual(ident["room"], "livingroom")

    def test_load_identity_missing_file_falls_back(self):
        mod = load_daemon()
        os.environ["NEXUSQ_NAME"] = "EnvName"
        try:
            ident = mod.load_identity("/nonexistent/device.json")
        finally:
            del os.environ["NEXUSQ_NAME"]
        self.assertEqual(ident["name"], "EnvName")
        self.assertEqual(ident["room"], "")

    def test_load_identity_garbage_file_falls_back(self):
        mod = load_daemon()
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "device.json")
            with open(p, "w") as f:
                f.write("{not json")
            ident = mod.load_identity(p)
        self.assertEqual(ident["name"], "Nexus Q")

if __name__ == "__main__":
    unittest.main()
```

Note: importing the daemon must not open sockets — all side effects are inside `main()` already; keep it that way.

- [ ] **Step 2: Run it**

Run: `python -m unittest discover -s userspace/nexusq-control/tests -v`
Expected: FAIL — `AttributeError: ... no attribute 'load_identity'`.

- [ ] **Step 3: Implement in `nexusq-control`**

After the `DEVICE_NAME = ...` line, replace the plain env read with:
```python
IDENTITY_PATH = os.environ.get("NEXUSQ_IDENTITY", "/etc/nexusq/device.json")
SETUP_FORCE_FLAG = "/run/nexusq-setup.force"


def load_identity(path=None):
    """Device identity {name, room}: /etc/nexusq/device.json (written by
    nexusq-setupd's setName) > NEXUSQ_NAME env > defaults. Resilient: a
    missing/corrupt file can never take the bridge down."""
    ident = {"name": os.environ.get("NEXUSQ_NAME", "Nexus Q"), "room": ""}
    try:
        with open(path or IDENTITY_PATH) as f:
            data = json.load(f)
        if isinstance(data.get("name"), str) and data["name"].strip():
            ident["name"] = data["name"].strip()
        if isinstance(data.get("room"), str):
            ident["room"] = data["room"].strip()
    except (OSError, ValueError):
        pass
    return ident


_IDENT = load_identity()
DEVICE_NAME = _IDENT["name"]
DEVICE_ROOM = _IDENT["room"]
```
(The old `DEVICE_NAME = os.environ.get("NEXUSQ_NAME", "Nexus Q")` line is replaced by this block.)

In `handle()`, extend `getDeviceInfo`:
```python
        if method == "getDeviceInfo":
            return {"name": DEVICE_NAME, "model": "steelhead", "room": DEVICE_ROOM,
                    "serial": _serial(), "swVersion": _sw_version()}, []
```
and add (before the final `raise Err("unknown_method", method)`):
```python
        if method == "startSetupMode":
            # Re-provisioning entry point: arm the force flag (the unit's
            # ExecCondition honors it even when a WiFi profile exists) and
            # start nexusq-setupd. The setup daemon owns everything after this.
            try:
                open(SETUP_FORCE_FLAG, "w").close()
                r = subprocess.run(["systemctl", "start", "nexusq-setupd.service"],
                                   capture_output=True, text=True, timeout=15)
                if r.returncode != 0:
                    raise Err("unavailable", "nexusq-setupd failed to start: " + r.stderr.strip())
            except OSError as e:
                raise Err("unavailable", f"cannot start setup mode: {e}")
            return {"started": True}, []
```
In `publish_mdns()`, add the TXT record after `"model=steelhead"`:
```python
             "proto=1", f"name={DEVICE_NAME}", "model=steelhead", f"room={DEVICE_ROOM}"],
```

- [ ] **Step 4: Re-run the tests**

Run: `python -m unittest discover -s userspace/nexusq-control/tests -v`
Expected: 3 tests PASS.

- [ ] **Step 5: librespot wrapper reads the name**

In `pmos/device-google-steelhead/librespot-nexusq` (shell wrapper), replace the hardcoded `--name "Nexus Q"` argument with a lookup (adapt to the wrapper's existing variable style — read the file first):
```sh
NQ_NAME="$(python3 - <<'EOF' 2>/dev/null || echo "Nexus Q"
import json
print(json.load(open("/etc/nexusq/device.json"))["name"])
EOF
)"
[ -n "$NQ_NAME" ] || NQ_NAME="Nexus Q"
```
and use `--name "$NQ_NAME"`.

- [ ] **Step 6: PROTOCOL.md**

In §4 add to the Device info table:
```markdown
| `getDeviceInfo` | — | `{ name, model:"steelhead", room, serial, swVersion }` |
| `startSetupMode` | — | `{ started: true }` — arms `/run/nexusq-setup.force` and starts `nexusq-setupd` (BT re-provisioning; see §8). Errors `unavailable`. |
```
In §2 Discovery, extend the TXT list with `room=<room>`.

- [ ] **Step 7: Bump `pmos/nexusq-control/APKBUILD` pkgrel and `pmos/device-google-steelhead/APKBUILD` pkgrel, commit**

```bash
git add userspace/nexusq-control pmos/nexusq-control/APKBUILD \
        pmos/device-google-steelhead/librespot-nexusq pmos/device-google-steelhead/APKBUILD \
        companion/PROTOCOL.md
git commit -m "feat(bridge): device identity file, room TXT, startSetupMode"
```

---

### Task 3: Shared pairing-color test vectors

The LED visual-pairing color is derived from the BT MAC identically on the device (Python) and in the app (Dart). Lock the algorithm with shared vectors both test suites read.

**Files:**
- Create: `companion/pairing-color-vectors.json`

**Interfaces:**
- Produces: the derivation contract — `hue = (mac[4]<<8 | mac[5]) % 360`, HSV(h, 1.0, 1.0) → RGB ints 0–255 (standard sector conversion, round half up). Consumed by Task 4 (Python) and Task 10 (Dart).

- [ ] **Step 1: Write the vectors file**

`companion/pairing-color-vectors.json`:
```json
{
  "algorithm": "hue = ((mac[4] << 8) | mac[5]) % 360; rgb = hsv_to_rgb(hue, s=1.0, v=1.0); channels rounded to nearest int (0..255)",
  "vectors": [
    { "mac": "F8:8F:CA:20:49:E5", "rgb": [0, 183, 255] },
    { "mac": "00:00:00:00:00:00", "rgb": [255, 0, 0] },
    { "mac": "AA:BB:CC:DD:01:2C", "rgb": [255, 0, 255] },
    { "mac": "AA:BB:CC:DD:00:3C", "rgb": [255, 255, 0] },
    { "mac": "11:22:33:44:00:78", "rgb": [0, 255, 0] }
  ]
}
```
Derivations for review: `0x49E5 % 360 = 197` (sector 180–240 → `(0, x, 255)`, `x = round(255·(1−|197/60 mod 2 − 1|)) = 183`); `0x0000 → 0` (red); `0x012C = 300` (magenta); `0x003C = 60` (yellow); `0x0078 = 120` (green).

- [ ] **Step 2: Commit**

```bash
git add companion/pairing-color-vectors.json
git commit -m "feat(companion): shared pairing-color test vectors"
```

---

### Task 4: nexusq-setupd — core daemon (state machine, nmcli, LED, identity)

Single-file Python daemon, importable for tests (like the bridge). This task builds everything **except** the BlueZ transport (Task 5): method handlers, nmcli wrapper, error classification, LED control, name sanitization, pairing color.

**Files:**
- Create: `userspace/nexusq-setupd/nexusq-setupd`
- Create: `userspace/nexusq-setupd/tests/test_setupd.py`
- Create: `userspace/nexusq-setupd/README.md` (short: what it is, env config, protocol pointer)

**Interfaces:**
- Consumes: nexusqd socket commands `spin R G B` (Task 1), `set R G B`, `breathe R G B`, `auto`.
- Consumes: `companion/pairing-color-vectors.json` (Task 3) in tests.
- Produces (for Task 5): `class SetupCore` with `handle(method, params) -> dict` (raises `Err(code, message)`), plus `SetupCore.touch()` (activity timestamp) and `SetupCore.finished` (bool).
- Produces (wire, for Tasks 9/10/12/13): methods `getDeviceInfo`, `confirmColor`, `scanNetworks`, `setWifi`, `getNetworkState`, `setName`, `setTheme`, `finishSetup` per the spec §2 table.
- Produces: `pairing_color(mac: str) -> tuple[int, int, int]`, `sanitize_hostname(name: str) -> str`.

- [ ] **Step 1: Write the failing tests**

`userspace/nexusq-setupd/tests/test_setupd.py`:
```python
import importlib.util
import importlib.machinery
import json
import os
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-setupd")
VECTORS = os.path.join(HERE, "..", "..", "..", "companion", "pairing-color-vectors.json")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_setupd", importlib.machinery.SourceFileLoader("nexusq_setupd", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestPairingColor(unittest.TestCase):
    def test_shared_vectors(self):
        mod = load_daemon()
        with open(VECTORS) as f:
            vectors = json.load(f)["vectors"]
        for v in vectors:
            self.assertEqual(list(mod.pairing_color(v["mac"])), v["rgb"], v["mac"])


class TestSanitizeHostname(unittest.TestCase):
    def test_diacritics_and_spaces(self):
        mod = load_daemon()
        self.assertEqual(mod.sanitize_hostname("Obývák Q"), "obyvak-q")

    def test_empty_falls_back(self):
        mod = load_daemon()
        self.assertEqual(mod.sanitize_hostname("---"), "nexusq")

    def test_length_cap(self):
        mod = load_daemon()
        self.assertLessEqual(len(mod.sanitize_hostname("x" * 100)), 63)


class TestNmErrorClassification(unittest.TestCase):
    def test_wrong_password(self):
        mod = load_daemon()
        self.assertEqual(mod.classify_nm_error(
            "Error: Connection activation failed: Secrets were required, but not provided."),
            "wrong_password")

    def test_not_found(self):
        mod = load_daemon()
        self.assertEqual(mod.classify_nm_error(
            "Error: No network with SSID 'foo' found."), "not_found")

    def test_timeout(self):
        mod = load_daemon()
        self.assertEqual(mod.classify_nm_error(
            "Error: Timeout expired (90) seconds"), "timeout")

    def test_unknown_is_internal(self):
        mod = load_daemon()
        self.assertEqual(mod.classify_nm_error("something odd"), "internal")


class TestScanParsing(unittest.TestCase):
    def test_parse_dedupe_and_security(self):
        mod = load_daemon()
        out = "MyNet:72:WPA2\nMyNet:55:WPA2\nOpenNet:40:\n:30:WPA2\n"
        nets = mod.parse_wifi_list(out)
        self.assertEqual(nets, [
            {"ssid": "MyNet", "signal": 72, "security": "wpa-psk"},
            {"ssid": "OpenNet", "signal": 40, "security": "open"},
        ])


class TestSetupCore(unittest.TestCase):
    def _core(self, mod):
        return mod.SetupCore(run=mock.Mock(), led=mock.Mock(), bt_mac="F8:8F:CA:20:49:E5")

    def test_get_device_info(self):
        mod = load_daemon()
        core = self._core(mod)
        info = core.handle("getDeviceInfo", {})
        self.assertEqual(info["model"], "steelhead")
        self.assertEqual(info["btMac"], "F8:8F:CA:20:49:E5")
        self.assertIn("provisioned", info)

    def test_confirm_color_drives_led_and_returns_rgb(self):
        mod = load_daemon()
        core = self._core(mod)
        r = core.handle("confirmColor", {})
        self.assertEqual(r["rgb"], [0, 183, 255])
        core.led.send.assert_called_with("set 0 183 255")

    def test_set_wifi_success(self):
        mod = load_daemon()
        core = self._core(mod)
        # run() mock: every nmcli call succeeds; IP lookup returns an address
        def fake_run(args, **kw):
            m = mock.Mock(returncode=0, stderr="")
            m.stdout = "192.168.20.195/24\n" if "IP4.ADDRESS" in args else ""
            return m
        core.run = fake_run
        r = core.handle("setWifi", {"ssid": "MyNet", "psk": "secret", "security": "wpa-psk"})
        self.assertTrue(r["ok"])
        self.assertEqual(r["ip"], "192.168.20.195")
        self.assertTrue(r["mdns"].endswith(".local"))

    def test_set_wifi_wrong_password_cleans_up(self):
        mod = load_daemon()
        core = self._core(mod)
        calls = []
        def fake_run(args, **kw):
            calls.append(args)
            if args[:3] == ["nmcli", "connection", "up"]:
                return mock.Mock(returncode=4,
                                 stderr="Error: Connection activation failed: Secrets were required, but not provided.")
            return mock.Mock(returncode=0, stdout="", stderr="")
        core.run = fake_run
        with self.assertRaises(mod.Err) as cm:
            core.handle("setWifi", {"ssid": "MyNet", "psk": "wrong", "security": "wpa-psk"})
        self.assertEqual(cm.exception.code, "wrong_password")
        # the failed profile must be deleted
        self.assertIn(["nmcli", "connection", "delete", "wifi"], calls)

    def test_set_wifi_missing_ssid(self):
        mod = load_daemon()
        core = self._core(mod)
        with self.assertRaises(mod.Err) as cm:
            core.handle("setWifi", {"psk": "x"})
        self.assertEqual(cm.exception.code, "bad_request")

    def test_finish_setup_sets_finished(self):
        mod = load_daemon()
        core = self._core(mod)
        core.run = lambda *a, **k: mock.Mock(returncode=0, stdout="", stderr="")
        r = core.handle("finishSetup", {})
        self.assertTrue(r["done"])
        self.assertTrue(core.finished)

    def test_unknown_method(self):
        mod = load_daemon()
        core = self._core(mod)
        with self.assertRaises(mod.Err) as cm:
            core.handle("nonsense", {})
        self.assertEqual(cm.exception.code, "unknown_method")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests**

Run: `python -m unittest discover -s userspace/nexusq-setupd/tests -v`
Expected: FAIL — cannot load daemon (file missing).

- [ ] **Step 3: Implement the daemon core**

`userspace/nexusq-setupd/nexusq-setupd` (complete file; the `main()`/BlueZ part lands in Task 5 — for now `main()` just prints and exits 0 so the file is import-safe and runnable):
```python
#!/usr/bin/env python3
"""nexusq-setupd — BT RFCOMM WiFi-provisioning daemon for the Nexus Q.

Implements the "Setup transport" of companion/PROTOCOL.md (§8): the same
newline-JSON envelope as the LAN bridge, carried over Bluetooth RFCOMM
(BlueZ Profile1, service UUID 8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a).

Runs ONLY in setup mode: on boot when no WiFi profile exists (unit
ExecCondition) or on demand via the bridge's startSetupMode (force flag).
While active: BT discoverable + Just-Works agent, LED ring spins the stock
"starting up" blue dot, WiFi ops go through nmcli.

Design mirror of userspace/nexusq-control: single file, importable for
tests (side effects only in main()); subprocess for nmcli/hostnamectl;
nexusqd over its Unix socket. D-Bus (dbus-python + GLib) is used ONLY for
BlueZ Profile1/Agent1 — there is no other way to own an RFCOMM profile.

Config via env:
  NEXUSQ_SETUP_UUID     (default 8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a)
  NEXUSQD_SOCK          (default /run/nexusqd.sock)
  NEXUSQ_IDENTITY       (default /etc/nexusq/device.json)
  NEXUSQ_SETUP_TIMEOUT  (default 600 s of inactivity -> exit)
  NEXUSQ_WLAN_IFACE     (default wlan0)
"""
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import unicodedata

SETUP_UUID = os.environ.get("NEXUSQ_SETUP_UUID", "8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a")
NEXUSQD_SOCK = os.environ.get("NEXUSQD_SOCK", "/run/nexusqd.sock")
IDENTITY_PATH = os.environ.get("NEXUSQ_IDENTITY", "/etc/nexusq/device.json")
SETUP_TIMEOUT = float(os.environ.get("NEXUSQ_SETUP_TIMEOUT", "600"))
WLAN = os.environ.get("NEXUSQ_WLAN_IFACE", "wlan0")
FORCE_FLAG = "/run/nexusq-setup.force"
SPIN_CMD = "spin 0 153 204"        # the stock #0099CC boot hue
SUCCESS_CMD = "breathe 0 200 0"    # green success breathe before exit

# Mirror of the bridge THEME_CMDS (userspace/nexusq-control) — keep in sync.
THEME_CMDS = {
    "blue":  ["breathe 0 153 204"],
    "warm":  ["breathe 255 90 10"],
    "cool":  ["breathe 0 200 140"],
    "rose":  ["breathe 255 40 90"],
    "smoke": ["breathe 110 115 135"],
    "off":   ["off"],
}


def log(*a):
    print("[nexusq-setupd]", *a, flush=True)


class Err(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


# --- pure helpers (host-tested) ------------------------------------------

def pairing_color(mac):
    """The LED visual-pairing color, derived from the BT MAC (stock trick).
    Contract + shared vectors: companion/pairing-color-vectors.json."""
    b = [int(x, 16) for x in mac.split(":")]
    hue = ((b[4] << 8) | b[5]) % 360
    c = 1.0
    x = 1.0 - abs((hue / 60.0) % 2.0 - 1.0)
    sect = hue // 60
    rgbf = [(c, x, 0.0), (x, c, 0.0), (0.0, c, x),
            (0.0, x, c), (x, 0.0, c), (c, 0.0, x)][sect]
    return tuple(int(v * 255 + 0.5) for v in rgbf)


def sanitize_hostname(name):
    """Display name -> RFC-952-ish hostname: ascii-fold, lowercase,
    non-alnum runs -> '-', trimmed, <=63 chars, fallback 'nexusq'."""
    folded = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    clean = re.sub(r"[^a-z0-9]+", "-", folded.lower()).strip("-")[:63].strip("-")
    return clean or "nexusq"


def classify_nm_error(stderr):
    s = stderr.lower()
    if "secrets were required" in s or "no secrets provided" in s:
        return "wrong_password"
    if "no network with ssid" in s or "not found" in s:
        return "not_found"
    if "timeout" in s:
        return "timeout"
    return "internal"


def parse_wifi_list(out):
    """Parse `nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list` output:
    dedupe by SSID (keep strongest), skip hidden/empty SSIDs, map security."""
    best = {}
    for ln in out.splitlines():
        parts = ln.split(":")
        if len(parts) < 3:
            continue
        ssid = ":".join(parts[:-2])          # SSIDs may contain ':'
        signal_s, sec = parts[-2], parts[-1]
        if not ssid:
            continue
        try:
            signal = int(signal_s)
        except ValueError:
            continue
        security = "wpa-psk" if "WPA" in sec.upper() else "open"
        if ssid not in best or best[ssid]["signal"] < signal:
            best[ssid] = {"ssid": ssid, "signal": signal, "security": security}
    return sorted(best.values(), key=lambda n: -n["signal"])


# --- side-effect adapters --------------------------------------------------

def run_cmd(args, timeout=60):
    """subprocess.run wrapper (injectable in SetupCore for tests)."""
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


class Led:
    """nexusqd control-socket sender (same contract as the bridge's)."""

    def send(self, line):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(2)
                s.connect(NEXUSQD_SOCK)
                s.sendall((line + "\n").encode())
                return s.recv(64).startswith(b"ok")
        except OSError as e:
            log("nexusqd send failed:", e)
            return False


def bt_adapter_mac():
    try:
        with open("/sys/class/bluetooth/hci0/address") as f:
            return f.read().strip().upper()
    except OSError:
        return ""


def wifi_provisioned(run=run_cmd):
    try:
        r = run(["nmcli", "-t", "-f", "TYPE", "connection", "show"], timeout=10)
        return r.returncode == 0 and "802-11-wireless" in r.stdout
    except Exception:  # noqa: BLE001
        return False


# --- the setup state machine ----------------------------------------------

class SetupCore:
    """Protocol method handlers. Transport-agnostic: Task 5's RFCOMM loop
    calls handle(); tests call it directly. Credentials are never logged."""

    def __init__(self, run=run_cmd, led=None, bt_mac=None):
        self.run = run
        self.led = led if led is not None else Led()
        self.bt_mac = bt_mac if bt_mac is not None else bt_adapter_mac()
        self.finished = False
        self.chosen_theme = None
        self.last_activity = time.monotonic()

    def touch(self):
        self.last_activity = time.monotonic()

    # -- dispatch --
    def handle(self, method, params):
        self.touch()
        p = params or {}
        if method == "getDeviceInfo":
            return self._device_info()
        if method == "confirmColor":
            return self._confirm_color()
        if method == "scanNetworks":
            return self._scan()
        if method == "setWifi":
            return self._set_wifi(p)
        if method == "getNetworkState":
            return self._net_state()
        if method == "setName":
            return self._set_name(p)
        if method == "setTheme":
            return self._set_theme(p)
        if method == "finishSetup":
            return self._finish()
        raise Err("unknown_method", method)

    # -- handlers --
    def _device_info(self):
        return {"model": "steelhead", "btMac": self.bt_mac,
                "swVersion": _sw_version(), "provisioned": wifi_provisioned(self.run),
                "proto": 1}

    def _confirm_color(self):
        r, g, b = pairing_color(self.bt_mac)
        if not self.led.send(f"set {r} {g} {b}"):
            raise Err("unavailable", "nexusqd not reachable")
        return {"rgb": [r, g, b]}

    def _scan(self):
        r = self.run(["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY",
                      "dev", "wifi", "list", "ifname", WLAN, "--rescan", "yes"],
                     timeout=30)
        if r.returncode != 0:
            raise Err("unavailable", "wifi scan failed")
        return {"networks": parse_wifi_list(r.stdout)}

    def _set_wifi(self, p):
        ssid = p.get("ssid")
        if not isinstance(ssid, str) or not ssid:
            raise Err("bad_request", "ssid required")
        psk = p.get("psk", "")
        security = p.get("security", "wpa-psk" if psk else "open")
        hidden = bool(p.get("hidden", False))
        # resume the spinner while we join (confirmColor left a solid color)
        self.led.send(SPIN_CMD)
        # replace any previous attempt/profile of the same name
        self.run(["nmcli", "connection", "delete", "wifi"], timeout=15)
        add = ["nmcli", "connection", "add", "type", "wifi", "con-name", "wifi",
               "ifname", WLAN, "ssid", ssid, "connection.autoconnect", "yes"]
        if security == "wpa-psk":
            if not psk:
                raise Err("bad_request", "psk required for wpa-psk")
            add += ["wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", psk]
        if hidden:
            add += ["802-11-wireless.hidden", "yes"]
        r = self.run(add, timeout=20)
        if r.returncode != 0:
            raise Err("internal", "profile create failed")
        up = self.run(["nmcli", "connection", "up", "wifi"], timeout=90)
        if up.returncode != 0:
            code = classify_nm_error(up.stderr)
            self.run(["nmcli", "connection", "delete", "wifi"], timeout=15)
            raise Err(code, "wifi join failed")
        ip = self._wlan_ip()
        return {"ok": True, "ip": ip,
                "mdns": socket.gethostname() + ".local"}

    def _wlan_ip(self):
        r = self.run(["nmcli", "-g", "IP4.ADDRESS", "dev", "show", WLAN], timeout=10)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip().splitlines()[0].split("/")[0]
        return None

    def _net_state(self):
        r = self.run(["nmcli", "-t", "-f", "DEVICE,STATE", "dev", "status"], timeout=10)
        state = "idle"
        if r.returncode == 0:
            for ln in r.stdout.splitlines():
                cols = ln.split(":")
                if len(cols) >= 2 and cols[0] == WLAN:
                    nm = cols[1]
                    state = ("online" if nm == "connected"
                             else "associating" if nm.startswith("connecting")
                             else "idle")
        out = {"state": state}
        if state == "online":
            out["ip"] = self._wlan_ip()
        return out

    def _set_name(self, p):
        name = p.get("name")
        if not isinstance(name, str) or not name.strip():
            raise Err("bad_request", "name required")
        room = p.get("room", "")
        if not isinstance(room, str):
            raise Err("bad_request", "room must be a string")
        name = name.strip()
        host = sanitize_hostname(name)
        r = self.run(["hostnamectl", "set-hostname", host], timeout=15)
        if r.returncode != 0:
            raise Err("internal", "hostname change failed")
        os.makedirs(os.path.dirname(IDENTITY_PATH), exist_ok=True)
        tmp = IDENTITY_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"name": name, "room": room}, f)
        os.replace(tmp, IDENTITY_PATH)
        # re-advertise: the bridge publishes its mDNS name at start; librespot
        # reads the name at start. Restart both, best-effort (setName may run
        # before either is relevant; failures must not fail the setup).
        self.run(["systemctl", "restart", "nexusq-control.service"], timeout=30)
        if os.path.isdir("/run/user/10000/systemd"):
            self.run(["systemctl", "-M", "user@", "--user", "restart",
                      "librespot.service"], timeout=30)
        return {"name": name, "room": room, "hostname": host,
                "mdns": host + ".local"}

    def _set_theme(self, p):
        theme = str(p.get("theme", ""))
        if theme not in THEME_CMDS:
            raise Err("bad_request", f"unknown theme {theme}")
        for c in THEME_CMDS[theme]:
            if not self.led.send(c):
                raise Err("unavailable", "nexusqd rejected theme")
        self.chosen_theme = theme
        return {"theme": theme}

    def _finish(self):
        self.led.send(SUCCESS_CMD)
        time.sleep(2.0)
        if self.chosen_theme:
            for c in THEME_CMDS[self.chosen_theme]:
                self.led.send(c)
        else:
            self.led.send("auto")
        self.finished = True
        return {"done": True}


def _sw_version():
    try:
        with open("/etc/os-release") as f:
            for ln in f:
                if ln.startswith("VERSION="):
                    return ln.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return "unknown"


def main():
    # Task 5 replaces this with the BlueZ Profile1/Agent1 transport loop.
    log("transport not yet implemented (see plan Task 5)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests**

Run: `python -m unittest discover -s userspace/nexusq-setupd/tests -v`
Expected: all PASS. If a `pairing_color` vector fails, fix the **vectors** only if hand-verification proves the code right — otherwise fix the code; the two must agree with the documented algorithm.

- [ ] **Step 5: README + commit**

`userspace/nexusq-setupd/README.md`: 10–15 lines — purpose, the §8 PROTOCOL.md pointer, env vars table (copy the docstring), "runs only in setup mode (ExecCondition), exits after finishSetup or 600 s idle".

```bash
git add userspace/nexusq-setupd
git commit -m "feat(setupd): provisioning state machine, nmcli glue, pairing color (core, transport-less)"
```

---

### Task 5: nexusq-setupd — BlueZ RFCOMM transport + Just-Works agent + lifecycle

**Files:**
- Modify: `userspace/nexusq-setupd/nexusq-setupd` (replace the stub `main()`; add the D-Bus classes)
- Create: `userspace/nexusq-setupd/nexusq-setupd.service`
- Create: `userspace/nexusq-setupd/nexusq-setup-needed` (ExecCondition helper)
- Modify: `userspace/nexusq-setupd/tests/test_setupd.py` (add line-protocol framing tests)

**Interfaces:**
- Consumes: `SetupCore` (Task 4).
- Produces: `handle_line(core, line: str) -> str | None` — pure framing function (envelope parse → core.handle → response JSON), testable without D-Bus.
- Produces: systemd unit `nexusq-setupd.service` + `/usr/bin/nexusq-setup-needed`.

- [ ] **Step 1: Add the framing tests (failing)**

Append to `test_setupd.py`:
```python
class TestFraming(unittest.TestCase):
    def _core(self, mod):
        core = mod.SetupCore(run=mock.Mock(), led=mock.Mock(), bt_mac="F8:8F:CA:20:49:E5")
        return core

    def test_ok_response(self):
        mod = load_daemon()
        core = self._core(mod)
        resp = mod.handle_line(core, '{"id": 3, "method": "confirmColor"}')
        obj = json.loads(resp)
        self.assertEqual(obj, {"id": 3, "ok": True, "result": {"rgb": [0, 183, 255]}})

    def test_error_response(self):
        mod = load_daemon()
        core = self._core(mod)
        resp = mod.handle_line(core, '{"id": 4, "method": "nonsense"}')
        obj = json.loads(resp)
        self.assertFalse(obj["ok"])
        self.assertEqual(obj["error"]["code"], "unknown_method")

    def test_fire_and_forget_no_response(self):
        mod = load_daemon()
        core = self._core(mod)
        self.assertIsNone(mod.handle_line(core, '{"method": "confirmColor"}'))

    def test_garbage_line_ignored(self):
        mod = load_daemon()
        core = self._core(mod)
        self.assertIsNone(mod.handle_line(core, "{not json"))
```

Run: `python -m unittest discover -s userspace/nexusq-setupd/tests -v` → the 4 new tests FAIL (`handle_line` missing).

- [ ] **Step 2: Implement `handle_line` + the BlueZ transport**

Add to the daemon (framing, above `main()`):
```python
def handle_line(core, line):
    """One PROTOCOL.md envelope line -> response line (or None). Never raises:
    garbage is ignored, handler errors become error responses."""
    try:
        obj = json.loads(line)
    except ValueError:
        return None
    method = obj.get("method")
    rid = obj.get("id")
    if not isinstance(method, str):
        return None
    try:
        result = core.handle(method, obj.get("params"))
        resp = {"id": rid, "ok": True, "result": result}
    except Err as e:
        resp = {"id": rid, "ok": False, "error": {"code": e.code, "message": e.message}}
    except Exception as e:  # noqa: BLE001
        log("handler error:", method, e)
        resp = {"id": rid, "ok": False, "error": {"code": "internal", "message": str(e)}}
    return json.dumps(resp) if rid is not None else None
```

Replace the stub `main()` and add the D-Bus service classes (imports of `dbus` stay INSIDE this section so the test import path never needs dbus installed):
```python
def _run_transport():
    import dbus
    import dbus.service
    import dbus.mainloop.glib
    from gi.repository import GLib

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    core = SetupCore()
    loop = GLib.MainLoop()

    AGENT_PATH = "/org/nexusq/setup/agent"
    PROFILE_PATH = "/org/nexusq/setup/profile"

    class Agent(dbus.service.Object):
        """Just-Works auto-accept agent — active only while setupd runs."""

        @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
        def Release(self):
            pass

        @dbus.service.method("org.bluez.Agent1", in_signature="ou", out_signature="")
        def RequestConfirmation(self, device, passkey):
            log("pairing: auto-confirming", device)

        @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
        def RequestAuthorization(self, device):
            log("pairing: auto-authorizing", device)

        @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
        def AuthorizeService(self, device, uuid):
            log("service: auto-authorizing", device, uuid)

        @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
        def Cancel(self):
            pass

    class Profile(dbus.service.Object):
        """RFCOMM server profile: BlueZ listens and hands us the socket fd."""

        @dbus.service.method("org.bluez.Profile1", in_signature="oha{sv}", out_signature="")
        def NewConnection(self, device, fd, properties):
            raw = fd.take()
            log("RFCOMM connection from", device)
            t = threading.Thread(target=_client_loop, args=(raw,), daemon=True)
            t.start()

        @dbus.service.method("org.bluez.Profile1", in_signature="o", out_signature="")
        def RequestDisconnection(self, device):
            log("RFCOMM disconnect requested:", device)

        @dbus.service.method("org.bluez.Profile1", in_signature="", out_signature="")
        def Release(self):
            pass

    def _client_loop(raw_fd):
        sock = socket.socket(fileno=raw_fd)
        sock.settimeout(60)
        buf = b""
        try:
            while True:
                try:
                    chunk = sock.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    resp = handle_line(core, line.decode(errors="replace").strip())
                    if resp is not None:
                        sock.sendall((resp + "\n").encode())
                    if core.finished:
                        loop.quit()
                        return
        except OSError as e:
            log("client io error:", e)
        finally:
            sock.close()

    # adapter: powered + discoverable + pairable, no timeout while setup runs
    adapter = dbus.Interface(bus.get_object("org.bluez", "/org/bluez/hci0"),
                             "org.freedesktop.DBus.Properties")
    ident = {"name": "Nexus Q"}
    try:
        with open(IDENTITY_PATH) as f:
            j = json.load(f)
            if isinstance(j.get("name"), str) and j["name"].strip():
                ident["name"] = j["name"].strip()
    except (OSError, ValueError):
        pass
    adapter.Set("org.bluez.Adapter1", "Powered", dbus.Boolean(True))
    adapter.Set("org.bluez.Adapter1", "Alias", dbus.String(ident["name"]))
    adapter.Set("org.bluez.Adapter1", "DiscoverableTimeout", dbus.UInt32(0))
    adapter.Set("org.bluez.Adapter1", "PairableTimeout", dbus.UInt32(0))
    adapter.Set("org.bluez.Adapter1", "Pairable", dbus.Boolean(True))
    adapter.Set("org.bluez.Adapter1", "Discoverable", dbus.Boolean(True))

    agent = Agent(bus, AGENT_PATH)         # noqa: F841 (exported object)
    am = dbus.Interface(bus.get_object("org.bluez", "/org/bluez"),
                        "org.bluez.AgentManager1")
    am.RegisterAgent(AGENT_PATH, "NoInputNoOutput")
    am.RequestDefaultAgent(AGENT_PATH)

    profile = Profile(bus, PROFILE_PATH)   # noqa: F841 (exported object)
    pm = dbus.Interface(bus.get_object("org.bluez", "/org/bluez"),
                        "org.bluez.ProfileManager1")
    pm.RegisterProfile(PROFILE_PATH, SETUP_UUID, {
        "Name": dbus.String("NexusQ Setup"),
        "Role": dbus.String("server"),
        "Channel": dbus.UInt16(3),
        "RequireAuthentication": dbus.Boolean(True),
        "RequireAuthorization": dbus.Boolean(False),
    })

    core.led.send(SPIN_CMD)
    log("setup mode active: discoverable, RFCOMM profile", SETUP_UUID)

    def _idle_check():
        if core.finished:
            loop.quit()
            return False
        if time.monotonic() - core.last_activity > SETUP_TIMEOUT:
            log(f"inactive {SETUP_TIMEOUT:.0f}s -> leaving setup mode")
            loop.quit()
            return False
        return True

    GLib.timeout_add_seconds(15, _idle_check)

    try:
        loop.run()
    finally:
        # leave no setup residue: discoverable off, LED back to auto unless a
        # theme was chosen (finishSetup already applied it), force flag gone.
        try:
            adapter.Set("org.bluez.Adapter1", "Discoverable", dbus.Boolean(False))
        except Exception:  # noqa: BLE001
            pass
        if not core.finished:
            core.led.send("auto")
        try:
            os.unlink(FORCE_FLAG)
        except OSError:
            pass
    log("setup mode ended (finished=%s)" % core.finished)
    return 0


def main():
    return _run_transport()
```

- [ ] **Step 3: Run the tests**

Run: `python -m unittest discover -s userspace/nexusq-setupd/tests -v`
Expected: ALL pass (the dbus import is lazy; tests never reach it).

- [ ] **Step 4: The unit + condition helper**

`userspace/nexusq-setupd/nexusq-setup-needed`:
```sh
#!/bin/sh
# ExecCondition for nexusq-setupd: exit 0 => setup mode runs.
#  - forced (bridge startSetupMode touched the flag) -> run
#  - a WiFi NM profile exists (baked or provisioned)  -> don't run
[ -e /run/nexusq-setup.force ] && exit 0
if nmcli -t -f TYPE connection show 2>/dev/null | grep -q '^802-11-wireless$'; then
    exit 1
fi
exit 0
```

`userspace/nexusq-setupd/nexusq-setupd.service`:
```ini
[Unit]
Description=Nexus Q BT WiFi-provisioning (setup mode)
# BT + LED + NM must exist; none is a hard dep (setupd degrades gracefully).
After=bluetooth.service nexusqd.service NetworkManager.service
Wants=bluetooth.service

[Service]
Type=simple
ExecCondition=/usr/bin/nexusq-setup-needed
ExecStart=/usr/bin/nexusq-setupd
# One shot per trigger: it exits after finishSetup / inactivity; a crash
# restarts it (setup must survive daemon bugs while the user is mid-flow).
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 5: Commit**

```bash
git add userspace/nexusq-setupd
git commit -m "feat(setupd): BlueZ RFCOMM Profile1 transport, Just-Works agent, setup-mode lifecycle"
```

---

### Task 6: nexusq-setupd packaging (aport + staging + device wiring)

**Files:**
- Create: `pmos/nexusq-setupd/APKBUILD`
- Modify: `docker-build.sh` (stage the new aport — mirror the `nexusq-control` block at lines ~228–236, and add the APKBUILD to the syntax-check list at line ~25 and to the `dos2unix` find at line ~257)
- Modify: `pmos/device-google-steelhead/APKBUILD` (depends += `nexusq-setupd`; pkgrel bump — merge with Task 2's bump if executed together)
- Modify: `pmos/device-google-steelhead/nexusq.preset` (add `enable nexusq-setupd.service`)

**Interfaces:**
- Consumes: Task 5 files.
- Produces: `nexusq-setupd` apk installable on the image; unit enabled via preset.

- [ ] **Step 1: Write the APKBUILD**

`pmos/nexusq-setupd/APKBUILD`:
```sh
# Nexus Q BT WiFi-provisioning daemon — Python, BlueZ D-Bus Profile1 RFCOMM
# carrying the companion PROTOCOL.md envelope (§8 Setup transport). Runs only
# in setup mode (no WiFi profile / forced via the bridge startSetupMode).
pkgname=nexusq-setupd
pkgver=0.1.0
pkgrel=0
pkgdesc="Nexus Q BT RFCOMM WiFi-provisioning daemon (setup mode)"
url="https://github.com/petronijus/nexusQ-reloaded"
arch="noarch"
license="GPL-2.0-only"
# py3-dbus + py3-gobject3: BlueZ Profile1/Agent1 (fd-passing RFCOMM server —
# no stdlib path exists). networkmanager-cli: nmcli. bluez: the daemon.
depends="python3 py3-dbus py3-gobject3 networkmanager-cli bluez"
options="!check"
# Staged flat next to this APKBUILD by docker-build.sh from userspace/nexusq-setupd/.
source="
	nexusq-setupd nexusq-setupd.service nexusq-setup-needed
"
builddir="$srcdir"

package() {
	install -Dm755 nexusq-setupd "$pkgdir"/usr/bin/nexusq-setupd
	install -Dm755 nexusq-setup-needed "$pkgdir"/usr/bin/nexusq-setup-needed
	install -Dm644 nexusq-setupd.service \
		"$pkgdir"/usr/lib/systemd/system/nexusq-setupd.service
}

sha512sums="SKIP"
```
(No wants symlink here: enablement comes from the 95-nexusq.preset — the vendor-unit preset gotcha documented in the device APKBUILD lines 347–365.)

- [ ] **Step 2: docker-build.sh staging**

After the nexusq-control staging block (line ~236), add (match the surrounding style exactly):
```sh
# nexusq-setupd: the BT provisioning daemon (pure staging, like nexusq-control).
NEXUSQSETUP_DIR="$PMAPORTS/main/nexusq-setupd"
mkdir -p "$NEXUSQSETUP_DIR"
cp "$SRC/pmos/nexusq-setupd/APKBUILD"                     "$NEXUSQSETUP_DIR/"
cp "$SRC/userspace/nexusq-setupd/nexusq-setupd"           "$NEXUSQSETUP_DIR/"
cp "$SRC/userspace/nexusq-setupd/nexusq-setupd.service"   "$NEXUSQSETUP_DIR/"
cp "$SRC/userspace/nexusq-setupd/nexusq-setup-needed"     "$NEXUSQSETUP_DIR/"
echo "  Installed: nexusq-setupd (aport + daemon -> main/nexusq-setupd)"
```
Add `"$SRC/pmos/nexusq-setupd/APKBUILD"` to the syntax-check loop (line ~25), add `"$NEXUSQSETUP_DIR"` to the `dos2unix` find roots (line ~257) and `-o -name "nexusq-setupd" -o -name "nexusq-setup-needed"` to its name filters.

- [ ] **Step 3: Device package wiring**

- `pmos/device-google-steelhead/APKBUILD`: add `nexusq-setupd` to `depends` (after `nexusq-control`); bump pkgrel.
- `pmos/device-google-steelhead/nexusq.preset`: append line `enable nexusq-setupd.service`.

- [ ] **Step 4: Verify shell syntax of the touched scripts**

Run: `bash -n docker-build.sh && sh -n pmos/nexusq-setupd/APKBUILD && sh -n userspace/nexusq-setupd/nexusq-setup-needed`
Expected: no output (all parse).

- [ ] **Step 5: Commit**

```bash
git add pmos/nexusq-setupd docker-build.sh pmos/device-google-steelhead
git commit -m "feat(setupd): package + stage nexusq-setupd, enable via preset"
```

---

### Task 7: NFC payload = connection info (device side)

**Files:**
- Modify: `pmos/device-google-steelhead/nexusq-nfc-send`
- Create: `pmos/device-google-steelhead/tests/test_nfc_payload.py`
- Modify: `pmos/device-google-steelhead/APKBUILD` (pkgrel bump — merge with earlier bumps if in one build)
- Modify: `companion/PROTOCOL.md` §7 (payload is now the connection-info JSON)

**Interfaces:**
- Produces (wire, consumed by Task 8): compact JSON APDU payload
  `{"v":1,"bt":"F8:8F:CA:20:49:E5","host":"steelhead","ip":"192.168.20.195"|null,"prov":true|false}` (≤ 250 bytes).
- Produces: `build_payload(run, gethostname, read_bt_mac) -> bytes` (injectable for tests).

- [ ] **Step 1: Write the failing test**

`pmos/device-google-steelhead/tests/test_nfc_payload.py`:
```python
import importlib.util
import importlib.machinery
import json
import os
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-nfc-send")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nq_nfc", importlib.machinery.SourceFileLoader("nq_nfc", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestPayload(unittest.TestCase):
    def test_provisioned_with_ip(self):
        mod = load_daemon()
        def run(args, **kw):
            if "IP4.ADDRESS" in args:
                return mock.Mock(returncode=0, stdout="192.168.20.195/24\n")
            return mock.Mock(returncode=0, stdout="802-11-wireless\n")
        raw = mod.build_payload(run=run, gethostname=lambda: "steelhead",
                                read_bt_mac=lambda: "F8:8F:CA:20:49:E5")
        obj = json.loads(raw.decode())
        self.assertEqual(obj, {"v": 1, "bt": "F8:8F:CA:20:49:E5",
                               "host": "steelhead", "ip": "192.168.20.195",
                               "prov": True})
        self.assertLessEqual(len(raw), 250)

    def test_unprovisioned_no_ip(self):
        mod = load_daemon()
        def run(args, **kw):
            return mock.Mock(returncode=0, stdout="")
        obj = json.loads(mod.build_payload(
            run=run, gethostname=lambda: "steelhead",
            read_bt_mac=lambda: "F8:8F:CA:20:49:E5").decode())
        self.assertIsNone(obj["ip"])
        self.assertFalse(obj["prov"])

    def test_resilient_to_failures(self):
        mod = load_daemon()
        def run(args, **kw):
            raise OSError("no nmcli")
        obj = json.loads(mod.build_payload(
            run=run, gethostname=lambda: "steelhead",
            read_bt_mac=lambda: "").decode())
        self.assertEqual(obj["v"], 1)   # still a valid payload


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it**

Run: `python -m unittest discover -s pmos/device-google-steelhead/tests -v`
Expected: FAIL — `build_payload` missing.

- [ ] **Step 3: Implement in `nexusq-nfc-send`**

Add `import json, subprocess` to the imports, and above `main()`:
```python
def _read_bt_mac():
    try:
        with open("/sys/class/bluetooth/hci0/address") as f:
            return f.read().strip().upper()
    except OSError:
        return ""


def build_payload(run=None, gethostname=None, read_bt_mac=None):
    """Connection info for the tap (PROTOCOL.md §7): the app parses this to
    auto-connect (prov=true -> LAN by ip/mdns; prov=false -> BT setup by bt).
    Resilient: every lookup degrades to null/false, never raises."""
    run = run or (lambda a, **kw: subprocess.run(a, capture_output=True, text=True, timeout=5))
    gethostname = gethostname or socket.gethostname
    read_bt_mac = read_bt_mac or _read_bt_mac
    ip, prov = None, False
    try:
        r = run(["nmcli", "-g", "IP4.ADDRESS", "dev", "show", "wlan0"])
        if r.returncode == 0 and r.stdout.strip():
            ip = r.stdout.strip().splitlines()[0].split("/")[0]
    except Exception:  # noqa: BLE001
        pass
    try:
        r = run(["nmcli", "-t", "-f", "TYPE", "connection", "show"])
        prov = r.returncode == 0 and "802-11-wireless" in r.stdout
    except Exception:  # noqa: BLE001
        pass
    return json.dumps({"v": 1, "bt": read_bt_mac(), "host": gethostname(),
                       "ip": ip, "prov": prov}, separators=(",", ":")).encode()
```
Note `import socket` already exists in the file.

In `main()`, replace the static-text selection:
```python
    # NQ_NFC_MESSAGE / argv override kept for testing; default = live
    # connection info, rebuilt fresh at every tap (ip/prov change over time).
    override = os.environ.get("NQ_NFC_MESSAGE") or (sys.argv[1] if len(sys.argv) > 1 else None)
    text = override.encode() if override else None
```
and at both call sites of `send_to_target(...)` pass `text if text is not None else build_payload()` instead of `text` (payload built per tap, not once at start).

- [ ] **Step 4: Re-run the tests**

Run: `python -m unittest discover -s pmos/device-google-steelhead/tests -v`
Expected: 3 PASS.

- [ ] **Step 5: PROTOCOL.md §7 — replace the "Payload today" bullet**

```markdown
- **Payload** (since step-1 onboarding): compact JSON connection info, rebuilt per tap:
  `{"v":1,"bt":"<BT MAC>","host":"<hostname>","ip":"<wlan0 IPv4>"|null,"prov":true|false}`.
  The app parses it: `prov=false` → jump into the setup wizard and connect over BT to `bt`;
  `prov=true` → connect over LAN to `ip` (fallback `<host>.local`). A non-JSON payload is
  still displayed as a plain text SnackBar (`NQ_NFC_MESSAGE` override, older devices).
```

- [ ] **Step 6: Commit**

```bash
git add pmos/device-google-steelhead companion/PROTOCOL.md
git commit -m "feat(nfc): tap payload = live connection info (closes the standing backlog item)"
```

---

### Task 8: App — NFC payload parsing + tap routing

**Files:**
- Create: `companion/app/lib/nfc/device_tap.dart`
- Create: `companion/app/test/device_tap_test.dart`
- Modify: `companion/app/lib/nfc/hce_listener.dart` (parse; route instead of SnackBar for JSON payloads)
- Modify: `companion/app/lib/main.dart` (pass a navigator key + tap callback)

**Interfaces:**
- Produces: `DeviceTap.tryParse(String text) -> DeviceTap?` with fields `btMac`, `host`, `ip`, `provisioned`.
- Consumes (Task 13 wires the actual navigation): `HceListener(onDeviceTap: void Function(DeviceTap))` — until Task 13, the callback shows a SnackBar "Nexus Q found via tap".

- [ ] **Step 1: Failing Dart test**

`companion/app/test/device_tap_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/nfc/device_tap.dart';

void main() {
  test('parses provisioned payload', () {
    final t = DeviceTap.tryParse(
        '{"v":1,"bt":"F8:8F:CA:20:49:E5","host":"steelhead","ip":"192.168.20.195","prov":true}');
    expect(t, isNotNull);
    expect(t!.btMac, 'F8:8F:CA:20:49:E5');
    expect(t.ip, '192.168.20.195');
    expect(t.provisioned, isTrue);
  });

  test('parses unprovisioned payload with null ip', () {
    final t = DeviceTap.tryParse(
        '{"v":1,"bt":"F8:8F:CA:20:49:E5","host":"steelhead","ip":null,"prov":false}');
    expect(t!.ip, isNull);
    expect(t.provisioned, isFalse);
  });

  test('rejects plain text and wrong version', () {
    expect(DeviceTap.tryParse('Ahoj z Nexus Q!'), isNull);
    expect(DeviceTap.tryParse('{"v":2,"bt":"x"}'), isNull);
  });
}
```

Run: `flutter test test/device_tap_test.dart` (in `companion/app/`) — FAIL (missing file).

- [ ] **Step 2: Implement `device_tap.dart`**

```dart
import 'dart:convert';

/// Parsed NFC tap payload (PROTOCOL.md §7): the Q's connection info.
class DeviceTap {
  DeviceTap({required this.btMac, required this.host, this.ip, required this.provisioned});

  final String btMac;
  final String host;
  final String? ip;
  final bool provisioned;

  /// Returns null for non-JSON / unknown-version payloads (those remain
  /// plain-text messages shown as a SnackBar).
  static DeviceTap? tryParse(String text) {
    if (!text.trimLeft().startsWith('{')) return null;
    try {
      final obj = jsonDecode(text);
      if (obj is! Map<String, dynamic> || obj['v'] != 1) return null;
      return DeviceTap(
        btMac: (obj['bt'] as String?) ?? '',
        host: (obj['host'] as String?) ?? '',
        ip: obj['ip'] as String?,
        provisioned: obj['prov'] == true,
      );
    } on FormatException {
      return null;
    }
  }
}
```

- [ ] **Step 3: Run the test — PASS. Then route in `hce_listener.dart`**

Add to `HceListener` a field `final void Function(DeviceTap tap)? onDeviceTap;` (constructor param), `import 'device_tap.dart';`, and change `_show`:
```dart
  void _show(HceMessage msg) {
    final tap = DeviceTap.tryParse(msg.text);
    if (tap != null && widget.onDeviceTap != null) {
      widget.onDeviceTap!(tap);
      return;
    }
    // ... existing SnackBar code unchanged ...
  }
```
In `main.dart`, pass a placeholder that keeps behavior working until Task 13:
```dart
      home: HceListener(
        messengerKey: _messengerKey,
        onDeviceTap: (tap) {
          _messengerKey.currentState?.showSnackBar(SnackBar(
              content: Text('Nexus Q found via tap (${tap.provisioned ? "on LAN" : "needs setup"})')));
        },
        child: ConnectGate(initialClient: initialClient),
      ),
```

- [ ] **Step 4: `flutter analyze` + `flutter test`**

Run in `companion/app/`: `flutter analyze && flutter test`
Expected: no analyzer errors, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add companion/app
git commit -m "feat(app): parse NFC connection-info payload, tap routing hook"
```

---

### Task 9: App — Kotlin BT RFCOMM platform channel

**Files:**
- Create: `companion/app/android/app/src/main/kotlin/org/nexusq/nexusq_companion/BtSetupChannel.kt`
- Modify: `companion/app/android/app/src/main/kotlin/org/nexusq/nexusq_companion/MainActivity.kt` (register the channel; forward permission results)
- Modify: `companion/app/android/app/src/main/AndroidManifest.xml` (BT permissions)

**Interfaces:**
- Produces (consumed by Task 10's Dart client):
  - MethodChannel `nexusq/btsetup`: `ensurePermissions() -> bool`, `startScan()`, `stopScan()`, `connect(mac: String) -> bool` (blocking until connected/failed), `sendLine(line: String)`, `disconnect()`.
  - EventChannel `nexusq/btsetup/events` streaming maps: `{type:"scan", name, mac}`, `{type:"line", line}`, `{type:"state", connected: bool}`.
- Service UUID constant `8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a` (global constraint).

- [ ] **Step 1: Manifest permissions**

In `AndroidManifest.xml` add above `<application>`:
```xml
    <!-- BT Classic setup transport (RFCOMM provisioning). maxSdkVersion pair
         covers pre-S devices; S+ uses the runtime BLUETOOTH_SCAN/CONNECT. -->
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
```

- [ ] **Step 2: Implement `BtSetupChannel.kt`**

```kotlin
package org.nexusq.nexusq_companion

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.UUID
import kotlin.concurrent.thread

/**
 * BT Classic RFCOMM transport for device setup (PROTOCOL.md §8).
 * One connection at a time; newline-JSON lines are relayed verbatim to Dart.
 */
class BtSetupChannel(private val activity: Activity, messenger: BinaryMessenger) {

    companion object {
        private const val TAG = "BtSetupChannel"
        const val PERMISSION_REQUEST = 0x4251
        val SETUP_UUID: UUID = UUID.fromString("8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a")
    }

    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null
    private var socket: BluetoothSocket? = null
    private var scanReceiver: BroadcastReceiver? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    private val adapter: BluetoothAdapter?
        get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    init {
        MethodChannel(messenger, "nexusq/btsetup").setMethodCallHandler { call, result ->
            when (call.method) {
                "ensurePermissions" -> ensurePermissions(result)
                "startScan" -> { startScan(); result.success(null) }
                "stopScan" -> { stopScan(); result.success(null) }
                "connect" -> connect(call.argument<String>("mac")!!, result)
                "sendLine" -> sendLine(call.argument<String>("line")!!, result)
                "disconnect" -> { disconnect(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "nexusq/btsetup/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) { events = sink }
                override fun onCancel(args: Any?) { events = null }
            })
    }

    private fun emit(map: Map<String, Any?>) = main.post { events?.success(map) }

    // --- permissions -----------------------------------------------------
    private fun neededPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        else
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun hasPermissions() = neededPermissions().all {
        ActivityCompat.checkSelfPermission(activity, it) == PackageManager.PERMISSION_GRANTED
    }

    private fun ensurePermissions(result: MethodChannel.Result) {
        if (hasPermissions()) { result.success(true); return }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(activity, neededPermissions(), PERMISSION_REQUEST)
    }

    /** Call from MainActivity.onRequestPermissionsResult. */
    fun onPermissionResult(requestCode: Int) {
        if (requestCode != PERMISSION_REQUEST) return
        pendingPermissionResult?.success(hasPermissions())
        pendingPermissionResult = null
    }

    // --- discovery -------------------------------------------------------
    @SuppressLint("MissingPermission")
    private fun startScan() {
        val ad = adapter ?: return
        stopScan()
        val recv = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) {
                if (i?.action != BluetoothDevice.ACTION_FOUND) return
                val dev: BluetoothDevice = i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE) ?: return
                emit(mapOf("type" to "scan", "name" to (dev.name ?: ""), "mac" to dev.address))
            }
        }
        activity.registerReceiver(recv, IntentFilter(BluetoothDevice.ACTION_FOUND))
        scanReceiver = recv
        ad.startDiscovery()
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        scanReceiver?.let { runCatching { activity.unregisterReceiver(it) } }
        scanReceiver = null
        adapter?.cancelDiscovery()
    }

    // --- connection ------------------------------------------------------
    @SuppressLint("MissingPermission")
    private fun connect(mac: String, result: MethodChannel.Result) {
        val ad = adapter
        if (ad == null) { result.error("no_bt", "Bluetooth unavailable", null); return }
        disconnect()
        stopScan()   // discovery kills RFCOMM connect reliability
        thread(name = "bt-setup-connect") {
            try {
                val dev = ad.getRemoteDevice(mac)
                val sock = dev.createRfcommSocketToServiceRecord(SETUP_UUID)
                sock.connect()   // triggers Just-Works pairing on first contact
                socket = sock
                emit(mapOf("type" to "state", "connected" to true))
                main.post { result.success(true) }
                readerLoop(sock)
            } catch (e: Exception) {
                Log.w(TAG, "connect failed", e)
                emit(mapOf("type" to "state", "connected" to false))
                main.post { result.error("connect_failed", e.message, null) }
            }
        }
    }

    private fun readerLoop(sock: BluetoothSocket) {
        try {
            val reader = BufferedReader(InputStreamReader(sock.inputStream, Charsets.UTF_8))
            while (true) {
                val line = reader.readLine() ?: break
                emit(mapOf("type" to "line", "line" to line))
            }
        } catch (e: Exception) {
            Log.d(TAG, "reader ended: ${e.message}")
        } finally {
            emit(mapOf("type" to "state", "connected" to false))
            runCatching { sock.close() }
            if (socket === sock) socket = null
        }
    }

    private fun sendLine(line: String, result: MethodChannel.Result) {
        val sock = socket
        if (sock == null) { result.error("not_connected", "no RFCOMM connection", null); return }
        thread(name = "bt-setup-send") {
            try {
                sock.outputStream.write((line + "\n").toByteArray(Charsets.UTF_8))
                sock.outputStream.flush()
                main.post { result.success(null) }
            } catch (e: Exception) {
                main.post { result.error("send_failed", e.message, null) }
            }
        }
    }

    fun disconnect() {
        socket?.let { runCatching { it.close() } }
        socket = null
    }
}
```

- [ ] **Step 3: Register in `MainActivity.kt`**

Add a field + wiring:
```kotlin
    private var btSetup: BtSetupChannel? = null
```
in `configureFlutterEngine` (after the existing channels):
```kotlin
        btSetup = BtSetupChannel(this, messenger)
```
and the override:
```kotlin
    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        btSetup?.onPermissionResult(requestCode)
    }
```

- [ ] **Step 4: Build check**

Run in `companion/app/`: `flutter build apk --debug`
Expected: BUILD SUCCESSFUL (Kotlin compiles; no Dart consumer yet).

- [ ] **Step 5: Commit**

```bash
git add companion/app/android
git commit -m "feat(app): Kotlin BT RFCOMM setup channel (scan/connect/lines)"
```

---

### Task 10: App — Dart BT setup client + pairing-color parity

**Files:**
- Create: `companion/app/lib/setup/bt_setup_client.dart`
- Create: `companion/app/lib/setup/pairing_color.dart`
- Create: `companion/app/test/pairing_color_test.dart`
- Create: `companion/app/test/bt_setup_client_test.dart`

**Interfaces:**
- Consumes: Task 9 channels.
- Produces: `BtSetupClient` — `ensurePermissions()`, `scan() -> Stream<BtScanResult>`, `connect(mac)`, `call(method, [params]) -> Future<Map>` (PROTOCOL envelope with id correlation + 30 s timeout; setWifi 100 s), `lines`/`connected` streams, `disconnect()`.
- Produces: `Color pairingColor(String mac)` (same contract as Task 3/4).

- [ ] **Step 1: Failing tests**

`companion/app/test/pairing_color_test.dart`:
```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/setup/pairing_color.dart';

void main() {
  test('matches the shared vectors', () {
    final raw = File('../pairing-color-vectors.json').readAsStringSync();
    final vectors = (jsonDecode(raw)['vectors'] as List).cast<Map<String, dynamic>>();
    for (final v in vectors) {
      final rgb = (v['rgb'] as List).cast<int>();
      final c = pairingColor(v['mac'] as String);
      expect(c, Color.fromARGB(255, rgb[0], rgb[1], rgb[2]), reason: v['mac'] as String);
    }
  });
}
```
Note the relative path: `flutter test` runs with CWD `companion/app`, the vectors live at `companion/pairing-color-vectors.json` → `../pairing-color-vectors.json`.

`companion/app/test/bt_setup_client_test.dart`:
```dart
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/setup/bt_setup_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('call correlates ids and decodes result', () async {
    final client = BtSetupClient();
    final sent = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nexusq/btsetup'), (call) async {
      if (call.method == 'sendLine') {
        sent.add(call.arguments['line'] as String);
        return null;
      }
      return null;
    });

    final future = client.call('confirmColor');
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(1));
    final req = jsonDecode(sent.single) as Map<String, dynamic>;
    expect(req['method'], 'confirmColor');

    // Simulate the device response arriving on the event stream.
    client.handleEventForTest({
      'type': 'line',
      'line': jsonEncode({'id': req['id'], 'ok': true, 'result': {'rgb': [0, 183, 255]}}),
    });
    final result = await future;
    expect(result['rgb'], [0, 183, 255]);
  });

  test('error response throws BtSetupError', () async {
    final client = BtSetupClient();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nexusq/btsetup'), (call) async => null);
    final future = client.call('setWifi', {'ssid': 'x', 'psk': 'bad'});
    await Future<void>.delayed(Duration.zero);
    client.handleEventForTest({
      'type': 'line',
      'line': jsonEncode({'id': 1, 'ok': false,
        'error': {'code': 'wrong_password', 'message': 'wifi join failed'}}),
    });
    await expectLater(future, throwsA(isA<BtSetupError>()
        .having((e) => e.code, 'code', 'wrong_password')));
  });
}
```
(`handleEventForTest` = a public test hook that feeds the same internal event handler the EventChannel feeds; the id counter starts at 1.)

Run: `flutter test test/pairing_color_test.dart test/bt_setup_client_test.dart` → FAIL (files missing).

- [ ] **Step 2: Implement `pairing_color.dart`**

```dart
import 'dart:ui';

/// LED visual-pairing color from the BT MAC. Contract + shared vectors:
/// companion/pairing-color-vectors.json (device twin: nexusq-setupd
/// pairing_color()).
Color pairingColor(String mac) {
  final b = mac.split(':').map((x) => int.parse(x, radix: 16)).toList();
  final hue = ((b[4] << 8) | b[5]) % 360;
  const c = 1.0;
  final x = 1.0 - ((hue / 60.0) % 2.0 - 1.0).abs();
  final sect = hue ~/ 60;
  final f = [
    [c, x, 0.0], [x, c, 0.0], [0.0, c, x],
    [0.0, x, c], [x, 0.0, c], [c, 0.0, x],
  ][sect];
  int ch(double v) => (v * 255 + 0.5).floor();
  return Color.fromARGB(255, ch(f[0]), ch(f[1]), ch(f[2]));
}
```

- [ ] **Step 3: Implement `bt_setup_client.dart`**

```dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

class BtScanResult {
  BtScanResult(this.name, this.mac);
  final String name;
  final String mac;
}

class BtSetupError implements Exception {
  BtSetupError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'BtSetupError($code): $message';
}

/// PROTOCOL.md envelope over the BT RFCOMM platform channel (Task 9).
/// Same request/response semantics as TcpClient, different transport.
class BtSetupClient {
  static const _method = MethodChannel('nexusq/btsetup');
  static const _events = EventChannel('nexusq/btsetup/events');

  BtSetupClient() {
    _sub = _events.receiveBroadcastStream().listen((e) => _onEvent((e as Map).cast<String, dynamic>()));
  }

  StreamSubscription? _sub;
  int _nextId = 1;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _scan = StreamController<BtScanResult>.broadcast();
  final _connected = StreamController<bool>.broadcast();

  Stream<BtScanResult> get scanResults => _scan.stream;
  Stream<bool> get connected => _connected.stream;

  Future<bool> ensurePermissions() async =>
      await _method.invokeMethod<bool>('ensurePermissions') ?? false;

  Future<void> startScan() => _method.invokeMethod('startScan');
  Future<void> stopScan() => _method.invokeMethod('stopScan');

  Future<void> connect(String mac) async {
    await _method.invokeMethod('connect', {'mac': mac});
  }

  Future<void> disconnect() async {
    await _method.invokeMethod('disconnect');
  }

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final line = jsonEncode({
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    });
    _method.invokeMethod('sendLine', {'line': line}).catchError((Object e) {
      _pending.remove(id)?.completeError(BtSetupError('send_failed', '$e'));
    });
    // setWifi legitimately takes up to ~90 s on the device (nmcli --wait).
    final timeout = method == 'setWifi' ? const Duration(seconds: 100) : const Duration(seconds: 30);
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw BtSetupError('timeout', '$method timed out');
    });
  }

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'scan':
        _scan.add(BtScanResult((e['name'] as String?) ?? '', e['mac'] as String));
      case 'state':
        _connected.add(e['connected'] == true);
      case 'line':
        _onLine(e['line'] as String);
    }
  }

  void _onLine(String line) {
    final Object obj;
    try {
      obj = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (obj is! Map<String, dynamic>) return;
    final id = obj['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (obj['ok'] == true) {
      completer.complete((obj['result'] as Map?)?.cast<String, dynamic>() ?? const {});
    } else {
      final err = (obj['error'] as Map?)?.cast<String, dynamic>() ?? const {};
      completer.completeError(BtSetupError(
          (err['code'] as String?) ?? 'internal', (err['message'] as String?) ?? ''));
    }
  }

  /// Test hook: inject an event as if it came from the EventChannel.
  void handleEventForTest(Map<String, dynamic> e) => _onEvent(e);

  void dispose() {
    _sub?.cancel();
    _scan.close();
    _connected.close();
  }
}
```

- [ ] **Step 4: Run the tests**

Run in `companion/app/`: `flutter analyze && flutter test`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add companion/app
git commit -m "feat(app): Dart BT setup client + pairing-color parity with device"
```

---

### Task 11: Stock-asset extraction pipeline

**Files:**
- Create: `scripts/extract-stock-assets.sh`
- Create: `companion/app/lib/setup/stock_assets.dart`
- Modify: `companion/app/pubspec.yaml` (register `assets/stock/`)
- Modify: `.gitignore` (add `companion/app/assets/stock/`)

**Interfaces:**
- Produces: `companion/app/assets/stock/` populated from `private/nexusq-original/companion/apktool/res/` — `drawable/` (q000–q035, cables, wifi + room icons), `raw/` (theme_*, q_outro.mp4, polaris.ogg).
- Produces: `StockAssets.available` (bool, set at app start), `stockImage(String name, {IconData fallback})` widget helper.

- [ ] **Step 1: Write the script**

`scripts/extract-stock-assets.sh`:
```bash
#!/usr/bin/env bash
# Extract the ORIGINAL Nexus Q companion-app imagery from the decompiled stock
# APK (private/nexusq-original — Google copyright, NEVER committed) into the
# Flutter app's gitignored assets/stock/. Public builds without private/ get
# the in-app icon fallbacks (lib/setup/stock_assets.dart).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-private/nexusq-original/companion/apktool/res}"
DEST="companion/app/assets/stock"

if [ ! -d "$SRC" ]; then
    echo "extract-stock-assets: $SRC not found — building WITHOUT stock assets (fallback icons)."
    mkdir -p "$DEST"
    exit 0
fi

# Prefer the highest density available for each drawable.
pick() { # pick <basename.png> -> echoes the source path or nothing
    for d in drawable-xhdpi drawable-hdpi drawable-mdpi drawable; do
        [ -f "$SRC/$d/$1" ] && { echo "$SRC/$d/$1"; return 0; }
    done
    return 1
}

mkdir -p "$DEST/drawable" "$DEST/raw"
missing=0

want_drawables=(
    setup_static.png ic_q_welcome.png ic_splash_drop.png
    cables_diagram_01.png cables_diagram_02.png
    ic_bt_config.png
)
for i in $(seq -w 0 35); do want_drawables+=("q0$i.png"); done
for w in 1 2 3 4; do
    want_drawables+=("ic_wifi_signal_$w.png" "ic_wifi_signal_lock_$w.png")
done
for room in bedroom kitchen livingroom bathroom closet diningroom familyroom garage mediaroom office; do
    want_drawables+=("ic_menu_location_$room.png")
done

for f in "${want_drawables[@]}"; do
    if src=$(pick "$f"); then cp "$src" "$DEST/drawable/$f"
    else echo "  missing drawable: $f"; missing=$((missing+1)); fi
done

want_raw=(theme_blue theme_cool theme_smoke theme_spectrum theme_warm theme_trackinfo theme_off q_outro.mp4 polaris.ogg)
for f in "${want_raw[@]}"; do
    if [ -f "$SRC/raw/$f" ]; then cp "$SRC/raw/$f" "$DEST/raw/$f"
    else echo "  missing raw: $f"; missing=$((missing+1)); fi
done

echo "extract-stock-assets: done ($(find "$DEST" -type f | wc -l) files, $missing missing)"
```

- [ ] **Step 2: Run it and verify**

Run: `bash scripts/extract-stock-assets.sh`
Expected: `done (60+ files, 0 missing)` on this machine (private/ present). If specific names are missing, check the actual filenames under `private/nexusq-original/companion/apktool/res/drawable-*/` and correct the `want_*` lists — the research inventory may differ from apktool's exact naming; the list in the script is the contract.

- [ ] **Step 3: pubspec + gitignore + fallback helper**

`pubspec.yaml` — under `flutter:` add:
```yaml
  assets:
    - assets/stock/drawable/
    - assets/stock/raw/
```
`.gitignore` — add the line `companion/app/assets/stock/`.
Note: Flutter errors on a registered-but-absent asset DIRECTORY at build time; the script's `mkdir -p "$DEST"` (fallback branch) plus a `.gitkeep`-less empty dir is enough — verify `flutter build apk --debug` works right after `rm -rf companion/app/assets/stock && mkdir -p companion/app/assets/stock/drawable companion/app/assets/stock/raw` (empty dirs). If Flutter still balks, have the script always `touch "$DEST/drawable/.keep" "$DEST/raw/.keep"` and register those paths.

`companion/app/lib/setup/stock_assets.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Loader for the (gitignored) original stock imagery. When the assets were
/// not extracted (public checkout without private/), every screen falls back
/// to Material icons — the wizard must work either way.
class StockAssets {
  static bool available = false;

  /// Call once at app start: probe one sentinel asset.
  static Future<void> init() async {
    try {
      await rootBundle.load('assets/stock/drawable/setup_static.png');
      available = true;
    } catch (_) {
      available = false;
    }
  }
}

/// A stock drawable by basename, or [fallback] icon when unavailable.
Widget stockImage(String name,
    {double? width, double? height, IconData fallback = Icons.image, Color? color}) {
  if (!StockAssets.available) {
    return Icon(fallback, size: width ?? height ?? 48, color: color);
  }
  return Image.asset('assets/stock/drawable/$name',
      width: width, height: height, fit: BoxFit.contain);
}
```
In `main.dart`, make `main()` async and call `await StockAssets.init();` before `runApp` (add `WidgetsFlutterBinding.ensureInitialized();` first).

- [ ] **Step 4: Build check both ways**

Run in `companion/app/`: `flutter build apk --debug` with assets present, then repeat after emptying `assets/stock/` (keep the dirs), then re-run the extraction script to restore.
Expected: both builds succeed.

- [ ] **Step 5: Commit**

```bash
git add scripts/extract-stock-assets.sh companion/app/pubspec.yaml .gitignore companion/app/lib/setup/stock_assets.dart companion/app/lib/main.dart
git commit -m "feat(app): stock-asset extraction pipeline with icon fallbacks"
```

---

### Task 12: Setup wizard — flow shell + device discovery + color confirm + WiFi

**Files:**
- Create: `companion/app/lib/setup/setup_flow.dart` (flow state + PageView shell)
- Create: `companion/app/lib/setup/screens/welcome_screen.dart`
- Create: `companion/app/lib/setup/screens/cables_screen.dart`
- Create: `companion/app/lib/setup/screens/find_device_screen.dart`
- Create: `companion/app/lib/setup/screens/confirm_color_screen.dart`
- Create: `companion/app/lib/setup/screens/wifi_screen.dart`
- Create: `companion/app/test/setup_flow_test.dart`

**Interfaces:**
- Consumes: `BtSetupClient` (Task 10), `stockImage`/`StockAssets` (Task 11), `pairingColor` (Task 10).
- Produces: `SetupFlow(initialMac: String?)` widget — pushable route; `SetupFlowState` (`ChangeNotifier`) holding `client`, `deviceMac`, `wifiResult` (`{ip, mdns}`), `deviceName`, `room`, `theme` — consumed by Task 13's screens.
- Wizard page order: welcome → cables → find (skipped when `initialMac != null`) → confirmColor → wifi → **(Task 13: name/room → theme → outro)**.

- [ ] **Step 1: Failing widget test**

`companion/app/test/setup_flow_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/setup/setup_flow.dart';

void main() {
  testWidgets('wizard starts on Welcome and advances to Cables', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SetupFlow()));
    expect(find.text('Set up your Nexus Q'), findsOneWidget);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(find.text('Connect your Nexus Q'), findsOneWidget);
  });

  testWidgets('NFC-tapped mac skips the find screen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SetupFlow(initialMac: 'F8:8F:CA:20:49:E5')));
    final state = tester.state<SetupFlowScreenState>(find.byType(SetupFlow));
    expect(state.flow.deviceMac, 'F8:8F:CA:20:49:E5');
  });
}
```

Run: `flutter test test/setup_flow_test.dart` → FAIL.

- [ ] **Step 2: Implement the flow shell**

`companion/app/lib/setup/setup_flow.dart`:
```dart
import 'package:flutter/material.dart';
import '../theme/nexusq_theme.dart';
import 'bt_setup_client.dart';
import 'screens/welcome_screen.dart';
import 'screens/cables_screen.dart';
import 'screens/find_device_screen.dart';
import 'screens/confirm_color_screen.dart';
import 'screens/wifi_screen.dart';

/// Shared wizard state. Screens mutate it and call [next]/[back].
class SetupFlowState extends ChangeNotifier {
  SetupFlowState({String? initialMac}) : deviceMac = initialMac;

  final client = BtSetupClient();
  String? deviceMac;          // chosen/NFC-provided device
  Map<String, dynamic>? wifiResult;   // {ip, mdns} after setWifi ok
  String deviceName = 'Nexus Q';
  String room = '';
  String? theme;

  @override
  void dispose() {
    client.disconnect();
    client.dispose();
    super.dispose();
  }
}

class SetupFlow extends StatefulWidget {
  const SetupFlow({super.key, this.initialMac});
  final String? initialMac;

  @override
  State<SetupFlow> createState() => SetupFlowScreenState();
}

class SetupFlowScreenState extends State<SetupFlow> {
  late final SetupFlowState flow = SetupFlowState(initialMac: widget.initialMac);
  final _page = PageController();
  int _index = 0;

  List<Widget> get _pages => [
        WelcomeScreen(onNext: next),
        CablesScreen(onNext: next, onBack: back),
        if (widget.initialMac == null) FindDeviceScreen(flow: flow, onNext: next, onBack: back),
        ConfirmColorScreen(flow: flow, onNext: next, onBack: back),
        WifiScreen(flow: flow, onNext: next, onBack: back),
        // Task 13 appends: NameRoomScreen, ThemeScreen, OutroScreen
      ];

  void next() {
    if (_index < _pages.length - 1) {
      setState(() => _index++);
      _page.animateToPage(_index,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  void back() {
    if (_index > 0) {
      setState(() => _index--);
      _page.animateToPage(_index,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    flow.dispose();
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexusQColors.background,
      body: SafeArea(
        child: PageView(
          controller: _page,
          physics: const NeverScrollableScrollPhysics(),
          children: _pages,
        ),
      ),
    );
  }
}
```
(If `NexusQColors.background` does not exist in `nexusq_theme.dart`, use the theme's existing scaffold/background constant — check the file and match.)

- [ ] **Step 3: Implement the five screens**

Common pattern: a `_WizardScaffold`-style column — title, body, bottom `Row` with Back/Next. Keep each screen a separate small file. Full code:

`screens/welcome_screen.dart` — the 36-frame sphere animation:
```dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../stock_assets.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.onNext});
  final VoidCallback onNext;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  Timer? _timer;
  int _frame = 0;

  @override
  void initState() {
    super.initState();
    if (StockAssets.available) {
      _timer = Timer.periodic(const Duration(milliseconds: 83), (_) {
        setState(() => _frame = (_frame + 1) % 36);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frameName = 'q0${_frame.toString().padLeft(2, '0')}.png';
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
              height: 220,
              child: stockImage(frameName, height: 220, fallback: Icons.circle_outlined)),
          const SizedBox(height: 40),
          const Text('Set up your Nexus Q',
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 12),
          const Text(
            'A few steps and your sphere is on the network and ready to play.',
            textAlign: TextAlign.center,
            style: TextStyle(color: NexusQColors.dim, fontSize: 14),
          ),
          const SizedBox(height: 48),
          FilledButton(onPressed: widget.onNext, child: const Text('Get started')),
        ],
      ),
    );
  }
}
```

`screens/cables_screen.dart`:
```dart
import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../stock_assets.dart';

class CablesScreen extends StatelessWidget {
  const CablesScreen({super.key, required this.onNext, required this.onBack});
  final VoidCallback onNext;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 16),
          const Text('Connect your Nexus Q',
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 24),
          Expanded(
            child: ListView(children: [
              stockImage('cables_diagram_01.png', fallback: Icons.cable),
              const SizedBox(height: 16),
              stockImage('cables_diagram_02.png', fallback: Icons.speaker),
              const SizedBox(height: 16),
              const Text(
                'Plug in power. Connect speakers to the banana terminals, or use '
                'the optical output. The LED ring spins blue while the Q starts up.',
                style: TextStyle(color: NexusQColors.dim, fontSize: 14),
              ),
            ]),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(onPressed: onBack, child: const Text('Back')),
              FilledButton(onPressed: onNext, child: const Text('Next')),
            ],
          ),
        ],
      ),
    );
  }
}
```

`screens/find_device_screen.dart` — BT scan, filter names starting with `Nexus Q` (adapter Alias) but list everything under an expander-free simple list; on select → save mac + next:
```dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../bt_setup_client.dart';
import '../setup_flow.dart';

class FindDeviceScreen extends StatefulWidget {
  const FindDeviceScreen(
      {super.key, required this.flow, required this.onNext, required this.onBack});
  final SetupFlowState flow;
  final VoidCallback onNext;
  final VoidCallback onBack;

  @override
  State<FindDeviceScreen> createState() => _FindDeviceScreenState();
}

class _FindDeviceScreenState extends State<FindDeviceScreen> {
  final _found = <String, BtScanResult>{};
  StreamSubscription? _sub;
  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final ok = await widget.flow.client.ensurePermissions();
    if (!ok) {
      setState(() => _error = 'Bluetooth permission is required to find the Q.');
      return;
    }
    _sub = widget.flow.client.scanResults.listen((r) {
      setState(() => _found[r.mac] = r);
    });
    await widget.flow.client.startScan();
    setState(() => _scanning = true);
  }

  @override
  void dispose() {
    _sub?.cancel();
    widget.flow.client.stopScan();
    super.dispose();
  }

  void _pick(BtScanResult r) {
    widget.flow.client.stopScan();
    widget.flow.deviceMac = r.mac;
    widget.onNext();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _found.values.toList()
      ..sort((a, b) {
        final aq = a.name.startsWith('Nexus Q') ? 0 : 1;
        final bq = b.name.startsWith('Nexus Q') ? 0 : 1;
        return aq != bq ? aq - bq : a.name.compareTo(b.name);
      });
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 16),
          const Text('Looking for your Q…',
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 8),
          Text(_error ?? 'Make sure the ring is spinning blue (setup mode).',
              style: const TextStyle(color: NexusQColors.dim, fontSize: 13)),
          const SizedBox(height: 16),
          if (_scanning) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ListView(
              children: [
                for (final d in devices)
                  ListTile(
                    leading: const Icon(Icons.bluetooth, color: NexusQColors.accent),
                    title: Text(d.name.isEmpty ? d.mac : d.name,
                        style: const TextStyle(color: NexusQColors.white)),
                    subtitle: Text(d.mac, style: const TextStyle(color: NexusQColors.dim)),
                    onTap: () => _pick(d),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(onPressed: widget.onBack, child: const Text('Back')),
              TextButton(onPressed: _start, child: const Text('Rescan')),
            ],
          ),
        ],
      ),
    );
  }
}
```

`screens/confirm_color_screen.dart` — connect over BT, call `confirmColor`, show the same color:
```dart
import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../pairing_color.dart';
import '../setup_flow.dart';

class ConfirmColorScreen extends StatefulWidget {
  const ConfirmColorScreen(
      {super.key, required this.flow, required this.onNext, required this.onBack});
  final SetupFlowState flow;
  final VoidCallback onNext;
  final VoidCallback onBack;

  @override
  State<ConfirmColorScreen> createState() => _ConfirmColorScreenState();
}

class _ConfirmColorScreenState extends State<ConfirmColorScreen> {
  Color? _color;
  String? _status;
  bool _ledUnavailable = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    final mac = widget.flow.deviceMac;
    if (mac == null) return;
    setState(() {
      _status = 'Connecting over Bluetooth…';
      _color = pairingColor(mac); // show immediately; device confirms below
    });
    try {
      await widget.flow.client.connect(mac);
      final r = await widget.flow.client.call('confirmColor');
      final rgb = (r['rgb'] as List).cast<int>();
      setState(() {
        _color = Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
        _status = null;
      });
    } on Object catch (e) {
      // nexusqd down = LED unavailable, but setup can continue.
      setState(() {
        _ledUnavailable = true;
        _status = 'Could not light the ring ($e). You can continue anyway.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Is your sphere glowing this color?',
              textAlign: TextAlign.center,
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 40),
          Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _color ?? Colors.transparent,
              boxShadow: [
                if (_color != null)
                  BoxShadow(color: _color!.withValues(alpha: 0.6), blurRadius: 48, spreadRadius: 8),
              ],
            ),
          ),
          const SizedBox(height: 32),
          if (_status != null)
            Text(_status!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: NexusQColors.dim, fontSize: 13)),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(onPressed: widget.onBack, child: const Text('Back')),
              FilledButton(
                onPressed: (_status == null || _ledUnavailable) ? widget.onNext : null,
                child: Text(_ledUnavailable ? 'Continue anyway' : 'Yes, that\'s it'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
```

`screens/wifi_screen.dart` — scan list (stock wifi icons), password sheet, join with progress + error mapping:
```dart
import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../bt_setup_client.dart';
import '../setup_flow.dart';
import '../stock_assets.dart';

class WifiScreen extends StatefulWidget {
  const WifiScreen(
      {super.key, required this.flow, required this.onNext, required this.onBack});
  final SetupFlowState flow;
  final VoidCallback onNext;
  final VoidCallback onBack;

  @override
  State<WifiScreen> createState() => _WifiScreenState();
}

class _WifiScreenState extends State<WifiScreen> {
  List<Map<String, dynamic>> _networks = [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() { _busy = true; _error = null; });
    try {
      final r = await widget.flow.client.call('scanNetworks');
      setState(() => _networks = (r['networks'] as List).cast<Map<String, dynamic>>());
    } on BtSetupError catch (e) {
      setState(() => _error = 'Scan failed: ${e.message}');
    } finally {
      setState(() => _busy = false);
    }
  }

  String _iconFor(int signal, bool locked) {
    final level = signal > 75 ? 4 : signal > 50 ? 3 : signal > 25 ? 2 : 1;
    return locked ? 'ic_wifi_signal_lock_$level.png' : 'ic_wifi_signal_$level.png';
  }

  Future<void> _join(Map<String, dynamic> net) async {
    final locked = net['security'] == 'wpa-psk';
    String psk = '';
    if (locked) {
      final entered = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: NexusQColors.surface,
        builder: (ctx) => _PasswordSheet(ssid: net['ssid'] as String),
      );
      if (entered == null || entered.isEmpty) return;
      psk = entered;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final r = await widget.flow.client.call('setWifi', {
        'ssid': net['ssid'],
        'psk': psk,
        'security': net['security'],
      });
      widget.flow.wifiResult = r;
      widget.onNext();
    } on BtSetupError catch (e) {
      setState(() => _error = switch (e.code) {
        'wrong_password' => 'Wrong password — try again.',
        'not_found' => 'Network not found. Is it 2.4 GHz and in range?',
        'timeout' => 'Joining timed out. Try again.',
        _ => 'Join failed: ${e.message}',
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 16),
          const Text('Choose a WiFi network',
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 8),
          Text(_error ?? 'The Q will join this network.',
              style: TextStyle(
                  color: _error != null ? Colors.redAccent : NexusQColors.dim, fontSize: 13)),
          const SizedBox(height: 12),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ListView(
              children: [
                for (final n in _networks)
                  ListTile(
                    leading: stockImage(
                        _iconFor(n['signal'] as int, n['security'] == 'wpa-psk'),
                        width: 28,
                        fallback: n['security'] == 'wpa-psk' ? Icons.wifi_lock : Icons.wifi),
                    title: Text(n['ssid'] as String,
                        style: const TextStyle(color: NexusQColors.white)),
                    subtitle: Text('${n['signal']}%',
                        style: const TextStyle(color: NexusQColors.dim)),
                    enabled: !_busy,
                    onTap: () => _join(n),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(onPressed: widget.onBack, child: const Text('Back')),
              TextButton(onPressed: _busy ? null : _scan, child: const Text('Rescan')),
            ],
          ),
        ],
      ),
    );
  }
}

class _PasswordSheet extends StatefulWidget {
  const _PasswordSheet({required this.ssid});
  final String ssid;

  @override
  State<_PasswordSheet> createState() => _PasswordSheetState();
}

class _PasswordSheetState extends State<_PasswordSheet> {
  final _ctrl = TextEditingController();
  bool _show = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          left: 24, right: 24, top: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Password for ${widget.ssid}',
              style: const TextStyle(color: NexusQColors.white, fontSize: 16)),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            obscureText: !_show,
            autofocus: true,
            style: const TextStyle(color: NexusQColors.white),
            decoration: InputDecoration(
              suffixIcon: IconButton(
                icon: Icon(_show ? Icons.visibility_off : Icons.visibility,
                    color: NexusQColors.dim),
                onPressed: () => setState(() => _show = !_show),
              ),
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.pop(context, _ctrl.text),
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests + analyze**

Run in `companion/app/`: `flutter analyze && flutter test`
Expected: PASS (fix `NexusQColors` member names against the real `nexusq_theme.dart` — `background`/`surface`/`accent`/`white`/`dim`/`divider` are the ones the existing screens use; keep exactly those).

- [ ] **Step 5: Commit**

```bash
git add companion/app
git commit -m "feat(app): setup wizard - welcome/cables/find/confirm-color/wifi"
```

---

### Task 13: Setup wizard — name/room, theme, outro + entry points

**Files:**
- Create: `companion/app/lib/setup/screens/name_room_screen.dart`
- Create: `companion/app/lib/setup/screens/theme_screen.dart`
- Create: `companion/app/lib/setup/screens/outro_screen.dart`
- Modify: `companion/app/lib/setup/setup_flow.dart` (append the three pages)
- Modify: `companion/app/lib/screens/connect_gate.dart` ("Set up new device" entry)
- Modify: `companion/app/lib/main.dart` (NFC tap → wizard/LAN routing with a navigator key)
- Modify: `companion/app/pubspec.yaml` (add `video_player` for the outro)

**Interfaces:**
- Consumes: `SetupFlowState` (Task 12), `DeviceTap` (Task 8).
- Produces: complete stock flow; after the outro, `Navigator` replaces to `ConnectGate` with `TcpClient(host: flow.wifiResult['ip'] ?? '<mdns>')`.

- [ ] **Step 1: name/room screen**

`screens/name_room_screen.dart` — room grid uses the stock icons; calls `setName` over BT:
```dart
import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../bt_setup_client.dart';
import '../setup_flow.dart';
import '../stock_assets.dart';

const _rooms = [
  ('livingroom', 'Living room'), ('bedroom', 'Bedroom'), ('kitchen', 'Kitchen'),
  ('diningroom', 'Dining room'), ('familyroom', 'Family room'), ('mediaroom', 'Media room'),
  ('office', 'Office'), ('garage', 'Garage'), ('bathroom', 'Bathroom'), ('closet', 'Closet'),
];

class NameRoomScreen extends StatefulWidget {
  const NameRoomScreen(
      {super.key, required this.flow, required this.onNext, required this.onBack});
  final SetupFlowState flow;
  final VoidCallback onNext;
  final VoidCallback onBack;

  @override
  State<NameRoomScreen> createState() => _NameRoomScreenState();
}

class _NameRoomScreenState extends State<NameRoomScreen> {
  late final _name = TextEditingController(text: widget.flow.deviceName);
  String _room = '';
  bool _busy = false;
  String? _error;

  Future<void> _apply() async {
    setState(() { _busy = true; _error = null; });
    try {
      await widget.flow.client.call('setName', {'name': _name.text.trim(), 'room': _room});
      widget.flow.deviceName = _name.text.trim();
      widget.flow.room = _room;
      widget.onNext();
    } on BtSetupError catch (e) {
      setState(() => _error = 'Could not set the name: ${e.message}');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 16),
          const Text('Name your Nexus Q',
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            style: const TextStyle(color: NexusQColors.white),
            decoration: const InputDecoration(labelText: 'Device name'),
          ),
          const SizedBox(height: 8),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          const SizedBox(height: 8),
          Expanded(
            child: GridView.count(
              crossAxisCount: 3,
              children: [
                for (final (id, label) in _rooms)
                  InkWell(
                    onTap: () => setState(() => _room = id),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: _room == id ? NexusQColors.accent : Colors.transparent),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          stockImage('ic_menu_location_$id.png',
                              width: 40, fallback: Icons.home),
                          const SizedBox(height: 6),
                          Text(label,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: NexusQColors.dim, fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(onPressed: widget.onBack, child: const Text('Back')),
              FilledButton(
                  onPressed: _busy ? null : _apply, child: const Text('Next')),
            ],
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: theme screen**

`screens/theme_screen.dart` — the bridge's theme list mirrored (blue/warm/cool/rose/smoke/off) with swatches; `setTheme` over BT; skippable:
```dart
import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../setup_flow.dart';

const _themes = [
  ('blue', 'Blue', Color(0xFF0099CC)),
  ('warm', 'Warm', Color(0xFFFF5A0A)),
  ('cool', 'Cool', Color(0xFF00C88C)),
  ('rose', 'Rose', Color(0xFFFF285A)),
  ('smoke', 'Smoke', Color(0xFF6E7387)),
  ('off', 'Off', Color(0xFF222222)),
];

class ThemeScreen extends StatefulWidget {
  const ThemeScreen(
      {super.key, required this.flow, required this.onNext, required this.onBack});
  final SetupFlowState flow;
  final VoidCallback onNext;
  final VoidCallback onBack;

  @override
  State<ThemeScreen> createState() => _ThemeScreenState();
}

class _ThemeScreenState extends State<ThemeScreen> {
  String? _selected;

  Future<void> _pick(String theme) async {
    setState(() => _selected = theme);
    try {
      await widget.flow.client.call('setTheme', {'theme': theme});
      widget.flow.theme = theme;
    } catch (_) {
      // theme preview failing must not block setup
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 16),
          const Text('Pick a light theme',
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 8),
          const Text('The ring previews your choice live.',
              style: TextStyle(color: NexusQColors.dim, fontSize: 13)),
          const SizedBox(height: 24),
          Expanded(
            child: GridView.count(
              crossAxisCount: 3,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              children: [
                for (final (id, label, color) in _themes)
                  InkWell(
                    onTap: () => _pick(id),
                    child: Column(
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                            border: Border.all(
                                color: _selected == id
                                    ? NexusQColors.white
                                    : Colors.transparent,
                                width: 2),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(label,
                            style: const TextStyle(color: NexusQColors.dim, fontSize: 12)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(onPressed: widget.onBack, child: const Text('Back')),
              FilledButton(onPressed: widget.onNext, child: const Text('Next')),
            ],
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 3: outro screen + handoff**

`screens/outro_screen.dart` — calls `finishSetup` on entry, plays `q_outro.mp4` (or static fallback), then hands off to the LAN connection:
```dart
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../protocol/tcp_client.dart';
import '../../screens/connect_gate.dart';
import '../../theme/nexusq_theme.dart';
import '../setup_flow.dart';
import '../stock_assets.dart';

class OutroScreen extends StatefulWidget {
  const OutroScreen({super.key, required this.flow});
  final SetupFlowState flow;

  @override
  State<OutroScreen> createState() => _OutroScreenState();
}

class _OutroScreenState extends State<OutroScreen> {
  VideoPlayerController? _video;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      await widget.flow.client.call('finishSetup');
    } catch (_) {
      // device may already have closed setup mode; proceed regardless
    }
    widget.flow.client.disconnect();
    if (StockAssets.available) {
      try {
        final v = VideoPlayerController.asset('assets/stock/raw/q_outro.mp4');
        await v.initialize();
        setState(() => _video = v);
        await v.play();
        v.addListener(() {
          if (v.value.position >= v.value.duration && !_finished) {
            setState(() => _finished = true);
          }
        });
      } catch (_) {
        setState(() => _finished = true);
      }
    } else {
      setState(() => _finished = true);
    }
  }

  void _done() {
    final host = (widget.flow.wifiResult?['ip'] as String?) ??
        (widget.flow.wifiResult?['mdns'] as String?) ?? '';
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
          builder: (_) => ConnectGate(
              initialClient: host.isEmpty ? null : TcpClient(host: host))),
      (route) => false,
    );
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (v != null && v.value.isInitialized)
            AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v))
          else
            stockImage('setup_static.png', height: 200, fallback: Icons.check_circle_outline),
          const SizedBox(height: 32),
          Text('${widget.flow.deviceName} is ready',
              style: const TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 40),
          FilledButton(onPressed: _finished || v == null ? _done : _done,
              child: const Text('Start listening')),
        ],
      ),
    );
  }
}
```
Add to `pubspec.yaml` dependencies: `video_player: ^2.9.0` (then `flutter pub get`).

- [ ] **Step 4: Append the pages + entry points**

`setup_flow.dart` — extend `_pages`:
```dart
        NameRoomScreen(flow: flow, onNext: next, onBack: back),
        ThemeScreen(flow: flow, onNext: next, onBack: back),
        OutroScreen(flow: flow),
```
(with the imports.)

`connect_gate.dart` — in `_fallback()`'s button `Row`, add a fourth action:
```dart
            TextButton(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SetupFlow())),
              child: const Text('Set up new device'),
            ),
```
(plus `import '../setup/setup_flow.dart';`).

`main.dart` — real tap routing (replaces Task 8's placeholder):
```dart
  final _navigatorKey = GlobalKey<NavigatorState>();
```
on `MaterialApp`: `navigatorKey: _navigatorKey,` and:
```dart
        onDeviceTap: (tap) {
          final nav = _navigatorKey.currentState;
          if (nav == null) return;
          if (!tap.provisioned && tap.btMac.isNotEmpty) {
            nav.push(MaterialPageRoute(
                builder: (_) => SetupFlow(initialMac: tap.btMac)));
          } else {
            final host = tap.ip ?? '${tap.host}.local';
            nav.pushAndRemoveUntil(
              MaterialPageRoute(
                  builder: (_) => ConnectGate(initialClient: TcpClient(host: host))),
              (route) => false,
            );
          }
        },
```

- [ ] **Step 5: Analyze, test, build**

Run in `companion/app/`: `flutter analyze && flutter test && flutter build apk --debug`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add companion/app
git commit -m "feat(app): setup wizard - name/room, theme, outro + NFC/gate entry points"
```

---

### Task 14: Build, flash, HW acceptance, docs

**Files:**
- Modify: `CHANGELOG.md`, `HANDOFF.md`, `PLAN.md`, `companion/PROTOCOL.md` §8 (via the docs agent)

**Interfaces:** none new — this task proves the whole step end-to-end.

- [ ] **Step 1: PROTOCOL.md §8 — write the Setup transport section**

Add a new section after §7 documenting: the RFCOMM UUID, Just-Works pairing, the envelope reuse, the 8 methods with params/results/error codes (copy the spec §2 table), the lifecycle (ExecCondition, force flag, 600 s inactivity, finishSetup), and the pairing-color contract (pointer to `pairing-color-vectors.json`).

- [ ] **Step 2: Build the image**

Invoke the `nexusq-build` skill/agent (full rootfs — new packages + kernel-independent; kernel unchanged, so boot.img rebuild is not required but harmless). Verify the build report lists `nexusq-setupd`, the bumped `nexusqd`, `nexusq-control`, `device-google-steelhead`.

- [ ] **Step 3: Flash + acceptance on real HW (with the user — inform every step, ask before reboot/sound)**

Acceptance protocol (= the spec's definition of done):
1. Flash; boot with the baked WiFi profile → setupd must NOT run (`systemctl status nexusq-setupd` = condition failed). Run the standard post-flash diag sweep.
2. `nmcli connection delete wifi` + reboot → setup mode: ring spins blue, `bluetoothctl show` shows Discoverable yes.
3. Full wizard from the Android phone: find → color confirm (visual check!) → WiFi join with a **deliberately wrong password first** (expect the in-app "Wrong password" and setup mode surviving) → correct join → name "Obývák Q" + room → theme → outro. Verify: `hostname` = `obyvak-q`, `/etc/nexusq/device.json` content, mDNS `_nexusq._tcp` shows the new name + room TXT, Spotify sees the new name, ring shows the chosen theme, setupd exited, Discoverable off.
4. NFC tap while provisioned → app auto-connects over LAN. NFC tap after `nmcli connection delete wifi` + reboot → app jumps into the wizard with the MAC prefilled.
5. `startSetupMode` over LAN → setupd starts despite the existing profile (re-provisioning path).
6. Re-run the diag sweep; journal/dmesg must stay clean of new errors.

- [ ] **Step 4: Docs sweep**

Invoke the `nexusq-docs` agent with the session summary (new daemons, protocol §8, NFC payload change closing the backlog item, acceptance results).

- [ ] **Step 5: Final commit + tag proposal**

Commit remaining doc changes; propose the release tag (v1.9.0 — new feature set) to the user. Do not tag without approval.

---

## Self-Review

**Spec coverage check:** §1 setup mode/lifecycle → Tasks 5, 6 (unit, ExecCondition, force flag, timeout, LED via Task 1). §2 protocol/methods → Tasks 4, 5 (all 8 methods + framing). §3 NFC → Tasks 7, 8. §4 wizard/assets/name-room → Tasks 11, 12, 13; name propagation (hostname, avahi, TXT, librespot) → Tasks 2, 4. §5 errors/testing → per-task tests + Task 14 acceptance incl. the wrong-password path. Non-goals respected (no iOS path, no TLV, no calibration). `startSetupMode` → Task 2. Pairing-color parity → Tasks 3, 4, 10.

**Known judgment calls** (documented here so the executor doesn't re-litigate): setupd exits after `finishSetup` (one-shot per trigger) rather than staying resident; `setName` restarts `nexusq-control` (drops LAN clients — acceptable because setName happens over BT during setup); the RFCOMM channel is fixed at 3 (BlueZ would auto-assign, a fixed channel simplifies debugging); nexusqd frame cadence for spin is 30 ms.

**Placeholder scan:** the two flagged look-before-you-code spots are explicit verification steps, not placeholders (Task 11 Step 2 asset-name check against apktool reality; Task 12 Step 4 theme-constant name check). Everything else ships concrete code.
