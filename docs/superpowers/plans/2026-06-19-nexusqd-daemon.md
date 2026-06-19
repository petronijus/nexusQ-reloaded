# nexusqd Daemon — Implementation Plan (Plan 2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A userspace daemon `nexusqd` that owns the Nexus Q LED ring via the
`leds-steelhead-avr` kernel driver and gives it living behavior — idle glow,
theme palettes, and reaction to the mute/volume keys — plus a `nexusled` CLI
and a control socket, started at boot by systemd.

**Architecture:** Python 3 daemon (the device already ships python3; avoids
musl cross-compilation). A priority **compositor** renders one 32-RGB frame and
writes it to the kernel **frame channel** (`/sys/bus/i2c/devices/1-0020/frame`
+ `commit_mode` + `mute`). An evdev reader turns the AVR keys into volume/mute
reactions. Pure logic (frame packing, compositor layering, theme parsing) is
host-unit-tested with pytest; sysfs/evdev I/O is verified on the device. The
performance-sensitive music visualizer is explicitly OUT of scope (Plan 3, C).

**Tech Stack:** Python 3 (stdlib only: `struct`, `socket`, `selectors`,
`fcntl`, `os`, `json`, `time`); pytest on host; systemd; the kernel driver from
Plan 1 (merged).

## Global Constraints

- Target runtime: postmarketOS (Alpine, **musl**) on the device; **python3 stdlib only** — no pip deps (none guaranteed on device).
- LED output is the Plan-1 kernel driver's sysfs ONLY: write 96 bytes (32×RGB, LED order = ring index 0..31) to `…/1-0020/frame`; `…/commit_mode` = `0` immediate / `1` interpolate; `…/mute` = `"R G B"`. Never touch `/dev/i2c` directly (the driver owns the device).
- Ring is **32 LEDs**; the mute LED is separate (driver's `mute` attr).
- Keys arrive via evdev: `KEY_MUTE`=113, `KEY_VOLUMEUP`=115, `KEY_VOLUMEDOWN`=114 on the input device named `steelhead-avr-keys`.
- **Theme palettes are Google-proprietary** (extracted to the gitignored `private/nexusq-original/themes/`): NOT committed. The daemon loads them from `/etc/nexusqd/themes/` at runtime; a deploy step installs them from the private overlay (mirrors the firmware-blob pattern). The repo ships only a small non-proprietary `default.json` fallback.
- Idle/default color when nothing else is active: subdued blue **`0x00385c`** (the original `lights.c` fallback).
- Device access for on-device tests: `root@192.168.20.179` (key installed; password `147147` documented). Python on device: `/usr/bin/python3`.
- Compositor update rate ≤ 30 Hz for transient animations (volume fade) — well within python/ARM budget; idle is near-static.

## File Structure

Repo dir `userspace/nexusqd/` (new):
- `nexusqd/avr.py` — thin LED-output wrapper over the kernel sysfs (open/write frame, set mute, set commit mode, read count). One responsibility: bytes ↔ sysfs.
- `nexusqd/frame.py` — pure helpers: a `Frame` (32 RGB), pack to 96 bytes, fill/set-range/blend. No I/O. Fully unit-tested.
- `nexusqd/themes.py` — load theme JSON (the extracted `theme_*.json` shape: `{engine, options:{display,led,colors[],...}, metaOption:{mode}}`), expose name→palette (list of `(r,g,b)`). Pure. Unit-tested.
- `nexusqd/compositor.py` — priority layer stack → one `Frame`. Pure (takes layer states, returns Frame). Unit-tested.
- `nexusqd/keys.py` — evdev reader: open the `steelhead-avr-keys` event node, decode `input_event` records, yield (keycode, down). Pure decode helper unit-tested; device read verified on-device.
- `nexusqd/control.py` — Unix-socket control server + protocol (line commands: `theme <name>`, `set <r> <g> <b>`, `off`, `status`). Pure command-parser unit-tested.
- `nexusqd/daemon.py` — `nexusqd` main: wires output+compositor+keys+control, runs the idle layer + volume/mute reactions, the run loop. Entry point.
- `nexusqd/cli.py` — `nexusled` CLI: connects to the control socket (or writes sysfs directly if the daemon isn't running). Mirrors the original `avrlights [start] [count] [color…]` plus `theme`/`off`.
- `nexusqd/default.json` — non-proprietary fallback theme (single `#00385c`).
- `nexusqd/nexusqd.service` — systemd unit.
- `nexusqd/tests/test_*.py` — pytest host tests.
- `scripts/deploy-nexusqd.sh` — rsync/scp the package to the device, install themes from `private/`, enable the service.

Behavior scope for THIS plan: idle glow, theme selection, manual control (CLI/socket), key events → a **faithful baseline** volume-ring + mute indicator. The *pixel-perfect* volume/mute rendering (decompile `android.view.VolumePanel.setVolumeLeds` + `tungsten.visualizer.led.LedController`) and the music visualizer are deferred to Plan 2b / Plan 3 — noted at the end.

---

### Task 1: `frame.py` — pure Frame model + 96-byte packing

**Files:**
- Create: `userspace/nexusqd/nexusqd/frame.py`
- Create: `userspace/nexusqd/nexusqd/__init__.py` (empty)
- Test: `userspace/nexusqd/nexusqd/tests/test_frame.py`

**Interfaces:**
- Produces: `RING = 32`; `class Frame` holding 32 `[r,g,b]` (0-255 ints); methods `fill(r,g,b)`, `set(i,r,g,b)`, `set_range(start,count,rgb_list)`, `blend(other, alpha)` (alpha 0..1, per-channel linear toward `other`), `pack() -> bytes` (96 bytes, LED 0 first, R,G,B order); classmethod `black()`.

- [ ] **Step 1: Write the failing tests**

```python
# userspace/nexusqd/nexusqd/tests/test_frame.py
from nexusqd.frame import Frame, RING

def test_fill_and_pack():
    f = Frame.black(); f.fill(1, 2, 3)
    b = f.pack()
    assert len(b) == RING * 3 == 96
    assert b[0:3] == bytes([1, 2, 3])
    assert b[-3:] == bytes([1, 2, 3])

def test_set_one():
    f = Frame.black(); f.set(5, 10, 20, 30)
    assert f.pack()[15:18] == bytes([10, 20, 30])
    assert f.pack()[0:3] == bytes([0, 0, 0])

def test_set_range_wraps_is_rejected():
    f = Frame.black()
    import pytest
    with pytest.raises(ValueError):
        f.set_range(30, 5, [(1, 1, 1)] * 5)   # 30+5 > 32

def test_blend_half():
    a = Frame.black(); b = Frame.black(); b.fill(100, 200, 0)
    a.blend(b, 0.5)
    assert a.pack()[0:3] == bytes([50, 100, 0])

def test_clamp():
    f = Frame.black(); f.set(0, 999, -5, 256)
    assert f.pack()[0:3] == bytes([255, 0, 255])
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd userspace/nexusqd && python3 -m pytest nexusqd/tests/test_frame.py -q`
Expected: FAIL (ModuleNotFoundError: nexusqd.frame).

- [ ] **Step 3: Implement `frame.py`**

```python
# userspace/nexusqd/nexusqd/frame.py
RING = 32

def _clamp(v):
    return 0 if v < 0 else 255 if v > 255 else int(v)

class Frame:
    __slots__ = ("px",)

    def __init__(self, px=None):
        self.px = px if px is not None else [[0, 0, 0] for _ in range(RING)]

    @classmethod
    def black(cls):
        return cls()

    def fill(self, r, g, b):
        for p in self.px:
            p[0], p[1], p[2] = _clamp(r), _clamp(g), _clamp(b)

    def set(self, i, r, g, b):
        self.px[i] = [_clamp(r), _clamp(g), _clamp(b)]

    def set_range(self, start, count, rgb_list):
        if start < 0 or count < 0 or start + count > RING:
            raise ValueError("range out of bounds")
        for k in range(count):
            r, g, b = rgb_list[k]
            self.px[start + k] = [_clamp(r), _clamp(g), _clamp(b)]

    def blend(self, other, alpha):
        a = 0.0 if alpha < 0 else 1.0 if alpha > 1 else alpha
        for p, q in zip(self.px, other.px):
            p[0] = _clamp(p[0] + (q[0] - p[0]) * a)
            p[1] = _clamp(p[1] + (q[1] - p[1]) * a)
            p[2] = _clamp(p[2] + (q[2] - p[2]) * a)

    def pack(self):
        out = bytearray(RING * 3)
        for i, p in enumerate(self.px):
            out[i*3:i*3+3] = bytes(p)
        return bytes(out)
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd userspace/nexusqd && python3 -m pytest nexusqd/tests/test_frame.py -q`
Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add userspace/nexusqd/nexusqd/__init__.py userspace/nexusqd/nexusqd/frame.py userspace/nexusqd/nexusqd/tests/test_frame.py
git commit -m "nexusqd: pure Frame model + 96-byte packing"
```

---

### Task 2: `themes.py` — load extracted theme palettes

**Files:**
- Create: `userspace/nexusqd/nexusqd/themes.py`
- Create: `userspace/nexusqd/nexusqd/default.json`
- Test: `userspace/nexusqd/nexusqd/tests/test_themes.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `class Theme` with `name:str`, `colors:list[tuple[int,int,int]]`, `led:bool`, `mode:int`; `parse_theme(name, json_text) -> Theme` (hex `#RRGGBB` → rgb tuples); `load_dir(path) -> dict[str,Theme]` (reads `theme_*` / `*.json` files; filename stem after `theme_` is the name).

- [ ] **Step 1: Write the failing tests**

```python
# userspace/nexusqd/nexusqd/tests/test_themes.py
from nexusqd.themes import parse_theme

SPECTRUM = '{"engine": {},"options": {"display": 1,"led": 1,"colors": ["#AA66CC","#FF4444","#0099cc"]},"metaOption": {"mode": 1}}'
OFF = '{"engine": {},"options": {"display": 0,"led": 0,"colors": ["#000000"]},"metaOption": {"mode": 1}}'

def test_parse_colors_and_flags():
    t = parse_theme("spectrum", SPECTRUM)
    assert t.name == "spectrum"
    assert t.colors[0] == (0xAA, 0x66, 0xCC)
    assert t.colors[2] == (0x00, 0x99, 0xcc)
    assert t.led is True and t.mode == 1

def test_off_theme():
    t = parse_theme("off", OFF)
    assert t.led is False
    assert t.colors == [(0, 0, 0)]
```

- [ ] **Step 2: Run, verify fail**

Run: `cd userspace/nexusqd && python3 -m pytest nexusqd/tests/test_themes.py -q`
Expected: FAIL (ImportError).

- [ ] **Step 3: Implement `themes.py` + `default.json`**

```python
# userspace/nexusqd/nexusqd/themes.py
import json, os, glob

def _hex(s):
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))

class Theme:
    def __init__(self, name, colors, led, mode):
        self.name, self.colors, self.led, self.mode = name, colors, led, mode

def parse_theme(name, json_text):
    d = json.loads(json_text)
    opt = d.get("options", {})
    colors = [_hex(c) for c in opt.get("colors", ["#000000"])]
    return Theme(name, colors, bool(opt.get("led", 1)), int(d.get("metaOption", {}).get("mode", 1)))

def load_dir(path):
    out = {}
    for f in sorted(glob.glob(os.path.join(path, "theme_*")) + glob.glob(os.path.join(path, "*.json"))):
        base = os.path.basename(f)
        name = base[len("theme_"):] if base.startswith("theme_") else os.path.splitext(base)[0]
        with open(f, "r") as fh:
            out[name] = parse_theme(name, fh.read())
    return out
```

```json
{"engine": {}, "options": {"display": 0, "led": 1, "colors": ["#00385c"]}, "metaOption": {"mode": 1}}
```
(write the JSON above to `userspace/nexusqd/nexusqd/default.json`)

- [ ] **Step 4: Run, verify pass**

Run: `cd userspace/nexusqd && python3 -m pytest nexusqd/tests/test_themes.py -q`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add userspace/nexusqd/nexusqd/themes.py userspace/nexusqd/nexusqd/default.json userspace/nexusqd/nexusqd/tests/test_themes.py
git commit -m "nexusqd: theme palette loader (+ non-proprietary default)"
```

---

### Task 3: `compositor.py` — priority layer stack → one Frame

**Files:**
- Create: `userspace/nexusqd/nexusqd/compositor.py`
- Test: `userspace/nexusqd/nexusqd/tests/test_compositor.py`

**Interfaces:**
- Consumes: `Frame` from `frame.py`.
- Produces: `class Layer` (abstract: `render(t: float) -> Frame | None`, `active: bool`); `class SolidLayer(rgb)`; `class Compositor` with `add(priority:int, layer)`, `render(t) -> Frame` (highest-priority active layer whose `render` returns non-None wins; if none, returns `Frame.black()`).

- [ ] **Step 1: Write the failing tests**

```python
# userspace/nexusqd/nexusqd/tests/test_compositor.py
from nexusqd.compositor import Compositor, SolidLayer
from nexusqd.frame import Frame

class Off:
    active = False
    def render(self, t): return None

def test_highest_active_wins():
    c = Compositor()
    c.add(0, SolidLayer((10, 0, 0)))     # idle
    c.add(10, SolidLayer((0, 20, 0)))    # higher
    assert c.render(0.0).pack()[0:3] == bytes([0, 20, 0])

def test_inactive_skipped():
    c = Compositor()
    c.add(0, SolidLayer((10, 0, 0)))
    c.add(10, Off())
    assert c.render(0.0).pack()[0:3] == bytes([10, 0, 0])

def test_empty_is_black():
    assert Compositor().render(0.0).pack() == bytes(96)
```

- [ ] **Step 2: Run, verify fail**

Run: `cd userspace/nexusqd && python3 -m pytest nexusqd/tests/test_compositor.py -q`
Expected: FAIL (ImportError).

- [ ] **Step 3: Implement `compositor.py`**

```python
# userspace/nexusqd/nexusqd/compositor.py
from .frame import Frame

class SolidLayer:
    def __init__(self, rgb):
        self.rgb = rgb
        self.active = True
    def render(self, t):
        f = Frame.black(); f.fill(*self.rgb); return f

class Compositor:
    def __init__(self):
        self._layers = []   # list of (priority, layer)
    def add(self, priority, layer):
        self._layers.append((priority, layer))
        self._layers.sort(key=lambda pl: pl[0], reverse=True)
    def render(self, t):
        for _, layer in self._layers:
            if getattr(layer, "active", True):
                f = layer.render(t)
                if f is not None:
                    return f
        return Frame.black()
```

- [ ] **Step 4: Run, verify pass**

Run: `cd userspace/nexusqd && python3 -m pytest nexusqd/tests/test_compositor.py -q`
Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add userspace/nexusqd/nexusqd/compositor.py userspace/nexusqd/nexusqd/tests/test_compositor.py
git commit -m "nexusqd: priority compositor"
```

---

### Task 4: `keys.py` — evdev input_event decode

**Files:**
- Create: `userspace/nexusqd/nexusqd/keys.py`
- Test: `userspace/nexusqd/nexusqd/tests/test_keys.py`

**Interfaces:**
- Produces: constants `KEY_MUTE=113, KEY_VOLUMEDOWN=114, KEY_VOLUMEUP=115`, `EV_KEY=1`; `EVENT_SIZE=16` and `EVENT_FMT="<iiHHi"` (32-bit ARM input_event: sec,usec as 4-byte longs, type,code u16, value i32); `decode_events(buf) -> list[(code:int, down:bool)]` (only EV_KEY, value!=2 i.e. ignore autorepeat; down = value==1); `find_event_node(by_name="steelhead-avr-keys") -> str|None` (scans `/sys/class/input/event*/device/name`).

- [ ] **Step 1: Write the failing tests**

```python
# userspace/nexusqd/nexusqd/tests/test_keys.py
import struct
from nexusqd.keys import decode_events, EVENT_FMT, KEY_MUTE, KEY_VOLUMEUP, EV_KEY

def ev(code, value, typ=EV_KEY):
    return struct.pack(EVENT_FMT, 123, 456, typ, code, value)

def test_decode_down_up():
    buf = ev(KEY_MUTE, 1) + ev(KEY_MUTE, 0) + ev(KEY_VOLUMEUP, 1)
    assert decode_events(buf) == [(KEY_MUTE, True), (KEY_MUTE, False), (KEY_VOLUMEUP, True)]

def test_ignore_syn_and_autorepeat():
    buf = ev(0, 0, typ=0) + ev(KEY_VOLUMEUP, 2)   # EV_SYN + autorepeat
    assert decode_events(buf) == []
```

- [ ] **Step 2: Run, verify fail**

Run: `cd userspace/nexusqd && python3 -m pytest nexusqd/tests/test_keys.py -q`
Expected: FAIL (ImportError).

- [ ] **Step 3: Implement `keys.py`**

```python
# userspace/nexusqd/nexusqd/keys.py
import struct, glob, os

KEY_MUTE, KEY_VOLUMEDOWN, KEY_VOLUMEUP = 113, 114, 115
EV_KEY = 1
EVENT_FMT = "<iiHHi"
EVENT_SIZE = struct.calcsize(EVENT_FMT)   # 16 on 32-bit ARM

def decode_events(buf):
    out = []
    for off in range(0, len(buf) - EVENT_SIZE + 1, EVENT_SIZE):
        _s, _u, typ, code, value = struct.unpack_from(EVENT_FMT, buf, off)
        if typ == EV_KEY and value in (0, 1):
            out.append((code, value == 1))
    return out

def find_event_node(by_name="steelhead-avr-keys"):
    for namef in sorted(glob.glob("/sys/class/input/event*/device/name")):
        try:
            with open(namef) as fh:
                if fh.read().strip() == by_name:
                    ev = namef.split("/")[4]   # eventN
                    return "/dev/input/" + ev
        except OSError:
            continue
    return None
```

- [ ] **Step 4: Run, verify pass**

Run: `cd userspace/nexusqd && python3 -m pytest nexusqd/tests/test_keys.py -q`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add userspace/nexusqd/nexusqd/keys.py userspace/nexusqd/nexusqd/tests/test_keys.py
git commit -m "nexusqd: evdev input_event decode + node discovery"
```

---

### Task 5: `control.py` — control-socket command parser

**Files:**
- Create: `userspace/nexusqd/nexusqd/control.py`
- Test: `userspace/nexusqd/nexusqd/tests/test_control.py`

**Interfaces:**
- Produces: `parse_command(line:str) -> tuple` — returns one of `("theme", name)`, `("set", (r,g,b))`, `("off",)`, `("status",)`, `("mute", (r,g,b))`; raises `ValueError` on malformed input. (Socket server wiring is in the daemon — Task 6 — and verified on-device; the parser is the unit-tested pure core.)

- [ ] **Step 1: Write the failing tests**

```python
# userspace/nexusqd/nexusqd/tests/test_control.py
import pytest
from nexusqd.control import parse_command

def test_theme():
    assert parse_command("theme spectrum") == ("theme", "spectrum")

def test_set_rgb():
    assert parse_command("set 255 0 128") == ("set", (255, 0, 128))

def test_off_status():
    assert parse_command("off") == ("off",)
    assert parse_command("status") == ("status",)

def test_mute():
    assert parse_command("mute 0 64 0") == ("mute", (0, 64, 0))

def test_bad():
    for bad in ["", "set 1 2", "set 1 2 999", "theme", "bogus"]:
        with pytest.raises(ValueError):
            parse_command(bad)
```

- [ ] **Step 2: Run, verify fail**

Run: `cd userspace/nexusqd && python3 -m pytest nexusqd/tests/test_control.py -q`
Expected: FAIL (ImportError).

- [ ] **Step 3: Implement `control.py`**

```python
# userspace/nexusqd/nexusqd/control.py
def _rgb(parts):
    if len(parts) != 3:
        raise ValueError("need r g b")
    vals = tuple(int(p) for p in parts)
    for v in vals:
        if not 0 <= v <= 255:
            raise ValueError("rgb out of range")
    return vals

def parse_command(line):
    toks = line.split()
    if not toks:
        raise ValueError("empty")
    cmd, args = toks[0], toks[1:]
    if cmd == "theme":
        if len(args) != 1:
            raise ValueError("theme <name>")
        return ("theme", args[0])
    if cmd == "set":
        return ("set", _rgb(args))
    if cmd == "mute":
        return ("mute", _rgb(args))
    if cmd == "off" and not args:
        return ("off",)
    if cmd == "status" and not args:
        return ("status",)
    raise ValueError("unknown command: " + cmd)
```

- [ ] **Step 4: Run, verify pass**

Run: `cd userspace/nexusqd && python3 -m pytest nexusqd/tests/test_control.py -q`
Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add userspace/nexusqd/nexusqd/control.py userspace/nexusqd/nexusqd/tests/test_control.py
git commit -m "nexusqd: control command parser"
```

---

### Task 6: `avr.py` + `daemon.py` — wire output, idle, keys, control (on-device)

**Files:**
- Create: `userspace/nexusqd/nexusqd/avr.py`
- Create: `userspace/nexusqd/nexusqd/daemon.py`
- Test: on-device (no host unit test — this is the I/O integration).

**Interfaces:**
- Consumes: `Frame`, `Compositor`, `SolidLayer`, `load_dir`/`Theme`, `decode_events`/`find_event_node`, `parse_command`.
- Produces: `class Avr` with `write_frame(frame: Frame, commit=0)`, `set_mute(r,g,b)`, `SYSFS="/sys/bus/i2c/devices/1-0020"`; `nexusqd` `main()` entry: builds a Compositor with an idle `SolidLayer(0x00,0x38,0x5c)` at priority 0 and a transient volume/mute layer at higher priority, reads keys via evdev, serves a control socket at `/run/nexusqd.sock`.

- [ ] **Step 1: Implement `avr.py`**

```python
# userspace/nexusqd/nexusqd/avr.py
import os

class Avr:
    SYSFS = "/sys/bus/i2c/devices/1-0020"

    def __init__(self, base=None):
        self.base = base or self.SYSFS

    def set_commit_mode(self, mode):
        with open(self.base + "/commit_mode", "w") as f:
            f.write(str(int(mode)))

    def write_frame(self, frame, commit=0):
        self.set_commit_mode(commit)
        fd = os.open(self.base + "/frame", os.O_WRONLY)
        try:
            os.write(fd, frame.pack())
        finally:
            os.close(fd)

    def set_mute(self, r, g, b):
        with open(self.base + "/mute", "w") as f:
            f.write("%d %d %d" % (r, g, b))
```

- [ ] **Step 2: Implement `daemon.py`** (idle + faithful-baseline volume/mute + control socket + key loop)

```python
# userspace/nexusqd/nexusqd/daemon.py
import os, socket, selectors, time
from .frame import Frame, RING
from .compositor import Compositor, SolidLayer
from .avr import Avr
from .keys import decode_events, find_event_node, KEY_MUTE, KEY_VOLUMEUP, KEY_VOLUMEDOWN
from .control import parse_command
from .themes import load_dir

IDLE_RGB = (0x00, 0x38, 0x5c)
THEMES_DIR = "/etc/nexusqd/themes"
SOCK = "/run/nexusqd.sock"

class VolumeLayer:
    """Faithful-baseline volume overlay: N of 32 LEDs lit in the active color
    for ~1.5s after a volume key, then deactivates. (Pixel-perfect rendering =
    Plan 2b, see plan footer.)"""
    def __init__(self):
        self.active = False
        self.level = 0.5          # 0..1
        self.until = 0.0
        self.color = (0x33, 0xB5, 0xE5)
    def bump(self, delta, now):
        self.level = max(0.0, min(1.0, self.level + delta))
        self.until = now + 1.5
        self.active = True
    def render(self, t):
        if t > self.until:
            self.active = False
            return None
        f = Frame.black()
        lit = int(round(self.level * RING))
        for i in range(lit):
            f.set(i, *self.color)
        return f

def main():
    avr = Avr()
    themes = {}
    try:
        themes = load_dir(THEMES_DIR)
    except OSError:
        pass
    idle = SolidLayer(IDLE_RGB)
    vol = VolumeLayer()
    comp = Compositor()
    comp.add(0, idle)
    comp.add(10, vol)

    muted = [False]
    def apply_mute():
        avr.set_mute(80, 0, 0) if muted[0] else avr.set_mute(0, 0, 0)

    # inputs
    sel = selectors.DefaultSelector()
    node = find_event_node()
    kfd = os.open(node, os.O_RDONLY | os.O_NONBLOCK) if node else None
    if kfd is not None:
        sel.register(kfd, selectors.EVENT_READ, "keys")

    if os.path.exists(SOCK):
        os.unlink(SOCK)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK); srv.listen(4); srv.setblocking(False)
    sel.register(srv, selectors.EVENT_READ, "ctrl")

    apply_mute()
    last = Frame.black()
    while True:
        now = time.monotonic()
        for key, _mask in sel.select(timeout=0.05):
            if key.data == "keys":
                buf = os.read(kfd, 16 * 64)
                for code, down in decode_events(buf):
                    if not down:
                        continue
                    if code == KEY_VOLUMEUP:
                        vol.bump(+0.1, now)
                    elif code == KEY_VOLUMEDOWN:
                        vol.bump(-0.1, now)
                    elif code == KEY_MUTE:
                        muted[0] = not muted[0]; apply_mute()
            elif key.data == "ctrl":
                conn, _ = srv.accept(); conn.setblocking(True)
                try:
                    line = conn.recv(256).decode("ascii", "replace").strip()
                    cmd = parse_command(line)
                    if cmd[0] == "theme" and cmd[1] in themes:
                        c = themes[cmd[1]].colors[0]
                        idle.rgb = c
                    elif cmd[0] == "set":
                        idle.rgb = cmd[1]
                    elif cmd[0] == "off":
                        idle.rgb = (0, 0, 0)
                    elif cmd[0] == "mute":
                        avr.set_mute(*cmd[1])
                    conn.sendall(b"ok\n")
                except (ValueError, OSError) as e:
                    try: conn.sendall(("err %s\n" % e).encode())
                    except OSError: pass
                conn.close()
        frame = comp.render(now)
        b = frame.pack()
        if b != last.pack():
            avr.write_frame(frame, commit=0)
            last = frame

if __name__ == "__main__":
    main()
```

- [ ] **Step 3: On-device smoke test**

```bash
# package + run on device (driver from Plan 1 is already auto-loaded)
scp -r userspace/nexusqd root@192.168.20.179:/opt/
ssh root@192.168.20.179 'cd /opt/nexusqd && (python3 -m nexusqd.daemon &) ; sleep 2;
  echo "theme should idle blue now"; printf "set 255 0 0" | nc -U /run/nexusqd.sock; sleep 1;
  printf "off" | nc -U /run/nexusqd.sock'
```
Expected: ring goes idle blue on start; `set 255 0 0` turns it red; `off` turns it off. Then physically rotate volume → ring fills/empties; tap mute → mute LED toggles red. (Visual confirmation.) If `nc` lacks `-U`, use a tiny python socket client.

- [ ] **Step 4: Commit**

```bash
git add userspace/nexusqd/nexusqd/avr.py userspace/nexusqd/nexusqd/daemon.py
git commit -m "nexusqd: daemon — idle glow, volume/mute reaction, control socket"
```

---

### Task 7: `cli.py` (`nexusled`) + systemd unit + deploy script

**Files:**
- Create: `userspace/nexusqd/nexusqd/cli.py`
- Create: `userspace/nexusqd/nexusqd/nexusqd.service`
- Create: `scripts/deploy-nexusqd.sh`
- Test: on-device.

**Interfaces:**
- Consumes: the control socket `/run/nexusqd.sock`; `Avr` for direct fallback.
- Produces: `nexusled` CLI — `nexusled set R G B`, `nexusled theme NAME`, `nexusled off`, `nexusled all R G B` (alias of set), talking to the socket; if the socket is absent, writes the kernel sysfs directly via `Avr`.

- [ ] **Step 1: Implement `cli.py`**

```python
# userspace/nexusqd/nexusqd/cli.py
import sys, socket
from .avr import Avr
from .frame import Frame

SOCK = "/run/nexusqd.sock"

def _send(line):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK); s.sendall(line.encode()); r = s.recv(64); s.close()
    return r.decode().strip()

def main(argv=None):
    a = (argv if argv is not None else sys.argv[1:])
    if not a:
        print("usage: nexusled set R G B | theme NAME | off | all R G B"); return 2
    line = " ".join(("set" if a[0] == "all" else a[0], *a[1:]))
    try:
        print(_send(line)); return 0
    except OSError:
        # daemon not running: direct sysfs fallback for set/off
        avr = Avr(); f = Frame.black()
        if a[0] in ("set", "all"):
            f.fill(int(a[1]), int(a[2]), int(a[3]))
        avr.write_frame(f, commit=0); print("ok (direct)"); return 0

if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Create the systemd unit**

```ini
# userspace/nexusqd/nexusqd/nexusqd.service
[Unit]
Description=Nexus Q LED ring daemon
After=multi-user.target
Requires=systemd-modules-load.service

[Service]
ExecStart=/usr/bin/python3 -m nexusqd.daemon
WorkingDirectory=/opt/nexusqd
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Create deploy script**

```bash
# scripts/deploy-nexusqd.sh
#!/bin/sh
set -e
DEV="${1:-root@192.168.20.179}"
scp -r userspace/nexusqd "$DEV:/opt/"
# proprietary theme palettes from the private overlay (not in the public repo)
ssh "$DEV" 'mkdir -p /etc/nexusqd/themes'
if [ -d private/nexusq-original/themes ]; then
    scp private/nexusq-original/themes/theme_* "$DEV:/etc/nexusqd/themes/" || true
fi
ssh "$DEV" 'cp /opt/nexusqd/nexusqd/default.json /etc/nexusqd/themes/ 2>/dev/null || true;
    cp /opt/nexusqd/nexusqd/nexusqd.service /etc/systemd/system/;
    ln -sf /opt/nexusqd/nexusqd/cli.py /usr/local/bin/nexusled; chmod +x /usr/local/bin/nexusled;
    systemctl daemon-reload; systemctl enable --now nexusqd.service; sleep 2; systemctl status nexusqd --no-pager | head -5'
```

- [ ] **Step 4: On-device test**

```bash
bash scripts/deploy-nexusqd.sh
ssh root@192.168.20.179 'nexusled theme spectrum; sleep 1; nexusled set 0 255 0; sleep 1; nexusled off; systemctl is-active nexusqd'
```
Expected: service `active`; CLI changes the ring; survives a `systemctl restart nexusqd`. Reboot once and confirm `systemctl is-active nexusqd` is `active` and the ring shows idle blue at boot.

- [ ] **Step 5: Commit**

```bash
git add userspace/nexusqd/nexusqd/cli.py userspace/nexusqd/nexusqd/nexusqd.service scripts/deploy-nexusqd.sh
git commit -m "nexusqd: nexusled CLI + systemd unit + deploy script"
```

---

## Self-Review

**Spec coverage (daemon portion):** compositor/priority layers (T3) ✅; control API mirroring ILedService — `theme/set/off/mute/status` (T5+T6) ✅; nexusled CLI mirroring avrlights (T7) ✅; systemd autostart + idle glow `0x00385c` (T6/T7) ✅; theme palettes loaded verbatim from extracted JSON (T2, installed via deploy from private overlay) ✅; input via evdev for the AVR keys (T4/T6) ✅; output via the Plan-1 frame channel only (T6) ✅. Visualizer → Plan 3 (out of scope, stated). Volume-ring + mute **pixel-perfect** → Plan 2b (this plan ships a faithful baseline; see footer).

**Placeholder scan:** none — every code step has complete code. The VolumeLayer is a complete, working faithful baseline (not a stub); its pixel-perfect refinement is a separate, explicitly-scoped plan.

**Type consistency:** `Frame.pack()`→96 bytes used by `Avr.write_frame`; `decode_events`→`(code,down)` consumed in daemon; `parse_command` tuples consumed in daemon; `Theme.colors` list-of-rgb used for idle. Consistent across tasks.

## Deferred to Plan 2b / Plan 3 (not in this plan)

- **Pixel-perfect volume ring + mute:** the original lived in `android.view.VolumePanel.setVolumeLeds` + `com.google.android.tungsten.visualizer.led.LedController` (found in the factory `system.img`). Plan 2b: baksmali `framework.jar`/`services` + the visualizer apk, extract the exact LED count→arc mapping, colors, and fade timing, and replace `VolumeLayer`/mute rendering with the exact algorithm.
- **Music visualizer (Plan 3):** audio tap (PipeWire/ALSA monitor) → Android-compatible FFT → ported GLSL LED shaders (`particle_screensaver`, `waveform`, `circles`, …) → frame channel, with the golden-test harness. Performance hot-loop in C.
