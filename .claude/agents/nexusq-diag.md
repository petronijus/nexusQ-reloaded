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
  **`192.168.20.184`** (2026-07-12; the lease is NOT stable — never hardcode the
  WiFi IP).
  ⚠️ **WiFi MAC — version boundary at v1.10.1.** On **v1.10.1+** wlan0's
  permanent MAC is the **factory `f8:8f:ca:20:48:e1`** (kernel patch 0043 pins
  `local-mac-address` in the DTS; `ethtool -P wlan0` confirms) and the lease
  carries the `steelhead` hostname — **match by the factory MAC or hostname**. On
  **≤ v1.10.0** wlan0 ran the chip **OTP MAC `14:7d:c5:3a:35:b5`** (Murata OUI)
  with an **empty hostname** (the NM `cloned-mac-address` pin only reached the
  baked profile — found 2026-07-15; the factory MAC was injected nowhere at
  runtime) — match those by the OTP MAC. (v1.6.5 and older randomized the MAC per
  boot.) If it moved, find the lease in OPNsense Kea
  (`opnsense-api GET /api/kea/leases4/search`) by the MAC appropriate to the
  image. This host may not route into vlan20.
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

Since 2026-08-10 `health.jsonl` also feeds the on-device **`nexusq-mqtt`** daemon
(retained health JSON + HA discovery to the home Mosquitto, 30 s cadence, freshness
gate ≤60 s) — so a healthd field rename/semantic change also breaks the MQTT/Home
Assistant view, and `systemctl status nexusq-mqtt` + the HA `nexusq` device are an
extra remote health read when ssh is down (`nexusq/status` retained topic =
online/offline LWT).
⚠️ **`healthd_fresh:false` with `nq-healthd.service` active ≠ a dead sampler**
— on device **r77–r79** (fixed **r80**, 2026-08-23) the C daemon's log rotation
renamed `health.jsonl` without closing its stream, so it wrote into
`health.jsonl.1` forever (unbounded) and `health.jsonl` was never recreated.
Check `ls -la /var/log/nq-health/` first: `.jsonl` absent + a growing `.1` =
that bug, not a hung daemon. `docs/2026-08-23-healthd-rotation-and-ota-holdback.md`.

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
  PA `bluez_source` appears (`pactl list short sources`) while a phone is connected
  (healthy: `bluez_source…a2dp_source s24le 2ch 48000Hz` + the PA loopback).
  **Pairing broken?** It is **userspace until proven otherwise** — check for a second
  BlueZ agent (`blueman-applet`) before suspecting the controller; see the setup-mode
  entry below. Loaded patchram must be **Phantasm build 0749** (md5
  `7e5bb859e33142e94052c76fba23b9e6`), not the wrong `Proxima … NoExtLNA` build-0482
  blob that shipped through v1.8.2.
- **WiFi** (BCM4330, `brcmfmac`): `dmesg | grep -i brcmfmac` — did
  `brcm/brcmfmac4330-sdio.bin` load or fail "-2"? `iw dev` → does `wlan0` exist?
  `sudo iw dev wlan0 scan | grep -iE 'SSID|freq'` → does it SEE 5 GHz APs (freq
  >5000)? `iw dev wlan0 link` / `nmcli dev status` → connected? band + signal?
  (A fresh flash has no saved creds, so "not connected" ≠ "broken" — distinguish
  radio/firmware working from network not configured.) brcmfmac wants
  `brcm/brcmfmac4330-sdio.bin` + nvram `brcm/brcmfmac4330-sdio.txt` (NOT the bcmdhd
  `fw_bcm4330*.bin` from firmware-aosp-broadcom-wlan — different driver).
  🆕 **WiFi PERMANENT MAC (v1.10.1+, kernel patch 0043):** `ethtool -P wlan0` (or
  `cat /sys/class/net/wlan0/address`) MUST report the **factory
  `f8:8f:ca:20:48:e1`** on a v1.10.1+ image. If it reads the chip **OTP
  `14:7d:c5:3a:35:b5`** (Murata OUI) on a v1.10.1+ image, patch 0043 regressed
  (the DTS `local-mac-address` on `wifi@1` is missing from the built DTB, or the
  wrong kernel is flashed) — report it. On ≤ v1.10.0 the OTP MAC is EXPECTED (the
  fix predates them). brcmfmac programs the DT MAC over OTP via `brcmf_of_probe()`;
  the nvram `macaddr=` is ignored either way.
  🆕 **5 GHz TX-dead wedge — FIXED by `roamoff=1`, watchdog-monitored (2026-08-02).**
  On long uptimes the BCM4330 could stay associated at good signal but pass **zero
  traffic** (100 % loss to the gateway) with `brcmf_escan_timeout` flooding every
  ~58 s — the chip failing in-firmware background *roam* scans. Fixed by
  **`brcmfmac roamoff=1`** (`brcmfmac-roamoff.conf`, device r56 — the Q never roams).
  A **`nexusq-wifi-watchdog.service`** (device r57, default-ON) gateway-pings every
  30 s and auto-bounces `wlan0` after 3 failures, logging health to
  **`/var/log/nq-health/wifi-watchdog.jsonl`** (check it for `heal` events / loss %).
  **Healthy tell:** `modprobe -c | grep brcmfmac` shows `roamoff=1`; the watchdog log
  is steady "ok" with no heals (a 29 h clean run 2026-08-01 confirmed the fix). Any
  return of `brcmf_escan_timeout` in `dmesg`, or repeated watchdog heals, = a
  regression. The old "5 GHz TX degrades intermittently, open" verdict is **retired**.
  🆕 **`nogw` heal (device r61, 2026-08-02):** the watchdog also heals a second wedge —
  `wlan0` associated at good signal but NM stuck in "getting IP configuration" (DHCP got
  no lease → an IP but **no default route/gateway**, LAN unreachable). A `"st":"nogw"`
  line now carries `"fails"` and triggers the same `wlan0` bounce once it reaches the
  heal threshold (pre-r61 it held `fails=0` and never healed the exact case it was built
  for). Repeated `nogw` heals in the log = a DHCP/AP problem worth chasing.
  🆕 **`reconnect` path (device r93, 2026-09-05):** the heal itself could STRAND the box.
  `nmcli device disconnect` blocks NM autoconnect until an explicit connect; when the
  `connect` half failed (empty scan cache: *"A 'wireless' setting is required if no AP
  path was given"*) the old `down` branch did nothing — the cottage Q logged 16 536
  `"st":"down"` lines over six days on an otherwise healthy box. Now `down` lines carry
  `"nm"` (NM state) + `"downs"`; state 30/120 for `NQ_WIFI_DOWNS` (4 ≈ 2 min) →
  `"ev":"reconnect"` (rescan + `nmcli device connect`) → `"ev":"reconnect_result"` with
  `"assoc"`. `heal_result` also carries `"assoc":"yes|no"`. **Reading it:** `down` with
  `nm:"30"` and climbing `downs` but no `reconnect` = pre-r93 script (fix by hand:
  `nmcli device connect wlan0`, or reboot); repeated `reconnect_result assoc:"no"` = the
  AP is genuinely gone; `heal` every ~5–12 min at −42 dBm `loss:100` = the TX wedge
  recurring (seen for 24 h after a **runtime** `cloned-mac-address` change — open
  question; prefer a reboot after any MAC change).
  `docs/2026-09-05-six-days-dark-and-the-ota-that-renamed-the-cottage.md`.
  ℹ️ **Two units in the fleet:** Prague (`f8:8f:ca:20:48:e1`, `192.168.20.x`) and the
  cottage `nexus-q-sumperak.local` (`f8:8f:ca:05:1f:11`, BT `F8:8F:CA:73:AC:9C`, DHCP on
  `<cottage-lan>/22` since 2026-08-30). If a unit reports the OTHER unit's MAC/BD_ADDR
  after a kernel OTA, that is the kernel-ota ≤ r4 identity loss — `nq-kernel-ota identity`
  shows what each slot claims; r5 carries it.
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
  (raw `PF_NFC` netlink poll + ISO-DEP raw socket) and pushes a payload to a
  phone running the companion app's HostApduService on each tap (AID `F0010203040506`).
  Payload: on images ≤ v1.8.2 a static `NQ_NFC_MESSAGE` text; **since device r44
  (2026-07-13, released in v1.9.0) it is live connection-info JSON**
  `{"v":1,"bt","host","ip","prov"}` rebuilt per tap by `build_payload()` — the unit
  must NOT set `NQ_NFC_MESSAGE` (it overrides the builder; a set value on an
  r44+ image is a regression — manual-test override only).
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
- 🆕 **Streaming inputs + per-service app toggles (v1.11.0 step 3; USB audio
  post-v1.11.0 dev).** The Q has **four** audio inputs: **Spotify** (librespot) +
  **AirPlay** (shairport-sync) + **Roon** (`roon.service`, glibc/bwrap) mix into the
  default PulseAudio sink (TAS5713) — and so does **USB Audio**
  (`nexusq-uac2-in.service`), via a snd-aloop hop since device r70, 2026-08-12 *(it was
  EXCLUSIVE and PA-bypassing in r65–r69; see below)*. Spotify + AirPlay are
  **vendor-default-ON**; Roon + USB Audio are **default-OFF**. `nexusq-control` **r16**
  exposes each as an app switch (`SERVICES`: spotify/airplay/roon/usbaudio). ⚠️ **An
  INACTIVE default-OFF unit (roon, usbaudio) is NORMAL, not a `failed_unit`.** ⚠️
  **`set_service` OFF uses `disable --now` for the default-OFF units and `mask --now`
  only for the vendor-default-ON ones** (a new `vendor_on` flag) — because `mask --now`
  `/dev/null`s a unit before stopping it, dropping `KillMode`/`ExecStop`, so a service
  with a SIGTERM-trap cleanup like `nexusq-uac2-in` (its trap stops the silence watcher,
  unloads its two PA modules — loopback before source — and kills `alsaloop`) would
  **skip its cleanup** on OFF (leaving `alsaloop` running and a stale `usb_in` source
  stacked on the aloop substream). **USB Audio input** (the Q as a USB DAC): kernel r46
  `CONFIG_USB_CONFIGFS_F_UAC2` + a `uac2.0` function on the composite gadget
  (`c_chmask=3`, `p_chmask=0` = a USB speaker, not a mic) surface the host audio as the
  `UAC2Gadget` ALSA capture card.
  - ⚠️ **THROUGH PulseAudio over a stable-clock snd-aloop hop (device r70, 2026-08-12)**
    — *was* the exclusive, PA-bypassing direct bridge of the 2026-08-09 r65 rewrite, which
    itself replaced a PA `module-alsa-source` + `module-loopback` bridge. Today
    `nexusq-uac2-in` runs `alsaloop -C hw:UAC2Gadget -P hw:Loopback,0,0 --sync=simple` into
    snd-aloop, and PA reads the stable side as source **`usb_in`** and loops it into the
    default sink. **Healthy tell when ON and the host is streaming:** `UAC2Gadget` capture
    card present + `nexusq-uac2-in` active + an **`alsaloop` process running** + a `usb_in`
    PA source + the tas5713 sink **RUNNING**. ⚠️ **A SUSPENDED tas5713 sink is no longer
    the expected state** (it was, r65–r69), USB audio **mixes** with Spotify/AirPlay/Roon,
    volume is the ordinary unified PA volume, and the **LED visualizer DOES react** to USB
    playback — the old "visualizer is blind to USB audio" note is retired. `--sync=simple`
    (NOT `--sync=samplerate` — the device's `alsa-utils` lacks libsamplerate, so
    `samplerate` fails `Loopback start failure`). The Q has **no optical/HDMI/line input**
    (all ports are OUTPUTS) — USB is the only no-solder digital audio in. See
    `docs/2026-08-02-usb-audio-input.md`.
  - ⚠️ **PARKED is a normal state, not a fault (device r88 → r90, 2026-08-30).** With the
    USB host attached but not streaming, the service stops `alsaloop` entirely: the unit
    is **active** with **no `alsaloop` process** and no `usb_in` source. Do not report that
    as a dead bridge. Ground truth for *is the host streaming* is the gadget's own control
    **`numid=4,iface=PCM,name='Capture Rate'`** (`amixer -c UAC2Gadget controls` to resolve
    the numid, then `cget numid=<N>`; **`iface=PCM`, not MIXER** — `cget name='Capture Rate'`
    returns nothing, which is why it went unnoticed). **0 = host not streaming**, and it
    tracks the HOST's alt-setting, so it stays 0 even while we hold the PCM open. Parked,
    the service polls it every 4th 3 s tick (12 s); it probes with a real `alsaloop` only
    when it parked from a *wedge* (rate non-zero, input frozen), and falls back to the old
    30 s probe — announced loudly at startup — on a kernel without the control. Journal:
    `host stream is closed; polling the rate flag every 12s` / `host started streaming at
    <rate> Hz`. This replaced r88's duty-cycled probe, which was **99 % of all time above
    350 MHz** on an idle box (350 MHz 85.40 → **90.40 %**, 1200 MHz 7.05 → **0.17 %**,
    relative dynamic power 1.54× → **1.21×**).
  - ⚠️ **The 28 h spin, fixed in r88 (2026-08-30).** A UAC2 host that stops sending
    *without* closing the stream leaves the gadget substream at `state: RUNNING` with
    `hw_ptr` frozen; `alsaloop` then spun at 19–25 % of a core and held 1200 MHz / ~78 °C
    for a day and a half while `kill -0` supervision called it healthy, and
    `nq-uac2-silence` sat in a blocking read and stopped logging entirely. **Tell: 350 MHz
    residency near 0 with nothing playing.** Supervision now measures whether INPUT is
    arriving (`hw_ptr` advancing), not whether the process is alive, and the watcher reads
    through `select()` with a timeout (`NQ_UAC2_READ_TIMEOUT_S`, 5 s) so a quiet producer
    is *reported* instead of making it vanish. See
    `docs/2026-08-30-release-reaches-nobody-and-the-flag-the-gadget-had.md`.
  - ⚠️ **"Active, running, and still silent" — the loopback can read the WRONG source
    (fixed in device r92, 2026-09-01).** PA's stock `module-switch-on-connect` makes each
    newly appeared source the default **and moves existing source-outputs onto it**, so
    `roon-nexusq` loading `roon_in` dragged the USB `module-loopback` off `usb_in` — and
    USB starting stole Roon the same way; whichever input came up last won. Nothing
    reports it: the module stays loaded, only its binding changes, and PA logs no move,
    which is why `ensure_modules()` (module *existence*) cannot see it. Check the
    source-output, never the module argument: `pactl list source-outputs` → `Owner Module`
    vs `Source:`, compared with `pactl list modules | grep -A2 module-loopback`. Both
    loopbacks now carry `source_dont_move=true`, so a forced
    `pactl move-source-output <id> roon_in` answering `Failure: Invalid argument` is the
    HEALTHY state. `docs/2026-09-01-loopback-source-stolen.md`.
  - ✅ **FIXED 2026-08-09 — do NOT re-flag the old PA-bridge bugs.** The pre-r65 PA
    bridge had TWO faults: (a) USB-Audio drifted **~3 min LATE over a long session**
    (`module-alsa-source` reported a bogus uptime-growing latency, ~5134 s, poisoning
    `module-loopback`'s resampler → pegged the ±1 % rail, backlog grew to minutes), and
    (b) it **burned steady CPU + heat in silence** (the loopback sink-input was never
    corked, so `module-suspend-on-idle` could never suspend the amp; ~15–20 % CPU + ~5 °C).
    Both are GONE: `alsaloop` rate-matches from real hardware pointers with bounded ALSA
    buffers, and the aloop hop keeps PA reading a well-behaved, timer-clocked PCM. See
    `docs/2026-08-08-usb-audio-playback-delay-and-ota-publish.md`.
- 🆕 **Setup mode / `nexusq-setupd` + `nexusq-btagent` (**v1.9.0** = device r47 /
  setupd r4 / btagent r1 / nexusqd r10 / kernel r43 / firmware r2 — NOT on flashed
  ≤ v1.8.2):** a BT RFCOMM
  WiFi-provisioning daemon (`nexusq-setupd.service`,
  `ExecCondition=/usr/bin/nexusq-setup-needed`) plus the **permanent** pairing agent
  (`nexusq-btagent.service`, `Restart=always` — runs the WHOLE uptime, since A2DP
  needs a bond long after setupd exits).
  **Expected states:** provisioned boot (a WiFi NM profile exists, no
  `/run/nexusq-setup.force`) → **setupd inactive with the condition failed** — an
  ACTIVE setupd on a provisioned boot is a fault (device discoverable + LED spinner
  when it shouldn't be) — while **btagent is ACTIVE regardless**.
  🔒 **This exact fault was REAL and is fixed in setupd r4 (v1.9.0) — a diag sweep
  found it, so keep checking it.** `nexusq-setup-needed` piped nmcli into grep and
  **discarded the exit code**, so a transient NetworkManager wobble read as "no wifi
  profile" → a **provisioned** device armed setup mode and went discoverable +
  pairable (the agent auto-accepts → a stranger gets a bond). It now **fails
  CLOSED**: only a *successful* nmcli listing no wifi profile counts as
  unprovisioned. Likewise **btagent's `setupd_active()` fails to FALSE** (claims the
  ring) when `systemctl is-active` cannot be consulted — it **has timed out live
  under load** — because assuming setupd owned the ring would SKIP the
  pairing-exposure indicator while the adapter is still pairable. **The ring going
  dark on a pairable adapter is the lie the ring exists to prevent.** Unprovisioned boot
  (or the force flag armed via the bridge's `startSetupMode`) → setupd active
  (`setup mode active: discoverable`), ring runs the `spin` animation (blue rotating
  dot), `bluetoothctl show` = Discoverable yes; it exits after `finishSetup` or 600 s
  idle. The psk must NEVER appear in its journal (a psk in a log line = a critical
  bug — expected: **0 PSK lines**).
  **Pairing health (root-caused 2026-07-15):** `nexusq-btagent` must be the
  **default agent**, `blueman-applet` must be **ABSENT** (its DisplayYesNo agent
  forces SSP → Numeric Comparison → an unanswerable HDMI dialog → every bond times out
  with mgmt `0x0e`; `RequestDefaultAgent` is last-writer-wins so it also steals the
  default agent), setupd registers **NO** agent, bonds come out **`Trusted`**, Class =
  **`0x006c0428`**, and **`Pairable == Discoverable`** (btagent's invariant —
  `Pairable`, NOT `Discoverable`, gates bonding; ring spinning blue ⇔ pairable).
  ⚠️ **"The BCM4330 can't complete SSP bonding" is RETRACTED** — never re-derive a
  hardware limit from a userspace symptom.
  ⚠️ **A dev image BAKES Petr's WiFi** → a fresh-flashed dev image self-provisions and
  **setup mode never arms**. That is EXPECTED, not a bug (`PUBLIC_RELEASE=1` doesn't
  bake it). See `companion/PROTOCOL.md` §8 +
  `docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`.
- **CPU 1.2 GHz** (OMAP4460 MPU): `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies`
  (expect `350000 700000 920000 1200000`), `scaling_governor` (expected:
  **`conservative`** since the 2026-07-13 v1.8.2 flash / kernel r43 —
  measurement-backed, see `docs/2026-07-13-idle-power-governor-and-pid1-churn.md`;
  was `ondemand` on v1.6.6–v1.8.1 images, `conservative` on v1.5.0–v1.6.5;
  `CPU_FREQ_STAT`/`time_in_state` present since 2026-07-03), `scaling_max_freq`.
  Put load on (**`timeout 12 yes >/dev/null &` — timeout each load process
  individually; `timeout N sh -c "yes & yes & wait"` ORPHANS the children when
  timeout kills the wrapper**), read `cpuinfo_cur_freq`/`scaling_cur_freq` →
  confirm it reaches 1200000. Thermal: `cat /sys/class/thermal/thermal_zone*/temp`.
  **Idle expectation changed with v1.8.2:** a healthy idle **settles at 350 MHz**
  (56.7 % residency measured 2026-07-13; **60.5 %** on the first clean 14 h
  hands-off MQTT-window measurement 2026-08-13, r70 — read residency from
  `opp_ms`/MQTT `opp*_pct`, NEVER healthd's `freq` spot sample; expect higher
  still on **r71 + nexusqd r13**, the 2026-08-13 idle diet: healthd 6.3 → 2.3 %
  of a core, **nexusqd 4.4 → 0.165 % and 22 → 2.9 wakeups/s**, idle fork rate
  14 → 2.6/s — ~12 pp of one core of constant background removed in one day;
  ~4.25 trans/s on `conservative`. **Post-diet attribution 2026-08-13** (240 s,
  ring blanked): total idle busy **8.73 %** of one core — **real ≈ 7.7 %**, an
  ssh poll loop inflated `sshd`/`init.scope` so those two are NOT trustworthy —
  forks **2.59/s**; **`nq-healthd` 2.43 % is the new #1**, nexusqd 0.14 %, and
  **`brcmf` WiFi kworker at ~34–40 wakeups/s dominates all other wakeup sources
  combined** — the healthd lead was closed 2026-08-20 by the **r77 C rewrite**
  (3.08 → 0.55 % of a core, system forks 2.45 → 0.75/s; `nexusq-mqtt` r4 also
  dropped its 30 s `pactl` poll), so on **r77+** expect healthd ≈0.55 % and
  `brcmf` as the remaining lead); a
  sustained ~920 MHz idle hover on a ≥v1.8.2 image is a **regression** (that
  was the ondemand microburst sawtooth + healthd's own systemctl churn, both
  fixed in v1.8.2; healthd's PAM churn re-fixed r68, fork churn fixed r71,
  nexusqd's 1.5 s `pactl` gate poll + 20 fps idle render fixed r13).
  ⚠️ **Idle temperature is observer-sensitive:** any live ssh/diag session heats
  the die to **74–79 °C within seconds** (cooling constant ~10 s); the true
  unobserved idle floor is **~65–66 °C** (C1-only MPUSS). Judge idle temp ONLY
  from an on-device self-logging capture with no session attached — never from an
  interactive read.
  2026-07-03 reference: 1200 MHz @ 1 380 000 µV load / 920 MHz @ 1 317 000 µV
  idle (exact OPP tracking); peak **91.8 °C** under dual-core
  load — only ~8 °C headroom to the 100 °C trip, so a sustained-load diag
  SHOULD report the peak temp (expected-hot, but watch it). **2026-07-06
  (v1.6.9/v1.6.10) the peak sits ~94–99 °C** under sustained dual-core load
  (97.2 °C on the 2026-07-13 v1.8.2 acceptance, bounded load) —
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
  **IDLE/clocked** at silence → **~7 % idle CPU**, top idle-heat source). nexusqd
  runs arecord **only while a real playback stream exists** (gate = sink-input
  **count, not level**). **Healthy idle tell:**
  no `arecord` process, the `tas5713` sink **SUSPENDED** (not IDLE) in
  `pactl list short sinks`, nexusqd **~0-1 % CPU** (was ~7 %). **During playback:**
  an `arecord` appears and the sink is **RUNNING**; **after** playback it re-gates off
  ~4 s later → SUSPENDED. Idle showing arecord running / sink IDLE / nexusqd ~7 % =
  the gate regressed. nexusqd depends on `pulseaudio-utils` (pactl).
  🆕 **The gate is EVENT-DRIVEN since nexusqd r13 (2026-08-13).** It used to poll
  `pactl list short sink-inputs` every `PA_POLL_S`=1.5 s while the tap was off —
  ~0.67 forks/s around the clock, and every one of those short-lived clients also
  woke every OTHER PA subscriber on the box (`nexusq-control`'s bridge) with
  client-connect events. Now **one persistent `pactl subscribe` child** feeds
  `'new'`/`'remove'` sink-input events into nexusqd's `poll()`; the timed re-count
  is only a safety net (30 s tapping / 60 s idle once the subscriber is *proven*
  ≥2 s alive; 1.5 s while it is down/unproven; respawn every 10 s). **Healthy
  tell:** exactly **one** long-lived `pactl subscribe` under `nexusqd.service`,
  and **no** recurring short-lived `pactl` from it — a stream of short `pactl`
  forks on r13+ means the subscriber keeps dying (check PulseAudio). Measured
  live: a *silent* sink-input (`paplay /dev/zero`) opens the tap in **~200 ms**.
  **Also r13: the render loop drops 20 fps → 1 Hz when idle** (40 bit-identical
  frames AND intent-idle: no overlay/fade/breathe/spin, screensaver locked or
  blanked; caps 0.25 s with the tap open, 0.5 s during the update blink) →
  nexusqd idle **0.165 % of a core, 2.9 wakeups/s** (was 4.4 % / 22). ⚠️ **Never
  A/B nexusqd CPU across screensaver states** — a fresh `systemctl restart
  nexusqd` restarts the screensaver, so the ring legitimately breathes at 20 fps
  and reads ~1.6 % / 54 wakeups per s; wait out `SS_LOCK_S`/`SS_BLANK_S` (~9 min)
  and confirm `led_sum` is static/0 first. See
  `docs/2026-07-08-audio-volume-scale-and-bootlog-cleanup.md` +
  `docs/2026-08-13-idle-opp-residency-measurement.md`.
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
  fires). Confirm with **led_frozen** + **nexusqd_no_progress**. *(Correction
  2026-08-13: the sd_notify watchdog is NOT a missing follow-up — it shipped in
  v1.6.x (`543b492`); `nexusqd.service` is `Type=notify` with `WatchdogSec=15s`
  and the daemon pings `WATCHDOG=1` once a second from the render loop, so
  systemd SIGABRTs + restarts a wedged daemon. These healthd signals still catch
  faults that leave the render loop, and the ping, alive.)*
  ✅ **`nq_progress` is a 60 s WINDOW since device r72 (2026-08-13) — FIXED.**
  *(Previously flagged here as an unverified risk. It was real: with `nexusqd`
  r13 + healthd ≤ r71 it fired **CRIT `led_frozen` on a healthy idle device
  twice** — `{"t_mono":214110,"sev":"crit","kind":"led_frozen","msg":"LED frame
  unchanged for 6 samples with distressed nexusqd (resp=1 progress=0) …"}`, and
  again at `t_mono` 214497.)* healthd used to compare `/proc/pid/stat` ticks
  across one 5 s sample; an idle r13 nexusqd accrues only **~0.8 USER_HZ ticks
  per sample**, so zero-delta samples became normal — and since `LED_STALL >= 6`
  is guaranteed on a locked/blanked ring, the CRIT co-signal
  (`nq_resp=0` **or** `nq_progress=0`) was satisfied by an efficient daemon.
  **r72:** `nq_progress` is 0 only when nexusqd's CPU time has not advanced for
  `PROGRESS_STALE_S` (env `NQ_PROGRESS_STALE_S`, **60 s** default ≈ 10× the ~6 s
  idle tick interval); the window resets while the unit is stopped. **On r72+,
  believe a `led_frozen` CRIT again.** Only on the narrow r13-with-healthd-≤r71
  combination should you downgrade it to info and judge by
  `nq_resp`/`nexusled status`. See
  `docs/2026-08-13-led-stall-verdict-and-progress-window.md`.
  ✅ **Healthy-idle tell (r72 + `nexusq-mqtt` r2):** a blanked ring shows a
  **large, growing `led_stall`** (hundreds–thousands) with **`led_stalled =
  false`** in the MQTT payload and `binary_sensor.nexus_q_led_ring = off` in HA.
  **That is HEALTHY — never report it.** `led_stall` is a diagnostic number;
  `led_stalled` (= `led_stall >= 6` AND nexusqd distressed) is the verdict.
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
  (0644) and nq-healthd r20 fingerprints it (md5 + byte sum; since r71,
  2026-08-13, a one-pass od|awk byte-sum + rolling hash — no md5, equality-only
  use, semantics unchanged) — the LED fingerprint is real. ✅ **Static-by-design guard LIVE since 2026-07-04**
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
  idle false CRIT.) *(2026-08-13: the `nq_progress` half of that co-signal broke
  and was fixed the same day — see the r13/r72 note above. On **r72+** the
  guard is sound again.)*
  ⚠️ **OTA LED states are NOT faults (nexusqd r11 / control r20, device OTA — PROTOCOL
  §12).** The bridge drives two states a sweep must not mis-read: the **mute LED blinks
  amber** (`mblink 255 140 0`) = a daemon OTA is available — a *persistent* indicator,
  not a stuck/frozen frame; and the **ring shows a determinate `progress` bar** then a
  brief green `set 0 255 0` **while installing** — transient + expected. The install
  restarts the daemons (incl. `nexusq-control` and possibly `nexusqd`), so a **brief
  nexusqd/bridge restart right after an OTA is expected**, not `nexusqd_restart`. A
  **full-system OTA** (`installSystemUpdate`, PROTOCOL §12b, control r21+) narrates with
  the **indeterminate `spin` spinner** (not the bar) and may **reboot the device** when
  base libc/init churns (musl/systemd/…) — a reboot / fresh uptime right after a System
  update is **expected**, not a hang/crash. See
  `docs/2026-08-02-device-ota-and-wifi-nogw-heal.md` +
  `docs/2026-08-02-full-system-ota-and-glibc-rt-split.md`.
  ⚠️ **KNOWN OPEN (2026-08-08): a System OTA reports "system update failed" but the
  packages actually installed.** `apk fix -s` shows `(1/1) Reinstalling
  postmarketos-mkinitfs … 1 error` — a **persistent pending trigger** (re-fails every
  apk run). Cause: `boot-deploy` errors `No kernel found in /boot` because `/boot` is an
  **empty plain dir** on this ramdisk-less device (kernel is in the flashed boot
  partition). **Do NOT read this as a broken update or a failed unit** — verify with
  `apk info` (the packages committed) and note the pending trigger. NOT fixed; Phase-2
  territory. See `docs/2026-08-08-system-ota-mkinitfs-trigger-failure.md`.
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
- **librespot fields (`ls_active`/`ls_restarts`) are UNTRUSTWORTHY in any capture
  from a device r31–r39 image** — healthd queried the SYSTEM manager after
  librespot became a uid-10000 USER unit (r31), so they read `unknown`/`0`
  forever and `librespot_restart` could never fire. **Fixed in r40** (flashed
  2026-07-13, v1.8.2): process-first liveness + `systemctl -M user@ --user`
  (root cannot borrow the user's `XDG_RUNTIME_DIR` — systemd 261 refuses
  cross-user private-socket connections; r39 shipped that broken form).
- **kernel_errors** — new oops/WARN/i2c-timeout/voltage lines; read `KERNEL_LOG_FULL`.
  ℹ️ healthd's `dmesg_err` matcher also counts info-level brcmfmac `clm_blob`
  lines (too-broad matcher, noted 2026-07-13) — cosmetic false positives, not a
  device fault.
- **pstore** (crit) — a previous boot panicked (only survives a *warm* reboot).

Every boot/dmesg error is ours to fix — never dismiss one as benign/expected.
As of **v1.6.10** the boot log is **GENUINELY CLEAN**: on a clean-flash boot of
`#36` / device r28, **`dmesg -l err,warn` is EMPTY** and `journalctl -b -p
warning` contains **ONLY these 4 genuinely-external residuals** (3 through
v1.8.1; the 4th dispositioned 2026-07-13) — anything else is a **REGRESSION**,
report it:
  1. **eth-lan DHCP fail** on a DHCP-less direct PC cable (environmental —
     `autoconnect=false` would break real-LAN plug-and-play);
  2. **kscreen `.service` D-Bus naming** (upstream libkscreen packaging lint, hard
     dep via lxqt-config);
  3. **avahi `No NSS support for mDNS`** (`nss-mdns` unpackaged in pmOS/Alpine;
     avahi's publish path for librespot Spotify-Connect zeroconf works fine);
  4. **NM `sd-event.c:4488 assertion failed`** — a ONE-SHOT assert from
     NetworkManager's **vendored libsystemd**, fired exactly at the RTC→NTP
     clock step (no RTC battery → CLOCK_REALTIME jumps years); NM continues
     fine, WiFi associates the same second. External/upstream (added
     2026-07-13, v1.8.2 acceptance). More than one occurrence per boot, or any
     NM malfunction around it, IS a finding.
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
