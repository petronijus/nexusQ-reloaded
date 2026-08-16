# Nexus Q Reloaded -- Hardware Status & Plan

Status as of **2026-06-10** (after the boot/WiFi debugging session, see
HANDOFF.md "Session 2026-06-10" for root causes and access paths).

> ## 🔴 NEXT SESSION — a complete COLD build (agreed with Petr, 2026-08-13)
>
> Everything we ship is built on the **warm** `nexusq-workdir` volume, which
> reuses cached aports and can hide an APKBUILD error outright. **No package we
> currently run has ever been clean-built** — nexusqd r13, device r71/r72 and
> nexusq-mqtt r2 included. Run the FULL pipeline on throwaway `-cold` volumes,
> budget **2–4 h**, and expect the Phase 6b `partitions_mount` pattern to need
> re-targeting before Phase 10 can assemble the rootfs. Exact command, evidence
> from the partial cold run, and the post-build verification list are in
> **HANDOFF.md → WHERE TO CONTINUE (2026-08-13), item 7**.

> ## 🎯 STANDING GOAL — idle OPP residency
>
> **With every streaming service off and nothing playing — the Q just sitting
> there asleep — the CPU should spend as close to 100 % of the time at
> `350 MHz` as possible, and an absolute minimum at any OPP above it.**
>
> This is the number every idle-power change is iterated against. It is not a
> nice-to-have: 350 MHz is the only OPP at 1025 mV, so residency above it is
> where the idle heat and the ~65 °C floor come from.
>
> - **Baseline to beat: 70.7 % @ 350 MHz** (nexusqd r13 / device r72 /
>   nexusq-mqtt r2, **79 h** clean MQTT-window measurement, 2026-08-16 — up from
>   60.5 % on r70, which was up from 56.7 % on v1.8.2 and 25.6 % on v1.8.1; see
>   `docs/2026-08-16-idle-opp-remeasure.md`). Residual at pure idle:
>   **22.6 % @ 700**, 6.0 % @ 920, **0.7 % @ 1200 MHz/1380 mV** — flat over the
>   whole 79 h (p05 69.6 %), die 58.4 °C mean. The 08-13 fixes converted the
>   predicted ~12 pp of core-time into ~10 pp of 350 MHz residency and all but
>   erased the hottest OPP (5.1 → 0.7 %), so **the remaining lever is 700 MHz,
>   not 1200**. Secondary metric from the 2026-07-13 study: **~4.2 governor
>   transitions/s** on `conservative` (was 17.5/s on `ondemand`'s sawtooth).
> - **Measure it from `opp_ms`** in `health.jsonl` (device r68+, kernel
>   `time_in_state` deltas) or the MQTT `opp*_pct` rolling window — the latter is
>   what **`scripts/diag/ha-opp-window.py --days N --since '<clean start>'`**
>   reads out of HA history (passive, never touches the device; it also chunks
>   the query, because **HA silently truncates a long multi-entity history
>   response** — a 3.5 d call returned only the first 24 h, well-formed and
>   wrong). **Never use healthd's `freq` field** — that is a spot read taken
>   inside healthd's own busy tick and is observer-biased: over a 12 h capture it
>   claimed 20.5 % at 350 MHz where the kernel counter said **39.1 %**
>   (`docs/2026-08-11-overnight-telemetry-analysis.md` §4).
> - **Root-caused 2026-08-16 — `docs/2026-08-16-idle-700mhz-deep-analysis.md`.**
>   The idle machine is only **3.8 % busy**, but the CPU arrives as ~one burst
>   per second and `conservative` (20 ms window, `up_threshold` 80) ramps on any
>   run **≥16 ms**. The bursts are **pid 1 (27 runs ≥16 ms/min, longest 59 ms,
>   driven by `systemctl` polling at 0.33/s)** and **nq-healthd (18/min)** — the
>   long-lived daemons never cross the threshold. Measured A/B: production
>   72.4 % → **86.2 %** with `ignore_nice_load=1` + housekeeping `Nice=19` +
>   `down_threshold=40` (ramp responsiveness unchanged) → **98.7 %** if
>   `sampling_rate=100 ms` + `up_threshold=95` is added (needs a listening test
>   first). A `powersave` arm proves **nothing at idle needs more than 350 MHz**.
> - **✅ SHIPPED 2026-08-16 (device r73 / btagent r5 / mqtt r3):**
>   `ignore_nice_load=1` + `down_threshold=40` (new `nexusq-cpufreq-tune` oneshot)
>   + `Nice=19` on healthd/mqtt/btagent/wifi-watchdog/nfc (**not** on
>   nexusq-control, it serves the app's volume RPC) + btagent's `systemctl
>   is-active` replaced by a cgroup-directory test. Measured **72.4 % → 86.2 %** from the governor knobs alone, and
>   **90.99 % verified on the device** once btagent's `systemctl` polling went too
>   (pid 1 fell 1.49–2.15 % → 0.186 % of a core), with **ramp responsiveness for real audio unchanged** (`sampling_rate` 20 ms
>   and `up_threshold` 80 are deliberately untouched).
> - 🔬 **KNOWN POTENTIAL TEST — the aggressive governor variant, NOT shipped.**
>   `sampling_rate=100 ms` + `up_threshold=95` on top of the above measured
>   **98.74 % @ 350 MHz** (920/1200 at zero, 0.04 transitions/s, ≈36 % less
>   dynamic power). It stretches a genuine ramp from ~60 ms to ~300 ms, so it
>   needs **Petr's listening test** — Spotify/AirPlay/USB-audio start plus a
>   volume sweep, `dmesg` watched for XRUNs. Runtime-only trial (reverts on
>   reboot): `echo 100000 > /sys/devices/system/cpu/cpufreq/conservative/sampling_rate`
>   and `echo 95 > .../up_threshold`. If it passes, fold both into
>   `nexusq-cpufreq-tune`.
> - **Judge idle only from an on-device self-logging capture with no live ssh
>   session** — an open session pushes the die 74–79 °C within seconds and
>   drags the OPP up with it (2026-07-13 Finding 1). Re-confirmed 2026-08-16:
>   across 3.5 days, **every** contaminated sample (die > 65 °C, peak 82.6;
>   opp350 < 60 %; opp1200 > 3 %, peak 16 %) fell inside the previous session's
>   own ssh window, and nothing outside it came close.

> **✅ DONE (2026-08-13) — the observability layer stopped lying: `nq_progress`
> window (device **r72**) + LED verdict in telemetry (`nexusq-mqtt` **r2**) —
> both SHIPPED via OTA, live-verified. Companion-app half is CODE ONLY.**
> Full record: `docs/2026-08-13-led-stall-verdict-and-progress-window.md`.
> **(a) r72 — a second-order defect created by r13's own success.**
> `nq_progress` was "did nexusqd's `/proc/pid/stat` tick count change since the
> last 5 s sample" — valid only while nexusqd burned 4.4 % of a core (≈22
> USER_HZ ticks/sample). r13 dropped it to 0.165 % ≈ **0.8 ticks/sample**, so a
> zero delta became the ORDINARY reading for a healthy daemon; combined with
> `LED_STALL` reaching 6 being *guaranteed* on a locked/blanked ring (the 1 Hz
> keepalive re-commits identical bytes), healthd's co-signal
> `nq_resp=0 || nq_progress=0` fired **CRIT `led_frozen` on a healthy idle
> device — twice, on the live Q** (`events.jsonl` `t_mono` 214110 and 214497,
> both `resp=1 progress=0`). Fix: `NQ_LAST_TICK_MOVE` + `PROGRESS_STALE_S` (env
> `NQ_PROGRESS_STALE_S`, default 60 s ≈ 10× the ~6 s idle tick interval); the
> window resets when the unit is not running. Post-r72 the same state logs
> **info `led_static` … (resp=1)**. **Lesson: an efficiency win can invalidate a
> monitoring threshold — re-check every "did this process burn CPU recently"
> signal whenever the process gets cheaper.**
> **(b) mqtt r2 — publish the VERDICT, not the counter.** Closes the last open
> action item of `docs/2026-08-11-overnight-telemetry-analysis.md` (§6/§10-2,
> was ⛔ open): every idle Q permanently reported "LED ring frame is stalled"
> ~10 min after the music stopped, because the app thresholded `led_stall >= 6`
> — a counter measuring frame CONTENT staying identical, which the screensaver
> does **by design** (`SS_LOCK_S`=300 s, `SS_BLANK_S`=600 s). New payload
> boolean **`led_stalled`** = `led_stall >= 6` **AND** (`nq_resp` falsy **OR**
> `nq_progress` falsy) — the same distress co-signal healthd uses to pick crit
> `led_frozen` over info `led_static`, so daemon and telemetry agree by
> construction; `led_stall` stays as a diagnostic number. New HA entity
> `binary_sensor` `led` / "LED ring" (problem, diagnostic); an **absent** field
> reads healthy. Live: `binary_sensor.nexus_q_led_ring = off`, payload
> `led_stall=17, led_stalled=False`; 28 pytest tests pass.
> **(c) companion app — NOT RELEASED.** `healthProblems()` reads
> `s['led_stalled'] == true`; two new regression tests pin the idle case
> (`led_stall: 9751` + `led_stalled: false` ⇒ empty) and strict-boolean
> handling; 6/6 pass. **No pubspec bump / no APK / no GitHub release / no
> `app-release.json` bump — Petr must approve the app release** (it self-installs
> on his phone).
> **(d) build infra — `docker-build.sh` OTA package order is no longer
> load-bearing.** The `OTA_PACKAGES_ONLY` loop interleaved `checksum; build` per
> package, so a listed package depending on another listed package hit
> `>>> ERROR: <dep>: <dep> is missing in checksums` (exit 3) — bit
> `nexusq-btagent`→`nexusq-setupd`, then `device-google-steelhead`→`nexusq-mqtt`
> today. Now: one checksum pass over the whole list, then a build pass. (The
> FULL pipeline's Phase 7c3-before-7c4 constraint still stands.)

> **📊 Attribution after the diet (2026-08-13, 240 s, ring blanked) — the next
> targets.** Total busy **8.73 % of one core** (was 18.2 % overnight), forks
> **2.59/s**. Per-cgroup: **nq-healthd 2.43 % (new #1)**, init.scope 1.69 %,
> nexusq-btagent 0.90 %, sshd 0.86 %, nexusq-mqtt 0.47 %, wifi-watchdog 0.36 %,
> avahi 0.30 %, dbus-broker 0.18 %, **nexusqd 0.14 % (confirms r13)**.
> Wakeups/s: **brcmf kworker 33.9**, kworker/0:1-events 13.1, rcu_sched 11.5,
> irq/116-i2c 10.0, dbus-broker 7.4, brcmf_wdog 6.5, avahi 5.8, systemd 4.7,
> btagent 3.3, nexusqd 3.0, healthd 2.6.
> ⚠️ **CAVEAT:** an ssh poll loop (8 logins in the window) inflated **sshd AND
> init.scope** (each login = a pid-1 PAM session), so **pid1/sshd/user.slice are
> NOT trustworthy**; the other daemons' figures are. **Real idle busy ≈ 7.7 %.**
> Two earlier attempts were discarded — one wrote its snapshots to the void
> (empty diffs) and its ~400 `awk` forks heated the die **60 → 67 °C**. **Rules
> for next time:** wait for `led_sum == 0`, run **detached** + fetch **ONCE** (no
> polling), **one** `awk` fork per snapshot.
> **NEXT, in order:** (1) re-measure the overnight opp350 window from HA history,
> **no ssh overnight**; (2) **`nq-healthd` C rewrite** — at 2.43 % it is #1 again
> and what remains is its ~6 forks/tick (`date`, `timeout`+`nexusled`, `od`+`awk`,
> amortized `dmesg`); the right fix is a C daemon in the nexusqd mould
> (in-process socket `connect()` for the liveness probe instead of forking
> `nexusled`, `/dev/kmsg` instead of `dmesg`, in-process hashing instead of
> `od|awk`) — **deliberately NOT started 2026-08-13**, three rewrites of the
> observability layer in one day is unacceptable churn; (3) **WiFi wakeups** —
> `brcmf` ~40/s dominates all other wakeup sources combined; investigate
> mDNS/avahi chatter + the MQTT keepalive; (4) `nexusq-mqtt`'s 30 s `pactl`
> volume poll (≈0.09 %) → take volume from `nexusq-control`'s persistent
> subscribe bridge; (5) governor tunables **LAST**; (6) commit r71 + r13 + r72 +
> mqtt r2 + the app change + `docker-build.sh`.
> **Device-side leftovers:** `/var/log/nq-idle-study/attrib.log` (36 MB) and
> `/usr/local/bin/nq-idle-attrib.sh` remain on the device (service stopped
> 2026-08-13; a local copy of the log was pulled for the analysis).

> **✅ DONE (2026-08-13) — nq-healthd fork diet (device r71) — SHIPPED via OTA,
> live-verified.** Driven by the first clean idle measurement above and its
> same-day attribution (`docs/2026-08-13-idle-opp-residency-measurement.md`):
> total idle busy = 18.2 % of one core, fork rate **13.96/s** (702 759 forks
> overnight), 63 % of busy CPU in short-lived forked children — **nq-healthd
> ~6.3 %** of a core (~5.7 % its forks) was the single biggest consumer,
> ahead of nexusqd ~4.4 % (22 wakeups/s), the leftover nq-idle-study sampler
> ~3.8 % (stopped 2026-08-13), pid 1 ~1.4 % (r68 fix holding), btagent 0.8 %,
> brcmf kworker 0.5 %, pulseaudio+pactl-forker 0.4 %. **r71** rewrites every
> healthd probe fork-free or amortized (builtin `read` for sysfs/procfs,
> fork-free stat/show parsing, one-pass LED fingerprint without md5sum, dmesg
> every 30 s, cgroup-scan librespot liveness, fifo `read -t` tick instead of
> `sleep`; JSONL schema unchanged). On-device A/B: 4212 → **1682 ms CPU/60 s
> (−60 %)**, −517 system forks/min; production after OTA: **2.3 %** of a core
> (was 6.3–7.0 %), system fork rate **3.2/s** (was ~14/s). With the idle-study
> stopped, ~8 pp of one core of constant idle background removed — tonight's
> overnight window is the free A/B (re-measure from HA/MQTT tomorrow morning,
> NO overnight ssh). **Next levers, in order:** ~~nexusqd wakeup audit (22/s for
> a 1 Hz keepalive)~~ **✅ done the same day → nexusqd r13, see the next note**,
> ~~the idle `pactl` forker (volume polling → subscription)~~ **mostly done —
> it was nexusqd's own gate poll (r13); residue = nexusq-mqtt, below**,
> governor tunables last (the 5.1 % @ 1200 MHz may collapse on its own).

> **✅ DONE (2026-08-13) — nexusqd event-driven PA gate + adaptive idle render
> cadence (`nexusqd` r13) — SHIPPED via OTA, live-verified.** The second half of
> the same day's attribution: with healthd fixed, **nexusqd was the top idle
> consumer at ~4.4 % of a core and 22 wakeups/s** on a fully idle box. Two
> causes, both closed. (a) The PA sink-input gate polled `pactl list short
> sink-inputs` every `PA_POLL_S`=1.5 s whenever the tap was off — ~0.67 forks/s
> around the clock, and every short-lived client also woke every OTHER PA
> subscriber (e.g. `nexusq-control`'s bridge) with connect events. Now a
> persistent `pactl subscribe` child (`pa_subscribe_open()`, watched in the main
> `poll()`) drives the re-count on `'new'`/`'remove'` sink-input events; the
> timed re-count is demoted to a safety net (30 s tapping / 60 s idle when the
> subscriber is **proven** ≥ `PA_SUB_PROVEN_S`=2 s, 1.5 s while it is
> down/unproven, respawn every 10 s). (b) The render loop ran a full 20 fps tick
> forever, even with the ring locked/blanked and the frame bit-identical — now
> the deadline stretches to `IDLE_FRAME_S`=1.0 s (matching the 1 Hz AVR
> keepalive) after 40 bit-identical renders **AND** an *intent-idle* test (no
> overlay, no fade, no breathe/spin, screensaver locked or blanked); caps 0.25 s
> with the tap open (a PAUSED stream still holds a sink-input) and 0.5 s while
> the update blink is live; keys / mutating control commands (`CTL_STATUS`
> excluded) / tap off→on force an immediate render.
> **Measured, blanked idle, 120 s, no ssh: 0.165 % of a core (was 4.4 %,
> −96 %), 2.9 wakeups/s (was 22/s, −87 %)**, system fork rate 2.6/s, die
> 59.2 °C; plus a 5-test acceptance suite off the AVR `frame` attr (overlay from
> deep idle in ~8 ms, breath still animating, silent sink-input opens the tap in
> ~200 ms, exactly 1 persistent child). ⚠️ **Never A/B across screensaver
> states** — the first measurement (1.6 % / 54 wake per s) was discarded because
> a fresh `systemctl restart nexusqd` restarts the screensaver and the ring was
> legitimately breathing at 20 fps; wait out `SS_LOCK_S`/`SS_BLANK_S` (548 s).
> **Cumulative for 2026-08-13:** healthd 6.3 → 2.3 %, idle-study stopped
> (~3.8 %), nexusqd 4.4 → 0.165 % ≈ **12 pp of one core** removed since the
> morning's 60.5 % baseline. **Next levers:** (1) re-measure the overnight
> opp350 window tomorrow morning from HA/MQTT, no overnight ssh; (2) the last
> quantified idle forker — `nexusq-mqtt`'s 30 s volume/mute poll (2 forks per
> 30 s ≈ 0.09 % of a core ≈ the 47 s of overnight `pactl` CPU) → take volume
> from `nexusq-control`'s existing persistent `pactl subscribe` bridge instead
> of forking; (3) governor tunables LAST.
> *(Superseded later the same day by the post-diet attribution above: healthd is
> #1 again at 2.43 %, `brcmf` WiFi wakeups are #3, and the `pactl` residue drops
> to #4. r13 also opened the `nq_progress` false-CRIT, fixed by device r72.)*

> **✅ DONE (2026-08-11) — healthd stopped distorting what it measures (device r68).**
> Two fixes out of the 12 h overnight-telemetry analysis
> (`docs/2026-08-11-overnight-telemetry-analysis.md`):
> **(1) the per-sample `systemctl` churn is gone.** With librespot *masked*
> (app's "Spotify off") its MainPID is 0 forever, so the r40 "query systemd only
> on transitions" rule degenerated into querying **every** sample — and each
> `systemctl -M user@` makes pid 1 build and tear down a full PAM login session:
> **~600 sessions/h, pid 1 back to 4 % CPU**, worse than the 3.4 % the r40
> rewrite existed to fix. Both units are now resolved **cgroup-first**
> (`cgroup.procs`, fork-free, instant — the same pattern `nexusq-control` took in
> `098b50f`); systemd is asked only on a real (re)start or once per
> `NQ_UNIT_REFRESH_S` (default 300 s) so `failed`/`inactive`/masked and
> `NRestarts` stay honest. Measured on-device (A/B from `/tmp` with a `systemctl`
> shim counting invocations): over 9 samples **r67 = 10 calls** (9 of them the
> per-sample librespot probe) vs **r68 = 2**; at the default refresh that is
> **60× fewer**, and `NQ_UNIT_REFRESH_S=20` fires exactly 4× in 65 s, so a
> stopped unit's state still cannot go stale.
> **(2) OPP residency is now measured, not guessed:** new `opp_ms`
> (per-OPP ms since the previous sample, from kernel `time_in_state`) and
> `opp_trans` (governor transitions in the same window) — `{}`/`-1` on the first
> sample and after a counter reset rather than a poisoned window. Live-verified:
> `opp_trans` reads **~4.2/s**, matching the independent 2026-07-13 governor
> study. Also `rotate_if_big` now uses `stat` instead of busybox `wc -c`, which
> was reading the whole 4 MB log every 5 s.
> **✅ BUILT + OTA-PUBLISHED + LIVE (2026-08-12, petronijus-PC).** device r68 +
> nonfree-firmware r68 built (warm volume), published to gh-pages `f61d9eb`, and
> installed on the Q (`apk upgrade --available`; mkinitfs/boot-deploy passed —
> Option-A /boot fix holds). Verified on-device: `opp_ms` emits real per-OPP ms
> summing to the sample window, `opp_trans` ≈ 4/s, temp 63–65 °C. `nexusq-mqtt`
> r1 was published in the same push.

> **✅ DONE (2026-08-12) — system update now restarts nq-healthd + nexusq-mqtt
> (nexusq-control r29).** Found while landing r68: `install_system_update` ran
> `apk upgrade --available` but then restarted only a hardcoded list of packages
> whose service name equals their package name — so **nq-healthd** (ships inside
> `device-google-steelhead`) and **nexusq-mqtt** fell through, and neither
> matches `_REBOOT_HINTS`. An app-driven update that changed either left the OLD
> daemon running until an unrelated reboot while the app said "up to date" — i.e.
> r68's whole point (kill 4 % idle CPU + `opp_ms`) would silently not take effect
> via the app button. Fix: a `_PKG_RESTART` package→service map +
> `_services_for_changed()`; `_finish_system_update` restarts `nq-healthd` +
> `nexusq-mqtt` too. 6 new unit tests, suite 19/19 green. **BUILT + OTA-published
> (gh-pages `56aa4d0`) + installed + running on the Q (r29, PID restarted).**

> **✅ DONE (2026-08-10) — MQTT health telemetry → Home Assistant + app (PLANNED-NEXT
> task 2, end-to-end; SHIPPED — commit `b49b536` pushed, device-OTA published as
> gh-pages `cff585f`, app released as `app-v1.12.0` + manifest live).**
> NEW aport **`nexusq-mqtt`** (0.1.0-r0, noarch; `userspace/nexusq-mqtt/`,
> 25 host tests): pure-Python **stdlib** MQTT 3.1.1 publisher (CONNECT+auth+LWT,
> QoS0+retain, PINGREQ dead-link detection, reconnect+backoff) publishing every
> 30 s — retained `nexusq/health/state` JSON, `nexusq/status` online/offline LWT,
> and retained **HA MQTT discovery** (12 sensors + 6 binary_sensors). Data =
> nq-healthd tail (fresh ≤60 s) + own sampling (per-OPP `time_in_state` deltas
> "podíl frekvencí", WiFi RSSI/SSID, volume/mute from whichever mixer owns the
> output, 4 service states, uptime). `/etc/nexusq/mqtt.json` (0600) is a per-home
> SECRET, never baked; unit = `ConditionPathExists`, NO `After=` (ordering-cycle
> rule); enablement self-contained (baked wants-symlink + own 96-preset). Device
> r66→**r67** (`depends += nexusq-mqtt`); docker-build Phase **7c5**;
> `publish-ota-repo.sh` += nexusq-mqtt (apks published, gh-pages `cff585f`).
> ⚠️ broker has NO acl_file.
> **DEPLOYED LIVE: 18 entities in Home Assistant with real values** (79.9 °C,
> 1200 MHz conservative, −28 dBm, volume 45 %); mkinitfs trigger passed — the
> Option-A `/boot` fix holds. **App 1.11.2+30 → 1.12.0+31** (apk released as gh
> release `app-v1.12.0`, manifest live): Settings → "Device health" `HealthScreen`.
> **SAME-DAY FOLLOW-UP (Petr's direction — provisioning architecture changed,
> uncommitted):** the dedicated `nexusq` broker user was REJECTED + deleted
> (1P item too) — the Q connects as the household **`petronijus`** login
> (pw in 1P "MQTT broker"; broker = `mqtt.home.arpa`), and **the companion app
> is the device's ONLY credential provisioner**: `nexusq-control` **r28**
> (PROTOCOL **§13** `setMqttConfig`/`getMqttStatus` + `mqttStatusChanged`;
> atomic 0600 write, password verbatim + never logged/returned; 13 control
> tests green; r28 apk OTA-published gh-pages `e428bef`, source uncommitted)
> + app **1.12.1+32** (Health-panel grey-screen crash fix, null
> cast on absent led_stall/pstore) → **1.13.0+33** (dialog Save also provisions
> the device). Live-proven end-to-end; the **v1.12.0 full image is built, all
> gates PASS** (bakes mqtt r0 + device r67 + control r27 — r28 via System OTA;
> **NOT flashed**). Also uncommitted: **nexusq-mqtt r1** — OPP residency over a
> **rolling 1 h window** (30 s shares swung wildly; 28 daemon tests green; r1
> not yet OTA-published). Known: `connect_gate_setup_entry_test` is NOT hermetic (real
> mDNS — fails with a live Q on the LAN); an internet-only outage still bounces
> the Q off the LAN (watchdog pings the gateway; self-healed on new lease
> `.246`). Record: `docs/2026-08-10-mqtt-health-telemetry.md` (§7 = follow-up).
> **Task (1) — USB audio back into PA via snd-aloop — REMAINS (see PLANNED NEXT
> below).**
>
> **✅ DONE (2026-08-09/10) — System OTA spurious "system update failed" + weak app
> reporting.** The "failed" was a concurrent `apk` CHECK (the app polling
> checkNexus/SystemUpdate) racing the install's `apk upgrade` → `Unable to lock
> database`. **Fixed:** `nexusq-control` r27 — a dedicated `_apk_lock` serializes
> the `apk` subprocess (kills the DB-lock race for check-vs-check AND
> check-vs-install), and `_nexus_install_lock` now only marks "install in
> progress" (checks TEST it → busy only during a real install). r26 first made
> checks TAKE the install lock, which regressed to "update already in progress" on
> a routine check-during-check (app runs checkNexusUpdate on open) — r27 split the
> two locks. **App reporting** (v1.11.2+30): live phase messages while installing
> (downloading→applying/restarting→reconnecting n/8), a `busy` reply shows "update
> in progress" not an error, and the post-install verdict is honest (a leftover
> upgradable package = "a few still pending", not a blanket "failed"). Live +
> OTA-published + on Petr's phone.
>
> **FOLLOW-UPS (2026-08-10 late, Petr):** (a) **HA switches for the audio
> services** (Spotify/AirPlay/Roon/USB Audio toggles on the KolacicekAPrdelcicka
> board — a "Nexus Q" view with gauge/vitals/shares/services/history was added
> 2026-08-10) — MQTT command topics + HA `switch` discovery in nexusq-mqtt,
> wired to the same set_service path nexusq-control uses; **deferred until after
> the idle performance work**. (b) **Idle load/heat investigation → RESOLVED by
> the 2026-08-11 overnight telemetry (device r68).** The real idle-load driver was
> **`nq-healthd` itself**, not the ssh/adb observer-effect hypothesis first noted
> here: with librespot *masked* it ran `systemctl -M user@` **every 5 s**, opening
> and tearing down a full PAM login session per tick (~600/h → pid 1 back to 4 %
> CPU). Fixed r68 (cgroup-first unit state, 60× fewer `systemctl` calls); see
> `docs/2026-08-11-overnight-telemetry-analysis.md` §5. *(Original hypothesis, kept
> for context: pid 1 D-state in `cgroup_lock_and_drain_offline` / `brcmf_escan_timeout`
> storms — the 12 h capture found WiFi flawless, so the escan storms are a separate
> occasional dmesg finding, not the load cause.)* Idle-goal residency is now read
> honestly from `opp_ms`; baseline to beat was **56.7 % @ 350 MHz** at the time
> (superseded 2026-08-13 → **60.5 %**; see STANDING GOAL).
>
> **PLANNED NEXT (2026-08-10) — two tasks, decided with Petr — task (2) ✅ DONE
> 2026-08-10 (see the top note); task (1) remains:**
>
> **(1) ✅ DONE 2026-08-12 (device r70, v1.12.0) — live-verified by Petr: plays,
> lip-sync holds (~130 ms), mixing works, LED visualizer pulses.** The r69 build
> played silence until the r70 fix: `module-loopback`'s sink-input came up
> muted/0 % from `module-stream-restore`; the service now forces it unmuted + 100 %
> after load. USB Audio back into PulseAudio via a stable-clock snd-aloop hop:
> `UAC2Gadget → alsaloop --sync=simple → hw:Loopback,0,0 → PA module-alsa-source
> usb_in → module-loopback → default sink` (mirrors Roon; the alsaloop up front
> converts the async gadget clock to the aloop's stable one, so PA never reads the
> async endpoint — that was the r65 runaway). Reuses the vestigial Loopback aloop
> card (PULSE_IGNORE'd, spare substreams → no new card / no index reshuffle / drift
> sidestepped). No suspend-sink → mixing + unified volume + visualizer restored.
> nq-vol reverted to the pure PA `@DEFAULT_SINK@` path (unified volume, per Petr);
> per-source `usbaudio-master` memory dropped. asound.conf tee retired to a stub.
> BUILT + OTA-published (gh-pages `7131f8c`) + installed on the Q; **structural
> test PASS** (start → usb_in+loopback+alsaloop load; stop → clean teardown, sink
> IDLE). **STILL TO VERIFY WITH PETR:** real listening — mixing, lip-sync (tune
> `NQ_UAC2_LOOPLAT`, start 120 ms), LED visualizer, and no delay-runaway over a
> 30+ min session; needs the Xiaomi in USB-host mode. Original design notes below.
>
> **(1-orig) USB Audio back into PulseAudio — "the proper way" (supersedes the r65
> direct-ALSA path).** r65 made USB audio EXCLUSIVE (alsaloop → hw:NexusQSpeaker,
> PA sink suspended): efficient + no delay, but it lost MIXING with
> Spotify/AirPlay/Roon, lost the unified PA volume (nq-vol was re-plumbed to the
> hardware amixer), and killed the LED music visualizer (it taps the PA monitor).
> Root cause of the ORIGINAL PA breakage was `module-alsa-source` reading the UAC2
> gadget's ASYNC HOST clock directly → the smoother diverged (runaway delay) and
> the loopback never corked (idle burn). **Fix = put a stable-clock snd-aloop
> between the gadget and PA — exactly the pattern Roon already uses successfully**
> (`RAAT → snd-aloop → PA roon_in → mix`): `UAC2 gadget → alsaloop --sync=simple →
> snd-aloop → PA (usb_in) → mix → TAS5713`. alsaloop rate-matches the async gadget
> to the aloop's stable clock (bounded buffers → no runaway); PA then reads a
> stable-clocked source (smoother happy, corks on idle → no burn). Result: low CPU
> + no delay AND back to mixing + unified volume (revert the nq-vol amixer branch)
> + working visualizer. Needs: build the aloop+alsaloop chain, wire PA usb_in like
> roon_in, revert nq-vol/USB-volume-memory to the PA path, and long-session
> re-validation (delay, idle, mixing). Superior architecture; deferred only for
> effort/validation time.
>
> **(2) ✅ DONE 2026-08-10 — MQTT health telemetry → Home Assistant + the app**
> (shipped as planned — see the top note +
> `docs/2026-08-10-mqtt-health-telemetry.md`; original plan text kept below).
> The Q already samples
> health (`nq-healthd`: die temp, cur freq + per-OPP residency "podíl frekvencí",
> load, governor, WiFi RSSI, uptime, active services, volume). Add a small
> publisher (`nexusq-mqtt`, or extend nq-healthd) that publishes those every
> ~30–60 s to `nexusq/health/*` with **Home Assistant MQTT discovery**
> (`homeassistant/sensor/nexusq_*/config` → HA auto-creates the sensors). Broker =
> Petr's HA Mosquitto (creds from 1Password). The companion app subscribes to
> `nexusq/health/#` (Flutter MQTT client) for a live health panel — decoupled, it
> reads the broker rather than needing a direct control-socket link. So: Q → MQTT →
> HA (sensors/dashboard/automations) AND the app reads the same feed.

> **2026-08-08 — ✅ OTA PUBLISHED (nexusqd r12 + device r63); ⚠️ USB-Audio-in delay finding.**
> `publish-ota-repo.sh` pushed to `gh-pages`: **`nexusqd` r12** (front-panel volume
> **ring applied headless** via `nq-vol` — Petr confirmed the ring changes volume) +
> **`device-google-steelhead` r63** (+ firmware r63): **desktop OFF by default**
> (`default.target` → `multi-user.target`) + dropped duplicated labwc audio keybinds;
> `nexusq-control` r25 / `btagent` r4 / `setupd` r4 unchanged. Build fix **`024d928`**
> (committed, **pushed**): r63 APKBUILD `install -dm755 $pkgdir/etc/systemd/system`
> before the `default.target` symlink (clean build was failing) + a
> **`OTA_PACKAGES_ONLY=1`** two-package build gate in `docker-build.sh`. **⚠️ NEW
> ISSUES (2 diagnosed on-device 2026-08-08, both now RESOLVED):**
> **(1) ✅ FIXED (2026-08-09, device r65, committed `2dccd3a` + pushed; OTA published gh-pages `d983b3f`):
> USB-Audio-in delay + idle CPU/heat.** Was: ~3 min playback drift over a long session
> (`module-alsa-source` reported a bogus uptime-growing latency that poisoned
> `module-loopback`'s resampler, pegging the ±1 % rail) AND steady CPU + heat in
> **silence** (never-corked loopback sink-input → `module-suspend-on-idle` couldn't
> sleep the amp; DAC/clock/DMA/resampler ran 24/7). **Fix:** rewrote the bridge as a
> **direct `alsaloop -C hw:UAC2Gadget -P hw:NexusQSpeaker --sync=simple` — no PulseAudio
> in the audio path** — rate-matched from the real hardware pointers with bounded ALSA
> buffers so the delay can't run away. Live: lip-sync correct (Petr-confirmed), ~0 % CPU,
> die 93 °C → 76–79 °C. `--sync=simple` (the device's `alsa-utils` lacks libsamplerate).
> Trade-off: USB audio is now **EXCLUSIVE** (PA sink suspended; `nq-vol` drives the
> TAS5713 hw mixer). Record:
> `docs/2026-08-08-usb-audio-playback-delay-and-ota-publish.md`.
> **(2) ✅ FIXED — System OTA "system update failed"** (Option A) — the
> `postmarketos-mkinitfs` / `boot-deploy` trigger failed (`No kernel found in /boot`)
> because `/boot` was an empty plain dir on this ramdisk-less device. Fixed by putting
> the kernel payload (vmlinuz + dtbs) in `/boot`: live device restored + `apk fix -s`
> clean, and `docker-build.sh` now copies `$ROOTFS/boot` into the exported rootfs
> (pending next-build verify). boot-deploy never flashes a partition
> (`deviceinfo_flash_kernel_on_update` unset). Kernel OTA itself is still Phase 2.
> Record: `docs/2026-08-08-system-ota-mkinitfs-trigger-failure.md`.
>
> **2026-08-03 — ✅ COMPANION APP RUNS ON iOS (app-side only; since committed as `5ba6a9e`).**
> Verified on the **iPhone 17 simulator, iOS 26.5** (Flutter 3.44 / Xcode 26.6;
> `flutter build ios --release --no-codesign` → 18.8 MB Runner.app; app stays
> **1.11.0+28**, no device/image change). Discovery on iOS is **native Bonjour**
> (`BonjourDiscovery.swift`, NWBrowser → `nexusq/bonjour` channel) because
> `package:multicast_dns` needs the restricted Apple multicast entitlement;
> **first-time BT setup + self-update stay Android-only** (no public iOS RFCOMM
> API — the connect gate says so; apk hand-off) — a WiFi'd Q is fully controllable
> from iOS. CocoaPods forced by `open_filex` (Podfiles now tracked). Pending:
> deploy to the physical iPhone (cable + Developer Mode). **Phase-2 candidate: BLE
> GATT setup transport (device-side BlueZ)** to lift the iOS setup limitation.
> Full record: `docs/2026-08-03-ios-companion-port.md`.
>
> **2026-08-02 — ✅ FULL-SYSTEM OTA (Phase 1) + glibc-rt SPLIT + app Update-UX.** On top
> of the daemon-OTA milestone below, the Q now upgrades its **whole system** over the air
> — the "apt upgrade" of the appliance. `nexusq-control` (**r21→r25**)
> `checkSystemUpdate`/`installSystemUpdate` (PROTOCOL **§12b**): `apk upgrade --available`
> for **every** package (base musl/systemd/python from the Alpine·pmOS mirrors + our
> config + daemons from the OTA repo) **MINUS the kernel** (no repo offers a newer one;
> applying a kernel is a boot-partition flash = **Phase 2**, not done). It **reboots when
> base libc/init churns** (musl/systemd/…) and narrates on the ring with the
> **indeterminate spinner** (a slow/unknown-length upgrade froze the determinate bar at
> its ~92 % cap). **Proven live** upgrading systemd **261.1 → 261.2**. Unblocked by the
> **glibc-rt split**: the ~180 MB Roon glibc base moved out of `device-google-steelhead`
> into a new standalone aport **`nexusq-glibc-rt`** (`1.0-r0`, flash-only) — the config
> apk dropped **~191 MB → 58 KB** and is now OTA-shippable (device **r62**; `nexusq-glibc-rt`
> + the kernel stay flash-only). ⚠️ adopting the split needs **one reflash** (a pre-split
> device can't OTA config r62 without the flash-only glibc dep) — done via
> fastboot-over-ssh (**v1.11.9**). **App Update-UX** (companion **1.10.0 → 1.11.0**): the
> Settings **Update cluster is now two items — App update** (phone app + device daemons
> merged into one, install order device-then-app) **and System** (kernel read-only + every
> package). Full record: `docs/2026-08-02-full-system-ota-and-glibc-rt-split.md`.
>
> **2026-08-02 — ✅ DEVICE (DAEMON) OTA PROVEN END-TO-END + LED-narrated updates +
> WiFi `nogw` heal.** The Nexus Q **updates its own software over the air, no
> reflash** — a **signed apk repo on GitHub Pages** (`gh-pages`,
> `petronijus.github.io/nexusQ-reloaded/nexusq`) hosts the four small daemons
> (`nexusq-control`, `nexusqd`, `nexusq-btagent`, `nexusq-setupd`); the device already
> trusts the `pmos@local` build key baked in `/etc/apk/keys`, so `apk` installs our
> signed packages straight from it (no new key). `nexusq-control` **r20**
> `checkNexusUpdate`/`installNexusUpdate` (PROTOCOL **§12**), driven from the app's
> **Nexus Q** Settings section. **PROVEN LIVE** — took the reference Q `nexusqd` r10 /
> control r16 **→ r11 / r19** from the app, no cable. **LED-narrated** (nexusqd
> **r11**, two new primitives `progress`/`mblink`): the **mute LED blinks amber** =
> "update available" while the ring stays on the user's theme; a **determinate ring
> progress bar** while installing; a **green** flash on success. ⚠️ the install
> restarts `nexusq-control` itself so **the app link drops — EXPECTED, not a failure**
> (the app reconnects + re-checks the version). A `_nexus_install_lock` refuses a
> concurrent install (`busy`) rather than racing a second `apk upgrade`. **Scope:**
> daemons only — `device-google-steelhead` is ~191 MB (glibc-rt Roon base), over
> GitHub's 100 MB limit → config OTA waits on a glibc-rt split; the **kernel** stays a
> fastboot flash (the "System" track, next phase). **Companion app self-updates** on
> its own track → **1.9.5** (`versionCode 24`; download-bar + CDN-cache + false-fail
> fixes). Images **v1.11.5**/**v1.11.6** baked (v1.11.6 = control r19 + watchdog fix);
> **v1.11.7** (control r20 + nexusqd r11) baked; OTA repo serves **r11/r20** (live,
> device upgraded to r20 via the app). **WiFi:** the watchdog now also heals the **associated-but-no-route
> `nogw` wedge** (device **r61**, live-caught 2026-08-02) — NM stuck in "getting IP
> configuration" leaves an IP but no default route/gateway; the old code held `fails=0`
> in the `nogw` branch and **never healed the exact case it was built for**, now it
> counts as a bad check and bounces `wlan0`. Full record:
> `docs/2026-08-02-device-ota-and-wifi-nogw-heal.md`.
>
> **2026-08-02 — ✅ USB AUDIO INPUT (the Q as a toggleable USB DAC) + WiFi 5 GHz
> RESOLVED; v1.11.0 tagged.** The Nexus Q has **no optical/HDMI/line audio INPUT** —
> every port is an OUTPUT (DTS McASP0 = DIT/TX → `spdif-dit`; OMAP4 HDMI = DSS
> output-only via TPD12S015A; TI docs + teardown), so **USB is the only no-solder /
> no-Bluetooth digital audio in**. Kernel **r46** (`#47`) gains
> `CONFIG_USB_CONFIGFS_F_UAC2`; `nexusq-usb-gadget.sh` adds a `uac2.0` function
> (`c_chmask=3`/`c_srate=48000`/`c_ssize=2`/`p_chmask=0` — a USB **speaker**, not a
> mic), and **`nexusq-uac2-in`** (long-running user service, `KillMode=mixed`,
> SIGTERM-trap unload) loopbacks the `UAC2Gadget` capture into the default PA sink
> (TAS5713) — **mixes with Spotify/AirPlay/Roon**. A **4th per-service app switch**
> "USB Audio" (`nexusq-control` **r16** `SERVICES` += `nexusq-uac2-in.service`,
> **default-OFF**; app **1.7.0+16**). ⚠️ **`set_service` OFF now `disable`s the
> default-OFF units** (roon, usbaudio) instead of masking — `mask --now` `/dev/null`s
> a unit before stopping it, dropping `KillMode`/`ExecStop` so a module-owning service
> leaks its loopback; `mask` stays only for the vendor-default-ON units
> (spotify/airplay) via a new `vendor_on` flag. **Verified end-to-end on a clean
> v1.11.3 dev flash** (ON → TAS5713 RUNNING, OFF → 0 modules). Device runs dev build
> **v1.11.3** (untagged; device r60, control r16, watchdog r57+, patch 0044); last
> public tag = **v1.11.0** (2026-07-31). **WiFi:** the v1.11.0 "5 GHz TX degrades,
> open" item is **RESOLVED** — `brcmfmac roamoff=1` (device r56) + the new
> **`nexusq-wifi-watchdog`** (device r57, gateway-ping auto-heal, health →
> `/var/log/nq-health/wifi-watchdog.jsonl`) logged a **29 h clean run (2026-08-01)**.
> Full record: `docs/2026-08-02-usb-audio-input.md`.
>
> **2026-07-30 — ✅ FASTBOOT OVER SSH (kernel patch 0044) + v1.11.0 FLASHED and
> live; the device DIED (blown mains fuse) and was repaired.**
> **`systemctl reboot --reboot-argument=bootloader`** now drops the device into
> fastboot in ~15 s (`fastboot reboot` returns to Linux, no loop) — no more
> mains power-cycle. Root cause: mainline `omap44xx_restart()` carried the TODO
> `/* XXX Should save 'cmd' into scratchpad */` and dropped the reboot command, so
> `reboot bootloader` never reached the stock u-boot. RE'd from `vmlinux.bin`
> (`steelhead_reboot_notifier_handler` via `reverse-eng/tools/nqdis.py`): stock
> u-boot reads a NUL-terminated reason string from **SAR RAM `0x4A326A0C`**
> (`"normal"`/`"bootloader"`/`"recovery"`/`"recovery:wipe_data"`) which survives
> the warm reset. Fix = **patch 0044** (kernel r44 → **r45**, uname `#46`),
> guarded to `google,steelhead`, byte-for-byte stock. ⚠️ must be `systemctl` —
> busybox `reboot` doesn't forward the arg. **v1.11.0 flashed** — rootfs
> `v1.11.0-rc3` + boot `v1.11.0-rc4` (kernel `#46`, 44 patches), first v1.11.0 on
> the hardware (rc1–rc3 never flashed — the device died first); carries step-3
> streaming + Settings + brand icons + 0044; app 1.5.2 (own track). **Hardware:**
> the unit went dead-cold (LED dark, no enumerate) = **BLOWN MAINS FUSE**, nothing
> downstream shorted (fuse OL; 400 V cap rail + amp 470 µF caps all OL). The Q has
> an integrated **~35 W mains SMPS (85–265 VAC)**, power board PCB `2400-00053-4`;
> **micro-USB is service-only, cannot power it**. Correct fuse: **Schurter
> `0034.6614` — T800 mA/250 VAC slow-blow (T), TR5 radial, 5.08 mm** (GME 1511926);
> a fast fuse nuisance-blows on inrush. Repaired, **zero collateral damage**.
> Full record: `docs/2026-07-30-fastboot-over-ssh-and-mains-fuse-repair.md`.
>
> **2026-07-16 — ✅ v1.10.1 BUG-FIX RELEASE (5 fixes) — built, flashed,
> hardware-verified** (device **r49** / btagent **r4** / kernel **r44** `#45` /
> control r10 / setupd r4 / nexusqd r10 / firmware r2; app on its own track at
> **1.3.1+9**). (1) **Factory WiFi MAC FIXED** — kernel patch **0043** pins
> `local-mac-address = [f8 8f ca 20 48 e1]` on the DTS `wifi@1` node (mirrors the BT
> `local-bd-address`); `ethtool -P wlan0` now reports the factory MAC as PERMANENT
> (was the chip OTP `14:7d:c5:3a:35:b5`). Stock sourced it from the bootloader cmdline
> (efs/factory) — unreproducible; nvram is a placeholder brcmfmac ignores (chip has a
> MAC in OTP); the only route is DT (`brcmf_of_probe()` programs it over OTP). Also
> closes the onboarding-profile gap (NM `permanent` == factory MAC now). **Lease
> lookups on v1.10.1+ return to the factory MAC / `steelhead` hostname.** (2) **btagent
> fd leak FIXED** (r3 → r4) — `start_control()` was called from the 10 s `_tick` too,
> leaking one fd/tick until exhaustion (~1024) → crash with the socket removed → the app
> saw "bluetooth agent unreachable" every 3 s; `_tick` no longer opens it (fd flat at
> 8). (3) **onboard SIGSEGV every boot FIXED** (device r48 → r49) — the apk trigger now
> neuters onboard's `/etc/xdg/lxqt-tablet/autostart/` file (`Hidden=true`); 0 coredumps.
> (4) **librespot boot-race storm FIXED** (device r48 → r49) — wrapper wlan0-IPv4 wait
> 30 → 180 s; 0 restarts. (5) **App debug mode + Devices poll-error fix** (1.3.1+9, own
> track) — an always-on in-app connection log (method names only, never params) that
> found fix #2 on the first try, and the 3 s Devices poll now logs failures instead of
> flashing the red bar. Full record: `docs/2026-07-16-v1.10.1-bugfixes.md`. Open items
> carry forward — see "Open work".
>
> **2026-07-15 — ✅ SOFTWARE-PHASE STEP 2 SHIPPED: BT pairing from the app, BOTH
> directions, + the HDMI desktop on demand — RELEASED as v1.10.0** (device r48 /
> btagent r3 / control r10 / setupd r4 / nexusqd r10 / kernel r43 / firmware r2;
> app on its own track at **1.2.0+7**). **The framing that matters** (Petr's
> correction, which reframed the whole step): the Q has **no screen and no input
> device**, so **the app is the ONLY way to pair anything to it — it IS the Q's
> Bluetooth settings panel**. The original phase spec only imagined "let a phone
> pair for music"; it missed the half **only the app can do** — **outbound**, where
> the *Q* scans for and pairs a **mouse/keyboard**. That is a **different flow, not
> a variant**: a mouse never connects TO us; we must discover it and call `Pair()`
> on it. Shipped: **btagent r3** (control socket `/run/nexusq-btagent.sock`, 0600 —
> the stdlib-only bridge's only way into BlueZ; async `pair` that owns its own
> discovery), **control r10** (PROTOCOL §9 Bluetooth + §10 Desktop), **device r48**
> (bakes `/var/lib/systemd/linger/user` — load-bearing, or stopping the desktop
> kills the music), **app 1.2.0+7** (Devices screen). **Root cause it is built on:
> v1.9.0's `Pairable == Discoverable` invariant was keyed on the WRONG property**
> and silently broke OUTBOUND bonding — `Pairable` → `HCI_BONDABLE` → SMP bonding
> bit → kernel `store_hint` → bluez persists; without it a mouse pairs, connects,
> genuinely types, and **evaporates on reboot**. Now **ring ⇔ `Pairable`**, off at
> rest. ⚠️ **`bonded`, not `paired`** — `paired` alone LIES. Full record:
> `docs/2026-07-15-step2-bt-pairing-implemented.md`. Known-open: the v1.9.0 pairing
> flake, the factory WiFi MAC, **102.8 °C** under load, and no design review of the
> Devices screen — see "Open work".
>
> **2026-07-15 — ✅ ONBOARDING STEP 1 SHIPPED: BT onboarding ROOT-CAUSED + FIXED,
> RELEASED as v1.9.0** (built from `v1.9.0-rc5`, flashed + hardware-accepted;
> device r47 / setupd r4 / btagent r1 / nexusqd r10 / kernel r43 / firmware r2).
> **TWO independent bugs, BOTH ours, NEITHER hardware:** (1) `blueman-applet`'s
> **DisplayYesNo** agent forced SSP into **Numeric Comparison** → a Confirm/Deny
> dialog on the HDMI desktop that **nothing attached to the Q can click** (every bond
> timed out, mgmt `0x0e`); `RequestDefaultAgent` is last-writer-wins, so it also stole
> the default agent. (2) The app let the RFCOMM socket **bond on demand** — Android's
> implicit bond against an unbonded Just-Works peer collapses (`status 0x5` → `0x0e`)
> and surfaces as the misleading **"incorrect PIN"** toast. Fixes: **NEW
> `nexusq-btagent`** (single **permanent** `NoInputNoOutput` agent — A2DP needs a bond
> long after setupd exits — holding **`Pairable == Discoverable`** so the ring is
> honest: **`Pairable`, not `Discoverable`, gates bonding**), **setupd r4**
> (agent-less, **`RequireAuthentication=True`** → **PSK no longer in the clear**,
> `finishSetup` refused unprovisioned), **device r47** (blueman-applet suppressed —
> package stays; bluez `Class = 0x200428`), **app 1.1.1+5** (bond-first + secure
> RFCOMM; NFC claim scoped to the connect screen). ⚠️ **RETRACTED: "the BCM4330
> cannot complete SSP bonding"** — pairing + A2DP worked 07-09 and were
> **re-verified 07-15**; *never re-derive a hardware limit from a userspace symptom*.
> **rc5 = FAIL CLOSED:** `nexusq-setup-needed` discarded nmcli's exit code, so an NM
> wobble could arm setup mode on a **provisioned** device and leave it discoverable +
> pairable (the agent auto-accepts → a stranger gets a bond); btagent's
> `setupd_active()` now fails to **FALSE** so the ring can never go dark while the
> adapter is pairable. `startSetupMode` re-provisioning **tested + passing**.
> Final acceptance (fresh rc5): tap → **bond first try (0 failures)** → RFCOMM →
> WiFi joined → `finishSetup` → pairing window auto-closed; **0 PSK lines in the
> journal**. **OPEN:** `NEXUSQ_NO_WIFI=1` build flag (the dev image bakes WiFi →
> self-provisions → setup mode never arms; **this, not onboarding, is why the 07-14
> fresh build "wouldn't come up"**), a pairing flake (one run 2 failed attempts, 3
> later runs first-try — **not root-caused**), factory WiFi MAC injected nowhere,
> **102.8 °C under load** (past the 100 °C passive trip), librespot boot race,
> `onboard` SIGSEGV, and an **UNPROVEN** contactless-payment link. Full record:
> `docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`.
>
> **2026-07-14 — v1.9.0-rc3 built + flashed; "NOT autonomous" ⛔ SUPERSEDED by
> 2026-07-15 (above).** The dual-agent hypothesis was RIGHT; the insecure/unbonded
> RFCOMM "workaround to REVISIT" is **RETIRED** — it was **stock parity** (stock never
> bonded during onboarding and accepted a cleartext PSK), and we deliberately moved
> **beyond** stock. Keepers that still stand: Phantasm BT firmware (r2), RFCOMM ch
> 3→22, BT-MAC D-Bus fallback, setup-stays-armed, nexusqd r10 spin-speed + LED
> feedback, device deps/timezone. Record (superseded):
> `docs/2026-07-14-bt-onboarding-state-as-is.md`.
>
> **2026-07-13 — ONBOARDING STEP 1 IMPLEMENTED (13/13 coding tasks, commits
> `ae8f499..cb03cf7`, pushed; targets v1.9.0 — build/flash/acceptance = plan
> Task 14, continues on the LINUX machine).** App-driven WiFi onboarding for
> the display-less Q: NFC tap → BT RFCOMM provisioning → WiFi join →
> name/room/theme → outro. New **`nexusq-setupd`** daemon (BlueZ Profile1
> RFCOMM, UUID `8e1f0cf7-…f3d3a`, Just-Works, `ExecCondition
> nexusq-setup-needed`, psk never logged; 23 host tests), `nexusqd` r9
> **`spin R G B`** setup animation, `nexusq-control` r9 identity file
> `/etc/nexusq/device.json` + **`startSetupMode`**, **NFC payload = live
> connection info** (device r44 — closes the standing backlog item; the unit's
> `NQ_NFC_MESSAGE` override REMOVED, a final-review catch), companion
> **8-screen setup wizard** + Kotlin BT channel + stock-asset pipeline
> (gitignored Google assets; 14 Flutter tests). PROTOCOL.md §8 written.
> Also: repo-wide **`.gitattributes` LF enforcement** (`cb03cf7`) after a CRLF
> worktree broke the dockerized build — committed blobs were never poisoned
> (msys pipe-translation measurement artifact). **Nothing flashed yet** —
> device runs v1.8.2; see HANDOFF.md "WHERE TO CONTINUE" +
> `docs/2026-07-13-onboarding-step1-implementation.md`.
>
> **2026-07-13 — v1.8.2: IDLE POWER — the "hot idle" was an OBSERVER ARTIFACT; the
> real fixes are the governor + OUR healthd.** A 686 s true-idle study (v1.8.1)
> showed any ssh/diag session heats the die to 74–79 °C in seconds (cooling
> constant ~10 s); the true unobserved floor is **~65–66 °C**. Real faults found:
> **74 % of idle at ≥700 MHz/≥1203 mV** (ondemand jump-to-max on ~1000 microburst
> wakeups/s — twd 168/s, WiFi SDIO 29.5/s, AVR i2c 15.5/s — → a 17.5 trans/s
> sawtooth) and **pid 1 as the top userspace idle consumer (3.4 %)** — OUR
> nq-healthd ran 5 systemctl/5 s and queried librespot on the SYSTEM manager where
> it hasn't existed since r31 (**`ls_active`/`ls_restarts` silently broken
> r31–r38**); plus ~7.5 s CPU of `user@0` churn per ssh login. Fixes (kernel
> **r43** `#44` defconfig-only + device **r40**; r39 burned on the systemd-261
> cross-user-socket gotcha — correct form `systemctl -M user@ --user`): default
> governor **`conservative`** (won the live A/B/C: 350 MHz 51.5 %, 4.16 trans/s,
> coolest; tuned-ondemand was a REGRESSION — slower sampling does NOT tame
> microbursts), **nq-healthd rewritten process-first** (cached MainPID + /proc
> liveness; systemctl only on transitions), baked **root linger**. Payoff (542 s
> re-study): 350 MHz 25.6→**56.7 %**, transitions →**4.25/s**, pid 1 →**0.10 %**,
> idle **settles at 350 MHz**. Acceptance PASS (`nq-captures/20260713-102339/`);
> NEW 4th external journal residual (one-shot NM vendored-libsystemd assert at the
> RTC→NTP jump) dispositioned in the boot-error inventory. Remaining floor ~65 °C
> = C1-only MPUSS (C2+ blocked on serial); next idle items: HDMI desktop DPMS
> policy (p3), `user@10000` manager watch (1.28 %).
> See `docs/2026-07-13-idle-power-governor-and-pid1-churn.md`.
>
> **2026-07-12 — CRACKLE CLOSED: TWO INDEPENDENT LAYERS, BOTH FIXED (kernel r41 +
> r42, hardware-verified; user-confirmed perfectly clean playback).** (a)
> load-correlated component → **r41** patch **0041** (sDMA `CCR_READ_PRIORITY` on
> the cyclic/audio channel + GCR `HI_THREAD_RESERVED=1`; verified live
> `GCR=0x00011010`, ch20 CCR bit6=1) — after r41 the crackle was load-INDEPENDENT,
> which isolated (b): a metronomic ~1/s click from **two free-running crystals** —
> mainline reparents the DPLL_ABE reference (`CM_ABE_PLL_REF_CLKSEL`) to sys_32k
> while the TAS5713 MCLK derives from DPLL_PER/sys_clkin 38.4 MHz (~21 ppm ≈
> 1 sample slip/s @ 48 kHz); stock x-loader + bootloader lock DPLL_ABE from
> sys_clkin at exactly 98.304 MHz and our port was undoing it → **r42** patch
> **0042** (DTS `assigned-clocks` on `&mcbsp2`: reparent → `sys_clkin_ck`, relock
> 98304000; `clk_summary`-verified on `#43-postmarketOS`). **v1.8.1 = kernel r42**
> (user decision; the earlier same-day r41-only build of that version was
> superseded and overwritten). First full flash exposed the empty `./firmware/`
> overlay on the Windows machine (rootfs without WiFi/BT firmware) — the **FINAL
> v1.8.1 image was rebuilt on Ubuntu the same evening** (all gates PASS, firmware
> staged), **flashed + acceptance-passed 10/10** (`nq-captures/20260712-233542/`:
> both audio fixes live, WiFi + BT restored — WiFi lease moved `.195`→`.184`
> router-side, don't hardcode it — dmesg err/warn empty, 0 failed units).
> ⚠️ Repo gotcha recorded: the DTS ships **via `kernel/patches/`** —
> editing `kernel/dts/` alone is a silent no-op (the first r42 build was; caught by
> DTB verification). See
> `docs/2026-07-12-audio-crackle-closed-sdma-priority-and-dpll-abe.md`.
>
> **2026-07-09 — v1.8.0: BLUETOOTH A2DP RELIABLE + CRACKLE ISOLATED TO THE OUTPUT
> PATH.** The BCM4330 BT HCI runs over UART2; our DTS BT node had **no `max-speed`**,
> so `hci_bcm` left `oper_speed=0` and never synced the host UART to the firmware
> baud → `hci0: Frame reassembly failed (-84)` (EILSEQ), tx timeouts, phantom
> "Connected", A2DP in corrupt bursts. Kernel **patch 0040** sets
> `max-speed = <3000000>` (stock 3 Mbaud) → **verified live**: reassembly failures 0
> (was 26+), addr correct, pairing + A2DP stable + user-confirmed. **This** (not
> coexistence, not HFP/SCO — both earlier wrong) was the real cause of every past BT
> instability. A2DP is now a baked capability (`phone → BT → PA bluez_source →
> TAS5713`). With A2DP working, the crackle experiment ran: **A2DP crackles the SAME
> as librespot** → the crackle is in the shared **output** path (PA → TAS5713 → sDMA
> → McBSP2), confirming the DMA-contention diagnosis; the **sDMA `HIGH_PRIORITY`
> kernel fix is the outstanding crackle task** _(done 2026-07-12 as r41 — plus the
> second r42 clock-drift layer; see the top note)_. The burned **v1.7.4** bake is reverted
> to a safe subset (kept `tsched=0` + Speaker-unity pin; dropped THRESHOLD service,
> 600 ms buffer, RT configs). Package: `linux` **r40**, `device-google-steelhead`
> **r38**. BT fix verified live (boot.img); full image built, on-device verification
> pending _(v1.8.0 tagged 2026-07-10)_.
> See `docs/2026-07-09-bluetooth-uart-max-speed-and-crackle-isolation.md`.
>
> **2026-07-08 — v1.7.0 (tagged release): NFC TAP-TO-SEND.** Tap a phone on the
> dome → the Q pushes a short text over NFC, shown in the companion app. Uses
> **reverse-HCE** (the 2011 PN544 can't host-card-emulate and Android Beam is gone,
> so the phone runs a HostApduService and the **Q is the ISO-DEP reader**). Enabler:
> kernel **patch 0037** — the pn544 driver now RATS-activates **any** ISO-DEP target
> (was Mifare-DESFire-only), so a modern Android HCE phone (ATQA 0x0004 / SAK 0x20)
> is reachable. Device `nexusq-nfc-send` daemon (owns `nfc0`, neard not installed) +
> companion native HCE. v1.7.0 also bundles the built-but-untagged work since
> v1.6.10 (PA-centric audio v1.6.14–16, volume dial → PA, ethernet-default,
> companion auto-reconnect). Package state: `device-google-steelhead` **r33**,
> `linux` **r37**, `nexusqd` **r7**, `nexusq-control` **r7**. VERIFIED on device.
> See `docs/2026-07-08-nfc-tap-to-send-reverse-hce.md`.
>
> **2026-07-06 — v1.6.10: THE BOOT LOG IS GENUINELY CLEAN (PUBLIC release in
> progress, no tag from here).** v1.6.9 still booted with **~15 err/warn lines**;
> v1.6.10 closes **all** of them — every one root-caused + fixed with a real fix,
> plus two authorized exceptional downgrades and two honestly-documented external
> lines. **Acceptance (clean flash, device `r28` / kernel pkgrel `35` / uname
> `#36`): `dmesg -l err,warn` EMPTY; `journalctl -b -p warning` = ONLY 3
> genuinely-external residuals.** Kernel patches **0033–0036** (brcmfmac
> nowarn-clm, drop HW_BREAKPOINT arch-select, L2C→pr_debug downgrade, btbcm
> 43:30:A0 BD_ADDR), defconfig **BPF** (`BPF_SYSCALL`/`BPF_JIT`/`CGROUP_BPF`) +
> `EXT4_FS_POSIX_ACL` + `SYN_COOKIES`, DTS `&pmu interrupt-affinity` / `&gpmc
> disabled` / `local-bd-address`, device pkg r22→r28 (PA autospawn off, dns-filter
> lo-guard, bluetooth confdir 0755, librespot readiness gate, bluetoothd
> `main.conf [LE]`, nsresourced disabled), new `firmware-google-steelhead` (r1,
> board-named brcmfmac symlinks). boot.img +~0.3 MB (BPF) → still < 8 MB.
> **BD_ADDR** now the real per-device `F8:8F:CA:20:49:E5` (was placeholder
> `43:30:A0:00:00:00`). **Whack-a-mole lesson:** the systemd IP-firewall notice
> fires once for the FIRST unit with `IPAddressDeny` — can't kill it per-unit,
> needs BPF or nothing. **No-serial lesson:** deep cpuidle C2/C3 stays BLOCKED
> (feasible code, but the suspend-to-RAM de-risk HUNG on resume and there is no
> serial console to debug it blind — deferred until serial exists). **3 external
> residuals:** eth-lan DHCP on a DHCP-less direct cable (environmental), kscreen
> `.service` D-Bus naming (upstream libkscreen), avahi No-NSS-mDNS (`nss-mdns`
> unpackaged). Thermal watch: peak ~94–99 °C under sustained load (no throttle).
> See `docs/2026-07-06-bootlog-cleanup.md` (rc1→rc5) + the v1.6.10 update in
> `docs/2026-07-02-boot-error-inventory.md`.
>
> **2026-07-06 — v1.6.9 BOOT-LOG CLEANUP: the boot log is now clean (PUBLIC
> release in progress).** The last two cosmetic log-noise items are fixed
> (device pkg **r23**, kernel **unchanged** `6.12.12-r32`/`#33`; **no functional
> change**): (1) **gkr-pam** "couldn't unlock the login keyring" on every ssh
> session — `/etc/pam.d/base-auth`+`base-session` drop the desktop-keyring PAM
> lines (gnome-keyring stays as an nm-applet/gvfs/webkit dep; `pam_systemd`
> preserved); 0 gkr lines verified. (2) **PulseAudio `module-alsa-card`** on the
> omap-hdmi-audio card — a `PULSE_IGNORE` udev rule; the r22 attempt pinned
> `KERNEL=="card1"` and was REJECTED (ALSA index is probe-order dependent — HDMI
> was card2 that boot), r23 matches the backing platform device
> `KERNELS=="omap-hdmi-audio.1.auto"` (index-independent). **bluetoothd** U5 left
> documented-benign. **Acceptance on r23 = ACCEPT:** 0 failed units, gkr=0, HDMI
> noise=0, eth cold-init works, WiFi/NFC/CPU healthy, no new regression; residual
> err/warn = the known-benign set. **Thermal watch:** peaked ~98–99 °C under
> sustained dual-core load (below the 100 °C trip, no throttle). **Backlog is now
> PROJECTS only:** NFC long-lived userspace (tap-to-pair), deep cpuidle C2+, the
> thermal-headroom watch. See `docs/2026-07-06-bootlog-cleanup.md` and the v1.6.9
> update in `docs/2026-07-02-boot-error-inventory.md`.
>
> **2026-07-06 — ETHERNET COLD-INIT FIXED, task #17 FULLY CLOSED (ships as
> v1.6.8, PUBLIC release in progress).** The LAN9500A "enumeration
> intermittency" was **not a kernel/ehci race** (correcting the note below) — it
> was a **pinmux miss**: `gpio_1` NENABLE (the LAN9500A power-enable) is pad
> `kpd_col2` @ CORE padconf `0x186`, but `ethernet_gpios` muxed only `gpio_62`
> NRESET (`0x08c`), so gpiolib drove the DATAOUT latch (debugfs "asserted")
> while the pad stayed safe_mode → the chip was never powered → PORTSC CCS=0 on
> cold boot. The "3/3 vs 0/3 boots" was stock priming (warm reboots from a stock
> RAM boot kept the chip attached). Fix: DTS `ethernet_gpios` +=
> `OMAP4_IOPAD(0x186, PIN_OUTPUT | MUX_MODE3)` (patch 0003; kernel pkgrel **32**,
> uname **`#33`**, commit **e33a1b4**); the `#31`/6c869e8 2500ms "settle" is
> reverted as a false positive, and the non-stock `gpio_159`/`0x164` mux dropped.
> **Gold-validated:** clean flash of `#33` + a true cold power-cycle → `eth0`
> 100Mbps/Full, 0 failed units. Task #17 is now fully closed (enumerate + link +
> the v1.6.7 NM serverless-DHCP-loop fix). See
> `docs/2026-07-06-eth-coldinit-resolved.md`.
>
> **2026-07-05 — v1.6.7 RELEASED + FLASHED (tag `v1.6.7` = kernel `#29`
> unchanged + device pkg r21: baked eth NM profiles + `led_static` healthd
> guard).** Accepted on device 2026-07-05: 3 clean boots, zero failed units,
> wait-online green, `led_static` guard live (33× info / 0 false CRIT in 91
> samples), NFC clean probe, factory WiFi MAC/.195, CPU/power nominal.
> **Task #17 NARROWED, not closed** (correcting the note below): the NM
> retry-loop half IS fixed and shipped, but the **LAN9500A enumeration
> intermittency is back** — 0/3 acceptance boots enumerated (USB CCS=0) vs 3/3
> on 2026-07-03/04 with the byte-identical kernel; a kernel/ehci bring-up race
> (patches 0006/0008/0012 area), not cpufreq, not r21. With the chip absent
> the boot stays clean (graceful degradation, verified ×3). See the 2026-07-05
> addendum in `docs/2026-07-04-ethernet-resolved-and-led-guard.md`.
>
> **2026-07-04 — v1.6.6 RELEASED (tag `v1.6.6` = the accepted `#29`/r20 image),
> and both post-acceptance open items CLOSED the same day:** (1) **ETHERNET
> RESOLVED, task #17 closed** — the `#29` "carrier flap" was NetworkManager's
> auto-generated-profile serverless-DHCP retry loop (deactivate's MAC reset
> bounced the LAN9500A carrier, the carrier event re-armed autoconnect; ~47 s
> period), not the link: NM detached, carrier held 90+ s / zero transitions /
> 0 errors. Fixed by baked eth0 profiles (device pkg **r21**, hot-deployed):
> `no-auto-default=eth0`, `eth-lan` (DHCP, `cloned-mac-address=permanent`,
> one retry), `eth-direct` (static 10.42.0.2, manual) + host profile
> `eth-direct-host`; `nm-online -s` rc=0, `ssh root@10.42.0.2` works.
> (2) **`led_frozen` static-by-design guard shipped** (healthd r21 +
> nq-health-report): crit only with distress co-signal, healthy static frame →
> info `led_static`. See `docs/2026-07-04-ethernet-resolved-and-led-guard.md`.
>
> **Flashed + acceptance-verified 2026-07-03, released 2026-07-04 as v1.6.6:** the
> boot-error-inventory fix batch — kernel patches 0023–0028 (twl6030 vsel/VC
> voltages, C1-only cpuidle replacing `cpuidle.off=1`, ti-sysc clkdev,
> phy-generic vbus, pwrseq clk-settle), governor back to `ondemand`, `CLK_TWL=y`
> + CLK32KG WiFi/BT clock fix, McPDM include dropped, PVDD supplies, NFC node
> disabled (then called "dead chip" — retracted, see batch 2 below), stable
> WiFi MAC, pipewire-autostart topology fix,
> baked-in ssh/WiFi access. **On device (`6.12.12 #27`, r19): 9/10 targeted
> dmesg error classes gone, zero failed units, governor `ondemand` @ exact OPP
> voltages, key-based `root@` ssh over gadget+WiFi, stable WiFi IP
> `192.168.20.175`.** Newly opened: the B22 `twl: not initialized` ×22 burst,
> B23 twl fck osc-rate, two nq-healthd tooling bugs, optional factory-MAC bake.
> See `CHANGELOG.md` [Unreleased] + `docs/2026-07-02-boot-error-inventory.md`
> §"FLASH-VERIFIED 2026-07-03".
>
> **BATCH 2b — FLASHED + ACCEPTED 2026-07-03 (kernel pkgrel 28 = uname `#29`,
> device r20): NFC IS FIXED AND WORKING.** The stock RAM-boot discrimination
> test (run during the flash cycle) proved the PN544 healthy and exposed the
> real bug: our `nfc_pins` muxed the **dpm_emu debug pads**
> (`0x1b4/0x1b6/0x1b8`) instead of the real `usbb2_ulpitll_dat1/2/3` pads
> (`0x16a/0x16c/0x16e`) — fixed in patch 0003, node re-enabled; `#29` detects
> `nfc_en polarity : active high` cleanly, `nfc0` registered. Batch 2 items all
> verified: B22 gone (patch 0030, `twl: not initialized` count = 0), B23 gone
> (0031), healthd led/vdd fixes live (0029 + r20), **factory WiFi MAC
> `f8:8f:ca:20:48:e1` on air — final IP `192.168.20.195`**. TWL6040 correction
> shipped (nodes/config removed). NEW: **ethernet partial comeback** — carrier
> up for the first time since v1.4.0 but flapping, DHCP never completes
> (task #17 lead); and `led_frozen` still needs a static-by-design guard
> _(both closed 2026-07-04, see the top note)_.
> This image **was released as v1.6.6 on 2026-07-04**. See
> `docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md` +
> `docs/2026-07-02-boot-error-inventory.md` §"BATCH 2b".
>
> **v1.6.5 (2026-07-01)** _(superseded by v1.6.6)_**.** A batch of device-side fixes + companion
> features on the v1.6.3 image (an interim **v1.6.4** was flashed internally to test the LED
> keepalive but never published — folded into v1.6.5; the 1.6.3 → 1.6.5 gap is intentional).
> Final pkgrels: `nexusqd` **r5**, `nexusq-control` **r4**, `device-google-steelhead` **r17**;
> `boot.img` byte-identical to v1.6.2/v1.6.3 (kernel unchanged). (1) **librespot no longer
> crash-loops on a fresh boot** — the ALSA `NexusQ` softvol control didn't exist yet when
> librespot opened its mixer (control created lazily on first PCM open, recreated empty each
> boot); `librespot.service` now bootstraps it with an `ExecStartPre` (`aplay … nexusq_soft`)
> — also fixes companion volume. (2) **color themes are now a BREATHING OVERRIDE** — new
> `nexusqd breathe R G B` (`CTL_BREATHE`) pulses the compositor manual layer (priority 8) in
> the theme hue with the same throb as the idle screensaver, **always visible** (over the
> music visualizer / a blanked screensaver); a companion theme maps to **just** `breathe R G B`
> (blue/warm/cool/rose/smoke/off). (The earlier screensaver-retint approach was reverted —
> it was invisible once the screensaver blanked / while music played.) (3) **the 5 music
> visualisations are selectable from the app** — bridge `setScene`/`listScenes`
> (→ `auto` + `scene 0..4`) + a separate app picker; color theme (breathing override, prio 8)
> and visualisation (music, prio 7) are independent. (4) **app-mute now lights the device
> mute LED** — new `nexusqd muted 0|1` (`CTL_SETMUTED`) calls the same `apply_mute_led()` the
> hardware key drives; the bridge's volume/mute path sends it. (5) **the LED ring no longer
> goes dark after a long idle** — the `steelhead-avr` fw starves without periodic frame
> *commits* once the screensaver locked/blanked and `nexusqd`'s `memcmp` write-gate went
> silent; fixed with a 1 Hz keepalive (`AVR_KEEPALIVE_S=1.0`). _(Deployed; "never wedges
> again" still needs an overnight idle soak — the wedge took ~20 h.)_ (6) **the companion
> bridge is reachable over WiFi** — new nftables drop-in `55_nexusq-control.nft` opens TCP
> 45015 on `wlan*`. _(Deferred to **v1.6.6**: companion volume/mute act on the ALSA softvol +
> mute LED but do NOT mirror to the LXQt desktop taskbar — app vs desktop can diverge; see
> HANDOFF.md.)_ See `CHANGELOG.md` ([1.6.5]),
> `docs/2026-07-01-led-ring-avr-starvation-keepalive.md` and
> `docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.
>
> **v1.6.3 (2026-06-30).** **A companion app and its on-device
> `nexusq-control` LAN bridge now ship** — a phone/desktop remote for the Q (volume,
> LED theme + brightness, now-playing), replacing the dead 2012 Google companion app.
> `nexusq-control` is a pure-Python3 daemon (new noarch aport `pmos/nexusq-control`,
> `userspace/nexusq-control/`) on **TCP 45015**, advertised over mDNS **`_nexusq._tcp`**,
> speaking a line-delimited JSON v1 protocol (`companion/PROTOCOL.md`). It fans out to:
> an ALSA **`nexusq_soft` softvol** (control `NexusQ`, layered on the v1.6.2 tee) for
> volume — the **same knob librespot uses** (`--mixer alsa --alsa-mixer-control NexusQ`),
> so Spotify-Connect and companion volume stay in lockstep — `nexusqd` over
> `/run/nexusqd.sock` for LED **theme + brightness** (new `nexusqd brightness <0-255>`),
> and a `librespot --onevent` hook for **now-playing**. The companion (`companion/app`)
> is a cross-platform **Flutter** app (sphere UI, animated ring, mDNS auto-discovery),
> built on the phone — **not** in the device image. The bridge is enabled at boot via a
> systemd preset (`95-nexusq.preset`) and its unit carries **no `After=`** ordering (an
> `After=nexusqd.service` formed a boot ordering cycle that systemd broke by **deleting
> the bridge's start job**, so it never auto-started — fixed by dropping `After=`).
> **Verified live:** the bridge auto-starts (`active`), answers every protocol method,
> volume works, and the LED visualizer still tracks playback. Transport
> (play/pause/next) is `unavailable` in v1 by design (librespot has no local transport
> API). See `CHANGELOG.md` ([1.6.3]) and `docs/2026-06-30-companion-app-RE.md`.
>
> **v1.6.2 (2026-06-30).** **The LED music visualizer now reacts to
> Spotify playback.** v1.6.1 sent librespot straight to the speaker, so nexusqd's
> snd-aloop audio tap got nothing and the ring stayed idle; v1.6.2 makes the `nexusq`
> ALSA PCM a TEE (`multi` + `route`) that duplicates the 48 kHz stereo to BOTH the
> TAS5713 speaker AND `hw:Loopback,0`, and adds `/etc/modules-load.d/snd-aloop.conf`
> to auto-load the loopback. nexusqd's existing `arecord` on `hw:Loopback,1` drives
> the FFT/beat ring while the speaker plays (speaker = timing master, loopback slave
> is `plughw` so it never blocks playback). `device-google-steelhead` pkgrel 12;
> verified live (ring pulses to music, no ALSA/xrun, NRestarts=0). See `CHANGELOG.md`.
>
> **v1.6.1 (2026-06-29).** **TAS5713 speaker audio works** and
> **Spotify Connect (librespot) is baked into the build.** The v1.6.0 speaker path
> played exactly 2× too fast — fixed by kernel patch 0022 (derives McBSP2 `CLKGDV`
> from the real fclk + a minimal I2S frame); on-device a 60 s clip now plays in
> **60.00 s** (was ~30 s). `device-google-steelhead` (pkgrel 11) now ships the enabled
> `librespot.service`, the `nexusq` ALSA PCM (`asound.conf`, by card NAME) and the
> `60_spotify.nft` drop-in, so the Spotify "Nexus Q" target survives a flash. See
> `CHANGELOG.md` and `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.
>
> **v1.6.0 (2026-06-28).** Added a **working armv7 `python3`** on the
> device — flash-verified from a clean flash. The fix was the byte-exact all-RAW
> `raw2simg.py` flash (the on-device SIGSEGV was a flash bug, not a build bug); v1.6.0
> ships a plain default-linker (bfd) `python3` rebuild with a build-integrity gate as a
> safety net (a gold-linker workaround was tried and dropped as unnecessary).
> `onboard`/`blueman`/`sleep-inhibitor`/`gdb` are no longer down. Plus zram swap and
> user namespaces. See `CHANGELOG.md` and `docs/2026-06-28-session-findings.md`.

## Open work (2026-07-15) — the repo IS the tracker

> Findings and follow-ups live here, not in a task app.

### ✅ DONE (v1.10.0, 2026-07-15) — btagent invariant re-based on `Pairable`
*(was "⛔ btagent invariant is based on the wrong property — fix first")*
**Shipped in btagent r3.** `nexusq-btagent` (v1.9.0) held `Pairable ==
Discoverable`. Measured A/B on a real MX Master 4: `Pairable: no` → pairing
"succeeds" but **stores no keys** and dies on restart; `Pairable: yes` →
`[PeripheralLongTermKey]` + `[IdentityResolvingKey]` on disk, survives. Chain (from
`bluetoothd -d`, not from source): `Pairable` → `HCI_BONDABLE` → SMP bonding bit →
kernel `store_hint` → BlueZ persists. So the invariant silently killed **outbound**
bond persistence (mouse/keyboard re-pair every boot). Inbound always worked because
setup makes the adapter discoverable.
**Fixed as planned:** re-based on **`ring ⇔ Pairable`**, `Pairable` **off at rest**,
opened only for a bounded window — and an **outbound pair now opens a window like
everything else**, so there is one mechanism for both directions. Landed in btagent
+ its tests + README + PROTOCOL (the corrected rule lives in the **new §9.7**;
§8.6 carries a superseded-by pointer). Records:
`docs/2026-07-15-step2-bt-pairing-implemented.md` +
`docs/superpowers/specs/2026-07-15-step2-bt-pairing-via-app.md` §4.2.

### ✅ DONE (v1.10.0, 2026-07-15) — desktop on demand, app-toggled
*(was "Desktop on demand (Petr's idea) — app button toggles the HDMI desktop")*
**Shipped**: `setDesktop {on|off}`/`getDesktop` + event `desktopChanged` in
`nexusq-control` **r10** (PROTOCOL §10), and a toggle on the app's new **Devices**
screen (1.2.0+7). The desktop is **`tinydm.service`** (a system service →
start/stop-able) in `session-c1.scope`, while PulseAudio and librespot live in
`user@10000.service` — a *different* cgroup.
**The BLOCKER is cleared:** `/var/lib/systemd/linger/` held **only `root`, not
`user`**, so `user@10000` (where audio lives) existed only because of the desktop
session — stopping the desktop would have **killed audio**. **device r48 now bakes
`/var/lib/systemd/linger/user`.** **Verified live 2026-07-15**: with linger,
`systemctl stop tinydm` leaves **pulseaudio + librespot active, both sinks
present**. Composes with the row above: pair a keyboard + mouse, switch the desktop
on → the appliance is a computer.
**⚠️ Still open from this item:** the **thermal delta was never measured** — the
desktop-vs-headless idle-heat question the toggle was supposed to answer is
unanswered. A diag sweep did measure **102.8 °C under sustained load** (above the
documented 94–99 °C envelope) and 72–75 °C at true idle; see below.
**Also learned:** stopping the desktop **churns logind** hard enough that ssh auth
(`pam_systemd`) hung for ~a minute during testing (it recovered on its own) — hence
`set_desktop`'s 60 s deadline. This still supersedes the older "HDMI desktop idle
policy" item below.

### 🌡 Thermal: 102.8 °C under sustained load — above the documented envelope
A 2026-07-15 diag sweep measured **102.8 °C** under sustained load, **above the
94–99 °C envelope** documented elsewhere in this file. True idle is **72–75 °C /
52 % at 350 MHz**. Not root-caused, not acted on. The desktop-on-demand toggle
(above) is the obvious first lever to measure against.

### ✅ DONE (v1.10.1, 2026-07-16) — factory WiFi MAC pinned in the DTS
*(was "⚠️ Factory WiFi MAC — ROOT-CAUSED, NOT fixed")*
The NM `cloned-mac-address` pin (`gen-wifi-profile.sh`) only reached the **baked dev
profile**; the profile `nexusq-setupd` created via `nmcli connection add` fell back to
`permanent` = the chip **OTP MAC `14:7d:c5:3a:35:b5`**, and the device had no runtime
source for the factory `f8:8f:ca:20:48:e1` (nvram is a generic Broadcom placeholder
brcmfmac ignores). **Fixed as planned — mirror BT:** kernel patch **0043** pins
`local-mac-address = [f8 8f ca 20 48 e1]` on the DTS `wifi@1` node
([[verify-hypothesis-against-stock]] confirmed stock sourced it from the bootloader
cmdline / efs-factory, which we can't reproduce). `brcmf_of_probe()` programs it over
OTP → `ethtool -P wlan0` = the factory MAC as **PERMANENT** on every profile, so no
per-profile clone is needed. **Lease lookups on v1.10.1+ return to the factory MAC /
`steelhead` hostname.** `docs/2026-07-16-v1.10.1-bugfixes.md`.

### ✅ DONE (v1.10.1, 2026-07-16) — librespot boot race + onboard SIGSEGV + btagent fd leak
- **librespot boot race** *(was "5 restarts, self-heals")* — the wrapper's wlan0-IPv4
  wait was 30 s but BCM4330 cold-boot association takes longer → 5× Restart storm; the
  USER-manager `network-online.target` is not wired to real connectivity so the poll IS
  the gate. **Fixed: wait 30 → 180 s (device r49); 0 restarts.**
- **`onboard` SIGSEGVs every boot** *(was open — NOT the old flash corruption)* — its
  native `osk` module, useless on a screenless/inputless appliance. Its autostart is in
  `/etc/xdg/lxqt-tablet/autostart/` (not the plain `autostart/` our XDG shadow covers),
  so **the apk trigger now neuters onboard's own file there** (`Hidden=true`, device
  r49); 0 coredumps. ([[fix-errors-dont-mask]] — neutered its autostart, did not mask
  the crash.)
- **btagent fd leak** — `start_control()` was called from the 10 s `_tick` as well as
  `run()`, leaking one fd/tick until btagent exhausted them (~1024) and crashed with its
  socket removed → the app saw "bluetooth agent unreachable" every 3 s. **Fixed (btagent
  r4): `_tick` no longer opens the socket; `start_control()` is idempotent; fd flat at
  8.** Found on the first try by the app's new debug log.

### ✅ DONE: USB-Audio bridge redesign — direct alsaloop (2026-08-09, device r65, committed `2dccd3a` + pushed; OTA published gh-pages `d983b3f`)
Two on-device findings, **one fix** — the PulseAudio `module-alsa-source` →
`module-loopback` bridge on the async UAC2 capture was replaced wholesale:
- **Was: playback drifts ~3 min late over a long session** — the loopback's
  latency-driven resampler was fed a bogus uptime-growing source latency (5134 s seen),
  pegged the ±1 % rail, backlog grew to minutes. Ruled out clock mismatch (+100 ppm
  normal), the capture buffer (~3 ms), and `tsched=0`.
- **Was: steady CPU + heat in SILENCE** — the loopback sink-input was **never corked**
  (`Corked: no`), so `module-suspend-on-idle` (loaded) could never suspend the TAS5713
  sink → DAC/clock/DMA/speex resampler powered 24/7 (die 78→73 °C when the unit was
  stopped; during streaming the CPU pinned at 1.2 GHz / 91–94 °C).
- **Shipped fix:** a **direct ALSA bridge, no PulseAudio in the audio path** —
  `alsaloop -C hw:UAC2Gadget -P hw:NexusQSpeaker -r 48000 -c 2 -f S16_LE --sync=simple`,
  rate-matched from the **real hardware pointers** (no PA smoother to diverge) with
  structurally **bounded** ALSA buffers so the delay **cannot** run away. Measured live:
  audio plays, lip-sync correct (Petr-confirmed), alsaloop ~0.5 % → ~0 % of one core
  (was 15–20 %), die 93 °C → 76–79 °C. **`--sync=simple`, not `--sync=samplerate`** —
  the device's `alsa-utils` is built without libsamplerate, so `--sync=samplerate` fails
  with `Loopback start failure`; `--sync=simple` uses the gadget's **Capture Pitch**
  control and works.
- **Volume re-plumbed (PA bypassed):** `nexusq-uac2-in` suspends PA's tas5713 sink (USB
  audio is now **EXCLUSIVE** — Spotify/AirPlay/Roon paused while on), enables the
  Speaker switch, sets a safe low Master (`NQ_UAC2_VOL`, 10 %), hands the amp back to PA
  on stop; `nq-vol` detects `alsaloop` and drives the TAS5713 **hardware** mixer so the
  ring still controls USB-audio volume. APKBUILD `pkgrel` 63→65, `depends += alsa-utils`.
  **Known minor:** the nexusqd LED visualizer taps the PA source → won't pulse to USB
  audio. Path: `pmos/device-google-steelhead/nexusq-uac2-in` (+ `.service`), `nq-vol`.
  Record: `docs/2026-08-08-usb-audio-playback-delay-and-ota-publish.md`.

### ✅ FIXED: System OTA "system update failed" — mkinitfs/boot-deploy trigger (2026-08-08, Option A)
The app's **System** update reported **"system update failed"** and `apk fix -s` showed
a **persistent pending `postmarketos-mkinitfs` trigger**: `boot-deploy` found
`No kernel found in /boot` because `/boot` was an empty plain dir on this ramdisk-less
device (kernel lives in the flashed boot partition). **Packages still installed**
(r63/r12 committed) — cosmetic + blocked a clean apk state. **Fixed via Option A** (put
the kernel payload in `/boot`) after confirming boot-deploy never writes a partition
(`flash_updated_boot_parts` gated on the unset `deviceinfo_flash_kernel_on_update`;
the boot.img it generates in `/boot` is inert): **live device** restored from the
`linux-google-steelhead-6.12.12-r46` apk → `apk fix -s` clean; **build** —
`docker-build.sh` Phase-10 now copies `$ROOTFS/boot/{vmlinuz,dtbs,System.map,config}`
into the exported rootfs (pending next-build verify). Real kernel OTA is still **Phase
2** (boot-partition p9 writer + recovery). Record:
`docs/2026-08-08-system-ota-mkinitfs-trigger-failure.md`.

### Carried forward, not root-caused
- **v1.9.0 onboarding pairing flake** — 1 run × 2 failed attempts; 3+ runs first-try
  since. Unexplained (has not recurred).
- **contactless-payment link UNPROVEN** — app 1.1.1 scoped its NFC claim, but the
  telemetry **never showed our uid toggling observe mode**. The fix may be correct;
  it is not demonstrated.
- **`NEXUSQ_NO_WIFI=1` build flag** — still promised-but-unwritten.
- **The Devices screen has had no design review** — functional test only; the copy is
  unreviewed and it has no Flutter tests of its own.

## Hardware Map

| Subsystem | Status | Detail |
|-----------|--------|--------|
| Kernel + boot | ✅ works | mainline 6.12.12, ≤8 MB image; flaky boot ~1 in 3 (retry helps). _(Updated 2026-06-28: now built with Alpine GCC 15.2 and boots — the old "GCC 13.3 only" no longer holds for the pmbootstrap path.)_ _(2026-07-30, v1.11.0: **fastboot is enterable over ssh** — `systemctl reboot --reboot-argument=bootloader` (kernel patch **0044** writes the stock reboot-reason to SAR RAM `0x4A326A0C`); no more mains power-cycle. Must be `systemctl`, not busybox `reboot`.)_ |
| HDMI video | ✅ works | omapdrm, framebuffer console |
| HDMI audio | 🟠 needs audio-EDID sink | _(Updated 2026-07-02)_ the ALSA card registers, but with no audio-capable EDID sink PulseAudio can't build a profile for `platform-omap-hdmi-audio.1.auto` (item U4). Speaker path (TAS5713) is the working audio output |
| eMMC + rootfs | ✅ works | postmarketOS (systemd variant) on userdata |
| WiFi (BCM4330) | ✅ works | _(Corrected 2026-07-02)_ the same-day "dead on the live unit" verdict was **wrong** — the DHCP **IP had moved** (NM randomized locally-administered MAC → fresh lease per boot; device was up at `192.168.20.142`). The v1.5.0 `mpc=0` fix cured the idle loss/latency. _(Characterized 2026-07-07: 5 GHz is **healthy, NOT flaky** — −48 dBm, 0 discarded/retry pkts, 2.6 ms jitter, 0 % loss; bulk **~34 Mbit/s is a HARDWARE CEILING** of the 2010-era 1×1 802.11n chip on SDIO, not a bug — same cipher does ~80 over ethernet so the crypto/CPU ceiling ≈80 and WiFi is the limit; 2 streams aggregate to less; `powersave=2` no change; ~100× the appliance's need. 2.4 GHz retested = also stable/not flaky but strictly worse (~13–16 Mbit). See `docs/2026-07-07-wifi-characterization-and-ethernet-default.md`.)_ _(Verified 2026-07-03 on `#27`:)_ `wifi-stable-mac.conf` holds — auto-joins the baked profile, stable IP `192.168.20.175` (on-air MAC = the chip's OTP `14:7d:c5:3a:35:b5`, not the factory `f8:8f:ca:20:48:e1` — _resolved in batch 2b, **verified on `#29` 2026-07-03**: NM `cloned-mac-address=F8:8F:CA:20:48:E1` pin, since brcmfmac ignores nvram `macaddr=`; the **factory MAC is on air** and the **final IP is `192.168.20.195`**_); the CLK32KG stock-parity clock fix + `CONFIG_CLK_TWL=y` retired the ~25 s pwrseq defer (B17 — pwrseq @4.31 s). clm_blob still missing (B4). `docs/2026-07-02-boot-error-inventory.md` _(2026-08-02: the long-uptime **5 GHz TX-dead wedge** — associated but 0 traffic, `brcmf_escan_timeout` flood, the BCM4330 failing in-firmware background roam scans — is FIXED by **`brcmfmac roamoff=1`** (device r56); the new **`nexusq-wifi-watchdog`** (device r57) gateway-pings + auto-bounces wlan0 and logged a **29 h clean run 2026-08-01**. The earlier "5 GHz TX degrades, open" verdict is retired.)_ |
| USB gadget network | ✅ works | RNDIS 172.16.42.1, SSH via nexus-diag.service. _(2026-07-07: demoted to FALLBACK — the direct-cable **ethernet path `10.42.0.2` is now the default** deploy/control transport: ~80 Mbit/s, 0.62 ms, fixed IP; the gadget's `enx*` renames per boot.)_ |
| **TAS5713 amplifier** | ✅ works | _(Updated 2026-07-07, v1.6.13/v1.6.15)_ sound card (ALSA card `NexusQSpeaker`, McBSP2 I2S → TAS5713) plays at **correct pitch/speed** (v1.6.0 2× bug fixed by patch 0022). **⚠️ physically SILENT until v1.6.13** — `mcbsp2_pins` muxed the wrong balls (`abe_dmic_*`), so the amp got no clock/data/frame (`aplay` rc=0); fixed to stock pads `0x0f6/0x0fa/0x0fc` MUX_MODE0 → user-confirmed audible. Since **v1.6.15** it is one selectable **PulseAudio** output (was direct ALSA); librespot feeds PA as an input. **Playback crackle diagnosed 2026-07-08** as **memory-bus / DMA contention** (McBSP2 SDMA FIFO underflows in HW under L3/EMIF contention — not a PA/CPU/network underrun). _(**CLOSED 2026-07-12:** two independent layers, both fixed — kernel **r41** patch 0041 (sDMA read priority; killed the load-correlated part) + **r42** patch 0042 (DPLL_ABE relocked from sys_clkin at 98.304 MHz — the metronomic ~1/s click was two free-running crystals). Hardware-verified, user-confirmed perfectly clean playback. See the 2026-07-12 note at the top + `docs/2026-07-12-audio-crackle-closed-sdma-priority-and-dpll-abe.md`.)_ See `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md` + `docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md` + `docs/2026-07-08-audio-crackle-dma-contention.md` |
| Bluetooth (BCM4330) | ✅ works | _(firmware corrected 2026-07-14; BD_ADDR/config 2026-07-06, v1.6.10)_ `hci0` up, `BCM4330B1.hcd` patchram loads every boot. **The BT firmware was the WRONG board blob (`Proxima - BCM4330B1 NoExtLNA`, build 0482, md5 `16db686…`) through v1.8.2 — replaced 2026-07-14 with the stock steelhead `Google Phantasm BCM4330B1` (build 0749, md5 `7e5bb859…`, 51813 B; firmware-google-steelhead r2).** **BD_ADDR is the real per-device `F8:8F:CA:20:49:E5`** (DTS `local-bd-address` + kernel patch 0036 teaching btbcm the `43:30:A0` placeholder) — was the non-unique, group-bit-set placeholder `43:30:A0:00:00:00`. The U5 `bluetoothd: Failed to set default system config` line is FIXED (bluez `main.conf [LE]` populated so the MGMT TLV is non-empty) — not the earlier "benign" |
| TWL6040 codec | ⚪ not populated/unused | _(Corrected 2026-07-03)_ **never a codec on this board**: stock 3.0.8 has ZERO twl6040/AUDPWRON code, the twldata codec pdata slot is NULL, stock i2c1 registers only `twl6030@0x48` — the 2026-06-10 "dead chip" verdict measured stock-correct behaviour (no chip to ACK at 0x4b). Node + ABE card + pins removed from the DTS, defconfig options off (shipped on `#29`, 2026-07-03). No headset path **by design**; audio = TAS5713 + HDMI. Was "🔴 dead hardware" |
| NFC (PN544) | ✅ WORKS | _(FIXED 2026-07-03 — was "🔴 dead hardware" 2026-07-02, then "🟠 under investigation")_ the chip was always healthy: our `nfc_pins` muxed the **wrong pads** (dpm_emu3/4/5 debug pads `0x1b4/0x1b6/0x1b8` instead of `usbb2_ulpitll_dat1/2/3` @ `0x16a/0x16c/0x16e`), so VEN/FW/IRQ never reached it. Proven by the stock RAM-boot test (ACK at 0x28, core-reset frame rc=0) + the live stock `omap_mux` dump (`reverse-eng/stock-omap-mux-full.txt`). Fixed in patch 0003 (kernel pkgrel 28), node re-enabled; on `#29`: `nfc_en polarity : active high` **clean**, `/sys/class/nfc/nfc0` present. **Tap-to-send shipped v1.7.0 (2026-07-08)** — reverse-HCE (Q = ISO-DEP reader, phone runs HCE), kernel patch 0037 RATS-activates any ISO-DEP target. See `docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md` + `docs/2026-07-08-nfc-tap-to-send-reverse-hce.md` |
| TMP101 temp sensor | ✅ works | _(Updated 2026-07-02)_ `lm75` autoloads, `hwmon0: sensor 'tmp101'` (though `temp1_input not attached to any thermal zone`) |
| LED ring (32× RGB) | ✅ works | mainline 6.12 driver `leds-steelhead-avr` (Plan 1, merged, auto-loads) + `nexusqd` daemon (Plan 2: idle glow, themes, CLI, autostart) -- behind `steelhead-avr` MCU (i2c `1-0020`). _(Updated 2026-07-01, v1.6.5:_ the ring **no longer goes dark after long idle** — the AVR fw starves without periodic frame commits; `nexusqd` now sends a 1 Hz keepalive re-commit. Color themes now **breathe** the hue (`nexusqd breathe R G B`) and the 5 music visualisations are app-selectable. See `docs/2026-07-01-led-ring-avr-starvation-keepalive.md` + `docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.) |
| Ethernet (LAN9500A) | ✅ works from cold | _(✅ FULLY FIXED 2026-07-06, task #17 CLOSED — was "🟠 enumeration intermittent" 2026-07-05, briefly "CLOSED" 2026-07-04, "🟠 sw bug", and a wrong "dead hardware" verdict)_ fixed in v1.1.0/v1.3.0 (patches 0006/0012), **regressed** in v1.4.0, enumeration+carrier **came back with batch 2b/`#29`** (2026-07-03), the "flap" was root-caused 2026-07-04 as **NM's serverless-DHCP retry loop** (fixed by baked eth0 NM profiles, device r21, v1.6.7: `no-auto-default=eth0` + `eth-lan` + `eth-direct` static + host `eth-direct-host`; `ssh root@10.42.0.2` works). The **enumeration** half was root-caused 2026-07-06 as a **pinmux miss**: `gpio_1` NENABLE = pad `kpd_col2` @ padconf `0x186`, which `ethernet_gpios` never muxed → gpiolib drove the DATAOUT latch (debugfs "asserted") but the pad stayed safe_mode → chip never powered → CCS=0 (the "0/3 vs 3/3" was stock priming, not a race). Fixed by the DTS pad mux (patch 0003, kernel `#33`, commit e33a1b4; 2500ms settle reverted as a false positive). **Gold-validated:** clean flash + true cold power-cycle → `eth0` 100Mbps/Full, 0 failed units. Ships v1.6.8. Caveat: no MAC EEPROM → random hw MAC per boot (LAN lease changes; pin a cloned MAC if needed). `docs/2026-07-06-eth-coldinit-resolved.md` (+ `docs/2026-07-04-ethernet-resolved-and-led-guard.md` for the NM half) |
| SMP (2nd core) | ✅ works | _(Updated 2026-06-28)_ dual-core since v1.2.0 — patch 0009 `dsb_sev()` in prepare + `cpuidle.off=1`; `nproc=2` re-confirmed live. See `docs/SMP-second-core.md` |

## Plan (by priority)

### 1. TAS5713 amplifier  ✅ DONE 2026-06-29 (v1.6.1 software) · physically AUDIBLE 2026-07-07 (v1.6.13)
The reason this device exists. **✅ speaker audio works at correct pitch/speed — the
v1.6.0 2× too-fast bug was root-caused and fixed (kernel patch 0022).**
> ⚠️ **Correction 2026-07-07:** the v1.6.1 "works" was **software-pipeline-only** — the
> physical amp was SILENT until v1.6.13 because `mcbsp2_pins` muxed the wrong balls
> (`abe_dmic_*`), leaving the real McBSP2 I2S balls in `safe_mode` (`aplay` rc=0 but no
> clock/data/frame). Fixed to stock pads `0x0f6/0x0fa/0x0fc` MUX_MODE0 → user-confirmed
> audible. See `docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md`.
- [x] DTS: `simple-audio-card` "NexusQ-Speaker" wiring McBSP2 → TAS5713
- [x] DTS: MCLK 12.288 MHz (dpll_per_m3x2 61.44 MHz → auxclk1 /5 → fref_clk1_out
      pad 0x19a); McBSP2 master (clkx/fsx pads OUTPUT), SRG from abe_24m_fclk
- [x] `snd-soc-omap-mcbsp` module enabled (=m) and probing
- [x] `speaker-test -D plughw:NexusQSpeaker` runs clean (rc=0, no dmesg errors)
- [x] **listening/timing test done 2026-06-29 — REVEALED A 2× SPEED BUG.** 10 s of
      `S16_LE` silence to `hw:1,0` plays in **5.00 s** (0.50× = 2× too fast, all
      rates). librespot/Spotify tracks therefore end in half real time and the player
      auto-skips ~40 s in. `func_mcbsp2_gfclk` reads 24.576 MHz (=512×48k, correct),
      so the ×2 is **downstream** (SRG divider / I2S frame width / TAS5713 MCLK
      16 vs 12.288 MHz — B7 family, `docs/2026-06-19-boot-warnings-followup.md`).
- [x] ✅ **FIXED the FSYNC 2× clock bug (kernel patch 0022, v1.6.1).** Root cause: with
      `simple-audio-card` mastering McBSP2, the generic card sets only `mclk-fs` and
      never calls `snd_soc_dai_set_clkdiv()`, so `omap-mcbsp` left `CLKGDV=0` (bit clock
      = the undivided 24.576 MHz fclk) and sized the frame as `in_freq/rate = 256` BCLK
      → **FSYNC = 96 kHz = 2× too fast**. The patch derives `CLKGDV` from the real fclk
      (`mcbsp->fclk`) + a minimal `wlen*channels` I2S frame, reproducing the factory
      registers (CLKGDV=15, BCLK 1.536 MHz, 32-BCLK frame, FSYNC 48 kHz). **Verified on
      hardware:** 60 s of audio plays in **60.00 s** (1.000×; was ~30 s = 0.50×). The
      "B7 TAS5713 MCLK 16 vs 12.288" lead was a **red herring** (mainline `tas571x` has
      no `.set_sysclk`, so MCLK never gates FSYNC). Cross-checked vs
      `reverse-eng/vmlinux.bin`. See `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.

### 2. Bluetooth  ✅ DONE 2026-06-10
- [x] firmware installed (BCM.hcd + BCM4330B1.hcd); loads automatically at boot
      ("Proxima - BCM4330B1 37.4 MHz Class 1.5" -- device-specific config)
- [x] scan finds devices; controller powered, name "Google Nexus Q"
- [ ] pair a BT keyboard when at hand (solves GUI input)

### 3. HDMI audio smoke test  🟠 blocked by monitor
- [x] tested 2026-06-10: ALSA opens fail with -22 because the Philips 190C
      (DVI-era panel) provides no audio EDID ("timeout reading edid").
      Retest against a real TV/AV receiver -- expected to work.

### 4. GUI: lightweight Wayland desktop (weston)  ✅ DONE 2026-06-19
Decision: device runs **primarily headless**; desktop is for occasional
debugging/ops on the HDMI port. Switched X11/XFCE → Wayland/weston so the
future SGX540 GPU path is viable (X11/glamor ES2 is the broken path on the SGX
blobs -- see docs/2026-06-19-gpu-sgx540-acceleration-research.md §5).
- [x] **was** XFCE4 + lightdm (2026-06-10, X11, llvmpipe). **Removed 2026-06-19**
      (`apk del postmarketos-ui-xfce4 lightdm`).
- [x] **now** `postmarketos-ui-weston` + `tinydm` (auto-login, no greeter).
      Reproducible: `docker-build.sh` `ui = weston`; device package ships
      `/etc/xdg/weston/weston.ini` + `weston-nexusq.desktop` session + a
      post-install that sets the default tinydm session.
- [x] **pixman** SW renderer forced (`[core] renderer=pixman` + explicit
      `--config`): lighter than GL-on-llvmpipe on the single A9. Idle bg #000F14.
- [x] headless-tolerant: `require-input=false` (DRM backend otherwise aborts
      with "failed to create input devices" -- no keyboard/mouse attached).
- [x] verified live on `192.168.20.179`: weston auto-starts on HDMI-A-1
      (1024x768@60), survives reboot, ~190 MB RAM.
- [~] input: a **BLE** mouse/keyboard (e.g. Logitech MX Master 4) pairs +
      bonds fine over the BCM4330, but delivers **no input** until the kernel
      has `CONFIG_UHID` — HID-over-GATT (HOGP) needs `/dev/uhid` to spawn the
      input device. Symptom without it: `Paired: yes`/`Connected: yes` yet
      bluetoothd loops `input-hog profile accept failed` and no `/dev/input/event*`
      appears. **Fixed in `steelhead_defconfig` (CONFIG_UHID=y + CONFIG_HIDRAW=y,
      2026-06-19) — pending a kernel rebuild + boot reflash.** `CONFIG_BT_HIDP=m`
      only covers Classic-BT HID, not BLE. The bond lives on the rootfs, so a
      boot-only reflash keeps it; the mouse will just connect once uhid is present.
      Alt: USB OTG mouse/Logi-Bolt receiver (sacrifices the gadget network).

### 5. TWL6040 codec  ⚪ NOT POPULATED — closed 2026-06-10 as "dead HW", CORRECTED 2026-07-03
- [x] root-caused: chip never ACKs on I2C 0x4b (-121/EREMOTEIO) with all
      inputs verified live: V1V8+V2V1 rails enabled, CLK32KG running,
      AUDPWRON (gpio_127) raised, bus healthy (TWL6030 ACKs on 0x48-0x4a).
      Second dead chip on this unit (with ethernet). Headset jack gone;
      TAS5713 speaker path and HDMI audio are unaffected.
- [x] sound + twl6040 nodes disabled in DTS -> clean boot, no deferred loop
- [x] **CORRECTION 2026-07-03: the verdict above was wrong in kind — the chip
      is simply unused/unpopulated on steelhead, not dead.** Stock 3.0.8 has
      ZERO twl6040/AUDPWRON code (whole-image string+symbol sweep), the twldata
      codec pdata slot is NULL (`steelhead_twldata+0x24` @ `0xc0719b30`), stock
      i2c1 board info registers only `twl6030@0x48`, and gpio_127 as AUDPWRON
      had no stock evidence. The missing ACK is stock-correct. Batch 2 (flashed
      2026-07-03 on `#29`) DELETES the node + ABE card + `twl6040_pins` from the DTS
      and drops TWL6040_CORE/SND_SOC_TWL6040/SND_SOC_OMAP_ABE_TWL6040/
      CLK_TWL6040 from the defconfig. Evidence:
      `docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §6.2.

### 6. NFC + temp sensor  ✅ (NFC FIXED 2026-07-03 — wrong pinmux pads)
- [x] TMP101: lm75 module added, binds, reads 41.75 °C on the board
- [x] PN544: NFC modules added (NFC_SHDLC=y was the missing dep), driver
      binds, `nfc0` registers. 🟠 "could not detect nfc_en polarity" warning
      -- chip health unverified until tested with an actual NFC tag
- [x] **CLOSED 2026-07-02: the PN544 is DEAD HARDWARE on this unit.** Live i2c
      probe: no ACK at 0x28 (or anywhere on i2c-2) with VEN high, low, or in
      fw-download mode; the driver's exact 6-byte core-reset frame NAKed —
      after first stock-verifying that our pins/polarity/timing MATCH
      (`nfc_gpios`: en=163 active-high, fw=162, irq=164; 20/60 ms VEN). DTS
      node `status = "disabled"` (flashed 2026-07-03; boot is clean of the
      polarity line). Same category as the TWL6040.
      See `docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §4.
- [ ] **RE-OPENED 2026-07-03: the "dead hardware" verdict is RETRACTED** (we
      never conclude dead hardware). The stock regulator audit proved stock has
      NO software power path for the PN544 (pdata = 3 gpios, zero regulator
      calls in `pn544_probe`; VBAT/PVDD hardwired) and our regulator state
      matches stock bit-for-bit → software parity COMPLETE, the no-ACK is
      **unexplained**. Next: NFC test under the stock RAM boot
      (`output/stock-adb-boot.img`), scheduled for the imminent flash cycle;
      then i2c timing/pads diff; VBAT pin measurement as last resort.
      See `docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §6.3.
- [x] **✅ FIXED 2026-07-03 — the stock RAM-boot test settled it: the chip is
      HEALTHY, our pinmux was WRONG.** `nfc_pins` muxed the dpm_emu3/4/5 debug
      pads (`0x1b4/0x1b6/0x1b8`); the real pads are `usbb2_ulpitll_dat1/2/3`
      (`0x16a/0x16c/0x16e` — from the live stock `omap_mux` dump,
      `reverse-eng/stock-omap-mux-full.txt`), so VEN/FW/IRQ never reached the
      chip and every mainline-side probe was meaningless. Under stock: ACK at
      0x28 with VEN high, core-reset frame accepted rc=0. Fixed in patch 0003
      (kernel pkgrel 28, "batch 2b"), `pn544@28` re-enabled; on `#29`:
      `nfc_en polarity : active high` clean, `nfc0` registered.
      See `docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md` +
      `docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §7.
- [x] **NFC tap-to-send SHIPPED 2026-07-08 (v1.7.0, device r33 / kernel r37).**
      The RF path is exercised end-to-end via **reverse-HCE** (the Q is the ISO-DEP
      reader, the phone runs a HostApduService): `nexusq-nfc-send` daemon pushes a
      text to the companion app on each tap. Enabler = kernel **patch 0037**
      (RATS-activate any ISO-DEP target, not just DESFire). neard is NOT installed —
      the daemon owns `nfc0`. See `docs/2026-07-08-nfc-tap-to-send-reverse-hce.md`.
      _(Deferred: ~~send IP/mDNS as the payload for tap-to-onboard~~ — **DONE
      2026-07-13** (commit `0307430`, device r44): the payload is now live
      connection-info JSON `{"v":1,"bt","host","ip","prov"}` rebuilt per tap,
      part of onboarding step 1 (**RELEASED as v1.9.0, 2026-07-15** — an NFC tap
      goes straight to pairing, the BT device list is only the no-NFC fallback — see
      `docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`);
      still deferred: C-rewrite the Python reader.)_

### 7. TOSLINK / SPDIF output (audio)  ✅ DONE 2026-07-07 (v1.6.13 kernel / v1.6.15 output)
Optical out is driven by the OMAP4's own McASP block -- fully independent of
the (absent) TWL6040 codec. `spdif_dit` node already exists in the DTS.
- [x] mainline support confirmed — `davinci-mcasp` already knows `ti,omap4-mcasp-audio`
      + DIT/IEC958; NO driver patch needed (defconfig `SND_SOC_DAVINCI_MCASP=m` +
      `SND_SOC_SPDIF=m`)
- [x] wired a second simple-audio-card `sound_spdif` (`NexusQ-SPDIF`): `&mcasp0` DIT →
      `spdif_dit`, new `mcasp_spdif_pins` (`0x0f8` MUX_MODE2, AXR0 out). Probe `-EINVAL`
      fixed with `format="i2s"` + mcasp bit/frame-master
- [x] a selectable PulseAudio output ("Optický výstup") since v1.6.15; PA pinned to
      48 kHz so the DIT locks (44.1 kHz → "off by 88435 PPM")
- [ ] listen-test into a real DAC / AV receiver (built · flash-verify pending)
- Payoff for a vinyl/music household: bit-perfect digital out into a hi-fi DAC.
  Full record: `docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md`

### 8. Flaky boot (research)
- [ ] needs UART serial console (requires opening the device / soldering)
- [ ] until then workaround: power-cycle again
- Candidates: U-Boot DRAM init, kernel early race

### 9. LED ring  ✅ DONE 2026-06-19 (driver + daemon)
The 32 RGB LEDs sit behind the steelhead-AVR MCU (i2c `1-0020`, DT node
`avr@20` compatible "google,steelhead-avr"). The AVR speaks a simple
register-write i2c protocol (from AOSP `drivers/misc/steelhead_avr_regs.h`):
  - 0x02 LED_MODE   (0x02 = HOST full control, 0x00 boot anim, 0x03 power-up)
  - 0x03 SET_ALL    payload R,G,B
  - 0x04 SET_RANGE  start, count, R,G,B...
  - 0x05 COMMIT     (0x00 immediate, 0x01 interpolate)
  - 0x06 SET_MUTE ; 0x07 GET_COUNT ; 0x08 HW_TYPE ; 0x09 HW_REV ; 0x0A FW_VER
- [x] verified from userspace via /dev/i2c-1 (no driver bound): AVR reports
      HW_TYPE=0x01 (SPHERE), LED count=32; "HOST mode + SET_ALL dim-blue +
      COMMIT" lit the whole ring blue. Reads work with plain write-then-read.
- [x] **driver (Plan 1):** mainline 6.12 `leds-steelhead-avr` — multicolor LED
      class for the 32 ring + mute, batch `frame` sysfs channel, mute/volume keys
      via threaded IRQ, AVR-reset restore. Merged to `main`, auto-loads at boot,
      validated live. Plan: `docs/superpowers/plans/2026-06-19-led-ring-kernel-driver.md`.
- [x] **daemon + CLI (Plan 2):** `nexusqd` (C11/musl) — idle glow, theme palettes,
      `/run/nexusqd.sock` control + `nexusled` CLI, mute key, postmarketOS aport,
      systemd autostart (verified across reboot). `userspace/nexusqd/`, `pmos/nexusqd/`.
      Plan: `docs/superpowers/plans/2026-06-19-nexusqd-daemon.md`.
- [x] **Plan 2b (done 2026-06-19):** pixel-perfect volume-ring + mute + true idle
      `#000F14` in the priority-10 reaction-layer seam (exact algo in
      `docs/2026-06-19-volume-mute-RE.md`). Verified live: fade-in + brightness levels +
      mute LED (#001E28/#006B8E) + idle #000F14. Volume ring is a rotary encoder (evtest).
- [x] **Plan 3 idle screensaver (done 2026-06-19):** pixel-perfect port of the factory
      ICS ParticleScreensaver LED path (RE'd from the tungsten-ian67k factory image →
      deodexed Visualizer.odex; `docs/2026-06-19-particle-screensaver-RE.md`). The ring
      breathes a uniform `#0099CC × A` (#000F14 ↔ #007AA3, 10 s cosine), 5 s fade-in,
      locks dim after 300 s without audio, blanks after 600 s. Compositor layer priority 5;
      `nexusled auto` resumes it after a manual override. Verified live (breathing + colors).
- [x] **Plan 3b music-reactive (done 2026-06-20):** all 5 scenes (Waveform/WaveformSolid/
      Circles/PointMorph/StarField) + AudioCapture/FFT/BeatProcessor ported pixel-perfect from
      the decompiled `Visualizer.apk` and wired into `nexusqd` (audio tap = arecord).
      Verified live: a track drives the ring.
      RE: `docs/2026-06-19-music-effects-RE.md`. _(Since **v1.6.15** the tap reads the
      active output's **PulseAudio monitor** — `arecord -D pulse`, follows output
      selection — instead of the snd-aloop loopback, plus an **AGC** so the ring reacts
      to the music at any listening volume; see
      `docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md`.)_
- [x] **Spotify Connect (librespot) baked into the build 2026-06-29 (v1.6.1)** —
      `librespot 0.8.0` (libmdns backend) advertises "Nexus Q"; phone discovers,
      authenticates and streams over **5 GHz** WiFi (the 2.4 GHz bulk stall no longer
      blocks it). `device-google-steelhead` (pkgrel 11) `depends librespot` and ships
      the enabled `librespot.service`, the `nexusq` ALSA PCM (`asound.conf`, forced
      48 kHz, by card NAME) and `60_spotify.nft` (wlan UDP 5353 + TCP 37879) — survives
      a flash. Audio is now at correct pitch (the §1 2× bug is fixed).
      See `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.
- [x] **LED follow-on: drive the music-reactive scenes off the live Spotify stream
      ✅ DONE 2026-06-30 (v1.6.2).** Was blocked on WiFi + the audio tap; resolved by
      teeing the `nexusq` PCM to BOTH the speaker and the snd-aloop loopback (`multi` +
      `route`) and auto-loading snd-aloop (`/etc/modules-load.d/snd-aloop.conf`).
      nexusqd's `arecord` on `hw:Loopback,1` now sees the playback and the ring reacts.
      Verified live (ring pulses to Spotify, no ALSA/xrun, NRestarts=0).
      `device-google-steelhead` pkgrel 12. See `CHANGELOG.md`.
- [x] **Idle AVR keepalive ✅ DONE 2026-07-01 (v1.6.5).** The ring went dark after a long
      idle (~20 h): the `steelhead-avr` fw starves without periodic frame *commits*, and
      `nexusqd`'s `memcmp(pk,lastpk)` write-gate suppressed all commits once the idle
      screensaver locked (`SS_LOCK_S=300 s`, `ledAlpha` constant `0.1`) / blanked
      (`SS_BLANK_S=600 s`) to a static frame. Fix: re-commit the current frame every
      `AVR_KEEPALIVE_S=1.0 s` even when unchanged (`nexusqd` pkgrel 5; keepalive landed at
      r3). Not HW / not a commit-mode / not a regression. _(Deployed + running; overnight
      idle soak still pending to prove it never re-wedges.)_ See
      `docs/2026-07-01-led-ring-avr-starvation-keepalive.md`.
- [x] **Breathing color themes + app-selectable visualisations + app-mute LED ✅ DONE
      2026-07-01 (v1.6.5).** New `nexusqd breathe R G B` (`CTL_BREATHE`) drives the
      compositor **manual layer (priority 8)** with a `breathe` flag — pulsing the ring in
      the theme hue with the same throb as the idle screensaver, **always visible** (over the
      music visualizer / a blanked screensaver); a companion color theme maps to **just**
      `breathe R G B` (blue/warm/cool/rose/smoke/off). _(The earlier screensaver-retint
      approach — a `br/bg/bb` base color + `screensaver_set_color` — was reverted as invisible
      once the screensaver blanked / while music played.)_ Separately, the bridge exposes the
      existing 5 `scene 0..4` RenderEngine effects (waveform/waveformsolid/circles/pointmorph/
      starfield) via `setScene`/`listScenes` (→ `auto` + `scene N`) and the app gained a
      VISUALIZATION picker — breathing override (prio 8) and music visualisation (prio 7) are
      independent. And new `nexusqd muted 0|1` (`CTL_SETMUTED`) lights the same
      `apply_mute_led()` mute LED as the hardware key, driven from the bridge's volume/mute
      path. `nexusqd` pkgrel 5, `nexusq-control` pkgrel 4. See
      `docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.
- [ ] LED follow-ons (remaining): scene auto-cycling (FadeTransition not ported);
      ship the musl apk (currently a static binary deployed over USB); overnight idle
      soak to confirm the AVR-keepalive fix holds.

### 10. SMP / second core  ✅ DONE 2026-06-22 (v1.2.0)
- [x] root cause was **not** a U-Boot CPU1-state problem but two mainline gaps:
      a missing `dsb_sev()` in `omap4_smp_prepare_cpus` (patch 0009) + a secondary
      cpuidle panic (boot `cpuidle.off=1`). Both Cortex-A9 online, `nproc=2`,
      `taint=0`; re-confirmed live 2026-06-28. Full writeup `docs/SMP-second-core.md`.
- [x] **cpuidle C1 (WFI) restored 2026-07-02 — ✅ verified on device 2026-07-03:**
      patch 0024 registers a C1-only cpuidle driver on steelhead and
      `cpuidle.off=1` is dropped from the cmdline (it made `cpuidle_register()`
      log "failed to register cpuidle driver" every boot, item B13). On `#27`:
      `cpuidle/state0` = "C1 - CPUx ON, MPUSS ON", governor `menu`, no
      registration error.
- [ ] follow-on: deep idle C2+ — stock has C1–C4 but C2+ traps into the HS
      secure dispatcher (services 0x1c/0x1d/0x21); a dedicated future project.
      **BLOCKED on serial-console access (2026-07-06):** the code path is feasible
      (mainline has the OMAP4460 HS secure idle dispatcher) but the suspend-to-RAM
      de-risk step **HUNG on resume**, and there is **no serial console** on this
      device (fastboot + ssh + stock/our build only; pstore doesn't survive the
      DRAM re-init) to debug a resume hang blind. Deferred until serial exists —
      do NOT re-attempt C2+ blind.

### 11. Companion app + LAN control bridge  ✅ DONE 2026-06-30 (v1.6.3)
A modern phone/desktop remote for the Q + the on-device bridge it talks to — replacing
the dead 2012 Google "Nexus Q" companion (its Android@Home cloud was killed in 2013).
- [x] **RE'd the original Google companion app** to recover the control-RPC vocabulary
      (`setMasterVolume`/`getMasterMute`/`setBrightness`/`setTheme`/`getPlayState`) →
      drove the v1 protocol. `docs/2026-06-30-companion-app-RE.md`.
- [x] **v1 protocol** (`companion/PROTOCOL.md`) — line-delimited JSON over **TCP 45015**,
      mDNS **`_nexusq._tcp`**; methods getState, setVolume/adjustVolume/setMuted/
      toggleMute, setTheme/listThemes/**setBrightness**, getPlayState, getDeviceInfo;
      events on change. Trusted-LAN, no auth in v1.
- [x] **`nexusq-control` device bridge** (new noarch aport `pmos/nexusq-control`,
      `userspace/nexusq-control/`, pure Python3 stdlib). Fans out to: ALSA `nexusq_soft`
      softvol (volume), `nexusqd` `/run/nexusqd.sock` (theme/brightness), `librespot
      --onevent` hook (now-playing). Degrades gracefully when a backend is down.
- [x] **Software master volume** — `asound.conf` `nexusq_soft` softvol (control `NexusQ`)
      over the v1.6.2 tee; `librespot.service` uses `--device nexusq_soft --mixer alsa
      --alsa-mixer-control NexusQ --onevent` so Spotify-Connect + companion share one knob.
- [x] **`nexusqd brightness <0-255>`** — software ring-brightness scalar (no firmware change).
- [x] **Companion Flutter app** (`companion/app`) — sphere UI, animated LED ring, mDNS
      auto-discovery; volume + LED theme/brightness + now-playing. Built on the phone,
      **not** in the device image.
- [x] **Boot enablement (the hard part).** The bridge is enabled durably via a systemd
      **preset** `95-nexusq.preset` (an aport `/usr/lib` vendor wants and a bare `/etc`
      symlink were both stripped by the image build's `systemctl preset-all` +
      postmarketOS's `disable *` catch-all). Its unit carries **no `After=`** — an
      `After=nexusqd.service` formed a boot ordering cycle (`nexusq-control` → `nexusqd`
      → `multi-user.target` → `nexusq-control`) that systemd resolved by **deleting the
      bridge's start job**, so it was enabled but never auto-started; manual
      `systemctl start` took a different path and masked it. `device-google-steelhead`
      pkgrel 15; `nexusq-control` aport pkgrel 2; `nexusqd` pkgrel 2. Full finding +
      journal evidence: `docs/2026-07-01-companion-bridge-boot-enablement.md`.
- [x] **Verified live on hardware** (clean v1.6.3 flash): bridge `active`, answers all
      methods, volume works, LED visualizer still tracks playback, `systemctl
      is-system-running` = running.
- [x] **Reachable over WiFi ✅ DONE 2026-07-01 (v1.6.5).** The bridge was only reachable
      over the USB-gadget net — over WiFi (the app's normal path) it was firewalled off.
      New nftables drop-in `55_nexusq-control.nft` opens TCP 45015 on `wlan*` (mDNS reuses
      the UDP 5353 rule in `60_spotify.nft`); `device-google-steelhead` pkgrel 17. Verified
      live: `getState` answers over WiFi.
- [x] **`setScene`/`listScenes` + breathing themes + app-mute LED ✅ DONE 2026-07-01
      (v1.6.5).** `setTheme` now maps to **just** `breathe R G B` (a breathing override on the
      compositor manual layer, priority 8, always visible) instead of a solid fill; new
      `setScene`/`listScenes` picks one of the 5 music visualisations (`auto` + `scene 0..4`);
      `getState` gained a `scene` field; and the volume/mute path also sends `nexusqd muted
      0|1` so a companion mute lights the device mute LED. `nexusq-control` pkgrel 4,
      `nexusqd` pkgrel 5. The app gained a VISUALIZATION picker. See
      `docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.
- [x] **librespot softvol bootstrap ✅ DONE 2026-07-01 (v1.6.5).** librespot crash-looped on
      a fresh boot (`Could not find Alsa mixer control`) because the `NexusQ` softvol control
      is created lazily on first `nexusq_soft` PCM open (and recreated empty each boot) but
      librespot opens its mixer before the sink; `librespot.service` now bootstraps the
      control with `ExecStartPre=-… aplay -D nexusq_soft …` — also fixes companion volume.
      `device-google-steelhead` pkgrel 17.
- [ ] **follow-on (v1.6.6): unify app + hardware + desktop + Spotify volume/mute.** The
      companion volume/mute act on the ALSA `NexusQ` softvol (the Spotify/librespot stream) +
      the mute LED (`nexusqd muted 0|1`), but do **not** mirror to the **LXQt desktop taskbar**
      volume/mute icon. The physical keys emit `KEY_MUTE`/`KEY_VOLUME*` events the desktop
      catches (→ taskbar + desktop audio) and nexusqd reads (→ mute LED); the app path goes
      straight to the softvol, so app vs desktop can diverge. Investigate whether the desktop
      drives ALSA `Master` vs PulseAudio/PipeWire, and whether emitting `uinput` KEY events or
      driving the canonical control is cleaner. **Not done.**
- [ ] follow-on: transport (play/pause/next) — `unavailable` in v1 (librespot has no
      local transport API); a future backend (e.g. go-librespot HTTP) could fill it in.
