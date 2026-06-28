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

- SSH as **`user` / `147147`** (NOT root — `root@` ssh is denied on this image;
  escalate with `echo 147147 | sudo -S <cmd>`):
  `sshpass -p 147147 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null user@172.16.42.1`
- Host-side sudo on THIS PC: try plain `sudo`; if it prompts,
  `op-cache "sudo petronijus-PC" password`.
- Prefer the repo's own `scripts/diag/nqctl` if it already knows the link
  (`nqctl status`, `nqctl run '<cmd>'`).
- Fallbacks: **serial** `/dev/ttyACM0` @115200 (`steelhead login:`, user/147147) —
  works even with no net; **WiFi** vlan20 DHCP — find the lease in OPNsense Kea
  (`opnsense-api GET /api/kea/leases4/search`, device MAC `f8:8f:ca:20:48:e1`); this
  host may not route into vlan20.
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

- **Bluetooth** (BCM4330B1, UART/`hci_uart_bcm`): `dmesg | grep -i bluetooth` — did
  the patchram load (finds `brcm/BCM4330B1.hcd`) or "Patch file not found, tried:"?
  `hciconfig -a` / `bluetoothctl show` → is `hci0` UP? Missing `.hcd` →
  `/lib/firmware/brcm/BCM4330B1.hcd` absent.
- **WiFi** (BCM4330, `brcmfmac`): `dmesg | grep -i brcmfmac` — did
  `brcm/brcmfmac4330-sdio.bin` load or fail "-2"? `iw dev` → does `wlan0` exist?
  `sudo iw dev wlan0 scan | grep -iE 'SSID|freq'` → does it SEE 5 GHz APs (freq
  >5000)? `iw dev wlan0 link` / `nmcli dev status` → connected? band + signal?
  (A fresh flash has no saved creds, so "not connected" ≠ "broken" — distinguish
  radio/firmware working from network not configured.) brcmfmac wants
  `brcm/brcmfmac4330-sdio.bin` + nvram `brcm/brcmfmac4330-sdio.txt` (NOT the bcmdhd
  `fw_bcm4330*.bin` from firmware-aosp-broadcom-wlan — different driver).
- **Ethernet** (SMSC LAN9500A over USB EHCI): `ip -br link`, `ethtool eth0`. Known
  regression: on-board eth went down (carrier=0) in the cpufreq patch series.
- **CPU 1.2 GHz** (OMAP4460 MPU): `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies`
  (expect `350000 700000 920000 1200000`), `scaling_governor`, `scaling_max_freq`.
  Put load on (`yes >/dev/null &`), read `cpuinfo_cur_freq`/`scaling_cur_freq`, kill
  it → confirm it reaches 1200000. Thermal: `cat /sys/class/thermal/thermal_zone*/temp`.
  (Idle is NOT 350 MHz — it hovers ~920 MHz, nexusqd LED polling keeps it up.)
- **SMP** (`nproc` should be **2**, `cat /sys/devices/system/cpu/online` = `0-1`) —
  dual-core works since v1.2.0; flag any single-core boot as a regression.
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
  `nexusled status` returns) — that is **idle-off** (the ring blanks on the idle
  timeout). Don't report a dark-but-responsive ring as a hang (it tripped a false
  CRIT on 2026-06-28).
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
- **thermal_throttle / thermal_crit** — at/over 100 °C passive / 125 °C critical.
- **governor_not_scaling** — load was high but freq stuck at 350 MHz (cpufreq stall);
  see `CPU` + `CLOCKS` (`dpll_mpu`).
- **kernel_errors** — new oops/WARN/i2c-timeout/voltage lines; read `KERNEL_LOG_FULL`.
- **pstore** (crit) — a previous boot panicked (only survives a *warm* reboot).

Every boot/dmesg error is ours to fix — never dismiss one as benign/expected.

## 5. Report back

Return:
1. A **yes/no hardware table**: BT | WiFi (firmware OK? sees 5 GHz? connected?) |
   eth (carrier) | CPU reaches 1.2 GHz — one evidence line each.
2. The **runtime verdict** (`worst_severity`) + each finding with its evidence
   (quote the timeline/snapshot section), and—if a finding implies a code fix—name
   the file to change (e.g. `pmos/nexusqd/`), not a workaround.
3. Where the capture was saved (`nq-captures/<ts>/`) for later good-vs-bad diffs.

Keep it tight — the verdict and evidence, not the capture scroll.
