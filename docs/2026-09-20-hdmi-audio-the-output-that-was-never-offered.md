# 2026-09-20 — HDMI audio: the output that was never offered

GitHub issue #5: a user with a Yamaha RX-V473 and an LG TV reported no sound
from the Q's HDMI port, on Bluetooth and on AirPlay alike. This is what was
actually wrong, and what it cost to find out.

## The short version

The hardware path had worked the whole time. What had never worked was the
userspace around it — and the feature had, quite literally, never been visible
to a user.

## 1. The hardware was fine, and it took ten minutes to prove

A Samsung soundbar was hung on the Q's HDMI port. Its EDID is a 128-byte base
block plus one CTA-861 extension carrying the basic-audio flag, three Short
Audio Descriptors (LPCM 2ch, AC-3 6ch, DTS 6ch), a speaker allocation of FL/FR
and the HDMI VSDB with source physical address `2.1.0.0`. In other words: a
real, audio-capable HDMI sink — the thing this project had never had.

A tone played to `hw:HDMI,0` was audible immediately, and the wrapper register
agreed:

```
HDMI_WP_AUDIO_CTRL (0x58006088)   idle     0x00000020
                                  playing  0xc05e0020    AUDIO_EN | CORE_REQ
```

So: not a driver bug, not a missing feature in the kernel. `snd_soc_omap_hdmi`
does exactly what it should.

## 2. Why nobody could ever pick it

**The app never showed HDMI.** `OUTPUTS` in `nexusq-control` has carried an
`hdmi` entry since 2026-07-07 (commit `4a1a871`) — and the same commit added:

```python
if sink is None and o["id"] == "hdmi":
    continue  # no real HDMI sink present → don't advertise it
```

together with `91-pulseaudio-hdmi-ignore.rules`, which tags the card
`PULSE_IGNORE`. With PA told to ignore the card, there was never a sink, so the
row was dropped on every single call. The Flutter side had known the `hdmi` id
all along (`models.dart:115`). It was dead code from the day it was written.

**And the output has to be lit.** HDMI has no audio-only mode: the samples ride
in data islands inside the blanking intervals of a video stream. With `fb0`
blanked the DSS is unclocked, and a read of the HDMI wrapper takes an external
abort:

```
Unhandled fault: external abort on non-linefetch (0x1018)
44000000.l3-noc: L3 Standard Error: MASTER MPU TARGET DSS (Read Link)
```

(That trace is self-inflicted — it is this investigation reading `/dev/mem` with
the DSS down — but it is exactly the evidence needed: the IP is not clocked.)
The nasty part is that the ALSA device still *opens* in that state and still
accepts a stream. It plays into nothing and returns no error.

Out of the box the Q settles with `fb0` blanked, because at boot omapdrm logs
`Cannot find any crtc or sizes` — nothing was connected yet — and never comes
back to it.

## 3. The Q cannot wake a sleeping sink. This is hardware.

Worth stating plainly, because it is the one thing the feature does not
promise. The measurement came for free: cutting the signal for 30 s during a
power comparison put the soundbar into standby, and standby on this sink drops
HPD — `status` goes `disconnected` and the EDID goes to 0 bytes.

Forcing the DRM connector (`echo on > .../status`) is **not** enough, and the
registers say why:

```
awake, transmitting   HDMI_WP_PWR_CTRL = 0xaa    PHY = TXON
forced, sink dark     HDMI_WP_PWR_CTRL = 0x5a    PHY = LDOON, tv_clk disabled
```

`hdmi4.c` ties it to the link interrupt and nothing else:

```c
} else if (irqstatus & HDMI_IRQ_LINK_CONNECT) {
        hdmi_wp_set_phy_pwr(wp, HDMI_PHYPWRCMD_TXON);
} else if (irqstatus & HDMI_IRQ_LINK_DISCONNECT) {
        hdmi_wp_set_phy_pwr(wp, HDMI_PHYPWRCMD_LDOON);
}
```

That interrupt is HPD-driven, and forcing the *DRM* connector does not fake it.
We are not blind to HPD by our own fault either: the TPD12S015A's `CT_CP_HPD`
(gpio_60) is set high at probe and stays high, so HPD detection is live the
whole time.

CEC cannot rescue it either. `CEC_CAP_PHYS_ADDR` is not among the adapter's
capabilities, so the driver owns the physical address and derives it from the
EDID — no HPD, no EDID, no physical address, no transmit. The forced-connector
idea was therefore dropped from the design: it achieves nothing measurable.

The contract that remains is the useful one: **the user switches the sink on,
and the hold then makes sure the signal never stops**, so it never sleeps again.

## 4. CEC worked all along and had never been used

```
driver      : omapdss_hdmi     capabilities: TRANSMIT | LOG_ADDRS | PASSTHROUGH
phys addr   : 2.1.0.0          <- read from the sink's EDID by the driver
log addrs   : num=0 mask=0x0   <- nothing in userspace ever claimed one
```

Without a claimed logical address the Q cannot put a byte on the bus. `nq-cec`
now claims a Playback address and announces us. Against the soundbar:

```
-> LA0  Image View On              no ack (0x24)   (no TV powered at LA 0)
-> LA5  System Audio Mode Request  ok
-> LA15 Active Source              ok
```

Note `2.1.0.0` means the Q hangs off port 1 of a device that itself sits on port
2 of the root — there is a TV above the soundbar, and `<Active Source>` is a
broadcast, so it switches that TV's input too. Petr agreed to that explicitly.

## 5. Design decisions, and what they were decided on

**Black screen, not the console** — Petr's call. Worth recording that the two
cost the same; the choice was taste, not power. Three 30 s windows:

| state | interrupts | ctxt switches | idle jiffies |
|---|---|---|---|
| console on tty1, cursor blinking | 15566 | 15114 | 4157 |
| empty VT, cursor off | 14939 | 14640 | 4245 |
| display off entirely | 15154 | 14738 | 4182 |

That is noise. Holding the display up does not show up in CPU wakeups at all —
what it costs is the DISPC scanout and the TMDS PHY, which is SoC-internal power
this board cannot measure (no current sense, only `twl6030_gpadc` rail voltages).
The real lever, if one is ever wanted, is the *mode*: 640x480@60 is 25.175 MHz
and ~55 MB/s of scanout against 1280x720@60's 74.25 MHz and ~212 MB/s, and a
soundbar has no opinion about resolution.

**No second DRM master.** The in-kernel DRM fbdev client already modesets,
already recovers on hotplug (verified: forcing the connector off and back on
re-enabled the output with no help from userspace) and already yields to a
compositor and takes the device back. A KMS client of our own would have to
re-implement all three and fight `tinydm` for mastership on every desktop
toggle. `nq-hdmi hold` steers the client the kernel already has instead:
unblank `fb0`, park the console on `tty8`, fbcon cursor off. Its steady-state
cost is **0.067 % of one core** (4 ticks in 60 s).

## 6. A bug in our own tests

The first live `setOutput hdmi` died with:

```
'Pulse' object has no attribute 'load_module'
```

The three module helpers had been added to `Mixer` instead of `Pulse` — both
classes have a `set_muted`, and the edit anchored on the wrong one. **Every unit
test still passed**, because the fake PulseAudio supplied the methods itself: a
mock describing a world that did not exist, which is the failure mode this repo
has been bitten by before. The suite now asserts that the real `Pulse` carries
what the HDMI path calls on it, that those helpers are *not* on `Mixer`, and
that the fake's surface matches.

The same run exposed a second fault: the failure left `nq-hdmi-hold` running, so
the DSS and the TMDS PHY stayed powered for an output the user had just been
refused. The switch now puts the display back down on any exception, and a test
pins it.

Every new test was seen failing against deliberately mutated code before it was
kept — the EDID verdict against an always-say-yes parser and against one that
ignores the Audio Data Block, the ordering tests against a switch that opens the
device before lighting the output and against one that unloads the sink before
moving the streams.

## Verified on the device

```
nq-hdmi status        connected: True, sink SAMSUNG, audio True
                      (basic audio, 3 audio descriptor(s), LPCM up to 2ch)
setOutput hdmi        hold active, console tty8, fb0 blank=0,
                      default sink = nexusq_hdmi, WP_PWR_CTRL = 0xaa (TXON)
playback              audible; WP_AUDIO_CTRL = 0xc05a0020
setOutput speaker     hold inactive, console back on tty1, cursor restored,
                      HDMI sink unloaded, default sink = tas5713
round trip            back to hdmi, everything restored
no sink attached      hold exits 2 with a plain-language message; systemd does
                      not retry it (RestartPreventExitStatus=2 3)
```

## 7. The first real listen: HDMI has no amplifier to hide a quiet source

With everything working, Petr selected HDMI, played Spotify — and heard nothing.
The Q was provably fine: PHY in `TXON`, `HDMI_WP_AUDIO_CTRL` at `0xc05e0020`,
the sink `RUNNING`, librespot's sink-input on it uncorked at 100 %, CEC acked by
the soundbar. And the same tone that had been audible minutes earlier was still
audible on demand.

What settled it was measuring the signal instead of arguing about it — 4 s off
the sink's monitor:

```
samples=380142  peak=36 (0.1% FS)  non-zero=92.0%
```

Not silence: 92 % of samples non-zero. Music was flowing, about **48 dB below
full scale**. Raising the PA sink from 70 % to 100 % moved the peak 69 → 129, so
the monitor sits after the sink volume and the sink volume genuinely works —
which also disproved an earlier suspicion of mine that PulseAudio reporting
`HARDWARE DECIBEL_VOLUME` on a card with **no ALSA mixer controls at all**
(`amixer -c HDMI scontrols` prints nothing) meant the app's slider was a no-op.
It is not; PA falls back to software volume and it works.

The attenuation was librespot's, i.e. **the Spotify volume for the device**.
Petr raised it and the peak went 129 → 9309, `-48 dBFS` → `-10.9 dBFS`. Audible.

The lesson worth keeping is why this never showed up on the speaker: the TAS5713
is a 25 W class-D part with a famously steep gain on this board (the standing
note is that ~8 % in the app is already deafening), so a source running 48 dB
low is still perfectly loud through it. **HDMI has no such gain to hide behind**
— it hands the sink exactly the samples it was given. So the first thing to
check when an HDMI sink is silent but every register says we are transmitting is
the level arriving at the sink, not the HDMI path.

## 8. Leaving HDMI lingers

Petr's call, out of three options put to him. Releasing the output the moment
another output is picked is cheapest, but because this board cannot wake a sink
that has dropped HPD, every "speaker for a minute, then back" would cost a walk
to the receiver. Holding whenever an awake sink is attached is the other
extreme and would keep the DSS scanout and the TMDS PHY powered on every unit
with a TV in the port. So the hold lingers for 30 min
(`NEXUSQ_HDMI_HOLD_GRACE_S`) and is cancelled the instant HDMI is picked again.

It is a transient systemd timer (`nq-hdmi-hold-release`), not a thread in the
bridge: an OTA of the bridge mid-grace would otherwise strand the output lit
with nothing left to take it down. A failed switch releases immediately, and a
timer that cannot be armed falls back to stopping now — held-forever is the
worse failure.

Verified live, and by accident, which is the best kind: restarting the bridge
made its own `BOOT_OUTPUT=speaker` logic switch away from HDMI, and the timer
appeared armed with 29 min left while `nq-hdmi-hold` kept running. Picking HDMI
again cancelled it.

## 9. Can we wake a dark sink by driving TMDS anyway? Measured: no.

Petr asked for the one experiment I had flagged as untried, so it was run. With
the soundbar asleep and HPD dark, the connector forced on and the DSS clocked,
`HDMI_WP_PWR_CTRL` was written directly through `/dev/mem` to put the PHY in
`TXON`, bypassing the driver's HPD gate entirely:

```
before:      PWR_CTRL=0x5a  phy_cmd=LDOON phy_status=LDOON
after 0.2s:  PWR_CTRL=0xaa  phy_cmd=TXON  phy_status=TXON
```

**The hardware accepted it** — the PHY really did reach TXON and transmit into a
line with no HPD, which the driver will never do on its own. It was held there
for a full 60 s:

```
t+  5s  edid=0  phy=TXON
 ...
t+ 60s  edid=0  phy=TXON
```

The sink never came back. `HDMI_WP_IRQSTATUS_RAW` never showed a link event
either. So driving TMDS blind is *possible* and *useless*: this soundbar in
standby is not watching the link at all. The register was restored to `0x5a`
and the connector handed back to the driver; nothing was wedged.

That closes the question for good, and it also means the design is right to stop
trying. Worth keeping in mind for other hardware, though: the limitation is this
sink's standby behaviour, not a universal one — plenty of AV receivers keep HPD
asserted in standby precisely so CEC can reach them, and on those the
`<Image View On>` / `<System Audio Mode Request>` that `nq-cec` already sends
would wake them.

## 10. One path ships untested, deliberately and knowingly

`_keep_black()` — putting the console back on the black VT after the HDMI
desktop has been toggled on and off — has **never run against a real `tinydm`**.
The hold only runs with an awake sink attached, and there was no way to keep the
receiver awake for the test (2026-09-20, Petr: "nemam jak vyzkouset na
soundbaru"). So it is shipped untested on hardware, on purpose, with the risk
bounded rather than hidden:

* Its decision logic *is* pinned (`tests/test_hdmi_hold_guard.py`): a compositor
  holding DRM master is left alone, a drifted console is re-parked, and "cannot
  tell" does nothing — because acting on a guess means a `chvt` underneath a
  running compositor, the one outcome worse than a console on screen. Both
  mutations (treating "cannot tell" as "no master"; finding the master column by
  position instead of by name) were seen failing.
* The worst case if the live path is wrong is **cosmetic**: the console ends up
  on the wrong VT. Audio does not depend on any of it — that needs only `fb0`
  unblanked, which `_keep_lit()` handles on its own.

Whoever next has a receiver they can keep awake: start the hold, toggle the
desktop on and off from the app, and check the console comes back to `tty8` with
the output still lit.

## Open, not fixed here

- **The selected output does not survive a reboot.** `BOOT_OUTPUT` is `speaker`,
  so after a restart the Q stops holding the output, the sink sleeps, and the
  user has to both re-select HDMI and switch the sink on by hand. This is
  pre-existing behaviour for all three outputs; making it persistent is a
  product decision, not a bug fix.
- ~~**`[drm] User-defined mode not supported: "1280x720"`**~~ — **explained,
  and benign.** It is not a race and not a fault. Two variants appear:

  ```
  "1280x720": 60 74250 1280 1390 1430 1650 ... 0x60 0x5   EDID mode, DRIVER|USERDEF
  "1280x720": 60 74440 1280 1336 1472 1664 ... 0x20 0x6   CVT mode,  USERDEF only
  ```

  With a sink present, `drm_helper_probe_add_cmdline_mode()` tags the matching
  EDID mode `USERDEF` (74.25 MHz). With no sink there is nothing to tag, so it
  *creates* one from the cmdline via CVT (74.44 MHz). Either way, a probe that
  finds the connector **disconnected** marks every mode `MODE_STALE` and
  `drm_mode_prune_invalid()` drops them all — printing the warning for whichever
  one still carried `USERDEF`. So it fires **once per connect→disconnect
  transition**, and is silent on every further disconnected probe because the
  tagged mode is already gone. That is exactly the "intermittency" that looked
  like a DDC race: three repeat cycles on an already-absent sink produced
  nothing. Nothing to fix; forcing a cheaper mode from the cmdline is not
  blocked by it after all.
- **245 directories in the image carry group `12345`** — pmbootstrap's build uid
  leaking through its install step, not anything our packages do (the device
  apk's own entries are `root:root`). Modes are 755, nothing is group-writable,
  and on the device that gid maps to no group, so it is cosmetic. Noticed in the
  v1.18.0 public build and **not diffed against an older release**, so nobody has
  established whether it is new; `output/nexusq-rootfs-v1.17.0-sparse.img.zst` is
  still there to check against before anyone quotes it as historical.

- **`nq-hdmi` is not yet wired into `nq-diag-snapshot`.** An HDMI audio row
  there would make the state visible in a routine sweep.
