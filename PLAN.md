# Nexus Q Reloaded -- Hardware Status & Plan

Status as of **2026-06-10** (after the boot/WiFi debugging session, see
HANDOFF.md "Session 2026-06-10" for root causes and access paths).

> ## ✅ SHIPPED (2026-08-24) — parametric 7-band EQ with a live curve
>
> Petr, after using the bass/treble card: *"chtěl bych nějakej lepší equalizer, aby
> byla vidět křivka a bylo tam víc handlů, prostě takovej ten pěknej moderní
> standard"* — plus **presets**, and **on the home screen**. Chosen shape:
> **fully parametric, draggable handles** (freq × gain, Q as a second gesture).
>
> **The hardware allows exactly this.** The TAS5713's main EQ bank is **7 biquads
> per channel** (`CH1/CH2 - Biquad 0..6`); today only two are used (low shelf
> 100 Hz, high shelf 8 kHz), so **five sit idle**. A 7-band parametric EQ fits
> entirely in the amp's DSP — still zero CPU, still post-mix, still every source.
> Measured 2026-08-24: engaging the EQ costs **nothing** (PulseAudio 22.24 % flat
> vs 22.11 % at bass+6/treble+6; the biquad is in the path either way). The only
> cost is the one-off ~300 ms write when a handle is released.
>
> ### Band model (stereo-linked: CH1 mirrored to CH2)
> `{type, freq_hz, gain_db, q, enabled}` per band, 7 bands.
> Defaults: band 0 **lowshelf 80 Hz**, bands 1–5 **peaking** at 200 / 500 / 1250 /
> 3150 / 8000 Hz, band 6 **highshelf 12.5 kHz**. Limits: freq 20 Hz–20 kHz,
> gain ±12 dB, Q 0.3–8. Coefficients stay RBJ at the chain's pinned 48 kHz.
>
> ### Preamp — part of "the modern standard", and a real safety item here
> Seven bands can stack to well past +12 dB and clip. The amp's only gains
> (`Master Volume`, `Speaker Volume`) are the **user's volume** and must not be
> hijacked, so the preamp folds into **band 0's `b` coefficients** — exact and
> free. `getEq` also returns the computed **`headroom_db`** (the summed response's
> peak) so the app can offer one-tap auto-preamp. ⚠️ 3.23 is bounded to ±4.0, so
> `_eq_pack` must gain a **range refusal** alongside its existing stability
> refusal — a coefficient that would wrap is worse than a filter that is declined.
>
> ### Protocol §14 v2 — extend, do not break
> `getEq` → `{bands[], preamp_db, headroom_db, max_bands, supported}` **and still
> `bass_db`/`treble_db`** derived from bands 0/6, so the shipped **1.14.0** app
> keeps working. `setEq` accepts either shape. New `listEqPresets`; applying a
> preset is just `setEq` with its bands, so there is one write path, not two.
>
> ### App
> Custom-painted curve (log-f 20 Hz–20 kHz × ±12 dB) with the summed magnitude
> response, 7 draggable handles, Q gesture, headroom readout, preset chips. Full
> editor in **Settings → Sound**; a compact read-only-ish card **on the home
> screen**. The response math is already unit-tested on the device side — port the
> same formulas so the drawn curve cannot disagree with what the amp does.
>
> ### Delivered
> `nexusq-control` **r32** (7 bands, preamp, presets, §14 v2, 32 tests) and app
> **1.15.3+39** (curve, 7 draggable handles, preset chips, preamp + auto,
> home-screen placement, 45 tests). Verified on the hardware by reading the
> coefficients back off the amp: a low-shelf −6 / +8 dB peak at 900 Hz / −5 dB dip
> at 3.8 kHz curve measured **within 0.25 dB everywhere**, auto-preamp cancelled
> the peak to −0.00 dB, both channels identical, Flat returned 14/14 unity.
>
> ### Three UI faults after the first release — and why the tests missed them
> Petr hit all three; each had a test that was already green.
> 1. **The curve could not be dragged, the page scrolled instead.** A `pan`
>    recognizer accepts after `kPanSlop` (36 px) but a scrollable's vertical drag
>    after `kTouchSlop` (18 px), so the scroll wins fairly. Overriding
>    `rejectGesture` to accept does **not** take the gesture back — the arena has
>    already awarded it, so BOTH ran and everything moved twice. Fixed by
>    competing on equal terms: vertical + horizontal drag recognizers, inner ones
>    accept first. *The drag test's host was a scroll view with nothing tall
>    enough to scroll, so it never entered the arena and tested nothing.*
> 2. **"EQ unavailable: not connected" on a cold start** — the card loads in
>    `initState`, before the link is up, and reported that as an EQ fault.
> 3. **Dead after the first drag.** A real `setEq` is ~300 ms (14 I2C writes) and
>    the card both disabled itself and dropped anything arriving during it.
>    *The fake client replied instantly, so the "sending" state never existed in
>    tests.* Fixed by staying live and queueing the newest write.
>
> **The standing lesson, learned twice in one day:** a test you have not watched
> fail is not a safety net. Every fix above was kept only after reverting the
> code and confirming the test goes red.
>
> ### ⛔ Rejected: writing only the bands that changed
> A single-band drag rewrites all 14 registers (~300 ms) where ~2 would do (~40 ms).
> **Petr, 2026-08-24: "to nemusí být okamžité, ať to zbytečně nezatěžujeme."**
> The write queue already makes the UI feel fine, and skipping registers means the
> daemon must track what the amp last received — new state that goes wrong the
> moment anything else writes a coefficient (`i2cset`, a second client, a recovery).
> Do not implement this without a reason better than latency nobody is waiting on.

> ## ✅ FIXED (2026-08-24) — Hardware EQ (GitHub issue #2): write path repaired in kernel r50
>
> **Deployed and unusable.** Kernel r49 exposes the 14 biquad controls and
> `getEq` reports `supported: true`, but **every write through them puts
> `0xFFFFFFFF` into the amp's coefficient RAM regardless of the value asked for** —
> confirmed on the I2C wire with ftrace, not inferred.
>
> Cause: mainline's `tas571x_coefficient_info()` sets the control max to
> `0xffffffff`, and ALSA carries bounds in a `long` — **32-bit on armv7**, so the
> max becomes **−1** and every write clamps to `0xFFFFFFFF`. An upstream bug that
> cannot appear on 64-bit. `amixer cget` shows it plainly: `min=0,max=-1`.
>
> ⚠️ The amp **keeps its coefficients across a warm reboot** — `systemctl reboot`
> does not power-cycle the TAS5713 — so garbage stays loaded until overwritten.
> All 14 biquads have been restored to unity with `i2cset -f` and verified.
> `/etc/nexusq/eq.json` is back to flat, which is what stops
> `eq_restore_thread` re-applying it at boot.
>
> **✅ Fixed by patch 0046, shipped as kernel r50** (deployed, auto-promoted).
> `amixer cget` now reports `max=67108863` instead of `max=-1`. Verified twice:
> on the wire (`[29-00-80-00-00-…]` for unity, and `1000,2000,3000,4000,5000`
> landing byte-exact) and by evaluating the coefficients read back **off the amp**
> as a transfer function — **+3.00 dB @ 20 Hz** for bass +3, half the gain exactly
> at the 100 Hz / 8 kHz design frequencies, independent bands, flat = true unity.
> Full record: `docs/2026-08-24-eq-biquad-write-broken.md`.
>
> **✅ COMPLETE 2026-08-24.** App **1.14.0+35** built (23/23 tests, EQ verified
> present in the binary), released as `app-v1.14.0`, and the OTA manifest points at
> it — Petr updated over OTA, tried the sliders and confirmed: *"testoval jsem to a
> funguje to výborně."* Issue #2 is done end to end: request → hardware EQ in the
> amp's DSP → kernel r50 → app → heard and approved.
>
> ## 🎯 ORIGINAL PLAN (2026-08-23) — Hardware EQ (GitHub issue #2)
>
> **Request:** issue #2 (terierbread360) asks for an EQ in the app — mainly a
> bass control (their Q drives a JBL Partybox donor speaker). Petr's call:
> best possible quality ⇒ **hardware EQ in the TAS5713**, no software DSP.
>
> **Why hardware:** the TAS5713 has **22 programmable biquads** (the main
> per-channel EQ bank = 7+7 biquads at I2C regs `0x29–0x2F`/`0x30–0x36`,
> coefficients in 3.23 fixed point) plus a programmable 2-band DRC. Filtering
> happens in the amp die, **post-mix**: one EQ applies to every source
> (Spotify/AirPlay/Roon/USB) at once, zero CPU, zero added latency, and the
> chain before the amp stays bit-exact. A PA-based EQ would reopen exactly the
> CPU/latency box the alsaloop work closed. Sample rate is a non-issue: the
> whole sink chain is **pinned to 48 kHz** (`50-nexusq-48k.conf`,
> default+alternate rate, avoid-resampling=false) — coefficients are computed
> for fs=48000, with the sink rate asserted at apply time.
>
> **Plan (bottom-up):**
> 1. **Kernel — patch 0045**: mainline `tas571x` already has the full biquad
>    control plumbing — TAS5707 exposes `CH1/CH2 - Biquad 0–6` ALSA integer
>    array controls at the **same addresses the 5713 uses**. Our `tas5713_chip`
>    (patch 0001) points at `tas5711_controls` (volume-only); give it its own
>    controls array = volume/mute + the 14 `BIQUAD_COEFS`, and make sure the
>    regmap config treats the biquad regs like tas5707's does. Bump kernel
>    pkgrel. `CONFIG_SND_SOC_TAS571X=m` ⇒ the change ships in the kernel apk's
>    `/lib/modules` — **`nq-kernel-ota` installs modules too** (nq-kernel-ota
>    lines 220–226), so delivery is the normal health-gated kernel OTA; a dev
>    shortcut is a direct `.ko` swap (same KERNELRELEASE) + reboot.
> 2. **Device — `nexusq-control` §14 `getEq`/`setEq`**: two user knobs first,
>    `bass_db` / `treble_db` (±12 dB, low-shelf ~100 Hz / high-shelf ~8 kHz,
>    RBJ cookbook → 3.23 two's complement), written identically to both
>    channels via `amixer -c NexusQSpeaker cset 'CHx - Biquad 0/1'`; unused
>    biquads stay pass-through. Persist to `/etc/nexusq/eq.json`, re-apply at
>    control start (after the codec probes) and on every set; `getEq` returns
>    the dB values + whether the kernel exposes the controls (feature-detect →
>    the app can grey the UI on an old kernel). Unit tests in the control suite.
> 3. **App**: EQ card (bass/treble sliders + Flat reset) driven by §14, hidden
>    when the device reports no EQ support. Own version track, **release only
>    after Petr's approval** (self-installs on his phone).
> 4. **Later (phase 2, not now):** DRC as speaker protection / loudness,
>    presets, per-source EQ memory if ever wanted.
>
> **Status 2026-08-24:** the sequencing constraint is lifted — the overnight
> USB-idle study is fetched and analysed
> (`docs/2026-08-24-usb-audio-idle-cost.md`). Remaining: deploy (kernel OTA +
> control apk OTA), then a **low-volume** listening check (≤1–2 %, no risky
> speaker tests) before handing the sliders to Petr. That same session should
> carry the `down_threshold=60` listening test — one check, both changes.

> ## 🎧 IN PROGRESS (2026-08-24) — PulseAudio burns ~25 % of a core on silence
>
> **Where we are:** `down_threshold=60` fixed the *power* (6.03× → 1.07×, 84 →
> 68 °C, live on the device). What it did NOT fix is that the box still *does*
> ~25 % of a core of work for a stream of digital silence. Petr: "to že se pořád
> počítá ticho není úplně dobrej stav."
>
> **The one number that frames everything:** `alsaloop` moves the same 48 kHz
> stereo stream one hop for **23 cycles/sample**; PulseAudio's sink thread costs
> **664**. ~30× for the same job, so this is not "audio is expensive".
> Full measurements: `docs/2026-08-24-usb-audio-idle-cost.md` § Follow-up.
>
> **Ground rules for this whole sequence:**
> - **Everything below is measured on SILENCE**, so a badly-chosen resampler or
>   latency cannot damage anything. Only the *final* config needs Petr's listening
>   test. That is what makes it safe to be aggressive with the experiments.
> - **One change at a time, measured before and after.** Two wrong guesses were
>   already made on this problem by reasoning instead of measuring (`tsched=0` as
>   a "leftover"; PA "restart-looping"). Do not repeat that.
> - Baseline to compare against, per PA thread @ 350 MHz, USB Audio live, ring
>   blanked: **sink 17.80 %, aloop source 4.47 %, PA main 3.67 %, alsaloop 0.63 %**;
>   sink does **200 wakeups/s** and **664 cycles/sample**; period 1200 frames
>   (25 ms), buffer 4800, `default-fragments=4 × 25 ms`, `resample-method=auto`,
>   `tsched=0`, everything pinned to 48 kHz.
>
> ### Step 1 — get a profiler ✅ DONE 2026-08-24
> The kernel already had `CONFIG_PERF_EVENTS`; only userspace was missing.
> `apk add perf` → **perf 7.1.5-r0** from `edge/main`, 3 packages
> (`libtraceevent`, `libtraceevent-plugins`, `perf`), no upgrades, no conflicts.
> Works against our 6.12.12 kernel. ⚠️ Installed **live only** — a reflash wipes
> it; add it to the image if profiling becomes routine.
>
> ### Step 2 — split the 17.80 % ✅ DONE 2026-08-24 — it is the RESAMPLER
> `perf record -t <sink tid> -F 499` for 45 s, 7791 samples:
>
> | DSO | share of the sink thread |
> |---|---|
> | **`libspeexdsp`** | **58.86 %** |
> | `libpulsecommon` | 14.01 % |
> | `libpulsecore` | 11.39 % |
> | `[kernel]` + `[snd_pcm]` | 10.46 % |
> | everything else | ~5 % |
>
> **≈10.5 % of a core is the speex resampler alone**, converting 48000 → 48003 to
> track drift between snd-aloop and the amp. `resample-method = auto` →
> `speex-float-1`.
>
> ### Step 2b — resampler NEON build ✅ DONE 2026-08-24 — shipped, 1.34–2.86x, but NOT the answer
> Confirmed two independent ways, not inferred:
> - ELF attributes of `libspeexdsp.so.1.5.2`: `Tag_FP_arch: VFPv3-D16` and
>   **no `Tag_Advanced_SIMD_arch` tag at all**.
> - Disassembly of the hot loop (0x5868–0x58ea): scalar `s`-registers only
>   (`vmov s14`, `vcvt.f32.u32`, `vdiv.f32`) — no NEON `q`-register SIMD.
>
> That is Alpine's doing, not a bug: the `armv7` target is built for the common
> denominator VFPv3-D16, because some ARMv7 parts have no NEON. **The OMAP4460
> does** (`Features: … neon vfpv3`), and **we build our own image**, so this is
> ours to fix. speexdsp ships NEON inner-product paths (`resample_neon.h`) that
> only compile when the build enables NEON.
>
> **The `speex-fixed-1` A/B was investigated and dropped — it would be a regression.**
> `libspeexdsp` here is a **float build** (the hot loop runs `vmla.f32`/`vmul.f32`
> on scalar `s`-registers; a FIXED_POINT build would use integer `smull`/`smlal`).
> In a float build, `speex_resampler_process_int` — which is what PA's
> `speex-fixed-N` calls — converts int16→float **internally and scalar**, instead
> of letting `libpulsecommon`'s NEON `pa_sconv` do it. It moves work from
> vectorised code into scalar code. Not worth three PA restarts to prove a
> negative. Also note `module-loopback` has **no `resample_method` argument** — the
> method is daemon-global, so any A/B costs a full PA restart.
>
> **So the fix is the NEON rebuild, and it is the only item here.** Rebuild
> `speexdsp` with NEON in a `pmos/speexdsp/` overlay: same math, vectorised, no
> quality trade-off, and it speeds up **real** playback too (Spotify is 44.1 kHz
> and hits this resampler on every track). speexdsp ships NEON inner-product
> paths that only compile when the build enables them.
> **Done:** `pmos/speexdsp/APKBUILD` (`1.2.1-r100`, `--enable-neon`), wired into
> `docker-build.sh` validation + the pmaports copy + the dos2unix sweep + a new
> **Phase 7c6** that must run before Phase 8, `publish-ota-repo.sh`
> `OTA_PACKAGES`, and a **Phase 10 SHIP CHECK** that reports whether the rootfs
> actually got our `-r100` or fell back to Alpine's `-r2`. Two build gates stop a
> silently-scalar rebuild: `#define USE_NEON` in `config.h`, and
> `Tag_Advanced_SIMD_arch` on the linked `.so`.
>
> ⚠️ `pkgrel=100` is a version pin so apk prefers ours. **It only holds while
> `pkgver` matches — an upstream `pkgver` bump makes Alpine's win again and we
> silently lose NEON.** Re-base the aport on any upstream bump.
>
> **Measured and deployed** (`speexdsp-1.2.1-r100` live on the device, published):
>
> | ratio | Alpine r2 | ours | speed-up |
> |---|---|---|---|
> | 48000 → 48003 (USB drift) | 2657 ns | 1898 ns | **1.40×** |
> | 48000 → 48000 (1:1) | 1368 ns | 478 ns | **2.86×** |
> | 44100 → 48000 (Spotify) | 2820 ns | 2105 ns | **1.34×** |
>
> Faster in every ratio that occurs here. But **this does not solve the problem
> Step 6 exists for** — a 1.4× cheaper resampler still resamples silence forever.
> Treat it as a win for real playback (every Spotify track) that happens to shave
> the idle case too.
>
> **Two measurement traps this burned, both now fixed in the tooling:**
> 1. **Never measure a resampler change in situ.** `module-loopback`'s rate
>    controller wanders between exactly 48000 and ~48003 Hz, and those ratios take
>    different code paths — so two PA samples minutes apart compare different
>    workloads. Use `scripts/diag/bench-speex-resampler.py`.
> 2. **Pin the CPU frequency, or the governor invents your result.** Three
>    unpinned runs of the same comparison gave 0.75×, 0.95× and 1.26× — the first
>    briefly "proved" the NEON build was a regression, and that near-wrong
>    conclusion nearly got the package reverted. Pinned at 350 MHz, repeats agree
>    to ~1.5 %. The tool now pins and restores automatically.
>
> Rejected on the same rig: **r101** (NEON via `CFLAGS` without `--enable-neon`) —
> 0.99× / 2.15× / 0.98×, i.e. no better than stock except at 1:1. `--enable-neon`'s
> `-O3 -march=armv7-a` is what carries the non-NEON interpolate path. Deleted from
> the build volumes so a later publish cannot pick it up as "newest".
>
> ⛔ **Do NOT lower the resampler quality** (`speex-float-0`). `resample-method`
> is global, so it would degrade Spotify's 44.1 → 48 conversion — audible on real
> music — to save CPU on silence. Wrong trade.
>
> ### Step 3 — chase the 5× wakeups ⬜
> The sink wakes **200×/s** where a 25 ms period needs **40**. With `tsched=0` the
> extra wakeups should be `module-loopback` pushing ~5 ms chunks plus rewinds.
> Levers to test: an explicit `latency_msec` on the loopback (the journal shows it
> losing the argument — `Cannot set requested sink latency of 40.00 ms, adjusting
> to 100.00 ms`, and `Configured latency of 120.00 ms is smaller than minimum
> latency`), and `default-fragment-size-msec`. Also check the odd **96000-frame
> period** on the snd-aloop capture side — a 2 s period there looks wrong.
> **Done when:** wakeups/s explained, and reduced or proven irreducible.
>
> ### Step 4 — listening test ✅ PASSED 2026-08-24 (Petr) — for the governor + NEON, NOT the EQ
> **Petr ran it and passed it** — "za mě dobrý". It covers what is live in the
> audio path: **`down_threshold=60`** and the **NEON resampler**. Backed by data
> from the same window: **94.28 % @ 350 MHz**, die **67 °C**, **777 governor
> transitions (0.37/s)** — so the clock really was moving up and down during
> playback, not sitting still — and **zero xrun/underrun/dropout** in dmesg and
> journal. ⛔ It does **NOT** cover the hardware EQ, which is broken and was
> deliberately excluded.
> **Do NOT touch `tsched=0`** as part of this — it is a deliberate fix for the
> periodic playback crackle on this OMAP4 (`device-google-steelhead.trigger`),
> not a leftover. It only moves if a listening test says so, on its own.
>
> ### Step 5 — deploy nexusqd r14 ⬜
> Independent of everything above, already built, worth **−5.24 % of a core**
> (of which two thirds is nexusqd's socket chatter with PA, not audio). Gates the
> LED render tap on silence instead of on "a sink-input exists".
>
> ### Step 6 — stop computing silence at all ✅ SHIPPED 2026-08-25 (device r82)
> Detect that the UAC2 stream carries nothing worth playing and cork or tear down
> the loopback, so the loaded `module-suspend-on-idle` can finally suspend the sink
> **and the amp powers down**. Worth ~20 % of a core plus the amp's own draw, and
> it is the only step that addresses Petr's actual objection — that the work
> happens at all. ⚠️ Delicate: must not clip the start of real audio; this is the
> path that took r65→r70 to stabilise.
>
> **Measured end to end 2026-08-25 on the live device, box genuinely idle. The
> design below is determined by data, not assumed:**
>
> ⚠️ **Correction to the 2026-08-24 note that briefly stood here.** It claimed
> "digital silence does not exist here — peak 541, 96.5 % of samples non-zero".
> That capture was taken while **Petr was playing music**; it measured his
> content, not the idle floor. Re-measured with the source genuinely idle:
> **960 000 samples, every one exactly 0, one distinct value in the whole
> record.** The step's original assumption was right. This matters a lot — an
> exact-zero test needs **no threshold**, so it can never mistake a quiet passage
> for silence, and calibration disappears from the problem.
>
> **1. Idle really is exact digital silence.** `parec` on `usb_in`, 10 s, box
> idle: peak 0, rms 0, 0/960 000 non-zero. Detection is a zero-test, not a level
> gate.
>
> **2. The host never closes the stream.** The gadget capture advances 96 432
> frames per 2 s and its `hw_ptr` covers the entire uptime, so the box streams
> from boot to forever. UAC2 altsetting-0 detection — where the host itself would
> declare "not playing" — is therefore unavailable. Worth re-testing against a
> different source before ruling it out permanently.
>
> **3. What it costs, and what each remedy recovers** (60 s / 45 s arms, per
> process, box idle throughout):
>
> | state | pulseaudio | nexusqd | alsaloop | total | amp sink | resume |
> |---|---|---|---|---|---|---|
> | today's idle | 27.17 % | 1.15 % | 0.52 % | **28.83 %** | RUNNING | — |
> | unload `module-loopback` | 0.02 % | 0.07 % | 0.32 % | **0.40 %** | SUSPENDED | module rebuild |
> | `suspend-sink` only | 9.11 % | 1.20 % | 0.51 % | **10.82 %** | SUSPENDED | 0 ms |
> | **`suspend-source` + `suspend-sink`** | 0.02 % | 0.04 % | 0.33 % | **0.40 %** | SUSPENDED | **0 ms** |
>
> Percentages are of ONE core. So the idle cost is **28.8 %**, above the ~20 %
> this step was written around, and PulseAudio's resampler is essentially all of
> it. Suspending the sink alone is not enough: the loopback keeps pulling and
> resampling into a suspended sink, wasting 9 %.
>
> **4. ✅ The lever, decided.** Suspending the **source and the sink together**
> gives the full 72× saving *and* returns in 0 ms, with every module left loaded —
> no teardown, no rebuild, and none of the volume/mute restoration the service
> needs after a fresh `module-loopback` load. `module-suspend-on-idle` is loaded
> and works here (SPDIF sits SUSPENDED as proof). `alsaloop` keeps running at
> 0.33 %, which is wanted: the gadget stays drained and the aloop ring stays fresh
> for an instant restart. (A `module-loopback` reload also measured 0 ms, but
> suspend/resume avoids rebuilding state at all.)
>
> ### The design that follows
>
> Sleep on N seconds of exact zeros → `pactl suspend-source usb_in 1` +
> `suspend-sink <tas5713> 1`. Wake on the first non-zero sample → the same two
> calls with `0`.
>
> **The open problem is WHO WATCHES, and it is asymmetric.** Going to sleep may be
> lazy and conservative; waking must beat the ~80 ms the aloop ring holds, or the
> front of the track is lost.
>
> - ⛔ **nexusqd cannot do the wake half.** Its visualizer tap is an `arecord` on
>   the active sink's **monitor** (`nexusqd.c:45`) — downstream of the sink, so a
>   suspended sink produces nothing to watch. It already has a silence gate
>   (`AGC_NOISE_FLOOR`) and an r13 sink-input gate, and it is worth reusing for the
>   sleep half, but it is structurally blind to the return of audio.
> - ⛔ A `parec` watcher on `usb_in` cannot watch while asleep either: connecting a
>   stream to a suspended PA source **resumes it**, undoing the sleep.
> - ✅ **While asleep the aloop capture is free** — PA has closed
>   `hw:Loopback,1,0` — so a watcher can own it directly, read, and on the first
>   non-zero close it and un-suspend. Resume is 0 ms and the ring covers ~80 ms,
>   so nothing should be clipped.
>
> So: a small two-mode watcher — `parec` on `usb_in` (or nexusqd's existing
> verdict) while awake, direct ALSA on `hw:Loopback,1,0` while asleep. Asleep it
> costs about what alsaloop costs; call it ~0.7 % all-in against today's 28.8 %.
>
> **Still to prove when it is built:** that the first note of a track is not
> clipped (record the sink monitor across a wake and compare against the source),
> and that repeated sleep/wake cycles do not drift the resampler or leak modules.
> Not yet measured: whether the amp's own power draw actually falls — the sink
> suspends, but the TAS5713 `Speaker` mixer still read `[on]`, so the analogue
> stage may still be biased. Check the codec's bias level, not just the PCM state.
>
> ### Step 6 — what shipped, and what it measured
>
> `nq-uac2-silence`, spawned and reaped by `nexusq-uac2-in` (device **r82**).
> Silence for 10 s → `suspend-source usb_in`; first non-zero frame → resume.
>
> | | before | after |
> |---|---|---|
> | idle CPU | **28.83 %** of a core | **3.13 %** |
> | relative dynamic power | 1.26× | **1.09×** |
> | PulseAudio alone | 27.17 % | 0.11 % |
> | wake turnaround | — | **1 ms** |
>
> **Never the sink, only the source.** `suspend-sink` is a sticky *user* suspend:
> with it set, a `paplay` stream created a sink-input and the sink still read
> SUSPENDED — the audio went nowhere. Measured, so Spotify/AirPlay/Roon would have
> been silently broken. Suspending only the source lets `module-suspend-on-idle`
> take the sink down by itself, and any other player brings it straight back
> (verified: SUSPENDED → IDLE the moment a second stream appeared).
>
> **The wake latency was 135 ms and is now 1 ms**, and neither number came from
> where it looked. Shortening the ALSA period changed nothing — 512, 1024 and 2048
> frames all measured the same. The 135 ms was **65 ms of waiting for a polite
> SIGTERM to `arecord`** (which must let go of the aloop before PA can reopen it)
> plus **70 ms of forking `pactl`** — the same `pactl` that round-trips in 0 ms
> from a shell, because the cost is forking a Python interpreter on an OMAP4 at
> 350 MHz, not PulseAudio. Fixed with SIGKILL (the readers are pure data pumps)
> and a persistent connection to PA's CLI socket, which `nexusq-uac2-in` now loads
> and owns. Instrument before optimising: the period was the obvious suspect and
> was innocent three times over.
>
> **Verified**: a full sleep → wake → sleep cycle with a 14 s-silence-then-tone
> feed into the same aloop the watcher reads, logged with timings; the real
> service sleeping on the real chain; one `alsaloop`, one source module, one
> loopback module after repeated restarts (no stacking, no leaks).
>
> ✅ **The "remaining prize" turned out not to exist — it was a measurement
> artifact, and correcting it is the main finding of 2026-08-25.** The claim that
> nexusqd's visualiser tap holds the amplifier awake (sink stuck at IDLE, 1.60 %
> of a core) came from a reading taken **45 s after a service restart**. After a
> restart nexusqd animates the breathing screensaver and commits frames to the
> AVR at ~1.4 % of a core; at ~300 s the static-screensaver memcmp gate
> suppresses the writes and it settles to ~0.07 %. Sliced by the minute:
> `1.42, 1.43, 1.22, 0.08, 0.07, 0.07, 0.07`. In steady state the sink reads
> **SUSPENDED** and nexusqd costs **0.10 %** — there was nothing left to fix.
>
> A gate change was built on that artifact anyway (count only UNCORKED
> sink-inputs — a corked input is not feeding the sink, so it should not hold the
> tap open), shipped as nexusqd **r15**, and then judged a regression because a
> settled nexusqd (0.08 %) was compared against a freshly restarted one (1.38 %).
> **The same trap, in reverse**, so the revert (r16) was itself unfounded. The
> change is back in as **r17** — it was never disproved, only its benefit, and
> the streaming "Corked: no" counter carries good tests (six of them, both
> mutations watched failing).
>
> ✅ **Overnight passive measurement, 2026-08-25 23:35 → 06:45 (25 224 s), everything
> settled, source idle throughout** (`ARM_S=25200 SETTLE_S=600`, arm
> `overnight_r17:-:-:-:-:-:-:-` — every knob a dash, so it changed nothing and
> only snapshotted). Raw snaps: `/var/log/nq-opp-study2-r17` on the device.
>
> | | |
> |---|---|
> | 350 MHz residency | **97.57 %** |
> | relative dynamic power | **1.08×** a locked-350 floor — *below* the published 2026-08-19 idle baseline of **1.16×**, and that baseline was plain idle with no USB audio at all |
> | `nexusq-uac2-in` cgroup | **2.158 %** of one core (alsaloop + watcher + its arecord) |
> | `nexusqd` cgroup | **0.148 %** — settled; it was never the problem |
> | governor transitions | 4848 (0.19/s), mean 350 MHz visit 15.6 s |
> | die temp at end | **56.2 °C** |
>
> Source and sink read SUSPENDED for the whole window and the watcher logged no
> transitions, because nothing played. No crashes, no module or process leaks.
>
> **r17 vs r16 is indistinguishable at this resolution.** The settled r16 spot
> reading was ~2.02 % of a core; overnight r17 is ~2.31 % counting nexusqd and PA
> — different windows, so neither is evidence of a difference. That is exactly
> what "the sink already suspends without the change" predicts. r17 is harmless
> and better-reasoned, but its benefit remains unproven; do not claim one.
>
> ### ⬜ NEXT, and it is bigger than anything left above: the USB gadget IRQ floor
>
> With **everything asleep**, `musb-hdrc` fires **~2000 interrupts per second**,
> continuously — two lines at exactly 1000.00/s each, 25.2 million apiece across
> the window, and re-confirmed live at **2006 IRQ/s**. That is the host's
> isochronous stream being serviced once per USB frame whether it carries audio
> or digital silence, which follows directly from the host never closing the
> stream.
>
> The consequences are visible in the same capture and they are large:
>
> * **38 % of all busy CPU is outside every cgroup** (IRQ/softirq/kthreads) —
>   **2.957 % of a core**, MORE than the entire USB-audio service we spent this
>   work shrinking.
> * **cpu0 reaches idle only 32.6 % of the time, mean 297 µs per idle spell**,
>   against cpu1 at **94 % / 833 µs**. Woken roughly every 500 µs, cpu0 can never
>   descend into deep idle at all.
>
> Nothing in PulseAudio, nexusqd or the watcher can touch this — it is below
> userspace.
>
> #### Investigated 2026-08-26 — the lever exists but the kernel forbids it
>
> * **What the two lines are.** OMAP4's musb node carries `interrupt-names =
>   "mc", "dma"`, so it is one endpoint interrupt plus one DMA-completion
>   interrupt **per ISO packet**. Neither is redundant; dropping to PIO would move
>   the copying into interrupt context, which is worse. There is no free 50 %.
> * **RNDIS and ACM contribute nothing** — `usb0` showed zero packets in both
>   directions across the whole window. It is all the audio endpoint.
> * **The interval is a parameter.** `c_hs_bint` (configfs) sets the ISO service
>   interval; ours is `0` = auto, and auto walks bInterval from 4 down to 1 taking
>   the largest that fits, so it lands on 4 = 1 ms = the 1000/s we measure. Our
>   `nexusq-usb-gadget.sh` never sets it.
> * **The arithmetic says there is room.** For 2ch × 16-bit × 48 kHz async with
>   `fb_max=5`, `get_max_bw_for_bint()` gives 196 B at bInterval 4 (1 ms), 388 B
>   at 5 (2 ms), **772 B at 6 (4 ms)** — all under the 1024 B high-speed ISO
>   limit — and 1544 B at 7, which does not fit. So **bInterval 6 is the ceiling,
>   and it would cut USB interrupts 4×**, 2000/s → 500/s.
> * ⛔ **The kernel refuses it anyway.** Tried on the device; the gadget would not
>   bind: `Error: incorrect capture HS/SS bInterval (1-4: fixed, 0: auto)`. It is
>   a bare range check in `afunc_validate_opts()` (`f_uac2.c:1011`) with no
>   bandwidth reasoning behind it — the real bandwidth guard is separate and
>   already clamps anything that does not fit. Reverted cleanly; the device came
>   back with `usb0` re-addressed, one source module, one loopback, both asleep.
> * 💡 Also learned: configfs refuses to change a function's attributes while it
>   is **linked into a config** (`Resource busy`) — unbinding the UDC is not
>   enough, the symlink has to come out first.
>
> **So the next step, if it is taken, is a kernel patch** raising that cap from 4
> to 6 and leaving every other guard alone. Then the open question becomes the
> host's: does the Xiaomi box accept a 4 ms isochronous interval? Nothing can
> answer that short of trying it, and `nq-kernel-ota`'s trial slot with
> health-gated promote is exactly the right vehicle. Expected payoff: IRQ/softirq
> CPU 2.957 % → roughly 0.7 %, and — probably worth more — cpu0 woken every ~2 ms
> instead of every ~500 µs, which is what currently keeps its idle residency down
> at 32.6 %.
