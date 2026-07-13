# Changelog

All notable changes to Nexus Q Reloaded. Format follows
[Keep a Changelog](https://keepachangelog.com/). Versioning is tag-only
(milestone-based) — there is no version string in the source.

## [Unreleased] — onboarding step 1 (targets v1.9.0; rc1 build + HW acceptance pending on the Linux machine)

> **App-driven WiFi onboarding for the display-less Q, implemented end-to-end
> 2026-07-13** (plan `docs/superpowers/plans/2026-07-13-onboarding-step1.md`,
> 13/13 coding tasks, commits `ae8f499..cb03cf7`, subagent-driven with per-task
> + final whole-branch reviews). Flow: NFC tap → BT RFCOMM provisioning →
> WiFi join → name/room/theme → outro, with the original stock imagery.
> **Nothing here is flashed yet** — the device runs v1.8.2; build/flash/HW
> acceptance = plan Task 14, continues on the Linux machine (see HANDOFF.md
> "WHERE TO CONTINUE"). Full write-up:
> `docs/2026-07-13-onboarding-step1-implementation.md`.

### Added

- **NEW package `nexusq-setupd` 0.1.0-r0** — BT RFCOMM WiFi-provisioning
  daemon (`userspace/nexusq-setupd/` + `pmos/nexusq-setupd` aport +
  docker-build.sh staging + `nexusq.preset` enable): SetupCore state machine
  (getDeviceInfo/confirmColor/scanNetworks/setWifi/getNetworkState/setName/
  setTheme/finishSetup; error codes `wrong_password`/`not_found`/`timeout`;
  the psk is never logged), BlueZ Profile1 RFCOMM transport (service UUID
  `8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a`, channel 3, Just-Works agent —
  accepted risk documented in PROTOCOL.md §8, 600 s idle timeout),
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
