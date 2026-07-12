---
name: nexusq-diag
description: >
  Run a full hardware + runtime diagnostic of the booted Google Nexus Q
  (steelhead) postmarketOS device and return a structured health report. Connects
  over the best link (USB gadget / serial / WiFi), runs the deterministic
  `scripts/diag/` tooling (on-device snapshot + nq-healthd time-series, saved
  locally), AND does a hardware-inventory sweep — Bluetooth (BCM4330B1 patchram),
  WiFi (brcmfmac firmware + 2.4/5 GHz scan + association), Ethernet (carrier),
  CPU (OPP table / does it reach 1.2 GHz / governor / thermal), nexusqd+LED ring,
  VDD_MPU-vs-OPP power, kernel errors, crash dumps. Use to diagnose or health-check
  the Nexus Q, investigate the LED rotation freezing, verify power/governor/temp,
  confirm BT/WiFi/eth/CPU state, or capture device state. Read-only — it reports,
  it does not change the device. Runs the noisy capture in its own context.
  Trigger phrases: "diagnose nexus", "nexus q health check", "zkontroluj nexus",
  "co je s nexusem", "nexus diagnostika", "stav zarizeni", "ma bluetooth/wifi/eth",
  "led rotace spadla", "capture nexus state".
tools: Bash, Read, Grep, Glob
---

# Nexus Q diagnostic — connect, capture, analyze, report

Your job: reach the **booted** Nexus Q, capture its hardware + runtime state, and
return a tight verdict with evidence. Read-only — never change the device. The
heavy lifting in `scripts/diag/` is deterministic; your value is connecting,
running it, and reasoning about the findings + the hardware sweep.

## 1. Connect (links are flaky; the gadget renames every reboot)

Reliable path is the **USB gadget RNDIS net `172.16.42.1`**, but its host iface
NAME + MAC change on every reboot, so re-establish it each time. If the device was
just rebooted, BE PATIENT — it takes ~60–120 s to come up (and ~1-in-3 boots hit a
black-screen U-Boot quirk and need another reboot).

```sh
enx=$(ip -br link | awk '/enx/{print $1; exit}')          # find the new RNDIS iface
sudo nmcli dev set "$enx" managed no                       # NM grabs it otherwise
sudo ip addr add 172.16.42.2/24 dev "$enx"; sudo ip link set "$enx" up
ping -c1 -W2 172.16.42.1
```

- SSH: since the 2026-07-03 flash (v1.6.6-candidate) **key-based `ssh
  root@172.16.42.1` works** (baked authorized_keys) — use it. Fallback / older
  v1.6.5 image: **`user` / `147147`** (root denied there; escalate with
  `echo 147147 | sudo -S <cmd>`):
  `sshpass -p 147147 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null user@172.16.42.1`
  A reflash regenerates the device host key — `ssh-keygen -R` stale entries.
- Host-side sudo on THIS PC: try plain `sudo`; if it prompts,
  `op-cache "sudo petronijus-PC" password`.
- Prefer the repo's own `scripts/diag/nqctl` if it already knows the link
  (`nqctl status`, `nqctl run '<cmd>'`).
- Fallbacks: **serial** `/dev/ttyACM0` @115200 (`steelhead login:`, user/147147) —
  works even with no net; **WiFi** vlan20 — last-known lease
  **`192.168.20.184`** (2026-07-12; the router reassigned `.195`→`.184` even
  though the image pins the **factory MAC `f8:8f:ca:20:48:e1`** — the MAC is
  stable, the lease is NOT; never hardcode the WiFi IP). Older images: the
  interim `#27` used the chip's OTP
  `14:7d:c5:3a:35:b5` (lease `.175`); v1.6.5 randomized the MAC per boot.
  If it moved, find the lease in OPNsense Kea
  (`opnsense-api GET /api/kea/leases4/search`) by hostname `steelhead` or the
  MAC per the image (factory on `#29`+, OTP on `#27`; on the older v1.6.5
  image the MAC is per-boot randomized and the IP wanders — hostname-match
  only). This host may not route into vlan20.
- If NOTHING answers on any transport after a few minutes, STOP and report that
  (likely the black-screen boot quirk → needs a re-reboot). Don't loop forever.

Device facts: hostname `steelhead`; a fresh rootfs flash WIPES device-side static
IPs + saved WiFi, so don't assume a fixed IP or that WiFi is configured.

## 2. Runtime health — run the deterministic tooling

From the repo root, the one command does link-find → on-device snapshot →
nq-healthd time-series → save under `nq-captures/<ts>/` → analyze:

```sh
scripts/diag/nq-collect            # [OUTDIR] [--burst N] [--interval S]
```

Watch an intermittent fault longer with e.g. `--burst 60 --interval 2`. The
capture holds `report.txt` (human), `report.json` (`summary.worst_severity` is the
verdict), `snapshot.txt` (full device dump), `health.jsonl`, `events.jsonl`. If the
running image predates `nq-healthd`, nq-collect bootstraps the tools into `/tmp`
and gathers a short live burst. Paths are documented in `scripts/diag/README.md`.

## 3. Hardware-inventory sweep (answer the concrete questions)

The runtime tooling focuses on nexusqd/power/thermal/cpufreq; ALSO sweep the
hardware the user usually asks about, via ssh. Quote the evidence line for each:

- **Bluetooth + A2DP** (BCM4330B1, UART2/`hci_uart_bcm`): `dmesg | grep -i bluetooth`
  — did the patchram load (finds `brcm/BCM4330B1.hcd`) or "Patch file not found,
  tried:"? `hciconfig -a` / `bluetoothctl show` → is `hci0` UP, and is the controller
  address the real **F8:8F:CA:20:49:E5** (NOT the old `43:30:A0:00:00:00`)? Missing
  `.hcd` → `/lib/firmware/brcm/BCM4330B1.hcd` absent. **`hci0: Frame reassembly failed
  (-84)` (EILSEQ) is NOT benign** — it means the host UART baud drifted from the
  controller; the DTS BT node needs `max-speed = <3000000>` (kernel patch **0040**,
  v1.8.0) so `hci_bcm` syncs both ends to 3 Mbaud. Before 0040 this produced tx
  timeouts, a phantom "Connected" state, and A2DP in corrupt bursts → count MUST be
  0 now. It was **NOT** WiFi/BT coexistence and **NOT** HFP/SCO. For A2DP, check the
  PA `bluez_source` appears (`pactl list short sources`) while a phone is connected.
- **WiFi** (BCM4330, `brcmfmac`): `dmesg | grep -i brcmfmac` — did
  `brcm/brcmfmac4330-sdio.bin` load or fail "-2"? `iw dev` → does `wlan0` exist?
  `sudo iw dev wlan0 scan | grep -iE 'SSID|freq'` → does it SEE 5 GHz APs (freq
  >5000)? `iw dev wlan0 link` / `nmcli dev status` → connected? band + signal?
  (A fresh flash has no saved creds, so "not connected" ≠ "broken" — distinguish
  radio/firmware working from network not configured.) brcmfmac wants
  `brcm/brcmfmac4330-sdio.bin` + nvram `brcm/brcmfmac4330-sdio.txt` (NOT the bcmdhd
  `fw_bcm4330*.bin` from firmware-aosp-broadcom-wlan — different driver).
- **Ethernet** (SMSC LAN9500A over USB EHCI): `ip -br link`, `ethtool eth0`.
  ✅ **task #17 FULLY CLOSED 2026-07-06 — enumerates from a cold boot on `#33`+
  (v1.6.8).** The old "enumeration intermittency" was NOT a race — it was an
  **unmuxed `gpio_1` NENABLE pad** (`kpd_col2` @ CORE padconf `0x186`; the DTS
  muxed only `gpio_62` NRESET at `0x08c`), so gpiolib drove the DATAOUT latch
  (debugfs "asserted") while the pad stayed safe_mode → the chip was never
  powered → USB CCS=0. Fixed by the DTS pad mux (patch 0003, kernel `#33`); the
  "0/3 vs 3/3 boots" was stock priming, not a race. Gold-validated: clean flash +
  true cold power-cycle → `eth0` 100Mbps/Full, 0 failed units. On a **pre-`#33`**
  image `eth0` may be absent on a cold boot (that unmuxed pad) — report as the
  known #17 root cause and note the kernel is out of date, not a new regression.
  ✅ The **NM layer is resolved** (2026-07-04, baked eth0 profiles in device r21,
  in the image since v1.6.7): when `eth0` exists the link is healthy
  (100Mbps/Full, 0 errors, stable carrier) — eth0 sits quietly at NM
  "disconnected" (or "connected" if `eth-direct` was activated / a real LAN gave
  a lease). **`NetworkManager-wait-online` PASSES even with the chip absent**
  (graceful degradation) — a wait-online failure is a REAL fault, report it. A
  recurring ~47 s activate/deactivate loop in the journal = the r21 profiles are
  missing (pre-v1.6.7 image). NB eth0's hw MAC is random per boot (no MAC
  EEPROM) — a changing LAN lease is expected, not a fault.
  - **gpio-debug lesson (record for reuse):** debugfs / `gpiolib` reporting a
    line "asserted" only means the **DATAOUT latch** is driven — NOT that the pad
    is routed to the pin. Verify the **IOPAD mux** (`mmio r 0x4A1000xx` / a live
    stock `omap_mux` dump) before trusting a gpio; a healthy sibling can mask a
    completely unmuxed control line. Same failure class hit NFC and ethernet.
- **NFC** (NXP PN544, i2c 2-0028) — the chip **works since `#29` (2026-07-03**, the
  pinmux fix; on older kernels the node is disabled/mis-muxed):
  `ls /sys/class/nfc/` → `nfc0` present; dmesg should show
  `NFC: nfc_en polarity : active high` **without** a "Could not detect …
  fallback" line (the fallback line = the pre-fix symptom). RF path exercised
  2026-07-04 (netlink poller: repeated `NFC_EVENT_TARGETS_FOUND` + card data frames).
  🆕 **NFC tap-to-send SHIPPED v1.7.0 (device r33, kernel r37):** `nexusq-nfc.service`
  runs `/usr/bin/nexusq-nfc-send`, a **reverse-HCE reader daemon** that OWNS `nfc0`
  (raw `PF_NFC` netlink poll + ISO-DEP raw socket) and pushes `NQ_NFC_MESSAGE` to a
  phone running the companion app's HostApduService on each tap (AID `F0010203040506`).
  **Checks:** `systemctl is-active nexusq-nfc` = active; its journal shows the poll
  loop (`[nfc] daemon: listening…`) and, on a real tap, `*** SENT … phone received
  it ***`. **neard is intentionally NOT installed** — the daemon owns the device; if
  a diag needs raw NFC, `systemctl stop nexusq-nfc` first (don't run a second NFC
  consumer against `nfc0`). The enabling kernel change is **patch 0037**: the pn544
  driver now RATS-activates **any** ISO-DEP target (`sel_res & 0x20`), not just
  Mifare DESFire — without it a modern **Android HCE phone (ATQA 0x0004 / SAK 0x20)**
  stays layer-3 and the chip returns `ANY_E_NOK` (phone never gets the SELECT APDU).
  ⚠️ Do NOT kill an active NFC poll session mid-poll (`timeout`/harness kills) — it
  wedges the pn544 HCI state until reboot (known fragility). See
  `docs/2026-07-08-nfc-tap-to-send-reverse-hce.md` and
  `docs/2026-07-04-ethernet-resolved-and-led-guard.md` (NFC section).
- **CPU 1.2 GHz** (OMAP4460 MPU): `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies`
  (expect `350000 700000 920000 1200000`), `scaling_governor` (expected:
  **`ondemand`** since the 2026-07-03 flash — verified, with
  `CPU_FREQ_STAT`/`time_in_state` present; `conservative` on the older v1.6.5
  image), `scaling_max_freq`.
  Put load on (`yes >/dev/null &`), read `cpuinfo_cur_freq`/`scaling_cur_freq`, kill
  it → confirm it reaches 1200000. Thermal: `cat /sys/class/thermal/thermal_zone*/temp`.
  (Idle is NOT 350 MHz — it hovers ~920 MHz, nexusqd LED polling keeps it up.)
  2026-07-03 reference: 1200 MHz @ 1 380 000 µV load / 920 MHz @ 1 317 000 µV
  idle (exact OPP tracking); idle 66–78 °C, peak **91.8 °C** under dual-core
  load — only ~8 °C headroom to the 100 °C trip, so a sustained-load diag
  SHOULD report the peak temp (expected-hot, but watch it). **2026-07-06
  (v1.6.9/v1.6.10) the peak sits ~94–99 °C** under sustained dual-core load —
  still below the 100 °C passive trip, no throttle, but the headroom is thin;
  this is an active watch-item, always report the peak.
- **SMP** (`nproc` should be **2**, `cat /sys/devices/system/cpu/online` = `0-1`) —
  dual-core works since v1.2.0; flag any single-core boot as a regression.
- **Audio / TAS5713** (ALSA card `NexusQSpeaker`, McBSP2 → TAS5713): `aplay -l` shows
  the card; the path **plays at correct pitch/speed** since **v1.6.1** (kernel patch
  0022 — derives McBSP2 `CLKGDV` from the real fclk). To sanity-check: time a
  fixed-length clip/silence — should match wall-clock (~1.000×).
  🚨 **MAJOR (fixed v1.6.13, kernel r36): the physical speaker was SILENT the whole
  project until 2026-07-07.** The ALSA/PCM/softvol pipeline was healthy end-to-end
  (`aplay` rc=0) but nothing reached the amp: `mcbsp2_pins` muxed the WRONG balls
  (`0x110/0x114/0x116` = `abe_dmic_*`, NOT McBSP2), so the real I2S balls
  (`0x0f6` clkx / `0x0fa` dx / `0x0fc` fsx) sat in `safe_mode` (no clock/data/frame).
  Fixed to the stock pads at `MUX_MODE0`. **So any pre-v1.6.13 "TAS5713 audio works"
  claim was software-pipeline-only.** Same failure class as NFC/ethernet: an unmuxed
  pad on a healthy driver. If the amp goes silent again with `aplay` rc=0, suspect the
  pinmux, not the driver. See
  `docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md`.
  🔀 **Audio routing is PA-centric since v1.6.15 (device r31 / nexusq-control r6):**
  the old direct-ALSA `type multi` fan-out is GONE. librespot is now a PulseAudio
  INPUT (systemd USER unit, `--device pulse`); the active OUTPUT (speaker / SPDIF /
  HDMI) = the PA **default sink**, switched from the companion app via `nexusq-control`
  `setOutput` (`pactl set-default-sink` + move all sink-inputs + a class-D amp Speaker
  safety toggle + point PA default-source at the active `<sink>.monitor`). Volume/mute
  are `pactl` on the active sink. **Checks:** `pactl list short sinks` (as uid-10000,
  or root with `PULSE_SERVER`/`PULSE_COOKIE`) shows the tas5713 + spdif sinks; both
  report **48000 Hz** (PA pinned to 48 kHz by `50-nexusq-48k.conf` — 44.1 kHz detunes
  the McASP DIT, "off by 88435 PPM"). **Volume gain RESOLVED** (v1.7.2 kernel patch
  0038 Master dB-scale shift + device r35 post-install pinning the per-channel
  Speaker at unity — PA was stacking Master+Speaker `volume = merge` = +48 dB at
  100%; now Master-only: PA 50% = +6 dB, 100% = +24 dB, user-confirmed). Note: r35 +
  nexusq-control r8 (dial→app sync) are BUILDING into v1.7.3, verified live but not
  yet in a flashed image. Deferred polish: boot default should be speaker-not-spdif.
  **Crackle / "lupance" CLOSED 2026-07-12 — it was TWO independent faults, both
  fixed in the kernel** (diagnosis history: 2026-07-08 DMA-contention note +
  2026-07-09 output-path isolation). (a) Load-correlated drops = memory-bus / DMA
  contention (the McBSP2 audio SDMA underflows the FIFO in HARDWARE under L3/EMIF
  contention — `0` PA XRUN / `0` dmesg underruns / low CPU does NOT rule it out,
  it sits below the PA buffer and below thread scheduling) → fixed by kernel
  **r41** patch **0041** (sDMA `CCR_READ_PRIORITY` on the cyclic audio channel +
  GCR `HI_THREAD_RESERVED=1`). **Healthy tell:** sDMA `GCR = 0x00011010` and the
  active audio channel's CCR has **bit6 = 1** (verified live on ch20).
  (b) A metronomic ~1/s load-independent click = TWO free-running crystals
  (mainline reparents the DPLL_ABE ref to sys_32k while TAS5713 MCLK sits on the
  38.4 MHz crystal; ~21 ppm ≈ 1 sample slip/s @ 48 kHz) → fixed by kernel **r42**
  patch **0042** (DPLL_ABE relocked from sys_clkin at 98.304 MHz, stock topology).
  **Healthy tell:** `/sys/kernel/debug/clk/clk_summary` shows
  `abe_dpll_refclk_mux_ck` under `sys_clkin_ck` and `dpll_abe_ck` at **98304000**;
  a mux back under `sys_32k_ck` or a different DPLL_ABE rate = the fix regressed
  and the 1 Hz click will return. Verified clean playback on `#43-postmarketOS`
  (user-confirmed). Notes: `docs/2026-07-12-audio-crackle-closed-sdma-priority-and-dpll-abe.md`
  (+ `docs/2026-07-08-audio-crackle-dma-contention.md` for the contention diag method).
  ℹ️ **Historical (FIXED in v1.6.1):** the v1.6.0 path played **2× too fast** (FSYNC at
  2× rate; 60 s drained in ~30 s), which made a librespot/Spotify track **auto-skip
  ~40 s in** — that was the audio-clock bug, **not** a librespot crash (the service
  stayed up; `librespot_restart` is a real restart). If the ~40 s auto-skip ever
  returns it's an audio-clock regression. See
  `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.
  ℹ️ **HDMI-audio card (v1.6.9):** the `omap-hdmi-audio` ALSA card is a
  snd-soc-dummy-DAI — NOT a usable sink (HDMI is desktop video only). PulseAudio
  now **ignores** it via a `PULSE_IGNORE` udev rule so `module-alsa-card` no
  longer errors every boot. **Lesson — ALSA card indices are probe-order
  dependent:** the first rule pinned `KERNEL=="card1"` and broke (HDMI came up
  as card2 one boot, tagging the wrong card); the shipped rule matches the
  backing device `KERNELS=="omap-hdmi-audio.1.auto"`. Any per-card udev/PA rule
  you write MUST match by backing device (`KERNELS=`) or card id, **never** by a
  `cardN` index.
  ✅ **Desktop audio sink (v1.6.12, device r30):** the LXQt/labwc **Wayland**
  desktop had a **red-cross no-sink tray icon** — PA never started (Alpine ships
  no PA systemd user unit; the XDG autostart `start-pulseaudio-x11` never fires
  under systemd+Wayland — `xdg-desktop-autostart.target` dead — with
  `autospawn=no`). Fixed by a native `pulseaudio.service` systemd USER unit
  (`default.target.wants/` symlink; plain daemon, NOT socket-activated — a socket
  double-binds PA's own native socket → "bind(): Address in use"), plus a 2nd
  PULSE_IGNORE rule for the snd-aloop **Loopback** (`KERNELS=="snd_aloop.0"`) so
  PA's ONLY sink is the TAS5713 speaker (Loopback had grabbed the default sink at
  card index 0). **Check:** `systemctl --user is-active pulseaudio` = active, and
  `pactl get-default-sink` = `alsa_output.platform-sound-tas5713.stereo-fallback`
  (NOT `…snd_aloop…`). Red cross / `pactl` "Connection refused" = PA down =
  regression. See `docs/2026-07-07-desktop-audio-pulseaudio-fix.md`.
- **LED music-visualizer tap + AGC (v1.6.15, nexusqd r7):** the visualizer no longer
  reads the snd-aloop loopback — nexusqd runs `arecord -D pulse` capturing PA's
  **default SOURCE**, which `nexusq-control` keeps pointed at the active sink's
  `.monitor` (so the LED follows the selected output). nexusqd is root and reaches the
  uid-10000 PA via `PULSE_SERVER`/`PULSE_COOKIE` in `nexusqd.service`. An **AGC**
  (`audiocap.c`, `AGC_TARGET 0.15`, fast attack / slow release, noise-gate) normalizes
  the post-volume monitor level so the ring reacts to the MUSIC at any listening
  volume. **Healthy tell:** a steady `audio DETECTED vol=0.150` (== AGC_TARGET) in the
  nexusqd log. The pre-AGC symptom was the visualizer **flickering ↔ breathing at low
  volume** (raw level below threshold) — if that returns, the AGC/monitor tap
  regressed. See `docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md`.
  ✅ **Tap is GATED on playback (v1.7.1, nexusqd r8):** the `arecord -D pulse` tap
  used to run continuously (uncorked PA source-output → the `tas5713` sink stayed
  **IDLE/clocked** at silence → **~7 % idle CPU**, top idle-heat source). nexusqd now
  polls `pactl list short sink-inputs` and runs arecord **only while a real playback
  stream exists** (gate = sink-input **count, not level**). **Healthy idle tell:**
  no `arecord` process, the `tas5713` sink **SUSPENDED** (not IDLE) in
  `pactl list short sinks`, nexusqd **~0-1 % CPU** (was ~7 %). **During playback:**
  an `arecord` appears and the sink is **RUNNING**; **after** playback it re-gates off
  ~4 s later → SUSPENDED. Idle showing arecord running / sink IDLE / nexusqd ~7 % =
  the gate regressed. nexusqd now depends on `pulseaudio-utils` (pactl). See
  `docs/2026-07-08-audio-volume-scale-and-bootlog-cleanup.md`.
- **`ss` is NOT installed on the device** (busybox/Alpine minimal) — use **`netstat`**
  (`netstat -tlnp` / `netstat -ln`) to check listening sockets. (A `ss`-not-found caused
  a long "no listener" misdiagnosis of the PA/bridge sockets.)
- **python ON DEVICE** (armv7 SIGSEGV, **fixed 2026-06-28, v1.6.0**): `python3 -S -c '';
  echo rc=$?`. rc **0** = healthy (the v1.6.0 default-linker r5 build, clean-flashed);
  rc **139** = a corrupt libpython is installed. **ONE documented root cause:** a
  **FLASH** corruption — the old `DONT_CARE`-chunked `raw2simg` sparse skipped zero
  blocks on the non-erasing U-Boot, leaving STALE eMMC garbage in libpython's
  `.PyRuntime`/`.data.rel.ro` (→ wild type-index deref in `Py_Initialize`) — fixed by the
  **all-RAW (byte-exact) `raw2simg.py`**. (**NOT** a build/compiler/CPython-source bug:
  LTO/PGO, LDREXD alignment, TLSDESC, optimization level, and a qemu-user mmap
  build-corruption theory + gold-linker workaround were **all disproven/dropped** — 6/6
  default-linker builds were gate-clean.) So rc 139 means the device is running a
  **pre-v1.6.0** image (flashed with a `DONT_CARE` sparse). Confirm by comparing the
  on-device `libpython3.14.so.1.0` md5 against the known-clean v1.6.0
  (`79a0d4ace1358bb2d94c8a4d72479da9`) — a mismatch in only the zero-regions is the flash
  re-corruption. This on-device check is the runtime authority (qemu false-passes). Fix =
  flash a v1.6.0 (all-RAW) image; also check `gdb` (it links `libpython`, so it tracks
  python's state). See `docs/2026-06-28-session-findings.md`.

## 4. Interpret the findings

`report.json` `summary.worst_severity` is the verdict. By `kind`:
- **nexusqd_hang** (crit) — LED daemon alive but `nexusled status` socket dead = the
  classic ring-froze-and-never-came-back (a hang, so `Restart=on-failure` never
  fires). Confirm with **led_frozen** + **nexusqd_no_progress**. Real fix is an
  sd_notify watchdog/`WatchdogSec=` in `pmos/nexusqd/` — name it, don't hack around.
  ⚠️ **A dark ring is NOT a hang if the socket still answers** (`nq_resp=1`,
  `nexusled status` returns). Two non-hang cases: (a) **idle-off / blank** — by design
  after the screensaver blank timeout (`SS_BLANK_S=600 s`); don't report it as a hang (it
  tripped a false CRIT on 2026-06-28); (b) **AVR starvation** (FIXED v1.6.5) — a dark ring
  after a **long** idle/uptime (~20 h) with the socket alive: the `steelhead-avr` fw
  (`0x00`) starves (host-frame watchdog) when `nexusqd`'s `memcmp` write-gate stopped
  committing a static locked/blanked frame; `nexusqd` (pkgrel 5) now re-commits every
  `AVR_KEEPALIVE_S=1.0 s`. On a **≥ v1.6.5** image a dark-after-long-idle ring means the
  keepalive stopped (nexusqd/render loop), not a design blank. See
  `docs/2026-07-01-led-ring-avr-starvation-keepalive.md`.
  ⚠️ **`led_frozen` false-CRIT — depends on the flashed image.** On images up
  to `#27` / device r19 it is a **PERMANENT FALSE CRIT on nexusqd r5+** (found
  by the 2026-07-03 acceptance run): nq-healthd fingerprints the led_classdev
  `brightness` attributes, but nexusqd commits frames via the **write-only
  `frame` bin_attr**, so the sampled `led_sum` is structurally 0 and the frozen
  heuristic always trips — there, **ignore `led_frozen`** and judge the ring by
  `nq_resp`/`nexusled status` (+ eyes); do NOT re-diagnose it as a hang.
  **On `#29`/r20+ (flashed 2026-07-03)** patch 0029 makes `frame` readable
  (0644) and nq-healthd r20 fingerprints it (md5 + byte sum) — the LED
  fingerprint is real. ✅ **Static-by-design guard LIVE since 2026-07-04**
  (healthd r21 + `scripts/diag/nq-health-report`; **baked in the flashed image
  since v1.6.7, 2026-07-05** — verified live: 33× info `led_static`, zero
  false CRIT in 91 samples): the
  screensaver intentionally locks a **static** frame after ~300 s idle and the
  keepalive re-commits identical bytes, so a healthy idle device's fingerprint
  legitimately stops changing — that now emits **info `led_static`**, NOT a
  CRIT; `led_frozen` CRIT fires only when `nq_resp=0`/`nq_progress=0` co-fires
  (i.e. a `led_frozen` CRIT is now believable — treat it as a real
  ring/AVR/nexusqd hang). Expect `led_static` info lines on idle captures;
  they are healthy. (Only a device running healthd ≤ r20 still shows the old
  idle false CRIT.)
- **failed_unit** (warn/crit) — a systemd unit is failed. On a **pre-fix** image the
  usual culprit is **python**: `python3` SIGSEGVs on ARMv7 (`onboard`,
  `blueman-applet`, `sleep-inhibitor.service`, `gdb`) — a **flash** corruption (the old
  `DONT_CARE` `raw2simg` on the non-erasing U-Boot), **fixed** in v1.6.0 by the all-RAW
  flash (see §python above), not a daemon-specific fault. If these units fail, confirm
  with `python3 -S -c ''` (rc 139 = a pre-v1.6.0 corrupt python is flashed via a
  `DONT_CARE` sparse; needs a v1.6.0 all-RAW image); if python is rc 0, look elsewhere.
- **vdd_mismatch** — `vdd_mpu` off the OPP target (350→1025, 700→1203, 920→1317,
  1200→1380 mV). A few samples = a DVFS transition; persistent = VC-bridge/TPS62361
  power-path. Cross-check `POWER_REGULATORS`/`omap_voltage`/`ti-abb`/`tps`.
  ⚠️ Known tooling bug (2026-07-03, on images up to r19): healthd samples freq
  and vdd **non-atomically**, so a DVFS transition between the two reads
  fabricates a mismatch — re-read freq after vdd before believing a warning.
  **Fixed in nq-healthd r20** (flashed 2026-07-03 with `#29`; clean in the
  acceptance capture): the sample is only
  judged when `scaling_cur_freq` holds across the vdd read. Residual race
  (2026-07-05): the guard is not fully atomic — 1/91 samples slipped past it
  on the v1.6.7 acceptance; a single isolated warn is still noise, only a
  persistent run is a real power-path fault.
- **thermal_throttle / thermal_crit** — at/over 100 °C passive / 125 °C critical.
- **governor_not_scaling** — load was high but freq stuck at 350 MHz (cpufreq stall);
  see `CPU` + `CLOCKS` (`dpll_mpu`).
- **kernel_errors** — new oops/WARN/i2c-timeout/voltage lines; read `KERNEL_LOG_FULL`.
- **pstore** (crit) — a previous boot panicked (only survives a *warm* reboot).

Every boot/dmesg error is ours to fix — never dismiss one as benign/expected.
As of **v1.6.10** the boot log is **GENUINELY CLEAN**: on a clean-flash boot of
`#36` / device r28, **`dmesg -l err,warn` is EMPTY** and `journalctl -b -p
warning` contains **ONLY these 3 genuinely-external residuals** — anything else
is a **REGRESSION**, report it:
  1. **eth-lan DHCP fail** on a DHCP-less direct PC cable (environmental —
     `autoconnect=false` would break real-LAN plug-and-play);
  2. **kscreen `.service` D-Bus naming** (upstream libkscreen packaging lint, hard
     dep via lxqt-config);
  3. **avahi `No NSS support for mDNS`** (`nss-mdns` unpackaged in pmOS/Alpine;
     avahi's publish path for librespot Spotify-Connect zeroconf works fine).
The whole former B/U residual set (B4 brcmfmac fw-probe, B10 hw-breakpoint, B16
ramoops, B21 L2C/gpmc/pmu/journald-BPF+ACL, B22/B23 twl, U5 bluetoothd
system-config, U7 nsresourced, U4 HDMI-audio, U6 gkr-pam) is **FIXED / downgraded
/ disabled in v1.6.10** — do NOT report any of them as benign; their return is a
regression. Notable v1.6.10 truths: BPF is now enabled (systemd IP-hardening
functional; no IP-firewall notice); the L2C aux-modify notice is an **authorized**
`pr_debug` downgrade (register end-state identical to stock); Bluetooth BD_ADDR is
the real per-device `F8:8F:CA:20:49:E5` (was placeholder `43:30:A0:00:00:00`).
Full disposition table: `docs/2026-07-02-boot-error-inventory.md` (v1.6.10
update) + `docs/2026-07-06-bootlog-cleanup.md`.
ℹ️ **DEBUG-level noise on v1.7.0/v1.7.1 images (NOT an err/warn regression):** the
continuous pn544 NFC-tap poll emits **~200 "shdlc: 00000000: .." lines/boot**, and
the old cmdline (`ignore_loglevel` + `loglevel=7`) forces the whole debug firehose
(incl. gpiolib "can't parse scl-gpios") onto the HDMI console. This is
**debug-level**, so `dmesg -l err,warn` stays EMPTY — do not report it as a
regression. **Silenced in v1.7.2** (BUILDING, not yet flashed): patch `0039`
(`print_hex_dump_debug`, no-op here) kills the shdlc dumps, and the cmdline drops
`earlyprintk`+`ignore_loglevel` with `loglevel=7`→`4`
(`kernel/configs/steelhead_defconfig`, `scripts/repack-bootimg.sh`,
`build-noramdisk.sh`). Once v1.7.2 is flashed, verify the shdlc lines are gone and
the console is no longer at debug level. Diag boot scripts stay verbose on purpose.
See `docs/2026-07-08-audio-volume-scale-and-bootlog-cleanup.md`.
**No serial console exists** on
this device (fastboot + ssh + stock/our build only) — deep cpuidle C2/C3 is
BLOCKED (resume hang can't be debugged blind), not a diag finding.

## 5. Report back

Return:
1. A **yes/no hardware table**: BT | WiFi (firmware OK? sees 5 GHz? connected?) |
   eth (carrier) | CPU reaches 1.2 GHz — one evidence line each.
2. The **runtime verdict** (`worst_severity`) + each finding with its evidence
   (quote the timeline/snapshot section), and—if a finding implies a code fix—name
   the file to change (e.g. `pmos/nexusqd/`), not a workaround.
3. Where the capture was saved (`nq-captures/<ts>/`) for later good-vs-bad diffs.

Keep it tight — the verdict and evidence, not the capture scroll.
