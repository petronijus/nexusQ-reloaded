# Changelog

All notable changes to Nexus Q Reloaded. Format follows
[Keep a Changelog](https://keepachangelog.com/). Versioning is tag-only
(milestone-based) — there is no version string in the source.

## [Unreleased]

### Found — Roon costs 36 % of a core doing nothing, and does not stop when switched off (2026-08-26)
- A four-hour "every service on, nothing playing" benchmark, with zero playback
  events in the journal: **pulseaudio 34.10 % of a core** (0.02 % without Roon),
  nexusqd 7.43 %, die **72–78 °C** against 55–59 °C. RoonBridge holds its aloop
  stream open while idle, so its `module-loopback` never corks, PulseAudio
  resamples forever and the sink never suspends — **structurally the same fault
  Step 6 removed from USB audio**, arriving through a different source.
- ⛔ **`setService roon off` does not stop it.** The unit goes inactive and every
  Roon process exits, but `roon-nexusq` never unloads the two PA modules it
  loaded, so PulseAudio kept burning **34.58 %** from a source with nothing
  behind it. Turning Roon off in the app leaves the device hot until PulseAudio
  restarts. `nexusq-uac2-in` already unloads its modules in a SIGTERM trap and is
  the model to copy. Not yet fixed — PLAN.md Step 8a.
- Nothing here is a regression from our work: the watcher suspended `usb_in`
  correctly throughout. It simply cannot win while another source holds the sink.

### Added — per-source transport routing (2026-08-26, `nexusq-control` r33+)
- `nowPlaying.transport` (`device` / `spotify-web` / `none`) tells a client
  whether its buttons work without knowing which source is playing. It reports
  what is **actually wired**, never what is possible in principle — a source
  whose backend is missing, or present but not yet able to control, says `none`.
  Advertising a capability we do not have would just move the dead buttons.
- **librespot stays.** Checked against upstream rather than our own comment: its
  changelog has never carried an API, D-Bus, MPRIS or socket, and the request is
  open as issues #457/#1473. Upstream's answer is "another Spotify client, or the
  Web API" — so the app will do that and the device is left alone, instead of
  swapping in go-librespot (twice the binary, native deps, our own Go build).

### Fixed — USB audio stops computing silence (2026-08-25, device **r82**)
- The UAC2 host never closes the stream: the gadget capture advances for the whole
  uptime whether anything plays or not. So PulseAudio resampled 48000 → ~48003
  forever, the amp sink never suspended, and **28.83 % of a core** went on silence
  — of which PulseAudio alone was 27.17 %.
- `nq-uac2-silence` watches for digital silence and suspends the PA **source**.
  Idle → **3.13 %** of a core, relative dynamic power 1.26× → 1.09×, and the wake
  turnaround is **1 ms**.
- **Idle really is exact digital silence** — 960 000 samples captured with the box
  idle, every one 0 — so the test is for zero with **no threshold**, and can never
  mistake a quiet passage of real music for silence. (An earlier capture that
  suggested otherwise was taken while Petr was playing something: it measured his
  music. A measurement taken in the wrong state answers the wrong question.)
- ⛔ **The sink is never suspended, only the source.** `suspend-sink` is a sticky
  *user* suspend: with it set, a second player's stream created a sink-input and
  the sink still read SUSPENDED — the audio went nowhere. Suspending the source
  alone lets `module-suspend-on-idle` take the sink down, and any other player
  brings it straight back. Both directions measured, not assumed.
- **The wake latency was 135 ms; it is now 1 ms, and the obvious suspect was
  innocent.** Shortening the ALSA period changed nothing at 512, 1024 or 2048
  frames. The real cost was 65 ms waiting for a polite SIGTERM to `arecord` — it
  must release the aloop before PulseAudio can reopen it — plus 70 ms forking
  `pactl`, the same `pactl` that round-trips in 0 ms from a shell. Forking a
  Python interpreter on an OMAP4 at 350 MHz is the expensive part, not
  PulseAudio. Fixed with SIGKILL and a persistent PA CLI socket.
- Watching is asymmetric and so is the watcher: awake, PulseAudio owns
  `hw:Loopback,1,0` (arecord there gets EBUSY) so it watches through `parec`;
  asleep, PA has closed it, so it owns the aloop directly. A `parec` watcher
  cannot do the asleep half at all — connecting to a suspended source resumes it.
- **Correction (2026-08-25): the "sink settles at IDLE" known issue was a
  measurement artifact and is withdrawn.** It came from a reading 45 s after a
  service restart, when nexusqd animates its screensaver at ~1.4 % of a core
  until the memcmp gate settles it to ~0.07 % at ~300 s. In steady state the sink
  reads SUSPENDED and nexusqd costs 0.10 %. A nexusqd gate change built on the
  artifact (r15) was then judged a regression by comparing a settled daemon
  against a freshly restarted one — the same trap in reverse — and reverted as
  r16. **Never A/B a restarted daemon against a long-running one.**
- **Steady state as shipped** (device r82 + nexusqd r16), source idle:
  **2.05 % of a core, sink SUSPENDED**, against 28.83 % before.
- ⚠️ The wake path was proven by feeding the aloop a 14 s-silence-then-tone file
  and logging the transitions; the Xiaomi box refuses adb, so "alsaloop delivers
  non-zero when the box plays" is the one link confirmed only by inspection.

### Added — save your own EQ presets (2026-08-24, `nexusq-control` **r33**, app **1.16.2+46**)
- Petr, after the parametric EQ landed: *"jeste misto toho flat ikonka resetu a pak
  tam moznost ulozit si co jsem si zrovna nakonfiguroval a pojmenovat a taky smazat.
  Takze udelat si custom preset."*
- **Flat is now a reset icon**, not a chip. Flat is where the EQ *starts*, so undoing
  your edits is an action, not one preset among several — and the icon gives the row
  back to the presets that are. It zeroes every band and the preamp; **widths are left
  alone**, because a reset that also discarded tuned Q values is a bigger hammer than
  the button reads as.
- **Saved presets live on the Q**, in `/etc/nexusq/eq-presets.json` — a file of its
  own, so a mangled preset list can only ever cost you presets, never the live EQ.
  They belong to the speaker: they survive reinstalling the app and every phone sees
  the same ones. Protocol §14.6 `saveEqPreset` / §14.7 `deleteEqPreset`, both
  answering with the whole list and emitting `eqPresetsChanged`.
- The **id is derived from the name**, so saving "Vinyl" twice replaces rather than
  piling up near-duplicates — and the dialog says *Replaces…* before you commit,
  because the app mirrors the daemon's slug rule exactly. Unicode-aware on both
  sides: the daemon uses Python's `str.isalnum()`, so `Kuchyň` → `u:kuchyň`, not
  `u:kuchy-`. Getting that wrong would make app and device disagree about what
  replaces what.
- Built-ins carry `"builtin": true` and offer no delete; only your own chips have a
  ×, so the affordance itself says which presets are yours. A daemon that predates
  saving omits the flag, and the card then shows **no save button** instead of one
  that can only fail.
- Stored bands are re-validated on the way **out** as well as in, so a hand-edited
  file can never hand the amplifier a coefficient `setEq` would have refused. At most
  24 presets, names ≤24 characters.
- **Save is pinned outside the chip scroller** — a regression a test caught first:
  inside it, every preset you saved pushed the save button further off-screen,
  exactly when you had most use for it.
- **Card polish, from looking at it on the phone (1.16.1):** the frequency labels
  moved out of the plot into a strip of their own below it — inside, they collided
  with the −12 dB label in the bottom-left corner and sat under the curve. The plot
  keeps its full height; the strip is extra. The permanent "runs in the amplifier
  hardware" line is gone: true, but you read it once and it sat there forever, so the
  hint line now speaks only when something is wrong. And the card is **black instead
  of grey** — the plot is most of it, and on the page's own black it stopped reading
  as a panel bolted on top.
- **A detent at 0 dB (1.16.2).** Petr: *"kdyz draguju ty body equalizeru a chci je
  vratit na 0, muze tam bejt nejakej snap na ten flat? ted to nejde vubec chytit
  perfektne."* Come within ~7 px of flat and the band snaps exactly onto it, with a
  haptic click on the way in only. The half-width is in **pixels of finger travel,
  not dB** — what makes flat hard to hit is the hand, not the scale, so the target
  must be the same size whatever the plot's height or range. Gain is continuous, so
  without it a band lands on ±0.1 dB and the curve never quite lies down.
  A too-wide detent is caught by the existing drag tests, not just the new ones.
- Verified on the device: save → daemon restart → still there; replace kept one
  entry; blank / punctuation-only names and deleting a built-in all refused with the
  right reason; the live EQ untouched throughout. 43 daemon tests, 64 app tests, and
  **every new assertion was watched failing** — seven separate mutations, each
  reddening exactly its own test.

### Added — parametric 7-band EQ (2026-08-24, `nexusq-control` **r32**, app **1.15.3+39**)
- Petr, after using the bass/treble card: he wanted the modern-standard equalizer —
  a visible curve, more handles, presets, on the home screen. The hardware already
  allowed it: the TAS5713's EQ bank is **7 biquads per channel** and only two were
  used, so five sat idle. All seven now drive a curve with **draggable handles**.
- **Preamp** with a headroom readout, a clipping warning and one-tap auto. It folds
  into band 0's feed-forward coefficients — the amp's `Master`/`Speaker` volumes are
  the **user's** volume and are never hijacked for headroom.
- Protocol §14 v2 **extends rather than breaks**: `getEq` still returns
  `bass_db`/`treble_db` derived from the shelf bands, so the shipped 1.14.0 app kept
  working, and an app updated ahead of its device falls back to two handles instead
  of an empty panel.
- **Verified on the hardware, not on the drawing**: coefficients read back off the
  amp and evaluated as a transfer function measured **within 0.25 dB** of the
  requested curve everywhere; auto-preamp cancelled the peak to −0.00 dB; both
  channels identical; Flat returned 14/14 unity.

### Fixed — three EQ UI faults that shipped past green tests (1.15.1 → 1.15.3)
- **The curve could not be dragged — the page scrolled instead.** `pan` accepts
  after `kPanSlop` (36 px), a scrollable's vertical drag after `kTouchSlop` (18 px),
  so the scroll wins fairly. Overriding `rejectGesture` to accept does **not** take
  the gesture back; the arena already awarded it, so both ran and everything moved
  twice. Fixed with vertical + horizontal recognizers, which accept at the same
  distance and are inner, so they win properly.
- **"EQ unavailable: not connected"** on a cold start — the card loads in
  `initState`, before the link is up. It now waits for the connection.
- **Dead after the first drag.** A real `setEq` is ~300 ms (14 I2C writes); the card
  disabled itself for that window *and* dropped anything arriving during it. It now
  stays live and queues the newest write.
- ⚠️ **All three had passing tests.** The drag test's host was a scroll view with
  nothing tall enough to scroll, so it never entered the gesture arena; the fake
  client replied instantly, so the "sending" state never existed. Both are fixed,
  and every repair was kept only after reverting the code and watching the test go
  red. **A test you have not seen fail is not a safety net.**
- ⛔ **Rejected:** writing only changed bands (~40 ms instead of ~300 ms). Petr:
  *"to nemusí být okamžité, ať to zbytečně nezatěžujeme."* The queue already makes
  it feel fine, and skipping registers means tracking what the amp last received —
  state that breaks the moment anything else writes a coefficient.


### Shipped — hardware EQ, GitHub issue #2, end to end (2026-08-24, app **1.14.0+35**)
- Companion app **1.14.0+35** built (23/23 tests, EQ strings verified present in the
  binary rather than assumed), released as `app-v1.14.0`, OTA manifest bumped to
  versionCode 35 and the download path checked live (HTTP 200, 55 809 137 B).
- **Petr updated over OTA and confirmed it works.** Request → biquads in the
  TAS5713's own DSP → kernel r49 → the 32-bit write bug → kernel r50 → app → heard
  and approved, all in one day.
- Release notes carry the one thing feature-detection cannot catch: on kernel r49
  the controls exist so the card looks available, but the write path is broken.
  r49 was published for a few hours and is superseded by r50.


### Fixed — the hardware EQ works: an upstream 32-bit bug (2026-08-24, kernel **r50**, patch **0046**)
- `tas571x_coefficient_info()` advertises `uinfo->value.integer.max = 0xffffffff`,
  but `snd_ctl_elem_info` carries bounds in a `long` — **32-bit on armv7**, so the
  control came out with `max = -1` and alsa-lib clamped **every** write to
  `0xFFFFFFFF`. Patch 0046 advertises `0x3ffffff` instead (3.23 fixed point, 26
  significant bits, unity `0x00800000`). Its own patch, not folded into 0045: it is
  an upstream bug, and 64-bit builds never see it.
- Deployed via `nq-kernel-ota` → trial slot → **auto-promoted unattended**.
  `amixer cget` now reports `min=0,max=67108863`.
- **Verified twice, neither by read-back alone.** On the wire: unity gives
  `[29-00-80-00-00-…]` and `1000,2000,3000,4000,5000` gives
  `[29-00-00-03-e8-00-00-07-d0-…]`, byte-exact. And by transfer function, from
  coefficients read **off the amp**:

  | | bass +3 | bass −6 / treble +6 | flat |
  |---|---|---|---|
  | 20 Hz | **+3.00 dB** | −5.99 dB | 0.00 |
  | 100 Hz | +1.50 dB | −3.00 dB | 0.00 |
  | 1 kHz | 0.00 | 0.00 | 0.00 |
  | 8 kHz | 0.00 | +3.00 dB | 0.00 |
  | 16 kHz | 0.00 | +5.92 dB | 0.00 |

  Half the gain exactly at the design frequency is the textbook shelf midpoint.
- ⚠️ Decode raw coefficients through **two's complement**: a naive `raw / 8388608`
  shows `b1` as `+6.0170` and `a2` as `+7.0168` and reads as garbage — they are
  −1.983 and −0.983.
- Left at unity with `/etc/nexusq/eq.json` flat. **Remaining:** a ≤1–2 % listening
  test and the **app 1.14.0+35 release, pending Petr's approval**.


### Confirmed — Petr's listening test passed for `down_threshold=60` + the NEON resampler (2026-08-24)
- "za mě dobrý". The governor tuning is **closed**: it descends mid-track without
  audible cost. Objective backing from the same window — **94.28 % @ 350 MHz**,
  die **67 °C**, **777 transitions (0.37/s)** so the clock really was moving during
  playback rather than parked, and **zero xrun/underrun/dropout** in dmesg and
  journal.
- ⛔ Does **not** cover the hardware EQ, which stays broken and excluded
  (`docs/2026-08-24-eq-biquad-write-broken.md`).


### Deployed — kernel **r49** + `device-google-steelhead` **r81** (2026-08-24)
- `nq-kernel-ota stage-latest` → trial slot → `try` → **auto-promoted unattended**
  (`trial boot marker found` → `healthy after 0s — promoting` → `promoted and
  disarmed` → package DB reconciled). The A/B kernel path proven again end to end.
- `device` r81 live: `nexusq-cpufreq-tune` logs **`down_threshold 20 -> 60` at
  boot**, so the idle-power fix is no longer a live-only knob. `perf` now ships in
  the image.

### ⛔ Broken — the hardware EQ writes `0xFFFFFFFF` into the amp (kernel patch 0045)
- Kernel r49 exposes all 14 `CH1/CH2 - Biquad 0..6` controls and `getEq` reports
  `supported: true` — but **every write through them puts `0xFFFFFFFF` into the
  TAS5713's coefficient RAM, whatever value was asked for.** Confirmed with ftrace
  on `i2c:i2c_write`, not inferred: asking for unity (`8388608,0,0,0,0`) and for
  `1000,2000,3000,4000,5000` both produced `[29-ff-ff-ff…]`, 20 bytes of `0xFF`.
- **Cause:** mainline's `tas571x_coefficient_info()` sets the control max to
  `0xffffffff`; ALSA holds bounds in a `long`, which is **32-bit on armv7**, so the
  max becomes **−1** and every write clamps to `0xFFFFFFFF`. An upstream bug that
  cannot manifest on 64-bit. The tell is `amixer cget` printing `min=0,max=-1`.
- `amixer cget` returning `67108863` is **not** a second bug — that is `0x3FFFFFF`,
  the 26-bit mask of what was really written. Reads are honest.
- ⚠️ **The amp keeps its coefficients across `systemctl reboot`** — the reboot does
  not power-cycle the TAS5713, so garbage survived two reboots. All 14 biquads were
  restored to unity with `i2cset -y -f 3 0x1b <reg> …` (regs `0x29`–`0x36`, mode
  `i`) and **verified 14/14 by read-back**; `/etc/nexusq/eq.json` reset to flat,
  which is what stops `eq_restore_thread` re-applying it at the next boot.
- **Blocked until fixed:** patch 0045 must also set a real control bound (26-bit
  3.23 ⇒ `0x3FFFFFF`) → kernel **r50**, then re-verify **on the wire**. ⛔ No EQ
  listening test, and **app 1.14.0+35 stays unreleased**.
  Full record: `docs/2026-08-24-eq-biquad-write-broken.md`.


### Added — speexdsp rebuilt with NEON: 1.34–2.86× faster resampling (2026-08-24, `speexdsp` **1.2.1-r100**, published + live)
- `perf` put **58.86 %** of PulseAudio's sink thread inside `libspeexdsp`. Alpine's
  armv7 build is **scalar** — `Tag_FP_arch: VFPv3-D16`, no `Tag_Advanced_SIMD_arch`,
  0 vector q-register f32 instructions — which is correct of Alpine (armv7 must run
  on parts without NEON) but leaves the OMAP4460's NEON unused. New
  `pmos/speexdsp/` overlay rebuilds it with `--enable-neon`: **NEONv1, 26 vector
  instructions**.

  | ratio | Alpine r2 | ours r100 | speed-up |
  |---|---|---|---|
  | 48000 → 48003 (USB drift) | 2657 ns | 1898 ns | **1.40×** |
  | 48000 → 48000 (1:1) | 1368 ns | 478 ns | **2.86×** |
  | 44100 → 48000 (Spotify) | 2820 ns | 2105 ns | **1.34×** |

- ⚠️ **This does NOT fix the ~25 % of a core spent on silence.** A 1.4× cheaper
  resampler still resamples silence forever; that needs the resampling to stop
  (PLAN.md Step 6). Shipped because 1.34× on every Spotify track stands on its own.
- Two build gates make a silently-scalar rebuild impossible: `#define USE_NEON` in
  `config.h`, and `Tag_Advanced_SIMD_arch` on the linked `.so`. A **Phase 10 SHIP
  CHECK** reports whether the rootfs got our `-r100` or fell back to Alpine's `-r2`.
- ⚠️ `pkgrel=100` is a version pin so apk prefers ours. It holds only while `pkgver`
  matches — an upstream bump silently returns the scalar build.

### Added — `scripts/diag/bench-speex-resampler.py`, and two measurement traps it exists to close
- **The governor invents benchmark results.** Three *unpinned* runs of the identical
  library comparison reported **0.75×, 0.95× and 1.26×** — the first briefly
  "proved" the NEON build was a regression and nearly got it reverted. The
  benchmark drags the clock up, the die throttles, and ns/op then depends on which
  OPP the sample landed on. Pinned at 350 MHz, repeats agree to **~1.5 %**.
- **A resampler cannot be measured in situ.** `module-loopback`'s rate controller
  wanders between exactly 48000 and ~48003 Hz, and speex picks a different inner
  loop from the ratio's *denominator* (1/1 and 147/160 → the NEON-accelerated
  direct path; 16000/16001 → the interpolate path, which has no NEON version). Two
  PA samples minutes apart therefore compare different workloads.
- The tool pins the governor and restores it **together with the `conservative`
  tunables** — switching governor resets them, which silently reverted a measured
  `down_threshold` 60 → 20 mid-session.
- Rejected on the same rig: **r101** (NEON via `CFLAGS` without `--enable-neon`) —
  0.99× / 2.15× / 0.98×, no better than stock except at 1:1. `--enable-neon`'s
  `-O3 -march=armv7-a` is what carries the non-NEON interpolate path. Deleted from
  the build volumes so a later publish cannot pick it up as "newest".

### Deployed (2026-08-24) — `speexdsp` r100, `nexusqd` r14, `nexusq-control` r31
- Installed with `apk add --upgrade <names>`, kernel untouched at r48, `world`
  entries left as plain names.
- ⚠️ **`device-google-steelhead` r81 is published but NOT installed**: adding it
  drags `linux-google-steelhead` r48 → r49 (apk v3 upgrades an explicitly-added
  package's dependencies), and apk must never apply a kernel — it deletes the
  running kernel's `/lib/modules`. It goes on in the same session as the kernel OTA.
  Until then `down_threshold=60` is live-only and any governor switch resets it.


### Added — `perf` in the image, and an audit that proves nothing else is live-only (2026-08-24, `device-google-steelhead` **r81**)
- Profiling settled the PulseAudio question in one shot, so `perf` belongs in the
  image rather than in whoever's ssh session. Added to `depends` next to the
  existing `gdb`/`i2c-tools` diagnostics. Folded into **r81** (unpublished), no
  extra revision. The kernel always had `CONFIG_PERF_EVENTS`; only userspace was
  missing.
- **Two commands now prove nothing is live-only** — do not rely on memory:
  `cat /etc/apk/world` (anything our `depends=` does not pull is a live install a
  reflash loses) and `apk audit --system` (files differing from their package).
- Result of running them: the device is **clean**. `apk audit` reports exactly two
  files — `gschemas.compiled` (glib regenerates it) and
  `usr/share/pulseaudio/alsa-mixer/paths/analog-output-speaker.conf` (rewritten by
  our own `device-google-steelhead.trigger`). Both expected, both in the build.
- ⚠️ **Fixed a latent OTA trap:** `linux-google-steelhead` and `nexusq-mqtt` were
  pinned in `world` as `name><Q1<checksum>=`. apk-tools 3 writes that when a
  package is installed **from a local file** (`apk add /path/foo.apk`) rather than
  a repo, which can make a later OTA silently refuse to upgrade it — the same
  class of failure as a dependency missing from `publish-ota-repo.sh`. Cleared
  with a plain `apk add linux-google-steelhead nexusq-mqtt`: rewrites the entries,
  changes no packages. `nq-kernel-ota` was **not** the cause — it correctly
  `apk fetch`es the payload and only ever `apk add --upgrade <name>`s by name.


### Fixed — USB Audio idle burned 5× the power; one governor knob recovers it (2026-08-24, `device-google-steelhead` **r81**)
- With "USB Audio" enabled and **nothing playing**, the Q sat at 1200 MHz /
  1380 mV **90 % of the time**, die **84 °C**, **6.0×** a locked-350 floor —
  the whole idle-power programme (90.8 % @ 350 MHz) erased by one toggle.
- Root cause is **not** load: the USB gadget fires **1000 IRQ/s** whenever the
  host is attached, and `conservative` *holds* the clock anywhere between
  `down_threshold` and `up_threshold`. That put every 20 ms window inside the
  40–80 band, so the governor had **no rule that could ever descend** and
  parked wherever the first spike left it. Tell: high OPP + a *low* transition
  rate (0.06/s) + `scaling_min_freq` already at 350000.
- Fix: `nexusq-cpufreq-tune` raises `down_threshold` **40 → 60** — the same
  failure the 20 → 40 change fixed in 2026-08-16, one band higher. Measured
  with USB Audio live: **97.3 % @ 350 MHz, 1.07× the floor, 68 °C** — better
  than this device's USB-*off* idle baseline (1.16×). `up_threshold`,
  `sampling_rate` and `freq_step` untouched ⇒ **ramp-up is unchanged** (3 ×
  20 ms ≈ 60 ms).
- Five-arm study (`nq-opp-study2.sh`, 20 min each): `base` 6.03× → `sr100up95`
  3.12× → **`down60` 1.07×** → `powersave` (locked 350) 1.00× → `base2` 6.04×
  (control: reproduces `base` to 0.2 %). `musb` held 1000.0 IRQ/s in every arm
  and per-cgroup work normalised by frequency was constant, so the arms are
  directly comparable. Full numbers: `docs/2026-08-24-usb-audio-idle-cost.md`.
- Ruled out along the way: the `sampling_rate=100 ms`+`up_threshold=95`
  variant (98.7 % on plain idle, but only **35 % / 3.12×** here *and* a ~300 ms
  ramp) **stays unshipped**; and PulseAudio's silence-resampling is **not**
  what pinned the clock — `down60` reached 97.3 % with PA still resampling at
  48003 Hz, so the attended "unload the PA loopback" experiment is off the
  critical path as a power fix.
- ⚠️ Applied **live** on the device (holding 94 % @ 350 MHz, 84 → 74 °C) but
  **not yet in a built image**: r81 needs a rootfs build + Petr's listening
  test before the knob is permanent (it governs only the descent, so the
  exposure is the ramp production already ships with USB Audio off).
- Still open, now on **efficiency** grounds only, not power: at 350 MHz the
  same silence costs `user.slice` 20.7 % and `nexusqd` 3.9 % of one core.
  `nexusqd` **r14** (silent-tap render gate) is built and undeployed.


### Added — hardware EQ on the TAS5713 (GitHub issue #2) — CODE + BUILDS ONLY, not yet deployed (2026-08-23, kernel **r49** + `nexusq-control` **r31** + app **1.14.0+35**)
- Issue #2 (terierbread360) asked for a bass control. Implemented **in the
  amp's own DSP**, not in software: kernel patch **0045** exposes the
  TAS5713's per-channel biquad bank (7+7 filters, regs 0x29–0x36 — the
  driver's TAS5707 plumbing reused; coefficient I/O bypasses regmap, so no
  regmap changes) as `CH1/CH2 - Biquad 0..6` ALSA controls. Post-mix ⇒ one EQ
  for Spotify/AirPlay/Roon/USB alike, zero CPU, zero latency.
- `nexusq-control` r31: PROTOCOL **§14** `getEq`/`setEq` + `eqChanged` —
  `bass_db`/`treble_db` ±12 dB → RBJ low-shelf @100 Hz (BQ0) / high-shelf
  @8 kHz (BQ1) on both channels, computed for the chain's pinned 48 kHz,
  packed 3.23 (TI negated-a convention, pinned word-for-word against the
  known-good kungpfui/tas5713-biquad packing); an **unstable filter is
  refused before any register write** (speaker safety). Persisted in
  `/etc/nexusq/eq.json`, re-applied at daemon start (DAP powers up flat).
  12 new tests (shelf response measured from the transfer function; 31/31
  suite green).
- App 1.14.0+35: **Settings → Sound → Equalizer** card (bass/treble sliders
  + Flat), sends on gesture end, reconciles via `eqChanged`, greys out with
  an update hint on a pre-r49 kernel (`supported` feature-detect). 3 new
  widget tests (23/23 green). **Not released** — needs Petr's approval.
- ⚠️ NOT on the device yet: the overnight USB-idle measurement blocks any
  device contact tonight. Deploy plan (kernel via nq-kernel-ota incl.
  /lib/modules, control via apk OTA, low-volume verification) in PLAN.md
  "Hardware EQ".

### Changed — GitHub Pages landing page redesigned + self-updating package table (2026-08-23, `gh-pages` + `scripts/publish-ota-repo.sh`)
- The OTA repo's landing page (https://petronijus.github.io/nexusQ-reloaded/)
  was a single unstyled paragraph; replaced with a self-contained dark page —
  animated LED-ring hero (CSS conic-gradient, the Q's signature ring), on-device
  install steps (incl. the `--ignore linux-google-steelhead` kernel note), a
  published-packages table, and a footer with the signing key + APKINDEX link.
- The table lives between `OTA:TABLE:START/END` markers and is **regenerated by
  `publish-ota-repo.sh` on every publish** from the freshly signed APKINDEX
  (name/version/size/description + publish date), so the public page can never
  show stale versions. The publish fails loudly if the markers go missing.
  `index.html` itself survives publishes — the script only replaces `nexusq/`
  and the marker block.

### Fixed — nq-healthd log rotation orphaned its own stream → "Health sampler" outage in HA (2026-08-23, `device-google-steelhead` r79→**r80**; package-only rebuild, OTA-published, live-verified)
- Introduced by the C rewrite (r77): `rotate_if_big()` renamed `health.jsonl` →
  `health.jsonl.1` past the 4 MiB cap but never closed the daemon's open
  `FILE *` — the stream followed the renamed **inode**, so every later sample
  went into `.1` (**25 MB and growing, unbounded** — rotation stats a path that
  no longer existed) and `health.jsonl` was never recreated. `nexusq-mqtt`
  stats `HEALTH_PATH` → **`healthd_fresh:false`**, HA lost temp/freq/governor
  and raised the "Health sampler" problem sensor, with `nq-healthd.service`
  running and sampling the whole time. Bug window r77–r79 (the shell daemon
  reopened per append, so its rotation was accidentally safe).
- Fix: `rotate_if_big(FILE **outp)` `fclose()`s + NULLs the stream after a
  successful rename, so the next sample's reopen creates a fresh `logpath` —
  readers stat the path, so the path must be what the daemon writes. Fixed in
  both synced copies (`userspace/nq-healthd/` + `pmos/device-google-steelhead/`).
  **Verified live: `healthd_fresh:true` on the broker.**
  `docs/2026-08-23-healthd-rotation-and-ota-holdback.md`.

### Fixed — OTA repo: a missing `OTA_PACKAGES` entry silently froze the fleet at r77 (2026-08-23, `scripts/publish-ota-repo.sh`)
- `device-google-steelhead` depends on **`nexusq-rootfs-ab`** since the A/B
  rootfs work (2026-08-20), but `publish-ota-repo.sh` never learned the new
  aport — the repo offered r78+ with an unsatisfiable dependency, and
  `apk add --upgrade` treats that as "nothing to do", **exit 0, no error**:
  the device silently kept **r77** (exactly the range carrying the rotation
  bug above). Diagnosed via `apk policy` (r80 offered?) + forcing
  `apk add device-google-steelhead=1.0-r80` (apk finally prints the
  unsatisfiable dep).
- Fix: `nexusq-rootfs-ab` added to `OTA_PACKAGES`, repo republished, device
  upgraded r77→r80 and verified. **Rule: any new runtime `depends=` of an
  OTA-shipped package goes into `OTA_PACKAGES` in the same change.** Also
  published `nexusq-kernel-ota` **0.1.0-r3** (built 2026-08-20, had sat in the
  workdir).

### Fixed in the field — 5 GHz back: router pinned to channel 36 (2026-08-23, no code change)
- The 2026-08-20 DFS finding resolved as recommended: the AP had auto-selected
  **ch100/5500 MHz**, which the BCM4330 (`ccode=US`, world regdomain) never
  reports; Petr pinned the router to **ch36** → the Q re-associated on its own
  at **−52 dBm, 5180 MHz**. The device clock had sat in **year 2000** the whole
  offline stretch (no RTC, no NTP off the USB link); timesyncd fixed it after
  reconnect, and MQTT telemetry came back online.

### Added — A/B rootfs + rescue initramfs, proven both directions (2026-08-20/21, `nexusq-rootfs-ab` r1 · `nexusq-kernel-ota` r3 · device r77–r79) *(backfilled 2026-08-23)*
- p13/p14 A/B rootfs split with the slot marker in p7 misc and health-gated
  auto-promote; the "u-boot ignores the ramdisk" belief was WRONG (bad load
  address — `0x84000000` works). The built boot.img now carries the A/B
  initramfs (repack is byte-reproducible); the kernel-OTA packer takes a
  ramdisk (`current_ramdisk`) so a kernel update no longer deletes it; the
  promote units gained the `After=` ordering fix (a `Type=oneshot` `WantedBy=`
  blocks its own target). r79 trial-booted through the kernel-OTA slot and
  promoted in the same boot. Full record:
  `docs/2026-08-20-rescue-initramfs-and-ramdisk-address.md`.

### Changed — nq-healthd rewritten in C · nexusq-mqtt volume from the control bridge (2026-08-20, device **r77** · `nexusq-mqtt` **r4**) *(backfilled 2026-08-23)*
- The shell healthd still cost **3.08 % of a core** after every diet — roughly
  three quarters of all idle CPU. The C daemon measures **0.550 %**, system
  forks 2.45 → **0.75/s**; every probe that forked is now a syscall, the JSONL
  schema verified field-by-field against the shell (`--once` side by side, 30
  fields identical — which caught an `avr_irq` parser bug and preserved
  `dmesg_err`'s historical semantics). `systemctl show` stays the one rationed
  fork.
- `nexusq-mqtt` r4 closed the last idle `pactl` forker: volume/mute now comes
  from `nexusq-control`'s persistent subscribe bridge over loopback (mixer
  probes kept as fallback; 6 new bridge-failure tests, 34 pass). Forks
  0.75 → 0.71/s.

### Measured — idle OPP residency after the 08-13 fixes: **70.7 % @ 350 MHz** (2026-08-16, 79 h passive window)
- The A/B the 08-13 session asked for, settled from 79 h of undisturbed idle:
  **350 MHz 70.69 %** (was 60.5 %, **+10.2 pp**) · 700 MHz 22.56 % · 920 MHz
  6.04 % · **1200 MHz 0.71 % (was 5.1 %, −86 %)** · die **58.4 °C** mean
  (min 54.6) — the coolest sustained idle recorded. Flat across the whole window
  (p05 69.6 %), no reboot (uptime 2.34 → 5.84 d), all services off.
- Every contaminated sample in a 3.5 d pull sat inside the previous session's own
  ssh hours (die up to **82.6 °C**, opp1200 up to 16 %) — the "never judge idle
  with a session open" rule, re-confirmed by accident.
- ⚠️ **New method trap: Home Assistant's history endpoint SILENTLY TRUNCATES a
  long multi-entity response.** One 3.5 d / 12-entity call returned only the
  first 24 h — well-formed JSON, no error, stopping right after the interesting
  transition. New tool `scripts/diag/ha-opp-window.py` chunks the query (6 h) and
  merges. Full record: `docs/2026-08-16-idle-opp-remeasure.md`.

### Root-caused — an idle Q ramps on BURST SHAPE, not on load (2026-08-16, 60 s ftrace + 10 × 12 min A/B arms)
- The idle machine is **3.8 % busy** (both cores), but that CPU arrives as ~one
  long burst per second, and `conservative` (20 ms window, `up_threshold` 80)
  ramps on **any run ≥16 ms**: 62 such runs and 48 up-transitions in the same
  60 s — very nearly one ramp per long run.
- **Culprits are short-lived processes and pid 1, not the daemons.**
  **systemd (pid 1) 1.94 % of a core, 190 slices, longest 59.1 ms, 27 runs
  ≥16 ms/min** · **nq-healthd 1.41 %, longest 40.1 ms, 18 runs/min**. The
  long-lived daemons never cross the threshold at all: python3 daemon 0.52 % / 0
  long runs, avahi 0.23 % / 0, **nexusqd 0.069 % / 0**.
- pid 1 is fed by **`/usr/bin/systemctl` at 0.33 execs/s**, traced to
  **`nexusq-btagent`** (12/min, `systemctl is-active nexusq-setupd` on its 10 s
  reconcile tick) — plus, embarrassingly, this study's own first-round playback
  guard.
- ⚠️ **Disproved hypothesis, recorded on purpose:** the cumulative `trans_table`
  showed arrivals at 700 MHz at 1.008/s, matching nexusqd's 1 Hz AVR keepalive so
  exactly that it looked certain. **The trace refutes it** — nexusqd's longest
  run is 0.9 ms and it appears in no ramp window. The 1 Hz figure was an average
  over 5.85 d that still contained the pre-r13/r71 workload.
- `schedutil` could not be evaluated: it is **not compiled in**. Added to
  `steelhead_defconfig` (with `CPU_IDLE_GOV_TEO`) for the next kernel build.
  Full record: `docs/2026-08-16-idle-700mhz-deep-analysis.md`.

### Fixed — idle OPP: `ignore_nice_load` + housekeeping `Nice=19` + `down_threshold=40` (device **r73**, nexusq-btagent **r5**, nexusq-mqtt **r3**)
- **Measured A/B (12 min arms, identical conditions): 72.4 % → 86.2 % at
  350 MHz**, 920 MHz 5.70 → 0.61 %, 1200 MHz 0.89 → 0.05 %, ≈22 % less relative
  dynamic power. The two levers are independent and additive (+5.1 pp and
  +5.8 pp alone): nice+ignore hides the housekeeping BURSTS, `down_threshold=40`
  shortens the TAIL (mean stay at 700 MHz 318 → 206 ms).
- **Ramp responsiveness for real load is deliberately UNCHANGED** —
  `sampling_rate` stays 20 ms and `up_threshold` stays 80. Only *nice* time is
  hidden, and the audio path (librespot/PulseAudio, PA at RT) is never nice'd.
- New `nexusq-cpufreq-tune` oneshot (script + unit + preset entry) applies
  `ignore_nice_load=1` and `down_threshold=40`; it waits for the governor's
  tunable directory instead of racing it, is idempotent, and never fails a boot.
- `Nice=19` on `nq-healthd`, `nexusq-mqtt`, `nexusq-btagent`,
  `nexusq-wifi-watchdog`, `nexusq-nfc`. **NOT** on `nexusq-control` — it serves
  the app's volume RPC, and the trace shows it never produces a ≥16 ms run
  anyway, so nothing is lost.
- **`nexusq-btagent` r5: `systemctl is-active` → cgroup directory test.** systemd
  creates a unit's cgroup when its start job begins and removes it when the unit
  is gone, so the directory covers active/activating/deactivating — the same
  tri-state the systemctl form reached for, in one `stat()` with no fork and no
  pid-1 wakeup. The 2026-07-15 "activating counts as active" regression stays
  covered (26 pytest tests pass, the class was rewritten around the new
  contract).
- Indicative worth of dropping `systemctl` polling on its own: round 1's baseline
  measured 64.7 % with a systemctl-based guard, round 2's 72.4 % with the cgroup
  test and nothing else changed — the latter landing within 1.7 pp of the passive
  79 h number. Not a controlled A/B (an hour apart), but it agrees with the trace.

### Verified on the device — the shipped set measures **90.99 % @ 350 MHz** (2026-08-16, 12 min, post-install)
- Beats the 86.2 % the governor A/B predicted, because that arm still carried
  btagent's `systemctl` polling. With r5 installed, **`init.scope` (pid 1) fell
  from 1.49–2.15 % of a core to 0.186 %** — a ~10× drop, exactly the mechanism
  the trace pointed at — and nexusq-btagent itself 1.00 → 0.55 %.
- **350 MHz 90.99 % · 700 MHz 8.83 % · 920 MHz 0.17 % · 1200 MHz 0.02 %**
  (from 72.4 / 21.0 / 5.70 / 0.89) — **+18.6 pp**, ≈**27.5 % less relative
  dynamic power**, and only 16 % above the floor of a CPU locked at 350 MHz.
- Mean stay at 700 MHz **318 → 170 ms**; idle busy 4.72 → 4.08 % of one core,
  forks 2.59 → 2.39/s. Die 60.3 °C (12 min is too short for a thermal claim).

### Known potential test — the aggressive governor variant (NOT shipped)
- Adding `sampling_rate=100 ms` + `up_threshold=95` on top of the above measured
  **98.74 % @ 350 MHz** with 920/1200 at exactly **zero** and only 28 transitions
  in 12 minutes (0.04/s vs 1.43/s), ≈36 % less relative dynamic power — 2 % above
  the theoretical floor of a CPU locked at 350 MHz.
- **Deliberately not shipped**: it stretches a genuine ramp from ~60 ms to
  ~300 ms, which is exactly where a first-second audio glitch would live. Needs a
  real listening test (Spotify / AirPlay / USB audio start + a volume sweep, with
  `dmesg` watched for XRUNs) driven by Petr. Apply for a test with:
  `echo 100000 > /sys/devices/system/cpu/cpufreq/conservative/sampling_rate` and
  `echo 95 > .../up_threshold` (runtime-only, reverts on reboot).
- A `powersave` arm proved **nothing at idle needs more than 350 MHz** (busy
  7.06 %, everything kept working), so the remaining headroom is real.

### Measured — `schedutil` rejected: better residency, identical power (2026-08-19)
- The standing "maybe schedutil is the real fix" hypothesis, open since the
  2026-08-16 burst analysis and untestable until kernel **r48** compiled it in.
  Four 12-minute arms, idle, detached.
- **On the STANDING GOAL's own metric schedutil wins**: **94.75 % @ 350 MHz** vs
  conservative's **91.22 %**. Shipping on that number alone would have changed
  nothing for the better.
- It spends **30× longer at 1200 MHz** (0.05 → 1.63 %), which at 1380 mV costs
  6.2× a 350 MHz tick — the two cancel to **1.158 vs 1.157 relative power**.
  Mean stay at 1200 MHz **2.6 ms** vs conservative's 97 ms: schedutil jumps
  straight to the frequency utilisation implies, conservative climbs one OPP per
  sampling tick and serves the burst at 700 MHz.
- `rate_limit_us` does not rescue it: 5 ms/20 ms cut transitions from 15.4/s to
  2.5/s but make power **2–3 % worse**.
- **Keeping `conservative`** with the shipped tuning, which additionally does
  ~20× fewer transitions — not free where each OPP change is a voltage ramp with
  a 300 µs transition latency. `docs/2026-08-19-schedutil-ab.md`.

### Added — kernel OTA (Phase 2): a kernel can now be applied without a cable (2026-08-18)
- **Phase 2 was never started** — it was scoped out in 2026-08 in favour of
  `fastboot-over-ssh`, which looked like it made kernel flashing software-only.
  It did not: the Q lives on WiFi with nothing in its micro-USB, so sending it to
  the bootloader works perfectly and leaves it **unreachable**. That happened
  today and cost a mute-sensor rescue with a cable.
- **New `nexusq-kernel-ota` aport** (`nq-kernel-ota` + a promotion unit) applies a
  kernel from the running system using the one lever a 2012 Android u-boot gives
  us — a second bootable slot selected by the SAR-RAM reboot reason that kernel
  patch 0044 writes:
  - `stage`/`stage-apk` → write to the **trial slot (p8)**, read back, compare
  - `try` → arm the reason and reboot into it (interactive `YES` required)
  - `autopromote` → on the next boot: disarm first, confirm the staged release is
    what is running, then promote **only** after the device proves it is usable
    (services up **and** a real ping through the default route) — because a
    kernel that boots without cfg80211 boots fine and locks us out
  - `restore` → put slot A back from the pre-stage backup
  **Slot A is never written with an image that has not booted.**
- **Proven end to end on hardware, `6.12.12` → `6.12.12-r48`:** trial boot came
  back on SSH in **36 s** running from the trial slot, promotion passed its health
  gate, and a plain reboot then came up on the promoted kernel from slot A in
  **30 s**. `schedutil` is now in `scaling_available_governors`, which unblocks
  the governor A/B that was previously gated on a flash.
- **The packer is verified against ground truth, not trusted:** `verify-self`
  rebuilds the image for the *running* kernel and compares it with slot A —
  5 545 984 B / md5 `03c7be62…` on both sides. A one-byte packing difference
  would otherwise have surfaced only as a failed boot.
- **Two module traps, both closed before they could bite.** (a) Both kernels
  called themselves `6.12.12` and shared `/lib/modules/6.12.12`; kernel **r48**
  now injects `CONFIG_LOCALVERSION="-r$pkgrel"` so every build gets its own tree
  (and `LOCALVERSION_AUTO` is off so the string is deterministic). (b) Even then,
  letting `apk upgrade` install the kernel would delete the *old* package's files
  — including the running kernel's modules — so `stage-apk` extracts the payload
  by hand and the real `apk` upgrade happens only on promote.
- ⚠️ **What the bootloader will NOT do, measured:** with a deliberately invalid
  image in the trial slot, stock u-boot does **not** fall back to p9 — it stops,
  and a power-cycle at that moment did not recover it either. Rescue was the
  documented mute-sensor fastboot path plus `fastboot -s AW1S12241020 flash
  recovery` from a backup. So a kernel update must never be silent or automatic,
  and `try` says so before it does anything.
- Also from this work: the eMMC map is now documented (p8 recovery / p9 boot /
  p1 u-boot env / p5 device_info / p10 `/factory`), and p8+p9 are backed up to
  `reverse-eng/factory/partitions/`. Full record:
  `docs/2026-08-18-kernel-ota-phase2.md`.

### Verified — the COLD BUILD passed: 27/27 rootfs gates, built from nothing (2026-08-17)
- The verification agreed with Petr on 2026-08-13 is **done**. Full pipeline, empty
  `-cold` volumes, nothing reused from the warm one. `scripts/verify-rootfs.sh`:
  **27 passed, 0 failed** — headline `PASS /sbin/init is systemd`, no OpenRC
  packages, no `/etc/runlevels`; nexusqd + sshd present and enabled; the whole
  r73 idle set (`nexusq-cpufreq-tune`, `Nice=19` on five units, `nexusq-control`
  deliberately NOT nice'd, btagent on the cgroup test); Roon default-OFF and
  RoonBridge not baked; **boot.img 5.3 MiB, ramdisk-less**.
- Hand-checked on the mounted rootfs beyond the script: fstab carries no `/boot`
  line, zero files owned by uid 12345 (the abuild-as-root fix holds), the BCM4330
  blob matches by md5, `/boot` is populated, and **the DTB inside boot.img is
  byte-identical to the rootfs DTB** and carries the factory WiFi MAC.
- Artifacts: `output/nexusq-rootfs-cold-2026-08-17.img` (2.7 GiB) +
  `output/boot-cold-2026-08-17.img`. Logs `nq-captures/2026-08-17-coldbuild-run*.log`.
  Not flashed, not published. Kernel is **r47** (schedutil + TEO) vs r46 live, so
  the new governor option only becomes testable after a flash.
- Package versions match the device exactly (nexusqd r13, control r29, btagent r5,
  setupd r4, mqtt r3, glibc-rt r0) — the tree really does rebuild what is running.

### Fixed — build: `/dev/loop*` nodes must be pre-created (2026-08-17)
- Phase 9 died at **"(3/4) PREPARE INSTALL BLOCKDEVICE"**: `losetup` reported
  `device node /dev/loop47 (7:47) is lost`. A container's `/dev` is a **static
  tmpfs snapshot** taken at container start — no devtmpfs, no udev — so any node
  the kernel materialises later never appears inside it. `losetup -f` asks the
  kernel for the next free index, and this host's snapd keeps ~47 squashfs loops
  alive, so it handed back an index whose node only ever existed on the host.
  pmbootstrap calls losetup with `check=False`, so the only symptom is the abort.
- New **Phase 6c** materialises `/dev/loop0..255` up front (inert until
  configured). Same class as the existing `partitions_mount()` mknod patch.
  **Only the full pipeline touches losetup** — every `OTA_PACKAGES_ONLY=1` run
  skips it, which is why this was invisible until a cold build.

### Removed — the python3 override, which had quietly stopped being installed (2026-08-17)
- The override existed because Alpine's stock python3 SIGSEGVed on armv7. That
  root cause was **settled 2026-06-28 and was never the build**: `raw2simg.py`
  marked all-zero blocks as fastboot `DONT_CARE`, the device does not pre-erase
  userdata, and stale garbage showed through libpython's should-be-zero regions
  **after flashing**. The built apk was always clean; `raw2simg.py` now writes
  every block RAW.
- The cold build then exposed that the override had gone **inert**: Alpine edge
  moved to **python3 3.14.7** and apk compares `pkgver` before `pkgrel`, so our
  `3.14.5-r5` stopped winning. Phase 7d still built it, still gate-passed it
  ("CLEAN, attempt 1"), still exported it and still printed *"supersedes Alpine's
  -r2"* — while **the rootfs installed 3.14.7-r0 regardless** (proved by libpython
  md5: rootfs `d7952ba7…` vs our apk `3ad0ce88…`). A warm build could never have
  shown this: it reuses a cached APKINDEX that still listed the old version.
- **A safety net that silently stops being installed is worse than none.** Gone:
  the Phase 6 staging, Phase 7d's build+gate+retry loop, the `PYTHON3_VALIDATE_RUNS`
  harness, and `pmos/python3` itself (a `git revert` restores all of it).
- The **Phase 10 ship gate stays and is now stronger**: it prints *which* python3
  the rootfs actually contains (read from apk's own db — the question nobody was
  asking), and **a missing python3 is now a hard FAILURE**, because
  `nexusq-control`, `nexusq-mqtt`, `nexusq-btagent` and `nexusq-nfc` are all
  stdlib-python daemons. ⚠️ Paragraph-mode `awk` needs `FS="\n"`: matching
  `/^P:python3$/` with `RS=""` anchors to the record, not the line, and silently
  never matches — the first version of the check did exactly that, and both the
  bug and the fix were verified against the cold rootfs.

### Shipped — device r74 published, and the live box realigned (2026-08-17)
- `device-google-steelhead` **r74** (the `deviceinfo_boot_filesystem="ext2"` fix)
  built on the warm volume and published to gh-pages (`91cd44a`), then installed
  on the Q via `apk upgrade`. This also closes the skew where the **firmware
  subpackage was two revisions behind** (r72) the main package.
- Live device after the upgrade: device **r74** + firmware **r74**, nexusqd r13,
  control r29, btagent r5, setupd r4, mqtt r3 — all seven services active, and
  the idle tuning intact (`down_threshold=40`, `ignore_nice_load=1`, `Nice=19`
  on the housekeeping units, `nexusq-control` at 0).

### Fixed — the cold build caught an OpenRC rootfs in the making: `systemd` → `service_manager` (2026-08-17)
- The verification build did exactly what it was commissioned for. pmbootstrap
  **3.11.0 renamed the config option `systemd` (≤3.10.x) to `service_manager`**
  (`default|openrc|systemd`), and **the old key is not rejected — it is silently
  ignored**. Our config therefore selected nothing, pmbootstrap fell back to the
  UI default (`postmarketos-ui-lxqt defaults to openrc`), and the run was on
  course to produce **an OpenRC rootfs with no `nexusqd` and no `sshd`**.
- **This is the v1.5.0 failure verbatim** — an image that builds green,
  checksums green and boots into nothing reachable. It stayed hidden because the
  **warm `nexusq-workdir` volume had been carrying a correct config since before
  the rename**, so every OTA build kept working while the option had quietly
  stopped meaning anything. Exactly the class of hidden warm-volume dependency
  the cold build exists to expose.
- Fix: the config writes `service_manager = systemd`, **and a gate right after
  the config write asserts pmbootstrap actually accepts that key** — read from
  argparse's choice list via `pmbootstrap config --help`, which needs no work
  dir — plus a best-effort read-back that fails on a wrong value and tolerates an
  empty one. Both directions verified in a container. *A config option we merely
  write is a hope; one we read back is a fact.*
- Self-inflicted, caught and fixed in the same run: the comment added with that
  fix used **backticks inside a heredoc whose delimiter is unquoted** (the config
  interpolates `$PMAPORTS`/`$WORK`), so they ran as command substitution
  (`service_manager: command not found`). Harmless — the config line itself has
  no backticks and read back correctly — but the heredoc will execute anything a
  future comment quotes that way, so the warning now sits next to it.

### Fixed — build: the toolchain was unpinned, and upstream broke it (`Dockerfile`)
- `Dockerfile` installed pmbootstrap from **git master** and `docker-build.sh`
  clones pmaports **`--depth=1` from HEAD**, so what a build used depended on the
  day it ran. On 2026-08-16 an image carrying **3.10.1** met a pmaports tree that
  had bumped `required_pmbootstrap_version` to **3.11.0**, and every build — OTA
  and full — died in Phase 7b with "Please update your pmbootstrap version".
- pmbootstrap is now **pinned to 3.11.0** (`ARG PMBOOTSTRAP_REF`, verified at
  image build time). All four monkey patches still apply under it — and
  **`partition.py partitions_mount` now applies again**, which had reported
  "PATTERN NOT FOUND" on 2026-08-13 and was recorded in HANDOFF as the blocker to
  expect during the cold build. That blocker is gone.
- **pmaports is pinned too** (`PMAPORTS_REF`, default `11e89df`): fetched by SHA
  (shallow) with a blobless-clone fallback for servers that refuse by-SHA
  fetches. Plus an **early toolchain check** — it reads pmaports'
  `pmbootstrap_min_version` and fails in Phase 5 with the exact one-line fix,
  instead of letting the run die in Phase 7b after all the staging work. ⚠️ The
  first version of that check read the WRONG key
  (`required_pmbootstrap_version`), matched nothing and skipped **silently** — a
  guard worse than no guard; it now accepts either key and says so out loud when
  it finds neither. All four branches exercised, both pins verified by real
  container builds.

### Measured — post-r71/r13 idle attribution: `nq-healthd` is the new #1 consumer (2026-08-13, 240 s window, ring blanked)
- Total idle busy **8.73 % of one core** (was **18.2 %** in the overnight window
  before the day's fixes), forks **2.59/s** (was 13.96/s).
- Per-cgroup: **nq-healthd 2.43 % (new #1)** · init.scope 1.69 % ·
  nexusq-btagent 0.90 % · sshd 0.86 % · nexusq-mqtt 0.47 % · wifi-watchdog
  0.36 % · avahi 0.30 % · dbus-broker 0.18 % · **nexusqd 0.14 % (confirms r13)**.
- Wakeups/s: **brcmf kworker 33.9** · kworker/0:1-events 13.1 · rcu_sched 11.5 ·
  irq/116-i2c 10.0 · dbus-broker 7.4 · brcmf_wdog 6.5 · avahi 5.8 · systemd 4.7 ·
  btagent 3.3 · nexusqd 3.0 · healthd 2.6.
- ⚠️ **MEASUREMENT CAVEAT — record it with the numbers:** an ssh poll loop (8
  logins inside the window) inflated `sshd` **and** `init.scope` (every login makes
  pid 1 build and tear down a PAM session), so the **pid1 / sshd / user.slice
  figures are NOT trustworthy**; the other daemons' figures are. Real idle busy
  ≈ **7.7 %**. Two earlier attempts were **discarded outright**: one wrote its
  snapshots to the void (empty diffs), and its ~400 `awk` forks heated the die
  **60 → 67 °C**. Rules for next time: wait for `led_sum == 0`, run **detached**
  and fetch **once** (no polling), **one** `awk` fork per snapshot.
- **Next targets, in order:** (1) re-measure the overnight opp350 window from HA
  history, **no ssh overnight**; (2) **nq-healthd C rewrite** — the residual
  2.43 % is its ~6 forks/tick (`date`, `timeout`+`nexusled`, `od`+`awk`,
  amortized `dmesg`); the correct fix is a C daemon in the nexusqd mould
  (in-process socket connect for the liveness probe instead of forking
  `nexusled`, `/dev/kmsg` instead of `dmesg`, in-process hashing instead of
  `od|awk`) — **deliberately NOT started 2026-08-13**: three rewrites of the
  observability layer in one day is unacceptable churn; (3) **WiFi wakeups** —
  `brcmf` ~40/s dominates every other wakeup source combined; investigate
  mDNS/avahi chatter + MQTT keepalive; (4) `nexusq-mqtt`'s 30 s `pactl` volume
  poll (2 forks/30 s ≈ 0.09 %) → take volume from `nexusq-control`'s persistent
  subscribe bridge; (5) governor tunables **last**; (6) commit r71 + r13 + r72 +
  mqtt r2 + the app change + `docker-build.sh`.
- Device-side leftovers still present after the study:
  `/var/log/nq-idle-study/attrib.log` (**36 MB**) and
  `/usr/local/bin/nq-idle-attrib.sh` (service **stopped** 2026-08-13; a local copy
  of the log was pulled for the analysis).

### Fixed — build: OTA package ORDER is no longer load-bearing (2026-08-13, `docker-build.sh`)
- The `OTA_PACKAGES_ONLY=1` loop interleaved `pmbootstrap checksum <pkg>; build
  <pkg>` **per package, in the caller's order**. When a listed package `depends=`
  another listed package, pmbootstrap resolves the dep and builds it **from inside
  the first build** — while that dep's aport still carries the
  `sha512sums="SKIP"` placeholder → `>>> ERROR: <dep>: <dep> is missing in
  checksums`, and the whole run exits **3**.
- Bit `nexusq-btagent`→`nexusq-setupd` before (documented only as a "list
  dependencies first" workaround in `.claude/agents/nexusq-build.md`), and again
  on 2026-08-13 with `device-google-steelhead`→`nexusq-mqtt` (r72 `depends=` the
  mqtt aport).
- **Fix:** a checksum pass over the **entire** `$_ota_list` first, then a separate
  build pass. Order-independent — the workaround is no longer required, and the
  failure mode catalogue in `.claude/agents/nexusq-build.md` is updated to say so.

### Fixed — the LED "stalled" alarm now reports a VERDICT, not a raw counter (2026-08-13, `nexusq-mqtt` r1→r2 built + OTA-published + installed, live-verified; companion app change is **code-only**)
- Closes the last open action item of
  `docs/2026-08-11-overnight-telemetry-analysis.md` (§6 / §10 item 2, previously
  ⛔ open): **every idle Q permanently reported "LED ring frame is stalled"** in
  the app's Health panel ~10 min after the music stopped. The app thresholded
  `led_stall >= 6`, but that counter measures the ring's frame **CONTENT** staying
  identical — which the screensaver does **by design** (locks at `SS_LOCK_S`=300 s,
  blanks at `SS_BLANK_S`=600 s) while the 1 Hz AVR keepalive re-commits the very
  same bytes.
- **`nexusq-mqtt` r2** publishes a new boolean **`led_stalled`** =
  `led_stall >= LED_STALL_MIN(6)` **AND** (`nq_resp` falsy **OR** `nq_progress`
  falsy) — i.e. the judgement is made **on-device**, from the same distress
  co-signal `nq-healthd` itself uses to choose crit `led_frozen` over info
  `led_static`, so daemon and telemetry agree **by construction**. `led_stall`
  stays in the payload as a diagnostic number.
- New HA discovery entity: `binary_sensor` key `led`, name **"LED ring"**,
  `device_class: problem`, `entity_category: diagnostic`, template
  `{{ 'OFF' if (not (value_json.led_stalled | default(false))) else 'ON' }}` — an
  **absent** field reads as healthy rather than inventing an alarm out of a
  missing signal. Live: `binary_sensor.nexus_q_led_ring = off` in HA with the
  payload showing `led_stall=17, led_stalled=False`. Daemon test suite **28/28**.
- **Companion app (code only — NOT built, NOT released):**
  `companion/app/lib/screens/health_screen.dart` `healthProblems()` swaps
  `led_stall >= 6` for `s['led_stalled'] == true`, message **"LED ring is
  stalled"**. A device too old to send the field raises **nothing** (silence beats
  a known-false alarm; a genuinely dead daemon still surfaces via
  `nexusqd_alive`). `companion/app/test/health_problems_test.dart`: the old
  assertion replaced + **two new regression tests** — a payload with
  `led_stall: 9751` **and** `led_stalled: false` must be EMPTY, and `led_stalled`
  fires only on a real boolean `true` (not `1`, not `"yes"`, not `null`). 6/6 pass
  under `flutter test`. ⚠️ **No pubspec bump, no APK build, no GitHub release, no
  `app-release.json` bump — the app release needs Petr's approval** (it
  self-installs on his phone).

### Fixed — `nq_progress` measured over a WINDOW, not per sample — a false CRIT created by r13's own success (2026-08-13, `device-google-steelhead` r71→r72; built + OTA-published to gh-pages + installed on the Q, live-verified)
- **A second-order defect created by `nexusqd` r13.** `nq_progress` was "did
  nexusqd's `/proc/pid/stat` tick count change since the last 5 s sample". Valid
  while nexusqd burned 4.4 % of a core (≈22 USER_HZ ticks per sample) — but r13
  dropped it to **0.165 % ≈ 0.8 ticks per sample**, so a **zero delta became the
  ORDINARY reading for a perfectly healthy daemon**. Combined with `LED_STALL`
  reaching 6 being *guaranteed* on a locked/blanked ring (the keepalive re-commits
  identical bytes), healthd's co-signal
  `[ "$nq_resp" = 0 ] || [ "$nq_progress" = 0 ]` fired **CRIT `led_frozen` on a
  healthy idle device**.
- **Not theoretical — it fired twice on the live device** in the window between
  r13 and r72 landing. Evidence from `/var/log/nq-health/events.jsonl`:
  ```json
  {"t_mono":214110,"sev":"crit","kind":"led_frozen","msg":"LED frame unchanged for 6 samples with distressed nexusqd (resp=1 progress=0) - ring/AVR/nexusqd hang"}
  ```
  (and again at `t_mono` 214497). After r72 the same situation correctly logs
  **info `led_static` … (resp=1)**.
- **Fix:** new `NQ_LAST_TICK_MOVE` state + `PROGRESS_STALE_S` (env
  `NQ_PROGRESS_STALE_S`, default **60 s**). `nq_progress` is 0 only when nexusqd's
  CPU time has **not advanced for that long**; at r13's idle rate nexusqd accrues a
  tick roughly every 6 s, so 60 s of silence is ~10× beyond normal and genuinely
  means wedged. The window resets when the unit is not running. File:
  `pmos/device-google-steelhead/nq-healthd`.
- Doc note: this closes the "UNVERIFIED RISK / flagged, not yet seen in a capture"
  warnings the earlier 2026-08-13 sweep left in `scripts/diag/README.md`,
  `.claude/agents/nexusq-diag.md` and `.claude/skills/nexusq-diag/SKILL.md` — it
  **was** seen, and it is fixed.

### Changed — nexusqd: event-driven PA gate + adaptive idle render cadence (2026-08-13, `nexusqd` r12→r13; built + OTA-published to gh-pages + installed on the Q, live-verified)
- **Why:** the same 2026-08-13 idle attribution
  (`docs/2026-08-13-idle-opp-residency-measurement.md`) put **nexusqd at ~4.4 % of
  a core and 22 wakeups/s** on a fully idle box — the #2 consumer, and the top one
  once r71 shipped. Two causes: (a) the PA sink-input gate polled `pactl list short
  sink-inputs` every `PA_POLL_S`=1.5 s whenever the tap was off, forking ~0.67
  procs/s around the clock (and each short-lived client also woke every OTHER PA
  subscriber on the box, e.g. `nexusq-control`'s bridge, with connect events);
  (b) the render loop ran a full 20 fps tick forever, even with the ring
  locked/blanked and the frame bit-identical.
- **Event-driven gate:** new `pa_subscribe_open()` (`audio.c`/`audio.h`) spawns a
  persistent `pactl subscribe` child; its non-blocking stdout is watched in the
  main `poll()`. Lines matching `on sink-input` + `'new'`/`'remove'` set
  `pa_check` → re-count. The timed re-count becomes a slow safety net
  (`PA_SAFETY_ON_S`=30 s tapping, `PA_SAFETY_OFF_S`=60 s idle) and falls back to
  `PA_POLL_S`=1.5 s while the subscriber is down/unproven. Dead subscriber
  (EOF/HUP) → close + respawn every `PA_SUB_RESPAWN_S`=10 s. `'change'` events are
  deliberately ignored (they don't alter the count). r12's "while music flows we
  never poll" still holds for the TIMED path; an EVENT may re-count mid-playback —
  an accepted deviation, bounded by real PA activity rather than by a clock.
- **Adaptive idle cadence:** after `IDLE_AFTER_TICKS`=40 bit-identical renders
  **and** an *intent-idle* test, the render deadline stretches to
  `IDLE_FRAME_S`=1.0 s — matching the 1 Hz AVR keepalive. Caps:
  `IDLE_TAP_FRAME_S`=0.25 s while the tap is open (a possibly-PAUSED stream still
  holds a sink-input), `MUTE_BLINK_S`=0.5 s while the update-available blink is
  live. Keys, any mutating control command (`CTL_STATUS` excluded — healthd probes
  it every 5 s), and a tap off→on transition reset `static_ticks` and force an
  immediate render.
- **Fixed during adversarial review (all found + fixed BEFORE shipping):**
  - **CRITICAL — 1 s black ring on a volume press from idle.** `frame_int` was
    computed *before* `poll()` but consumed *after* event handling
    (`next_frame += frame_int`), so from idle cadence a single volume detent
    rendered the overlay's fade-in first frame at `eased=0` — with
    `RX_COLOR_R=0x00` that is **pure black** — and scheduled the next render 1.0 s
    later, by which time `RX_TIMEOUT_S` had expired. Net: the ring went black for
    ~1 s instead of showing the volume flash. Fix: the whole cadence choice moved
    to the **END** of the render tick (it picks the NEXT deadline, so it must see
    post-render state); `tick_base` preserves the non-drifting accumulate + resync.
  - **MAJOR — stretching mid-animation.** Keying the stretch on bytes alone
    engaged during the breathing screensaver: near its cosine trough the breath
    quantizes to an identical frame for >40 ticks at low global brightness (breath
    would visibly freeze, then step). Fix: an **INTENT** test — stretch only when
    there is no overlay, `child_alpha == 0`, no breathe/spin override, and the
    screensaver is locked (`elapsed_no_audio > SS_LOCK_S`) or blanked. Bytes AND
    intent must both agree.
  - **MAJOR — gate blind for the whole respawn gap.** `pa_poll` kept its 30/60 s
    safety deadline after the subscriber died, so the documented 1.5 s degraded
    polling never ran; a stream started right after a PA restart left the
    visualizer dark ~10 s. Fix: clamp `pa_poll` to `now + PA_POLL_S` in the
    EOF/HUP path.
  - **MAJOR — a doomed subscriber armed the long horizon.** `fork`+`exec` succeed
    even when PulseAudio is down (the child only EOFs afterwards). Fix:
    `PA_SUB_PROVEN_S`=2.0 — a subscriber earns the long safety horizon only after
    surviving that long.
  - **MINOR — leaked pipe fd defeated the arecord SIGPIPE backstop.** The pipe
    read ends lacked `FD_CLOEXEC`, so the long-lived subscribe child inherited
    `arecord`'s read end; `audio_close()`'s documented SIGPIPE backstop then had a
    second holder and `arecord` could survive a raced SIGTERM, capturing forever
    and pinning the sink out of suspend. Fix: `FD_CLOEXEC` in both spawn helpers.
  - **MINOR — a leaked locale would silently kill every match.** pactl's event
    wrapper `Event '%s' on %s #%u` is gettext-translated. Fix: `setenv LC_ALL=C`
    in the forked children.
  - The volume **overlay is excluded from the stretch** — it was hitting 40 static
    ticks during its 1 s hold, delaying expiry + the mute-LED hand-back.
- **Verified on device (r13 live), acceptance suite of 5 tests** driven
  programmatically off the AVR `frame` attr (the same bytes healthd fingerprints):
  volume overlay from deep idle visible in **~8 ms** (the pre-fix bug would have
  left it black); screensaver still breathes (`led_sum` 8192→1248 over 6 s — i.e.
  cadence NOT stretched while animating); a **silent** sink-input
  (`paplay /dev/zero`, nothing audible) brings the tap up in **~200 ms** via the
  subscribe path and it closes again when the stream ends; exactly **1** persistent
  child (`pactl subscribe`), 7 open fds, `NRestarts` unchanged.
- **Blanked-idle measurement** (waited 548 s for the ring to blank, then a 120 s
  window with NO ssh session): nexusqd **198 ms/120 s = 0.165 % of a core (was
  4.4 %, −96 %)**, **2.9 wakeups/s (was 22/s, −87 %)**, system-wide fork rate
  2.6/s, die 59.2 °C.
- ⚠️ **Method note — never A/B across screensaver states.** The first attempt
  measured 1.6 % / 54 wakeups per s and was **DISCARDED as invalid**: a fresh
  `systemctl restart nexusqd` restarts the screensaver, so the ring was
  legitimately breathing at 20 fps (`led_sum` ≠ 0). The r12 comparison numbers come
  from the locked+blanked state — any A/B must wait out `SS_LOCK_S`/`SS_BLANK_S`
  first.
- **Cumulative idle picture for 2026-08-13:** healthd 6.3 → 2.3 % (r71),
  `nq-idle-study` stopped (~3.8 %), nexusqd 4.4 → 0.165 % (r13) — roughly **12 pp
  of one core** of constant idle background removed since the morning's 60.5 % @
  350 MHz baseline.
- **Known issues / next:** the only remaining idle `pactl` forker is quantified —
  **`nexusq-mqtt`'s 30 s volume/mute poll** (2 forks per 30 s ≈ 0.09 % of a core,
  ≈ the 47 s of `pactl` CPU seen overnight). Proposed follow-up (NOT done): have
  `nexusq-mqtt` take volume from `nexusq-control` (which already runs a persistent
  `pactl subscribe` bridge) instead of forking `pactl`.

### Changed — nq-healthd fork diet (2026-08-13, `device-google-steelhead` r70→r71; built + OTA-published to gh-pages + installed on the Q, live-verified)
- **Why:** the first clean idle-OPP measurement (14 h overnight MQTT window,
  2026-08-13) landed at **60.5 % @ 350 MHz** and the same-day attribution from the
  device's own logs (the 2026-08-11 `nq-idle-attrib.sh` sampler log, 36 MB, + live
  60 s per-cgroup `cpu.stat` deltas) put **nq-healthd at ~6.3 % of a core** —
  ~0.6 % the shell itself, **~5.7 % its forked children** — the single biggest
  idle consumer. System-wide fork rate at idle: **13.96/s** (702 759 forks
  overnight); 63 % of all busy CPU was short-lived forked children. Record:
  `docs/2026-08-13-idle-opp-residency-measurement.md`.
- **r71:** every sysfs/procfs read is now an ash-builtin `read` (`rdv` helper,
  no `$(cat)`); `/proc/pid/stat` parsed fork-free (`read_stat`, replaces 2×
  awk); LED frame fingerprint = **one** `od|awk` pass (byte sum + rolling hash;
  no more `md5sum` — `led_fp` only ever feeds an equality test); dmesg ring
  scan amortized to every `NQ_DMESG_EVERY` ticks (default 6 = 30 s); rotation
  `stat()` every 12 ticks; pstore counted by glob (no `ls|wc`);
  loadavg/meminfo/uptime via builtins; `systemctl show` output parsed by the
  fork-free `sv()` (no sed/subshell); librespot liveness = cgroup membership
  scan (`cg_scan`) with restart detection via "cached pid no longer a member
  while the cgroup is non-empty" (no more `grep` on cmdline); inter-sample
  sleep replaced by a fork-free `read -t` on a private fifo fd 9 (probed at
  startup, falls back to `sleep`; the start event carries `tickfd=0/1`).
  **JSONL schema UNCHANGED** (keys verified identical). Fixed during review:
  `set --` in the AVR-scan/pstore-glob clobbered `sample()`'s `$1`, so `--once`
  is captured up front (`_oncearg`).
- **Verified on-device A/B** (60 s each, systemd-run transient units, throwaway
  `NQ_LOGDIR`): r70 = **4212 ms** CPU, r71 = **1682 ms** (**−60 %**), system
  forks **−517/min** (−43/tick). Production unit after the OTA: **1403 ms/60 s
  = 2.3 %** (was 6.3–7.0 %), system-wide fork rate **3.2/s** (was ~14/s incl.
  the now-stopped idle-study sampler).
- Also **stopped the leftover `nq-idle-study` transient unit** (~3.8 % of a
  core; the 2026-08-11 sampler — script + logs remain on the device). Together
  ~8 pp of one core of constant idle background removed; tonight's overnight
  window is the free A/B — expect opp350 well above 60.5 %.
- **Known issues / next (idle attribution, in impact order):** re-measure the
  overnight opp350 window tomorrow morning from HA/MQTT (no ssh overnight) ·
  ~~**nexusqd wakes 22×/s** for a 1 Hz keepalive (event-loop poll timeout
  audit)~~ ✅ **done the same day — nexusqd r13, see the entry above** (22 → 2.9
  wakeups/s) · ~~something forks `pactl` repeatedly at idle (volume polling —
  switch to a subscription)~~ **mostly done same day** — nexusqd's 1.5 s poll is
  gone (r13); the residue is `nexusq-mqtt`'s 30 s volume/mute poll (~0.09 % of a
  core), follow-up proposed · `conservative` governor tunables only after those,
  to see if the residual 5.1 % @ 1200 MHz collapses on its own.
  *(Superseded later the same day — see "Measured — post-r71/r13 idle
  attribution" at the top of [Unreleased]: healthd is **again** #1 at 2.43 %, and
  `brcmf` WiFi wakeups moved ahead of the `pactl` residue.)*

## [1.12.0] — 2026-08-12 — OTA everywhere (device · app · full-system) · MQTT health telemetry → Home Assistant + app · USB Audio as a mixing PulseAudio source · iOS app · idle-power made measurable

### Changed — USB Audio back into PulseAudio via a stable-clock snd-aloop hop (2026-08-12, `device-google-steelhead` r68→r70; committed + OTA-published gh-pages `4d1d8e1`; live-verified)
- Supersedes the r65/r68 exclusive direct-ALSA bridge (`alsaloop → hw:NexusQSpeaker`
  + `suspend-sink`), which was efficient but took the amp exclusively — no mixing
  with Spotify/AirPlay/Roon, no unified PA volume, and the LED visualizer went dark
  (a suspended sink has no `.monitor`).
- New path mirrors the proven Roon pattern with an `alsaloop` inserted up front to
  convert the async gadget clock to a stable one:
  `UAC2Gadget (async) → alsaloop --sync=simple → hw:Loopback,0,0 (snd-aloop,
  timer-clocked) → PA module-alsa-source usb_in → module-loopback → default sink`.
  PA's `module-alsa-source` now reads the STABLE aloop capture (sane latency) instead
  of the async endpoint (which misreported latency as ~uptime → the r65 runaway to
  minutes). Reuses the existing PULSE_IGNORE'd `Loopback` aloop card (spare
  substreams) — no new card, no index reshuffle, `CONFIG_SND_ALOOP=y` drift
  sidestepped. `asound.conf` tee retired to a stub; `nq-vol` reverted to the pure PA
  `@DEFAULT_SINK@` path (one unified volume, Petr's call — the r66 per-source memory
  is gone).
- **r70 fix (found in the live test):** the `module-loopback` sink-input came up
  `Mute:yes`/0% because `module-stream-restore` restored a stale muted entry —
  hidden per-stream attenuation that silenced USB audio while amp/source/routing all
  looked fine. The service now forces that sink-input unmuted + 100% (unity
  passthrough) after loading. **Live-verified: plays, lip-sync holds (~130 ms total),
  mixing works, LED visualizer pulses.**

### Fixed — System update now restarts nq-healthd + nexusq-mqtt (2026-08-12, `nexusq-control` r29; OTA-published gh-pages `56aa4d0`)
- `install_system_update` restarted only daemons whose service name equals their
  package name, so `nq-healthd` (ships inside `device-google-steelhead`) and
  `nexusq-mqtt` fell through — an app-driven update that changed either left the OLD
  daemon running until an unrelated reboot while the app said "up to date". Now a
  `_PKG_RESTART` package→service map drives the restart set. 6 new unit tests (suite
  19/19).

### Fixed — nq-healthd stopped distorting what it measures (2026-08-11, `device-google-steelhead` r68)
- From a 12 h overnight telemetry run (`docs/2026-08-11-overnight-telemetry-analysis.md`):
  (1) with librespot masked, healthd ran `systemctl -M user@` **every 5 s** → a full
  PAM login session per tick (~600/h, pid 1 back to 4 % CPU) — now resolved
  **cgroup-first** (fork-free), systemd queried only on a real (re)start or once per
  `NQ_UNIT_REFRESH_S` (60× fewer). (2) New `opp_ms` / `opp_trans` (kernel
  `time_in_state` deltas) — OPP residency is now MEASURED, not read from the
  observer-biased `freq` spot sample. Standing idle goal recorded in PLAN.md
  (56.7 % @ 350 MHz to beat).

### Changed — MQTT credentials: the companion app is the device's ONLY provisioner (2026-08-10 follow-up; `nexusq-control` r28 + app 1.13.0+33 — source uncommitted; the r28 apk is already OTA-published as gh-pages `e428bef`, the app OTA release of 1.13.0 is imminent)
- **Petr rejected the dedicated `nexusq` broker user** ("that's not another user
  at all, delete it — it just connects with our petronijus"): the user was
  removed from the Mosquitto `password_file` (broker back to its original three
  users petronijus/ustredna/sumperak) and the 1Password item "MQTT nexusq (Nexus
  Q telemetry)" was **deleted**. The Q connects as **`petronijus`** (household
  login; password now in the 1P item **"MQTT broker"**); broker host referred to
  as **`mqtt.home.arpa`** (→ 192.168.20.102).
- **`nexusq-control` r28 — PROTOCOL §13** ("appka to musí nexusu
  provisionovat"): **`setMqttConfig`** (validate → **atomic 0600** write of
  `/etc/nexusq/mqtt.json`, 0600 tempfile + rename → restart `nexusq-mqtt`;
  password **verbatim + never logged/returned**) and **`getMqttStatus`**
  (password-less state + unit active state); event **`mqttStatusChanged`**.
  Security note in §13: creds transit the unauthenticated LAN control link —
  accepted trade-off, Petr's call. New host tests
  `tests/test_mqtt_config.py` (7; control suite now **13 green**). The r28 apk
  is published to the OTA repo (gh-pages `e428bef`).
- **App 1.13.0+33:** Save in the "Connect to MQTT" dialog **ALSO provisions the
  device** via `setMqttConfig` (`HealthScreen` takes the `NexusQClient`;
  graceful message on a pre-r28 device build) — nothing hand-edited on the Q.
- **Live end-to-end PROVEN:** Petr filled the dialog → app provisioned the Q
  (`getMqttStatus`: host `mqtt.home.arpa`, user `petronijus`, `active`) → phone
  panel Live with data → HA still fed.
- **`nexusq-mqtt` r0→r1 (uncommitted, not yet OTA-published):** per-OPP
  residency now over a **rolling 1 h window** (`NQMQTT_OPP_WINDOW_S`, default
  3600) instead of the wildly-swinging 30 s publish window (Petr: "lítá to
  úplně jak se to zlíbí"); counter reset discards the history; daemon tests
  25→**28** green.
- Record: `docs/2026-08-10-mqtt-health-telemetry.md` §7.

### Fixed — app 1.12.1+32: Health-panel grey-screen crash (2026-08-10)
- 1.12.0's Health panel crashed to a grey screen on the first build after
  saving broker settings: a **null cast on absent `led_stall`/`pstore`** in an
  *empty* state map — `(x ?? 0) is num && (x as num) …` tested the FALLBACK but
  cast the ORIGINAL (the daemon deliberately omits unavailable fields, and the
  map is empty until the first retained message). `healthProblems()` extracted
  top-level + regression test `test/health_problems_test.dart`. Diagnosed over
  adb (uiautomator repro + logcat stack trace); a `notAuthorized` seen en route
  was mistyped creds on the phone, not a bug. Installed on Petr's phone via adb
  (1.12.1 and 1.13.0 both; OTA release ships as 1.13.0).

### Added — v1.12.0 full image built, all gates PASS (2026-08-10; NOT flashed)
- Full pipeline run: bakes `nexusq-mqtt` 0.1.0-r0 + device **r67** + control
  **r27** (r28 arrives via System OTA once published). Artifacts
  `output/nexusq-boot-v1.12.0.img` + `output/nexusq-rootfs-v1.12.0-sparse.img`
  (+ `.sha256`). The live device already runs the same bits via OTA; the image
  is the flash-anytime safety copy.

### Added — MQTT health telemetry → Home Assistant + app Health panel (2026-08-10; SHIPPED — commit `b49b536` pushed on `main`, device-OTA published as gh-pages `cff585f`, app released as `app-v1.12.0` + manifest live)
- **NEW aport `pmos/nexusq-mqtt` (0.1.0-r0, noarch)** + `userspace/nexusq-mqtt/`
  (daemon, `.service`, `96-nexusq-mqtt.preset`, README, **25 host tests** passing
  incl. a fake TCP MQTT broker): a **pure-Python3 stdlib MQTT 3.1.1 publisher**
  (CONNECT+auth+LWT, PUBLISH QoS0+retain, PINGREQ with PINGRESP-timeout dead-link
  detection, reconnect+backoff). Every 30 s: retained JSON at
  `nexusq/health/state`, availability `nexusq/status` (retained LWT
  online/offline; SIGTERM publishes offline explicitly), retained **HA MQTT
  discovery** (`homeassistant/(binary_)sensor/nexusq_<factoryMAC>/*/config` — **12
  sensors + 6 binary_sensors**, shared state topic + value_templates; unavailable
  fields are **omitted**, never null).
- **Data:** nq-healthd's `health.jsonl` tail (fresh ≤60 s:
  temp/freq/gov/load/mem/nq_alive/led_stall/dmesg_err/pstore) + the daemon's own
  sampling: **per-OPP residency deltas** from `time_in_state` ("podíl
  frekvencí"), WiFi RSSI/SSID via `iw`, volume/mute from the mixer that owns the
  output (`amixer` while `alsaloop` runs — same pgrep detection as `nq-vol` —
  else uid-10000 PA), 4 streaming-service states via instant `cgroup.procs`
  reads, uptime.
- **Config `/etc/nexusq/mqtt.json` (0600) is a per-home SECRET — never baked into
  the public image**; unit has `ConditionPathExists` + deliberately **NO
  `After=`/`Wants=`** (boot-ordering-cycle rule). Enablement is self-contained:
  baked `multi-user.target.wants` symlink (live OTA installs) + own priority-96
  preset (image `preset-all`).
- **Integration:** `device-google-steelhead` r66→**r67** (`depends +=
  nexusq-mqtt`); `docker-build.sh` Phase 2/5/dos2unix + NEW **Phase 7c5**
  build/export; `publish-ota-repo.sh` `OTA_PACKAGES += nexusq-mqtt`. Built via
  `OTA_PACKAGES_ONLY=1` → `nexusq-mqtt-0.1.0-r0.apk` +
  `device-google-steelhead-1.0-r67.apk` (signed, verified; **published to the
  OTA repo as gh-pages `cff585f`**).
- **Broker:** NEW MQTT user `nexusq` on the TrueNAS Mosquitto
  (eclipse-mosquitto 2.0.22, `192.168.20.102:1883`). **SUPERSEDED later the
  same day** — Petr rejected the extra user; it and its 1P item were deleted,
  the Q connects as the household `petronijus` (see the Changed entry above).
  ⚠️ broker has **no `acl_file`** — every
  authenticated user can read/write everything (incl. zigbee2mqtt).
- **DEPLOYED LIVE 2026-08-10** (device at the new lease `192.168.20.246`): apk
  add clean (**mkinitfs trigger OK — the 2026-08-08 Option-A `/boot` fix
  holds**), **18 entities live in Home Assistant** with real values (die
  79.9 °C, 1200 MHz conservative, OPP shares, −28 dBm RSSI, volume 45 %); binary
  sensors cross-checked against device truth.
- **Companion app 1.11.2+30 → 1.12.0+31** (apk published as gh release
  **`app-v1.12.0`**; the `app-release.json` bump shipped with `b49b536` — the
  OTA offer is live): Settings → **"Device health"** → `HealthScreen` (status/problem
  flags/vitals/OPP bars/service chips/WiFi card; retained topics populate it
  instantly); manual **"Connect to MQTT"** dialog (hand-entered creds; at this
  point no provisioning verb — **superseded same day by 1.13.0/§13**, see the
  Changed entry above), creds in
  `flutter_secure_storage`; subscriber `lib/mqtt/` on `mqtt_client ^10.6`.
- **Known issues found:** `test/connect_gate_setup_entry_test.dart` is **not
  hermetic** (real mDNS discovery — fails whenever a live Q is on the LAN; needs
  a discovery seam/mock) · an **internet-only outage still drops the Q off the
  LAN** (wifi-watchdog pings the GATEWAY; ~2 h today, self-recovered on lease
  `.246` — working as designed, noted for refinement) · `opnsense-api` helper
  currently broken from this PC (no `opnsense.home.arpa` DNS + 404 on gw :8443 —
  re-verify after the outage).
- Full record: `docs/2026-08-10-mqtt-health-telemetry.md`.

### Added — OTA published 2026-08-08 (`nexusqd` 0.1.0-r12 · `device-google-steelhead` 1.0-r63)
- **`scripts/publish-ota-repo.sh` pushed to `gh-pages`** — live at
  `https://petronijus.github.io/nexusQ-reloaded/nexusq`:
  - **`nexusqd` r12** — the **front-panel volume ring is applied headless** via
    `nq-vol` (turning the physical dome ring changes volume with no desktop/app in
    the loop). **Confirmed on-device by Petr — the ring changes volume.**
  - **`device-google-steelhead` r63** (+ `firmware-google-steelhead` r63) —
    **desktop OFF by default**: `default.target` → `multi-user.target` symlink (was
    `graphical.target`, which auto-started the HDMI desktop) + the **duplicated
    labwc audio keybinds dropped**.
  - Unchanged in the OTA index: `nexusq-control` **r25**, `nexusq-btagent` **r4**,
    `nexusq-setupd` **r4**.
- **Build fix (main `024d928`, committed + pushed):** the committed
  r63 APKBUILD (`9a9bb16`) ran `ln -sf … default.target` before anything created
  `$pkgdir/etc/systemd/system` (later blocks `install -dm755` it, but run after) →
  a clean pipeline build **failed** (`ln: … default.target: No such file or
  directory`); the committed r63 never built through docker-build. Fix =
  `install -dm755` the dir first.
- **`docker-build.sh` gains `OTA_PACKAGES_ONLY=1`** — a targeted **two-package**
  build (`nexusqd` + `device-google-steelhead`, both `--force`) that reuses all the
  load-bearing setup verbatim then exports **just the two signed apks** for
  `publish-ota-repo.sh`, skipping the full rootfs/boot.img. Pure addition; the
  full-pipeline path is unchanged.
- See `docs/2026-08-08-usb-audio-playback-delay-and-ota-publish.md`.

### Fixed — USB Audio input multi-minute delay + idle CPU/heat, via a direct alsaloop bridge (2026-08-09, `device-google-steelhead` r65; committed `2dccd3a` + pushed, OTA published — gh-pages `d983b3f` 2026-08-09)
- **What was broken (both were the SAME PulseAudio bridge):** audio fed into the Q
  over USB (Xiaomi Mi TV Box → UAC2 gadget capture, `nexusq-uac2-in`) (a) came out
  **~3 min late** after a **long session**, and (b) burned **~15–20 % CPU + ~5 °C** even
  in silence. `module-alsa-source` on the **async** `hw:UAC2Gadget` reported a bogus,
  uptime-growing latency (5134 s seen) that poisoned `module-loopback`'s latency-driven
  resampler (pegged the ±1 % rail, `memblockq` backlog grew to minutes); and the
  loopback sink-input never corked, so `module-suspend-on-idle` could never sleep the
  TAS5713 sink → DAC/clock/DMA/resampler ran 24/7. Full pre-fix analysis:
  `docs/2026-08-08-usb-audio-playback-delay-and-ota-publish.md`.
- **Fix:** rewrite the bridge to a **direct ALSA loopback — no PulseAudio in the audio
  path**: `alsaloop -C hw:UAC2Gadget -P hw:NexusQSpeaker -r 48000 -c 2 -f S16_LE
  --sync=simple`, rate-matched from the **real hardware pointers** (no PA smoother to
  diverge) with structurally **bounded** ALSA buffers, so the delay **cannot** run away.
  Runs only while the toggle is on. **Measured live end-to-end:** audio plays, lip-sync
  correct (Petr-confirmed "sedí to na mluvení"), alsaloop **~0.5 % → ~0 %** of one core
  (was 15–20 %), die temp **93 °C → 76–79 °C**.
- **`--sync=simple`, not `--sync=samplerate`:** the device's `alsa-utils` is built
  **without libsamplerate**, so `--sync=samplerate` fails with `Loopback start failure`;
  `--sync=simple` uses the gadget's **Capture Pitch** control (closed-loop pitch
  rate-match) and works.
- **Volume re-plumbed (PA is bypassed):** `nexusq-uac2-in` suspends PA's tas5713 sink
  (USB audio is now **EXCLUSIVE** — Spotify/AirPlay/Roon are paused while it's on),
  enables the TAS5713 **Speaker** switch, sets a low safe starting **Master**
  (`NQ_UAC2_VOL`, default `10%`, so turning it on can't blast the 25 W amp); on stop it
  kills alsaloop and hands the amp back to PA. `nq-vol` now detects `alsaloop` running
  and drives the TAS5713 **hardware** mixer (`amixer` Master / Speaker) instead of the
  suspended PA sink, so the front-panel ring controls USB-audio volume.
- **APKBUILD:** `pkgrel` 63 → **65**, `depends += alsa-utils` (for `alsaloop`).
- **Trade-off (accepted):** USB audio is **exclusive** — no simultaneous mixing with
  Spotify/Roon/AirPlay. **Known minor:** the nexusqd LED music visualizer taps the PA
  source, so the ring won't pulse to USB-audio playback.
- **Source device:** the Xiaomi TV Box (adb `192.168.20.169:5555`) confirmed routing
  media to `AUDIO_DEVICE_OUT_USB_DEVICE` (the Q); host-mode is via
  `gpioset -t 0 -c 0 16=0` and reverts on box reboot unless the `magisk-usb-host-audio`
  module is deployed (in `~/Documents/Dev/xiaomi-tvbox-twilight`).

### Fixed — System OTA "system update failed" (mkinitfs/boot-deploy trigger) (2026-08-08, Option A)
- **Symptom:** the app's **System** update (`installSystemUpdate`, PROTOCOL §12b) shows
  **"system update failed"**, and `apk fix -s` reports `(1/1) Reinstalling
  postmarketos-mkinitfs … 1 error` — a **persistent pending trigger** that re-fails on
  **every** future apk transaction.
- **Root cause** (`/var/log/apk.log`): `ERROR: No kernel found in /boot (checked:
  vmlinuz*, linux.efi)` → `boot-deploy failed → exit status 1` → the
  `postmarketos-mkinitfs-2.11.1-r0.trigger` exits 1. The trigger runs
  `/usr/bin/boot-deploy`, which requires a kernel in `/boot`; on this device **`/boot`
  is an EMPTY plain dir** (not a mount — `findmnt /boot` empty). `linux-google-steelhead`
  **does** ship `boot/vmlinuz`, but it is stripped from the rootfs because the Q boots
  **ramdisk-less directly from the flashed boot partition** (see `scripts/make-bootimg.py`).
- **Nuance — packages DO install despite the "failure":** the trigger runs at the end
  and does not roll back; `device-google-steelhead` r63 + firmware r63 + `nexusqd` r12
  all committed (verified in `apk info`), and the device boots fine (kernel is in the
  flashed boot partition). The failure is **cosmetic-but-alarming** + **blocks a clean
  apk state**. The live reference device currently carries the pending failing trigger.
- **Fix — Option A (put a kernel in `/boot`).** First confirmed boot-deploy never
  writes a partition: `flash_updated_boot_parts` is gated on
  `deviceinfo_flash_kernel_on_update` (unset here), so it only generates a boot.img and
  copies files into `output_dir=/boot` — the generated `/boot/boot.img` is inert (the Q
  boots ramdisk-less from the flashed p9). **Live device:** restored `/boot`
  (vmlinuz + dtbs + System.map + config from the installed `linux-google-steelhead-6.12.12-r46`
  apk), ran `mkinitfs` → boot-deploy exit 0 (no flash), `apk fix` → `OK: … 982 packages`,
  `apk fix -s` clean. **Build:** `docker-build.sh` Phase-10 post-processing now copies
  `$ROOTFS/boot/{vmlinuz,dtbs,System.map,config}` into the exported rootfs `/boot`
  (pending next-build verification). Kernel OTA itself is still Phase 2. See
  `docs/2026-08-08-system-ota-mkinitfs-trigger-failure.md`.

### Added — the companion app runs on iOS (2026-08-03; app-side only, no device/image change)
- **The Flutter companion now runs on iOS** — verified on the **iPhone 17 simulator,
  iOS 26.5** (Flutter 3.44 / Xcode 26.6); `flutter build ios --release --no-codesign`
  passes (18.8 MB Runner.app). Deploying to the physical iPhone is still pending
  (needs the phone on cable with Developer Mode).
- **mDNS discovery via native Bonjour** — `package:multicast_dns` cannot run on
  iOS 14+ (raw port-5353 sockets need the restricted
  `com.apple.developer.networking.multicast` entitlement, Apple-granted on request
  only). New `ios/Runner/BonjourDiscovery.swift` (NWBrowser browse + resolve of
  `_nexusq._tcp`, exposed as the `nexusq/bonjour` MethodChannel:
  `discover {timeoutMs} -> {name, host, port} | nil`; resolution = a throwaway
  NWConnection whose remote IPv4+port is read once `.ready`, doubling as a
  reachability check). `discovery.dart` branches: iOS → channel, everywhere else →
  multicast_dns unchanged.
- **Platform gating:** `BtSetupClient.supported` (Android-only — first-time setup
  rides BT Classic RFCOMM, which iOS has no public API for; SPP is MFi-gated) —
  ConnectGate shows an explanatory note on iOS instead of "Set up new device"
  (**setup stays on Android; once the Q is on WiFi, iOS works fully**);
  `AppUpdate.selfUpdateSupported` (Android-only apk hand-off — on iOS the merged
  "App update" card degrades to the device-daemon track alone). NFC/HCE was
  already Android-gated.
- **Build plumbing:** `ios/Podfile` + `Podfile.lock` + `macos/Podfile` now exist
  and are tracked (`open_filex` has no Swift-Package-Manager support → CocoaPods).
  Known: release mode is not supported on iOS **simulators** (debug there);
  `test/connect_gate_setup_entry_test.dart` fails on some LANs with a real-mDNS
  `SocketException: No route to host` — **pre-existing, environment-dependent**
  (fails on clean HEAD too). Phase-2 idea recorded: **BLE GATT-based setup**
  (device-side BlueZ) would lift the iOS setup limitation. See
  `docs/2026-08-03-ios-companion-port.md`.

### Added — Full-system OTA (Phase 1): the "apt upgrade" of the whole appliance (`nexusq-control` r21→r25, app 1.10.0→1.11.0)
- **The Q upgrades its whole system over the air, not just its daemons.** New
  `checkSystemUpdate` / `installSystemUpdate` (**PROTOCOL §12b**), distinct from the
  daemon track (§12a). `checkSystemUpdate` reports the **running kernel version** (read-
  only, `uname -r`) + **every upgradable package MINUS the kernel** (parsed from
  `apk version -l '<'`); it does **not** blink the mute LED (that stays the daemon
  "update available" indicator). `installSystemUpdate` runs **`apk upgrade --available`
  across the system EXCEPT the kernel** — base musl/systemd/python from the Alpine·pmOS
  mirrors + our config/daemons from the OTA repo. Guarded by the same
  `_nexus_install_lock`. **Proven live:** upgraded systemd **261.1 → 261.2** + base
  packages.
- **The kernel is never OTA'd** — no repo the device reads offers a newer one, and
  applying a kernel is a **boot-partition flash = Phase 2** (not done; the kernel stays
  a fastboot flash / fastboot-over-ssh).
- **Reboots when base libc/init churned.** `rebootRecommended` fires when any changed
  package starts with `musl` / `systemd` / `kmod` / `eudev` / `busybox` / `openrc`;
  the ring holds **green** and the Q `systemctl reboot`s (the app reconnects when it's
  back).
- **LED: the INDETERMINATE spinner, not the determinate bar.** A full-system upgrade is
  slow and of unknown length (downloads + triggers like mkinitfs), so the determinate
  bar eased to its ~92 % cap and looked frozen; the system install now narrates with
  `spin 0 153 204 2` → **green** on success. (r23 fix.)
- **Reboot-detection bug fixed (r23):** apk-tools writes its `(N/M) Upgrading <name>`
  lines to **STDERR**, so the old stdout-only parser never saw an upgrade and
  `rebootRecommended` never fired on a systemd/base bump. New `_apk_changed()` reads
  **both streams** (the daemon parser uses it too).
- **App Update-UX (companion 1.10.0 → 1.11.0):** 1.10.0 added a **System** section
  (kernel version + `apk upgrade --available`, reboot-aware verify); 1.10.1 grouped the
  update options into one **Update** cluster; 1.10.2 fixed a false "Something went wrong"
  (the OTA RPCs were `silent=false` so the generic error banner fired on the **expected**
  control-bridge restart — now silent + verify-by-recheck). **1.11.0 MERGED App + Device
  into ONE "App update" item** (the phone app and the on-device daemons version together
  as the companion system): one "App update available" indicator + one Update button
  covering whichever side is newer (app / device / both) with **merged release notes**;
  install order = **device daemons first, then the phone app** (installing the app
  restarts the phone, so it goes last, onto an already-updated device). So the Settings
  **Update cluster is now two items: App update + System.** Manifest `1.11.0` /
  `versionCode 28` (own track). `publish-ota-repo.sh` now serves `nexusq-control` **r25**,
  `nexusqd` **r11**, `device-google-steelhead` **r62**. See
  `docs/2026-08-02-full-system-ota-and-glibc-rt-split.md`.

### Changed — glibc-rt split out of the device config → device-config OTA-shippable (new aport `nexusq-glibc-rt`, `device-google-steelhead` r62)
- **The ~180 MB glibc-rt Roon base moved into its own package.** It was baked into
  `device-google-steelhead`, making that apk **~191 MB** — over GitHub Pages' 100 MB
  limit, so the device config could not be OTA'd. The unpacked Debian-bookworm armhf
  sandbox base (`/opt/glibc-rt`) now lives in a **new standalone aport
  `pmos/nexusq-glibc-rt`** (`pkgver 1.0-r0`, versioned independently — a pinned static
  base). `device-google-steelhead` (**r62**) `depends=` on it; the base arrives via the
  dependency and is baked into the flashed image exactly as before.
- **device-config apk dropped ~191 MB → 58 KB** — now under 100 MB and **OTA-shippable**
  (it ships in the full-system OTA above). `nexusq-glibc-rt` (~182 MB) stays
  **FLASH-ONLY** (kept out of the OTA repo, not bumped, so `apk upgrade` never touches
  it); the kernel stays flash-only too.
- `docker-build.sh` builds the new aport as a device dependency (Phase 2 validate,
  Phase 6 copy loop, Phase 7b checksum), kept out of `--force` so 180 MB isn't
  re-unpacked each build. `publish-ota-repo.sh` now also ships
  `device-google-steelhead` + its firmware subpackage, with a **size guard refusing any
  apk ≥ 99 MB**.
- **Verified on-device (reflash to v1.11.9):** `/opt/glibc-rt` intact and owned by
  `nexusq-glibc-rt`, Roon not regressed, full diag clean.
- ⚠️ **Adopting the split needs ONE reflash.** A pre-split device can't OTA
  `device-google-steelhead` r62 — it would need the flash-only `nexusq-glibc-rt` and
  `apk` refuses the unsatisfiable dependency. The layout is established once by a
  reflash (v1.11.9, via fastboot-over-ssh this session); afterward, system OTA of the
  config is incremental. Images built this session: v1.11.5 / v1.11.6 / v1.11.7 /
  v1.11.8 / v1.11.9.

### Added — OTA device (daemon) updates: the Q updates its own software (`nexusq-control` r20, `nexusqd` r11, app 1.9.5)
- **The Nexus Q updates its own daemons over the air** — no reflash. A signed apk
  repo on GitHub Pages (`gh-pages` → `petronijus.github.io/nexusQ-reloaded/nexusq`)
  hosts the device software (`nexusq-control`, `nexusqd`, `nexusq-btagent`,
  `nexusq-setupd`); the device already trusts the `pmos@local-6a42e957` build key
  (baked in `/etc/apk/keys`), so `apk` installs our signed packages straight from
  it — no new key, no reflash. `nexusq-control` `checkNexusUpdate`
  (adds the repo, `apk update`, reports upgradable daemons) and `installNexusUpdate`
  (`apk upgrade` them, then restarts — nexusq-control restarts itself via
  `--no-block`, the app reconnects). The companion app gets a **"Nexus Q"**
  Settings section to check + install. Republish after a build with
  `scripts/publish-ota-repo.sh`. **PROTOCOL §12.**
- ✅ **PROVEN END-TO-END on hardware (2026-08-02):** the reference Q was taken
  **`nexusqd` r10 / `nexusq-control` r16 → r11 / r19** entirely via the app's update
  button — no reflash, no adb, no ssh. The gh-pages repo now serves
  **nexusqd r11 + nexusq-control r20**; the reference Q was then taken **r19 → r20
  live via the app** too, which verified the in-app install feedback (Installing…
  title + package list + activity bar). Images **v1.11.5**/**v1.11.6**/**v1.11.7**
  baked (v1.11.6 = control r19 + WiFi-watchdog fix; v1.11.7 = control r20).
- **LED narration + install lock (`nexusq-control` r20, `nexusqd` r11).** The LEDs
  narrate the flow, and an update that merely *waits* is signalled **only on the mute
  LED** — the ring stays on the user's theme. `checkNexusUpdate` blinks the **mute LED
  amber** (`mblink 255 140 0`) when an update is available, else `mblink stop`.
  `installNexusUpdate` clears the blink, shows a **determinate ring progress bar**
  (`progress`) while `apk upgrade` runs, flashes the ring **green** on success, then
  restores the theme; the changed daemons (incl. the bridge itself) restart
  **off-thread so the ack ships first**. A **`_nexus_install_lock`** rejects a
  concurrent install (`Err "busy"`) instead of racing a second `apk upgrade` — a flaky
  link had the app resend the call, and the second upgrade got killed = `Terminated`.
  Two new nexusqd LED primitives back this (r11): **`progress <pct> [R G B]`** (a
  determinate 32-LED ring bar, default `#0099CC`, cleared by any other manual mode)
  and **`mblink R G B | mblink stop`** (an autonomous blink of the dedicated mute LED,
  daemon-owned 0.5 s cadence; a *persistent* "update available" indicator that
  survives ring activity and is suppressed only while the mute LED does its real job —
  actual mute or a volume overlay — resuming the moment that ends). Parser + range
  tests added (`test_control.c`).
- **Companion app 1.9.1 → 1.9.5** (own track; manifest `version 1.9.5` /
  `versionCode 24`): download progress bar fixed in stages (handle a missing
  `Content-Length` on GitHub's redirected asset → indeterminate + MB; **throttle** to
  ~100 updates, was ~10 000 `setState`/download pegging the UI thread; and **explicit
  colours** — dim track vs bright accent — since the Material-3 default track blended
  with the blue fill so a partial bar read as one static strip). Update check now
  **bypasses GitHub's CDN cache** (`no-cache` + `?t=`, was stale up to Fastly's 5 min);
  a failed check **shows an error** instead of reading as "up to date"; Settings
  **auto-checks the device track on open** (was only the app track). Device OTA **no
  longer shows a false "failed"** — the install restarts the daemons (incl. the
  bridge), so the call's disconnect is expected; success is confirmed by reconnecting
  and re-checking the version — and the install now shows in-app feedback (Installing…
  title, the upgrading package list, an activity bar, a reconnect note).
- **Scope:** only the small daemons. `device-google-steelhead` is ~191 MB (it
  bundles the unpacked glibc-rt Roon base) — over GitHub's 100 MB file limit — so
  device-config OTA waits on splitting glibc-rt into its own package; the **kernel**
  stays a fastboot flash (fastboot-over-ssh). This is the "Nexus apps" track; full
  "System" (kernel + base OS) OTA is the next phase. See
  `docs/2026-08-02-device-ota-and-wifi-nogw-heal.md`.

### Fixed — WiFi watchdog now heals the associated-but-dead `nogw` wedge (`device` r61)
- **Live-caught + healed 2026-08-02.** A new wedge shape: `wlan0` **associated** at
  strong signal but NetworkManager stuck in *"getting IP configuration"* — DHCP got no
  lease, so the interface has an IP but **no default route** and the LAN is unreachable
  (the app just says "reconnecting"). `nexusq-wifi-watchdog` detects wedges by pinging
  the **default gateway**, but with no route there **is** no gateway — so it hit the
  `nogw` branch, which held **`fails=0`** and therefore **never healed this exact case,
  the one it was built for.** Now an associated `nogw` **counts like a bad check**
  (heal condition fires on `st = bad` *or* `st = nogw` once `fails ≥ FAILS_TO_HEAL`),
  triggering the same `nmcli disconnect/connect wlan0` heal that re-runs DHCP and
  restores the route; the health line carries `"fails"` for `nogw` too. Complements the
  `brcmfmac roamoff=1` escan/roam fix — a different failure mode the watchdog now also
  covers. See `docs/2026-08-02-device-ota-and-wifi-nogw-heal.md`.

### Added — OTA app updates (companion app 1.8.0+17)
- **The companion app updates itself over the air** — no more `adb install`. On
  the Settings screen it checks GitHub for a newer build (a small manifest
  `companion/app-release.json` fetched from raw.githubusercontent, compared by
  Android versionCode), shows "Update available — vX.Y.Z", and on tap downloads
  the apk and hands it to the OS package installer (needs the new
  `REQUEST_INSTALL_PACKAGES` permission; the user still confirms). Kept
  dependency-light: the fetch + download use dart:io's HttpClient; only the final
  install uses a plugin (`open_filex` + `path_provider`). The apk is published as
  a GitHub release asset `app-vX.Y.Z`. This is the **app** update track — the
  Nexus Q **system** update (apk-repo OTA) is a separate, follow-up track.

### Added — USB Audio input: the Q as a USB DAC (`linux` r46 · `device` r60 · `nexusq-control` r16 · app 1.7.0+16)
- **The Nexus Q can now take audio IN over USB** — no soldering, no Bluetooth.
  Plug a computer or phone into the micro-USB and the Q enumerates as a **USB
  speaker** ("Nexus Q"); whatever the host plays comes out the TAS5713 amp. The Q
  has **no optical/HDMI/line input** (all its ports are OUTPUTS — verified in the
  DTS and confirmed by TI docs); USB was the only no-solder / no-BT digital input.
- **How:** kernel gains `CONFIG_USB_CONFIGFS_F_UAC2` (module `usb_f_uac2`); the USB
  composite gadget (`nexusq-usb-gadget.sh`) adds a `uac2.0` function with
  `c_chmask` set (host→device capture = a speaker, not a mic). The host's audio
  arrives on the device as the `UAC2Gadget` capture card, and `nexusq-uac2-in`
  loopbacks it into the default PulseAudio sink — it **mixes with Spotify /
  AirPlay / Roon** like any other input.
- **App toggle:** it is a **4th per-service switch** ("USB Audio") next to
  Spotify / AirPlay / Roon (`nexusq-control` SERVICES `usbaudio` →
  `nexusq-uac2-in.service`, a default-OFF user unit). OFF frees the always-on
  alsa-source + loopback CPU — same resource policy as Roon.
- **`setService` OFF now `disable`s default-OFF units** (roon, usbaudio) instead
  of masking them, and only `mask`s the vendor-default-ON ones (spotify/airplay).
  `mask --now` replaces the unit with `/dev/null` *before* stopping it, which
  drops the unit's `KillMode`/`ExecStop`, so a service that owns external state —
  `nexusq-uac2-in` loads PulseAudio modules that outlive its process — would leak
  its loopback on OFF. The unit is a long-running process (`KillMode=mixed`) that
  unloads its modules in a SIGTERM trap; `disable` keeps the unit intact so that
  trap actually runs.

### Added — WiFi watchdog (`device` r57)
- **`nexusq-wifi-watchdog`** — an on-device systemd service that keeps the
  marginal BCM4330 5 GHz link alive and records its health. Every 30 s it pings
  the wlan0 gateway; after 3 consecutive failures (the "associated but TX-dead"
  wedge NetworkManager can't see) it bounces the connection
  (`nmcli disconnect/connect wlan0`, rate-limited) to auto-heal — no PC needed.
  It logs per-check health (loss %, signal) plus heal events to
  `/var/log/nq-health/wifi-watchdog.jsonl` (steady "ok" thinned to one line per
  5 min, every degradation logged in full; capped at 20 000 lines ≈ weeks), so we
  can see whether the `roamoff=1` fix is holding and characterise any remaining
  intermittent 5 GHz TX degradation (the open Asus+Mercusys same-channel-mesh
  known-issue). Enabled by default via `nexusq.preset`.

### Fixed — WiFi 5 GHz TX degradation RESOLVED (`brcmfmac roamoff=1` holds; watchdog-proven)
- The intermittent **5 GHz TX degradation** flagged open at v1.11.0 (associated at
  −48 dBm with good RX but 70-100 % packet loss on transmit, worsening over a
  session) is **resolved by `roamoff=1`**. The `nexusq-wifi-watchdog` telemetry
  logged a **29 h continuous clean run (2026-08-01)** — no TX-dead wedge, no heal
  bounces triggered — confirming the disabled-firmware-roaming fix holds over the
  long uptimes that used to surface the fault. The earlier "environmental / AP-side
  on ch36" hypothesis is retired: it was the same in-firmware background-roam-scan
  failure as the escan wedge, and pinning the Q to its single AP cures both.
  WiFi is now a reliable management/streaming path again (eth-direct `10.42.0.2`
  remains the fastest for bulk).

## [1.11.0] — 2026-07-31 — step 3: streaming services (AirPlay · rootfs resize · Roon · per-service app toggles) · fastboot over ssh

### Fixed — app "connection lost" flapping: bridge head-of-line blocking + WiFi escan wedge (`nexusq-control` r14, app 1.6.1+15, device r56)
- **Bridge no longer head-of-line-blocks (`nexusq-control` r14).** Each request on
  a connection was handled synchronously in the read loop, so one slow call froze
  every request behind it. On this armv7 `systemctl --user unmask` alone is **~9 s**
  (user-manager reload), making `setService` ON run 10-18 s — during which the
  app's 3 s `getState` liveness probe timed out → supervisor tore the link down →
  "connection lost", and the toggle itself blew the app's 5 s call timeout →
  "something went wrong". Now each request runs on its **own thread** with a
  per-connection send lock (replies are id-correlated and may return out of order);
  proven on-device: 6 `getState` answered in 0.5-3 s *while* a `setService` was
  still running. getState over the bridge measures ~1 ms.
- **App slow-method timeout 5 s → 60 s** (app 1.6.1+15) for the calls that
  legitimately shell out on the device (`setService`, `serviceLog`, `setDesktop`,
  BT pair/connect, WiFi scan/join). Polls and the liveness probe keep the tight
  5 s so a genuinely dead link is still caught fast.
- **WiFi escan-timeout wedge (`brcmfmac roamoff=1`, device r56).** After hours of
  uptime wlan0 would stay associated at good signal but pass zero traffic (100%
  loss to the gateway) with `brcmf_escan_timeout` flooding every ~58 s — the
  BCM4330 failing in-firmware background *roam* scans. Disabled firmware roaming
  (`brcmfmac-roamoff.conf`); verified **0 escan timeouts in 120 s** after. The Q is
  bolted to one AP and never roams. Live recovery when wedged:
  `nmcli device disconnect/connect wlan0`.

> **Known issue (WiFi) — ✅ RESOLVED 2026-08-01 (see [Unreleased] above):** at
> v1.11.0 the device's **5 GHz TX** was seen to degrade intermittently (2026-07-31)
> — associated at −48 dBm with perfect RX but 70-100% packet loss on transmit,
> worsening over the session and not cleared by a reboot; the phone on the same AP
> was unaffected. Ruled out at the time: the bridge, the escan flood, regulatory
> domain, power-save, BT coexistence. **`roamoff=1` fixed it** — the WiFi watchdog
> then logged a 29 h clean run (2026-08-01) with no wedge; eth-direct
> (`10.42.0.2`) stays the fastest management path for bulk.

### Added — enter fastboot over ssh, no power-cycle (kernel patch 0044, `linux` r44 → r45)
- **`systemctl reboot --reboot-argument=bootloader` now lands the device in
  fastboot** (verified 2026-07-30: ~15 s to fastboot; `fastboot reboot` returns to
  Linux with **no loop** — u-boot clears the flag). Removes the only reason to
  mains-power-cycle the box, which stresses its integrated ~35 W SMPS + single
  slow-blow fuse. Root cause: mainline `omap44xx_restart()` carried the TODO
  `/* XXX Should save 'cmd' into scratchpad */` and **dropped the reboot command**,
  so `reboot bootloader` never reached the stock u-boot's fastboot path.
  Reverse-engineered from `reverse-eng/vmlinux.bin`
  (`steelhead_reboot_notifier_handler`, via `reverse-eng/tools/nqdis.py`): the
  stock u-boot reads a NUL-terminated reason string from **SAR RAM at
  `0x4A326A0C`** (`0x4A326000 + 0xA0C`) — `"normal"` (default), `"bootloader"`,
  `"recovery"`, `"recovery:wipe_data"` — and SAR RAM survives the PRM global warm
  SW reset. Patch **0044** reimplements the stock write in `omap44xx_restart()`,
  guarded to `of_machine_is_compatible("google,steelhead")`, using mainline's
  `omap4_get_sar_ram_base()`; offset/clear-size/strings match stock byte-for-byte.
  ⚠️ **must be `systemctl`** — busybox/util-linux `reboot` does NOT forward the
  argument. See `docs/2026-07-30-fastboot-over-ssh-and-mains-fuse-repair.md`.

> **2026-07-30 — v1.11.0 FLASHED + LIVE (first v1.11.0 on the device), after a
> hardware death + fuse repair.** The reference unit died completely (LED dark, no
> enumerate, dead-cold) — root cause a **blown mains fuse**, nothing downstream
> shorted (multimeter: fuse OL; primary 400 V cap rail + amp 470 µF caps all OL /
> no-short). The Q has an **integrated ~35 W mains SMPS (85–265 VAC)** on power
> board PCB `2400-00053-4`; **micro-USB is service/debug ONLY and cannot power it**;
> amp board = TAS5713 → banana jacks. Correct replacement fuse: **Schurter
> `0034.6614` — T800 mA/250 VAC, TIME-LAG (slow-blow), TR5 radial, 5.08 mm pitch**
> (GME 1511926) — a **fast** fuse nuisance-blows on the SMPS inrush. Repair
> succeeded; a full post-repair diag found **ZERO collateral damage**.
> Then **v1.11.0 was flashed** — rootfs **`v1.11.0-rc3`** + boot **`v1.11.0-rc4`**
> (kernel `#46`, pkgrel 45, 44 patches through 0044). rc1–rc3 were never flashed
> because the device died first. It carries the step-3 streaming services + the
> Settings restructure + brand icons + **patch 0044**; companion app at **1.5.2**
> (own track). Artifacts: `output/nexusq-boot-v1.11.0-rc4.img` (sha256
> `8d40e429502a6fda28b6a07454a6542edecb8e6b4426f8a0768997336ade32ed`) + its pair
> `output/nexusq-rootfs-v1.11.0-rc3-sparse.img`.

### Fixed — service-state read was stalling the whole connection (`nexusq-control` r13)
- `listServices` read each unit's state with `systemctl --machine=user@.host
  --user is-active` — **~2 s per call** (the `--machine` transport is the only one
  allowed; the local user bus refuses a root connection). The Settings screen
  polls `listServices` every 3 s, so that latency made the app↔bridge connection
  look unhealthy and the app dropped it → **"No Nexus Q found"** (2026-07-17).
  Now `on` is read directly from the unit's **cgroup** (`…/user@10000.service/
  app.slice/<unit>/cgroup.procs` non-empty) — an **instant** filesystem read
  (measured: 2–3 s → 0.00 s). Same active/inactive answer, no systemctl in the
  poll path. Enable/mask still use systemctl (one-off, latency is fine).

### Changed — app 1.6.0+14
- Roon icon rendered **white** (its brand blue is too dark on the dark theme).
- **Debug mode defaults ON** during bring-up (the connection log's value is being
  there before a symptom shows).

### Added — Settings screen + per-service logs (`nexusq-control` r12, app 1.5.0+11)
- **New Settings screen** (app bar → gear): the streaming-service toggles, the
  HDMI desktop toggle, and Debug mode moved here out of Devices. **Devices is now
  Bluetooth-only** (pair a phone / mouse / keyboard) — a task screen, not settings.
- **Per-service logs**: each service in Settings has a *Log* button →
  `serviceLog {id, lines?}` returns that unit's recent journal (read from the
  system journal by `_SYSTEMD_USER_UNIT`, newest last, ANSI-stripped). A
  monospace viewer with copy + refresh. Answers "what is this service doing / why
  is it down" right next to its switch. **Verified live 2026-07-17.**
- Measured the toggles' actual relief on-device: **Roon off frees ~80 MB RAM +
  ~1.8 % idle CPU** (3 Mono processes → 0); AirPlay ~2.5 MB, Spotify ~1.2 MB.
  Confirms the resource policy — an off service truly costs nothing.

### Added — companion-app per-service toggles (`nexusq-control` r11, app 1.4.0+10)
- **Turn each streaming input on/off from the app** (Devices → *Streaming
  services*): Spotify / AirPlay / Roon, each an independent switch. The resource
  policy Petr asked for — one box runs only Spotify, another only Roon+AirPlay;
  an off service uses **no** memory or CPU. The choice is **persistent** across
  reboots (a reflash resets to defaults: Spotify + AirPlay on, Roon off).
- Protocol §11 (`companion/PROTOCOL.md`): `listServices` → `{services:[{id,name,on}]}`,
  `setService {id,on}` → emits `servicesChanged`. `on` = `systemctl --user
  is-active` (NOT `is-enabled` — it reports `disabled` for both a vendor-enabled
  *running* unit and a genuinely-off one, measured 2026-07-17). ON = `unmask` +
  `enable --now`; OFF = `mask --now` (mask, not disable — it overrides the
  `/usr/lib` vendor `default.target.wants` symlink that keeps librespot/shairport
  default-on). Root bridge reaches the uid-10000 manager via
  `systemctl --machine=user@.host --user`. **Tested live 2026-07-17.**
- HDMI desktop stays on its own §10 `setDesktop` (system unit, non-persistent).
- NOT in v1.11.0-rc1 (which built from before this change, control r10); folds
  into the eventual v1.11.0 release build (control r11).



> **2026-07-17 late session: Roon VALIDATED END-TO-END against Petr's ROCK Core
> (Proxmox VM, 192.168.20.105) — all three inputs (Spotify, AirPlay, Roon) play.**
> The v1.10.2-dev-r53 image was flashed (first-boot resize worked: 2.0→12.7 GB);
> Roon was then brought up live and every fix baked as device r54 (+ r55: the
> loopback cushion bumped 100→250 ms to match the value proven smooth live):
> - glibc base gaps: `/tmp` missing from the base tarball broke unprivileged bwrap
>   (mountpoint must pre-exist) → recreated at package time (+ apt dirs).
> - `--tmpfs /run` (bind target for `/run/user/10000` in a root-owned baked /run).
> - `--ro-bind /sys` — Mono reads iface state from /sys/class/net; without it all
>   ifaces enumerate "not up" and the bridge never SOOD-announces (invisible).
> - `--unshare-uts --hostname` from the onboarding name (device.json) — Roon
>   lists "Nexus-Q", not "steelhead" (Petr's request).
> - PA grabbed the RoonLoop card (udev-detect) and held its playback substream →
>   RAAT `DeviceOpenFailed`; fixed by extending the PULSE_IGNORE udev rule to
>   `snd_aloop.1`.
> - Audio architecture: Roon can't speak PulseAudio → dedicated 2nd aloop card
>   `RoonLoop` (index 7 pinned; `snd-aloop-options.conf`), sandbox sees ONLY its
>   nodes (can never grab TAS5713 hw), wrapper loads `module-alsa-source`
>   (hw:RoonLoop,1,0 @48k, holds the pair at 48 kHz so RAAT converts) +
>   `module-loopback` (250 ms) to the default sink — Roon follows the app's
>   output switch like every input.
> - Firewall `62_roon.nft` — measured packet-by-packet: udp 9003 (SOOD),
>   tcp 9100-9200 (jsonserver), tcp+udp 32768-60999 (dynamic zone device/audio +
>   clock-sync ports; blocked clock = zone enables but tracks "skip").
> - Choppy playback fixed by: RTPRIO for RAAT (`user@10000.service.d/rtprio.conf`,
>   LimitRTPRIO=50 — its sched_setscheduler was failing in the sandbox), the
>   250 ms loopback cushion, and Core-side Device Setup → **Buffer Size** (Petr
>   set it up; RAAT's default 40 ms buffer is too tight for this chain).
> Known cosmetics: RAAT enumerates the RoonLoop card as TWO "Loopback PCM"
> devices (control-level, can't hide DEV=1 — it fails fast if enabled; enable the
> one that succeeds); a PA restart restores stale device volume (live-session
> artifact only). RoonBridge itself: lazy first-run fetch + Roon self-updates.

### Added
- **AirPlay input (shairport-sync)** — device r50. A systemd USER unit in the
  uid-10000 session (like librespot); `alsa`→`pulse` routing so AirPlay is one
  more PulseAudio input; name from `/etc/nexusq/device.json`; pinned ports
  (RTSP 5000/tcp, UDP 6001-6010) opened by `61_airplay.nft`.
  **User-tested 2026-07-17 on the live device (hand-copied files): works great.**
  Not yet built into a flashed image.
- **First-boot rootfs grow** — device r51. `nexusq-resize-rootfs` (+ `.service`,
  enabled via `95-nexusq.preset`): online-grows the flashed ~2 GB ext4 to fill the
  14 GB partition, once, self-guarded. Live-verified: 2.0 GB → 12.7 GB.
- **Roon Bridge packaged** — device r52. Roon's Mono cannot run on musl (gcompat
  segfaults it), so the Bridge runs in a bwrap sandbox over a baked, sha512-pinned
  Debian bookworm armhf glibc base at `/opt/glibc-rt` (proven live end-to-end:
  `check.sh` SUCCESS, RAATServer running — `docs/2026-07-17-roon-tidal-feasibility.md`).
  Only the base is baked; `roon-nexusq` lazily fetches RoonBridge on first start
  into a uid-10000-owned dir and Roon self-updates from there. `roon.service` is a
  **default-OFF** user unit (`systemctl --user enable --now roon`) — the resource
  policy is that only user-enabled services run; the companion app gets per-service
  toggles as a follow-up feature. Tidal deferred (grey-area extracted binary).
  Open: upload the base tarball as the `glibc-rt-bookworm-armhf-1` GitHub release
  asset (automation was permission-blocked); RAAT firewall drop-in measured during
  live validation against a Roon Core.

## [1.10.1] — 2026-07-16 — bug-fix release (factory WiFi MAC · btagent fd leak · onboard · librespot boot race · app debug mode) (device r49, btagent r4, kernel r44, control r10, setupd r4, nexusqd r10, firmware r2)

> Five faults, each root-caused with evidence; built, flashed, and hardware-verified
> on a fresh v1.10.1 flash. App on its own track at **1.3.1+9** (NOT part of the
> image). Full record: `docs/2026-07-16-v1.10.1-bugfixes.md`. Base: v1.10.0.

### Fixed

- **Factory WiFi MAC — now pinned in the DTS** (kernel patch
  `0043-ARM-dts-omap4-steelhead-wifi-local-mac-address.patch`, r43 → **r44**).
  `local-mac-address = [f8 8f ca 20 48 e1]` on the `wifi@1` node, mirroring the BT
  `local-bd-address`. **Hardware-verified:** `ethtool -P wlan0` now reports PERMANENT
  `f8:8f:ca:20:48:e1` (was the chip OTP MAC `14:7d:c5:3a:35:b5`, Murata OUI). Stock
  sourced it from the bootloader cmdline (`androidboot.wifi_macaddr=`, from the
  efs/factory partition) — a path we can't reproduce (U-Boot doesn't pass it,
  `CONFIG_CMDLINE_FORCE=y` discards it); the nvram macaddr is a generic Broadcom
  placeholder and **brcmfmac ignores it** because the chip has a MAC in OTP (verified
  live 2026-07-16: overriding nvram + reloading the module left the permanent MAC at
  OTP). The only route is DT — `brcmf_of_probe()` reads `local-mac-address` into
  `settings->mac` and programs it over OTP. **This closes the onboarding-profile gap
  too:** the setupd-created profile no longer needs a `cloned-mac-address` pin since NM
  `permanent` == the factory MAC now. *(Was "ROOT-CAUSED but NOT fixed" in v1.9.0 /
  v1.10.0 known issues.)*
- **btagent fd leak → the app "kept disconnecting"** (btagent r3 → **r4**). The phone's
  Devices screen showed BT calls failing every 3 s with **"bluetooth agent unreachable:
  No such file or directory"** while the connection itself was healthy. On device
  btagent was `active` but **its control-socket file was GONE** and the journal repeated
  `[Errno 24] No file descriptors available`. Cause: `start_control()` (listening socket
  + GLib watch) was called from the **10 s `_tick`** as well as `run()`, leaking one fd
  per tick until it exhausted them (~1024) and crashed mid-tick with the socket removed.
  Fix: `_tick` no longer calls it; `start_control()` is guarded idempotent. **Verified:
  fd count flat at 8 across ticks.** *(Found on the first try by the app's new in-app
  debug log — below.)*
- **`onboard` SIGSEGV every boot** (device r48 → **r49**). The on-screen keyboard
  crashed in its native `osk` module every boot — useless on an appliance with no
  touchscreen/input. Its autostart lives in `/etc/xdg/lxqt-tablet/autostart/` (not the
  plain `autostart/` our XDG shadow covers), so the apk **trigger** now also fires there
  and neuters onboard's own file (`Hidden=true`). **Verified: 0 onboard coredumps on the
  fresh v1.10.1 boot.** *(Was a v1.9.0/v1.10.0 known-open item.)*
- **librespot boot-race storm** (device r48 → **r49**, same package). The wrapper waited
  **30 s** for wlan0's DHCP IPv4 before starting librespot; BCM4330 cold-boot
  association routinely takes longer, so the first start gave up → systemd `Restart` → a
  **5× storm**. `After=network-online.target` doesn't help (the USER-manager-level target
  isn't wired to real connectivity). Extended the wait **30 → 180 s** (exit 1 stays for a
  genuinely dead radio). **Verified: 0 restarts.** *(Was a v1.9.0/v1.10.0 known-open
  item.)*
- **Companion app — Devices red-bar flicker** (app 1.2.0 → **1.3.1**). The Devices
  screen's 3 s background poll now **logs** failures instead of flashing the red error
  bar; only user-initiated actions show a visible error.

### Added

- **Companion app — "Debug mode"** (Devices → Developer, app **1.3.1+9**, own version
  track — NOT part of the image). Reveals an **always-on** in-app connection log:
  collection is always on (a 600-entry ring of short strings), the toggle only reveals
  the viewer, so the history leading up to a flicker is already captured. Records the
  banner switch (connection UP/DOWN), DROP causes (peer-closed vs socket-error vs
  supervisor-disconnect on a failed probe), probe latency, call timeouts with
  pending-queue depth, slow/late responses, and lifecycle transitions. **Method names
  only, never params** (`setWifi` carries the PSK). **This log is what found the btagent
  fd leak (above) on the first try.**

## [1.10.0] — 2026-07-15 — Bluetooth pairing from the app, BOTH directions · HDMI desktop on demand (device r48, btagent r3, control r10, setupd r4, nexusqd r10, kernel r43, firmware r2)

> **Step 2 of the software phase**, built on v1.9.0's BlueZ infrastructure.
> Hardware-verified and user-accepted 2026-07-15. App on its own track at
> **1.2.0+7**. Full record: `docs/2026-07-15-step2-bt-pairing-implemented.md`.
>
> **The framing that matters:** the Q has **no screen and no input device**, so the
> **app is the ONLY way to pair anything to it — it IS the Q's Bluetooth settings
> panel**. The original phase spec only imagined "let a phone pair for music"; it
> missed the half that **only the app can do**:
>
> | Direction | Who initiates | Example |
> |---|---|---|
> | Inbound | the phone | pairs for music (A2DP) |
> | **Outbound** | **the Q** | scans for and pairs a **mouse / keyboard** |
>
> Outbound is a **different flow, not a variant**: a mouse never connects TO us; we
> must discover it and call `Pair()` on it.
>
> ⚠️ **Read "Known issues / open" at the end of this release before relying on it** —
> the v1.9.0 onboarding flake is still un-root-caused, the factory WiFi MAC is
> root-caused but NOT fixed, a diag sweep measured **102.8 °C** under sustained load,
> and the new Devices screen has had **no design review**.

### Fixed

- **⛔ ROOT CAUSE — the `Pairable == Discoverable` invariant shipped in v1.9.0 was
  based on the WRONG property and silently broke OUTBOUND bonding.** A/B on a real
  Logitech MX Master 4, same agent, **one variable**:

  ```
  Pairable: no   ->  pair "succeeds", Bonded: no,  NO keys stored, gone on restart
  Pairable: yes  ->  pair succeeds,   Bonded: yes, [PeripheralLongTermKey] +
                     [IdentityResolvingKey] on disk, SURVIVES restart
  ```

  Chain, **measured from `bluetoothd -d`** (not read from source): the key **ARRIVES**
  (`new_long_term_key_callback() … new LTK … enc_size 16`), but bluez only
  **persists** a key the kernel marked **`store_hint`**; the kernel only marks it so
  when **both** sides set the SMP **bonding bit**; and our side only sets that bit
  under **`HCI_BONDABLE`** — which is exactly **`Adapter1.Pairable`**. So a mouse
  paired at rest reports success, connects, genuinely types, and **evaporates on
  reboot**. **Inbound never hit it** because setup opens a window first.
  **Fix (btagent r3):** the ring now keys off **`Pairable`** (the only property that
  gates pairing), `Pairable` is **off at rest**, and an outbound pair **OPENS A
  WINDOW like everything else** — one mechanism for both directions. *Turning
  `Pairable` on is not a concession to minimise; it is what makes a bond durable.*
- **A pairing window now self-closes via bluez's own timer** (btagent r3). Verified:
  `openWindow(30)` → open at t+10/t+20, **CLOSED at t+30/t+40**. This was FALSE
  before: our own 10 s reconcile tick rewrote `DiscoverableTimeout` and **restarted
  the countdown** every pass, so a window could stay open indefinitely. bluez owning
  the timer also means the window still closes if btagent is killed mid-window.
- **`pair` now owns its own discovery** (btagent r3). BlueZ forgets an unpaired
  device object shortly after discovery stops, so the object from the user's scan is
  usually **gone** by the time they tap Pair (measured: `Pair` → `UnknownObject`).

### Added

- **`nexusq-btagent` r3 — a control socket** (`/run/nexusq-btagent.sock`, **0600**,
  newline-JSON): the LAN bridge's **only** way into BlueZ. The bridge is stdlib-only
  by standing rule, and that rule is right — **BlueZ knowledge belongs in the
  component that owns BlueZ**, not in a second Bluetooth stack. Methods:
  `openWindow`/`closeWindow`/`windowState`, `startScan`/`stopScan`/`scanResults`,
  `pair`/`remove`/`connect`/`disconnect`, `listPaired`. **`pair` is async** — `Pair()`
  takes seconds and our own `Agent1` **must answer DURING it**, so a synchronous call
  would deadlock the very agent that completes the pairing.
- **`nexusq-control` r10 — Bluetooth + desktop methods** (PROTOCOL §9/§10):
  `startPairing`/`stopPairing`/`getPairingState`, `startBtScan`/`stopBtScan`/
  `listBtScanResults`, `pairBtDevice`/`removePairedDevice`/`connectBtDevice`/
  `disconnectBtDevice`, `listPairedDevices`; events **`pairingChanged`**,
  **`pairedDevicesChanged`**. Plus **`setDesktop`/`getDesktop`** + event
  **`desktopChanged`**. All BT calls forward to btagent's socket; its error codes
  (`not_found`/`pair_failed`/`unavailable`/`unknown_method`) already speak this
  protocol's vocabulary and pass through.
- **HDMI desktop on demand** — `setDesktop {on|off}` starts/stops `tinydm.service`.
  **`device-google-steelhead` r48 bakes `/var/lib/systemd/linger/user`**, which is
  **load-bearing**: PA + librespot are user units under `user@10000.service`, the
  desktop is `tinydm` → labwc in `session-c1.scope`; **without linger the user
  manager exists only because of the graphical session, so stopping the desktop would
  kill the music**. Verified: with linger, `systemctl stop tinydm` leaves pulseaudio +
  librespot **active, both sinks present**.
- **Companion app 1.2.0+7** (own **independent** version track — **NEVER** aligned to
  image releases): a new **Devices** screen — *Pair a phone* / *Add a mouse or
  keyboard* / paired list with *Forget* / **HDMI desktop toggle** — reachable from the
  home app bar.
- **PROTOCOL.md §9 "Bluetooth"** (both directions, the methods, `pairingChanged`/
  `pairedDevicesChanged`, error codes incl. `pair_failed`, the 120 s window, and the
  **`bonded` vs `paired`** distinction) and **§10 "Desktop"** (`setDesktop`/
  `getDesktop`/`desktopChanged` + the linger prerequisite). These methods existed
  **only in code** until this release.

### Changed

- **`bonded`, not `paired`, is the honest answer to "will this survive a reboot?"**
  `pairBtDevice` returns both; `paired: true` + `bonded: false` is a device that
  pairs, connects, genuinely types — and is **gone on reboot**. **`paired` alone
  LIES.** Documented in PROTOCOL §9.2.
- **`device_kind()` reads `Icon` → `Appearance` → `Class`, in that order** — because
  **BLE peripherals have NO Class of Device**. The MX Keys / MX Master report
  `class=none` and identify via BlueZ's `Icon` (`input-keyboard`/`input-mouse`) +
  `Appearance` (0x03c1/0x03c2). **A CoD-based device-type rule — this spec's first
  draft — would have hidden Petr's keyboard and mouse from the app entirely.**
- **Scan results are filtered on a real `Name`, never `Alias`.** BlueZ
  **synthesises `Alias` from the ADDRESS** (`"6B-64-CB-F3-81-98"`) when a device has
  no name, so `Alias` is never empty and **can never answer "does this have an
  identity"**. Without this, a scan returns a wall of the neighbours' anonymous BLE
  beacons (**~38 in 25 s**, measured).
- **`set_desktop` uses a 60 s deadline** — stopping the desktop **churns logind** hard
  enough that ssh auth (`pam_systemd`) hung for ~a minute during testing. It recovered
  on its own; a snappy timeout would report a false failure.
- **A scan self-stops** (25 s default, clamped 5–60): a permanently scanning radio
  hurts BT/WiFi coexistence on the shared BCM4330 antenna — and **WiFi is the app's
  own transport**.

### Verified (hardware)

- **Mouse paired from the app**: `pairBtDevice` → `{"paired":true,"bonded":true,
  "connected":true}`, **3 key sections on disk**, and the kernel created
  **`MX Master 4 Mouse`** on `/dev/input/…` via **uhid**.
- **A real BLE keyboard (MX Keys) completes Just Works** against our
  `NoInputNoOutput` agent — **no typed passkey**. HID works end to end
  (`/dev/uhid` → `/dev/input/event*`). **Good thing we never copied stock's
  `DisablePlugins = audio,network,input`** — that `input` is exactly **BlueZ's HID
  plugin**.
- **Discovery only lives while a client holds it**: a fire-and-forget
  `bluetoothctl scan on` dies instantly (`Discovering: no`, 0 devices). This is why
  discovery lives in btagent (D-Bus, long-lived), not in the bridge.
- **BLE devices change address between pairings/channels** — the MX Master exposed
  `…74:F4`, `:F5`, `:F6`, `:F7` on different channels. **A scan MAC is not a stable
  identity.**
- **Petr confirmed from the app**: mouse listed with the right icon, desktop toggle
  works both ways, phone paired to the Q, mouse forgotten and re-paired.

### Known issues / open

- **The v1.9.0 onboarding pairing flake is still un-root-caused** — 1 run × 2 failed
  attempts; 3+ runs first-try since. Carried forward unchanged.
- **The contactless-payment link is UNPROVEN.** App 1.1.1 scoped its NFC claim, but
  the telemetry **never showed our uid toggling observe mode**. The fix may be
  correct; it is not demonstrated.
- **Factory WiFi MAC: ROOT-CAUSED but NOT fixed.** `gen-wifi-profile.sh` pins
  `cloned-mac-address` into the **BAKED dev profile only**; the profile setupd creates
  via `nmcli connection add` does **not**, so NM falls back to `permanent` = the chip
  **OTP MAC `14:7d:c5:3a:35:b5`**. **The device has no source for the factory MAC at
  all** (nvram carries a generic Broadcom default). Proper fix mirrors BT: a
  **`local-mac-address` in the DTS wifi node**, after a stock audit. **Use the OTP MAC
  for lease lookups.** *(FIXED in v1.10.1 — DTS patch 0043; wlan0 permanent MAC is
  the factory `f8:8f:ca:20:48:e1` again.)*
- **Thermal: 102.8 °C** under sustained load — **above the documented 94–99 °C
  envelope**. True idle 72–75 °C / 52 % at 350 MHz.
- **librespot boot race** — 5 restarts, self-heals. *(FIXED in v1.10.1 — wait 30→180 s.)*
- **`onboard` SIGSEGVs every boot** — its native `osk` module. **NOT** the old flash
  corruption. *(FIXED in v1.10.1 — trigger neuters its lxqt-tablet autostart.)*
- **`NEXUSQ_NO_WIFI=1` build flag: still promised-but-unwritten.**
- **The Devices screen has had NO design review.** Petr tested it **functionally**
  2026-07-15; the copy is unreviewed.

## [1.9.0] — 2026-07-15 — app-driven onboarding: NFC tap → bonded BT → WiFi (device r47, setupd r4, btagent r1, nexusqd r10, kernel r43, firmware r2)

> **App-driven WiFi onboarding for the display-less Q, implemented end-to-end
> 2026-07-13** (plan `docs/superpowers/plans/2026-07-13-onboarding-step1.md`,
> 13/13 coding tasks, commits `ae8f499..cb03cf7`, subagent-driven with per-task
> + final whole-branch reviews). Flow: NFC tap → BT RFCOMM provisioning →
> WiFi join → name/room/theme → outro, with the original stock imagery.
> Full write-up: `docs/2026-07-13-onboarding-step1-implementation.md`.
>
> **✅ BT onboarding WORKS autonomously from a fresh flash — root-caused, fixed,
> user-accepted.** It was **TWO independent bugs, BOTH ours, NEITHER hardware**:
> (1) `blueman-applet`'s **DisplayYesNo** agent forced SSP into **Numeric
> Comparison**, raising a Confirm/Deny dialog on the HDMI desktop that **nothing
> attached to the Q can click** (every bond timed out, mgmt `0x0e`) — and
> `RequestDefaultAgent` being last-writer-wins let it steal the default agent too;
> (2) the app let the RFCOMM socket **bond on demand**, and Android's implicit bond
> against an unbonded Just-Works peer collapses (`bonding_attempt_complete status
> 0x5` → `0x0e`), surfacing as the misleading **"incorrect PIN"** toast. Shipped
> from **v1.9.0-rc5**, flashed and hardware-accepted. Full record:
> `docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`
> (supersedes `docs/2026-07-14-bt-onboarding-state-as-is.md`).
>
> ⚠️ **Read the "Known issues / open" section at the end of this release before
> relying on it** — pairing has an un-root-caused flake, the factory WiFi MAC is
> injected nowhere, and a diag sweep measured **102.8 °C** under load.
>
> **⚠️ RETRACTED: "the BCM4330 cannot complete SSP bonding."** That claim was
> WRONG. Pairing + A2DP worked 2026-07-09 (after the v1.8.0 BT-UART `max-speed`
> fix) and were **re-verified 2026-07-15**. **Lesson: never re-derive a hardware
> limit from a userspace symptom.**

### Added

- **NEW package `nexusq-setupd` 0.1.0-r0** — BT RFCOMM WiFi-provisioning
  daemon (`userspace/nexusq-setupd/` + `pmos/nexusq-setupd` aport +
  docker-build.sh staging + `nexusq.preset` enable): SetupCore state machine
  (getDeviceInfo/confirmColor/scanNetworks/setWifi/getNetworkState/setName/
  setTheme/finishSetup; error codes `wrong_password`/`not_found`/`timeout`;
  the psk is never logged), BlueZ Profile1 RFCOMM transport (service UUID
  `8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a`; **shipped as channel 22, bonded
  (`RequireAuthentication=True`), agent-less** — see the 07-14/07-15 entries
  below for how it got there; 600 s idle timeout),
  `ExecCondition=/usr/bin/nexusq-setup-needed` (runs only unprovisioned or
  when `/run/nexusq-setup.force` is armed). Deps `py3-dbus` + `py3-gobject3`
  (setupd only). 23 host tests.
- **`nexusqd` `spin R G B`** (r9) — rotating-dot setup animation on the manual
  override layer (`spinner.c`, host-tested; 30 ms cadence while active).
- **`nexusq-control` device identity + `startSetupMode`** (r9) —
  `/etc/nexusq/device.json` (`name` + `room`; room ships as mDNS TXT `room=`);
  `startSetupMode` arms the force flag + starts nexusq-setupd for
  re-provisioning (all failures map to `unavailable`); the librespot wrapper
  reads the Spotify device name from device.json.
- **Companion app setup wizard** — 8 screens (welcome/cables/find/
  confirm-color/wifi/name-room/theme/outro with `q_outro.mp4`), Kotlin BT
  RFCOMM platform channel, Dart BtSetupClient with pairing-color parity to the
  device (shared vectors `companion/pairing-color-vectors.json`), NFC-tap +
  "Set up new device" entry points, stock-asset extraction pipeline
  (`scripts/extract-stock-assets.sh`; Google-copyright assets gitignored,
  fresh clones build via `.keep` placeholders + icon fallbacks). 14 Flutter
  tests, analyze clean; debug build installed on the reference phone.
- **PROTOCOL.md §8 "Setup transport"** — UUID, Just-Works accepted-risk note,
  envelope reuse, the 8 methods + error codes, lifecycle, pairing-color
  contract.

### Changed

- **NFC tap payload = live connection info** (device pkg **r44**, closes the
  standing v1.7.0 backlog item): `nexusq-nfc-send` now rebuilds
  `{"v":1,"bt","host","ip","prov"}` per tap instead of a static greeting —
  provisioned tap auto-connects the app over LAN, unprovisioned tap jumps
  into the setup wizard.

### Fixed

- **`nexusq-nfc.service` no longer sets `NQ_NFC_MESSAGE`** (final-review
  catch, `af2dec4`): the env override takes precedence over the dynamic
  payload builder and would have dead-ended tap-to-onboard; it is now a
  documented manual-test override only, kept unset.
- **Repo-wide LF enforcement** (`.gitattributes` + renormalize, `cb03cf7`):
  a CRLF Windows worktree (system `autocrlf=true`) broke the dockerized
  build via the mount ("failed to source APKBUILD"). Committed blobs were
  never poisoned (verified byte-exact from a Linux container — earlier
  "poisoned blob" claims were msys pipe-translation measurement artifacts);
  the LF policy now lives in the repo, not machine config.

### Added (2026-07-14, v1.9.0-rc3)

- **`nexusqd` `spin R G B [rev_per_s]`** (r10) — optional 5th token sets the
  rotation speed (revolutions/s, float, 0<s≤20; omitted/≤0 = default 0.75). Plumbed
  through `spinner_render`; setupd uses it for LED state feedback (CONNECTING slow
  blue, WiFi-joined SUCCESS fast green, join ERROR slow red). **User-confirmed on
  device.** `pmos/nexusqd` r9→**r10**.
- **device r44→r46** — `+iw +ethtool +iproute2-minimal +tzdata`; **Europe/Prague**
  timezone (post-install symlinks `/etc/localtime`+`/etc/timezone`).

### Changed (2026-07-14, v1.9.0-rc3)

- **Correct BT firmware** — `firmware/bcm4330.hcd` (+ `private/firmware/`) replaced
  the WRONG board blob (*"Proxima BCM4330B1 NoExtLNA"*, md5 `16db686…`) with the
  stock steelhead *"Google Phantasm BCM4330B1"* (md5
  `7e5bb859e33142e94052c76fba23b9e6`, 51813 B, build 0749).
  `firmware-google-steelhead` r1→**r2**.
- **`nexusq-setupd` RFCOMM channel 3→22** (r0→**r2**) — channel 3 collided with the
  Headset profile (`rfcomm_bind` "Address in use" → server never started). Lesson: a
  BlueZ server-role ext profile only starts its RFCOMM listener when a `Channel` is
  given; 22 is clear of the Q's audio/PBAP stack (3,9,10,13–17).
- **`nexusq-setupd` transport set INSECURE/unbonded** (`RequireAuthentication=False`)
  + app `createInsecureRfcommSocketToServiceRecord` — ⚠️ **REVERTED 2026-07-15**
  (see below): it was a workaround for a misdiagnosed "hardware limit", and the
  cleartext-PSK + no-BT-audio costs are gone with it.
- **`docker-build.sh`** — `--force` on the `nexusqd`/`nexusq-control`/`nexusq-setupd`
  builds (fixed a warm-volume STALE-apk trap that shipped an old setupd); `timezone =
  Europe/Prague` (pmbootstrap was overriding the post-install symlink with GMT).
- **Companion app polish** — NFC-tap dedup guard (the Q re-emits the payload ~8 s →
  wizard was restarting), BT permission requested inside `connect()`, confirm-color
  retry, centered/rotating find-device glow, outro de-flicker, welcome sphere
  (gaplessPlayback+precache+original-size+centered), build stamp
  (`lib/build_info.dart` via `--dart-define BUILD_TAG`).

### Fixed (2026-07-14, v1.9.0-rc3)

- **BT adapter MAC via D-Bus/bluetoothctl fallback** — mainline 6.x has no
  `/sys/class/bluetooth/hci0/address`; the empty MAC broke the NFC tap payload
  (`"bt":""`) and `confirmColor`. setupd falls back to BlueZ `Adapter1.Address`;
  `nexusq-nfc-send` falls back to `bluetoothctl show`. `confirmColor` now raises
  `unavailable` on an unknown MAC instead of crashing.
- **Setup mode stays armed while unprovisioned** — the 600 s inactivity timeout no
  longer leaves setup mode when there is still no WiFi profile (would strand the
  device with nothing to re-arm it until a reboot).

### Added (2026-07-15, v1.9.0-rc4)

- **NEW package `nexusq-btagent` 0.1.0-r0** (`userspace/nexusq-btagent/` +
  `pmos/nexusq-btagent/APKBUILD` + docker-build.sh staging/build + preset enable) —
  the appliance's **single, PERMANENT** BlueZ `Agent1`: `NoInputNoOutput`
  auto-accept, marks new bonds **`Trusted`**. Permanent (not setup-scoped) because
  **BT audio/A2DP needs a bond long after setupd exits**. Full rationale +
  interfaces: `userspace/nexusq-btagent/README.md`.
- **`Pairable == Discoverable` invariant** (btagent) — KEY INSIGHT: **`Pairable`,
  not `Discoverable`, gates bonding** (discovery only affects *inquiry*, and bluez
  leaves `Pairable=true` forever), so a ring tied to `Discoverable` alone would be a
  **LIE** — dark while still bondable. Now **ring spins blue ⇔ anyone can pair**
  (a user requirement: security visibility). `led_plan()` is a pure, unit-tested
  function; btagent never releases a ring it did not take (so it can't wipe
  setupd's applied theme).

### Changed (2026-07-15, v1.9.0-rc4)

- **`nexusq-setupd` r2→r3 — bonded, agent-less setup link.** Registers **NO agent**
  (two agents is exactly how this broke) and hard-`depends=` nexusq-btagent; profile
  **`RequireAuthentication=True`** (was `False`) → bonded + encrypted setup link →
  **the WiFi PSK no longer crosses the air in cleartext** (0 PSK lines in the
  journal, verified). This **retires** the 07-14 "insecure RFCOMM workaround to
  revisit" — which was itself **stock parity** (stock never bonded during onboarding
  and accepted a cleartext PSK); we moved **beyond** stock deliberately.
- **`device-google-steelhead` r46→r47** — `depends=` +nexusq-btagent; preset enables
  it; **`/etc/xdg/nexusq/autostart/blueman.desktop`** (`Hidden=true`) suppresses
  `blueman-applet` via the existing XDG_CONFIG_DIRS shadow trick (the blueman
  **package stays** — `blueman-manager` on demand); post-install sets bluez
  **`Class = 0x200428`** (Audio/Video / HiFi Audio — live reads `0x006c0428`, bluez 5
  ORs in its own service bits; **cosmetic identity only** — stock's own scanner
  ignored CoD and matched SDP UUIDs, and so does our app).
- **Companion app 1.0.0+1 → 1.1.0+2** — secure `createRfcommSocketToServiceRecord` +
  **explicit bond-first**; find-device list overflow fixed (a `Column` can't scroll →
  yellow overflow stripes with many BT devices); connect-gate ring re-centred (a
  non-positioned `Stack` child gets loose constraints and parks at `topStart` →
  `Positioned.fill`); new `companion/app/build-apk.sh`; version shown in UI
  (`kBuildLabel`). ⚠️ **The app is versioned on its OWN INDEPENDENT TRACK —
  deliberately NOT aligned to the device image releases** (device compatibility is a
  PROTOCOL concern, not a version-number one).
- **`docker-build.sh`** — nexusq-btagent wired into validation, staging, dos2unix and
  the build phases. ⚠️ **Phase ORDER IS LOAD-BEARING**: btagent (**7c3**) must be
  checksummed + built **BEFORE** setupd (**7c4**), which now depends on it — the
  reverse order fails **every clean build** with `nexusq-btagent is missing in
  checksums`.

### Fixed (2026-07-15, v1.9.0-rc4)

- **BT onboarding now works autonomously from a fresh flash** — TWO independent
  bugs, BOTH ours, NEITHER hardware (see the status note at the top of this
  release):
  - **`blueman-applet` hijacked the SSP pairing model.** SSP picks its model from
    BOTH ends' IO capabilities: phone DisplayYesNo + Q `NoInputNoOutput` = **Just
    Works** (no prompt); phone DisplayYesNo + Q **DisplayYesNo** = **Numeric
    Comparison** (both ends must confirm). blueman registers a DisplayYesNo agent →
    bluetoothd raised a Confirm/Deny dialog on the HDMI desktop that **nothing
    attached to the Q can click** (no keyboard/mouse/touch) → every bond timed out
    (mgmt `0x0e`). Live proof with blueman gone: `user_confirm_request_callback …
    confirm_hint 1` (= Just Works) and a Pixel 9 Pro Fold bonded **instantly, zero
    agent callbacks**.
  - **The app let the RFCOMM socket bond on demand.** Android's implicit bond from
    `createRfcommSocketToServiceRecord` against an unbonded Just-Works peer forms
    and immediately collapses (`bonding_attempt_complete status 0x5` = auth failed,
    then `0x0e` = disconnected); no link key is written and RFCOMM never reaches
    setupd. Android surfaces this as the **misleading "incorrect PIN"** toast —
    **no PIN exists in a Just-Works flow.** Fix: explicit `createBond()` + wait for
    `BOND_BONDED` **before** opening the socket.
- **`finishSetup` no longer strands the device** (setupd r3) — it is now REFUSED
  (`bad_request`) unless wifi is provisioned. Accepting it unprovisioned made setupd
  exit 0, so `Restart=on-failure` did **not** restart it and nothing re-armed setup
  mode until a reboot. The app reached this state live 2026-07-15.

### Fixed (2026-07-15, v1.9.0-rc5) — fail CLOSED on the pairing window

- **`nexusq-setup-needed` failed OPEN: a provisioned device could drop into setup
  mode and advertise itself pairable** (`nexusq-setupd` r3→**r4**, `b2a08af`; found
  by a diag sweep, in a window where NetworkManager was demonstrably disturbed). It
  piped nmcli straight into grep and threw the exit code away —

      if nmcli -t -f TYPE connection show 2>/dev/null | grep -q '^802-11-wireless$'

  — so **"nmcli failed / NM is not up yet" was indistinguishable from "there is no
  WiFi profile"** → exit 0 → a fully **provisioned** device arms setup mode and goes
  **discoverable + pairable**. The agent **auto-accepts by design** (nothing
  attached to this appliance can answer a prompt), so that transient hands a
  passer-by a bond. Now **only a SUCCESSFUL nmcli listing no wifi profile** means
  unprovisioned; anything else assumes provisioned and stays out. Being wrong that
  way costs a `startSetupMode` to re-enter setup — being wrong the other way leaves
  an open pairing window on a live device. Verified on the device including a faked
  nmcli failure; +65 lines of host tests.
- **`nexusq-btagent` `setupd_active()` failed OPEN in the opposite direction**
  (btagent r0→**r1**, same commit): `systemctl is-active` **has timed out live under
  load**, and the fallback assumed *"setupd owns the ring"* — which **SKIPS the
  pairing-exposure indicator while the adapter is still pairable**, i.e. exactly the
  lie the ring exists to prevent (**dark must mean nobody can pair**). It now fails
  to **FALSE** and claims the ring. Cost is near-zero (`DISCOVERABLE_CMD` is
  byte-identical to setupd's idle spin → worst case it re-sends the blue already
  showing, plus a wiped theme in a rare error path); a silently dark ring on a
  bondable appliance is the worse failure.

### Added (2026-07-15, v1.9.0-rc5)

- **`startSetupMode` re-provisioning — TESTED and PASSING** (the last untested
  acceptance item). Verified live over the LAN bridge:
  `{"ok":true,"result":{"started":true}}` → setupd active, force flag armed,
  adapter discoverable + pairable, and **btagent correctly YIELDED the ring to
  setupd** (no "ring ON" line).

### Changed (2026-07-15, v1.9.0-rc5)

- **Companion app 1.1.0+2 → 1.1.1+5 — the NFC claim is scoped to when a tap is
  actually expected** (`f0b5b20`, `33d3122`, `4717b44`). ⚠️ The app is versioned on
  its **OWN INDEPENDENT TRACK — deliberately NOT aligned to the image releases.**
  **Measured, not reasoned**: routing alone is not enough, because the phone sits in
  Android 15 **observe mode** and deliberately never answers a reader's field —
  `MSG_RF_FIELD_ACTIVATED`/`_DEACTIVATED` cycling ~150 ms, **no APDU ever reaching
  `NqHceService`**. The platform drops observe mode for the **PREFERRED** service
  when it declares `shouldDefaultToObserveMode="false"`, which ours does — **so the
  claim IS the tap.** It is now claimed **only by the connect screen** (the "waiting
  to be tapped" state) and dropped on connect, on dispose and on every `onPause`;
  the HCE component ships `android:enabled="false"` so a **closed app has ZERO NFC
  surface** (previously ANY open app claimed NFC priority, including while just
  playing music). Measured:

  | state | preferred | observe mode | AID routed |
  |---|---|---|---|
  | app closed / backgrounded | `null` | `true` | 0 |
  | app on the connect screen | ours | `false` | 1 |

  Observe mode **returns to `true` when we let go** — the phone is not left in a
  payment-hostile state. **Motivation — and its unproven status:** the user's
  contactless payment failed twice, only ever after a dev session. This is **NOT a
  confirmed root cause** and is recorded as **risk reduction only** — the NFC
  telemetry shows observe mode toggled solely by `com.android.nfc` /
  `com.google.android.gms`, **never by our uid**, and it returns to `true` on its
  own. **If payment fails again, capture `dumpsys nfc` AT THE MOMENT OF FAILURE.**

### Acceptance (v1.9.0-rc4, fresh flash, 2026-07-15) — PASS

Cold boot from a fresh flash → setupd armed itself (`setup mode active:
discoverable`), btagent registered as default, blueman absent, Class `0x006c0428`,
no bonds. App (NFC tap path) → bond + `Trusted` + **A2DP authorized** (`0000110d`) →
RFCOMM → **WiFi joined** (192.168.20.149) → `finishSetup` → btagent auto-closed the
pairing window (`enforcing Pairable=False`). **PSK: 0 lines in the journal.** A2DP
live: `bluez_source…a2dp_source s24le 2ch 48000Hz` + PA loopback. Also
user-verified: wrong WiFi password → **ring turns red**; **NFC tap goes straight to
pairing** (the BT device list is only the no-NFC fallback).

### Final acceptance (v1.9.0-rc5, fresh flash, 2026-07-15) — PASS (shipped)

NFC tap delivered → **bond first try (0 failed attempts)** → RFCOMM → **WiFi
joined** → `finishSetup` → pairing window auto-closed → **`NFC: released preferred`**
the moment the device came up. **PSK: 0 log lines.** This is the build v1.9.0 is cut
from.

### Known issues / open (v1.9.0)

- **Pairing flakiness — NOT root-caused.** One run needed **2 failed attempts**
  before succeeding (user-reported); the **three subsequent runs passed first try (0
  failures)**. Suspicion only, nothing confirmed: the app's 30 s `ensureBonded`
  timeout (the phone log shows a ~27 s gap before the successful bond) and/or a
  stale phone-side bond — **that second one is WEAKENED**, since a run with a stale
  phone bond still succeeded first try. A repro needs `bluetoothd -d`. **OPEN.**
- **The contactless-payment link is UNPROVEN.** The NFC-claim scoping (see rc5
  above) is risk reduction, not a fix for a diagnosed fault: observe mode is toggled
  only by `com.android.nfc`/`com.google.android.gms` in the telemetry, never by our
  uid, and it returns to `true` on its own. **If it recurs, capture `dumpsys nfc` AT
  THE MOMENT OF FAILURE.** **OPEN.**
- **The dev image BAKES Petr's WiFi** (`private/access/wifi.nmconnection`), so a
  fresh-flashed **dev** image self-provisions and `nexusq-setup-needed` correctly
  reports "not needed" → **setup mode never arms**. This — not an onboarding bug —
  is why the fresh 07-14 build "wouldn't come up". `PUBLIC_RELEASE=1` images do not
  bake it, so real users get onboarding. Today's acceptance required manually
  deleting the baked profile. **Open task: a `NEXUSQ_NO_WIFI=1` build flag** (skip
  only the wifi bake, keep ssh keys) — promised, **NOT yet written**.
- **The factory WiFi MAC `f8:8f:ca:20:48:e1` is injected NOWHERE** — wlan0 runs the
  chip OTP MAC (`14:7d:c5:3a:35:b5`, Murata OUI; nvram `bcmdhd.cal` says
  `00:90:4c:c5:12:38`) and its DHCP lease carries an **empty hostname**. **Look the
  lease up by the OTP MAC `14:7d:c5:3a:35:b5`** — the documented
  `f8:8f:ca:20:48:e1` is **stale**. BT MAC is fine (DTS `local-bd-address`). NB
  `firmware/README.md`'s claim that WiFi identity is "pinned at the NetworkManager
  layer" is **retired-pending-fix**. **Open task**, unrelated to onboarding.
- ⚠️ **Starting `blueman-applet` by hand breaks pairing again** until it exits.
- **Thermal: 102.8 °C measured under bounded dual-core load** (diag sweep
  2026-07-15) — **above the documented 94–99 °C envelope** and past the **100 °C
  passive trip**. Throttling engaged correctly and the 125 °C critical trip was
  never approached, but the envelope in the docs understates the real ceiling.
  **True idle is fine**: 72–75 °C, 52 % residency at 350 MHz. **OPEN.**
- **librespot boot race — 5 restarts at boot** (`wlan0 has no IPv4 after 30s`): the
  wrapper hard-binds `--zeroconf-interface`, so it must wait for the WiFi IP.
  **Self-heals once associated**, but the restart burst is noise. **OPEN.**
- **`onboard` SIGSEGVs every boot** in its native `osk` module. **NOT** the old
  flash-corruption class — `python3 -S -c ''` is rc 0. **OPEN.**
- Full record:
  `docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`.

## [1.8.2] — 2026-07-13 — idle power: conservative governor + pid-1 churn killed (kernel r43, device r40)

> **The "hot idle" AI-handover task, attacked measurement-first — and the measurement
> rewrote the problem.** A 686 s true-idle study on v1.8.1 showed the ~74–76 °C "idle
> floor" was an **observer artifact** (any ssh/diag session heats the die to 74–79 °C
> in seconds; cooling constant ~10 s; true unobserved floor ~65–66 °C). The REAL
> faults found instead: **74 % of idle spent at ≥700 MHz/≥1203 mV** (ondemand
> jump-to-max on ~1000 microburst wakeups/s → a 17.5 trans/s sawtooth) and **pid 1 as
> the top userspace idle consumer (steady 3.4 %)** — caused by OUR nq-healthd's
> systemctl polling, which had ALSO silently broken librespot monitoring since device
> r31. Ships: kernel **r43** (`#44-postmarketOS`, defconfig-only — no new patch, 42
> patches unchanged), `device-google-steelhead` **r40** (r39 was burned
> mid-iteration, see Fixed). Flashed + acceptance-swept PASS
> (`nq-captures/20260713-102339/`). Full write-up:
> `docs/2026-07-13-idle-power-governor-and-pid1-churn.md`.

### Changed

- **Default cpufreq governor → `conservative`** (defconfig
  `CONFIG_CPU_FREQ_DEFAULT_GOV_CONSERVATIVE=y`, ondemand still built; kernel
  **r43**). Decided by a live A/B/C test (8-min windows, settings restored after):
  **conservative wins** (350 MHz residency 51.5 %, 1.2 GHz 9.6 %, 4.16 trans/s,
  coolest avg 65.1 °C); tuned ondemand
  (`sampling_rate=100000`/`up_threshold=80`/`sampling_down_factor=5`) was a
  **REGRESSION** (parks at high OPPs, 350 MHz only 21 %); `powersave_bias=100`
  dithers (39.9 trans/s). **Lesson: slower ondemand sampling does NOT tame
  microburst load** (~1000 wakeups/s × ~1.1–1.4 ms dwell: twd tick 168/s, WiFi
  SDIO 29.5/s, AVR i2c 15.5/s, DISPC 4.9/s → ondemand's 20 ms window +
  `up_threshold=95` = jump-to-max 3.7×/s) — conservative's gradual `freq_step`
  climb does. This re-reverses the v1.6.6 "back to ondemand" defconfig change;
  that call predates any idle-residency measurement.
- **nq-healthd rewritten process-first** (device **r40**): cached MainPID +
  `/proc` liveness per 5 s sample; **one** `systemctl show` (3 props, single bus
  connection) only on transitions (a unit restart always changes MainPID, so
  `NRestarts` bumps are still caught). Was 5 systemctl execs per sample — every
  root systemctl forces pid 1 to re-register its private-bus object tree, holding
  pid 1 at a steady ~3.4 % idle CPU.
- **Baked `/var/lib/systemd/linger/root`** (≡ `loginctl enable-linger root`,
  device r40): root's user manager stays resident — each ssh login was building +
  tearing down the whole `user@0.service` session (~7.5 s CPU per login/logout
  cycle; 31 logins in the studied boot).

### Fixed

- **librespot monitoring was silently DEAD r31–r38** (`ls_active`/`ls_restarts`
  always `unknown`/`0` — librespot restart detection never fired): nq-healthd
  queried `librespot.service` on the SYSTEM manager, where it hasn't existed
  since it became a uid-10000 USER unit (device r31) — worse, pid 1 loaded +
  GC'd the nonexistent unit from disk on every poll. Now queried on the
  uid-10000 user manager via `systemctl -M user@ --user show …` (verified
  on-device 2026-07-13). **GOTCHA that burned r39:** root cannot borrow the
  user's `XDG_RUNTIME_DIR` — systemd 261 refuses cross-user private-socket
  connections (`Operation not permitted, consider using --machine=<user>@.host`);
  r39 shipped that broken form (`ls_active=unknown` again), was caught by the
  post-flash acceptance sweep, and fixed as r40 + rebuild + reflash.

### Documented

- **Measured payoff (542 s idle re-study on the final v1.8.2):** 350 MHz
  residency 25.6 → **56.7 %**, ≥700 MHz 74 → **43.3 %**, 1.2 GHz → **3.5 %**,
  transitions 17.5 → **4.25/s**, pid 1 3.4 → **0.10 %**, idle temp avg 66.4 →
  **65.8 °C**, idle now **settles at 350 MHz** (was a ~920 MHz hover). The
  remaining ~65 °C structural floor is C1-only MPUSS — unchanged, blocked on
  serial (deep cpuidle C2+ backlog).
- **Idle-temp diag rule:** judge idle temperature only from an on-device
  self-logging capture with **no live ssh session** — an interactive read
  measures the measurement (74–79 °C within seconds of connecting).
- **NEW known-external journal residual (#4):** one-shot `NetworkManager:
  sd-event.c:4488 assertion failed` exactly at the RTC→NTP clock step — NM's
  **vendored libsystemd** asserting on the huge CLOCK_REALTIME jump (no RTC
  battery; the clock jumps years at NTP sync). NM continued fine, WiFi
  associated the same second. Dispositioned in
  `docs/2026-07-02-boot-error-inventory.md`; a real fix (upstream NM /
  clock-step ordering) is backlog, not cleanly ours-fixable in-tree.
- **Acceptance sweep PASS** (`nq-captures/20260713-102339/`): all v1.8.1
  regressions-to-watch clean — DPLL_ABE 98.304 MHz, sDMA GCR `0x00011010`, WiFi
  `.184`, BT 0 frame-reassembly, dmesg err/warn EMPTY, 0 failed units; thermal
  peak 97.2 °C under bounded load (inside the known ~94–99 °C watch band, no
  throttle).
- **v1.8.2 artifacts** (`output/nexusq-v1.8.2.sha256`; flashed to the device):
  `nexusq-boot-v1.8.2.img` sha256
  `1c589a70ffc10e4ac0ea7197a420e5168d43da64d0e902160dcf90a0ee977d0c`
  (5,545,984 B, ramdisk-less), `nexusq-rootfs-v1.8.2-sparse.img` sha256
  `6538e0ba225f63585551604f0323ad4d3bdfa8d67347e27e15acbeebdddb8a02`.
- **Durable lessons:** `timeout N sh -c "yes & yes & wait"` **ORPHANS** the
  `yes` children when timeout kills the wrapper — timeout each load process
  individually; healthd's `dmesg_err` matcher counts info-level brcmfmac
  `clm_blob` lines (cosmetic refinement candidate); the uid-10000 user manager
  (`systemd --user`) is now the #2 idle consumer at 1.28 % (minor watch item).
- **Remaining idle backlog:** HDMI desktop idle policy (DPMS never blanks at the
  DRM level — DISPC stays awake; Todoist p3), deep cpuidle C2+ (p4, blocked on
  serial), `user@10000` manager watch.

## [1.8.1] — 2026-07-12 — crackle CLOSED (kernel r42, hardware-verified)

> **The playback crackle ("lupance") investigation is CLOSED — it was TWO independent
> faults stacked, both fixed and hardware-verified 2026-07-12:** (a) load-correlated
> bus/DMA contention → kernel **r41** (patch `0041`, commit `fc7e280`); (b) a
> metronomic ~1/s load-independent click from **two free-running crystals** → kernel
> **r42** (patch `0042`, commit `9f76754`). Final state: user-confirmed **perfectly
> clean playback** on kernel `#43-postmarketOS` (*"bez jedinyho zaskobrtnuti"*).
> **v1.8.1 ships kernel r42** (rootfs content otherwise identical to v1.8.0; an
> intermediate r41-only build of the same version passed the gate earlier that day
> but was superseded and overwritten before release — user decision). ⚠️ The first
> full flash exposed a machine-setup gotcha: the Windows machine's gitignored
> `./firmware/` overlay was empty → the rootfs shipped the **empty
> firmware-google-steelhead fallback** (no wlan0, no BT firmware). Overlay populated;
> the **FINAL v1.8.1 image was rebuilt on Ubuntu the same evening** (full docker
> build, all gates PASS incl. `Staged BCM4330 firmware` + a complete
> `/lib/firmware/brcm/`), **flashed, and acceptance-swept 10/10**
> (`nq-captures/20260712-233542/`): both audio fixes live (DPLL_ABE 98.304 MHz
> under sys_clkin; sDMA GCR `0x00011010` + CCR bit6), WiFi + BT restored, dmesg
> err/warn EMPTY, 0 failed units, CPU 1.2 GHz @ 1380 mV. Full
> write-up: `docs/2026-07-12-audio-crackle-closed-sdma-priority-and-dpll-abe.md`.

### Fixed

- **Crackle layer A — load-correlated drops → sDMA HIGH read priority** (kernel
  patch `0041`, `linux` r41, commit `fc7e280`). The fix owed since 2026-07-08/09:
  `drivers/dma/ti/omap-dma.c` defines `CCR_READ_PRIORITY` (`BIT(6)`) but never
  applies it; 0041 sets it on the **cyclic (audio) channel** and reserves a
  high-priority GCR thread (`HI_THREAD_RESERVED=1`) so the McBSP2 FIFO-refill reads
  outrank SDIO/USB at the sDMA/L3 port. **Verified live:** `GCR = 0x00011010`,
  active audio channel ch20 CCR bit6 = 1. After r41 the crackle became
  **load-INDEPENDENT** (ssh/scp no longer affected it) — the behavioral change that
  isolated layer B.
- **Crackle layer B — the metronomic ~1/s click = two free-running crystals →
  DPLL_ABE relocked from sys_clkin** (kernel patch `0042` — DTS `assigned-clocks`
  on `&mcbsp2` — `linux` r42, commit `9f76754`). Mainline `clk-44xx.c` reparents
  `CM_ABE_PLL_REF_CLKSEL` (`abe_dpll_refclk_mux_ck`) to **sys_32k** for deep-idle
  PM (states steelhead never enters — C1-only, patch 0024), while the TAS5713 MCLK
  (auxclk1 12.288 MHz) derives from DPLL_PER on the **38.4 MHz** system crystal —
  so the McBSP2 frame clock and the amp MCLK drifted at the crystals' relative ppm
  (~21 ppm ≈ **1 sample slip/s at 48 kHz**). Stock **x-loader AND bootloader** force
  the mux to SYS_CLK and lock DPLL_ABE at exactly **98.304 MHz** (M=64/N=24) and the
  stock kernel never touches it — **our port was actively undoing the bootloader's
  correct setting** (audit evidence: xloader `prcm_init` tail offsets
  `0x5c7c–0x5ca0` — `bic #1` on `CM_ABE_PLL_REF_CLKSEL` `0x4a30610c`; bootloader
  `0x1e0c–0x1e30`; `steelhead_init` `clk_set_parent` chain at `0xc0016770`+ in
  `reverse-eng/vmlinux.bin`). Fix: reparent `abe_dpll_refclk_mux_ck` →
  `sys_clkin_ck` + relock `dpll_abe_ck` at 98304000 — single reference crystal for
  the whole audio path, stock topology. **Verified on device** (kernel
  `#43-postmarketOS`): `clk_summary` shows the reparent + 98.304 MHz lock; playback
  clean, user-confirmed.
- **Fast kernel build hardened** (`scripts/build-kernel-boot.sh`, commit `554175b`):
  the apk is now picked by **exact `pkgver-pkgrel`** from the staged APKBUILD (the
  newest-glob selection grabbed a **stale** kernel apk from the work-volume repo);
  no more `ls | head` (SIGPIPE → rc 141 under `pipefail`); and the kernel is found
  by **globbing `vmlinuz*`** (newer `postmarketos-installkernel` names it
  `boot/vmlinuz-<kernelrelease>`).

### Documented

- **⚠️ REPO GOTCHA — editing `kernel/dts/omap4-steelhead.dts` alone is a silent
  no-op:** the DTS enters the kernel tree **via `kernel/patches/`** (0003 +
  follow-ups) — that is what the build scripts stage. The first r42 build shipped
  the OLD DTB until the DTB verification caught it; the change had to become patch
  `0042`. Any DTS change must land as a patch and the built DTB must be verified.
- **Windows build-host gotchas (durable):** MSYS/Git-Bash mangles the docker `-v`
  path (`/src` → `C:/Program Files/Git/src`) — launch the build via PowerShell;
  CRLF breaks sed-parsed APKBUILD vars and the dos2unix whitelist —
  `core.autocrlf=false` set machine-locally + worktree renormalized to LF.
- **v1.8.1 FINAL artifacts** (kernel r42; Ubuntu rebuild with the populated
  firmware overlay, verification-gate-passed + flashed + acceptance-passed
  2026-07-12 evening; `output/nexusq-v1.8.1.sha256`):
  `nexusq-boot-v1.8.1.img` sha256
  `6d55b3485e9b1704ec398348ed8e30e8fb50b4628f69a8337f1d60d6bfd42157` (5,543,936 B,
  ramdisk-less; DTB in the packed image verified to carry the 0042
  assigned-clocks), `nexusq-rootfs-v1.8.1-sparse.img` sha256
  `ec3d47a0…c748d` (all-RAW, 23 chunks; round-trip == raw `d4f1bba5…3d6f2e`).
  The earlier Windows-build hashes (boot `51748379…`, sparse `ab6bc0dc…`) are
  **SUPERSEDED** — same r42 source, but that rootfs lacked WiFi/BT firmware; the
  byte differences are rebuild artifacts.
- **WiFi DHCP lease can move (durable):** the router reassigned the device's
  wlan0 lease `.195` → `192.168.20.184` on 2026-07-12 even with the pinned
  factory MAC `f8:8f:ca:20:48:e1` — never hardcode the WiFi IP; re-discover by
  hostname `steelhead` / factory MAC.

## [1.8.0] — 2026-07-09 (tagged 2026-07-10; BT fix verified live via boot.img)

> **v1.8.0 — Bluetooth A2DP now works reliably (root cause found + fixed) + the
> playback crackle ISOLATED to the output path + the burned v1.7.4 bake reverted to a
> safe subset.** Working successor to the unusable **v1.7.4** (see the note below —
> left intact). Package delta: `linux` r39 → **r40** (patch `0040`),
> `device-google-steelhead` r37 → **r38** (r38 was the burned v1.7.4 pkgrel; it is
> reused for this clean release since v1.7.4 was never committed/tagged). The **BT
> fix is verified LIVE** after a boot.img flash; the **full rootfs image is BUILT and
> pending on-device verification** (a full build runs in parallel). Full write-up:
> `docs/2026-07-09-bluetooth-uart-max-speed-and-crackle-isolation.md`.

### Fixed — v1.8.0

- **Bluetooth A2DP now stays connected and plays cleanly — ROOT CAUSE was a missing
  BT HCI UART `max-speed`** (kernel patch `0040`, `linux` r40). The BCM4330 BT HCI
  runs over **UART2**; our DTS BT node had **no `max-speed`**, so `hci_bcm` left
  `oper_speed = 0` and **never synced the host UART to the baud the BCM4330 firmware
  operates at** → host/controller drift → a stream of `Bluetooth: hci0: Frame
  reassembly failed (-84)` (EILSEQ), HCI command tx timeouts, a **phantom
  "Connected"** state, and A2DP audio in **corrupt bursts** (~1 s sound then seconds
  of silence) until the phone dropped the link (HCI reason `0x13`). Fix: set
  `max-speed = <3000000>` (stock ran the BT UART at **3 Mbaud**; RTS/CTS already muxed
  in `uart2_pins`). **Verified on device** (boot.img flash): `Frame reassembly failed`
  count **0** (was 26+), controller address correct unicast **F8:8F:CA:20:49:E5**
  (`local-bd-address` honoured), pairing + A2DP playback stable, user-confirmed
  (*"bluetooth jede, perfektni prace"*). This — **NOT** WiFi/BT coexistence and
  **NOT** HFP/SCO (both earlier wrong guesses) — was the real cause of every past
  "BT won't stay connected / reports wrong state" symptom.

### Added — v1.8.0

- **Bluetooth A2DP sink is now a real, baked audio capability.** Path:
  `phone → BT → PulseAudio bluez_source (s24le / 48 kHz, no resample) → looped to the
  TAS5713 sink`. Joins the PA-centric audio model as another input alongside
  librespot.

### Changed — v1.8.0

- **Audio crackle ("lupance") ISOLATED to the common OUTPUT path** (diagnostic
  result, no code change beyond the mitigation below). Bringing up A2DP gave a second,
  independent **input** path: A2DP (`phone → BT → PA → TAS5713`) shows the **SAME**
  periodic drops as librespot (`WiFi → librespot → PA → TAS5713`). Therefore the
  crackle is **NOT** in the app, **NOT** in librespot, **NOT** in WiFi/network — it is
  in the shared **PulseAudio → TAS5713 → sDMA → McBSP2** output path, directly
  confirming the 2026-07-08 bus/DMA-contention hypothesis. **Outstanding fix (NOT done
  yet):** the OMAP4 sDMA `HIGH_PRIORITY` patch (`CCR_READ_PRIORITY` on the McBSP2
  cyclic DMA channel). _(Done 2026-07-12 as kernel r41 patch 0041 — plus a second,
  independent clock-drift layer fixed by r42 patch 0042; see [Unreleased] above.)_
- **The burned v1.7.4 crackle-bake is REVERTED to a safe subset** in the device
  package (`device-google-steelhead` r38). REMOVED: the McBSP2 THRESHOLD op-mode
  service (`nexusq-mcbsp-threshold.service` — garbled audio), the 600 ms PA buffer
  (`60-nexusq-latency.conf` — user-rejected), and the RT scheduling configs
  (`10-nexusq-rtprio.conf` + `CPUSchedulingPolicy` on the user units — crashed
  pulseaudio/librespot with `214/SETSCHEDULER`). KEPT as the working crackle
  mitigation: **`tsched=0`** baked into `/etc/pulse/default.pa` via the apk **trigger**
  (the device package now also triggers on `/etc/pulse`; patches `module-udev-detect`
  → `module-udev-detect tsched=0`), the **TAS5713 Speaker-unity pin**, and the
  **+24 dB volume ceiling** (both from v1.7.2/v1.7.3).

## [Unreleased] — investigations (not shipped, not baked, not committed)

### Diagnosed — audio crackle ("lupance") = memory-bus / DMA contention (2026-07-08)

> **No code change shipped.** The tuning below is **config-persistent on the running
> rootfs** (it survives a reboot) but a **reflash wipes it** — none of it is in the
> device package, and the root-cause fix is **not yet implemented**. Recorded so it
> isn't re-derived. Full write-up: `docs/2026-07-08-audio-crackle-dma-contention.md`.

- **Root cause found.** The Spotify-playback crackle (`librespot → PA → TAS5713`) is
  **memory-bus / DMA contention on the L3/EMIF interconnect**: the audio SDMA that
  refills the **McBSP2 FIFO underflows in hardware** when other bus masters (WiFi
  SDIO, the USB-ethernet LAN9500A, memory-heavy tasks) contend for the interconnect.
  Proven by elimination — **0** PulseAudio XRUN, **0** dmesg underruns, low CPU,
  clean librespot logs (not a PA-buffer/CPU/network problem); stopping the LED tap
  **and** NFC didn't fix it; it worsens with **any** concurrent activity — even ssh
  over **ethernet** (which is USB on this device), so it is **not WiFi-specific** —
  and a CPU + memory-bandwidth stress test made it "definitely worse". It sits
  **below** the PA buffer (DMA→FIFO refill is hardware-timed) and **below** thread
  scheduling (the SDMA is a DMA engine + hardirq, and WiFi RX is a softirq/NAPI that
  runs above all userspace SCHED_FIFO). `cpu_dma_latency=0` did not help → bus
  arbitration, not idle-retention latency.
- **Live-only mitigations (config-persistent, NOT baked into the image, NOT
  committed) → "dramatically better, occasional glitch remaining":** `tsched=0` in
  `/etc/pulse/default.pa` (biggest win — stops PA timer-scheduling periodic clicks);
  a ~400 ms PA buffer (`60-nexusq-latency.conf`); PA priority (`nice -11` + a
  `user@10000.service.d/10-nexusq-rtprio.conf` `LimitRTPRIO=95` drop-in so rtkit can
  grant RT). A manual `chrt -f -p 55` on the PA IO thread further helped but is
  **runtime-only (lost on reboot)**.
- **Not yet done (next):** a **kernel audio-DMA-priority fix** (OMAP4 sDMA
  `HIGH_PRIORITY`/`DMA4_CCR` on the McBSP2 channel, L3 NoC / EMIF QoS, omap-mcbsp
  FIFO threshold + the mainline omap-mcbsp PM-QoS patch); and **baking** the live
  tuning into the device package **plus a permanent RT-thread-promotion mechanism**.

### Regressed — the v1.7.4 bake attempt is an UNUSABLE artifact (NOT shipped) (2026-07-08)

> **v1.7.4 (device `r38`) baked the crackle tuning but REGRESSED — the built image is
> unusable, DO NOT flash it.** Two of the baked items are broken. The repo service
> files were corrected afterwards, but the **v1.7.4 artifact still carries the bad
> config.** Nothing shipped/tagged. Full write-up: "Update 2" in
> `docs/2026-07-08-audio-crackle-dma-contention.md`.

- **THRESHOLD op-mode is HARMFUL — reverted to `element`.** Baking McBSP2
  `dma_op_mode=threshold` (via `nexusq-mcbsp-threshold.service`) made playback
  "completely broken / interrupts exactly like originally" with **0 PA XRUN / 0 dmesg
  XRUN** → audio **corruption/garble, not underrun** (matches the stock-parity
  auditor's channel-shift warning: mainline stereo runs ELEMENT `pkt_size=2`;
  THRESHOLD raises maxburst/threshold and can shift channels). The earlier "threshold
  helped" reading was **confounded** by RT + WiFi-PM applied at the same time.
  **Threshold must not be used on this hardware.** Action still owed: remove/disable
  `nexusq-mcbsp-threshold.service` from the device package.
- **RT via systemd `CPUSchedulingPolicy=rr` on the USER services CRASH-LOOPS audio.**
  `pulseaudio.service` + `librespot.service` fail with
  `214/SETSCHEDULER: … Operation not permitted` → neither starts → **NO AUDIO**. Even
  with `LimitRTPRIO=95` on the user manager and per-service, a user service can't
  `sched_setscheduler(SCHED_RR)` (system `DefaultLimitRTPRIO=0`; user-session RT needs
  `CAP_SYS_NICE`). The `CPUSchedulingPolicy` lines were **removed from the repo
  service files** — but the v1.7.4 image still has them. A permanent RT mechanism must
  be a **root promoter** (a system service that `chrt`s the PA `alsa-sink` + librespot
  threads), not user-service `CPUSchedulingPolicy`.
- **Keepers (live-confirmed):** `tsched=0` (biggest), **WiFi runtime-PM off**, a
  **~400 ms** PA buffer (600 ms adds LED-visualizer lag), and the **RT `chrt`**
  (FIFO ~55 audio / ~45 librespot) → "dramatically better, occasional glitch".
- **New clues:** the first 1–2 s of the first stream after a cold boot is broken then
  "catches" — classic **librespot ramp-up** (0.8 has no native PA backend), so
  librespot may be a separate contributor. **Next diagnostic: Bluetooth A2DP sink** to
  localize source-vs-output (BT bypasses librespot + WiFi; pairing not yet completing).

## [Unreleased] — v1.7.3 (BUILDING, not yet flashed)

> **v1.7.3 — completes the volume fix + adds bidirectional (dial→app) volume sync.**
> Framed for **v1.7.3** (versioning is tag-only). **BUILT, NOT yet flashed as an
> image, NOT tagged** — but the fix itself is **verified LIVE on device** (the r35
> path pin applied on the running v1.7.2 device; measured + user-confirmed). Package
> delta: `device-google-steelhead` **r34 → r35**, `nexusq-control` **r7 → r8**. Full
> analysis (§4 Resolution): `docs/2026-07-08-audio-volume-scale-and-bootlog-cleanup.md`.

### Fixed — v1.7.3

- **Volume fix COMPLETED — PA now drives only the TAS5713 Master, not Master+Speaker
  stacked** (`device-google-steelhead` r35 post-install). Kernel patch `0038`
  (v1.7.2) shifted the Master dB scale but the amp was still deafening: on-device
  measurement showed PA drives **BOTH** the Master (numid 1) **and** the per-channel
  Speaker (numid 2), because `analog-output-speaker.conf` marks both as
  `volume = merge`. PA **stacks** them — Master (0..+24 dB) then Speaker (another
  0..+24 dB) = **+48 dB at PA 100 %** (the shifted Master TLV made PA recruit Speaker
  *sooner*, so 0038 alone was insufficient). Fix: the post-install `sed`s
  `[Element Speaker] volume = merge → volume = zero` (pins Speaker at unity, 0 dB;
  in-place, idempotent, same pattern as the bluez/avahi path patches). **Measured
  live (v1.7.2 + this pin):** PA 20 % = −17.5 dB · 50 % = +6 dB (comfortable,
  mid-dial) · 100 % = +24 dB (was +48); Speaker pinned 0 dB throughout; Base Volume
  100 %; spreads cleanly 0-100 %. **User confirmed by ear: "this is good."** Closes
  the audio-gain-cap polish item (no separate lower ceiling needed).

### Added — v1.7.3

- **Bidirectional volume sync — the physical dome dial and LXQt applet now update the
  companion app slider** (`nexusq-control` r8, bridge `pa_watch_thread`). A
  `pactl subscribe` loop detects sink volume/mute changes made **outside** the bridge
  (dome dial via `nq-vol` → `pactl set-sink-volume`, and the panel applet) and
  broadcasts `volumeChanged` to app clients so the slider tracks the knob. Re-reads
  the active sink on each `on sink #` event but broadcasts **only on an actual
  level/mute change** — the sink run-state transitions from the v1.7.1 LED-tap
  gating don't spam clients. Verified live.

## [1.7.2] — 2026-07-08 (kernel flashed/on device; volume completed by v1.7.3)

> **v1.7.2 — TAS5713 volume-scale rework (no PA software boost) + boot-log cleanup.**
> Kernel (`linux` r37 → **r39**, patches **0038** + **0039**) **flashed and on
> device**; the volume-scale shift is measured correct but was **insufficient by
> itself** — completed by the v1.7.3 Speaker-pin (see [Unreleased] above). Full
> analysis: `docs/2026-07-08-audio-volume-scale-and-bootlog-cleanup.md`.

### Changed — v1.7.2

- **TAS5713 Master volume maps to PA 0-100 % with no software boost** (kernel patch
  `0038`, `linux` r38). The TAS5713 gets its **own** ALSA controls instead of
  sharing mainline `tas5711_controls`. The mainline `tas5711_volume_tlv` tops out at
  **+24 dB**, so PA's 100 % sat above the hardware max: Master saturated at **~PA
  45 %**, PA added **software gain** above (dead zone + quality loss), and the
  desktop icon read "45 %" at the real ceiling. Fix: shift **only** the Master dB
  scale (`tas5713_volume_tlv = -12750`) so the hardware max register maps to PA
  0 dB / 100 % (spreads 0-100 %, no software boost, icon reads full, hardware/dB
  throughout). ⚠️ **Insufficient alone** — on-device measurement found PA *also*
  drives the per-channel Speaker control (`analog-output-speaker.conf` merges both),
  stacking a second +24 dB (+48 dB at 100 %); **completed in v1.7.3** by pinning
  Speaker at unity. See [Unreleased] v1.7.3 and §4 of the note.

### Fixed — v1.7.2

- **Boot log no longer floods with NFC SHDLC frame dumps** (kernel patch `0039`,
  `linux` r39). `SHDLC_DUMP_SKB()` used `print_hex_dump(KERN_DEBUG)`, which writes
  to the ring buffer regardless of loglevel; the continuous pn544 poll for NFC
  tap-to-send emitted **~200 "shdlc: .." lines/boot**. Switched to
  `print_hex_dump_debug()` (no-op without `CONFIG_DYNAMIC_DEBUG`, which this image
  lacks).
- **Kernel cmdline trimmed of debug-forcing flags** (`kernel/configs/steelhead_defconfig`
  `CONFIG_CMDLINE`, `scripts/repack-bootimg.sh`, `build-noramdisk.sh`): removed
  `earlyprintk` + `ignore_loglevel`, `loglevel=7` → `loglevel=4`. `ignore_loglevel`
  was forcing ALL debug prints (gpiolib "can't parse scl-gpios" + the shdlc dumps)
  onto the HDMI console. The diag boot scripts (`build-diag-boot2.sh`,
  `manual-export.sh`) were intentionally LEFT verbose.

## [1.7.1] — 2026-07-08

> **v1.7.1 — idle-CPU/thermal fix: the LED audio tap is gated on playback.**
> SHIPPED and **verified live on device**. Package delta: `nexusqd` **r7 → r8**
> (commit `af7fa0e`). Notes:
> `docs/2026-07-08-audio-volume-scale-and-bootlog-cleanup.md`.

### Fixed — v1.7.1

- **Idle CPU ~7 % → ~1 %: gate the LED music-visualizer tap on PA activity**
  (`userspace/nexusqd`, `pmos/nexusqd` r8). The tap (`arecord -D pulse` on
  `tas5713.monitor`) was an uncorked PA source-output, so suspend-on-idle could
  never suspend the sink — at silence the `tas5713` sink stayed **IDLE (clocked)**
  and PA + arecord burned ~7 % (the top idle-heat contributor). nexusqd now polls
  `pactl list short sink-inputs` and only runs arecord while a real playback stream
  exists; when idle it stops arecord so the sink **suspends**. Gate signal is
  sink-input **count, not audio level** (a quiet passage keeps the tap on); pactl is
  polled only around a transition, never while music flows. `audio_open()` returns
  the arecord pid, `audio_close()` SIGTERMs it. New dep `pulseaudio-utils`.
  **Verified on device (v1.7.1):** idle → arecord=0, sink SUSPENDED, nexusqd 0 %;
  playback → arecord=1, sink RUNNING; after playback → arecord=0 (re-gated), sink
  IDLE→SUSPENDED. Satisfies the AI-handover "idle temperature / performance" task.

## [1.7.0] — 2026-07-08

> **v1.7.0 — NFC tap-to-send: tap a phone on the dome and the Nexus Q hands it a
> short message over NFC, shown in the companion app.** This is the tagged
> release; it bundles everything built-but-never-tagged since **v1.6.10** (the
> last tag): the new **NFC tap-to-send** headline, the full **PA-centric audio
> system** (v1.6.14–16 — multi-input → PulseAudio → app-selectable output, LED
> AGC, SPDIF 48 kHz, the McBSP2 pinmux that first made the speaker audible), the
> **physical volume dial → PulseAudio + tray icon** (v1.6.16), the companion
> app's **auto-reconnect on resume/drop**, ethernet-as-default + the desktop-audio
> sink fix (v1.6.12). **Package state shipping in v1.7.0:**
> `device-google-steelhead` **r33**, `linux` **r37** (37 patches — new pn544 RATS
> fix 0037), `nexusqd` **r7**, `nexusq-control` **r7**, plus the Flutter companion
> app with native HCE. NFC was VERIFIED end-to-end on device 2026-07-08; full
> record `docs/2026-07-08-nfc-tap-to-send-reverse-hce.md`.

> **v1.6.15 — the PA-centric audio system: multi-input → PulseAudio hub →
> app-selectable output, with a volume-independent LED visualizer.** Framed for
> **v1.6.15** (the release step flips this heading to `[1.6.15]`; versioning is
> tag-only). **BUILT 2026-07-07 and about to be flashed — the final
> flash-verify (clean-flash acceptance sweep) is still PENDING**; the individual
> capabilities below were each confirmed live on the device during bring-up (see
> the VERIFIED markers). Builds on the v1.6.13 SPDIF/McBSP2 **kernel** (`linux`
> pkgrel **36**, the DTS/defconfig audio work below, already flashed as a test
> build) + v1.6.14. Package delta shipping in v1.6.15: `device-google-steelhead`
> **r31**, `nexusq-control` **r6**, `nexusqd` **r7**, `linux` **r36**. This
> replaces the old direct-ALSA `type multi` fan-out: every audio **input**
> (librespot now; Bluetooth-A2DP / Tidal / casting later) is a PulseAudio client,
> the active **output** (TAS5713 speaker / optical SPDIF / HDMI) is the PA default
> sink chosen from the companion app, and the LED music-visualizer taps the active
> output's PA monitor with an auto-gain stage so it reacts to the music regardless
> of listening volume. Full record:
> `docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md`.

> **v1.6.12 — ethernet is the default deploy path; WiFi characterized; desktop
> audio sink fixed.** Framed for **v1.6.12** (the release step flips this heading
> to `[1.6.12]`; versioning is tag-only). **Note on the version bump:** the
> ethernet-default work below was built + flashed as **v1.6.11** for live testing
> on 2026-07-07 but was **never git-tagged/released**; the next public release is
> **v1.6.12** and folds in BOTH the ethernet-default change (device
> `device-google-steelhead` **r29**) AND the desktop-audio fix (**r30**) — so the
> shipped delta over v1.6.10 is **r28→r30**. No kernel change and no boot
> behaviour change. Three things this session, all measured live on the v1.6.10/
> v1.6.11 device 2026-07-07: (1) the direct-cable **ethernet path is now the
> default** deploy/control transport — fastest, most stable, and the only one
> with a fixed IP; (2) the old **"WiFi is flaky" framing is retired** — 5 GHz is
> healthy and the ~34 Mbit/s bulk cap is a hardware ceiling of the 2010-era
> BCM4330, not a bug; (3) the LXQt/labwc **Wayland desktop had a red-cross
> (no-sink) audio tray icon** — root-caused and fixed (PA never started + wrong
> default sink). Notes:
> `docs/2026-07-07-wifi-characterization-and-ethernet-default.md`,
> `docs/2026-07-07-desktop-audio-pulseaudio-fix.md`.

### Added — v1.7.0: NFC tap-to-send (reverse-HCE, Q → phone)

> The v1.7.0 headline. **VERIFIED end-to-end on device 2026-07-08.** Package
> delta: kernel `linux` **r37** (new patch **0037**), `device-google-steelhead`
> **r33**, companion app (native Kotlin HCE + Dart listener). Full investigation
> and design: `docs/2026-07-08-nfc-tap-to-send-reverse-hce.md`.

- **Tap the dome with your phone → the Nexus Q pushes a short UTF-8 text to it
  over NFC**, surfaced as a Holo-dark SnackBar in the companion app. Sends **once
  per tap** (re-arms when the phone leaves the field). The payload is a static
  greeting for now (`NQ_NFC_MESSAGE`, default `Ahoj z Nexus Q!`).
- **Why it had to be reverse-HCE (the hard part).** The 2011 **PN544 canNOT be a
  passive tag / host-card-emulate** — its card-emulation RF path routes only to a
  hardware Secure Element over SWP, which this device does not have (host CE only
  arrived with the next chip gen PN547 + Android 4.4); and Google removed **Android
  Beam** (NFC P2P push) in Android 14. So "tap a bare phone and it reads the Q like
  a sticker" is impossible on this hardware, and passive stickers were rejected.
  The working path inverts the roles: the **phone runs a HostApduService (HCE**,
  fully supported on modern Android), the **Q is the ISO-DEP reader**, and data
  flows Q→phone as APDUs. Requires the companion app installed + foreground.
- **The key kernel fix — pn544 RATS-activate all ISO-DEP targets (patch 0037,
  `linux` r37).** The mainline pn544 driver only sent RATS (ISO 14443-4 layer-4
  activation, via `CONTINUE_ACTIVATION`) for Mifare DESFire (`sens_res == 0x4403`)
  per its own TODO; an Android HCE phone (**ATQA 0x0004 / SAK 0x20**) never matched,
  so the reader transceived against a still-layer-3 target and the chip returned
  `ANY_E_NOK` — the phone entered card emulation but `processCommandApdu` was never
  called. Fix: RATS-activate **any** ISO-DEP target (`target->sel_res & 0x20`),
  keeping the DESFire ATQA match as belt-and-suspenders. This was THE missing piece
  (the chip already does reader-side ISO-DEP — DESFire works through the same path).
- **Device side (`device-google-steelhead` r33):** `/usr/bin/nexusq-nfc-send` — a
  Python reverse-HCE reader daemon (raw `PF_NFC` generic-netlink poll on `nfc0` +
  an ISO-DEP `NFC_SOCKPROTO_RAW` socket; custom **AID `F0010203040506`**; SELECT +
  payload APDU `80 10 00 00 <Lc> <utf8>`) run by `nexusq-nfc.service`
  (`NQ_NFC_LOOP=1`, `NQ_NFC_MESSAGE`, enabled in `nexusq.preset`). **neard is NOT
  installed** — the daemon owns the kernel NFC device directly. The reader is a
  working **Python prototype** (a C rewrite is possible future polish).
- **Companion app (Flutter) side:** native Kotlin `NqHceService` (HostApduService,
  AID `F0010203040506`, category `other`, **`android:shouldDefaultToObserveMode="false"`
  — CRUCIAL on Android 15**, which otherwise defaults HCE to observe-mode and won't
  answer APDUs); `HceBridge` (persists the last message with **`.commit()` — NOT
  `apply()`**, which lost the message when the service was killed before the async
  flush — and delivers it to Flutter); `MainActivity` Event/MethodChannel +
  `setPreferredService` on resume (unambiguous routing, no app-chooser); Dart
  `HceListener` showing the SnackBar. **VERIFIED trail:** `NqHceService: received
  text` → `HceBridge: post: persisted (sink=true)` → `flutter: [HCE] show
  (messenger=true)` → the user saw the SnackBar.
- **Usage gotchas (durable):** tap **and hold steady ~5–10 s** — RATS NOKs if the
  phone moves mid-activation; the companion app must be **foreground** (preferred
  HCE routing) with the **screen on**. Reader dev/test note: `systemctl stop neard`
  was needed only when neard was live-installed — the shipped image has no neard.

### Deferred / future — NFC (honest, not in v1.7.0)
- **Payload is a static greeting** (`NQ_NFC_MESSAGE`). The useful next step is
  sending the device's **connection info** (IP / mDNS) so the app could
  auto-connect — the original "tap to onboard" intent — but that needs app-side
  parsing plus mDNS re-discovery (also still owed to the app reconnect path).
- **Q-side reader is a Python prototype** — a C daemon would be cleaner for the
  shipped image.
- **Continuous NFC polling keeps the RF field active** (minor power/thermal on
  this thin-headroom OMAP4); revisit if it matters.

### Added — v1.6.16: physical volume dial → PulseAudio + tray icon

- **The Nexus Q's capacitive volume dial now drives PulseAudio** (was ALSA
  softvol) and the LXQt/labwc tray volume icon follows the active output
  selection. Device pkg **r32**, kernel + labwc glue. Built + flashed 2026-07-07.

### Changed — companion app: auto-reconnect on resume/drop

- **The app now recovers a dropped/backgrounded connection with no app kill.**
  It previously connected once and never recovered — when Android backgrounded it
  and tore down (or half-opened) the TCP socket, returning left a dead connection.
  New: idempotent socket teardown + per-socket done/error guards (a stale socket's
  late close can't kill a fresh connection), a foreground-only backoff reconnect
  supervisor (1→2→4→8→15 s cap) with full re-hydration (subscribe→getState→
  listOutputs) on every reconnect, a resume-time active `getState` probe (a
  half-open post-doze socket looks alive until written to), a 25 s heartbeat, and a
  Holo-dark reconnecting/disconnected banner. **Verified on-device:** background→
  resume re-attaches with no app kill.

### Added — v1.6.15: the PA-centric audio system (multi-input → PulseAudio → selectable output)

> Built 2026-07-07; each capability confirmed live during bring-up (VERIFIED
> markers). **Final clean-flash acceptance sweep still PENDING.** Replaces the old
> direct-ALSA `type multi` fan-out. Package delta: `device-google-steelhead`
> **r31**, `nexusq-control` **r6**, `nexusqd` **r7** (kernel `linux` **r36** from
> the v1.6.13 audio bring-up below).

- **librespot → PulseAudio** (was: direct ALSA `type multi` fan-out to the
  speaker + a snd-aloop tap). librespot is now a systemd **USER** unit in the
  uid-10000 session (`librespot.service` moved to `/usr/lib/systemd/user/`,
  enabled via a `default.target.wants/` symlink like `pulseaudio.service`) so it
  shares that session's PulseAudio. New wrapper `/usr/bin/librespot-nexusq`:
  `--backend alsa --device pulse` (librespot 0.8.0 has no native PA backend →
  route via the ALSA `pulse` plugin), `--zeroconf-interface <wlan0 IP>` (0.8.0
  ships only the libmdns zeroconf backend, which otherwise advertised the usb0
  gadget IP — unreachable from a WiFi phone; the wrapper resolves the live wlan0
  IPv4 at start), `--ap-port 443` (VLAN20 blocks Spotify's default AP port 4070),
  `--disable-credential-cache`. avahi additionally pinned to wlan0
  (`allow-interfaces=wlan0`, patched into `avahi-daemon.conf` by the post-install).
  **VERIFIED end-to-end:** Spotify Connect discoverable + connectable + plays into
  PA (a sink-input on the default sink).
- **App-selectable output** (TAS5713 "Reproduktor" / SPDIF "Optický výstup" / HDMI):
  `nexusq-control` gained `listOutputs` / `setOutput` (+ an `outputChanged` event).
  `setOutput` = `pactl set-default-sink` **plus** move every existing sink-input
  onto it (input-agnostic — a playing stream follows) + a class-D amp Speaker
  on/off safety toggle (amp powered only when `speaker` is active) + points PA's
  default **source** at the active sink's `.monitor` (so the LED tap follows the
  output). Volume/mute reworked `amixer`→`pactl` on the active sink. The bridge
  runs as root and reaches the user-session PA via `PULSE_SERVER`/`PULSE_COOKIE`.
  The Flutter companion app gained an OUTPUT selector (Holo-dark segmented
  control). **VERIFIED end-to-end:** app switch → device default sink changes +
  amp Speaker toggles.
- **SPDIF pinned to 48 kHz** (`/etc/pulse/daemon.conf.d/50-nexusq-48k.conf`): PA
  runs every sink at 48000 and resamples 44.1 kHz sources (Spotify). The McASP DIT
  + McBSP2 clock only the 48 kHz family cleanly — at 44.1 kHz the McASP logs
  "Sample-rate is off by 88435 PPM" (the 48000/44100 ratio) → detuned optical out.
  **VERIFIED:** both PA sinks report 48000 Hz on a fresh boot.
- **LED music-visualizer re-tapped + auto-gain (AGC).** The visualizer tap moved
  off the (now-removed) snd-aloop loopback to a **PA monitor source** (nexusqd
  `arecord -D pulse` on the active sink's monitor — follows output selection).
  Added an **AGC** (nexusqd r7, `audiocap.c`): the monitor is post-volume, so raw
  level scales with listening volume; the AGC normalizes it to a stable target
  (`AGC_TARGET 0.15`, fast attack / slow release, noise-gate for silence) so the
  LED reacts to the music at any volume. **VERIFIED live:** steady
  `audio DETECTED vol=0.150` (== AGC_TARGET), no flicker (the pre-AGC symptom was
  the visualizer flickering ↔ breathing at low volume).
- **Architecture is input-agnostic + future-proof:** output selection + the LED
  monitor tap work for ANY PA input. Bluetooth-A2DP (bluez + pulseaudio-bluez, both
  present) / Tidal (unofficial Linux daemon) / casting (AirPlay via shairport-sync)
  can join later as further PA input clients with no further routing work.

### Added — v1.6.13 kernel: SPDIF bring-up + the McBSP2 pinmux fix (shipped as `linux` r36)

> The kernel foundation for the audio system above — DTS + defconfig only, no C
> driver work. Built + flashed as the v1.6.13 test build; the `rc2` SPDIF-probe
> fix is folded in and the DTB is verified.

- **MAJOR: the banana-terminal speaker (TAS5713) was SILENT the whole project —
  root-caused to a wrong McBSP2 pinmux, now fixed → the speaker actually plays**
  (user-confirmed audible, 2026-07-07). `mcbsp2_pins` was muxing pads
  `0x110/0x114/0x116`, which are the **`abe_dmic_*`** balls, NOT McBSP2 — so the
  real McBSP2 I2S balls sat in `safe_mode` and the amp got no clock/data/frame
  (`aplay` returned `rc=0` but nothing was driven). Fixed to the stock McBSP2
  pads **`0x0f6` clkx / `0x0fa` dx / `0x0fc` fsx** at `MUX_MODE0` (confirmed vs
  `reverse-eng/stock-omap-mux-full.txt` + a live pinctrl read). **This
  recontextualizes every prior "TAS5713 audio works" claim as
  software-pipeline-only** — the driver/PCM/softvol chain was correct but nothing
  ever reached the physical amp until now. Files: `kernel/dts/omap4-steelhead.dts`
  (`mcbsp2_pins`), regenerated `kernel/patches/0003-ARM-dts-omap4-add-steelhead.patch`.

- **SPDIF (optical TOSLINK) output brought up** (no C driver work — mainline
  `davinci-mcasp` already supports `ti,omap4-mcasp-audio` + DIT/IEC958).
  defconfig: **`CONFIG_SND_SOC_DAVINCI_MCASP=m` + `CONFIG_SND_SOC_SPDIF=m`**.
  DTS: `&mcasp0` enabled (`status=okay`; node lives in `omap4-l4-abe.dtsi`), new
  `mcasp_spdif_pins` = `OMAP4_IOPAD(0x0f8, PIN_OUTPUT|MUX_MODE2)`
  (`abe_mcbsp2_dr` → `abe_mcasp_axr`, serializer AXR0 out — mirrors stock
  `board-steelhead.c`), new `sound_spdif` simple-audio-card (`mcasp0` DIT ↔
  `spdif_dit` codec, card name `NexusQ-SPDIF`).
  - **SPDIF probe fix (folded in as `rc2`).** The initial v1.6.13 test build
    failed to probe: `davinci_mcasp 40128000.mcasp: ASoC: error at
    snd_soc_dai_set_fmt -22` — the simple-audio-card passed a DAI fmt with the
    FORMAT field = 0 → `davinci_mcasp_set_dai_fmt()` hit `default:`/`-EINVAL`.
    Fixed by giving `sound_spdif` **`simple-audio-card,format = "i2s"`** +
    `bitclock-master`/`frame-master = <&spdif_cpu>` (the `mcasp0` CPU DAI). Kernel
    `pkgrel` kept at **36** across the fix so module vermagic still matches the
    rootfs. DTB verified.

- **HDMI audio** (recorded earlier, unchanged): the HDMI card is the real
  `omap-hdmi-audio` (not a stub); PCM open returns `-EINVAL` only because the
  attached display is a **Philips 190C DVI monitor** (128-byte EDID, no CEA
  extension, no audio). Very likely works on an audio-capable HDMI sink (TV/AVR)
  with no code change — **UNTESTED**. It joins the output list as `hdmi` once its
  `PULSE_IGNORE` udev rule is lifted against a real audio sink.

### Known issues / deferred polish (NOT in v1.6.15 — need care/hardware)
- **Volume gain-cap.** The TAS5713 amp is very hot (app ~8% ≈ deafening) — the
  bridge sends a plain linear pactl % for now; a usable-range gain cap on the
  Master/Speaker control needs calibration with the user at a safe volume /
  reconnected speaker.
- **Boot default output.** Should default to the speaker; PA picked spdif/sink0 on
  boot in testing — ensure the speaker sink is the boot default and not muted.
- **Speaker CRACKLE.** A McBSP2/TAS5713 dropout was heard when the speaker path
  first became audible (the mcbsp2 pinmux fix un-silenced it). The old `type multi`
  async-tap back-pressure theory is now moot (the tap moved to a PA monitor source,
  which can't back-pressure the sink) — re-diagnose from measurement with the
  speaker safe-disconnected, and check whether the 48 kHz pin already reduced it.

### Fixed
- **Fast kernel-only build path no longer hangs at "Entering fakeroot…"**
  (`scripts/build-kernel-boot.sh`, new Phase 6b2). Under `--no-cross` the kernel
  `package()` runs in the armv7 chroot where abuild's `faked` busy-loops forever
  under qemu — the same trap already fixed for the full `docker-build.sh`. The fix
  patches pmbootstrap `backend.py` to run **abuild as root** (`-F`,
  `HOME=/home/pmos`) so `FAKEROOT=""` skips fakeroot and produces correct
  root:root files. (Needed to build the pn544 RATS kernel `r37` on the fast path.)
- **Desktop audio: red-cross "no sound sink" on the LXQt/labwc Wayland desktop
  fixed** (diagnosed + fixed live 2026-07-07, device pkg **r29→r30**; verified
  across a reboot). Two layers:
  - **PulseAudio never started.** Alpine's pulseaudio ships no systemd user
    unit — it relies on the XDG autostart `/etc/xdg/autostart/pulseaudio.desktop`
    (`Exec=start-pulseaudio-x11`, `X-GNOME-HiddenUnderSystemd=true`), which never
    fires in this systemd + LXQt/labwc **Wayland** session (systemd's
    `xdg-desktop-autostart.target` stays dead, the .desktop is hidden-under-systemd
    deferring to a native unit that did not exist, and `autospawn=no` per
    `50-nexusq-no-autospawn.conf`). → no PA daemon → `/run/user/10000/pulse/native`
    missing → every PA client (LXQt volume applet, `pactl`) got "Connection
    refused" → red cross. **Not** a PipeWire-owns-the-session problem (PipeWire was
    already correctly suppressed). **Fix:** ship a native **`pulseaudio.service`
    systemd USER unit** (`pulseaudio --daemonize=no --log-target=stderr`,
    `ConditionUser=!root`, `Restart=on-failure`), enabled for every session via a
    `/usr/lib/systemd/user/default.target.wants/` symlink. NOT socket-activated (a
    `pulseaudio.socket` double-binds the native socket PA's own `default.pa`
    creates → "bind(): Address in use"); `--log-target=journal` is rejected by this
    Alpine PA build, `stderr` is captured into the journal by systemd; `autospawn=no`
    stays.
  - **Wrong default sink.** Once running, PA auto-loaded `module-alsa-card` for the
    snd-aloop **Loopback** card and (being card index 0 on some boots) made
    `alsa_output.platform-snd_aloop.0.analog-stereo` the DEFAULT sink — desktop
    audio would go into the internal loopback plumbing instead of the speaker, and
    PA holding the Loopback risks EBUSY against the librespot→speaker / companion-tap
    chain. **Fix:** extend `91-pulseaudio-hdmi-ignore.rules` to also PULSE_IGNORE
    the Loopback via `KERNELS=="snd_aloop.0"` (platform-name match — ALSA card index
    is probe-order-unstable, observed Loopback=card0 with HDMI/tas5713 shuffling).
    PA's ONLY sink is now the **TAS5713 speaker** → correct deterministic default;
    the Loopback stays pure ALSA plumbing for librespot (`nexusq_soft`) + the
    companion tap. Verified live post-reboot: PA `is-active`, sole sink
    `alsa_output.platform-sound-tas5713.stereo-fallback`, and it is the default.
  - Files: `pmos/device-google-steelhead/pulseaudio.service` (new),
    `91-pulseaudio-hdmi-ignore.rules` (2nd rule), `APKBUILD`
    (source/sha512sums/package + pkgrel **29→30**).

### Changed
- **Ethernet (direct PC↔Nexus cable, `10.42.0.2`) is now the DEFAULT
  deploy/control path**, replacing the USB gadget. Measured 2026-07-07:
  **~80 Mbit/s, 0.62 ms, 0 % loss** — beats WiFi (~34 Mbit/s) and the USB gadget
  (~64 Mbit/s crypto), and unlike the gadget (whose `enx*` iface renames every
  reboot with no host IP) it has a fixed name/IP.
  - `eth-direct.nmconnection` is now **`autoconnect=true`** (was `false`) at
    `autoconnect-priority=5`, `autoconnect-retries=1`; `eth-lan.nmconnection`
    priority **5→10** and `dhcp-timeout` **30→10 s**. On a real LAN `eth-lan`'s
    DHCP wins (higher priority); on the serverless direct cable `eth-lan` fails
    its single DHCP attempt (~10 s) and NM falls through to the static
    `eth-direct` → **10.42.0.2 comes up on its own, no manual
    `nmcli c up eth-direct`**. Device pkg **r28→r29**.
  - `scripts/diag/nqctl`: ethernet is the first-tried path (eth → usb → wifi);
    added `NQ_ETH_HOST` + an ssh-agent-independent `SSH_OPTS`
    (`IdentityAgent=none` + `-i $NQ_SSH_KEY`) so it works when the host ssh-agent
    is unavailable.
  - Connect agent/skill briefs updated: `eth-direct` is the #1 transport, USB
    gadget demoted to fallback.

### Documented
- **WiFi (BCM4330) characterized — 5 GHz is healthy, NOT flaky; bulk ~34 Mbit/s
  is a HARDWARE CEILING** (measured 2026-07-07, not fixable in software).
  - 5 GHz `Svatovitske-Internety-5g`: −48 dBm, link 62/70, **0** discarded/retry/
    frag packets, jitter **2.6 ms avg / 6 ms max, 0 % loss**.
  - The ~34 Mbit/s bulk cap is intrinsic to the 2010-era **1×1 802.11n** combo
    chip on SDIO (last firmware Jan-2013, 5.90.195.114): 2 parallel streams
    *aggregate* to ~29 Mbit/s (less — contention, so not per-flow); the same
    cipher does ~80 Mbit/s over ethernet (so crypto/CPU ≈ 80, WiFi is the limit);
    `powersave=2` gave no change; SDIO `mmc4` already at 50 MHz/4-bit/SD-high-speed
    (raw ~200 Mbit/s headroom). It is ~100× the appliance's real need.
  - 2.4 GHz retested: also **stable (0 % loss), not flaky**, but strictly worse —
    main AP is 802.11g-only (54 Mbit) → ~14 Mbit/s; the chip *does* do 2.4 GHz 11n
    (joined the `_EXT` mesh node at 130 Mbit negotiated) but still only
    ~13–16 Mbit/s (backhaul + congested ch6). Idle BT-coexist impact was minor.
  - **The old "flaky BCM4330 / deploy over the USB gadget" guidance is
    superseded:** use 5 GHz for WiFi, ethernet for bulk.
- **Process lesson: run the FULL `nexusq-diag` sweep after every flash + boot.**
  The desktop-audio red-cross regression (above) was caught only because the user
  noticed the tray icon — the post-flash check was too narrow. Post-flash
  acceptance must sweep the whole subsystem surface (incl. desktop audio: PA
  running + a real default sink), not just the boot log / units.

## [1.6.10] - 2026-07-07

> **v1.6.10 — the genuinely clean boot log.** Framed for **v1.6.10** (PUBLIC
> build + release in progress, handled separately — **no git tag from here**;
> the release step flips this heading to `[1.6.10]`). Picks up where v1.6.9 left
> off (the gkr-pam + HDMI-audio noise): **every one of the ~15 err/warn lines
> still on the v1.6.9 boot was root-caused and fixed with a REAL fix** — plus two
> authorized exceptional downgrades and two genuinely-external lines documented
> honest. **Final state, verified by a clean-flash acceptance on device pkg
> `r28` / kernel pkgrel `35` (uname `#36`): `dmesg -l err,warn` is EMPTY, and
> `journalctl -b -p warning` contains ONLY the 3 genuinely-external residuals**
> below. Device pkg **r28**, kernel `linux-google-steelhead` pkgrel **35** (uname
> **`#36`**), firmware pkg `firmware-google-steelhead` **r1**. boot.img grew
> **~0.3 MB** (the BPF core) → still well under the 8 MB boot partition.
> **Thermal watch-item** unchanged: sustained dual-core load peaks **~94–99 °C**
> (below the 100 °C passive trip, no throttle) — thin headroom on the fanless
> sphere.

### Fixed
- **Boot log is now genuinely clean (device pkg r22→r28, kernel patches
  0033–0036, defconfig + DTS).** Each remaining err/warn line individually
  root-caused (grouped by subsystem):
  - **kernel/DTS**
    - `armv7-pmu … no interrupt-affinity property, guessing.` — DTS `&pmu`
      `interrupt-affinity = <&cpu0 &cpu1>`.
    - `gpmc_mem_init: disabling cs 0 mapped at 0x0-0x1000000` — DTS `&gpmc`
      `status = "disabled"` (there is no GPMC device on steelhead).
    - `brcmfmac … brcmfmac4330-sdio.clm_blob failed with error -2` /
      `no clm_blob available` — kernel **patch 0033**: the driver requests the
      OPTIONAL CLM/txcap blobs with `firmware_request_nowarn` (the BCM4330 CLM is
      in-firmware; there is no separate blob to load).
    - `hw-breakpoint: Failed to enable monitor mode on CPU 0.` — kernel
      **patch 0034** drops the `HAVE_HW_BREAKPOINT` arch select. The OMAP4460 is a
      fused HS part with secure debug locked, so `enable_monitor_mode()` can never
      set `DSCR.MDBGEN`; perf/ptrace HW watchpoints cannot function on this silicon
      regardless, and stock 3.0.8 did not build the feature. **No functional loss.**
    - Bluetooth `BD_ADDR` (the real correctness bug found while investigating the
      cosmetic bluetoothd MGMT line): the controller shipped the non-unique,
      group-bit-set Broadcom placeholder `43:30:A0:00:00:00`. Fixed by DTS
      `local-bd-address = [e5 49 20 ca 8f f8]` (stock `f8:8f:ca:20:49:e5`, DT LE
      order) **plus** kernel **patch 0036** — btbcm now recognizes the `43:30:A0`
      BCM4330 placeholder so the DT address is actually programmed (the DT alone
      didn't take: btbcm only knew the `43:30:B1` signature). Verified live:
      controller stays `F8:8F:CA:20:49:E5`.
  - **defconfig**
    - journald `Failed to set ACL … Not supported` — `CONFIG_EXT4_FS_POSIX_ACL=y`
      (also makes per-user `journalctl` work).
    - `unit configures an IP firewall, but the local system does not support
      BPF/cgroup firewalling` **+** the `unprivileged_bpf_disabled` sysctl warn —
      **BPF ENABLED** (`CONFIG_BPF_SYSCALL=y` + `BPF_JIT=y` + `CGROUP_BPF=y`).
      **The whack-a-mole insight:** that notice is emitted once for the FIRST unit
      with `IPAddressDeny`, so fixing units one-by-one just moved the line to the
      next unit — enabling BPF kills it for ALL units at once, makes systemd
      IP-address hardening (`IPAddressDeny=any`) actually functional, and exposes
      the `kernel.unprivileged_bpf_disabled` knob. (The interim per-unit
      journald/udevd no-ipfirewall drop-ins were consequently **removed** — with
      BPF present the default `IPAddressDeny=any` is real hardening.)
    - `TCP: request_sock_TCP: Possible SYN flooding` / `tcp_syncookies` sysctl
      warn — `CONFIG_SYN_COOKIES=y`.
  - **firmware pkg**
    - `brcmfmac … brcmfmac4330-sdio.google,steelhead.bin failed with error -2` —
      `firmware-google-steelhead` (r1) ships board-named symlinks so the
      device-specific probe hits instead of falling through to the generic name.
  - **device pkg (userspace, r22→r28)**
    - PulseAudio `pid.c: Daemon already running.` — ship
      `/etc/pulse/client.conf.d` disabling client autospawn (PA is started once by
      the XDG autostart).
    - `50-dns-filter.sh` NM dispatcher exit 1 on `lo` — NM `conf.d` marks the
      loopback unmanaged so the dispatcher never runs for `lo` (the upstream
      postmarketos-base script lacks an `lo` guard — worth an upstream bug).
    - bluetooth `ConfigurationDirectory` 755-vs-555 — drop-in
      `ConfigurationDirectoryMode=0755`.
    - librespot boot restart / mixer race — `librespot.service` `ExecStartPre` is
      now a readiness gate (waits for both ALSA cards + the `NexusQ` softvol
      control) with **no** timeout wrapper (busybox `timeout` leaked an orphaned
      process).
    - `bluetoothd: Failed to set default system config for hci0` — device
      post-install populates bluez's `/etc/bluetooth/main.conf` `[LE]` section with
      sane defaults (MinConnectionInterval etc.) so the MGMT system-config TLV is
      non-empty and the call succeeds. (bluez was logging a failure though it never
      sent anything on an empty main.conf — corrects the v1.6.9
      "documented-benign" framing of this line.)

### Changed
- **L2C `platform modifies aux control register` notice → `pr_debug`** (kernel
  **patch 0035**, ×2 lines). **AUTHORIZED exceptional downgrade** (Petr approved
  masking genuinely-unfixable lines): Linux legitimately enables L2 prefetch via
  the secure SMC over a ROM value that leaves it off — the readback delta IS the
  prefetch bits; the immutable stock bootloader + no DT/upstream reconciliation
  path make it otherwise unremovable without a perf regression. Exhaustively
  verified 2026-07-06: the register end-state is identical to stock.
- **`systemd-nsresourced` disabled** (a low-priority preset
  `20-nexusq-nsresourced-off.preset` `disable` + device post-install removes the
  enable symlinks). `nsresourced` logged `bpf-lsm not supported, can't lock down
  user namespace` every boot; BPF-LSM isn't built and the appliance uses no
  unprivileged-userns delegation. (systemd's `configure` had enabled the socket
  before our preset existed, and the build's preset pass didn't re-evaluate it —
  hence the post-install symlink removal alongside the preset.)

### Known issues — the 3 genuinely-external residuals (not cleanly fixable)
- **eth-lan DHCP fail on a DHCP-less direct PC cable** — environmental; making
  `eth-lan` `autoconnect=false` would break real-LAN plug-and-play.
- **kscreen `.service` D-Bus naming** — upstream libkscreen packaging lint (hard
  dep via lxqt-config).
- **avahi `No NSS support for mDNS`** — `nss-mdns` is not packaged in the
  pmOS/Alpine repos (`apk: no such package`); avahi's publish path (librespot
  Spotify-Connect zeroconf) works fine.
- Plus the standing **~94–99 °C** sustained-load thermal watch-item (not a fault).

## [1.6.9] - 2026-07-06

> Boot-log cleanup: the two residual once-per-boot / per-ssh log-noise items
> are gone (gkr-pam keyring, PulseAudio HDMI card) — the boot log is now clean.
> Device pkg r23; kernel unchanged `#33-postmarketOS` (boot.img byte-identical
> to v1.6.8). Cosmetic only, no functional change.

> Framed for **v1.6.9** (PUBLIC build + release in progress, handled
> separately — no git tag from here). All cosmetic boot-log cleanup, **no
> functional change**; device pkg **r23**, kernel **unchanged** `6.12.12-r32`
> (uname `#33`). Acceptance **ACCEPT on r23** (clean fastboot flash): **0 failed
> units**, gkr=0, HDMI-audio noise=0, ethernet cold-init works (100Mbps/Full),
> WiFi/NFC/CPU healthy, no new regression; the residual err/warn are all the
> known-benign set. Watch-item: under sustained dual-core load the SoC peaked
> **~98–99 °C** (below the 100 °C passive trip, no throttle) — the known thin
> thermal headroom.

### Fixed
- **Boot-log cleanup (cosmetic, device pkg r23; no functional change).** Two
  once-per-boot / per-ssh log-noise items on an otherwise-clean boot, both
  root-caused and fixed (not masked):
  - **`gkr-pam: couldn't unlock the login keyring`** on every key-based ssh
    session — `/etc/pam.d/base-auth`+`base-session` now shadow the Alpine base
    to drop the desktop-keyring PAM lines (gnome-keyring is a hard dep of
    nm-applet/gvfs/webkit so it stays installed; nothing here uses the user
    keyring; `pam_systemd`/`pam_rundir` → `XDG_RUNTIME_DIR` preserved, and every
    base-session line is `-session optional` so a stale copy can never block
    login). Verified: **0 gkr lines across fresh logins, sessions register**
    (`loginctl`).
  - **PulseAudio `module-alsa-card: Failed to find a working profile`** on the
    omap-hdmi-audio card every boot — a `PULSE_IGNORE` udev rule tells PA to
    skip it (the card is a snd-soc-dummy-DAI with no usable IEC958 sink; HDMI
    carries desktop video only, device audio is TAS5713 + snd-aloop).
    - **r22 → r23 correction:** the first attempt (r22) pinned
      `KERNEL=="card1"` and was **rejected in acceptance** — the ALSA card index
      is **probe-order dependent** (HDMI enumerated as `card2` that boot), so the
      rule tagged the wrong card and PA still errored. r23 matches the backing
      **platform device** instead: `SUBSYSTEM=="sound", KERNEL=="card*",
      KERNELS=="omap-hdmi-audio.1.auto"` — index-independent. Verified on r23:
      `PULSE_IGNORE=1` lands only on the HDMI card, **0 module-alsa-card errors**.
    - **Lesson:** ALSA card indices are probe-order dependent — a per-card udev
      rule (`PULSE_IGNORE` and friends) MUST match by backing device (`KERNELS=`)
      or card id, **never** by `cardN` index.
- `bluetoothd: Failed to set default system config for hci0` is left as
  **documented-benign**: bluez sends `MGMT_OP_SET_DEF_SYSTEM_CONFIG` regardless
  of `main.conf` and the BCM4330B1 rejects the batch, but the controller
  initialises and works (`Powered: yes`) — no clean suppression exists.

## [1.6.8] - 2026-07-06

> Ethernet works from a cold boot at last: the LAN9500A cold-init bug (task
> #17) is fixed and gold-validated (clean fastboot flash + true cold
> power-cycle → eth0 100Mbps/Full, 0 failed units). Kernel `#33-postmarketOS`
> (r32), device pkg r21.

> Framed for **v1.6.8** (PUBLIC build + release in progress). Kernel
> `linux-google-steelhead` pkgrel **32** (uname **`#33`**); no device-pkg change.

### Fixed
- **ETHERNET COLD-INIT FIXED — task #17 FULLY CLOSED (2026-07-06).** The
  LAN9500A now enumerates from a **true cold boot** after a clean flash. Root
  cause (same class as the NFC pinmux bug): `gpio_1` NENABLE — the LAN9500A
  power-enable — is pad **`kpd_col2` at CORE padconf offset `0x186`**, but the
  DTS `ethernet_gpios` node muxed only `gpio_62` NRESET (`0x08c`); `0x186` was
  omitted (a prior comment wrongly placed `gpio_1` in the wkup padconf). So
  gpiolib drove the `gpio_1` DATAOUT latch (debugfs read "asserted") while the
  pad stayed in **safe_mode** and NENABLE never reached the chip → the LAN9500A
  was never powered, never drove D+, and the port sat at **PORTSC CCS=0** on
  every cold boot. The healthy USB3320 PHY (its pads ARE muxed) masked it. Stock
  muxes both pads (`omap_mux_init_gpio` 1 & 62 @ VA `0xc00178d0`/`dc`, value
  `0x0e03`). **Fix:** DTS `ethernet_gpios` += `OMAP4_IOPAD(0x186, PIN_OUTPUT |
  MUX_MODE3)` (patch 0003; kernel pkgrel **32**, uname **`#33`**). Proven three
  ways: (a) a live mmio write of the pad register `0x4A100184` → `eth0` attach at
  100Mbps from the cold-failed state; (b) bidirectional causality (pad set →
  attach, pad cleared → detach); (c) **GOLD STANDARD** — a clean fastboot flash
  of `#33` + a **true cold power-cycle** → `eth0` enumerates **100Mbps/Full,
  0 failed units** (clean-flash warm boot #1 also enumerated). Commit
  **e33a1b4**. Together with the r21 NM eth profiles (v1.6.7, the
  serverless-DHCP-loop fix), ethernet is now fully working from cold: enumerate +
  link + no DHCP retry loop. `docs/2026-07-06-eth-coldinit-resolved.md`.
  - **Correction — the 2500ms "attach-ready settle" (kernel `#31`, commit
    6c869e8, "closes #17") was a FALSE POSITIVE, not a fix.** Those "5/5" boots
    all descended from a stock RAM boot via warm reboots that never cut LAN9500A
    power, so the stock-initialized chip just stayed attached; a clean flash /
    true cold boot without stock still failed. e33a1b4 **reverts** the patch 0006
    power block to stock timing (`udelay(100)`/`udelay(2)`, dropping the disproven
    200ms/50ms/2500ms delays) and removes the non-stock `gpio_159` (`0x164`) pad
    mux + `steelhead-eth-phy-reset-gpios` property (stock leaves that pad in
    safe_mode; not wired to the LAN9500A).
  - **Lesson (for future gpio bring-up):** debugfs / `gpiolib` reporting a line
    "asserted" only means the **DATAOUT latch** is driven — NOT that the pad is
    routed to the pin. Always verify the **IOPAD mux** against a live stock
    `omap_mux` dump (`reverse-eng/stock-omap-mux-full.txt`); a healthy sibling
    (here the USB3320 PHY) can mask a completely unmuxed control line. Probe live
    with the aligned `/root/mmio` helper + ULPI viewport reads — **never** python
    mmap (it wedges INSNREG05).
- **eth0 hw MAC is random per boot** — the LAN9500A has no MAC EEPROM, so on a
  real LAN the DHCP lease/IP changes every boot (match by hostname, not eth MAC).

## [1.6.7] - 2026-07-05

> Device pkg **r21** (kernel unchanged: `6.12.12-r28`, `#29-postmarketOS`).
> Flashed + accepted 2026-07-05: zero failed units across 3 boots (the baked
> eth profiles handle both a present and an ABSENT ethernet chip gracefully —
> `NetworkManager-wait-online` green either way), `led_static` guard verified
> live (33× info, zero false CRIT in 91 samples), NFC clean probe, WiFi factory
> MAC/.195, CPU/power nominal.

### Known issues
- **LAN9500A enumeration intermittency is BACK (task #17 REOPENED, narrowed):**
  on the acceptance boots the chip did not enumerate at all (USB CCS=0, 0/3
  boots; the 2026-07-03/04 boots enumerated 3/3 with the byte-identical
  kernel). The NM retry-loop half of #17 IS fixed (this release); the
  remaining half is the kernel/ehci bring-up race — the direct-cable
  `eth-direct` workflow was verified end-to-end on 2026-07-04 on an
  enumerated boot and is unaffected when the chip appears.
  _(RESOLVED 2026-07-06 in [Unreleased]/v1.6.8 — the enumeration half was the
  unmuxed `gpio_1` NENABLE pad; task #17 FULLY CLOSED, gold-validated from a
  true cold boot.)_

### Fixed
- **ETHERNET NM-LAYER RESOLVED (2026-07-04; task #17 narrowed, see Known
  issues).** The `#29` "partial
  comeback / carrier flap" was fully explained and fixed. The LAN9500A/driver
  is **fully healthy** (revived by batch 2b): with NM detached, carrier held
  90+ s with **zero transitions**, 100Mbps/Full, 0 rx/tx errors, under
  `ondemand` (rules out the cpufreq-timing theory for the current image). The
  "flap" was **NetworkManager's auto-generated "Wired connection 1" DHCP retry
  loop** on a wire with no DHCP server (the direct PC↔Nexus cable): 45 s DHCP
  timeout → deactivate resets the cloned "stable" MAC → the MAC write bounces
  the LAN9500A carrier → the carrier event resets NM's autoconnect-retries
  counter → reactivate — self-arming, ~47 s period, 14 811 journal lines in
  29 h; it also failed `NetworkManager-wait-online` (the one failed unit in the
  `#29` acceptance). Fix (`device-google-steelhead` **r21**, also hot-deployed
  to the running device): `eth-no-auto-default.conf` (`no-auto-default=eth0`) +
  baked `eth-lan.nmconnection` (DHCP, `dhcp-timeout=30`,
  `autoconnect-retries=1`, **`cloned-mac-address=permanent`** — no MAC churn →
  no carrier bounce → the retry counter sticks) + `eth-direct.nmconnection`
  (static 10.42.0.2/24 + 10.0.0.2/24, never-default, manual activation). Host
  side: persistent NM profile `eth-direct-host` on petronijus-PC `enp7s0`
  (10.42.0.1/24 + 10.0.0.1/24) — the direct-cable workflow needs zero ad-hoc
  setup on either end. Verified live 2026-07-04: eth0 settles at
  "disconnected" quietly (0 re-activations), carrier stable, **`nm-online -s`
  rc=0**, `nmcli c up eth-direct` → ping 3/3 (0.77 ms avg) → **`ssh
  root@10.42.0.2` works**. Caveat: eth0's hw MAC is **random per boot** (no
  MAC EEPROM) — on a real LAN the DHCP lease/IP changes per boot; pin a fixed
  cloned MAC in eth-lan if stable LAN identity is ever wanted.
  `docs/2026-07-04-ethernet-resolved-and-led-guard.md`.
- **`led_frozen` static-by-design guard (2026-07-04)** — the other open item
  from the `#29` acceptance. `nq-healthd` (r21, hot-deployed + restarted) now
  emits crit `led_frozen` **only when the frozen frame co-fires with distress**
  (`nq_resp=0` or `nq_progress=0`); a static frame with a healthy daemon emits
  **info `led_static`** (the screensaver locks a static frame by design).
  `scripts/diag/nq-health-report` mirrors the logic and splits the summary into
  `led_frozen_events` / `led_static_events`. Regression-tested on the
  `nq-captures/20260703-144228/` capture: verdict **CRIT → OK** with
  `led_static … 25 occasion(s)`.

> Deployment note: device pkg **r21** is baked in this image; the 2026-07-04
> hot-deploy is superseded — the device runs the flashed v1.6.7 image since
> 2026-07-05 (no regression window). No kernel change in this batch.

## [1.6.6] - 2026-07-04

> The whole 2026-07-02 boot-error fix batch below was **flashed 2026-07-03 and
> the acceptance run PASSED** — uname `#27-postmarketOS`, zero failed units,
> **9/10 targeted dmesg error classes gone** (only the `twl: not initialized`
> line survived, mutated into the new B22 burst). Kernel
> `linux-google-steelhead` pkgrel **26** (patches 0023–0028),
> `device-google-steelhead` pkgrel **19**. Inventory + per-item verification:
> `docs/2026-07-02-boot-error-inventory.md` ("FLASH-VERIFIED 2026-07-03");
> stock-parity evidence: `docs/2026-07-02-stock-parity-voltage-wifi-idle.md`.
>
> **Batch 2 shipped as batch "2b" — FLASHED AND ACCEPTED 2026-07-03**: during
> the flash cycle the scheduled **stock RAM-boot NFC discrimination test** found
> the real NFC bug (**wrong pinmux pads** — see the headline Fixed entry), so
> patch 0003 was regenerated once more and the kernel went out at pkgrel **28**
> (uname **`#29-postmarketOS`**, patches 0029–0031 + the NFC pinmux fix; all 31
> patches apply GNU-patch-clean) with `device-google-steelhead` pkgrel **20**.
> Acceptance on `#29` PASSED: **NFC detects cleanly**, B22/B23 lines gone
> (`twl: not initialized` count = 0), all batch-1 wins holding, the **factory
> WiFi MAC `f8:8f:ca:20:48:e1` on air** — final IP **`192.168.20.195`** — ring
> fingerprint via the readable `frame` attr, CPU/power nominal (ondemand,
> 1200 MHz @ 1 380 mV exact). One new finding: **ethernet partial comeback**
> (see Known issues). Capture `nq-captures/20260703-144228/`; full story:
> `docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md`. This image
> **is v1.6.6** (kernel `#29-postmarketOS`, r28 + device r20).

### Fixed
- **NFC (PN544) IS FIXED AND WORKING — the DTS muxed the WRONG PADS (B15,
  closed for real 2026-07-03).** `nfc_pins` used IOPAD `0x1b4`/`0x1b6`/`0x1b8`
  — the **dpm_emu3/4/5 debug pads** — while the real PN544 pads for
  gpio162/163/164 are **`usbb2_ulpitll_dat1/2/3` at `0x16a`/`0x16c`/`0x16e`**:
  the GPIO controller drove the right lines but the pads were never muxed to
  GPIO, so VEN/FW/IRQ never reached the chip and it looked electrically dead
  from every mainline probe (both prior verdicts — "dead hardware" 2026-07-02
  and "software parity complete, suspect board-level" — retracted). Found by
  the **stock RAM-boot discrimination test** (`fastboot boot
  output/stock-adb-boot.img` + musl i2c-tools over adb: chip ACKs at 0x28 with
  VEN high, exact 6-byte core-reset frame accepted rc=0, silent with VEN low)
  and the live **`omap_mux` debugfs dump from the working stock kernel**
  (`0x16a`/`0x16c` = `0x0003` OUTPUT|MODE3, `0x16e` = `0x011b`
  INPUT_PULLUP|MODE3; full dump preserved locally at
  `reverse-eng/stock-omap-mux-full.txt`). Fix: `nfc_pins` corrected + the
  `pn544@28` node re-enabled (patch 0003 regenerated, kernel pkgrel **28**).
  Verified on `#29`: `NFC: nfc_en polarity : active high` — **clean, no
  fallback** — and `/sys/class/nfc/nfc0` exists. Tag-read test pending.
  `docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md`.
- **twl6030 `OUT OF RANGE! non mapped vsel for 1375000` ×4 + `twl: not
  initialized` ×4 (B12)** — two stock-parity kernel patches: **0023** stops
  latching a failed early SMPS_OFFSET efuse read as valid (and seeds steelhead
  with the efuse value read live over i2c: `SMPS_OFFSET=0x7f`, `SMPS_MULT=0x52`);
  **0027** replaces mainline's blanket 1 375 000 µV VC ON/ONLP with the stock
  per-domain voltages (MPU 1 375 000 / IVA 1 188 000 / CORE 1 200 000 µV — the
  ×4 was the IVA+CORE VC channels ×(on,onlp)) and retargets the 4460 core VC
  channel VCORE3→VCORE1 (`0x55`/`0x56`; stock unmaps VCORE3).
- **`failed to register cpuidle driver` (B13)** — patch **0024** registers a
  C1-only (WFI) cpuidle driver on steelhead and `cpuidle.off=1` is dropped from
  `CONFIG_CMDLINE`. (Stock has C1–C4; C2+ needs the HS secure dispatcher
  services 0x1c/0x1d/0x21 — a future project.)
- **clkctrl `device ID is greater than 24` ×3 (B14)** — patch **0025**: ti-sysc
  child named clocks registered via `clkdev_add()` (no 24-char device-ID limit).
- **hsusb1-phy `dummy supplies not allowed for exclusive requests (id=vbus)`
  (B20)** — patch **0026**: usb_phy_generic gets its optional vbus supply with
  `devm_regulator_get_optional()`.
- **bcm4330-pwrseq ~25 s deferred probe (B17)** — `CONFIG_CLK_TWL=m`→`y` (the
  module deferred the pwrseq's 32k clock provider; WiFi only came up ~31 s) +
  the **CLK32KG naming-trap fix**: WiFi pwrseq + BT clocks `<&twl 1>`→`<&twl 0>`
  (stock enables TWL6030 **CLK32KG** 0x8C under the misleading consumer name
  "clk32kaudio" — our old CLK32KAUDIO value gated the wrong pin, so the BCM4330
  LPO never ran) + `clk-settle-delay-ms = <300>` (patch **0028**, new optional
  `mmc-pwrseq-simple` property) matching stock's clk→300 ms→WLAN_EN→200 ms.
  Parity correctness — 5 GHz WiFi already worked; no throughput claims.
  Verified 2026-07-03: pwrseq probes @4.31 s, mmc pwrseq allocated @6.10 s
  (was ~27 s).
- **`40132000.target-module` permanent deferred probe (B18)** — the
  `omap4-mcpdm.dtsi` include is dropped: McPDM's pdmclk provider is the dead
  TWL6040, and McPDM is unusable without the codec. _(2026-07-03: "dead"
  corrected to "absent" — the TWL6040 is unpopulated/unused on steelhead, see
  under Changed; the fix stands either way.)_
- **tas571x `PVDD_A..D not found, using dummy regulator` ×4 (B19)** — new
  `amp_pvdd` fixed regulator wired to the four PVDD supplies (deliberately no
  voltage props: rail unmeasured, TAS5713 spec 8–26 V, driver only enables).
- **PulseAudio-vs-PipeWire session conflict (U4)** — config-topology fix:
  PulseAudio is the pmOS backend and pipewire is only a library dep, but its XDG
  autostart double-started a second sound server and `pipewire-pulse.socket` had
  no service package behind it. Now: `Hidden=true` autostart overrides in
  `/etc/xdg/nexusq/` (via an `XDG_CONFIG_DIRS` prepend in `nexusq-wayland.sh`)
  + the orphaned user socket masked. (The PA HDMI-audio profile failure is a
  separate open item.) `device-google-steelhead` pkgrel 19 (was written up at
  18; the flashed apk is r19). Verified on device 2026-07-03: only pulseaudio
  in `ps`, no pipewire/wireplumber, no socket error.
- **Wandering WiFi IP** — the device's WiFi IP changed every boot because
  NetworkManager used a randomized locally-administered MAC (fresh DHCP lease
  per boot; this masqueraded as "WiFi dead" on 2026-07-02). New
  `wifi-stable-mac.conf` pins `cloned-mac-address=permanent` + disables scan
  MAC randomization. Verified 2026-07-03: WiFi auto-joins the baked profile,
  **stable IP `192.168.20.175`**. Note the on-air MAC is now the chip's OTP
  `14:7d:c5:3a:35:b5`, not the factory `f8:8f:ca:20:48:e1` (brcmfmac never
  reads the factory-cal MAC) — boot-stable; optionally bake `macaddr=` into
  the nvram to restore the factory identity (open decision).
- **Access regression (root ssh unreachable after a flash)** — `docker-build.sh`
  Phase 6 now stages `private/access/authorized_keys` → `/root/.ssh` +
  `/etc/skel/.ssh` (0600) and `private/access/wifi.nmconnection` →
  `/etc/NetworkManager/system-connections/` (0600, skipped when empty), so a
  clean reflash comes up reachable. The WiFi profile is generated per machine by
  the new `scripts/gen-wifi-profile.sh` (PSK from 1Password at run time; output
  gitignored even in the private overlay). Verified 2026-07-03: key-based
  `ssh root@` works over both the USB gadget (`172.16.42.1`) and WiFi after a
  clean flash. (A reflash regenerates the device ssh host key — `ssh-keygen -R`
  the stale entries.)
- **`twl: not initialized` ×22 burst @0.78 s (B22)** — patch **0030** _(verified
  GONE on `#29` 2026-07-03 — zero occurrences in the whole boot)_: `mfd: twl-core` exports a
  **`twl_is_ready()`** predicate; OMAP4 `omap_twl.c` gates the SMPS_OFFSET
  efuse read attempt AND the patch-0014 retask poll on it, and the retask work
  latches the real efuse the moment twl is up. Full call-site accounting of the
  ×22: per domain (IVA, CORE) 3 nonzero VC voltages ×2 read attempts (the
  `uv_to_vsel` path reads once directly and once via its `vsel_to_uv` range
  check) + the zero off-voltage ×1 + 2 VP limits ×2 = 11, × 2 domains = 22;
  the +2 poll repeats came from the 0014 retask probe.
- **`Skipping twl internal clock init and using bootloader value (unknown osc
  rate)` (B23)** — patch **0031** _(verified GONE on `#29` 2026-07-03)_: twl-core
  `clocks_init()` gated to the **twl4030 class**. The originally planned DTS fix
  (twl `fck = <&sys_clkin_ck>`) was investigated and **REJECTED as actively
  harmful**: on twl6030 the CFG_BOOT/PROTECT_KEY offsets resolve to unrelated
  Phoenix PM registers (absolute `0x24`/`0x2D`, next to PHOENIX_DEV_ON); no
  mainline twl6030 board wires an fck; stock printed the same line.
- **nq-healthd `led_frozen` permanent false CRIT** — patch **0029** _(verified on
  `#29` 2026-07-03: frame attr readable, fingerprint changes while animating,
  `led_sum=4416` sampled — but see the NEW static-by-design guard item under
  Known issues)_ makes the `leds-steelhead-avr` `frame` bin_attr **readable
  (0644)** — the system previously had NO readable ring-state source (nexusqd
  renders exclusively through the write-only `frame`, so the classdev
  `brightness` files stay 0) — and `nq-healthd` (r20) fingerprints the frame
  attr (md5 + byte sum), keeping the brightness loop only as a pre-0029
  fallback.
- **nq-healthd `vdd_mismatch` false warnings** (`device-google-steelhead` r20,
  _verified on `#29` 2026-07-03: no false vdd warnings in the acceptance
  capture_) — freq/vdd were sampled non-atomically, so a DVFS
  transition between the reads fabricated adjacent-OPP mismatches (17/71
  samples in the 2026-07-03 acceptance capture, healthy power path);
  `vdd_mismatch` is now evaluated only when `scaling_cur_freq` holds across the
  vdd read.
- **WiFi factory-MAC identity restored** _(verified on `#29` 2026-07-03:
  `f8:8f:ca:20:48:e1` on air, final IP **`192.168.20.195`** — closes the
  "open decision" from the acceptance run)_ — a live driver-reload test proved
  **brcmfmac/firmware IGNORES the nvram `macaddr=`** (the chip's OTP
  `14:7d:c5:3a:35:b5` always wins), so the fix is at the **NM layer**: the
  baked profile + `scripts/gen-wifi-profile.sh` now pin
  `cloned-mac-address=F8:8F:CA:20:48:E1`. After the flash the device appears
  under the factory MAC — new DHCP lease, the IP changes one final time from
  `192.168.20.175`.

### Changed
- **Default cpufreq governor back to `ondemand`** (+`CONFIG_CPU_FREQ_STAT=y` for
  `time_in_state`) — the v1.5.0 switch to `conservative` was deliberate but its
  rationale was disproven 2026-06-28. Verified on device 2026-07-03: governor
  `ondemand`, `time_in_state` present, 1200 MHz @ 1 380 000 µV under load /
  920 MHz @ 1 317 000 µV idle (exact OPP tracking).
- **NFC (PN544) node disabled in the DTS** — the chip was proven **electrically
  dead** on the reference unit (no i2c ACK at 0x28 with VEN high/low/fw-download,
  core-reset frame NAKed; pins/polarity/timing stock-verified MATCH first). Same
  dead-HW category as the TWL6040. Was "driver binds, chip untested".
  **RETRACTED 2026-07-03** (was "dead hardware", now **under investigation** —
  never conclude dead hardware): the stock-parity regulator audit closed the
  last software suspicion — stock has **NO software power path** for the PN544
  (pdata = 3 gpios only, `pn544_probe` makes zero regulator calls; VBAT/PVDD
  ride hardwired rails) and the full stock `steelhead_twldata` regulator array
  matches our live mainline regulator state bit-for-bit, so software parity is
  COMPLETE and the no-ACK is **unexplained**, not explained-as-dead. Next
  discriminator: NFC test on this unit under the stock RAM boot
  (`output/stock-adb-boot.img`), scheduled for the imminent flash cycle. Node
  stays disabled meanwhile; the DTS comment is rewritten accordingly. Evidence:
  `docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §4/§6.
  **RESOLVED 2026-07-03 — the stock RAM-boot test found it: the chip is
  HEALTHY, our pinmux was wrong** (dpm_emu pads instead of usbb2_ulpitll_dat).
  The node is **re-enabled** and NFC **works** — see the headline entry under
  Fixed.
- **TWL6040 was NEVER a "dead codec" — the chip is unused/unpopulated on
  steelhead** _(flashed + boot-verified on `#29` 2026-07-03)_: the stock 3.0.8 kernel contains
  **ZERO** twl6040/AUDPWRON code (whole-image string+symbol sweep over
  `reverse-eng/vmlinux.bin`), the twldata codec pdata slot is NULL
  (`steelhead_twldata+0x24` @ `0xc0719b30`), and stock's i2c1 board info
  registers only `twl6030@0x48` — the missing ACK at `0x4b` (the 2026-06-10
  "dead chip" verdict) is **stock-correct behaviour**. The twl6040 node, the
  ABE sound card and `twl6040_pins` are **DELETED** from the DTS (explanatory
  comment left in place; the removed node's `ti,audpwron-gpio` gpio_127 had no
  stock evidence either), and the defconfig drops `TWL6040_CORE` /
  `SND_SOC_TWL6040` / `SND_SOC_OMAP_ABE_TWL6040` / `CLK_TWL6040`. DTB compiled
  with zero twl6040 refs (verified in the binary).
- **i2c1–4 scl/sda pads `PIN_INPUT_PULLUP` → `PIN_INPUT`** _(flashed on `#29`
  2026-07-03)_ — stock-exact (mux `0x100`; the board has external pulls).
- `device-google-steelhead` depends + `i2c-tools`, `gptfdisk` (both needed for
  live diagnostics/GPT work).

### Known issues
- **2026-07-02 last-boot error inventory + 2026-07-03 acceptance**
  (`docs/2026-07-02-boot-error-inventory.md`): the dmesg/`journalctl -p err`
  sweep of the v1.6.5-era boot (`6.12.12 #26`) opened **B12–B21 / U4–U7**; the
  fix batch above was flash-verified 2026-07-03 on `#27`
  (B12/B13/B14/B15/B17/B18/B19/B20/U4 + B8 all confirmed gone). Opened by the
  acceptance run and **fixed by batch 2b — flashed + re-accepted on `#29`
  2026-07-03**: **B22** `twl: not initialized` ×22 burst @0.78 s (patch 0030 —
  count 0 on `#29`), **B23** `Skipping twl internal clock init…` (patch
  0031 — NOT the originally planned twl-fck DTS wiring, which proved harmful),
  the two **nq-healthd tooling bugs** (`led_frozen` false CRIT — patch 0029 +
  healthd r20 frame fingerprint; `vdd_mismatch` non-atomic sampling — healthd
  r20), and the **WiFi factory-MAC** identity (NM `cloned-mac-address` pin;
  brcmfmac ignores nvram `macaddr=`; on air on `#29`, final IP
  `192.168.20.195`). Still genuinely open: **U5** bluetoothd
  config error (did not reproduce on `#27`/`#29` — watching), BT BD_ADDR is the
  default-pattern `43:30:A0:00:00:00` (no per-device address); the PulseAudio
  **HDMI-audio UCM profile**, **U6** gkr-pam ssh-session noise, **U7**
  nsresourced bpf-lsm, **B16** ramoops invalid-buffer error (cold boot), **B21**
  minor L2C/gpmc/pmu/journald batch, **B4** (clm/txcap blobs + the
  `brcmfmac4330-sdio.google,steelhead.bin` probe miss), **B10** hw-breakpoint,
  deep cpuidle C2+ (HS secure dispatcher). **B8** (Alternate GPT invalid) is
  **FIXED on-device 2026-07-03** (p13 shrunk 33 sectors + backup GPT relocated,
  atomic `sgdisk`; survived the reboot — no "Alternate GPT" line on `#27`).
  Thermal headroom is thin under sustained dual-core
  load: peak **91.8 °C** vs the 100 °C passive trip (~8 °C) — genuine but
  expected; watch it.
  _(The morning claim "WiFi dead on the live unit" was **wrong** — the IP had
  moved due to the randomized-MAC DHCP lease; corrected same day.)_
- **Ethernet PARTIAL COMEBACK on `#29` (2026-07-03)** — `eth0` shows
  **carrier=1 / operstate up for the first time since the v1.4.0 regression**
  (task #17): `smsc95xx … eth0: Link is Up - 100Mbps/Full` @74.5 s — but the
  link **flaps** (Down within ~1 s, NM disconnect/connect loop) and DHCP never
  completes, making `NetworkManager-wait-online.service` the one failed unit
  of the boot. Likely one of the batch clock changes revived enumeration — a
  strong new lead for task #17. Open follow-ups: root-cause the flap; ship an
  eth0 NM profile with may-fail semantics so wait-online tolerates a
  flapping/cable-less port. _(RESOLVED 2026-07-04 — the flap was NM's
  auto-generated-profile DHCP retry loop, the link itself is healthy; see
  [Unreleased] and `docs/2026-07-04-ethernet-resolved-and-led-guard.md`.)_
- **`led_frozen` still needs a static-by-design guard** — the r20 frame
  fingerprint works, but the screensaver intentionally locks a **static**
  frame after ~300 s idle and the keepalive re-commits identical bytes, so
  `led_frozen` CRIT fires on a healthy idle device (the 2026-07-03 acceptance
  capture's verdict=CRIT was exactly this). Fix direction: only CRIT when
  `nq_resp=0` or `nexusqd_no_progress` co-fires (`nq-healthd` +
  `scripts/diag/nq-health-report`). Until then, expect this false positive on
  idle devices. _(SHIPPED 2026-07-04 exactly as described — healthd r21 +
  nq-health-report emit info `led_static` for a healthy static frame; see
  [Unreleased].)_

## [1.6.5] - 2026-07-01

> The whole batch below ships as a single release **v1.6.5**. An interim **v1.6.4** was
> built + flashed internally to test the LED-ring AVR keepalive but was **never published**;
> it was folded, with the librespot softvol fix + breathing themes + the visualisation
> picker, into v1.6.5. The 1.6.3 → 1.6.5 version-number gap is intentional.

Device-side fixes and companion features on the v1.6.3 image, verified on a **clean flash**:
the **LED ring no longer goes dark after a long idle** (AVR starvation), the **companion
bridge is now reachable over WiFi**, **librespot no longer crash-loops on a fresh boot**
(softvol bootstrap), color themes are now a **breathing** animation, and the **5 music
visualisations are selectable from the app**. `boot.img` is **byte-identical** to
v1.6.2/v1.6.3 (kernel unchanged; md5 `36a3dec2c4a493710dffa18c4d796236`), so an already
up-to-date device only needs the userdata reflash. Final pkgrels: `nexusqd` **r5**,
`nexusq-control` **r4**, `device-google-steelhead` **r17**. The companion APK is rebuilt +
reinstalled separately (not part of the device image). See
`docs/2026-07-01-led-ring-avr-starvation-keepalive.md` and
`docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.

### Fixed
- **librespot crash-loops on a fresh boot — "Could not find Alsa mixer control"
  (`device-google-steelhead` pkgrel 17).** The ALSA `NexusQ` **softvol** control
  (`asound.conf`) does not exist until the `nexusq_soft` PCM is first opened, and it is
  recreated empty every boot, but librespot opens its ALSA mixer control **before** the
  sink → it exits and `Restart=on-failure` respawns it into the same missing-control state
  forever (a reboot never helps). Fix: `librespot.service` gained
  `ExecStartPre=-/bin/sh -c 'timeout 5 aplay -q -D nexusq_soft -f cd -d 1 /dev/zero'`,
  which opens `nexusq_soft` once (1 s of silence) to create the control before librespot's
  mixer opens. Also fixes companion **volume** (the bridge's `amixer NexusQ set` needs the
  same control to exist).
- **LED ring goes dark after long idle — fixed with a 1 Hz AVR keepalive (`nexusqd`
  pkgrel 5; the keepalive itself landed at r3, later rels add `breathe`/`muted` below).**
  The `steelhead-avr` MCU firmware (fw `0x00`) **starves**: it stops lighting
  the ring if the host sends no frame *commit* for too long (a host-frame watchdog). The
  kernel driver `frame_write` (`kernel/drivers/leds-steelhead-avr.c`, sysfs
  `/sys/bus/i2c/devices/1-0020/frame`) sends `SET_RANGE` + `COMMIT` on **every** write, but
  `nexusqd`'s render loop pushed a frame only when it **changed** (a `memcmp(pk, lastpk)`
  gate). Once the idle screensaver locks to a **static** frame (`SS_LOCK_S = 300 s` →
  `ledAlpha` constant `0.1`, breathing stops) and blanks (`SS_BLANK_S = 600 s`), the frame
  stops changing → `memcmp` identical → `nexusqd` stops committing → the AVR starves → ring
  dark until `nexusqd` restarts (~20 h to manifest on the live unit). **Not** hardware
  (a direct sysfs write lights the ring), **not** a commit-mode issue (both
  `AVR_COMMIT_IMMEDIATE=0` and `AVR_COMMIT_INTERPOLATE=1` display fine at 1 write / 4 s),
  **not** a regression. Fix: a keepalive — re-commit the current frame every
  `AVR_KEEPALIVE_S = 1.0 s` even when unchanged. Adds nothing during animation (the frame
  already changes each tick); idle costs ~1 cheap 96-byte-payload i2c frame write/s.
  _(Caveat: mechanically deployed and running, but the "never wedges again" proof needs an
  overnight idle soak — the wedge took ~20 h.)_

### Added
- **Color themes are now a breathing override, not a solid fill** (`nexusqd` pkgrel 5,
  `nexusq-control` pkgrel 4). New `nexusqd` control command **`breathe R G B`**
  (`CTL_BREATHE`) drives the **compositor manual layer (priority 8)** with a new `breathe`
  flag: it pulses the ring in the theme hue using the **same throb envelope as the idle
  screensaver** (`screensaver_throb`, `A = 0.1 + 0.35*(1 - throb)`) but at priority 8 it is
  **always visible** — over the music visualizer and over a blanked/idle screensaver. This
  fixes "pick a color, ring stays dark" (the earlier screensaver-retint approach was
  invisible once the screensaver blanked or while music played, and was **reverted** —
  `screensaver.c/.h` no longer carry `br/bg/bb`/`screensaver_set_color`). A companion color
  theme now maps (in the bridge) to **just** `breathe R G B` (no `auto`). Theme set redefined
  to breathing hues: **blue** (`#0099CC`, the original) / **warm** (`#FF5A0A`) / **cool**
  (`#00C88C`) / **rose** (`#FF285A`) / **smoke** (`#6E7387`) / **off** (blank); the stale
  `spectrum`/`trackinfo` themes were dropped.
- **Five music visualisations selectable from the app** (`nexusq-control` pkgrel 4 +
  companion app). `nexusqd` already had `scene 0..4` (the 5 RenderEngine effects
  waveform / waveformsolid / circles / pointmorph / starfield, shown while audio plays);
  the bridge gained **`setScene` / `listScenes`** (maps a name → `auto` + `scene N`) and a
  `scene` field in `getState`, and the Flutter app gained a separate **VISUALIZATION**
  picker. A color theme (breathing override hue, priority 8) and a visualisation
  (music-reactive effect, priority 7) are now two **independent** controls.
- **App-mute now lights the device mute LED** (`nexusqd` pkgrel 5, `nexusq-control`
  pkgrel 4). New `nexusqd` command **`muted 0|1`** (`CTL_SETMUTED`) sets the mute state and
  calls the same `apply_mute_led()` (dim-teal `#001E28`/`#006B8E` AVR mute LED) the hardware
  mute key drives. The bridge's `setVolume`/`adjustVolume`/`setMuted`/`toggleMute` path now
  also sends `muted 0|1`, so a companion mute has a device-side ring indicator.
- **Companion bridge reachable over WiFi.** New nftables drop-in
  `pmos/device-google-steelhead/55_nexusq-control.nft` opens **TCP 45015 on `wlan*`** so the
  companion app reaches the `nexusq-control` bridge over WiFi (previously only over the
  USB-gadget net; it had been live-patched but not baked). mDNS `_nexusq._tcp` discovery
  reuses the UDP 5353 rule from `60_spotify.nft`. `device-google-steelhead` pkgrel 17.
  Verified live: `getState` returns the "Nexus Q" state over WiFi.

## [1.6.3] - 2026-06-30

A **companion app** and its on-device control bridge — a phone/desktop remote for the
Q (volume, LED theme + brightness, now-playing), replacing the dead 2012 Google
companion app. See `companion/` and `docs/2026-06-30-companion-app-RE.md`.

### Added
- **`nexusq-control` — a LAN control bridge** (new noarch aport `pmos/nexusq-control`).
  A pure-Python3 daemon on TCP **45015**, advertised over mDNS **`_nexusq._tcp`**,
  speaking a v1 JSON protocol (`companion/PROTOCOL.md`). It fans out to: ALSA softvol
  (volume/mute), `nexusqd` over `/run/nexusqd.sock` (LED theme + brightness), and a
  `librespot --onevent` hook (now-playing metadata). Enabled via the device package.
- **Software master volume.** `asound.conf` gains a `nexusq_soft` **softvol** PCM with a
  single ALSA control **`NexusQ`**, layered on top of the v1.6.2 audio tee
  (`nexusq_soft` → `nexusq` tee → TAS5713 speaker **and** the visualizer loopback). One
  knob is shared by librespot (`--mixer alsa --alsa-mixer-control NexusQ`) and the
  companion, so Spotify-Connect volume and companion volume stay in lockstep — and the
  LED visualizer still tracks the (post-volume) output.
- **`nexusqd brightness <0-255>`** control command + a software ring-brightness scalar
  (no firmware change).
- **Companion app** (`companion/app`) — a cross-platform Flutter remote (sphere UI,
  animated LED ring, mDNS auto-discovery; volume + LED theme/brightness + now-playing).
  Built and installed separately on the phone — **not** part of the device image.
- Reverse-engineering of the original Google Nexus Q companion app
  (`com.google.android.setupwarlock`) — its control-RPC vocabulary informed the v1
  protocol (`docs/2026-06-30-companion-app-RE.md`).

### Changed
- `librespot.service` now plays via `--device nexusq_soft --mixer alsa
  --alsa-mixer-control NexusQ --onevent /usr/bin/nexusq-onevent`.
- `device-google-steelhead` pkgrel 15 (`depends nexusq-control`; the bridge is
  enabled durably via a systemd **preset** `95-nexusq.preset` — the aport's
  `/usr/lib` vendor wants and a bare `/etc` symlink were both stripped by the
  image build's `systemctl preset-all` + postmarketOS's `disable *` catch-all).

### Known issues
- **Transport (play/pause/next) is `unavailable` in v1** — librespot is a
  Spotify-Connect receiver with no local transport API; control happens from the
  Spotify app.

## [1.6.2] - 2026-06-30

The **LED music visualizer** now reacts to Spotify playback. v1.6.1 routed
librespot straight to the speaker, so nexusqd's audio tap (the snd-aloop loopback)
got nothing and the ring stayed idle while music played.

### Fixed
- **LED visualizer is fed from playback (audio TEE).** The `nexusq` ALSA PCM is now
  a tee (`multi` + `route`) that duplicates librespot's stereo to BOTH the TAS5713
  speaker AND the snd-aloop loopback (`hw:Loopback,0`), all at 48 kHz. nexusqd's
  existing tap (`arecord` on `hw:Loopback,1` @ 48 kHz, `userspace/nexusqd`) drives
  the FFT/beat visualizer while the speaker plays. The speaker is the timing
  master; the loopback slave is `plughw`, so it adapts to whatever rate the cable
  is at (nexusqd's arecord may have set it) and never blocks playback — verified:
  the tee opens whether the tone-playback or nexusqd's arecord grabs the loopback
  first, and the tone reaches `hw:Loopback,1` at 48 kHz.

### Added
- **snd-aloop auto-loaded.** New `/etc/modules-load.d/snd-aloop.conf` (the kernel
  ships `CONFIG_SND_ALOOP=m`); without it the `Loopback` card doesn't exist and the
  visualizer tap can't open. `device-google-steelhead` pkgrel 12.

### Known issues
- The Spotify Connect session can briefly go "inactive" on the first play and
  reconnect (librespot "context is not available" — a single-track-vs-playlist
  context quirk; no ALSA error); playback is stable afterwards.

## [1.6.1] - 2026-06-29

Working **TAS5713 speaker audio** and **Spotify Connect**, baked into the build. The
v1.6.0 speaker path played exactly 2× too fast (root-caused and fixed here);
`librespot` is now part of the image, so the Spotify "Nexus Q" target survives a
flash. See `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.

### Fixed
- **TAS5713 amplifier played EXACTLY 2× too fast — fixed (kernel patch 0022).**
  Root cause: with `simple-audio-card` driving the McBSP2 → TAS5713 I2S link in
  bit/frame-master mode, the generic card only sets `mclk-fs` and never calls
  `snd_soc_dai_set_clkdiv()`, so `omap-mcbsp` left `CLKGDV = 0` (bit clock = the
  *undivided* 24.576 MHz functional clock) and sized the frame as `in_freq/rate =
  256` BCLK → **FSYNC = 96 kHz for a 48 kHz stream = 2× too fast**. Tracks reached
  their end in half the real time, so librespot auto-skipped ~40 s in. Fix:
  `kernel/patches/0022-ASoC-omap-mcbsp-derive-CLKGDV-from-fclk-simple-card.patch`
  derives `CLKGDV` from the real functional-clock rate (`mcbsp->fclk`) and uses a
  minimal `wlen*channels` I2S frame when the machine driver supplied no explicit
  divider — reproducing the factory kernel's registers exactly (CLKGDV = 15, BCLK
  1.536 MHz, 32-BCLK frame, FSYNC 48 kHz). **Verified on hardware:** 60 s of audio
  to the speaker now plays in **60.00 s (ratio 1.000×)** — was ~30 s (0.50×). Method
  was pure timing (no speaker needed). Cross-checked against `reverse-eng/vmlinux.bin`
  (stock-parity audit). The earlier "B7 TAS5713 MCLK 16 vs 12.288 MHz" concern is a
  red herring for this bug — the mainline `tas571x` codec has no `.set_sysclk`, so
  MCLK never gates FSYNC.

### Added
- **Spotify Connect (librespot) baked into the build.** `device-google-steelhead`
  now `depends` on `librespot` (Alpine edge/testing, 0.8.0, `libmdns` zeroconf
  backend — coexists with `avahi-daemon` on UDP 5353 via `SO_REUSEPORT`) and ships:
  - `/etc/systemd/system/librespot.service` (enabled) — `librespot --name "Nexus Q"
    --device nexusq --bitrate 320 --format S16 --ap-port 443 --zeroconf-port 37879
    --cache /var/cache/librespot`.
  - `/etc/asound.conf` — defines the `nexusq` PCM (`plug` → `hw:CARD=NexusQSpeaker,0`
    forced to **48000 Hz**). The McBSP2/TAS5713 link only clocks the 48 kHz family
    cleanly, so 44.1 kHz Spotify is resampled to 48 k; with patch 0022 that is an
    exact 48 kHz (correct pitch).
  - `/etc/nftables.d/60_spotify.nft` — opens `wlan*` UDP 5353 (mDNS) + TCP 37879
    (zeroconf HTTP) so the phone can discover "Nexus Q".
  Discovery + auth + streaming verified over 5 GHz WiFi; `--ap-port 443` dodges
  VLAN20 blocking librespot's default AP port 4070.

### Changed
- **Audio is addressed by card NAME, not number.** The TAS5713 speaker and HDMI race
  for card 0/1 across boots, so `asound.conf`/librespot use `hw:CARD=NexusQSpeaker,0`
  (via the `nexusq` PCM) — a hardcoded `plughw:1,0` would have played into HDMI after
  an unlucky reboot.
- **TAS5713 25 W speaker amp: now working** (was "software-verified, listening test
  pending"). First fully verified speaker playback.

## [1.6.0] - 2026-06-28

First release with a **working `python3` on the device**, hardware-verified from a
clean flash. Over 1.5.0: a working armv7 python3 — the actual fix was the
`raw2simg.py` byte-exact (all-RAW) flash; the on-device SIGSEGV was a flash bug, not
a build bug (a local `python3` rebuild supersedes Alpine's broken `-r2`, with a
build-integrity gate + ship gate kept as a safety net) — plus zram compressed swap,
user namespaces, on-device `gdb`/`python3-dbg`, and a live re-confirmation of
dual-core SMP + cpufreq-to-1.2 GHz power/thermal.

### Added
- **zram compressed swap.** Kernel `CONFIG_ZRAM=m` plus
  `deviceinfo_zram_swap_algo="lzo-rle"` brings up `postmarketos-zram-swap`. The
  mainline ZRAM module here only carries the lzo/lzo-rle backend, so the service's
  default **zstd** failed (`zramctl: failed to set algorithm: Invalid argument`)
  and swap never came up; lzo-rle is also the CPU-cheap pick for this Cortex-A9.
  Verified live: `/dev/zram0` lzo-rle, 1.4 G, active `[SWAP]`. (linux APKBUILD
  pkgrel 23→24.)
- **User namespaces** — `CONFIG_USER_NS=y`. Verified live:
  `max_user_namespaces=7716`, `unshare --user` works.
- **Dual-core SMP re-confirmed on the full-rootfs image** — `nproc=2`,
  `cpu/online=0-1`, both Cortex-A9 in `/proc/cpuinfo`. (SMP shipped in 1.2.0; this
  corrects any stale "CPU1 not brought up / SMP is groundwork" framing — it is done
  and working on the current image.)
- **CPU power/thermal health confirmed live** — scales 350/700/920/1200 MHz,
  reaches 1.2 GHz under load, VDD_MPU tracks the OPP exactly (1200→1380, 920→1317,
  350→1025 mV; abb_mpu FBB@Nitro 1375 mV). Idle ~70 °C, peak 95 °C under sustained
  2-core load (no throttle; 100 °C passive trip not reached).

### Changed
- **Build infra: local `python3` override aport + gated Phase 7d.**
  `docker-build.sh` stages `pmos/python3/` → `main/python3` (Phase 6) and builds it
  (`pmbootstrap --no-cross build python3 --arch armv7`, Phase 7d) so a higher pkgrel
  (now r5) supersedes Alpine's broken `python3-3.14.5-r2` in the rootfs. The override
  drops `--with-lto` + `--enable-optimizations` and the `!gettext-dev` makedepends
  token (pmbootstrap's apk wrapper rejects `!` entries), keeps stock `-O2` and the
  **default linker (bfd)**. Phase 7d gates every built libpython with
  `scripts/verify-libpython-clean.py` and rebuilds on residual corruption (pkgrel-exact
  apk selection, no stale-apk glob); Phase 10 re-gates the installed rootfs libpython
  before emitting an image — a build-integrity safety net (the on-device crash was a
  flash bug, see Fixed; this only guarantees the build feeding the flash is clean).
- **`device-google-steelhead` no longer masks `sleep-inhibitor.service`; adds
  on-device debug tools.** The `/dev/null` mask was removed in favour of fixing the
  root cause (the python crash, now fixed below); the image also ships `gdb` (16.3) +
  `python3-dbg` (used to coredump-debug the crash on hardware; gdb links `libpython`,
  so it works once python links a clean libpython). (device APKBUILD pkgrel 6→10.)

### Fixed
- **Flash: the rootfs sparse image is now byte-exact (all-RAW, no `DONT_CARE`).**
  `raw2simg.py` (raw ext4 → Android sparse for the 2012 U-Boot fastboot, which lacks
  FILL-chunk support) used to emit every all-zero 4 KiB block as a `DONT_CARE` chunk to
  shrink the image — but fastboot **skips** `DONT_CARE` blocks, which is only correct
  on a **pre-erased** partition. The Nexus Q's U-Boot does **not** erase `userdata`, so
  each skipped block kept STALE data from the previous flash, re-corrupting on-device
  file zero-regions — specifically libpython's `.PyRuntime` / `.data.rel.ro` (PROGBITS,
  read during `Py_Initialize`) — which was **the actual and only root cause of the
  on-device armv7 python SIGSEGV (rc 139)**, even though the flashed (and built) image
  was provably clean. Forensic signature distinguishing flash- from build-corruption:
  the on-device libpython differed from the (gate-CLEAN) flashed image in **exactly 47**
  4 KiB blocks, **all** "image-zero → device-garbage", 0 other
  (`.PyRuntime longest_run 30652`); the image gated CLEAN, the device gated CORRUPT, and
  `scp`-ing the clean image libpython over the device's → `python3 -S -c ''` rc 0
  instantly — proof it was the flash, not the build. **Fix:** `raw2simg.py` now encodes
  **every** block as RAW (no `DONT_CARE`), so the flash is byte-exact regardless of prior
  eMMC content (sparse ≈ raw size; correctness over compression). Verified by a de-sparse
  round-trip (md5 of de-sparsed == raw image) **and** on hardware: a fresh flash (no
  live-patch) of a default-linker (bfd) build gives `/usr/lib/libpython3.14.so.1.0` md5
  `79a0d4ace1358bb2d94c8a4d72479da9`, `SYSPY_OK 3.14.5 … [GCC 15.2.0]`, `SYS_PY_RC=0`.
  Lesson: integrity-verify what the **device** runs, not just the built artifact. See
  `docs/2026-06-28-session-findings.md`.
- **armv7 `python3` works on the device — the on-device SIGSEGV was the FLASH bug
  above, not a build bug.** Alpine's `python3-3.14.5-r2` SIGSEGVed deterministically on
  the Cortex-A9 (`python3 -S -c ''` → rc 139 during `Py_Initialize`), taking down
  `onboard`, `blueman-applet`, `sleep-inhibitor.service` and `gdb` (it links
  `libpython`). The **single root cause** was the `raw2simg.py` `DONT_CARE` flash bug
  (above): a re-flash over non-erased eMMC left stale garbage in libpython's
  should-be-zero `.PyRuntime` / `.data.rel.ro`, landing on
  `interp->types.builtins.num_initialized` (read back as `0xf0012b00`) → wild
  type-index deref → SIGSEGV. v1.6.0 ships a local `pmos/python3/` override (same 3.14.5
  at a higher pkgrel, **r5**, **default linker / bfd**) so it supersedes Alpine's `-r2`;
  the override drops `--with-lto` + `--enable-optimizations` and the `!gettext-dev`
  makedepends token, keeps stock `-O2`. **A qemu-user "linker mmap zero-fill corrupts
  the build" theory and a gold-linker workaround (`-fuse-ld=gold
  -Wl,--no-mmap-output-file`, `binutils-gold` makedep) were investigated and DROPPED as
  unnecessary** — the build was never reproducibly corrupt: 6 independent default-linker
  builds were all integrity-gate-clean, and a bfd build (gold-note absent, libpython md5
  `79a0d4ace1358bb2d94c8a4d72479da9`), flashed via the corrected all-RAW `raw2simg`, ran
  `python3 -S -c ''` rc 0 on the real device (6/6 clean would be ~1.6 % if a real 50 %
  build coin-flip existed). Retained — **not** as a "gold fix" but as a cheap
  **build-integrity safety net** that catches zero-region corruption from any source:
  `scripts/verify-libpython-clean.py` (flags long non-zero runs in those zero-regions;
  clean ≤52 B, corrupt ≥22000 B, threshold 256), run in a Phase-7d gate+retry loop and
  again as a Phase-10 ship gate, with pkgrel-exact apk selection. Other early suspects
  also disproven: LTO/PGO, LDREXD alignment, gnu2/TLSDESC, optimization level. The
  all-RAW flash fix above is what actually fixed the device; the gate only guarantees the
  build feeding it is clean. See `docs/2026-06-28-session-findings.md`.
- **Build-pipeline: rootfs python ≠ the verified apk — fixed.** Phase 7d's old bare
  `python3-3.14.5-r*.apk` glob could match a *stale* apk in the persistent work-volume
  repo rather than the one just built, so the rootfs could install a different build than
  the one gated. Fixed by selecting the **exact `pkgver-pkgrel`** apk, gating that file,
  and re-gating the **installed** rootfs libpython at ship time (the version-only check
  that green-lit a mismatch is gone). _(The apparent "two r4 builds, one crashes / one
  runs" that first surfaced this was almost certainly a post-flash device pull — the
  flash bug above — misread as build corruption, not a real build coin-flip.)_

### Known issues / in progress
- **On-board LAN9500A Ethernet still down** — the v1.4.0 cpufreq boot-timing
  regression is unchanged: `smsc95xx` registers but the device never enumerates, no
  `eth0`. Use WiFi / the USB gadget. (Fix tracked for 1.4.1.)

## [1.5.0] - 2026-06-27

### Added
- **NFC: the PN544 stack is built into the kernel** (NFC / HCI / PN544 / PN544_I2C
  `=y`) with stock-faithful tweaks — a 20 ms VEN settle and a level-triggered IRQ.
  The chip is proven alive (it ACKs i2c when powered); full NFC functionality is a
  follow-up.
- **Nexus Q diagnostics suite.** `nq-healthd` continuously watches the things that
  silently fail in the field (LED-ring / nexusqd hangs, VDD_MPU-vs-OPP drift,
  thermal throttle, kernel errors) and logs to `/var/log/nq-health`;
  `nq-diag-snapshot` captures a full one-shot device snapshot. Both ship enabled in
  the device image, with host-side helpers (`scripts/diag/`) and a `nexusq-diag`
  skill to collect and analyse it over the best available link.
- **nexusqd** now signals systemd readiness + watchdog via `sd_notify`
  (self-contained, no libsystemd dependency), so the LED-ring daemon runs as a
  proper `Type=notify` unit.
- **SSH out of the box** — the device image now ships `openssh` (server + client),
  so the Nexus Q is reachable over the network and the USB gadget without any
  manual install.
- **Composite USB gadget** — a deterministic RNDIS network (`172.16.42.1`) **plus**
  an ACM serial console, bound every boot from configfs. This is the reliable
  fallback link when the on-board ethernet is down, and replaces the old, fragile
  RNDIS→ACM swap that could leave the gadget unbound (no net and no console).

### Changed
- **DTS regulators now point at the real board rails** — DSS `vdda_video`→vcxio,
  tmp101 `vs`→v1v8, the Bluetooth `vbat`/`vddio`, and the TAS5713 amp `AVDD`/`DVDD`→a
  3V3 rail replace placeholder dummies. The spurious "supplying voltage" warnings
  drop from 10 to 5.
- **Default cpufreq governor → `conservative`** (vs `ondemand`). _(Correction
  2026-06-28: this entry's claim that idle "settles at 350 MHz" is not what the
  live device does — idle actually hovers ~920 MHz because `nexusqd`'s LED-ring
  polling keeps the CPU busy, dipping to 350 MHz only briefly. ~70 °C idle. See
  `docs/2026-06-28-session-findings.md`.)_
- **Ethernet (LAN9500A) is reliable again** — it came up on every boot tested in
  v1.5.0 (the v1.4.0 cpufreq-build bring-up intermittency was not reproducible),
  sustaining full ~100 Mbit/s line-rate throughput.
- **Device image UI:** added `nm-tray` (network applet), `blueman` (Bluetooth
  manager) and `breeze-icons` to the LXQt-Wayland session.

### Fixed
- **WiFi: the BCM4330 radio no longer sleeps when idle.** brcmfmac forced the
  firmware `mpc` (Minimum Power Consumption) iovar on, powering the radio down
  between packets — ~30 % packet loss and 270–530 ms latency. A new brcmfmac `mpc`
  module parameter plus a device modprobe.d conf (`mpc=0`) keep it awake (the
  Nexus Q is mains-powered): loss 30 %→0 %, latency 270–530 ms→4–59 ms. Stock-proven
  to be a driver gap — the same firmware + nvram works under the vendor `bcmdhd`.
- **WiFi: disabled brcmfmac P2P** on the BCM4330 — the firmware advertises P2P but
  cannot create the P2P_DEVICE interface, which spammed the log with failed p2p-dev
  creations and orphaned "event handler failed (72)" errors.
- **boot: silenced the benign ti-sysc active-timer `-EBUSY`** probe error for
  GPTIMER1 (an always-on system clockevent owned by the timer core).
- **boot: the systemd rootfs no longer drops to emergency mode.** pmbootstrap
  generated an `/etc/fstab` with a `/boot` entry for a separate boot partition that
  this single-partition (root-only) flash layout does not have; systemd failed that
  mount → `emergency.target`, and `root` was locked so the console was unusable. The
  image build now strips the `/boot` fstab line and unlocks `root`.
- **the device image now actually ships systemd** (explicit
  `deviceinfo_systemd="always"`). Without the opt-in pmbootstrap defaulted to
  OpenRC, silently dropping the entire systemd device integration — nexusqd,
  nq-healthd and the USB-gadget units never ran.

### Known issues
- **WiFi 2.4 GHz bulk throughput** is limited by Bluetooth coexistence (the BCM4330
  combo shares one 2.4 GHz antenna) on a g-only AP — **use 5 GHz for full speed**
  (~26–30 Mbit/s, 802.11n). See
  `docs/2026-06-26-wifi-mpc-fix-and-bulk-bufferbloat.md`.

## [1.4.0] - 2026-06-26

### Added
- **MPU CPU frequency scaling — on-demand up to 1.2 GHz (3.4× the old floor).** 🚀
  The OMAP4460 was pinned at its 350 MHz boot OPP; it now scales across
  350 / 700 / 920 / 1200 MHz under the `ondemand` governor. Built up in small,
  hardware-validated stages, each cross-checked against this unit's
  reverse-engineered stock kernel:
  - VDD_MPU is handed from the TWL6030 VCORE1 SMPS to the external **TPS62361**
    regulator over the PRM Voltage-Controller SR-i2c — the same hand-over stock does.
  - A thin "VC-bridge" `cpu-supply` regulator lets `cpufreq-dt` scale the rail
    through the OMAP voltage layer (VP force-update), at the stock-measured nominal
    voltages (1025 / 1203 / 1317 / 1380 mV).
  - At the 1.2 GHz OPP, **Forward Body Bias** is engaged on VDD_MPU via the on-chip
    ABB LDO — required for stable 1.2 GHz operation.
  - **Thermal throttling**: at the 100 °C trip the CPU cooling drops the frequency
    and ramps it back as it cools, so sustained full load stays safe.
- **USB serial debug console.** The USB gadget is now an ACM serial console
  (`/dev/ttyACM0` on the host, with a `steelhead login:` prompt) that survives
  reboots and leaves fastboot untouched.

### Changed
- The USB gadget no longer exposes a host-side network interface — it was swapped
  from the RNDIS network gadget to the serial console above. Use the on-board
  ethernet / WiFi for networking.

### Known issues
- **On-board LAN9500A USB-Ethernet is down — a regression from 1.3.0.** 🌐 The
  Ethernet that 1.3.0 fixed no longer enumerates on these cpufreq builds: the
  LAN9500A fails to connect (the EHCI port's `PORTSC` connect-status stays 0). It
  is a boot-timing side-effect of the voltage/cpufreq changes, which tipped the
  formerly-marginal connect timing into consistent failure. WiFi works in the
  meantime; a fix (a settle delay in the ethernet bring-up, or reordering the
  voltage init) is tracked for 1.4.1.

## [1.3.0] - 2026-06-24

### Fixed
- **On-board LAN9500A USB-Ethernet now works on mainline 6.12** 🌐 — the
  long-standing "intermittent / never enumerates" problem is **resolved**. The
  chip enumerates on every boot (`0424:9e00` → `smsc95xx … eth0`), the link comes
  up at 100 Mbps/Full and passes traffic cleanly. Verified on hardware: 5/5
  reboots all enumerate, 600 sustained pings at **0 % loss**, 410 MB moved with
  **zero** rx/tx/CRC/drop errors. Root cause was two combined bugs, both found by
  stock-parity auditing against the factory Android kernel:
  - **Patch 0012** (`mfd: omap-usb-host`): mainline only enables the per-port
    UTMI functional clock (`usb_host_hs_utmi_pN_clk` — the L3INIT CLKCTRL
    OPTFCLKEN gate) for **TLL/HSIC** port modes. An external-PHY (`ehci-phy`)
    port falls through to `default:` and never gets its clock, so the port-1 UTMI
    link block ran unclocked (`clk_summary` showed it disabled) and the
    controller never latched the downstream connect (PORTSC CCS stuck 0). Added
    `OMAP_EHCI_PORT_MODE_PHY` to the clock enable/disable paths.
  - **Patch 0006** (`usb: ehci-omap`): stock's `omap_ehci_soft_phy_reset` (the
    UHH softreset / gpio pulse / clock re-park / ULPI register burst) is **not**
    the EHCI `.reset` hook — it is a runtime `ehci_hub_control` *recovery*
    handler that only fires when a port reset/resume times out, **after** a
    device has connected. We were running that whole sequence at bring-up, which
    blocked the very first connect. The `.reset` hook is now a plain
    `ehci_setup()` bring-up (the USB3320's reset defaults already put it in host
    mode); the ULPI/UHH recovery helpers are retained for a future hub_control
    hook.

### Changed
- All kernel patch headers now carry `petronijus@bastla.com` (was a work email /
  placeholder).

## [1.2.0] - 2026-06-23

### Added
- **Second CPU core (dual-core SMP) now works** 🧠 — the OMAP4460 ES1.1 **HS**
  ("steelhead") had always silently dead-locked with `CONFIG_SMP=y`. Two changes:
  - Kernel patch `0009-ARM-OMAP4-steelhead-SEV-in-prepare-wake-cpu1` — stock
    issues a `dsb_sev()` at the end of `omap4_smp_prepare_cpus` after writing
    `AUX_CORE_BOOT_1`; mainline omitted it, so CPU1 (parked in the ROM WFE
    holding pen) never re-read the boot address. Adding the SEV releases it.
  - `cpuidle.off=1` on the cmdline (stock = `cpuidle44xx.disallow_smp_idle`) —
    OMAP4 secondary deep-idle faults → "Attempted to kill the idle task" panic
    on `swapper/1`. Disabling cpuidle keeps SMP stable.
  - `CONFIG_SMP=y`, `CONFIG_NR_CPUS=2`, `CONFIG_HOTPLUG_CPU=y`, `cpu@1` restored
    in the DTS. **Verified on hardware**: both cores online (`nproc` = 2), load
    spreads across CPUs, idle desktop ~70 % idle (the second core absorbs the
    software-rendered compositor that saturated single-core).
  - Kernel switched to **LZMA** compression to keep the now-larger SMP image
    under the ~6.6 MB U-Boot boot-partition ceiling.
- **HDMI EDID now reads + the desktop is visible.** DDC pads
  (`hdmi_scl 0x09c` / `hdmi_sda 0x09e`) changed from `PIN_INPUT_PULLUP` to
  `PIN_INPUT` — the forced internal pull-up fought the board's external DDC
  pull-ups and corrupted the I²C, so EDID never read. Then patch
  `0010-drm-omapdrm-hdmi4-cap-pixel-clock-steelhead` adds `.mode_valid` to the
  hdmi4 bridge capping the pixel clock at 75 MHz: the wlroots compositor was
  selecting the monitor's native 1440×900 @ 106.5 MHz (which the OMAP4 HDMI PLL
  can't generate → blank), and `video=` only constrains fbcon, not the
  compositor. With the cap, wlroots picks **1280×720 @ 60 Hz** and the
  LXQt-Wayland desktop renders. **Verified on hardware.** Native 1440×900 is a
  follow-up (omapdrm PLL).
- **Rotary volume + mute keys work again** 🎛️ — patch
  `0011-leds-steelhead-avr-drain-key-fifo-at-probe`. The `steelhead-avr` keys
  were dead: the AVR holds INT low while its KEY_FIFO is non-empty, the driver
  requests an `IRQF_TRIGGER_FALLING` irq, so a FIFO with stale entries at probe
  left INT already-low → no falling edge → the irq never fired → the FIFO was
  never drained (a latent driver bug; "worked sometimes" = a boot that probed
  with an empty FIFO). Draining the FIFO in probe releases INT and arms the edge.
  **Verified on hardware**: the IRQ fires (0 → 118), `KEY_VOLUMEUP/DOWN` stream as
  you rotate the dome, and the LED ring (driven by `nexusqd`) responds again. The
  AVR was detecting keys all along — confirmed by reading its KEY_FIFO directly
  over i²c. (Mapping the keys to actual audio volume + fixing the
  pulseaudio/wireplumber audio stack is a remaining userspace follow-up.)

### Changed
- **WiFi (BCM4330) power-save disabled by default** — NetworkManager drop-in
  `wifi.powersave = 2` shipped by the device package. Fixes severe latency jitter
  (ping avg ~175 ms, spikes 545–660 ms → stable ~15 ms). Bulk throughput is a
  separate firmware limitation, untouched.

### Added (ethernet, partial)
- Kernel patch `0006` gains stock's **1 ms `udelay(1000)` ULPI pre-reset settle**
  in `omap_ehci_soft_phy_reset` (stock VA `0xc0329ba4`). Real stock parity, but
  not sufficient to make LAN9500A enumeration deterministic — see Known issues.

### Tooling / docs
- `scripts/build-kernel-boot.sh` — fast docker kernel-only rebuild + boot.img
  repack reusing the warm `nexusq-workdir` volume (skips the rootfs).
- Comprehensive writeups: `docs/SMP-second-core.md`,
  `docs/2026-06-22-smp-session-findings.md`, `docs/ethernet-bringup-procedure.md`,
  `docs/2026-06-23-session-findings.md`,
  `docs/2026-06-23-ethernet-continuation.md`.
- `reverse-eng/` ground-truth: stock 3.0.8 SMP `vmlinux.bin` extracted for the
  stock-parity-auditor (gitignored; recreation in `reverse-eng/README.md`).

## [1.1.0] - 2026-06-22

### Added
- **Ethernet (LAN9500A) now works** 🎉 — the soldered on-board SMSC LAN9500A
  USB-ethernet enumerates and carries traffic. Two kernel changes did it:
  - `0006-usb-ehci-omap-steelhead-keep-ethernet-port-alive-ulp` — steelhead
    host-init in `ehci-omap`: INSNREG01 burst thresholds, a ULPI Function-Control
    soft reset of the USB3320 PHY *before* `usb_add_hcd()`, and
    `usb_disable_autosuspend()` on the root hub so the idle port is not
    clock-gated away.
  - `0008-mfd-omap-usb-host-steelhead-UHH-HOSTCONFIG-connect` — program
    `UHH_HOSTCONFIG` to the vendor's `0x11c` (set `P1_CONNECT_STATUS`, leave
    `APP_START_CLK` clear) so the EHCI latches the port-1 connect. Measured
    mainline default was `0x1c`; the stock Android 3.0 kernel uses `0x11c`.

  The long-standing "ethernet is dead hardware" verdict was **wrong** — the stock
  kernel enumerates the same chip on this unit, proving the HW is fine and the bug
  was ours. **Verified on hardware** (#8 kernel): `eth0` (`0424:9e00` → `smsc95xx`)
  links at 100 Mbps/Full and passes bidirectional traffic — 0% packet loss over a
  direct cable, zero rx/tx/CRC/frame errors after ~660 MB moved. Throughput
  ~30–60 Mbps (USB2 / single-core OMAP4 bound, not a link fault). Reach the device
  over ethernet with the persistent `eth-direct` NetworkManager profile
  (static `10.42.0.2/24`).
- Kernel patch `0007-clk-ti-composite-implement-divider-round-set-rate` — OMAP4
  `ti,composite-clock` nodes (gate + divider) had stub `round_rate`/`set_rate`
  returning `-EINVAL`, so any `clk_set_rate()` on them failed. Delegated both to
  `ti_clk_divider_ops` (as `recalc_rate` already did). Fixes the TAS5713
  amplifier MCLK: `dpll_per_m3x2_ck` now sets to 61.44 MHz →
  `auxclk1_ck` = 12.288 MHz (256 × 48 kHz). **Verified on hardware** (#4 kernel):
  clock rates correct, ALSA card 0 `NexusQ-Speaker` registers cleanly, no
  `couldn't set dpll_per_m3x2_ck` error.
- `CONFIG_SRAM=y` in the defconfig (OMAP4 on-chip SRAM driver).
- Tooling: `scripts/regen-dts-patch.sh` (regenerate patch 0003 from the working
  DTS) and `scripts/extract-and-repack.sh` (pull kernel+DTB from the build
  chroot pkgdir and repack a partition-sized boot image — a fast path that skips
  the rootfs build).
- **Build fix:** the recurring `abuild create_apks` "Permission denied" on
  `/home/pmos/packages//pmos/armv7/...apk` is fixed. On a reused `nexusq-workdir`
  volume `$WORK/packages` was owned by the container `pmos` (uid 1000) while
  abuild inside the chroot runs as uid 12345, so it could not write its `.apk`.
  `docker-build.sh` Phase 7a now `chown`s `$WORK/packages` to 12345 before the
  build, so `linux-google-steelhead-*.apk` is created cleanly and `pmbootstrap
  install` runs. `extract-and-repack.sh` is kept as a fast path, no longer a
  required workaround.
- **Build fix:** clearing the armv7 ccache out-of-band leaves its directory owned
  by uid 1000, so abuild inside the chroot (uid 12345) then hits `ccache: error:
  Permission denied` at `make olddefconfig`. `docker-build.sh` Phase 7a now also
  `chown`s `$WORK/cache_ccache_armv7` to 12345 (alongside `$WORK/packages`).

### Changed
- DTS: delete the upstream `cpu@1` node to match the single-core build
  (`CONFIG_SMP=n`). Clears the early-DT `nodes greater than max cores 1` warning
  and the resulting kernel taint (was 512, now 0). Re-add together with the
  deferred OMAP4460 SMP / CPU1 bring-up. Patch 0003 regenerated accordingly.
- Device root password is now read at runtime from a gitignored `.nexus_pw`
  (no hard-coded credential in the SSH/flash helpers).

### Known limitations
- Rootfs image build (`pmbootstrap install`, Phase 9) currently fails on a
  `device-google-steelhead` post-install step (exit 127); the kernel `.apk` and
  boot image build fine, so kernel/DTB iteration is unaffected. Reflash boot only.

## [0.1.0] - 2026-06-10

First public milestone — **postmarketOS userspace boots on the Nexus Q**.

### Working
- Mainline Linux 6.12 LTS boots on TI OMAP4460 (`steelhead`); postmarketOS
  (systemd) comes up from the userdata partition.
- SSH access over USB gadget and over WiFi (BCM4330, original calibration).
- Audio amplifier path (TAS5713) and BT auto-firmware load; sensors.
- HDMI framebuffer console, eMMC + all partitions detected.
- Device tree, defconfig and kernel patches under `kernel/`; pmbootstrap build
  pipeline (`docker-build.sh`) and flashing helpers (`build-and-flash.sh`).
- Release images: `nexusq-boot-v0.1.0.img` + `nexusq-rootfs-v0.1.0-sparse.img`
  (see `INSTALL.md`).

### Known limitations
- Single-core only (SMP disabled due to a U-Boot bug).
- Ethernet is dead hardware on this unit.
- TAS5713 amplifier bring-up is the next roadmap item (`PLAN.md`).

See `HANDOFF.md` for technical notes and root-cause analysis.
