# Nexus Q PostmarketOS Port -- Agent Handoff Document

## Project Goal

Boot PostmarketOS (mainline Linux 6.12 LTS) on the Google Nexus Q ("steelhead"), an OMAP4460-based media streamer from 2012.

## Session 2026-07-13 (latest): **ONBOARDING STEP 1 IMPLEMENTED — 13/13 coding tasks, pushed (ae8f499..cb03cf7); Task 14 (build v1.9.0-rc1 → flash → HW acceptance → tag) continues on the LINUX machine**

Full write-up: `docs/2026-07-13-onboarding-step1-implementation.md`. Plan:
`docs/superpowers/plans/2026-07-13-onboarding-step1.md` (spec approved 2026-07-13).
**This was the last Windows session — the project moves to a Linux machine.**
Machine-local ledgers/memory do NOT transfer; everything needed is in this repo.

✅ **All 13 coding tasks executed end-to-end** (subagent-driven, per-task reviews
+ fix rounds + a final whole-branch review), 25 commits on `main`, **all pushed**:
- **nexusqd r9** — new `spin R G B` socket command: rotating-dot setup animation
  (`spinner.c`, host-tested; 30 ms cadence; manual layer, cleared by
  `auto`/`set`/`breathe`/`off`).
- **nexusq-control r9** — identity file **`/etc/nexusq/device.json`**
  (`load_identity`; name + room; mDNS TXT `room=`), new **`startSetupMode`**
  method (arms `/run/nexusq-setup.force` + starts nexusq-setupd; all failures
  map to `unavailable`); the librespot wrapper reads the Spotify name from
  device.json.
- **NEW package `nexusq-setupd` 0.1.0-r0** (`userspace/nexusq-setupd/` +
  `pmos/nexusq-setupd` aport + docker-build.sh Phase 7c3 staging + preset
  enable): **BT RFCOMM WiFi provisioning** — SetupCore state machine
  (getDeviceInfo/confirmColor/scanNetworks/setWifi/getNetworkState/setName/
  setTheme/finishSetup; error codes `wrong_password`/`not_found`/`timeout`;
  **psk never logged**, sanitized SubprocessError handling,
  validate-before-side-effects), BlueZ Profile1 transport (UUID
  `8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a`, channel 3, Just-Works agent,
  600 s idle timeout, crash-restart re-arm via the force flag),
  `ExecCondition=/usr/bin/nexusq-setup-needed`. Extra deps `py3-dbus` +
  `py3-gobject3` (setupd only; bridge/NFC stay stdlib). **23 host tests.**
- **nexusq-nfc-send** (device pkg **r44**) — the tap payload is now **live
  connection-info JSON** `{"v":1,"bt","host","ip","prov"}` rebuilt per tap —
  **closes the standing "NFC payload = connection info" backlog item**.
  ⚠️ Final-review critical catch: the unit's `NQ_NFC_MESSAGE` env override was
  **REMOVED** (`af2dec4`) — it overrides `build_payload()` entirely and would
  have dead-ended tap-to-onboard with the old static string (manual-test
  override only now, kept unset).
- **Companion app** — DeviceTap NFC parsing + routing, Kotlin BT RFCOMM channel
  (`nexusq/btsetup`), Dart BtSetupClient + **pairingColor parity** (shared
  vectors `companion/pairing-color-vectors.json`), stock-asset extraction
  pipeline (`scripts/extract-stock-assets.sh`; Google-copyright assets
  gitignored, `.keep` placeholders + icon fallbacks so fresh clones build),
  the **8-screen setup wizard** (welcome/cables/find/confirm-color/wifi/
  name-room/theme/outro with `q_outro.mp4`) + entry points (NFC tap routing in
  main.dart, "Set up new device" in ConnectGate). **14 Flutter tests, analyze
  clean.** Debug build **installed on the user's Pixel 9 Pro Fold**.
- **PROTOCOL.md §8 "Setup transport"** written (`379e59c`, incl. the Just-Works
  accepted-risk note); §7 updated for the dynamic payload; setupd README.
- **Build agent brief updated** (`afa3101`): nexusq-build MUST report live
  progress to main (phase transitions + 10-min heartbeats + immediate
  error/retry notices).

⚠️ **CRLF incident (durable, know this on Linux):** the Windows worktree was
CRLF (system `autocrlf=true`) which broke the dockerized build (the container
reads the worktree via the mount → "failed to source APKBUILD", nexusqd build
fail). **Committed blobs were NEVER poisoned** — verified byte-exact from a
Linux container; the earlier in-session "blob poisoning" claims were **msys
pipe-translation measurement artifacts** (never judge git-object bytes through
an msys pipe). Durable fix: repo-wide **`.gitattributes` forcing LF** + worktree
normalization (`cb03cf7`). On Linux after `git pull`: worktree is LF, nothing
else needed.

⚠️ **Windows-machine-only note:** repeated null-byte file corruption was found
outside the repo (Python stdlib, pub cache, Android SDK) — user should
chkdsk/SMART that machine. Unrelated to the repository.

### WHERE TO CONTINUE (Linux machine — plan Task 14, IN PROGRESS)

1. **`git pull`** — main at `cb03cf7`+.
2. **Build v1.9.0-rc1** via the standard dockerized pipeline. Pre-build:
   populate the `firmware/` overlay + `private/access` per the standard
   pre-build checklist (the v1.8.1 empty-overlay lesson). **Verification
   additions** on the mounted rootfs: `/usr/bin/nexusq-setupd` +
   `/usr/bin/nexusq-setup-needed` + `nexusq-setupd.service` + its
   `nexusq.preset` enable line; `py3-dbus` + `py3-gobject3` installed;
   `nexusq-nfc.service` **WITHOUT** `NQ_NFC_MESSAGE`;
   `/var/lib/systemd/linger/root` present.
3. **Flash** — the device was left in fastboot on 2026-07-13 (may need
   re-entering).
4. **HW acceptance = plan Task 14 Step 3** (6 numbered checks): baked-profile
   boot must NOT enter setup mode + diag sweep; `nmcli connection delete wifi`
   + reboot → setup mode incl. LED spin + discoverable; full wizard from the
   Pixel incl. a **deliberately wrong password**; NFC tap in both provisioned
   states; `startSetupMode` re-provisioning; final diag sweep. Final-review
   recommendation: exercise the fresh-boot path with the baked
   `wifi.nmconnection` REMOVED.
5. **Propose tag v1.9.0** (user approves; never tag unasked).

**Backlog (post-v1.9.0, final-review triage):** `bad_params` (PROTOCOL §3 doc)
vs `bad_request` (impl) naming unification; "add second device" entry point in
the connected app UI; Kotlin `bad_args` message polish; Dart `dispose()`
in-flight completers; `fakeAsync` timeout tests; `ACTION_DISCOVERY_FINISHED`
progress bar; nmcli psk-in-argv → keyfile hardening; `sendLine` write-lock.

---

## Session 2026-07-12→13: **v1.8.2 — idle power: the "hot idle" was an observer artifact; real fixes = conservative governor (kernel r43) + nq-healthd rewrite + root linger (device r40)**

Full write-up: `docs/2026-07-13-idle-power-governor-and-pid1-churn.md`.
State: **UNCOMMITTED working tree** (defconfig + both APKBUILDs + nq-healthd) —
the main session commits/tags v1.8.2 after user approval. _(Done later the same
day: committed as `1504ef3`, tagged **v1.8.2**.)_ Built, **flashed to the
device 2026-07-13**, acceptance sweep PASS (`nq-captures/20260713-102339/`).
Packages: `linux` r42 → **r43** (`#44-postmarketOS`, defconfig-only, 42 patches
unchanged), `device-google-steelhead` r38 → **r40** (**r39 burned**, see below).

✅ **Finding 1 — the ~74–76 °C "idle floor" was an OBSERVER ARTIFACT** (686 s
true-idle study on v1.8.1): any ssh/diag session pushes the die to 74–79 °C in
seconds (cooling constant ~10 s); the true unobserved floor is **~65–66 °C**.
Judge idle temp ONLY from an on-device self-logging capture with no live session.

✅ **Finding 2 — the real problem: 74 % of idle at ≥700 MHz/≥1203 mV** (350 MHz
only 25.6 %): ~1000 wakeups/s with ~1.1–1.4 ms dwell (twd tick 168/s, WiFi SDIO
29.5/s, AVR i2c 15.5/s, DISPC 4.9/s) × ondemand 20 ms sampling + `up_threshold=95`
→ jump-to-max 3.7×/s, a 17.5 trans/s sawtooth.

✅ **Finding 3 — pid 1 was the top userspace idle consumer (steady 3.4 %) — root
cause OURS (nq-healthd):** 5 systemctl execs per 5 s sample (each root systemctl
forces pid 1 to re-register its private-bus object tree); worse, 2 of the 5
queried `librespot.service` on the SYSTEM manager where it hasn't existed since
device r31 (user unit) → pid 1 loaded+GC'd a nonexistent unit every poll AND
**`ls_active`/`ls_restarts` were silently broken r31–r38** (librespot restart
detection dead). Second amplifier: every ssh login built + tore down
`user@0.service` (~7.5 s CPU per login; 31 logins that boot).

✅ **Governor A/B/C (8-min live windows, restored after): `conservative` WINS**
(350 MHz 51.5 %, 1.2 GHz 9.6 %, 4.16 trans/s, coolest avg 65.1 °C); tuned
ondemand `sampling_rate=100000`/`up_threshold=80`/`sdf=5` was a **REGRESSION**
(parks at high OPPs, 350 MHz 21 %); `powersave_bias=100` dithers (39.9 trans/s).
**Lesson: slower ondemand sampling does NOT tame microburst load — conservative's
gradual `freq_step` climb does.** (Re-reverses the v1.6.6 "back to ondemand"
defconfig call, which predates any residency measurement.)

🔧 **v1.8.2 fixes shipped:**
- defconfig `CONFIG_CPU_FREQ_DEFAULT_GOV_CONSERVATIVE=y` (ondemand still built) — kernel r43.
- **nq-healthd REWRITTEN process-first** (device r40): cached MainPID + /proc
  liveness per sample, ONE `systemctl show` (3 props) only on transitions;
  librespot queried on the uid-10000 USER manager. ⚠️ **GOTCHA that burned r39:**
  root cannot borrow the user's `XDG_RUNTIME_DIR` — systemd 261 refuses
  cross-user private-socket connections (`Operation not permitted, consider using
  --machine=<user>@.host`); the correct form is
  `systemctl -M user@ --user show …` (verified on-device). r39 shipped the broken
  form (`ls_active=unknown` again), caught by the post-flash sweep → r40 +
  rebuild + reflash.
- baked `/var/lib/systemd/linger/root` (root user manager resident — kills the
  per-login user@0 churn).

📈 **Measured payoff (542 s idle re-study, final v1.8.2):** 350 MHz 25.6→**56.7 %**,
1.2 GHz →**3.5 %**, ≥700 MHz 74→**43.3 %**, transitions 17.5→**4.25/s**, pid 1
3.4→**0.10 %**, idle temp avg 66.4→**65.8 °C**, idle **settles at 350 MHz** (was
~920 hover). Structural ~65 °C floor = C1-only MPUSS — unchanged, blocked on serial.

📋 **Acceptance PASS** (`nq-captures/20260713-102339/`): all v1.8.1
regressions-to-watch clean (DPLL_ABE 98.304 MHz, GCR `0x00011010`, WiFi `.184`,
BT 0 reassembly, dmesg err/warn EMPTY, 0 failed units); thermal peak 97.2 °C
bounded-load (known watch band). **NEW journal residual #4** (dispositioned in
`docs/2026-07-02-boot-error-inventory.md`): one-shot `NetworkManager:
sd-event.c:4488 assertion failed` at the RTC→NTP clock step — NM's vendored
libsystemd asserting on the huge CLOCK_REALTIME jump; NM continued fine.
External/upstream; real fix = backlog. **Artifacts**
(`output/nexusq-v1.8.2.sha256`): boot `1c589a70…977d0c` (5,545,984 B), sparse
`6538e0ba…ddb8a02` — flashed.

⚠️ **Durable lessons:** `timeout N sh -c "yes & yes & wait"` ORPHANS the yes
children — timeout each load process individually; healthd `dmesg_err` counts
info-level brcmfmac `clm_blob` lines (cosmetic refinement candidate); the
uid-10000 user manager is now the **#2 idle consumer at 1.28 %** (watch).

**Next:** commit + tag `v1.8.2` (main session, after user approval); HDMI desktop
idle policy (DPMS never blanks at the DRM level — DISPC awake forever; Todoist
p3); deep cpuidle C2+ (p4, BLOCKED on serial); watch `user@10000`; standing
backlog (NFC payload = connection info, thermal watch).

---

## Session 2026-07-12: **CRACKLE CLOSED — two independent layers, both fixed (kernel r41 sDMA priority + r42 DPLL_ABE sys_clkin); v1.8.1 FINAL — rebuilt on Ubuntu, flashed, acceptance 10/10**

Full write-up: `docs/2026-07-12-audio-crackle-closed-sdma-priority-and-dpll-abe.md`.
Commits: `fc7e280` (r41, patch 0041), `9f76754` (r42, patch 0042), `554175b`
(build-infra). Current kernel = **r42** (`#43-postmarketOS`, on device; r42
supersedes r41).

✅ **The playback crackle ("lupance") is CLOSED — it was TWO independent faults:**

1. **Layer A — load-correlated drops → sDMA HIGH read priority (r41, patch 0041).**
   `CCR_READ_PRIORITY` (BIT(6), defined-but-never-applied in
   `drivers/dma/ti/omap-dma.c`) set on the cyclic/audio channel + GCR
   `HI_THREAD_RESERVED=1`. **Verified live:** `GCR = 0x00011010`, active audio
   channel ch20 CCR bit6=1. After r41 the crackle became **load-INDEPENDENT**
   (ssh/scp no longer affected it) — that pivot is what isolated layer B.
2. **Layer B — metronomic ~1/s click = TWO FREE-RUNNING CRYSTALS (r42, patch 0042).**
   Mainline `clk-44xx.c` reparents `CM_ABE_PLL_REF_CLKSEL`
   (`abe_dpll_refclk_mux_ck`) to **sys_32k** for deep-idle PM (never entered here —
   C1-only), while TAS5713 MCLK (auxclk1 12.288 MHz) derives from DPLL_PER /
   **sys_clkin 38.4 MHz** → McBSP2 frame clock and amp MCLK drift at the crystals'
   relative ppm (~21 ppm ≈ 1 sample slip/s @ 48 kHz). Stock **x-loader AND
   bootloader** force the mux to SYS_CLK and lock DPLL_ABE at exactly **98.304 MHz**
   (M=64/N=24); the stock kernel never touches it — **our port was actively undoing
   the bootloader's correct setting**. Audit evidence: xloader `prcm_init` tail
   offsets `0x5c7c–0x5ca0` (`bic #1` on `0x4a30610c`), bootloader `0x1e0c–0x1e30`,
   `steelhead_init` `clk_set_parent` chain @ `0xc0016770`+ in
   `reverse-eng/vmlinux.bin`. Fix = DTS `assigned-clocks` on `&mcbsp2` (reparent
   mux → `sys_clkin_ck`, relock `dpll_abe_ck` 98304000). **Verified:** `clk_summary`
   shows the reparent + 98.304 MHz lock; **user-confirmed perfectly clean playback**
   (*"bez jedinyho zaskobrtnuti"*).

⚠️ **REPO GOTCHA (cost a build): editing `kernel/dts/omap4-steelhead.dts` alone is a
SILENT NO-OP.** The DTS enters the kernel tree **via `kernel/patches/`** (0003 +
follow-ups) — that is what the build scripts stage; `kernel/dts/` is the reference
copy. The first r42 build shipped the old DTB until the DTB verification caught it;
the change had to become **patch 0042**. Any DTS change → a patch + verify the
built DTB.

🔧 **Build-infra fixes (`554175b`, `scripts/build-kernel-boot.sh`):** apk picked by
**exact `pkgver-pkgrel`** from the staged APKBUILD (newest-glob grabbed a STALE
kernel apk); `ls | head` SIGPIPE (rc 141 under pipefail) removed; kernel found by
**globbing `vmlinuz*`** (newer postmarketos-installkernel names it
`vmlinuz-<kernelrelease>`).

🖥️ **Windows-host gotchas (durable):** MSYS/Git-Bash path mangling breaks the
docker run (`/src` → `C:/Program Files/Git/src`) — **launch via PowerShell**;
CRLF broke sed-parsed APKBUILD vars + the dos2unix whitelist —
`core.autocrlf=false` set machine-locally, worktree renormalized to LF.

📦 **Release state:** **v1.8.1 = kernel r42** (user decision; an intermediate
r41-only build of the same version passed the gate earlier that day but was
superseded and its artifacts overwritten). The first full flash (Windows build)
**shipped WITHOUT WiFi/BT firmware**: the Windows machine's gitignored
`./firmware/` overlay had never been populated, so `docker-build.sh` silently
packed the empty `firmware-google-steelhead` fallback (no `wlan0`,
`/lib/firmware/brcm/` empty). Overlay populated
(`cp private/firmware/{bcm4330.hcd,bcmdhd.cal} firmware/`) and **the FINAL
v1.8.1 image was rebuilt on Ubuntu the same evening** — full docker build exit 0,
ALL gates PASS (`Staged BCM4330 firmware` in the log, `/lib/firmware/brcm/`
complete incl. the `google,steelhead` aliases, kernel 6.12.12-r42
`#43-postmarketOS`, DTB decompiled from the packed boot.img carries the 0042
assigned-clocks, libpython CLEAN 3×, boot.img ramdisk-less 5,543,936 B, sparse
all-RAW 23 chunks round-trip-verified). **Flashed (fastboot boot + chunked
sparse userdata) and ACCEPTANCE-PASSED 10/10** via the full nexusq-diag sweep
(`nq-captures/20260712-233542/`): uname `#43`/r42; clock fix live
(abe_dpll_refclk_mux under sys_clkin, DPLL_ABE 98.304 MHz); sDMA GCR
`0x00011010` + audio ch CCR bit6=1; **WiFi RESTORED** (5 GHz associated, IP
**192.168.20.184** — lease moved from `.195` router-side despite the pinned
factory MAC `f8:8f:ca:20:48:e1` → **never hardcode the WiFi IP**); **BT
RESTORED** (`F8:8F:CA:20:49:E5`, 0 frame-reassembly); audio stack healthy
(TAS5713 default, 48 k, tsched=0, Speaker unity, idle-suspended); CPU 1.2 GHz +
VDD_MPU 1380 mV exact; thermal peak 96.7 °C no throttle (watch-item stands);
dmesg err/warn EMPTY; journal = only the 3 known externals; 0 failed units;
nexusqd/NFC/python3 healthy. **FINAL hashes** (`output/nexusq-v1.8.1.sha256`):
boot `6d55b348…d42157`, sparse `ec3d47a0…c748d`, raw `d4f1bba5…3d6f2e` — the
Windows-build hashes (boot `51748379…`) are SUPERSEDED (same r42 source,
byte-diff = rebuild).

**Next:** tag `v1.8.1` (main session — this closes the Todoist AI-handover
"finish v1.8.1 on Ubuntu"); user listening test on the final image (the crackle
fix was already user-confirmed on the earlier r42 boot); then the standing
backlog (deep cpuidle C2+ blocked on serial, NFC payload = connection info,
thermal watch).

---

## Session 2026-07-09: **Bluetooth A2DP FIXED (BT UART max-speed, kernel 0040) + crackle ISOLATED to the output path + v1.7.4 bake reverted → v1.8.0**

Full write-up: `docs/2026-07-09-bluetooth-uart-max-speed-and-crackle-isolation.md`.
Ships as **v1.8.0** (`linux` r39 → **r40**, `device-google-steelhead` **r38** — r38
reused from the burned v1.7.4, which was never committed/tagged).

✅ **Bluetooth A2DP now reliable — ROOT CAUSE = the BT HCI UART had no `max-speed`.**
The BCM4330 BT HCI runs over **UART2**; our DTS BT node had **no `max-speed`**, so
`hci_bcm` left `oper_speed=0` and **never synced the host UART to the baud the BCM4330
firmware operates at** → host/controller drift → a stream of `Bluetooth: hci0: Frame
reassembly failed (-84)` (EILSEQ), HCI command tx timeouts, a **phantom "Connected"**
state, and A2DP audio in **corrupt bursts** (~1 s then silence) until the phone
dropped the link (HCI reason `0x13`). Fix: kernel patch **`0040`** sets
`max-speed = <3000000>` (stock ran the BT UART at **3 Mbaud**; RTS/CTS already muxed in
`uart2_pins`). **VERIFIED live** (boot.img flash): reassembly failures **0** (was 26+),
controller addr correct unicast **F8:8F:CA:20:49:E5** (`local-bd-address` honoured),
pairing + A2DP stable, user-confirmed (*"bluetooth jede, perfektni prace"*). This was
**NOT** WiFi/BT coexistence and **NOT** HFP/SCO (both earlier wrong guesses) — it was
the real cause of every past "BT won't stay connected / wrong state" symptom. A2DP path:
`phone → BT → PulseAudio bluez_source (s24le/48 kHz, no resample) → looped to TAS5713`.

✅ **Crackle ISOLATED to the OUTPUT path.** Bringing up A2DP gave a second, independent
**input** (bypasses librespot + WiFi). Result: **A2DP crackles the SAME as librespot**
→ the fault is **NOT** app/librespot/WiFi, it is the shared **PA → TAS5713 → sDMA →
McBSP2** output path — directly confirming the 2026-07-08 bus/DMA-contention diagnosis.
**Outstanding fix (NOT done):** OMAP4 sDMA `HIGH_PRIORITY` (`CCR_READ_PRIORITY`, `BIT(6)`
in `drivers/dma/ti/omap-dma.c`, defined but never applied) on the McBSP2 cyclic channel.

✅ **v1.7.4 bake REVERTED to a safe subset** (device r38). REMOVED: the McBSP2 THRESHOLD
service (`nexusq-mcbsp-threshold.service` — garbled audio), the 600 ms buffer
(`60-nexusq-latency.conf` — rejected), the RT configs (`10-nexusq-rtprio.conf` +
`CPUSchedulingPolicy` on the user units — `214/SETSCHEDULER` crash-loop). KEPT:
**`tsched=0`** baked into `default.pa` via the apk **trigger** (device pkg now also
triggers on `/etc/pulse`), the **TAS5713 Speaker-unity pin**, and the **+24 dB ceiling**.

⚠️ **Maturity:** the **BT fix is verified live** (boot.img flash). The **full v1.8.0
rootfs image is BUILT + pending on-device verification** (the `tsched=0` bake + v1.7.4
revert live in the rootfs, so they need a full flash to confirm; a build runs in
parallel). The crackle root-cause (sDMA priority) is still the outstanding audio task.
_(As written 2026-07-09 — superseded: v1.8.0 was tagged 2026-07-10, and the crackle
was CLOSED 2026-07-12 by kernel r41 + r42; see the session above.)_

---

## Session 2026-07-08: **audio crackle "lupance" DIAGNOSED = memory-bus / DMA contention (live-only mitigations; NOTHING baked/committed)**

Follow-on to the volume session below. Full write-up:
`docs/2026-07-08-audio-crackle-dma-contention.md`.

⚠️ **Maturity — nothing here is shipped/baked/committed.** The tuning is
config-persistent on the *running rootfs* (survives reboot) but a **reflash wipes
it**; the root-cause fix is **not implemented**. The only committed+baked audio work
of the day is the volume/dial/boot-log change (commit `2634b45`, **v1.7.3 / device
r37**).

✅ **DIAGNOSED — the Spotify-playback crackle is bus/DMA contention.** The audio
SDMA that refills the **McBSP2 FIFO underflows in HARDWARE** when other bus masters
(WiFi SDIO, the USB-ethernet LAN9500A, memory-heavy tasks) contend on the L3/EMIF
interconnect. Proven: **0** PA XRUN / **0** dmesg underruns / low CPU / clean
librespot logs (not a PA-buffer/CPU/network problem); stopping the LED tap **and**
NFC didn't fix it; it worsens with **any** activity — even the operator's ssh over
**ethernet** (USB on this device) breaks it, so **not WiFi-specific** — and a
CPU+memory-bandwidth stress test made it "definitely worse". It is **below** the PA
buffer (DMA→FIFO is hardware-timed) and **below** thread scheduling (SDMA is a DMA
engine + hardirq; WiFi RX is softirq/NAPI, above all userspace SCHED_FIFO).
`cpu_dma_latency=0` didn't help → arbitration, not idle-retention latency.

🩹 **Live-only mitigations (config-persistent, NOT baked) → "dramatically better,
occasional glitch remaining":** (1) **`tsched=0`** in `/etc/pulse/default.pa` — the
biggest win (kills PA timer-scheduling periodic clicks, fixed ALSA fragments);
(2) **~400 ms PA buffer** (`/etc/pulse/daemon.conf.d/60-nexusq-latency.conf`:
`default-fragments=8`, `default-fragment-size-msec=50`; dome dial stays instant via
hardware volume; 683 ms + `soxr-mq` both tried & rejected); (3) **priority** — same
`60-*.conf` (`high-priority`, `nice-level=-11`, RT req) + a systemd drop-in
`/etc/systemd/system/user@10000.service.d/10-nexusq-rtprio.conf`
(`LimitRTPRIO=95`) so rtkit can grant RT. BUT PA's IO thread still only takes
high-priority, so it was manually promoted with **`chrt -f -p 55`** (librespot 45)
— **runtime-only, LOST on reboot**. After the user's hard-power reboot, `tsched=0` +
buffer + `nice -11` + RTPRIO limit survive; the RT `chrt` + `cpu_dma_latency` holder
are gone.

⚠️ **Operational:** the on-device stress used **unbounded `while :;`** CPU loops →
saturated both cores, starved sshd, locked out ssh on all transports → user
hard-powered the box. **Future device stress must be `timeout`-bounded + niced.**

⛔ **v1.7.4 bake attempt REGRESSED — the v1.7.4 artifact (device `r38`) is UNUSABLE,
DO NOT FLASH IT.** It baked the tuning but two items are broken: (a) McBSP2
`dma_op_mode=threshold` is **harmful** — "completely broken / interrupts exactly like
originally" with **0 PA/dmesg XRUN** (corruption, not underrun; matches the auditor's
channel-shift warning — threshold must NOT be used on this hardware; earlier "threshold
helped" was confounded by RT+WiFi-PM applied together); (b) **RT via systemd
`CPUSchedulingPolicy=rr` on the USER services crash-loops both** (`214/SETSCHEDULER …
Operation not permitted` → PA + librespot never start → **no audio**; user services
can't `SCHED_RR` even with `LimitRTPRIO=95` — needs `CAP_SYS_NICE`). The
`CPUSchedulingPolicy` lines were **removed from the repo** `pulseaudio.service` /
`librespot.service` (repo fixed) but the **v1.7.4 image still has them**. Keepers
(live-confirmed): `tsched=0`, **WiFi runtime-PM off**, **~400 ms** buffer (600 ms adds
LED-visualizer lag), RT via **`chrt`**. New clue: cold-boot first 1–2 s is broken then
"catches" → **librespot ramp-up** may be a separate contributor. Current live state
(v1.7.4 flashed then hand-tuned): `element` mode, `tsched=0`, 600 ms buffer, WiFi PM
off, **no RT** — audio works but still interrupts.

**Next:** (1) **Bluetooth A2DP sink as a DIAGNOSTIC** — play from the phone over BT
(bypasses librespot + WiFi) to localize the fault: BT clean → source path
(librespot/WiFi); BT also crackles → output path (PA→TAS5713→sDMA/McBSP2). Adapter
"Google Nexus Q" (BD F8:8F:CA:20:49:E5), A2DP endpoints registered; **pairing not yet
completing** (being debugged). (2) **The real fix — sDMA `HIGH_PRIORITY` kernel
patch**: set `CCR_READ_PRIORITY` (`BIT(6)`, `drivers/dma/ti/omap-dma.c` — defined but
never applied to any channel) on the McBSP2 (sig 32/tas5713) cyclic channel so audio
reads outrank SDIO/USB at the sDMA/L3 port (`omap4_data.rw_priority=true` already
enables the GCR path; only the per-channel bit is missing) — helps librespot AND BT AND
any player. (3) **Fix the device package**: remove/disable
`nexusq-mcbsp-threshold.service`, drop the 600 ms buffer to ~400 ms, and replace the
broken user-service RT with a **root promoter** (system service that `chrt`s the PA
`alsa-sink` + librespot threads — root can always set RT).

---

## Session 2026-07-08: **idle-CPU tap gating (v1.7.1, SHIPPED) + volume fix RESOLVED (v1.7.2 kernel + v1.7.3 path pin) + dial→app sync + boot-log cleanup**

Follow-on to the v1.7.0 NFC session below. Full analysis:
`docs/2026-07-08-audio-volume-scale-and-bootlog-cleanup.md`.

✅ **v1.7.1 — SHIPPED & VERIFIED on device: LED audio tap gated on playback.**
`nexusqd` **r8** (commit `af7fa0e`, dep `+pulseaudio-utils`). The visualizer tap
(`arecord -D pulse` on `tas5713.monitor`) was an uncorked PA source-output that held
the sink IDLE/clocked at silence → **~7 % idle CPU** (top idle-heat source). nexusqd
now polls `pactl list short sink-inputs` and runs arecord **only while a real stream
plays**; idle → arecord stopped → sink **SUSPENDED**. Gate = sink-input **count, not
level**. **Verified live:** idle arecord=0 / sink SUSPENDED / nexusqd 0 %; playback
arecord=1 / sink RUNNING; after playback re-gated → SUSPENDED. Idle CPU **~7 %→~1 %**.
Closes the AI-handover idle-temperature/performance task.

✅ **VOLUME RESOLVED — verified LIVE + user-confirmed ("this is good")**, baking into
**v1.7.3** (`device-google-steelhead` **r35** + `nexusq-control` **r8**; NOT yet
flashed as an image, NOT tagged). Kernel patch **0038** (v1.7.2, on device) shifted
the Master dB scale but **alone was insufficient**: on-device measurement showed PA
drives **BOTH** the TAS5713 Master (numid 1) **and** the per-channel Speaker (numid
2) — `analog-output-speaker.conf` marks both `volume = merge`, so PA **stacks** them
(+24 dB Master then +24 dB Speaker = **+48 dB at 100 %**; the shift made PA recruit
Speaker *sooner*). **Complete fix = 0038 + device r35 post-install** `sed`ing
`[Element Speaker] volume = merge → volume = zero` (pins Speaker at unity). PA now
drives **only** Master. **Measured live:** PA 20 % = −17.5 dB · 50 % = +6 dB
(comfortable, mid-dial) · 100 % = +24 dB (was +48); Speaker 0 dB throughout. Gain-cap
polish item CLOSED.

✅ **Dial→app volume sync (`nexusq-control` r8, v1.7.3, verified live):** bridge
`pa_watch_thread` runs `pactl subscribe`; the physical dome dial (`nq-vol`) and LXQt
applet now update the companion app slider (broadcasts `volumeChanged` only on a real
level/mute change, so LED-tap-gating sink state changes don't spam).

🚧 **v1.7.2 boot-log cleanup (kernel `linux` r37→r39, on device):** shdlc frame
hexdumps → `print_hex_dump_debug` (no-op here) kills ~200 "shdlc: .." lines/boot from
the continuous NFC poll; cmdline dropped `earlyprintk`+`ignore_loglevel`,
`loglevel=7`→`4` (ignore_loglevel was forcing all debug onto the HDMI console). Diag
boot scripts left verbose intentionally.

**Next:** audio crackle now diagnosed as **memory-bus / DMA contention** (see the
2026-07-08 crackle session at the very top) — two follow-ups: (1) a **kernel
audio-DMA-priority fix** (OMAP4 sDMA `HIGH_PRIORITY`/`DMA4_CCR`, L3/EMIF QoS,
omap-mcbsp FIFO+PM-QoS) so the McBSP2 FIFO wins bus arbitration under contention;
(2) **bake the live crackle tuning** (`tsched=0`, `60-nexusq-latency.conf`,
`10-nexusq-rtprio.conf`) into the device package **+ a permanent RT-thread-promotion
mechanism** (the manual `chrt` is runtime-only). Also still owed: flash v1.7.3 +
full diag sweep.

## Session 2026-07-08: **NFC tap-to-send — v1.7.0** (VERIFIED end-to-end on device)

✅ **v1.7.0 is the tagged release** — it bundles everything built-but-never-tagged
since **v1.6.10** (the audio v1.6.14–16 work, ethernet-default + desktop-audio fix
v1.6.12, the volume dial → PA v1.6.16, companion auto-reconnect) **plus the new
headline: NFC tap-to-send.** Package state: `device-google-steelhead` **r33**,
`linux` **r37** (37 patches — new pn544 RATS 0037), `nexusqd` **r7**,
`nexusq-control` **r7**, companion app with native HCE. Full record:
`docs/2026-07-08-nfc-tap-to-send-reverse-hce.md`.

**What it does:** tap the dome with your phone → the Q pushes a short UTF-8 text
to it over NFC, shown as a SnackBar in the companion app. Sends **once per tap**.

**Why it had to be reverse-HCE (the hard part):**
- The 2011 **PN544 cannot be a passive tag / host-card-emulate** — its
  card-emulation RF path routes only to a hardware Secure Element over SWP, which
  this device lacks (host CE arrived with PN547 + Android 4.4). And Google removed
  **Android Beam** (NFC P2P push) in Android 14. So "tap a bare phone, it reads the
  Q like a sticker" is impossible here; passive stickers were rejected.
- Working path: the **phone runs a HostApduService (HCE)**, the **Q is the ISO-DEP
  reader**, data flows Q→phone as APDUs. Needs the companion app installed + foreground.

**THE kernel fix (patch 0037, `linux` r37):** the mainline pn544 driver only sent
RATS (ISO 14443-4 layer-4 activation via `CONTINUE_ACTIVATION`) for Mifare DESFire
(`sens_res == 0x4403`); an Android HCE phone (**ATQA 0x0004 / SAK 0x20**) never
matched, so the reader transceived against a layer-3 target and the chip returned
`ANY_E_NOK` (phone entered card emulation but never got the SELECT APDU). Fix:
RATS-activate **any** ISO-DEP target (`target->sel_res & 0x20`), DESFire match kept
as belt-and-suspenders. This was THE missing piece.

**Device side (r33):** `/usr/bin/nexusq-nfc-send` — Python reverse-HCE reader
daemon (raw `PF_NFC` netlink poll on `nfc0` + ISO-DEP raw socket; **AID
`F0010203040506`**; SELECT + payload APDU `80 10 00 00 <Lc> <utf8>`) run by
`nexusq-nfc.service` (`NQ_NFC_LOOP=1`, `NQ_NFC_MESSAGE`, enabled in `nexusq.preset`).
**neard NOT installed** — the daemon owns the NFC device. Reader is a **prototype**.

**Companion (Flutter) side:** native Kotlin `NqHceService` (HostApduService, AID
`F0010203040506`, category `other`, **`android:shouldDefaultToObserveMode="false"`
— CRUCIAL on Android 15** which otherwise defaults HCE to observe-mode and won't
answer APDUs); `HceBridge` (persists via **`.commit()` NOT `apply()`** — apply lost
the message when the service was killed before the async flush); `MainActivity`
Event/MethodChannel + `setPreferredService` on resume; Dart `HceListener` SnackBar.
**VERIFIED trail:** `NqHceService: received text` → `HceBridge: post: persisted
(sink=true)` → `flutter: [HCE] show (messenger=true)` → user saw the SnackBar.

**Usage gotchas (durable):** tap **and hold steady ~5–10 s** (RATS NOKs if the
phone moves mid-activation); companion app **foreground**, **screen on**. Reader
dev/test: `systemctl stop neard` only if neard was live-installed (image has none).

**Build note:** the fast kernel path (`scripts/build-kernel-boot.sh`) got the
abuild-as-root fix (new Phase 6b2) so it no longer hangs at "Entering fakeroot…"
under `--no-cross` — same trap already fixed in `docker-build.sh`.

**Deferred / future (honest):**
1. **NFC payload is a static greeting** (`NQ_NFC_MESSAGE`). Next step: send the
   device's connection info (IP/mDNS) so the app could auto-connect (the original
   "tap to onboard" intent) — needs app-side parsing + mDNS re-discovery (also
   still owed to the app-reconnect path).
2. **Q-side reader is a Python prototype** — a C daemon would be cleaner for the image.
3. **Continuous NFC polling keeps the RF field active** (minor power/thermal);
   revisit if it matters.
4. **Audio polish** (from the v1.6.15 session below): the **volume gain-cap is
   RESOLVED** (kernel 0038 + device r35 Speaker-pin, verified live + user-confirmed —
   see the latest session at the top; no separate lower ceiling needed). **Speaker
   crackle / "lupance"** (McBSP2/TAS5713, from measurement) still open — the next task.

---

## Session 2026-07-07 (evening): **PA-centric audio system — v1.6.15** (BUILT, flash-verify PENDING)

✅ **BUILT 2026-07-07 and about to be flashed — each capability confirmed live
during bring-up; the final clean-flash acceptance sweep is still PENDING.**
Package delta: `device-google-steelhead` **r31**, `nexusq-control` **r6**,
`nexusqd` **r7**, `linux` **r36** (the v1.6.13 SPDIF/McBSP2 kernel, already
flashed as a test build). Full record:
`docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md`.

The design: multi-input → **PulseAudio hub** → app-selectable output, replacing
the old direct-ALSA `type multi` fan-out. Every input (librespot now; BT-A2DP /
Tidal / casting later) is a PA client; the active output (TAS5713 / SPDIF / HDMI)
is the PA default sink chosen from the companion app; the LED visualizer taps the
active output's monitor with an auto-gain stage.

**Kernel foundation (v1.6.13, `linux` r36, already flashed as a test build):**
- **MAJOR: the speaker (TAS5713) was SILENT the whole project — a wrong McBSP2
  pinmux, now fixed → it actually plays** (user-confirmed audible). `mcbsp2_pins`
  was muxing `0x110/0x114/0x116` = the `abe_dmic_*` balls, NOT McBSP2, so the real
  I2S balls sat in `safe_mode` and the amp got no clock/data/frame (`aplay` rc=0
  but nothing driven). Fixed to stock McBSP2 pads **`0x0f6` clkx / `0x0fa` dx /
  `0x0fc` fsx** MUX_MODE0 (confirmed vs `reverse-eng/stock-omap-mux-full.txt` +
  live pinctrl). **Recontextualizes all prior "TAS5713 works" claims as
  software-pipeline-only.**
- **SPDIF (optical) brought up** — no C driver work (mainline `davinci-mcasp`
  supports `ti,omap4-mcasp-audio` + DIT/IEC958). defconfig
  `SND_SOC_DAVINCI_MCASP=m` + `SND_SOC_SPDIF=m`; DTS `&mcasp0` okay + new
  `mcasp_spdif_pins` (`0x0f8` MUX_MODE2, AXR0 out) + new `sound_spdif`
  simple-audio-card (`NexusQ-SPDIF`, mcasp0 DIT ↔ `spdif_dit`). Probe `-EINVAL`
  (`snd_soc_dai_set_fmt -22`, fmt FORMAT field = 0) fixed via `format = "i2s"` +
  `bitclock`/`frame-master = <&spdif_cpu>` (folded in as `rc2`; DTB verified;
  pkgrel kept 36 so module vermagic matches the rootfs).

**PA-centric userspace (v1.6.15 — implemented + baked):**
- **librespot → PA (VERIFIED end-to-end).** Now a systemd USER unit (uid-10000)
  via wrapper `/usr/bin/librespot-nexusq` (`--backend alsa --device pulse` — 0.8.0
  has no native PA backend; `--zeroconf-interface <wlan0 IP>` — 0.8.0 ships only
  libmdns which otherwise advertised the usb0 gadget IP; `--ap-port 443`;
  `--disable-credential-cache`). avahi pinned to wlan0 (`allow-interfaces=wlan0`).
  Spotify Connect discoverable + connectable + plays into PA.
- **Output selection (VERIFIED end-to-end).** `nexusq-control` gained
  `listOutputs`/`setOutput` (+ `outputChanged`): `setOutput` = `pactl
  set-default-sink` + move all sink-inputs (input-agnostic) + amp Speaker
  on/off safety toggle + points PA default-source at the active sink's monitor.
  Volume/mute reworked amixer→pactl on the active sink; the root bridge reaches
  the user PA via `PULSE_SERVER`/`PULSE_COOKIE`. Flutter app got an OUTPUT selector
  (Holo-dark segmented control). App switch → device default sink + Speaker toggle.
- **SPDIF 48 kHz (VERIFIED).** `50-nexusq-48k.conf` pins PA to 48000 + resamples
  (McASP DIT + McBSP2 clock only the 48 kHz family cleanly; 44.1 kHz → "off by
  88435 PPM"). Both PA sinks report 48000 Hz on fresh boot.
- **LED visualizer re-tapped + AGC (VERIFIED live).** Tap moved off the dead
  snd-aloop loopback to a PA monitor source (nexusqd `arecord -D pulse` on the
  active sink's monitor — follows output selection) + an **AGC** (nexusqd r7,
  audiocap.c, `AGC_TARGET 0.15`) that normalizes the post-volume monitor level so
  the LED reacts to music at any volume. Steady `audio DETECTED vol=0.150`, no
  flicker (pre-AGC symptom was flickering visualizer↔breathing at low volume).
- **HDMI audio (unchanged):** real `omap-hdmi-audio`; PCM open `-EINVAL` only
  because the attached Philips 190C DVI monitor has a 128-byte EDID (no CEA ext,
  no audio). Joins the output list as `hdmi` once its PULSE_IGNORE rule is lifted
  against a real audio sink — UNTESTED.

**Deferred polish (NOT in v1.6.15 — need care/hardware):**
1. **Volume gain-cap** — TAS5713 amp is very hot (app ~8% ≈ deafening); bridge
   sends plain linear pactl % for now. Cap Master/Speaker gain to a usable SPL
   range; needs calibration with the user at a safe volume / reconnected speaker.
2. **Boot default output** — should be the speaker; PA picked spdif/sink0 on boot;
   ensure the speaker sink is boot-default and not muted.
3. **Speaker crackle** — the McBSP2/TAS5713 dropout heard when the speaker first
   became audible; the type-multi theory is now moot (tap moved to a monitor
   source). Re-diagnose from measurement (speaker safe-disconnected); check whether
   48 kHz already reduced it.

**Next steps:** (1) **flash-verify v1.6.15** — full clean-flash acceptance sweep;
(2) work the deferred polish list above; (3) multi-input roadmap (BT-A2DP / Tidal /
casting each join as another PA client — routing + LED tap already work).

**Gotcha:** `ss` is NOT installed on the device — use **`netstat`** (`-tlnp`) to
check listening sockets (caused a long misdiagnosis of "no listener").

---

## Session 2026-07-07: **Desktop audio sink fixed** (v1.6.12, device r29→r30)

The LXQt/labwc **Wayland** desktop showed a **red-cross (no-sink) audio tray
icon** — no sound. Diagnosed + fixed live 2026-07-07 (device pkg **r29→r30**,
verified across a reboot). Full note:
`docs/2026-07-07-desktop-audio-pulseaudio-fix.md`.

- **Layer 1 — PulseAudio never started.** Alpine's PA ships no systemd user unit;
  it relies on the XDG autostart `pulseaudio.desktop`
  (`start-pulseaudio-x11`, `X-GNOME-HiddenUnderSystemd=true`), which never fires
  under systemd + Wayland (`xdg-desktop-autostart.target` dead, .desktop hidden-
  under-systemd deferring to a native unit that didn't exist, `autospawn=no`). →
  no daemon → `/run/user/10000/pulse/native` missing → PA clients "Connection
  refused" → red cross. **Not** a PipeWire-owns-the-session issue (PW already
  suppressed). **Fix:** ship a native **`pulseaudio.service` systemd USER unit**
  (`pulseaudio --daemonize=no --log-target=stderr`, `ConditionUser=!root`,
  `Restart=on-failure`), enabled via a `default.target.wants/` symlink. NOT
  socket-activated (a `pulseaudio.socket` double-binds the native socket PA's own
  `default.pa` creates → "bind(): Address in use"); `--log-target=journal` is
  rejected by this Alpine build, `stderr` → journal via systemd.
- **Layer 2 — wrong default sink.** PA auto-loaded `module-alsa-card` for the
  snd-aloop **Loopback** (card index 0 on some boots) → made it the DEFAULT sink
  (audio into loopback plumbing, EBUSY risk vs librespot/tap). **Fix:** extend
  `91-pulseaudio-hdmi-ignore.rules` with a 2nd rule `KERNELS=="snd_aloop.0"`
  PULSE_IGNORE (platform-name match; card index is probe-order-unstable). PA's
  ONLY sink is now the **TAS5713 speaker** → deterministic default. Verified live:
  post-reboot PA `is-active`, sole sink
  `alsa_output.platform-sound-tas5713.stereo-fallback`, and it is the default.
- **Baked (device r30):** `pmos/device-google-steelhead/pulseaudio.service` (new),
  `91-pulseaudio-hdmi-ignore.rules` (2nd rule), `APKBUILD`
  (source/sha512sums/package + pkgrel 29→30).
- **Process lesson:** run the FULL `nexusq-diag` sweep after every flash + boot —
  this red-cross regression was caught only because the user noticed the tray
  icon; the post-flash check was too narrow (must include desktop audio: PA
  running + a real default sink).

⚠️ **Version note:** the ethernet-default work below was built + flashed as
**v1.6.11** for testing but never git-tagged/released. The next release is
**v1.6.12** and includes BOTH the ethernet-default change (device r29) AND this
audio fix (r30) → shipped delta over v1.6.10 is **r28→r30**.

---

## Session 2026-07-07: **WiFi characterized + ethernet is the default deploy path** (device r28→r29, built as v1.6.11 test → ships in v1.6.12)

Two findings, both measured live 2026-07-07 on the running **v1.6.10** image
(device pkg `r28`, kernel `#36`). No kernel change; the only baked delta is
`device-google-steelhead` **r28→r29** (three NM ethernet-profile tweaks, already
applied LIVE on the device). Built + flashed as v1.6.11 for testing (never
tagged) → ships in **v1.6.12**. Full note:
`docs/2026-07-07-wifi-characterization-and-ethernet-default.md`.

- **WiFi (BCM4330) — 5 GHz is HEALTHY, NOT flaky; the old "flaky" framing is
  RETIRED.** 5 GHz `Svatovitske-Internety-5g`: −48 dBm, link 62/70, **0**
  discarded/retry/frag pkts, jitter **2.6 ms / 6 ms max, 0 % loss**. Bulk
  **~34 Mbit/s is a HARDWARE CEILING** of the 2010-era 1×1 802.11n combo chip on
  SDIO (last fw Jan-2013, 5.90.195.114), not a bug — ruled out per-flow (2
  streams *aggregate* to ~29, less), crypto (same cipher does ~80 over ethernet →
  the A9 crypto ceiling ≈80, WiFi is the limit), power-save (`powersave=2` = no
  change) and SDIO (mmc4 already 50 MHz/4-bit, ~200 Mbit raw). ~100× the
  appliance's real need. 2.4 GHz retested: also **stable, not flaky** (0 % loss)
  but strictly worse — main AP is 802.11g-only (~14 Mbit); the chip *does* do
  2.4 GHz 11n (joined the `_EXT` mesh at 130 Mbit negotiated) but still only
  ~13–16 Mbit real (backhaul + congested ch6).
- **Ethernet is now the DEFAULT deploy/control path** (replaces the USB gadget).
  Measured 2026-07-07: **~80 Mbit/s, 0.62 ms, 0 % loss** — beats WiFi (~34) and
  the USB gadget (~64 crypto), and has a fixed name/IP (the gadget's `enx*`
  renames per boot). Direct cable: host `eth-direct-host` on `enp7s0`
  10.42.0.1/24 ↔ device `eth-direct` 10.42.0.2/24.
- **Config change (baked r29):** `eth-direct.nmconnection` is now
  **`autoconnect=true`** (was false) at `autoconnect-priority=5`,
  `autoconnect-retries=1`; `eth-lan.nmconnection` priority **5→10**,
  `dhcp-timeout` **30→10 s**. On a real LAN `eth-lan`'s DHCP wins; on the
  serverless direct cable `eth-lan` fails its one attempt (~10 s) and NM falls
  through to the static `eth-direct` → **10.42.0.2 comes up automatically, no
  manual `nmcli c up eth-direct`**. `scripts/diag/nqctl` now tries ethernet first
  (eth→usb→wifi) + gained an ssh-agent-independent `SSH_OPTS`. The
  `nexusq-connect` agent/skill briefs promote `eth-direct` to the #1 transport.
  ⚠️ eth0 hw MAC is still random per boot (no MAC EEPROM) → LAN lease/IP changes;
  the direct-cable static path is unaffected.
- **Next steps:** ship the v1.6.12 build (bakes r30 = ethernet r29 + audio) +
  reflash + git-tag it (v1.6.11 was a test build only); the standing
  PROJECTS (NFC tap-to-pair, deep cpuidle C2+ blocked on serial, thermal-headroom
  watch ~94–99 °C).

---

## Session 2026-07-06: **v1.6.10 — the boot log is GENUINELY clean (dmesg err/warn EMPTY)**

v1.6.9 still booted with **~15 err/warn lines**. v1.6.10 closes **all** of them —
every one root-caused and fixed with a REAL fix, plus two authorized exceptional
downgrades and two honestly-documented external lines. **Acceptance (clean
fastboot flash, device pkg `r28` / kernel pkgrel `35` / uname `#36`):
`dmesg -l err,warn` is EMPTY; `journalctl -b -p warning` = ONLY the 3
genuinely-external residuals below.** Kernel patches **0033–0036**, defconfig
(BPF/ACL/SYN), DTS (pmu/gpmc/BD_ADDR), device pkg r22→r28, new
`firmware-google-steelhead` (r1). boot.img grew **~0.3 MB** (the BPF core) → still
well under the 8 MB boot partition. A v1.6.10 PUBLIC build + release is in
progress separately (**no tag from here**). Full note:
`docs/2026-07-06-bootlog-cleanup.md` (rc1→rc5 arc); inventory closed out in
`docs/2026-07-02-boot-error-inventory.md`.

- **kernel/DTS:** `&pmu interrupt-affinity`; `&gpmc status=disabled` (no GPMC on
  steelhead); patch **0033** brcmfmac `firmware_request_nowarn` for the OPTIONAL
  clm/txcap blobs (BCM4330 CLM is in-firmware); patch **0034** drops the
  `HAVE_HW_BREAKPOINT` arch select (OMAP4460 HS = secure debug locked, monitor
  mode can never enable, stock didn't build it — zero functional loss); patch
  **0036** + DTS `local-bd-address=[e5 49 20 ca 8f f8]` gives the controller its
  real per-device **BD_ADDR `F8:8F:CA:20:49:E5`** (was the non-unique,
  group-bit-set placeholder `43:30:A0:00:00:00` — the DT alone didn't take,
  btbcm only knew the `43:30:B1` signature).
- **defconfig:** `CONFIG_EXT4_FS_POSIX_ACL=y` (journald ACL + per-user
  journalctl); **BPF enabled** (`BPF_SYSCALL`+`BPF_JIT`+`CGROUP_BPF`) — the
  whack-a-mole fix, see below; `CONFIG_SYN_COOKIES=y`.
- **firmware pkg (r1):** board-named brcmfmac symlinks so the device-specific
  `google,steelhead.bin` probe hits.
- **device pkg (r28):** PA client autospawn off; `50-dns-filter.sh` skipped on
  `lo` (NM marks loopback unmanaged); bluetooth `ConfigurationDirectoryMode=0755`;
  librespot `ExecStartPre` readiness gate (no busybox `timeout` orphan);
  bluetoothd `main.conf [LE]` populated so the MGMT system-config TLV is non-empty
  (the "Failed to set default system config" line was bluez logging a failure it
  never actually sent — corrects the v1.6.9 "benign" framing); `systemd-nsresourced`
  disabled (preset + post-install symlink removal — BPF-LSM not built, no
  unprivileged-userns use).
- **AUTHORIZED downgrade:** patch **0035** → L2C aux-modify notice to `pr_debug`.
  Linux legitimately enables L2 prefetch via the secure SMC over a ROM value that
  leaves it off; the readback delta IS the prefetch bits, otherwise unremovable
  without a perf regression (immutable stock bootloader). Register end-state
  identical to stock, exhaustively verified.
- **Whack-a-mole lesson:** the systemd `unit configures an IP firewall … does not
  support BPF/cgroup firewalling` notice fires **once for the FIRST unit** with
  `IPAddressDeny`, so silencing units one-by-one just moves it to the next unit.
  **Enable BPF or nothing** — BPF kills it for ALL units and makes
  `IPAddressDeny=any` functional hardening.
- **No-serial lesson (blocks deep cpuidle):** the only device paths are
  **fastboot + ssh + stock/our build** — **no serial console**. Deep cpuidle
  C2/C3 is code-feasible (mainline has the OMAP4460 HS secure idle dispatcher,
  services 0x1c/0x1d/0x21) but **BLOCKED**: the suspend-to-RAM de-risk HUNG on
  resume and debugging a resume hang blind (no console; pstore doesn't survive the
  DRAM re-init) is impractical. **Deferred until serial exists — do not re-attempt
  C2+ blind.**
- **The 3 genuinely-external residuals (honest, not cleanly fixable):**
  (1) **eth-lan DHCP fail** on a DHCP-less direct PC cable — environmental
  (`autoconnect=false` would break real-LAN plug-and-play); (2) **kscreen
  `.service` D-Bus naming** — upstream libkscreen packaging lint (hard dep via
  lxqt-config); (3) **avahi `No NSS support for mDNS`** — `nss-mdns` is not
  packaged in the pmOS/Alpine repos (avahi's publish path for librespot
  Spotify-Connect zeroconf works fine). Anything else on a future boot is a
  **regression**.
- **Thermal watch (active):** sustained dual-core load peaks **~94–99 °C** (below
  the 100 °C passive trip, no throttle) — thin headroom on the fanless sphere;
  keep reporting the peak in every diag.
- **Next steps / backlog (PROJECTS only — no boot-log items left):** NFC
  long-lived userspace (tap-to-pair), deep cpuidle C2+ (blocked on serial),
  the thermal-headroom watch.

---

## Session 2026-07-06: **v1.6.9 BOOT-LOG CLEANUP — the boot log is now clean**

The last two once-per-boot / per-ssh log-noise items on the (already clean)
v1.6.8 boot are fixed — all **cosmetic, no functional change**. Device pkg
**r23**, kernel **unchanged** `6.12.12-r32` (uname `#33`). A v1.6.9 PUBLIC build
+ release is in progress separately (no tag from here). Full note:
`docs/2026-07-06-bootlog-cleanup.md`; inventory update at the end of
`docs/2026-07-02-boot-error-inventory.md`.

- **gkr-pam `couldn't unlock the login keyring` (U6) — FIXED (commit e155ec9,
  r22):** `/etc/pam.d/base-auth`+`base-session` shadow the Alpine base to drop
  the desktop-keyring PAM lines. gnome-keyring stays installed (hard dep of
  nm-applet/gvfs/webkit); nothing here uses the user keyring;
  `pam_systemd`/`pam_rundir` (`XDG_RUNTIME_DIR`) preserved. Verified: **0 gkr
  lines across fresh logins, sessions register**.
- **PulseAudio `module-alsa-card` on omap-hdmi-audio (U4 half) — FIXED, r22 →
  r23:** a `PULSE_IGNORE` udev rule tells PA to skip the HDMI card (a
  dummy-DAI, not a usable sink — HDMI is desktop video only). **r22 pinned
  `KERNEL=="card1"` and was REJECTED in acceptance** — the ALSA card index is
  **probe-order dependent** (HDMI came up as card2 that boot), so it tagged the
  wrong card. **r23 (commit f4462a1)** matches the backing platform device
  `KERNELS=="omap-hdmi-audio.1.auto"` — index-independent. Verified: PULSE_IGNORE
  only on the HDMI card, **0 module-alsa-card errors**.
  - **Lesson:** ALSA card indices are probe-order dependent — a per-card udev
    rule (PULSE_IGNORE and similar) MUST match by backing device (`KERNELS=`) or
    card id, **never** by `cardN` index.
- **bluetoothd `Failed to set default system config for hci0` (U5) — left
  DOCUMENTED-BENIGN:** bluez sends the MGMT batch regardless of `main.conf` and
  the BCM4330B1 rejects it, but the controller initialises and works
  (`Powered: yes`) — no clean suppression.
- **Acceptance on r23 (clean fastboot flash) = ACCEPT:** 0 failed units, gkr=0,
  HDMI noise=0, ethernet cold-init works (100Mbps/Full), WiFi/NFC/CPU healthy,
  no new regression; residual err/warn = the known-benign set only. **Thermal
  watch:** SoC peaked ~98–99 °C under sustained dual-core load (below the 100 °C
  passive trip, no throttle) — thin thermal headroom, keep watching.
- **Next steps / backlog (PROJECTS only — no boot-log items left):** NFC
  long-lived userspace (tap-to-pair), deep cpuidle C2+ (HS secure dispatcher),
  the thermal-headroom watch.

---

## Session 2026-07-06: **ETHERNET COLD-INIT FIXED — task #17 FULLY CLOSED**, gold-validated; shipping as v1.6.8

The LAN9500A "enumeration intermittency" was **not a kernel/ehci race** — it was
a **pinmux miss** (same class as the NFC bug). `gpio_1` NENABLE (the LAN9500A
power-enable) is pad **`kpd_col2` @ CORE padconf `0x186`**, but the DTS
`ethernet_gpios` node muxed only `gpio_62` NRESET (`0x08c`); `0x186` was omitted
(a prior comment wrongly placed `gpio_1` in the wkup padconf). So gpiolib drove
the DATAOUT **latch** (debugfs read "asserted") while the pad stayed in
**safe_mode** → NENABLE never reached the chip → LAN9500A never powered → never
drove D+ → **PORTSC CCS=0** on every cold boot. The healthy USB3320 PHY (its
pads ARE muxed) masked it. The "3/3 vs 0/3 boots" was **stock priming**: those
passing boots all descended from a stock RAM boot via warm reboots that never
cut LAN9500A power, so the stock-initialized chip just stayed attached; a clean
flash / true cold boot without stock always failed.

- **Fix (commit `e33a1b4`, supersedes the premature `6c869e8`):** DTS
  `ethernet_gpios` += `OMAP4_IOPAD(0x186, PIN_OUTPUT | MUX_MODE3)` (patch 0003).
  Kernel pkgrel **32**, uname **`#33`**. Cleanup to stock parity: patch 0006
  power block reverted to `udelay(100)`/`udelay(2)` (the disproven
  200ms/50ms/2500ms delays dropped — the 2500ms "attach-ready settle" was the
  false positive `6c869e8` claimed as the fix); DTS drops the non-stock
  `gpio_159` (`0x164`) mux + `steelhead-eth-phy-reset-gpios` (stock leaves that
  pad safe_mode; not wired to the LAN9500A).
- **Proven three ways:** (a) live `mmio w 0x4A100184 0x0e03010f` + `ehci-omap`
  rebind from the cold-failed state → `eth0` 100Mbps/Full; (b) bidirectional
  causality (pad set→attach, cleared→detach); (c) **GOLD STANDARD** — a clean
  fastboot flash of `#33` + a **true cold power-cycle** → `eth0` enumerates
  **100Mbps/Full, 0 failed units** (clean-flash warm boot #1 too).
- **Task #17 is now FULLY CLOSED:** enumerate (this fix) + link + the NM
  serverless-DHCP-loop fix (r21, v1.6.7).
- **Method / lesson:** the device was left in the cold-FAILED state and probed
  live with the aligned `/root/mmio` helper + ULPI viewport reads (**never**
  python mmap — it wedges INSNREG05); the stock-parity-auditor found the pad miss
  by diffing `reverse-eng/stock-omap-mux-full.txt` (`kpd_col2` line 520 =
  `0x0e03`) against the DTS. **debugfs/gpiolib "asserted" only means the DATAOUT
  latch is driven — NOT that the pad is routed.** `eth0`'s hw MAC is random per
  boot (no MAC EEPROM) → LAN lease/IP changes; match by hostname.
- **Release:** a v1.6.8 PUBLIC build + release is in progress (handled
  separately). Full record: `docs/2026-07-06-eth-coldinit-resolved.md`.
- **Next steps:** the remaining standing items — PA HDMI-audio UCM, U6 gkr-pam,
  B4, B10, B16, B21, deep cpuidle C2+, NFC long-lived userspace.

---

## Session 2026-07-05: **v1.6.7 RELEASED + FLASHED** — #17 NARROWED (NM half fixed & shipped; LAN9500A enumeration intermittency is BACK) _(enumeration half FIXED 2026-07-06 — see the session above)_

**v1.6.7 was released and flashed 2026-07-05**
(<https://github.com/petronijus/nexusQ-reloaded/releases/tag/v1.6.7>; assets
`nexusq-boot-v1.6.7.img` + `nexusq-rootfs-v1.6.7-sparse.img.zst` +
`nexusq-v1.6.7.sha256`, post-verified). Clean `PUBLIC_RELEASE` build,
no-secrets preflight **rc=0** (the 958bc0a guard held — no `Staged` lines).
Content: device pkg **r21** (baked eth NM profiles + the `led_static` healthd
guard); kernel **unchanged** `6.12.12-r28` `#29` (boot.img byte-identical to
v1.6.6, md5 `12fba8987364226b2c60aaaf94650557`). **The device now runs the r21
image** — the 2026-07-04 hot-deploy is superseded, no regression window. Full
record: the 2026-07-05 addendum in
`docs/2026-07-04-ethernet-resolved-and-led-guard.md`.

- **Acceptance PASSED (3 boots):** zero failed units **every** boot,
  `NetworkManager-wait-online` green, `led_static` guard verified live (**33×
  info, zero false CRIT in 91 samples**), NFC clean probe, WiFi factory
  MAC / `192.168.20.195`, CPU/power nominal (1200 MHz @ 1380 mV exact, C1).
- **Task #17 NARROWED, not closed** (the 2026-07-04 "CLOSED" below
  over-claimed): the **NM retry-loop half IS fixed and shipped** — but the
  **LAN9500A enumeration intermittency is back**: **0/3 acceptance boots
  enumerated** (USB CCS=0; the 0006 `LAN9500A power-on-reset sequenced` init
  runs but the port never shows connect) vs **3/3 enumerated boots
  2026-07-03/04 on the byte-identical kernel**. NOT cpufreq (`ondemand` ran on
  the good boots too), NOT r21 (NM config only). #17 continues for the
  **kernel/ehci bring-up race** (patches 0006/0008/0012 area) only.
- **Graceful-degradation win:** with the chip absent, the baked profiles keep
  the boot clean — no auto-generated profile, no retry loop, no failed units —
  verified across all 3 boots. (`eth-direct` still works end-to-end on boots
  where the chip enumerates — verified 2026-07-04.)
- **Minor:** one residual `vdd_mismatch` sampling race — 1/91 samples slipped
  past the r20 freq-hold guard (warn-only; noted in `scripts/diag/README.md`).
- **Next steps:** the ehci **enumeration-race investigation** (task #17,
  patches 0006/0008/0012 area); NFC long-lived userspace (the session-kill
  fragility follow-up); PA HDMI-audio UCM; U6 gkr-pam; B4; B10; deep cpuidle
  C2+.

---

## Session 2026-07-04: **ETHERNET NM-LAYER RESOLVED** _(header originally said "task #17 CLOSED" — over-claim corrected 2026-07-05, see above: the enumeration half reopened)_ + led_frozen guard shipped (device r21, hot-deployed; v1.6.6 released)

**v1.6.6 was released 2026-07-04** (tag `v1.6.6` = the accepted `#29`/r20
image). This follow-up session closed both open items from the `#29`
acceptance. Everything verified on the live device; the tree carries device
pkg **r21 uncommitted** — the device still runs the r20 image with the r21
files **hot-deployed** (already in the APKBUILD, so the next rebuild+reflash
bakes them; no kernel change) _(as written 2026-07-04 — superseded: r21
committed, released as v1.6.7 and flashed 2026-07-05, see the session
above)_. Full record:
`docs/2026-07-04-ethernet-resolved-and-led-guard.md`.

- **ETHERNET RESOLVED** _(2026-07-05: the NM half of this stands; the
  enumeration half reopened — see the session above)_**.** The `#29` "partial
  comeback / carrier flap" is fully
  explained: the **LAN9500A/driver is fully healthy** (batch 2b revived it —
  NM detached: carrier held 90+ s with ZERO transitions, 100Mbps/Full, 0 rx/tx
  errors, under `ondemand`, which rules out the cpufreq-timing theory;
  autosuspend pinned by patch 0006; textbook boot enumeration). The "flap" was
  **NM's auto-generated "Wired connection 1" DHCP retry loop** on the
  serverless direct cable: 45 s DHCP timeout → deactivate resets the cloned
  "stable" MAC → the MAC write bounces the LAN9500A carrier → the carrier
  event resets NM's autoconnect-retries counter → reactivate. Self-arming,
  ~47 s period, **14 811 journal lines in 29 h**; also the
  `NetworkManager-wait-online` failure from the acceptance. TX/RX proven
  healthy (DISCOVERs captured on the host NIC; static-IP ping 0 % loss both
  ways). **Fix (device r21, hot-deployed + verified):**
  `eth-no-auto-default.conf` (`no-auto-default=eth0`) + `eth-lan.nmconnection`
  (DHCP, `dhcp-timeout=30`, `autoconnect-retries=1`,
  **`cloned-mac-address=permanent`** — the key: no MAC churn → no carrier
  bounce → the retry counter sticks) + `eth-direct.nmconnection` (static
  10.42.0.2/24 + 10.0.0.2/24, never-default, manual `nmcli c up eth-direct`).
  **Host side:** persistent NM profile **`eth-direct-host`** on petronijus-PC
  `enp7s0` (10.42.0.1/24 + 10.0.0.1/24, never-default, autoconnect) — the
  direct-cable workflow needs zero ad-hoc setup on either end. **Verified:**
  eth0 settles "disconnected" quietly (0 re-activations), carrier stable,
  **`nm-online -s` rc=0**, `nmcli c up eth-direct` → ping 3/3 (0.77 ms avg) →
  **`ssh root@10.42.0.2` works**. ⚠️ Caveat: eth0's hw MAC is **random per
  boot** (no MAC EEPROM) — on a real LAN the lease/IP changes per boot; pin a
  fixed cloned MAC in eth-lan if stable LAN identity is ever wanted.
- **`led_frozen` static-by-design guard SHIPPED.** `nq-healthd` (r21,
  hot-deployed + service restarted) emits crit `led_frozen` only when the
  frozen frame **co-fires with distress** (`nq_resp=0` or `nq_progress=0`); a
  static frame with a healthy daemon → **info `led_static`** (screensaver
  locks a static frame by design). `scripts/diag/nq-health-report` mirrors it
  (summary split into `led_frozen_events`/`led_static_events`).
  Regression-tested on the `nq-captures/20260703-144228/` capture: verdict
  **CRIT → OK**, `led_static … 25 occasion(s)`.
- **Next steps:** commit + rebuild/reflash to bake r21 _(done 2026-07-05 —
  released as v1.6.7 and flashed, see the session above)_; NFC tag-read test;
  then the standing B4/B10/B16/B21, U5 (watch), U6, U7, PA HDMI-audio UCM,
  deep cpuidle C2+.

---

## Session 2026-07-03 final: BATCH 2b FLASHED + ACCEPTED — **NFC IS FIXED AND WORKING** (kernel r28 `#29` + device r20)

The batch-2 image below was flashed and **accepted 2026-07-03** — with one
twist: the scheduled **stock RAM-boot NFC discrimination test** (step ② of the
pending checklist) found the real NFC bug BEFORE the flash, so patch 0003 was
regenerated once more and the kernel shipped at pkgrel **28** (uname
**`#29-postmarketOS`**, all 31 patches; the built-but-never-flashed pkgrel
27/`#28` was superseded). Device pkg stayed **r20**. The flashed image is the
**v1.6.6 release candidate — release pending Petr's go.** Full detail:
`docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md` + the inventory
doc's "BATCH 2b" section. Capture: `nq-captures/20260703-144228/`.

- **THE HEADLINE — NFC FIXED: the DTS muxed the WRONG PADS.** `nfc_pins` used
  IOPAD `0x1b4`/`0x1b6`/`0x1b8` (the **dpm_emu3/4/5 debug pads**); the real
  PN544 pads for gpio162/163/164 are **`usbb2_ulpitll_dat1/2/3` at
  `0x16a`/`0x16c`/`0x16e`**. Mainline drove the gpios correctly at the
  controller, but the pads were never muxed to GPIO → VEN/FW/IRQ never reached
  the chip → it looked electrically dead from every mainline-side probe. Found
  by the stock RAM boot (`fastboot boot output/stock-adb-boot.img` + musl
  i2c-tools over adb: **ACK at 0x28 with VEN high**, the exact 6-byte
  core-reset frame accepted rc=0, silent with VEN low, ACK in fw-mode) + the
  live **`omap_mux` debugfs dump from the working stock kernel**
  (`0x16a`/`0x16c` = `0x0003` OUTPUT|MODE3, `0x16e` = `0x011b`
  INPUT_PULLUP|MODE3; full dump preserved at
  `reverse-eng/stock-omap-mux-full.txt`, gitignored). Fix: `nfc_pins`
  corrected + `pn544@28` re-enabled (patch 0003, pkgrel 28). On `#29`:
  `NFC: nfc_en polarity : active high` — **clean, no fallback** —
  `/sys/class/nfc/nfc0` exists. Two wrong verdicts retracted on the way
  ("dead hardware" 2026-07-02 — it drove gpios into unmuxed pads; "software
  parity complete, suspect board-level" — the §4 audit compared logical pins,
  not IOPAD offsets). **Lesson: the stock RAM-boot discrimination test is the
  gold standard**; third win for never-conclude-dead-hardware (ethernet,
  TWL6040, NFC).
- **Acceptance `#29` PASSED:** uname `#29`, `nproc=2`; **B22 `twl: not
  initialized` count = 0** (patch 0030), **B23 gone** (0031); all batch-1 wins
  holding (no OUT-OF-RANGE / cpuidle / clkctrl ID>24 / deferred / PVDD / vbus
  / Alternate-GPT). CPU/power nominal: `ondemand`, **1200 MHz @ 1 380 000 µV
  exact**, C1 state0, 69.8 °C idle / 91.8 °C load peak. LED: frame bin_attr
  readable (0029), fingerprint changes while animating, `led_sum=4416` via
  `nq-healthd --once`. Audio: only pulseaudio; Loopback + NexusQSpeaker cards.
  Remaining err/warn = exactly the known-open residue (B4, B10, B16 cold-boot
  ramoops, B21, journald BPF/ACL).
- **WiFi: factory MAC `f8:8f:ca:20:48:e1` on air** (the NM pin works) —
  **NEW AND FINAL IP: `192.168.20.195`**; pwrseq @4.5 s.
- **NEW FINDING — ethernet PARTIAL COMEBACK (task #17 lead):** `eth0` has
  **carrier=1/operstate up for the first time since the v1.4.0 regression** —
  but the link **flaps** (`Link is Up` @74.5 s → `Link is Down` within ~1 s,
  repeating; NM disconnect/connect loop) and DHCP never completes, making
  `NetworkManager-wait-online.service` the ONE failed unit this boot. Likely a
  batch clock change revived enumeration. Follow-ups: root-cause the flap +
  ship an eth0 NM profile with **may-fail semantics** so wait-online tolerates
  a flapping/cable-less port.
- **OPEN — `led_frozen` needs a static-by-design guard:** the r20 fingerprint
  works, but the screensaver intentionally locks a static frame after ~300 s
  idle and the keepalive re-commits identical bytes → `led_frozen` CRIT fires
  on a healthy idle device (this acceptance capture's verdict=CRIT was exactly
  that; `nq_resp=1` throughout). Fix: only CRIT when `nq_resp=0` or
  `nexusqd_no_progress` co-fires (`nq-healthd` +
  `scripts/diag/nq-health-report`). Until then diagnostics must expect this
  false positive.
- **Next steps:** release **v1.6.6** (pending Petr), NFC tag-read test, the
  eth0 flap root-cause + may-fail profile, the led_frozen guard; then the
  standing B4/B10/B16/B21, U5 (watch), U6, U7, PA HDMI-UCM, deep cpuidle C2+.

---

## Session 2026-07-03 later: BATCH 2 BUILT (kernel `#28`, device r20) — was "awaiting flash" (superseded: shipped as batch 2b/`#29`, see above); TWL6040 + NFC verdicts corrected

Batch 2 of the boot-error cleanup is **implemented and built, NOT yet flashed**
— the device waits for a **manual fastboot power-cycle by Petr**. Kernel
`linux-google-steelhead` pkgrel 26→**27** (patches **0029–0031**; all 31 apply
GNU-patch-clean on pristine; next boot = uname **`#28-postmarketOS`**),
`device-google-steelhead` r19→**20**; all build gates green (incl. the
pinned-MAC `wifi.nmconnection`, verified by exact-string grep, and the sparse
all-RAW round-trip). Authoritative detail:
`docs/2026-07-02-boot-error-inventory.md` §"BATCH 2"; correction evidence:
`docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §6.

- **MAJOR CORRECTION 1 — TWL6040 was NEVER a "dead codec"; the chip is
  unused/unpopulated on steelhead.** Stock 3.0.8 has ZERO twl6040/AUDPWRON code
  (whole-image string+symbol sweep over `reverse-eng/vmlinux.bin`), the twldata
  codec pdata slot is NULL (`steelhead_twldata+0x24` @ `0xc0719b30`), stock
  i2c1 board info registers only `twl6030@0x48`, and the removed node's
  `ti,audpwron-gpio` (gpio_127) had no stock evidence. The 2026-06-10 "no ACK
  at 0x4b = dead chip" was measuring **stock-correct behaviour**. Actions:
  twl6040 node + ABE card + `twl6040_pins` DELETED from the DTS (comment left),
  defconfig TWL6040_CORE/SND_SOC_TWL6040/SND_SOC_OMAP_ABE_TWL6040/CLK_TWL6040
  off; DTB has zero twl6040 refs (verified in the binary).
- **MAJOR CORRECTION 2 — NFC "dead hardware" verdict RETRACTED** (never
  conclude dead hardware). The regulator audit closed the last software
  suspicion: stock has **no software power path** for the PN544 (pdata = 3
  gpios only, `pn544_probe` makes zero regulator calls; VBAT/PVDD ride
  hardwired rails), and the full stock `steelhead_twldata` regulator array
  matches our live mainline `regulator_summary` bit-for-bit (VAUX1 3.0 V
  always-on no-consumer, VAUX2/3 boot-off, VPP/VUSIM off, VANA/V2V1/VCXIO
  always-on, VMMC→hsmmc, VDAC→hdmi_vref, VUSB→twl usb, CLK32KG boot_on
  "clk32kaudio", CLK32KAUDIO NULL, + `regulator_has_full_constraints`).
  Software parity COMPLETE → the no-ACK is **unexplained**; status **"under
  investigation"**. Next discriminator: NFC under the **stock RAM boot**
  (`output/stock-adb-boot.img`; plan ready: unbind pn544 → gpio163 VEN high →
  `i2cdetect`/`i2ctransfer` 0x28 with pushed musl i2c-tools; stock has i2c-dev
  per kallsyms) — do it during the imminent flash cycle. DTS comment rewritten.
- **B22 fixed (patch 0030):** twl-core exports `twl_is_ready()`; `omap_twl.c`
  gates the SMPS_OFFSET read attempt + the 0014 retask poll on it; the retask
  work latches the real efuse once twl is up. The ×22 is fully accounted: per
  domain (IVA, CORE) 3 nonzero VC voltages ×2 attempts (uv_to_vsel reads once
  directly + once via its vsel_to_uv range check) + off ×1 + 2 VP limits ×2 =
  11, ×2 domains = 22 (+2 poll repeats).
- **B23 fixed (patch 0031):** twl-core `clocks_init()` gated to twl4030 class.
  **Negative finding:** the planned DTS fix (twl fck = sys_clkin) was REJECTED
  as actively harmful — on twl6030 the CFG_BOOT/PROTECT_KEY offsets resolve to
  unrelated Phoenix PM registers (absolute 0x24/0x2D next to PHOENIX_DEV_ON);
  no mainline twl6030 board wires fck; stock printed the same warning.
- **Both healthd bugs fixed (patch 0029 + device r20):** the
  `leds-steelhead-avr` `frame` bin_attr is now readable (0644) — previously the
  system had NO readable ring-state source — and nq-healthd fingerprints it
  (md5 + byte sum, brightness fallback for pre-0029 kernels); `vdd_mismatch` is
  evaluated only when `scaling_cur_freq` holds across the vdd read.
- **WiFi factory MAC (closes the open decision):** a live driver-reload test
  proved **brcmfmac/fw IGNORES nvram `macaddr=`** (OTP `14:7d:c5:3a:35:b5`
  wins) → NM-layer fix: the baked profile + `scripts/gen-wifi-profile.sh` pin
  `cloned-mac-address=F8:8F:CA:20:48:E1`. **After the flash the device appears
  under the factory MAC — new DHCP lease, the IP changes ONE FINAL time from
  `.175`** (match OPNsense leases by hostname `steelhead` or the factory MAC).
- **DTS also:** i2c1–4 scl/sda pads `PIN_INPUT_PULLUP`→`PIN_INPUT` (stock-exact,
  mux `0x100`, external pulls). Patch 0003 regenerated (842 lines).
- **PENDING (in order):** ① manual fastboot power-cycle → ② stock RAM-boot NFC
  discrimination test → ③ flash `#28` (boot + all-RAW userdata `-S 100M`) →
  ④ acceptance: B22/B23 lines gone, clean healthd capture (frame-attr ring
  fingerprint, no false vdd_mismatch), factory MAC on air, batch 1 still
  holding (9/10 classes gone, ondemand @ exact OPP voltages, root ssh, zero
  failed units). Then release **v1.6.6**.

## Session 2026-07-03: v1.6.6-candidate FLASHED — acceptance PASSED, 9/10 error classes gone

The 2026-07-02 fix batch (below) was built, **flashed and acceptance-verified
2026-07-03**: kernel `6.12.12 #27-postmarketOS` (pkgrel 26) +
`device-google-steelhead` **r19** (the 2026-07-02 writeups said r18; r19 is
what shipped) + baked access. Full per-item verification:
`docs/2026-07-02-boot-error-inventory.md` §"FLASH-VERIFIED 2026-07-03". Diag
capture `nq-captures/20260703-005812/`.

- **Baseline:** uname `#27-postmarketOS`, `nproc=2`, **zero failed units**,
  `python3` clean (all-RAW flash), LXQt session up.
- **9/10 targeted dmesg error classes GONE:** twl6030 OUT-OF-RANGE ×4 (B12),
  cpuidle registration error (B13 — C1-only driver registered:
  `cpuidle/state0` = "C1 - CPUx ON, MPUSS ON", governor menu), clkctrl
  "device ID is greater than 24" ×3 (B14), pn544 polarity (B15, node disabled),
  bcm4330-pwrseq ~25 s defer (B17 — now probes @4.31 s, mmc pwrseq @6.10 s),
  40132000 McPDM defer (B18), tas571x PVDD dummies ×4 (B19), hsusb1-phy vbus
  warning (B20), and **B8 Alternate-GPT — the on-disk fix SURVIVED the reboot**
  (no "Alternate GPT" line on the first boot with the new GPT).
- **Governor/power:** `ondemand`, `time_in_state` exists, **1200 MHz @
  1 380 000 µV** under load, idle 920 MHz @ 1 317 000 µV — exact OPP tracking.
  Thermal: idle 66–78 °C, **peak 91.8 °C** under dual-core load — only ~8 °C to
  the 100 °C trip; genuine but expected, worth watching.
- **Access baking works:** key-based `ssh root@` over BOTH gadget
  (`172.16.42.1`) and WiFi. WiFi auto-joined the baked 5 GHz profile — **new
  stable IP `192.168.20.175`**. NB: with `cloned-mac-address=permanent` the
  on-air MAC is the chip's **OTP `14:7d:c5:3a:35:b5`**, NOT the factory/bcmdhd
  `f8:8f:ca:20:48:e1` (brcmfmac never reads the factory-cal MAC; the nvram
  `macaddr=` is the Broadcom placeholder). Boot-stable. **Open decision:**
  optionally bake `macaddr=f8:8f:ca:20:48:e1` into `brcmfmac4330-sdio.txt` to
  restore the factory identity. _(Resolved later 2026-07-03, batch 2 — NOT via
  nvram: the driver ignores `macaddr=`; NM-layer `cloned-mac-address` pin.)_
- **Audio (U4):** only pulseaudio runs (pipewire/wireplumber absent from `ps` —
  the XDG override works), `snd_aloop` loaded, card `NexusQSpeaker` present.
- **Bluetooth:** up (BCM4330B1 patchram build 0482); the U5 bluetoothd MGMT
  error did NOT appear this boot (watching, not claiming fixed). BD_ADDR is the
  default-pattern `43:30:A0:00:00:00` — minor identity item.
- **Ethernet STILL dead** (LAN9500A never enumerates, PORTSC CCS=0) — the known
  v1.4.0 regression, task #17, unchanged.
- **NEW findings (opened):** **B22** — `twl: not initialized` **×22 burst
  @0.7797–0.7807 s**, right after patch 0013's `steelhead: vdd_mpu
  PMIC=TPS62361` print: the 0013/0014 init path hits twl_i2c before twl-core
  probes (different call site than the old ×4; top item for the next batch;
  +2 expected retask-poll repeats @2.86/3.47 s). **B23** — `Skipping twl
  internal clock init and using bootloader value (unknown osc rate)`, surfaced
  by `CLK_TWL=y`; planned fix: twl node `clocks = <&sys_clkin_ck>;
  clock-names = "fck"` (38.4 MHz).
- **nq-healthd tooling bugs (open** _as written; fixed later 2026-07-03 in
  batch 2 — patch 0029 + r20, awaiting flash;_ `pmos/device-google-steelhead/nq-healthd`**):**
  (a) `led_frozen` is a **permanent false CRIT** on nexusqd r5+ — healthd
  fingerprints led_classdev brightness but nexusqd commits via the write-only
  `frame` bin_attr, so `led_sum` is structurally 0; ignore `led_frozen` until
  fixed. (b) `vdd_mismatch` warnings come from non-atomic freq/vdd sampling —
  re-read freq after vdd.
- **Flash-procedure notes:** boot + `-S 100M` userdata (all-RAW sparse) took
  ~3 min (23 chunks, all OKAY); a reflash **regenerates the device ssh host
  key** → `ssh-keygen -R` the stale entries on the host.
- **Next steps:** fix the B22 twl burst + B23 twl fck; fix the two nq-healthd
  bugs; decide the WiFi factory-MAC bake; then **release v1.6.6**
  (`PUBLIC_RELEASE=1`). Ethernet (task #17) remains the standing regression.
  _→ ALL implemented + built later 2026-07-03 (batch 2, see the sessions above);
  flashed + accepted the same day as batch 2b/`#29` — NFC fixed en route._

---

## Session 2026-07-02: boot-error inventory root-caused + FIX BATCH IMPLEMENTED (patches 0023–0028, pkgrel 26/18) — flashed + verified 2026-07-03, see above

Morning: full dmesg + `journalctl -b -p err` sweep of `6.12.12 #26-postmarketOS`
(v1.6.5-era image, ~23 h uptime, **zero failed systemd units**) — inventory with
verbatim log lines in **`docs/2026-07-02-boot-error-inventory.md`** (B-IDs
continue `docs/2026-06-19-boot-warnings-followup.md`). Afternoon/evening: the
investigation **completed** and the whole fix batch was implemented —
stock-parity evidence in **`docs/2026-07-02-stock-parity-voltage-wifi-idle.md`**.
**Everything is in the working tree with a build running; NOTHING is flashed or
hardware-verified yet** _(as written 2026-07-02 — superseded: flashed +
verified 2026-07-03, see the session above)_. Kernel `linux-google-steelhead`
pkgrel **26** (next boot = uname `#27`), `device-google-steelhead` pkgrel
**18** (shipped as **19**), DTS patch 0003 regenerated (866 lines; DTB
compiled + decompile-verified).

- **CORRECTION — WiFi was NEVER dead.** The morning sweep declared WiFi dead
  (`192.168.20.179` unreachable); in fact the device was on WiFi the whole time
  at **`192.168.20.142`** — NetworkManager used a **randomized
  locally-administered MAC** (`8a:d8:d9:ac:c6:e5` vs hw `f8:8f:ca:20:48:e1`), so
  every boot pulled a fresh DHCP lease and the IP wandered. Fix baked
  (pkgrel 18): `wifi-stable-mac.conf` (`cloned-mac-address=permanent` + scan
  randomization off). **Until the new image is flashed the IP keeps moving** —
  find it in OPNsense leases by hostname `steelhead` (not by the hw MAC).
- **Fix batch (kernel patches 0023–0028 + defconfig + DTS):**
  - **B12** (twl6030 `OUT OF RANGE 1375000` ×4 + `twl: not initialized` ×4):
    patch **0023** — SMPS_OFFSET efuse read no longer latched-valid on failure,
    steelhead seeded with the live-read efuse (`0x7f`; `SMPS_MULT=0x52`); patch
    **0027** — stock-parity per-domain VC ON/ONLP voltages (MPU 1375000 /
    IVA 1188000 / CORE 1200000 µV — the ×4 was the IVA+CORE channels ×(on,onlp))
    + 4460 core VC channel VCORE3→VCORE1 (0x55/0x56; stock unmaps VCORE3).
  - **B13**: patch **0024** — C1-only cpuidle on steelhead, replaces
    `cpuidle.off=1` (dropped from CMDLINE). Stock has C1–C4; C2+ needs HS secure
    dispatcher services 0x1c/0x1d/0x21 — future project.
  - **B14**: patch **0025** — ti-sysc child clocks via `clkdev_add()` (kills the
    "device ID is greater than 24" ×3).
  - **B20**: patch **0026** — phy-generic optional vbus getter.
  - **B17**: `CONFIG_CLK_TWL=y` (the =m module deferred the bcm4330-pwrseq ~25 s
    for its 32k clock provider) + the **CLK32KG naming trap** fixed in the DTS
    (`<&twl 1>`→`<&twl 0>`: stock's "clk32kaudio" consumer string is wired to
    the CLK32KG regulator 0x8C — our old value gated the wrong pin, the BCM4330
    LPO never ran) + `clk-settle-delay-ms=300` (patch **0028**) matching stock's
    clk→300 ms→WLAN_EN→200 ms. Parity correctness — 5 GHz WiFi already worked
    well; no throughput promises.
  - **B18**: `omap4-mcpdm.dtsi` include dropped (pdmclk = dead TWL6040 →
    permanent deferred probe of 40132000). _(2026-07-03: "dead" corrected to
    "absent" — the TWL6040 is unpopulated/unused; the fix stands either way.)_
  - **B19**: `amp_pvdd` fixed regulator → PVDD_A..D (no voltage props — rail
    unmeasured, TAS5713 spec 8–26 V, driver only enables).
  - **B15 / NFC**: **chip proven electrically DEAD** by live i2c probe (no ACK
    at 0x28/anywhere on i2c-2 under VEN high/low/fw-download; the driver's exact
    6-byte core-reset frame NAKed; pins/polarity/timing stock-verified MATCH
    first) — DTS node `status = "disabled"`. Same category as the TWL6040.
    _(Both verdicts corrected 2026-07-03: NFC is "under investigation", NOT
    dead; the TWL6040 was never a dead chip — it's unused/unpopulated. See the
    latest session.)_
  - **governor**: defconfig back to **ondemand** + `CPU_FREQ_STAT=y` (the
    `conservative` default was the deliberate v1.5.0 change, rationale disproven
    2026-06-28).
  - **U4**: pipewire/wireplumber XDG-autostart `Hidden` overrides in
    `/etc/xdg/nexusq` (activated by an `XDG_CONFIG_DIRS` prepend in
    `nexusq-wayland.sh`) + orphaned `pipewire-pulse.socket` masked — PA is the
    pmOS backend, pipewire was only a library dep double-starting a second sound
    server; the socket had NO service package behind it (config topology, not
    masking a fault).
  - **Access baking**: docker-build.sh Phase 6 stages
    `private/access/authorized_keys` → `/root/.ssh` + `/etc/skel/.ssh` and
    `private/access/wifi.nmconnection` → NM system-connections (0600, empty
    files skipped). Keys exist (petronijus-PC ed25519); the WiFi profile comes
    from the NEW `scripts/gen-wifi-profile.sh` (PSK from 1Password at run time,
    output gitignored even in the private repo) — **not yet generated**, so this
    build bakes keys but no WiFi profile.
  - deps: `i2c-tools` + `gptfdisk` added (both needed live today).
- **B8 BLOCKED:** `sgdisk -e` **refused to write** — userdata p13 ends at the
  literal last sector (30777343), the 33-sector backup GPT cannot fit; nothing
  changed. Proper fix = shrink p13 by 33 sectors (mounted root — needs explicit
  approval).
- **RESOLVED from the old inventory** (absent this boot): B1 GPTIMER1 `-EBUSY`,
  B2 cpu-map WARN, B3 SRAM I688, B5 brcmfmac P2P, B6 EDID timeout, B7 TAS5713
  clocks, B9 vconsole-setup, B11 snd-aloop.
- **Still open:** U5 bluetoothd `MGMT_OP_SET_DEF_SYSTEM_CONFIG` (1 line), the PA
  HDMI-audio **UCM profile**, U6 gkr-pam attribution, U7 nsresourced bpf-lsm,
  B16 ramoops error, B21 minor batch, B4 clm_blob (+ the
  `brcmfmac4330-sdio.google,steelhead.bin` probe miss), B10 hw-breakpoint, deep
  cpuidle C2+ (secure dispatcher project); eth carrier=0 unchanged (v1.4.0
  regression, task #17). CPU+power healthy (1200 MHz, vdd_mpu 1380 mV tracks
  OPP, FBB engaged).
- **Next steps:** finish the build, generate the WiFi profile
  (`scripts/gen-wifi-profile.sh`), flash, verify: uname `#27`, no OUT-OF-RANGE /
  clkctrl / PVDD-dummy / vbus / McPDM-defer lines, cpuidle C1 registered,
  governor `ondemand`, WiFi up fast (<10 s) on the hw MAC with a stable IP,
  `root@` ssh works after a clean flash, no pipewire double-start.
  _→ ALL DONE 2026-07-03 (see the session above); one deviation: the stable
  WiFi MAC is the chip's OTP `14:7d:c5:3a:35:b5`, not the factory hw MAC._

---

## Session 2026-07-01: v1.6.5 shipped — LED keepalive + breathing themes + 5 visualisations + app-mute LED + librespot softvol fix + companion-over-WiFi

A batch of device-side fixes and companion features on the v1.6.3 image — released as a
single **v1.6.5**. (An interim **v1.6.4** was built + flashed internally to test the LED
keepalive but **never published**; it was folded into v1.6.5 along with the other items.
The 1.6.3 → 1.6.5 gap is intentional.) `boot.img` is **byte-identical** to
v1.6.2/v1.6.3 (kernel unchanged; md5 `36a3dec2c4a493710dffa18c4d796236`), so an
already-current device only needs the userdata reflash. Final pkgrels: `nexusqd` **r5**,
`nexusq-control` **r4**, `device-google-steelhead` **r17**. The companion APK is rebuilt +
reinstalled separately (not part of the device image). Full detail:
`docs/2026-07-01-led-ring-avr-starvation-keepalive.md` +
`docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.

- **librespot crash-loops on a fresh boot — FIXED (`device-google-steelhead` pkgrel 17).**
  The ALSA `NexusQ` **softvol** control (`asound.conf`) does not exist until the
  `nexusq_soft` PCM is first opened, and it is recreated empty each boot, but librespot
  opens its ALSA mixer control **before** the sink → exits `Could not find Alsa mixer
  control` and `Restart=on-failure` respawns it into the same state forever (a reboot never
  helps). Fix: `librespot.service` gained
  `ExecStartPre=-/bin/sh -c 'timeout 5 aplay -q -D nexusq_soft -f cd -d 1 /dev/zero'`, which
  opens `nexusq_soft` once (1 s silence) to create the control before librespot's mixer
  opens. Also fixes companion **volume** (the bridge's `amixer NexusQ set` needs that
  control to exist).
- **Color themes are now a BREATHING OVERRIDE, not a solid fill (`nexusqd` pkgrel 5,
  `nexusq-control` pkgrel 4).** New `nexusqd` control command **`breathe R G B`**
  (`CTL_BREATHE`, control.c/.h) drives the **compositor manual layer (priority 8)** via a
  new `breathe` flag (`struct manual_ctx`): `manual_render` pulses the ring in the theme hue
  with the **same throb envelope as the idle screensaver** (`screensaver_throb`,
  `A = 0.1 + 0.35*(1 - throb)`) but at priority 8 it is **always visible** — over the music
  visualizer and over a blanked/idle screensaver. This was the fix for "pick a color, ring
  stays dark". _(The earlier screensaver-retint approach — a `br/bg/bb` base color +
  `screensaver_set_color` — was **REVERTED**: it was invisible once the screensaver blanked
  or while music played. `screensaver.c/.h` no longer carry those.)_ A companion color theme
  maps (in the bridge) to **just** `breathe R G B` (no `auto`). Hues: blue (`#0099CC`) /
  warm (`#FF5A0A`) / cool (`#00C88C`) / rose (`#FF285A`) / smoke (`#6E7387`) / off;
  `spectrum`/`trackinfo` dropped.
- **5 music visualisations selectable from the app (`nexusq-control` pkgrel 4 + companion
  app).** `nexusqd` already had `scene 0..4` (waveform/waveformsolid/circles/pointmorph/
  starfield); the bridge gained `setScene`/`listScenes` (maps a name → `auto` + `scene N`)
  + a `scene` field in `getState`, and the Flutter app gained a separate **VISUALIZATION**
  picker (models.dart `kVisualizations`, device_controller.dart `setScene`, home_screen.dart
  section, mock_client.dart). A color theme (breathing override, priority 8) and a
  visualisation (music-reactive effect, priority 7) are now two **independent** controls.
- **App-mute now lights the device mute LED (`nexusqd` pkgrel 5, `nexusq-control`
  pkgrel 4).** New `nexusqd` command **`muted 0|1`** (`CTL_SETMUTED`) sets the mute state
  and calls the same `apply_mute_led()` (dim-teal `#001E28`/`#006B8E` AVR mute LED) the
  hardware mute key drives. The bridge's `setVolume`/`adjustVolume`/`setMuted`/`toggleMute`
  path now also sends `muted 0|1`, so a companion mute has a device-side ring indicator.
- **LED ring goes dark after long idle — root-caused + fixed (AVR keepalive, `nexusqd`
  pkgrel 5; the keepalive landed at r3, later rels add `breathe`/`muted`).** The
  `steelhead-avr` MCU firmware (fw `0x00`) **starves**: it stops lighting
  the ring if the host sends no frame *commit* for too long (a host-frame watchdog). The
  kernel driver `frame_write` (`kernel/drivers/leds-steelhead-avr.c`, sysfs
  `/sys/bus/i2c/devices/1-0020/frame`) sends `SET_RANGE` + `COMMIT` on **every** write, but
  `nexusqd` only wrote a frame when it **changed** (a `memcmp(pk, lastpk)` gate). The idle
  screensaver locks to a **static** frame at `SS_LOCK_S=300 s` (`ledAlpha` constant `0.1`,
  breathing stops) and blanks at `SS_BLANK_S=600 s` → frame stops changing → `memcmp`
  identical → no more commits → AVR starves → ring dark until `nexusqd` restarts
  (~20 h to manifest). **Not** HW (a direct sysfs write lights the ring), **not** a
  commit-mode issue (both `AVR_COMMIT_IMMEDIATE=0` and `AVR_COMMIT_INTERPOLATE=1` display
  fine at 1 write / 4 s), **not** a regression. Fix: re-commit the current frame every
  `AVR_KEEPALIVE_S=1.0 s` even when unchanged (`last_avr_push` var + `|| now-last_avr_push
  >= AVR_KEEPALIVE_S` in the write-gate). Zero cost during animation; idle adds ~1 cheap
  96-byte-payload i2c frame write/s. **Caveat:** mechanically deployed + running, but the
  "never wedges again" proof needs an **overnight idle soak** (the wedge took ~20 h).
- **Companion bridge reachable over WiFi** — new nftables drop-in
  `pmos/device-google-steelhead/55_nexusq-control.nft` opens **TCP 45015 on `wlan*`**
  (mDNS discovery reuses the UDP 5353 rule in `60_spotify.nft`). Previously the bridge was
  only reachable over the USB-gadget net; it had been live-patched but not baked.
  `device-google-steelhead` pkgrel 17.
- **Verified live** (clean flash of the internal v1.6.4 keepalive build): boots;
  `nexusqd 0.1.0-r3` (correct musl binary), `device-google-steelhead 1.0-r16` at that point;
  the bridge answers `getState` (returns the "Nexus Q" state) over WiFi on 45015; WiFi
  rejoined (`192.168.20.x`). The released **v1.6.5** ships `nexusqd 0.1.0-r5` +
  `nexusq-control 0.1.0-r4` + `device-google-steelhead 1.0-r17` with the other items above;
  the softvol/breathe/scene/mute-LED work is verified in the build (device flash-verification
  of those was still pending when this was written).

### Known limitation — deferred to v1.6.6: app/hardware/desktop/Spotify volume+mute are not unified
The companion volume + mute act on the ALSA **`NexusQ` softvol** (the Spotify/librespot
stream) and now the **mute LED** (via `nexusqd muted 0|1`), but do **not** mirror to the
**LXQt desktop taskbar** volume/mute icon. The physical mute/volume keys emit
`KEY_MUTE` / `KEY_VOLUME*` input events that the **desktop** catches (→ taskbar + desktop
audio) and `nexusqd` reads (→ mute LED); the **app** path goes straight to the softvol, so
the app and the desktop can **diverge**. Unifying app + hardware + desktop + Spotify onto
one canonical volume/mute control is a focused **v1.6.6** task — investigate whether the
desktop drives ALSA `Master` vs PulseAudio/PipeWire, and whether emitting `uinput` KEY
events or driving the canonical control is the cleaner approach. **Not done — do not claim
it is.**

---

## Session 2026-07-01: v1.6.3 shipped — companion app + nexusq-control LAN bridge

A **companion app** and its on-device **`nexusq-control` LAN bridge** now ship and are
**verified working on hardware** — released **v1.6.3** (CHANGELOG dated 2026-06-30; the
device-side build, flash and live verification, which surfaced + fixed the boot-ordering
cycle below, were done 2026-07-01). Branch `feat/companion-app` is **merged to main**
(`1844d98`). This **resolves the "HANDOVER 2026-06-30 → Linux: build the companion-bridge
image"** below. Full detail in `CHANGELOG.md` ([1.6.3]),
`docs/2026-06-30-companion-app-RE.md`, `companion/PROTOCOL.md`, and the boot-enablement
finding in `docs/2026-07-01-companion-bridge-boot-enablement.md`.

- **`nexusq-control`** — new noarch aport (`pmos/nexusq-control`, daemon
  `userspace/nexusq-control/`, pure Python3 stdlib). TCP **45015**, mDNS
  **`_nexusq._tcp`**, line-delimited JSON v1 protocol. Fans out to: ALSA softvol
  (volume), `nexusqd` `/run/nexusqd.sock` (LED theme/brightness), a `librespot
  --onevent` hook (now-playing). Methods: getState, setVolume/adjustVolume/setMuted/
  toggleMute, setTheme/listThemes/**setBrightness**, getPlayState, getDeviceInfo.
- **Software master volume** — `asound.conf` `nexusq_soft` softvol (control `NexusQ`)
  over the v1.6.2 tee; `librespot.service` now `--device nexusq_soft --mixer alsa
  --alsa-mixer-control NexusQ --onevent /usr/bin/nexusq-onevent` → one volume knob
  shared by Spotify-Connect + the companion, and the visualizer still tracks the output.
- **`nexusqd brightness <0-255>`** — new control command + software ring-brightness
  scalar (`nexusqd` pkgrel 2).
- **Companion app** (`companion/app`) — cross-platform **Flutter** remote (sphere UI,
  animated LED ring, mDNS auto-discovery; volume + LED theme/brightness + now-playing).
  Built on the phone, **not** in the device image.
- **The enablement fix (3 layers tried; the 3rd stuck) + the boot-cycle fix.** On a clean
  flash the image build kept stripping the unit's enable symlink:
  1. the aport's **`/usr/lib` vendor wants** → wiped by the build's `systemctl preset-all`;
  2. a **bare `/etc` wants symlink** (pkgrel 14) → wiped by postmarketOS's `disable *`
     catch-all;
  3. a **systemd preset `95-nexusq.preset`** (pkgrel 15) → **stuck** (preset-all enables it).
  But then it was *enabled yet never auto-started*: the unit's
  `After=network-online.target nexusqd.service sound.target` formed a boot ordering cycle
  (`nexusq-control` → `nexusqd` → `multi-user.target` → `nexusq-control`); systemd breaks
  cycles by **deleting a start job** and dropped `nexusq-control`. (Manual `systemctl
  start` took a different path, which masked the bug.) **Fix (r2):** the bridge degrades
  gracefully (binds `0.0.0.0`, lazy-reconnects to the sockets), so nexusqd/librespot are
  soft `Wants` only and the unit needs **no `After=`** — removed it. `nexusq-control`
  aport pkgrel 2, `device-google-steelhead` pkgrel 15.
- **Verified live** (clean v1.6.3 flash): `nexusq-control` auto-starts (`active`, no
  cycle), answers every protocol method, volume works (the `nexusq_soft` softvol over the
  tee), the LED visualizer still reacts to playback, `systemctl is-system-running` =
  running. **Transport (play/pause/next) is `unavailable` in v1 by design** (librespot has
  no local transport API).

---

## Session 2026-06-30: v1.6.2 shipped — LED music visualizer wired up (audio tee + snd-aloop)

The **LED music visualizer now reacts to Spotify playback** — released **v1.6.2**,
verified live on the device. v1.6.1 routed librespot straight to the TAS5713 speaker,
so nexusqd's snd-aloop audio tap got nothing and the ring stayed idle while music
played. Full detail in `CHANGELOG.md` ([1.6.2]).

- **Audio TEE feeds the visualizer.** The `nexusq` ALSA PCM (`asound.conf`) is now a
  tee (`type multi` + `type route`) that duplicates librespot's 48 kHz stereo to BOTH
  the TAS5713 speaker AND the snd-aloop loopback (`hw:Loopback,0`). nexusqd's existing
  `arecord` tap on `hw:Loopback,1` (48 kHz) drives the FFT/beat visualizer while the
  speaker plays. The **speaker is the timing master**; the loopback slave is `plughw`
  so it adapts to the cable rate and **never blocks playback** — the tee opens
  regardless of which side grabs the loopback first.
- **snd-aloop auto-loaded.** New `/etc/modules-load.d/snd-aloop.conf` loads the
  loopback (`CONFIG_SND_ALOOP=m`); without it the `Loopback` card doesn't exist and
  the tap can't open. `device-google-steelhead` pkgrel 12.
- **Verified live:** the LED ring pulses/animates to the music; no ALSA/xrun errors,
  no failed units, nexusqd/librespot `NRestarts=0`. This closes the long-standing
  "Spotify-driven visualizer blocked by WiFi + the snd-aloop B11 gap" item from
  `docs/2026-06-20-session-handoff.md`: WiFi works on 5 GHz, librespot ships,
  snd-aloop auto-loads, and the audio is teed to the loopback.

---

## HANDOVER 2026-06-30 → Linux (petronijus-PC): build the companion-bridge image  ✅ RESOLVED 2026-07-01

> **DONE — built, flashed and verified live; shipped as v1.6.3** (see the 2026-07-01
> session above). Branch `feat/companion-app` is **now merged to main** (`1844d98`).
> The build surfaced + fixed the boot-ordering cycle (unit `After=` deleted its start job)
> and the enablement-symlink stripping (resolved via the `95-nexusq.preset` systemd preset).
> Kept below as the original handover record.

Companion app + its device-side bridge are done on branch **`feat/companion-app`** (pushed,
14 commits, ~~NOT merged to main~~ **now merged — `1844d98`**). The **device-side build must be
done on Linux** (the dockerized pmbootstrap pipeline). The Flutter app itself runs on the phone
and is built separately — it is NOT in the device image.

**What this branch adds to the device image (all needs to land in the build):**
- `pmos/nexusq-control/` — new noarch aport: the `nexusq-control` LAN bridge (port 45015, mDNS
  `_nexusq._tcp`) + `nexusq-onevent` hook + systemd unit. (`userspace/nexusq-control/`.)
- `userspace/nexusqd/` — new **`brightness <0-255>`** control command + software ring-brightness
  scalar (control.h/control.c/nexusqd.c).
- `pmos/device-google-steelhead/` — `APKBUILD` now `depends nexusq-control`; **`asound.conf`**
  adds the `nexusq_soft` softvol PCM + `NexusQ` control; **`librespot.service`** now uses
  `--device nexusq_soft --mixer alsa --alsa-mixer-control NexusQ --onevent /usr/bin/nexusq-onevent`.
- `docker-build.sh` — Phase 2 validates the aport, Phase 6 stages `nexusq-control` into
  `$PMAPORTS/main/nexusq-control`, Phase 7c2 builds it (noarch).

**Build steps (on petronijus-PC / Ubuntu):**
1. `cd ~/Documents/Dev/nexusQ-reloaded && git fetch && git checkout feat/companion-app && git pull`
   (or merge the branch to main first, your call — building the branch directly is fine).
2. Ensure the **private overlay** is present (non-redistributable BT/WiFi firmware blobs):
   `private/` must hold `firmware/bcm4330.hcd` + `firmware/bcmdhd.cal` (clone
   `nexusQ-reloaded-private` into `private/`, see `private/README.md`). Run
   `scripts/setup-firmware.sh` if the build expects staged blobs.
3. Build the full image via the dockerized pipeline (`docker-build.sh`, or the **nexusq-build**
   skill). Watch for the two new build lines: `Installed: nexusq-control (...)` (Phase 6) and
   `nexusq-control build exit code: 0` (Phase 7c2). The build should also still build `nexusqd`.
4. **Flash** boot.img + rootfs in fastboot (INSTALL.md).

**Verify on the device after flash** (full checklist: `docs/2026-06-30-companion-hardware-bringup.md`):
```sh
systemctl status nexusqd nexusq-control librespot
amixer -c NexusQSpeaker scontrols | grep -i nexusq    # softvol control 'NexusQ' exists
ss -ltnp | grep 45015                                  # bridge listening
```
Then on the phone: `adb install -r companion/app/build/app/outputs/flutter-apk/app-debug.apk`
(non-mock build, auto-discovers via mDNS) — or `flutter run --dart-define=NEXUSQ_HOST=<ip>`.

**Confirm against real values** (likely needs a tweak once on hardware): the softvol control
name/card (defaults `NexusQ`/`NexusQSpeaker` — override via `NEXUSQ_MIXER_CTRL`/`NEXUSQ_MIXER_CARD`
in the unit), and the librespot `--onevent` env field names in `nexusq-onevent` (NAME/ARTISTS/
ALBUM/COVERS/VOLUME) against the installed librespot version. Transport (play/pause/next) is
`unavailable` in v1 by design.

Refs: `companion/PROTOCOL.md`, `docs/2026-06-30-companion-app-RE.md`,
`docs/2026-06-30-companion-design-language.md`, `docs/2026-06-30-companion-hardware-bringup.md`.

---

## Session 2026-06-29 (late): v1.6.1 shipped — TAS5713 2× bug FIXED + Spotify Connect BAKED IN

Both the audio bug and the live Spotify Connect install from the earlier 2026-06-29
entry below are now **resolved and in the build** — released **v1.6.1**, verified on a
**fresh flash**. Full detail in `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.

- **TAS5713 2× speed bug FIXED — kernel patch 0022** (`linux-google-steelhead`
  pkgrel 25). Root cause was the `simple-audio-card`↔`omap-mcbsp` master-mode gap: the
  generic card sets only `mclk-fs` and never `snd_soc_dai_set_clkdiv()`, so McBSP2 left
  `CLKGDV=0` (bit clock = the undivided 24.576 MHz fclk) and sized the frame as
  `in_freq/rate = 256` BCLK → **FSYNC = 96 kHz = 2× too fast**. Patch 0022 derives
  `CLKGDV` from the real `mcbsp->fclk` + a minimal `wlen*channels` I2S frame,
  reproducing the factory registers (CLKGDV=15, BCLK 1.536 MHz, 32-BCLK frame, FSYNC
  48 kHz). **Verified on hardware:** 60 s of audio now plays in **60.00 s** (1.000×; was
  ~30 s / 0.50×). The "B7 TAS5713 MCLK 16 vs 12.288 MHz" lead from the entry below was a
  **red herring** — mainline `tas571x` has no `.set_sysclk`, so MCLK never gates FSYNC.
  Cross-checked vs `reverse-eng/vmlinux.bin` (stock-parity audit).
- **Spotify Connect (librespot) BAKED INTO THE BUILD** — `device-google-steelhead`
  pkgrel 11 now `depends librespot` (Alpine edge/testing **0.8.0**, libmdns zeroconf)
  and ships: the enabled `/etc/systemd/system/librespot.service` (`librespot --name
  "Nexus Q" --device nexusq …`), `/etc/asound.conf` (the **`nexusq`** PCM = `plug` →
  `hw:CARD=NexusQSpeaker,0` forced to **48000 Hz** — addressed by **NAME** because the
  TAS5713/HDMI cards race for card 0/1 across boots), and `/etc/nftables.d/60_spotify.nft`
  (`wlan*` UDP 5353 + TCP 37879). Discovery + auth + streaming verified over 5 GHz WiFi
  at correct pitch (44.1 k Spotify resampled to the clean 48 k). All of it now **survives
  a flash**. (The device-side install + nftables/`--ap-port 443` rationale are in the
  entry below.)

## Session 2026-06-29: Spotify Connect streams; TAS5713 plays 2× too fast (NEW bug) → both RESOLVED in v1.6.1 (see above)

Full detail in `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`. Both
results below are on the v1.6.0 image and were open when written; **both are now
shipped in v1.6.1 — see the session above.**

- **Spotify Connect (librespot) installed + streaming VERIFIED** — `apk add
  librespot` (Alpine edge/testing, **0.8.0-r0**, **libmdns-only** zeroconf backend so
  it coexists with `avahi-daemon` on UDP 5353 via `SO_REUSEPORT`). Unit
  `/etc/systemd/system/librespot.service`: `librespot --name "Nexus Q" --backend alsa
  --device plughw:1,0 --bitrate 320 --format S16 --initial-volume 60 --ap-port 443
  --zeroconf-port 37879 --cache /var/cache/librespot`. nftables drop-in
  `/etc/nftables.d/60_spotify.nft` opens `wlan*` UDP 5353 (mDNS) + TCP 37879
  (zeroconf HTTP). `--ap-port 443` dodges VLAN20 blocking librespot's default AP port
  4070. Phone sees "Nexus Q", authenticates, tracks load + play over 5 GHz WiFi.
  **NOT baked into the build** (a flash wipes it) — bake-in deferred until the audio
  bug below is fixed.
- **NEW HARDWARE BUG — TAS5713 plays EXACTLY 2× too fast.** First real timing test of
  the speaker path (was "software-verified, listening test pending"): 10.0 s of
  `S16_LE` stereo silence to `hw:1,0` (card 1 `NexusQ-Speaker` = McBSP2 → TAS5713)
  plays in **5.00 s** = **0.50× = 2× too fast** at 48000 Hz, 2× at all rates. So
  librespot/Spotify tracks end in half real time and the player **auto-skips ~40 s
  in** (the "plays ~40 s then skips" symptom — **not** a librespot crash). Root cause:
  **McBSP2/ABE SRG emits FSYNC (LRCLK) at 2× the requested rate** — a kernel/DTS clock
  bug in the **B7 TAS5713-MCLK family** (`docs/2026-06-19-boot-warnings-followup.md`
  §B7). `func_mcbsp2_gfclk` reads 24.576 MHz (=512×48k, correct), so the ×2 is
  **downstream** (SRG divider / I2S frame width / TAS5713 MCLK 16 vs 12.288 MHz). A
  stock-parity audit vs `reverse-eng/vmlinux.bin` (the factory kernel that drove this
  amp correctly) + the precise kernel fix are **IN PROGRESS** — open, newly
  root-caused; fix + verification to follow.
- **WiFi join after a fresh flash documented** (SSID `Svatovitske-Internety-5g`,
  5 GHz/vlan20, PSK in 1Password — never in-repo) in `.claude/agents/nexusq-connect.md`
  + the `nexusq-wifi-join` memory. 5 GHz ~26–30 Mbit/s carries the Spotify stream;
  2.4 GHz still has the BT-coexist bulk stall.

## Session 2026-06-28: zram + userns + power health; ARMv7 python crash FIXED (flash bug; gold dropped) → v1.6.0

Full detail in `docs/2026-06-28-session-findings.md`. Diag capture
`nq-captures/20260628-124159/` (verdict CRIT — dark-but-responsive LED ring + the
then-failed python unit, **not** a true hang).

- **zram swap fixed** — `CONFIG_ZRAM=m` + `deviceinfo_zram_swap_algo="lzo-rle"`
  (the kernel module only has the lzo backend; the service's default zstd failed
  `Invalid argument`). Live: `/dev/zram0` lzo-rle 1.4 G `[SWAP]`. linux pkgrel 23→24.
- **`CONFIG_USER_NS=y`** — `max_user_namespaces=7716`, `unshare --user` works.
- **SMP re-confirmed** — `nproc=2`, `cpu/online=0-1`. Corrects any stale "CPU1 not
  brought up / SMP groundwork" framing; SMP is done (v1.2.0).
- **CPU power/thermal health confirmed** — 350/700/920/1200 MHz, reaches 1.2 GHz,
  VDD_MPU tracks OPP exactly, abb_mpu FBB@Nitro 1375 mV, governor `conservative`,
  idle ~70 °C / peak 95 °C (no throttle). `CONFIG_CPU_FREQ_STAT` is off (no
  `time_in_state`) — a diagnostic gap.
- **CORRECTION (idle freq):** the v1.5.0 CHANGELOG "idle settles at 350 MHz" is
  wrong on hardware — idle hovers **~920 MHz** (nexusqd LED polling keeps the clock
  up), dipping to 350 only briefly.
- **CORRECTION (GCC):** the **current shipping kernel is built with GCC 15.2.0**
  (`/proc/version`: `cc (Alpine 15.2.0) 15.2.0`) and boots fine. The old
  "13.3.Rel1 only / GCC 15 silently does not boot" finding below (2026-06-10)
  applied to the early hand-cross-compiled build and is **superseded** for the
  pmbootstrap path.
- **FIXED — armv7 python3-3.14.5 SIGSEGV: the on-device crash was a FLASH bug, not a
  build bug.** Alpine's `python3-3.14.5-r2` SIGSEGVed deterministically
  (`python3 -S -c ''` → rc 139 in `Py_Initialize`), crashing
  onboard/blueman/sleep-inhibitor and `gdb` (it links libpython). The **single root
  cause** was the `raw2simg.py` `DONT_CARE` deployment bug (next bullet): a re-flash over
  non-erased eMMC left stale garbage in libpython's should-be-zero `.PyRuntime` /
  `.data.rel.ro`, landing on `interp->types.builtins.num_initialized` (read back
  `0xf0012b00`), so `_PyStaticType_InitBuiltin` derefs a wild address → SIGSEGV. v1.6.0
  ships a local `pmos/python3/` override (same 3.14.5, **r5**, **default linker / bfd**)
  so its higher pkgrel supersedes Alpine's `-r2`; it drops `--with-lto` +
  `--enable-optimizations` and the `!gettext-dev` token, keeps stock `-O2`.
  **The session HYPOTHESISED a build-time qemu-user mmap-corruption and tried a
  gold-linker workaround (`-fuse-ld=gold -Wl,--no-mmap-output-file`, `binutils-gold`) —
  both INVESTIGATED then DROPPED as unnecessary:** the build was never reproducibly
  corrupt — 6 independent default-linker builds were all integrity-gate-clean, and a bfd
  build (gold-note absent, libpython md5 `79a0d4ace1358bb2d94c8a4d72479da9`) flashed via
  the corrected all-RAW `raw2simg` ran `python3 -S -c ''` rc 0 on the real device. (The
  earlier "byte-identical `.text`, opposite outcome" / "two r4 builds" coin-flip evidence
  was almost certainly a post-flash device pull misread as build corruption.) The
  deterministic build-integrity gate `scripts/verify-libpython-clean.py` (long non-zero
  runs in those zero-regions; clean ≤52 B, corrupt ≥22000 B, threshold 256) is **kept as
  a cheap safety net** — Phase-7d gate+retry (rebuild ≤4×, pkgrel-exact apk selection) +
  a Phase-10 **ship gate** on the installed rootfs libpython — catching zero-region
  corruption from any source, **not** as "the gold fix". **DISPROVEN (do not re-tread):**
  LTO/PGO; LDREXD misalignment (faulting addr 8-byte aligned but **UNMAPPED** → SIGSEGV
  not SIGBUS); gnu2/TLSDESC; optimization level; and the qemu-build / gold theory above.
  A clean build is necessary-but-not-sufficient — the flash must also be **byte-exact**;
  always validate `python3 -S -c ''` **on the device**.
- **FIXED — the DEPLOYMENT (flash) bug that corrupted python on-device → v1.6.0.** The
  gate-CLEAN rootfs SIGSEGVed `python3` (rc 139) on-device: the build was clean, the
  **flash** was not — `raw2simg.py` emitted all-zero blocks as `DONT_CARE`, which
  fastboot SKIPS, correct only on a pre-erased partition; the Nexus Q's U-Boot does
  **not** erase `userdata`, so each skipped block kept STALE eMMC data from the prior
  flash, corrupting libpython's `.PyRuntime`/`.data.rel.ro` zero-regions. Forensics:
  on-device libpython differed from the (clean) image in **exactly 47** 4 KiB blocks,
  **all** image-zero→device-garbage (`.PyRuntime longest_run 30652`); `scp`-ing the
  clean image libpython over the device's → `python3 -S -c ''` rc 0 instantly (proof:
  flash, not build). **Fix:** `raw2simg.py` now writes **every** block as RAW (no
  `DONT_CARE`) → byte-exact flash regardless of prior eMMC content (sparse ≈ raw size).
  Verified by de-sparse round-trip (md5 matches raw) **and** on hardware: a **fresh
  flash, no live-patch** (no `.flashcorrupt` backup) of a default-linker (bfd) build
  gives `libpython3.14.so.1.0` md5 `79a0d4ace1358bb2d94c8a4d72479da9`,
  `SYSPY_OK 3.14.5 … [GCC 15.2.0]`, `SYS_PY_RC=0`. **The all-RAW flash fix → shipped
  v1.6.0**, the first release with a working system python from a clean flash. Lesson:
  integrity-verify what the **device** runs, not just the artifact (do NOT use DONT_CARE
  on a non-erasing target).
- The currently-flashed image is now **v1.6.0** (bfd r5 python + all-RAW flash).
  `device-google-steelhead` pkgrel 6→10 **removed**
  the `sleep-inhibitor.service` `/dev/null` mask and added `gdb` + `python3-dbg`. WiFi
  creds added live are wiped by reflash — to persist they need a **private overlay**
  (PSK is a secret), not the public repo.
- **Ethernet still down** (v1.4.0 cpufreq boot-timing regression, unchanged).

## Session 2026-06-23: device hardening — AVR keys, HDMI desktop, WiFi; ethernet still open

Released **v1.2.0**. Built on the dual-core SMP win. Full detail in
`docs/2026-06-23-session-findings.md`; ethernet next steps in
`docs/2026-06-23-ethernet-continuation.md`.

- **AVR rotary volume + mute keys FIXED** (patch 0011) — the keys were dead
  because the AVR holds INT low while its KEY_FIFO is non-empty and the driver
  uses an `EDGE_FALLING` irq: stale FIFO entries at probe meant the line was
  already low → no edge → the irq never fired → FIFO never drained (latent driver
  bug; intermittent). Drain the FIFO in probe to release INT. Proven by reading
  the KEY_FIFO directly over i²c (the AVR was detecting keys the whole time) and
  by the IRQ count going 0→118 once drained. The LED ring (nexusqd) now responds
  to the dome again.
- **HDMI desktop visible** — DDC pads to `PIN_INPUT` (EDID reads) + hdmi4 bridge
  `.mode_valid` cap at 75 MHz (patch 0010) so wlroots picks a DSS-displayable
  1280×720 instead of the blank native 1440×900.
- **WiFi latency** fixed via NM `wifi.powersave = 2` drop-in.
- **Ethernet LAN9500A — still intermittent.** stock-parity-auditor REFUTED the
  board-level timing/power-cycle hypothesis (stock uses identical udelay(2), no
  power-cycle, no retry) and found one real divergence: stock's **1 ms ULPI
  pre-reset settle** (added, commit `3b06c41`) — but it is **not** sufficient; a
  cold boot still shows PORTSC CCS=0 / no enumeration. **Prime open suspect:**
  `UHH_HOSTCONFIG` not holding `0x11c` across `usbhs_runtime_resume`. Next: a
  kernel-side diag build dumping `UHH_HOSTCONFIG` + USB3320 ULPI identity (userspace
  `/dev/mem` faults on the clock-gated USBHS). See the continuation doc.

### Process reminders reinforced this session
- **Verify every hypothesis against stock before building.** The user's "does
  stock confirm this?" caught a wrong ethernet fix mid-flight (a board-level
  power-cycle that stock does not do) before it was flashed.
- **Nothing is "benign/cosmetic."** Every half-working subsystem gets root-caused.
- **sha-verify the on-device boot image before `dd`** (a slow-WiFi scp once
  silently transferred a 0-byte file); flash via fastboot or the USB gadget.
- Test ethernet only by **cold power-cycle** over **multiple boots** — warm
  `fastboot reboot` is not representative and one good boot is luck.

## Session 2026-06-22: SECOND CPU CORE WORKS ✅ — dual-core SMP

The OMAP4460 HS second Cortex-A9 is online and stable on mainline 6.12.
`CONFIG_SMP=y` had silently deadlocked the boot for the life of the port; root
cause found by disassembling the stock kernel (`reverse-eng/vmlinux.bin`):

- **Missing SEV in `omap4_smp_prepare_cpus`** — stock issues `dsb;sev` after
  writing AUX_CORE_BOOT_1 to kick CPU1 out of ROM WFE; mainline omits it → CPU1
  never starts → `__cpu_up` hangs before any console. Fix: **patch 0009**
  (`dsb_sev()` at end of prepare).
- **CPU1 cpuidle panic** once online (`Attempted to kill the idle task`, on
  `swapper/1`). Fix: **`cpuidle.off=1`** (stock ships `cpuidle44xx.disallow_smp_idle`).

Secure SMC service IDs already matched stock byte-for-byte; `omap_type()=HS`.
defconfig: `CONFIG_SMP=y`, `NR_CPUS=2`, `HOTPLUG_CPU=y`, `KERNEL_LZMA` (SMP+gzip
busted the ~6.6 MB U-Boot ceiling; LZMA → ~5.1 MB); DTS `cpu@1` restored.

**Validated** (cold boot, `boot-smp-dualcore.img`): `nproc=2`, online/possible=0-1,
`taint=0`, 0 module-ABI errors, `SMP: Total of 2 processors activated`, CPU1 up at
`[0.25s]`, both cores load under stress, ~59 °C; audio/LED-ring/wifi/BT/USB up.
Dual-core also cured the single-core-saturation network flakiness.

Build: `scripts/build-kernel-boot.sh` (fast kernel-only docker build). Branch
`feat/smp-cpu1-bringup` (`510f8ab` breakthrough+debug, `8d4df5d` clean dual-core).
Also fixed a repo-integrity bug: patch 0008 (ethernet) applied with `git apply`
but FAILED under GNU `patch` (abuild) — regenerated clean.

**Full writeup: `docs/SMP-second-core.md`.** Open items (cpuidle proper, eth
LAN9500A enumeration reliability, wifi BCM4330 power-save, making SMP the default
after multi-cold-boot reliability validation) tracked in
`docs/2026-06-22-smp-session-findings.md`.

## Session 2026-06-22 (late): ETHERNET FIXED ✅ — kernel #8, released v1.1.0

The on-board **SMSC LAN9500A USB-ethernet works.** This retires the multi-month
"ethernet is dead hardware" verdict, which was wrong: the stock Android 3.0 kernel
enumerates the same chip on this unit, so the bug was always in our mainline port.

**Two kernel patches, both required:**
- `0006-usb-ehci-omap-steelhead-keep-ethernet-port-alive-ulp` — vendor steelhead
  host-init in `ehci-omap` done *before* `usb_add_hcd()`: LAN9500A power-on-reset
  sequence (auxclk3 38.4 MHz, NENABLE/NRESET gpios), `INSNREG01` burst thresholds
  = 0x80, a ULPI Function-Control soft reset of the USB3320, plus
  `usb_disable_autosuspend()` on the root hub so the idle port is not clock-gated.
- `0008-mfd-omap-usb-host-steelhead-UHH-HOSTCONFIG-connect` — in `omap_usbhs_init`,
  program `UHH_HOSTCONFIG` to the vendor's **0x11c**: set `P1_CONNECT_STATUS`
  (bit 8) so EHCI latches the port-1 connect, and leave `APP_START_CLK` (bit 31)
  **clear** so the UHH does not auto clock-gate. Measured mainline default was
  **0x1c** (the "ethernet-stockinit" handover's APP_START_CLK guess was wrong).

**Discovery note:** kernel **#7** (patch 0006 alone) already enumerated `eth0` —
the `docs/2026-06-22-HANDOVER-ethernet-stockinit.md` "#4–#7 all failed, eth0 absent"
conclusion was a mis-test. #8 adds the UHH_HOSTCONFIG change as the *more-correct*
root-cause form (matches the vendor exactly, no autosuspend reliance) and is the
released kernel.

**Verified on hardware (#8):** `eth0` (`0424:9e00` → `smsc95xx`) at 100 Mbps/Full,
bidirectional ping 0% loss (~0.69 ms avg), **zero** rx/tx/CRC/frame/over errors and
zero collisions after ~660 MB transferred. Throughput TX ~60 / RX ~28 Mbps —
USB2 + single-core OMAP4 bound (device ~64% idle during RX), not a link fault.

**Access over ethernet (now preferred over the renaming USB gadget):** the Nexus
RJ45 is cabled directly to `petronijus-PC` NIC `enp7s0` (Intel I225-V, 100M). Device
`eth0` has a persistent NetworkManager profile **`eth-direct`** (`ipv4.method
manual`, `10.42.0.2/24`, never-default, autoconnect, bound to ifname not MAC since
smsc95xx has no EEPROM MAC) → survives reboot and stopped the earlier NM-DHCP-timeout
link flap. PC side: `enp7s0` = `10.42.0.1/24`, set NM-unmanaged so the IP sticks.
`ssh root@10.42.0.2`.

Artifacts: `#7` backup `output/p9-backup-7-working.img` (sha c0dd95d1); released
`#8` boot image `output/boot-eth-8.img` (sha 8c7b4f75, 6496 KB, under the ~6.5 MB
U-Boot ceiling). The released boot image is #8 *with* a one-time diagnostic
`UHH_HOSTCONFIG` boot log; source patch 0008 in the v1.1.0 tag omits that logging
(functionally identical). Build gotcha fixed: `docker-build.sh` Phase 7a now also
chowns `$WORK/cache_ccache_armv7` to uid 12345.

## Session 2026-06-22: TAS5713 amp clock fixed, single-core taint cleared; ethernet still dead

Built and flashed kernel **#4** (`6.12.12`), verified live over the USB gadget
(WiFi is unstable — flash/diagnostics go over `172.16.42.1`).

- **TAS5713 amplifier MCLK fixed** (kernel patch 0007). OMAP4 composite-clock
  `round_rate`/`set_rate` were `-EINVAL` stubs; delegated to
  `ti_clk_divider_ops`. On HW: `dpll_per_m3x2_ck` = 61.44 MHz, `auxclk1_ck` =
  12.288 MHz (256×48 kHz), ALSA `card 0 NexusQ-Speaker` registers, no clock
  error. (Actual audio playback through speakers not yet tested.)
- **Single-core taint cleared.** DTS now `/delete-node/ cpu@1` (matches
  `CONFIG_SMP=n`). `/proc/sys/kernel/tainted` = 0 (was 512), no DT cpu-cap WARN.
- `CONFIG_SRAM=y`; new helper scripts `regen-dts-patch.sh`,
  `extract-and-repack.sh`; device password moved to gitignored `.nexus_pw`.
- **Ethernet (LAN9500A) STILL DEAD.** #4 kernel: EHCI port powered, ULPI PHY
  (USB3320, VID 0x4:0x24) responds, `PORTSC=00001000` (PP set, CCS clear) — no
  enumeration, no `eth0`, EHCI bus 002 has only the root hub. This is the next
  thing to investigate/fix. Backup of the pre-#4 boot partition:
  `output/p9-backup-pre-clockfix-b7.img`.

## Session 2026-06-10: Userspace boots, WiFi works, ethernet is dead HW

### Status: postmarketOS (systemd) boots, SSH over USB gadget, WiFi functional

### Root causes found today (in order of discovery)
1. **U-Boot kernel-size ceiling (~6.5-7 MB)** when loading from the boot
   partition: 6.45 MB zImage+DTB boots, 7.3 MB does not. This was the hidden
   variable behind "Finding 2" (identical-config rebuilds not booting) --
   embedded initramfs pushed the image over the limit.
2. **Ubuntu GCC 15.2 kernels do NOT boot** (black screen). Only the Arm GNU
   Toolchain 13.3.Rel1 (same as original builds) produces booting kernels.
   Toolchain lives in `build/arm-gnu-toolchain-13.3.rel1-*/bin`,
   prefix `arm-none-linux-gnueabihf-`.
3. **Feb rootfs flash silently failed**: 511 MB sparse image exceeds the
   U-Boot fastboot download buffer (~150 MB). Flash userdata with
   `fastboot -S 100M flash userdata <img>` -- works reliably (6 chunks).
4. **Rootfs is pmOS systemd variant** (/sbin/init -> ../lib/systemd/systemd).
   /etc/inittab and /etc/init.d are decoys. Emergency mode was caused by an
   fstab entry for a /boot partition UUID that only existed in the build VM;
   line removed. Root account unlocked (password 147147, same as user).
5. **Ethernet (LAN9500A) is dead hardware.** Verified at register/pad level:
   pinmux applied, GPIO pads toggle (DATAIN readback), 38.4 MHz PHY refclk
   running, ULPI PHY (SMSC USB3320, id 0x0424/0x0007) responds via the EHCI
   ULPI viewport (INSNREG05 @ 0x4A064CA4), EHCI port powered -- but PORTSC
   CCS never asserts. gpio_1 (ethernet NENABLE) is physically clamped low
   (drive-high reads back 0). DTS ethernet fixes applied anyway (38.4 MHz
   clock per board-steelhead-usbhost.c, NENABLE polarity, gpio_wk1 pad 0x042
   in wkup domain, fref_clk3_out mux) -- correct for a healthy unit.
6. **WiFi (BCM4330) works.** Chain of fixes:
   - kernel patch 0004: twl-core registers the clk mfd cell for TWL6030
     (mainline only did TWL6032; register bases 0x8C/0x8F are identical)
   - DTS: pwrseq clocks = <&twl 1> (clk32kaudio, per board-steelhead-wifi.c)
   - DTS: WLAN_EN (gpio_43) only in pwrseq (was double-claimed by the vmmc
     regulator -> EBUSY); vmmc is a plain always-on 3.3 V fixed regulator
     (3.3 V matters: SDIO OCR negotiation fails at 1.8 V "no support for
     card's volts")
   - nvram: **original bcmdhd.cal recovered from the old Android system
     partition (mmcblk0p11, still intact!)** -> /lib/firmware/brcm/
     brcmfmac4330-sdio.txt. Generic Prowise nvram does NOT work (dongle
     timeout -110). Also recovered bcm4330.hcd (Bluetooth patchram).
     Both backed up in `firmware/` in this repo.

### Access to the running device
- USB gadget RNDIS via micro-USB: device 172.16.42.1, host 172.16.42.2/24
  (NetworkManager profile "nexusq" on this PC; iface name changes each boot
  -- random MAC -- fix with `nmcli con mod nexusq connection.interface-name <enx...>`)
- SSH as root (password 147147, petronijus' ed25519 key authorized)
- Gadget+sshd is started by /usr/local/bin/nexus-diag.sh (systemd unit
  nexus-diag.service), which also dumps diagnostics to /dev/tty1 and
  /var/log/nexus-diag.log
- **Boot images can be written from the running system**:
  `dd if=boot.img of=/dev/mmcblk0p9 bs=1M conv=fsync` -- no fastboot needed
- **`systemctl reboot` over SSH works cleanly** (~90 s to gadget back up).
  The old "software reboot re-enters fastboot" note applied to panic-reboots
  and `fastboot reboot`, NOT to a clean systemd reboot.
- pstore/ramoops configured in cmdline (last 1 MB of RAM, mem=1008M) --
  survives warm reboots only

### Current images
- boot: `output/boot-wifi-v5.img` (GCC 13.3, gzip, no initramfs,
  root=/dev/mmcblk0p13 + ramoops in cmdline, DTS with all fixes)
- rootfs: `output/work-rootfs.img` (raw) / `work-rootfs-sparse.img` (flash)
  -- modules for this exact kernel installed, fstab fixed, sshd fixed
  (UsePAM drop-in removed), root unlocked, host keys baked in
- mini mkbootimg replacement: `make-bootimg.py` (or reuse a proven header)

### Known issues / next steps
1. **Intermittent boot failure** (~1 in 3 boots: black screen, retry helps).
   Unexplained. Candidates: U-Boot flakiness, DRAM init, kernel race.
   pstore won't help across cold cycles. Consider UART2/3 serial console.
2. WiFi: NetworkManager connection profile not yet configured (needs SSID
   + password). brcmfmac autoloads on boot; firmware+nvram persist in rootfs.
3. Bluetooth: bcm4330.hcd recovered; hci_bcm + UART2 wiring in DTS untested.
4. SMP still disabled (single core) -- original U-Boot CPU1 issue.
5. Audio (TWL6040/TAS5713), NFC, LEDs untested.
6. APKBUILD sha512sums need refresh (0004 patch added with SKIP).

## Current Status: KERNEL BOOTS (HDMI output confirmed)

**Milestone achieved 2026-02-27:** The kernel boots, HDMI output works (framebuffer console with Tux logo), eMMC is fully detected with all partitions, and the kernel panics with "Unable to mount root fs" -- which is expected since no rootfs is configured yet.

### What Was Wrong (Root Cause)

**`CONFIG_SMP=y`** was the sole root cause of boot failure. The U-Boot 2011.09 bootloader leaves CPU1 (second Cortex-A9 core) in an undefined state. The mainline kernel's OMAP4 SMP startup code hangs trying to bring it online -- no panic, no output, silent deadlock. **Fix: `CONFIG_SMP` disabled.**

### Required Config for Boot (all must be set)

| Option | Value | Why |
|--------|-------|-----|
| `CONFIG_SMP` | `n` | U-Boot leaves CPU1 in bad state; SMP startup hangs |
| `CONFIG_ARM_ATAG_DTB_COMPAT` | `y` | **REQUIRED** -- kernel does NOT boot without it; U-Boot passes ATAGs that the kernel needs for proper initialization |
| `CONFIG_ARM_APPENDED_DTB` | `y` | DTB appended to zImage (standard for this platform) |
| `CONFIG_CMDLINE_FORCE` | `y` | U-Boot's cmdline is unreliable; compiled-in cmdline only |
| `CONFIG_INITRAMFS_SOURCE` | `"mini-initramfs.cpio"` | Initramfs MUST be embedded in kernel (see below) |

### Boot Method

- **Reliable: `fastboot flash boot` + normal power-on** -- Flash to the 8 MB boot partition, then power-cycle without holding mute sensor. U-Boot loads from partition and boots reliably.
- **Unreliable: `fastboot boot` (RAM boot)** -- Intermittent on this U-Boot. Works sometimes, fails silently other times. Avoid for testing.

### Initramfs Strategy: MUST Be Embedded in Kernel

**U-Boot does NOT load the ramdisk from the boot partition** during normal boot. The boot.img ramdisk section is ignored. Therefore:
- External ramdisk in boot.img: **DOES NOT WORK** (U-Boot ignores it)
- DTB initrd-start/end: **DOES NOT WORK** (U-Boot doesn't load ramdisk to RAM)
- `CONFIG_INITRAMFS_SOURCE`: **WORKS** (initramfs compiled into zImage)

A minimal initramfs (busybox + USB gadget setup, 549 KB compressed) is embedded in the kernel via `CONFIG_INITRAMFS_SOURCE="mini-initramfs.cpio"`. Total boot image: 6.7 MB, fits in 8 MB partition.

The full pmOS initramfs (8.4 MB) is too large to embed. Solution: use the minimal initramfs for initial boot, mount full rootfs from userdata partition.

## Boot Image Variants Tested
| Image | Size | Description | Result |
|-------|------|-------------|--------|
| `boot.img` | 13.5 MB | Full pmos initramfs, SMP=y | No output (SMP bug) |
| `boot-diag.img` | 5.9 MB | Minimal diag initramfs, SMP=y | No output (SMP bug) |
| `boot-builtin.img` | 8.8 MB | Full initramfs, built-in drivers, SMP=y | No output (SMP bug) |
| `boot-noramdisk.img` | 5.0 MB | Kernel+DTB only, SMP=y | No output (SMP bug) |
| `boot-test-nosmp-noatag.img` | 6.2 MB | SMP=n, ATAG=n, no ramdisk | Boots (HDMI+kernel panic) |
| `boot-atag-initramfs.img` | 6.7 MB | SMP=n, ATAG=y, external ramdisk | Boots (panic: ramdisk not found) |
| `boot-atag-embedded.img` | 6.7 MB | SMP=n, ATAG=y, embedded initramfs | **Testing...** |
| Various rebuild tests | 6.2 MB | SMP=n, ATAG=n, no ramdisk | No output (ATAG required) |

### Kernel Configuration Changes (Current State)
These drivers were changed from `=m` (module) to `=y` (built-in) in `kernel/configs/steelhead_defconfig`:
- `CONFIG_DRM=y`, `CONFIG_DRM_OMAP=y` (HDMI display)
- `CONFIG_DRM_PANEL_SIMPLE=y`, `CONFIG_DRM_DISPLAY_CONNECTOR=y`
- `CONFIG_DRM_SIMPLE_BRIDGE=y`, `CONFIG_DRM_TI_TFP410=y`, `CONFIG_DRM_TI_TPD12S015=y`
- `CONFIG_USB=y`, `CONFIG_USB_EHCI_HCD=y` (USB host)
- `CONFIG_USB_MUSB_HDRC=y`, `CONFIG_USB_MUSB_OMAP2PLUS=y` (USB OTG)
- `CONFIG_NOP_USB_XCEIV=y`, `CONFIG_OMAP_USB2=y`, `CONFIG_TWL6030_USB=y` (USB PHY)
- `CONFIG_USB_GADGET=y`, `CONFIG_USB_CONFIGFS=y` (USB gadget/RNDIS)
- `CONFIG_USB_USBNET=y`, `CONFIG_USB_NET_SMSC95XX=y` (Ethernet)
- `CONFIG_FRAMEBUFFER_CONSOLE=y`, `CONFIG_FB=y` (framebuffer console)

### Other Fixes Applied
- `deviceinfo_dtb` changed from `"ti/omap/omap4-steelhead"` to `"omap4-steelhead"` (kernel installs DTBs flat, not under `ti/omap/`)
- `deviceinfo_append_dtb="true"` added (appends DTB to zImage)
- `CONFIG_ARM_APPENDED_DTB=y` in defconfig (DTB concatenated after zImage)
- `CONFIG_ARM_ATAG_DTB_COMPAT=y` in defconfig (REQUIRED for boot, see Investigation Log)
- Rootfs flashes to `userdata` partition (13 GB) since `system` is only 1 GB
- Custom `raw2simg.py` for sparse image conversion. U-Boot supports only RAW +
  DONT_CARE chunks (no FILL/CRC32), but as of 2026-06-28 we emit **all-RAW** (no
  DONT_CARE): U-Boot does NOT erase userdata, so a skipped DONT_CARE block keeps stale
  eMMC data → corrupts the flash (it re-broke libpython; see the 2026-06-28 session).

## Investigation Log & Key Findings

### Finding 1: SMP Is the Only Boot Blocker
`CONFIG_SMP=y` causes a silent deadlock during OMAP4 SMP startup. All other early boot failures were caused by SMP, not by other config options. With SMP disabled, the kernel boots reliably.

### Finding 2: ATAG_DTB_COMPAT Is REQUIRED (Corrected)
Earlier testing incorrectly concluded that `CONFIG_ARM_ATAG_DTB_COMPAT=y` caused crashes. This was wrong -- ATAG_DTB_COMPAT was always disabled alongside SMP, so the real culprit (SMP) was masked. When we later rebuilt with ATAG_DTB_COMPAT=y and SMP=n, the kernel booted fine (6.12.12 #2).

**With ATAG_DTB_COMPAT=n, kernel rebuilds do NOT boot.** The original working binary was a fluke or compiled under slightly different conditions. Multiple clean rebuilds with ATAG_DTB_COMPAT=n (identical config, verified via extract-ikconfig, only 43 bytes of timestamp differences) all failed to boot.

### Finding 3: U-Boot Ignores Boot.img Ramdisk on Partition Boot
U-Boot 2011.09 on the Nexus Q does NOT load the ramdisk section of the Android boot.img when booting from the boot partition. Only the kernel is loaded and executed. This means:
- External ramdisk in boot.img is useless for partition boot
- The initramfs must be embedded in the kernel via `CONFIG_INITRAMFS_SOURCE`
- CyanogenMod worked because it used `fastboot boot` (RAM boot) which DOES load the ramdisk, or because its U-Boot had ramdisk loading patched in

### Finding 4: Boot Method Reliability
- `fastboot flash boot` + cold power-cycle (unplug/replug): **RELIABLE**
- `fastboot boot` (RAM boot): **UNRELIABLE** (intermittent)
- `fastboot reboot`: **UNRELIABLE** (often re-enters fastboot instead of booting)
- Software reboot (panic=XX): Re-enters fastboot

### What Was NOT the Problem
- LZMA compression (GZIP kept for compatibility)
- `CONFIG_OMAP_RESET_CLOCKS` (disabled as precaution)
- `CONFIG_POWER_AVS_OMAP` (disabled as precaution)
- The device tree (omap4-steelhead.dts is correct)
- The boot image format (mkbootimg header v0, correct addresses)
- `CONFIG_ARM_ATAG_DTB_COMPAT` (was falsely suspected)

## Immediate Next Steps

### 1. Verify Embedded Initramfs Boot (IN PROGRESS)
`boot-atag-embedded.img` (6.7 MB) has the kernel with embedded mini-initramfs and ATAG_DTB_COMPAT=y. Currently being tested.

### 2. Get USB Networking / Telnet Access
The mini-initramfs sets up:
- USB gadget RNDIS on micro-USB (host IP 172.16.42.1, client 172.16.42.2)
- Telnet on 172.16.42.1:23
- Tries to mount rootfs from /dev/mmcblk0p13 (userdata)
- Falls back to interactive shell on HDMI console

### 3. Flash Full Rootfs to Userdata
Once we have shell access:
- Flash the full pmOS rootfs to userdata partition (mmcblk0p13)
- Or create a minimal rootfs with networking, then expand later

### 4. Re-enable SMP (Future)
Investigate proper OMAP4460 SMP startup with this U-Boot. May need:
- Custom SMP startup code that handles the undefined CPU1 state
- A secondary CPU holding pen implementation
- Patching the kernel's OMAP4 SMP code to reset CPU1 before bringing it online

## How to Reproduce a Working Boot

```bash
# 1. Build kernel (from /tmp/linux-6.12.12)
export ARCH=arm CROSS_COMPILE=/path/to/arm-none-linux-gnueabihf-
# Ensure .config has: SMP=n, ATAG_DTB_COMPAT=y, INITRAMFS_SOURCE="mini-initramfs.cpio"
make -j$(nproc) zImage dtbs

# 2. Create boot image (kernel + appended DTB, no external ramdisk)
cat arch/arm/boot/zImage arch/arm/boot/dts/ti/omap/omap4-steelhead.dtb > zImage-dtb
# Use Python mkbootimg script (see output/ directory) with:
#   base=0x80000000, kernel_offset=0x8000, ramdisk_size=0, pagesize=2048

# 3. Flash
fastboot flash boot output/boot-atag-embedded.img

# 4. Cold power-cycle (UNPLUG power, wait 5s, replug WITHOUT mute sensor)
# Do NOT use 'fastboot reboot' -- it re-enters fastboot
```

## Device Information

### Partition Layout
```
environment    97 KB    raw
crypto         16 KB    raw
xloader       384 KB    raw
bootloader    512 KB    raw     *** NEVER FLASH ***
device_info   512 KB    raw
bootloader2   512 KB    raw
misc          512 KB    raw
recovery        8 MB    boot
boot            8 MB    boot    (can fit <=8 MB images)
efs             8 MB    ext4
system          1 GB    ext4    (too small for rootfs)
cache         512 MB    ext4
userdata     13.17 GB   ext4    (rootfs target)
```

### Fastboot Mode
- Enter: Cover mute LED sensor during power-on -> solid red LED
- The device is **unbrickable** as long as bootloader is never overwritten
- Serial: `AW1S12241020`
- Bootloader: `steelheadB4H0J` (U-Boot 2011.09-rc1, Apr 2012)

### U-Boot Quirks
- Only supports sparse image chunk types `RAW` and `DONT_CARE` (not `CRC32` or `FILL`).
  NB: U-Boot does **not** pre-erase the partition, so `DONT_CARE` (which fastboot skips)
  leaves stale eMMC data behind — `raw2simg.py` therefore emits **all-RAW**, byte-exact
  (see the 2026-06-28 session: DONT_CARE re-corrupted libpython on re-flash).
- `fastboot boot` accepts images up to ~150 MB (download buffer)
- `fastboot flash boot` limited to 8 MB partition
- USB connection can be flaky -- always power-cycle between flash operations

## Build System

### Docker Build (Windows Host)
```bash
# Build Docker image
docker build -t nexusq-builder .

# Full build (clean)
docker volume rm nexusq-workdir nexusq-output 2>/dev/null
docker run --rm --privileged \
    -v "${PWD}:/src:ro" \
    -v nexusq-output:/tmp/output \
    -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap \
    --name nexusq-build \
    nexusq-builder /src/docker-build.sh

# Extract output
docker run --rm -v nexusq-output:/data -v "${PWD}/output:/out" \
    alpine:3.21 sh -c 'cp /data/*.img /out/'
```

### Build Volumes
- `nexusq-workdir` -- pmbootstrap work directory (kernel build cache, chroots)
- `nexusq-output` -- Output images (boot.img, rootfs)

### Current Build Artifacts in Docker Volume
The `nexusq-workdir` volume contains a **completed kernel build** with the built-in driver defconfig. Key paths inside:
```
chroot_rootfs_google-steelhead/boot/vmlinuz          (5.1 MB, kernel 6.12.12)
chroot_rootfs_google-steelhead/boot/dtbs/omap4-steelhead.dtb  (94 KB)
chroot_rootfs_google-steelhead/boot/config            (kernel config)
chroot_rootfs_google-steelhead/lib/modules/6.12.12/   (150 modules)
```

The `mkinitfs` step failed because `deviceinfo_dtb` had the wrong path (`ti/omap/omap4-steelhead` vs `omap4-steelhead`). This has been fixed in `pmos/device-google-steelhead/deviceinfo`. A clean rebuild should work.

### Manual Image Export
If `mkinitfs` fails in the chroot (QEMU binfmt issues), use `manual-export.sh` which:
1. Fixes DTB path in chroot deviceinfo
2. Builds initramfs manually (copies busybox + modules)
3. Creates boot.img with mkbootimg
4. Creates rootfs ext4 image from chroot

## File Inventory

### Core Configuration
| File | Purpose |
|------|---------|
| `kernel/configs/steelhead_defconfig` | Kernel config (MODIFIED: key drivers =y) |
| `kernel/dts/omap4-steelhead.dts` | Device tree source — **reference copy only: the build stages the DTS via `kernel/patches/` (0003 + follow-ups); editing this file alone is a silent no-op** (bit hard 2026-07-12 — see that session note) |
| `kernel/patches/0001-*.patch` | TAS5713 audio amp driver |
| `kernel/patches/0002-*.patch` | TAS5713 DT binding |
| `kernel/patches/0003-*.patch` | Steelhead DTS added to kernel tree |
| `pmos/device-google-steelhead/deviceinfo` | Device config (MODIFIED: DTB path fixed) |
| `pmos/device-google-steelhead/modules-initfs` | Initramfs modules list |
| `pmos/device-google-steelhead/APKBUILD` | Device package recipe |
| `pmos/linux-google-steelhead/APKBUILD` | Kernel package recipe |
| `pmos/firmware-google-steelhead/APKBUILD` | Firmware package recipe |

### Build Scripts
| File | Purpose |
|------|---------|
| `Dockerfile` | Alpine-based build container |
| `docker-build.sh` | Main build orchestrator (10 phases) |
| `build-and-flash.sh` | Top-level build + flash script |
| `manual-export.sh` | Manual image export when mkinitfs fails |
| `raw2simg.py` | Convert raw image to Android sparse format |

### Diagnostic Scripts
| File | Purpose |
|------|---------|
| `build-diag-boot2.sh` | Build minimal diagnostic boot image |
| `build-noramdisk.sh` | Build kernel-only boot image (no initramfs) |
| `fix-dtb.sh` | Manually append DTB to kernel |
| `verify-dtb.sh` | Validate DTB structure |
| `verify-kernel.sh` | Validate kernel binary |
| `inspect-initramfs.sh` | Extract and inspect initramfs contents |
| `inspect-initramfs-detail.sh` | Detailed initramfs inspection |
| `inspect-stage2.sh` | Inspect pmos init stage 2 |
| `regen-initramfs-fixed.sh` | Rebuild initramfs with correct module paths |

### Output Images
| File | Size | Description |
|------|------|-------------|
| `output/boot-atag-embedded.img` | 6.7 MB | **CURRENT** -- SMP=n, ATAG=y, embedded initramfs |
| `output/boot-test-nosmp-noatag.img` | 6.2 MB | Milestone: first boot (SMP=n, ATAG=n, no ramdisk) |
| `output/boot-atag-initramfs.img` | 6.7 MB | SMP=n, ATAG=y, external ramdisk (boots, no initramfs) |
| `output/boot.img` | 13.5 MB | Original full image (SMP=y, no boot) |
| `output/google-steelhead.img` | 720 MB | Rootfs (raw ext4) |
| `output/google-steelhead-sparse.img` | 530 MB | Rootfs (sparse, for flashing) |
| `output/milestone-kernel-boot-2026-02-27.png` | -- | Screenshot of first kernel boot |

## Ubuntu Transition Notes

If continuing on Ubuntu (instead of Windows):
1. USB/fastboot should work natively (`sudo apt install android-tools-adb android-tools-fastboot`)
2. Docker build should be faster (no QEMU overhead for Windows Docker)
3. Can also build natively with pmbootstrap if Alpine chroot works
4. Serial UART debugging is easier with USB-to-serial adapters on Linux
5. The rootfs (`google-steelhead-sparse.img`) is already flashed to the device's userdata partition -- only boot.img needs reflashing after kernel rebuilds
6. Consider using `pmbootstrap` natively on Ubuntu instead of Docker for faster iteration
