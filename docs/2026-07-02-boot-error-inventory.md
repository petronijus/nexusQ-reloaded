# Last-Boot Error Inventory — kernel `6.12.12 #26` (v1.6.5 era)

**Captured:** 2026-07-02, full `dmesg` + `journalctl -b -p err` of the last boot of
`Linux version 6.12.12 … #26-postmarketOS SMP Mon Jun 29 22:43:29 UTC 2026`
(GCC Alpine 15.2.0, the v1.6.5-era boot.img), uptime ~23 h at capture,
**ZERO failed systemd units**. This is the periodic re-sweep of the boot-error
B-inventory started in `docs/2026-06-19-boot-warnings-followup.md`
(IDs **B1–B11**, userspace **U1–U3** defined there). Policy unchanged: **every
boot error is ours to fix** — nothing is "benign/environmental/expected".

The investigation **completed later the same day**: see **"CORRECTIONS"** and
**"Fixes implemented 2026-07-02"** at the bottom. The per-item tables
below are kept as originally written (the morning inventory record); where a
morning claim was later disproven (the "WiFi dead" finding, B8's `sgdisk -e`)
the corrections section is authoritative.

**UPDATE 2026-07-03: the batch was FLASHED and the acceptance run PASSED** —
kernel `6.12.12 #27-postmarketOS` (pkgrel 26) + `device-google-steelhead` r19.
**9/10 targeted error classes are GONE on the device**; per-item verification,
two NEW twl findings (B22/B23) and two nq-healthd tooling bugs are in the
**"FLASH-VERIFIED 2026-07-03"** section at the bottom.

**UPDATE 2026-07-03 (later): BATCH 2 is BUILT — kernel pkgrel 27 (uname `#28`)
+ device r20 — but NOT YET FLASHED**; it fixes B22/B23 + both healthd bugs +
the WiFi factory-MAC, and carries two MAJOR CORRECTIONS (TWL6040 was never a
dead codec; the NFC "dead hardware" verdict is RETRACTED). See the **"BATCH 2"**
section at the very bottom, which is now the authoritative status.

---

## RESOLVED since the 2026-06-20 inventory — no longer present in this boot

| ID | Old symptom | Evidence this boot | Fixed by |
|----|-------------|--------------------|----------|
| **B1** | `ti-sysc 4a318000.target-module: probe … -16` (GPTIMER1 `-EBUSY`) | absent; `TI gptimer clockevent: always-on 32768 Hz` probes clean | ti-sysc active-timer silencing (v1.5.0 CHANGELOG "boot: silenced the benign ti-sysc active-timer -EBUSY") |
| **B2** | `WARNING … arm_dt_init_cpu_maps` (2 DT CPUs, SMP=n) | absent; `smp: Brought up 1 node, 2 CPUs`, `cpu@1` restored | SMP bring-up (v1.2.0, patch 0009) |
| **B3** | `omap4_sram_init: Unable to get sram pool … errata I688` | absent; `[0.000000] OMAP4: Map 0xafe00000 to (ptrval) for dram barrier` — the I688 barrier now allocates | not individually flash-verified before; confirmed gone on #26 |
| **B6** | `HDMICORE: timeout reading edid` every ~6 s | absent this boot | DDC pads `PIN_INPUT` + hdmi4 `.mode_valid` (v1.2.0, patch 0010); an EDID-providing sink is attached |
| **B7** | `clk: couldn't set dpll_per_m3x2_ck … 61440000 (-22)` (TAS5713 MCLK) | absent; audio plays at 1.000× since v1.6.1 | patch 0007 (composite clk `round_rate`/`set_rate`) + patch 0022 (McBSP2 CLKGDV → FSYNC 48 kHz) |
| **B9** | `systemd-vconsole-setup.service` failed (`KD_FONT_OP_GET` I/O error) | absent; 0 failed units (`Starting Virtual Console Setup...` completes) | (unit no longer fails on this image; exact fixing change not isolated) |
| **B11** | snd-aloop missing (`hw:Loopback` absent, nexusqd tap dead) | absent; loopback tee drives the visualizer | `CONFIG_SND_ALOOP=m` + `modules-load.d/snd-aloop.conf` (v1.6.2) |

---

## STILL OPEN from the old inventory

| ID | Log line (verbatim, this boot) | Status 2026-07-02 |
|----|-------------------------------|--------------------|
| **B4** | `brcmfmac mmc4:0001:1: Direct firmware load for brcm/brcmfmac4330-sdio.clm_blob failed with error -2` · `brcmf_c_process_clm_blob: no clm_blob available (err=-2), device may have limited channels available` · `brcmf_c_process_txcap_blob: no txcap_blob available (err=-2)` | OPEN. **NEW sub-finding:** the driver also probes a device-specific firmware first and misses it: `Direct firmware load for brcm/brcmfmac4330-sdio.google,steelhead.bin failed with error -2` (then falls back to the generic `brcmfmac4330-sdio.bin`, which loads: FWID `01-cafa6b3e` ver 5.90.195.114). A symlink/copy under the board-specific name would silence the probe miss. |
| **B8** | `Alternate GPT is invalid, using primary GPT.` | **FIXED on-device 2026-07-03 (Petr-approved):** userdata `p13` ended at the literal last sector (**30777343**) so the 33-sector backup GPT could not fit. With the ext4 fs measured at 2.09 GiB (~11 GiB slack — the ramdisk-less image never grows the fs), p13 was atomically recreated with end **30777310** (same start/name/GUIDs) + backup structures relocated, in ONE `sgdisk -d 13 -n ... -e` invocation (the two-step variant self-deadlocks). `sgdisk -v`: **No problems found.** Original GPT backed up to `nq-captures/gpt-backup-2026-07-03.bin`. Takes effect at next reboot; the running kernel keeps its in-memory table. Reflash-safe: fastboot writes partition *content*, not the GPT — only a factory-image restore would reintroduce this. |
| **B10** | `hw-breakpoint: Failed to enable monitor mode on CPU 0.` | OPEN (investigate; suspected secure-side gating on the GP/HS OMAP4460). |

---

## NEW kernel ERRORS — B12+ (investigation in progress 2026-07-02)

| ID | dmesg (verbatim) | Analysis | Where |
|----|------------------|----------|-------|
| **B12** | `twl6030_uv_to_vsel:OUT OF RANGE! non mapped vsel for 1375000 Vs max 1316660` ×4 (all at 0.767 s) + `twl: not initialized` ×4 (at 0.767 / 2.784 / 3.294 / 3.839 s) | Fires immediately after `steelhead: vdd_mpu PMIC=TPS62361 i2c=0x60 volt_reg=0x01`. Correlates with **abb_mpu = 1 375 000 µV** (the FBB/Nitro ABB rail: `abb_mpu: Setting 1025000-1389000uV`): something pushes the ABB voltage through the **twl6030** vsel mapping, whose table tops out at 1 316 660 µV — but VDD_MPU is owned by the **TPS62361** (patches 0013–0018), not the twl6030. Runtime VDD_MPU itself is **correct** (1380 mV @ 1200 MHz, verified in the 2026-06-28 power diag). Likely a leftover twl6030 regulator consumer in the cpufreq/ABB path being asked for the FBB voltage before/instead of the TPS bridge; also note the `twl: not initialized` calls happen **before** the twl driver probes (twl PIH registers at 3.97 s). | kernel/DTS (cpufreq-ABB path) |
| **B13** | `failed to register cpuidle driver` | No CPU idle states at all (cmdline ships `cpuidle.off=1` since the SMP CPU1 cpuidle panic, v1.2.0 — this error is the registration refusing under that flag). Contributes to the warm 69.8 °C idle. Proper fix = the "cpuidle proper" open item from `docs/2026-06-22-smp-session-findings.md` (stock uses `cpuidle44xx.disallow_smp_idle`, keeping C-states on CPU0). | kernel |
| **B14** | `ocp:target-module@48210000:mpu:fck: device ID is greater than 24` · `ocp:target-module@54000000:pmu:fck: device ID is greater than 24` · `5a05a400.target-module:iva:fck: device ID is greater than 24` | TI **clkctrl** indexing: the MPU / PMU / IVA target-module `fck` lookups compute a clkctrl device ID > 24 (the omap4 clkctrl provider's limit), so those fck's don't resolve. PMU still probes (`armv7_cortex_a9 PMU driver, 7 counters`); check whether MPU/IVA target-modules lose runtime PM. Suspect the DTS clkctrl `<&…_clkctrl OFFSET BIT>` cells vs the provider's expected offset encoding. | DTS/kernel |
| **B15** | `pn544_hci_i2c 2-0028: NFC: Could not detect nfc_en polarity, fallback to active high` (after `NFC: Detecting nfc_en polarity` at 3.06 s) | The NFC enable-GPIO polarity is not described in the DTS, so the driver's runtime detection fails and it guesses. NFC is untested hardware (README status 🟠); fix = describe `enable-gpios` polarity per the board schematic / stock init. | DTS |
| **B16** | `ramoops: found existing invalid buffer, size 1090782208, start 65604` | Consistent with the known finding that the ramoops region at `0xbf000000` does **not** survive reboot (DRAM re-init scrubs it — see the pstore memory note): the kernel finds garbage where a previous-boot buffer would be, and logs it at error level. Not new data loss — but it is logged as an error every boot; decide whether to zero the region early or accept + document. | kernel/cmdline |

---

## NEW kernel WARNINGS — B17+ (investigation in progress 2026-07-02)

| ID | dmesg (verbatim) | Analysis | Where |
|----|------------------|----------|-------|
| **B17** | `platform bcm4330-pwrseq: deferred probe pending: pwrseq_simple: external clock not ready` (deferred-probe dump at 22.3 s) | The WiFi power-sequence's external clock (`clocks = <&twl 1>`, clk32kaudio) is not ready at that point. In this boot the pwrseq eventually attached (`omap_hsmmc 480d5000.mmc: allocated mmc-pwrseq` at 28.0 s, SDIO card + brcmfmac firmware load OK), ~~but WiFi is currently DEAD on the live unit~~ **CORRECTED later 2026-07-02: WiFi was NEVER dead — the IP had moved** (see CORRECTIONS below; device was at `192.168.20.142` the whole time). The ~25 s defer itself is real (the `CONFIG_CLK_TWL=m` module delayed the 32k clock provider) and the clock was additionally the **wrong TWL pin** (CLK32KAUDIO instead of CLK32KG) — both fixed, see "Fixes implemented" below. | DTS/kernel |
| **B18** | `platform 40132000.target-module: deferred probe pending: (reason unknown)` | `0x40132000` is in the **ABE** L3 region (McASP/AESS neighborhood). Permanently deferred with no stated reason — identify the node and either satisfy its dependency or disable it. | DTS |
| **B19** | `tas571x 3-001b: supply PVDD_A not found, using dummy regulator` (+ `PVDD_B` / `PVDD_C` / `PVDD_D`) | The amp's four PVDD power-stage rails are not described in the DTS (only AVDD/DVDD were mapped in the v1.5.0 regulator pass). Map them to the real board rail to retire the dummies. | DTS |
| **B20** | `usb_phy_generic hsusb1-phy: dummy supplies not allowed for exclusive requests (id=vbus)` | The hsusb1 PHY (ethernet's USB3320) requests `vbus` exclusively but the DTS provides none → the regulator core refuses to substitute a dummy for an exclusive request. Describe the vbus supply (or drop the exclusive request). Worth checking against the ethernet regression (B-eth / task #17) while in that code. | DTS |
| **B21** (minor batch) | `L2C: platform modifies aux control register: 0x0e070000 -> 0x3e470000` + `L2C: DT/platform modifies aux control register…` · `gpmc_mem_init: disabling cs 0 mapped at 0x0-0x1000000` · `armv7-pmu … hw perfevents: no interrupt-affinity property, guessing.` · `systemd-journald.service: unit configures an IP firewall, but the local system does not support BPF/cgroup firewalling.` · `systemd-journald[131]: Failed to set ACL on /var/log/journal/…/user-10000.journal, ignoring: Not supported` | Low-priority polish: L2C aux-ctrl double-modification (DT vs platform both patch it), GPMC chip-select 0 mapped over SDRAM and disabled, missing PMU `interrupt-affinity` DT property, journald wants cgroup-BPF (kernel lacks `CONFIG_BPF_LSM`/cgroup-bpf bits) and POSIX ACLs on the journal fs. Each is a one-line DTS/defconfig decision; batch them with the next kernel/DTS round. | DTS/defconfig |

---

## NEW userspace ERRORS — U4+ (`journalctl -b -p err`; investigation in progress 2026-07-02)

| ID | journal (verbatim) | Analysis |
|----|--------------------|----------|
| **U4** | `systemd[484]: pipewire-pulse.socket: Socket service pipewire-pulse.service not loaded, refusing.` + `Failed to listen on PipeWire PulseAudio.` · `pulseaudio[912]: [pulseaudio] module-alsa-card.c: Failed to find a working profile.` · `pulseaudio[912]: [pulseaudio] module.c: Failed to load module "module-alsa-card" (argument: "device_id="1" name="platform-omap-hdmi-audio.1.auto" …"): initialization failed.` · `pulseaudio[1307]: [pulseaudio] pid.c: Daemon already running.` ×2 | **PulseAudio vs PipeWire conflict** in the user session: a `pipewire-pulse.socket` exists without its service, PulseAudio itself runs but can't profile the HDMI-audio ALSA card (no audio-capable EDID sink — README status 🟠), and a second PA spawn races the first. Decide ONE sound server for the image (the working audio path — librespot→ALSA softvol→tee — bypasses both) and remove/disable the loser. |
| **U5** | `bluetoothd[365]: Failed to set default system config for hci0` | bluetoothd can't push its default controller config to the BCM4330. BT is functionally up (hci0 patched to `BCM4330B1 (002.001.003) build 0482`); find which config item is rejected. |
| **U6** | `sshd-session.pam[…]: gkr-pam: unable to locate daemon control file` (every ssh session, ×12+ over the boot) · `gkr-pam: couldn't unlock the login keyring.` · `login[…]: gkr-pam: error looking up user information` | **gnome-keyring PAM** is wired into the ssh/login PAM stack but no keyring daemon exists for these sessions (headless root/user logins). Pure noise on every session — drop `pam_gnome_keyring` from the relevant PAM services in the image. |
| **U7** | `systemd-nsresourced[224]: bpf-lsm not supported, can't lock down user namespace.` | Kernel lacks BPF-LSM (`CONFIG_BPF_LSM`); nsresourced degrades. Decide: enable BPF-LSM in the defconfig (size/perf cost on armv7) or accept + document as a known image limitation. Related to the journald BPF warning in B21. |

Also captured in the -p err stream (self-inflicted, documented not fixed):
`sshd-session.pam[12718]: error: PAM: Authentication failure for root from 172.16.42.2` ×3 +
`error: maximum authentication attempts exceeded for root from 172.16.42.2 port 55526 ssh2 [preauth]`
— see the root-ssh access regression below.

---

## DEVICE-STATE observations 2026-07-02 (not boot errors)

- **cpufreq governor is `conservative` — this MATCHES the build**, it is the shipped
  default (`kernel/configs/steelhead_defconfig`:
  `CONFIG_CPU_FREQ_DEFAULT_GOV_CONSERVATIVE=y`, switched from `ondemand` in v1.5.0 —
  CHANGELOG "Default cpufreq governor → conservative"). The "expected `ondemand`"
  framing was v1.4.0-era and is stale; nothing on the device overrides the governor.
  **Resolved, not a fault** — a deliberate v1.5.0 defconfig change whose rationale
  was disproven 2026-06-28. Now flipped back: the defconfig carries
  `CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y` + `CONFIG_CPU_FREQ_STAT=y` (closing the
  `time_in_state` diagnostic gap from 2026-06-28) — in tree, build in progress
  2026-07-02, not yet flashed.
- **eth carrier=0** — the KNOWN v1.4.0 cpufreq boot-timing regression (task #17),
  unchanged; see `docs/ethernet-bringup-procedure.md`.
- **root ssh authorized_key is MISSING from this image** — `ssh root@172.16.42.1`
  fails PAM auth (journal evidence above); the device is only reachable as
  **`user@172.16.42.1`** over the USB gadget (~~and WiFi is dead, see B17~~ —
  corrected below: WiFi was up at `192.168.20.142`).
  This is an **access-config regression**: per the bake-successes-into-build rule,
  the authorized key / root access path must be baked into the image (via the
  private overlay for anything secret), not restored by hand after each flash.
  **Fix implemented same day** (access baking, see below).
- ~~**WiFi DEAD on the live unit** (see B17) — `192.168.20.179` unreachable~~ —
  **DISPROVEN same day, see CORRECTIONS below** (the IP moved; WiFi was up).
- **CPU + power HEALTHY** (the always-run CPU/power diag): reaches **1200 MHz**,
  `vdd_mpu` **1380 mV** tracks the OPP exactly, FBB engaged (abb_mpu 1375 mV),
  **69.8 °C idle-warm** (consistent with 2026-06-28; cpuidle absent, B13).
- RTC/journal timestamps: the journal shows `Jan 10 11:55` lines mid-boot — the
  known wrong-RTC artifact (`twl_rtc … setting system clock to 2000-01-10T11:55:04`,
  systemd advances to its built-in epoch `2026-06-29 14:23:57` first); later entries
  are NTP-corrected real dates (Jul 01/02).

---

## CORRECTIONS (later 2026-07-02 — the investigation completed)

- **WiFi was NEVER dead.** The device was on WiFi the whole time, at
  **`192.168.20.142`** — the IP had **moved**, not the link died:
  NetworkManager was using a **randomized locally-administered MAC**
  (`8a:d8:d9:ac:c6:e5` vs the hardware `f8:8f:ca:20:48:e1`), so every boot pulled
  a **fresh DHCP lease** and the documented `192.168.20.179` went stale. The
  morning "WiFi DEAD" verdict (B17 / device-state above) is **withdrawn**.
  Fix baked (`device-google-steelhead` pkgrel 18): `wifi-stable-mac.conf`
  (`cloned-mac-address=permanent` + scan MAC randomization off). **Until the new
  image is flashed the IP keeps wandering** — find the current one in the
  OPNsense DHCP leases by hostname `steelhead` (matching on the hw MAC won't work).
- **The `conservative` governor** was traced to the defconfig — a deliberate
  v1.5.0 change whose rationale was disproven 2026-06-28; flipped back to
  `ondemand` + `CONFIG_CPU_FREQ_STAT=y` (in tree, see below).
- **B8 `sgdisk -e` did NOT apply on 2026-07-02** — it refused to write; fixed 2026-07-03 with the atomic resize+relocate (see the corrected B8
  row above): p13 ends at the literal last eMMC sector 30777343, the 33-sector
  backup GPT cannot fit. Blocked on a p13 shrink (needs explicit approval).

---

## Fixes implemented 2026-07-02 — flashed + verified 2026-07-03 (see the section below)

Everything below is in the working tree; written 2026-07-02 while the build was
still running (then "nothing is flash-verified yet" — **superseded: flashed and
acceptance-verified 2026-07-03**, see "FLASH-VERIFIED" below). Kernel: `linux-google-steelhead`
pkgrel 25→**26** (patches **0023–0028** added to `source=` + sha512sums; next
boot will be uname `#27`). DTS: patch 0003 regenerated (866 lines; DTB compiled
and decompile-verified). Device pkg: `device-google-steelhead` pkgrel 17→**18**
(bumped again to **19** before the flash — r19 is what shipped 2026-07-03).
Stock-parity evidence for the voltage/WiFi-clock/cpuidle/NFC items:
`docs/2026-07-02-stock-parity-voltage-wifi-idle.md`.

| Item | Fix |
|------|-----|
| **B12** twl6030 `OUT OF RANGE! … 1375000` ×4 + `twl: not initialized` ×4 | Root cause was **not** the ABB path guessed above — it was the **IVA + CORE VC channels** ×(on, onlp): mainline programs a blanket 1 375 000 µV ON/ONLP into all three VC channels, through a twl6030 vsel map stuck on the ES1.0 scale because a failed early SMPS_OFFSET efuse read was **latched as valid**. **Patch 0023**: don't latch on fail + steelhead seed `0x7f` (efuse read live over i2c 2026-07-02: `SMPS_OFFSET=0x7f`, `SMPS_MULT=0x52`). **Patch 0027**: stock-parity per-domain VC ON/ONLP voltages — MPU 1 375 000 / IVA 1 188 000 / CORE 1 200 000 µV — plus the 4460 core VC channel retargeted VCORE3→**VCORE1** (volt/cmd `0x55`/`0x56`; stock explicitly unmaps VCORE3). |
| **B13** `failed to register cpuidle driver` | **Patch 0024**: register a **C1-only (WFI)** cpuidle driver on steelhead, replacing `cpuidle.off=1` (dropped from `CONFIG_CMDLINE`). Stock has C1–C4, but C2+ traps into the HS secure dispatcher (services `0x1c`/`0x1d`/`0x21`) — deep idle is a future project. |
| **B14** clkctrl `device ID is greater than 24` ×3 (mpu/pmu/iva fck) | **Patch 0025**: ti-sysc registers child named clocks via `clkdev_add()` (no `MAX_DEV_ID` 24-char limit), same approach the file already uses elsewhere. |
| **B15** pn544 `nfc_en` polarity fallback | **The NFC chip is electrically DEAD** — live probe 2026-07-02: no i2c ACK at 0x28 (or anywhere on i2c-2) with VEN high, low, or in fw-download mode (FW=1+VEN=1); the driver's exact 6-byte core-reset frame NAKed. Pins/polarity/timing were **stock-verified MATCH first** (`nfc_gpios`: en=163 active-high, fw=162, irq=164 pull-up; 20/60 ms VEN timing). Same dead-hardware category as the TWL6040. DTS node `status = "disabled"`. **_(Verdict RETRACTED 2026-07-03 — status "under investigation", see BATCH 2 below; the TWL6040 comparison also collapsed — it was never a dead chip.)_** |
| **B17** bcm4330-pwrseq deferred ~25 s | Two independent fixes: defconfig `CONFIG_CLK_TWL=m`→**`y`** (the module made the pwrseq defer ~25 s for its 32k clock provider — WiFi only came up at ~31 s), and the **CLK32KG stock-parity fix** in the DTS: WiFi pwrseq + BT clocks `<&twl 1>`→**`<&twl 0>`**. Stock enables the TWL6030 **CLK32KG** output (0x8C); its consumer string "clk32kaudio" is a **naming trap** (wired to the CLK32KG regulator in the board data), so our old CLK32KAUDIO value gated the **wrong pin** and the BCM4330 LPO never ran. Plus `clk-settle-delay-ms = <300>` (**patch 0028**, new pwrseq-simple property) matching stock's clk → 300 ms → WLAN_EN → 200 ms. NB: 5 GHz WiFi already works well — this is **parity correctness**, no promises on bulk-throughput improvement. |
| **B18** `40132000.target-module` deferred | `omap4-mcpdm.dtsi` include **dropped** from the DTS: McPDM's pdmclk provider is the dead TWL6040, so the module deferred forever; without the codec McPDM is unusable anyway. |
| **B19** tas571x PVDD_A–D dummy regulators ×4 | New `amp_pvdd` fixed regulator wired to `PVDD_A..D-supply` — deliberately **no voltage properties** (rail unmeasured; TAS5713 spec allows 8–26 V; the driver only `enable()`s its supplies). |
| **B20** hsusb1-phy exclusive-vbus refusal | **Patch 0026**: `usb_phy_generic` gets its optional vbus supply with `devm_regulator_get_optional()` (silent `-ENODEV` for an absent supply). |
| **U4** PulseAudio vs PipeWire | **Config-topology fix, not a mask**: PulseAudio is the pmOS audio backend; the pipewire package is present only as a **library dependency**, but its XDG autostart double-started a second sound server every session, and `pipewire-pulse.socket` had **no service package behind it** at all. Fix (pkgrel 18): `Hidden=true` override .desktops in `/etc/xdg/nexusq/autostart/` (activated by an `XDG_CONFIG_DIRS` prepend in `nexusq-wayland.sh`) + `/etc/systemd/user/pipewire-pulse.socket` masked to `/dev/null`. (The PA "Failed to find a working profile" HDMI-audio line is separate — UCM profile, still open.) |
| **Access regression** (root ssh) | `docker-build.sh` Phase 6 stages `private/access/authorized_keys` → `/root/.ssh/authorized_keys` + `/etc/skel/.ssh/authorized_keys` (0600) and `private/access/wifi.nmconnection` → `/etc/NetworkManager/system-connections/` (0600); empty staged files are skipped (`[ -s ]` guards), so a public clone still builds. `authorized_keys` (petronijus-PC ed25519) **exists**; the WiFi profile is generated per machine by the NEW `scripts/gen-wifi-profile.sh` (PSK pulled from 1Password at run time; the output is **gitignored even in the private repo**) — **not yet generated**, so this build bakes ssh keys but **no WiFi profile**. |
| **Wandering WiFi IP** | `wifi-stable-mac.conf` (pkgrel 18): `cloned-mac-address=permanent` + scan MAC randomization off — see CORRECTIONS above. |
| **Governor** | defconfig back to `CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y` + `CONFIG_CPU_FREQ_STAT=y`. |
| (tooling) | `i2c-tools` + `gptfdisk` added to the device package depends — both were needed live today (the NFC/efuse i2c probes, the B8 GPT work). |

### Still open after this batch

- **U5** bluetoothd `MGMT_OP_SET_DEF_SYSTEM_CONFIG` failure (the one journal line).
- **U4-adjacent**: PulseAudio **HDMI-audio UCM profile** ("Failed to find a working profile").
- **U6** gkr-pam noise — attribute which PAM stack drags `pam_gnome_keyring` in.
- **Deep cpuidle C2+** — the HS secure dispatcher project (services 0x1c/0x1d/0x21).
- **B4** clm_blob / txcap / `google,steelhead.bin` probe miss; **B10** hw-breakpoint.
- ~~B8~~ — DONE 2026-07-03: p13 shrunk by 33 sectors + backup GPT written and verified (see the B8 row above).
- **B16** ramoops invalid-buffer error, **B21** minor L2C/gpmc/pmu/journald batch,
  **U7** nsresourced bpf-lsm — untouched this round.

## Raw captures

Full logs captured off-device 2026-07-02 (`lastboot-dmesg.txt`, 700 lines;
`lastboot-journal-err.txt`, 45 lines); all lines above are verbatim quotes from
them. Boot: `6.12.12 #26-postmarketOS SMP Mon Jun 29 22:43:29 UTC 2026`.

---

## FLASH-VERIFIED 2026-07-03 — acceptance run of the v1.6.6-candidate image

The full batch was flashed 2026-07-03 (`fastboot flash boot` + `fastboot -S 100M
flash userdata` of the all-RAW sparse — ~3 min, 23 chunks, all OKAY) and the
acceptance diagnostic **PASSED**. Boot under test:
`Linux version 6.12.12 … #27-postmarketOS SMP Thu Jul  2 22:16:43 UTC 2026`
(kernel pkgrel 26 + `device-google-steelhead` r19). Baseline: `nproc=2`,
**zero failed systemd units**, `python3 -S -c ''` rc 0 (all-RAW flash), LXQt
session up. Diag capture: `nq-captures/20260703-005812/`.

### Per-item verification — 9/10 targeted error classes GONE

| ID | 2026-07-02 symptom | Verified on `#27` (2026-07-03) |
|----|--------------------|--------------------------------|
| **B12** | twl6030 `OUT OF RANGE! … 1375000` ×4 | ✅ GONE (no OUT-OF-RANGE line in the whole boot). ⚠️ but the companion `twl: not initialized` **grew** — new item **B22** below |
| **B13** | `failed to register cpuidle driver` | ✅ GONE — C1-only driver registered: `cpuidle/state0` = `C1 - CPUx ON, MPUSS ON`, `cpuidle: using governor menu` @0.306 s |
| **B14** | clkctrl `device ID is greater than 24` ×3 | ✅ GONE |
| **B15** | pn544 `nfc_en` polarity fallback | ✅ GONE (node disabled — _"dead HW" retracted 2026-07-03, now "under investigation"; see BATCH 2_) |
| **B17** | bcm4330-pwrseq deferred ~25 s | ✅ GONE — pwrseq probes @**4.31 s**, `omap_hsmmc … allocated mmc-pwrseq` @**6.10 s** (was ~27–28 s) |
| **B18** | `40132000.target-module` deferred (McPDM) | ✅ GONE |
| **B19** | tas571x `PVDD_A..D` dummy regulator ×4 | ✅ GONE |
| **B20** | hsusb1-phy exclusive-vbus warning | ✅ GONE |
| **B8** | `Alternate GPT is invalid` | ✅ GONE — **the 2026-07-03 on-disk fix survived the reboot** (first boot with the resized p13 + relocated backup GPT: no "Alternate GPT" line). Zero occurrences in dmesg |
| **U4** | pipewire double-start / orphan socket | ✅ FIXED — only pulseaudio runs (pipewire/wireplumber absent from `ps`; the XDG `Hidden=true` override works), `snd_aloop` loaded, card `NexusQSpeaker` present |

Also verified:

- **Governor `ondemand`** on the device; `cpufreq/stats/time_in_state` exists
  (`CPU_FREQ_STAT=y` live). **1200 MHz @ 1 380 000 µV under load**, idle
  **920 MHz @ 1 317 000 µV** — exact OPP tracking.
- **Thermal:** idle 66–78 °C, **peak 91.8 °C** under dual-core load — only
  ~8 °C headroom to the 100 °C passive trip. Genuine but expected on this
  fanless sphere at 1.2 GHz; worth watching in future diags.
- **Access baking works:** key-based `ssh root@` succeeds over BOTH the USB
  gadget (`172.16.42.1`) and WiFi — the access regression is closed.
- **WiFi auto-joined** the baked 5 GHz profile; **stable IP `192.168.20.175`**
  (`wifi-stable-mac.conf` holds). ⚠️ Identity note: with
  `cloned-mac-address=permanent` the on-air MAC is the chip's **OTP MAC
  `14:7d:c5:3a:35:b5`**, NOT the factory/bcmdhd `f8:8f:ca:20:48:e1` — brcmfmac
  never reads the factory-cal MAC (the nvram `macaddr=` is the Broadcom
  placeholder). It is boot-stable now. **Open decision:** optionally bake
  `macaddr=f8:8f:ca:20:48:e1` into `brcmfmac4330-sdio.txt` to restore the
  factory identity. _(Resolved 2026-07-03 in BATCH 2 — but NOT via nvram: a
  live driver-reload test proved brcmfmac/fw IGNORES nvram `macaddr=`; the pin
  is NM-layer `cloned-mac-address=F8:8F:CA:20:48:E1`, see below.)_
- **Bluetooth up** (`BCM4330B1 (002.001.003) build 0482` patchram loads). The
  **U5** `bluetoothd: Failed to set default system config` error did **not**
  appear this boot (keep an eye on it; not claiming fixed). ⚠️ BD_ADDR is the
  default-pattern `43:30:A0:00:00:00` — no per-device BD_ADDR is set (minor
  identity item, same family as the WiFi MAC note).
- **Ethernet STILL dead** — LAN9500A never enumerates, PORTSC
  connect-status=0. The known v1.4.0 regression (task #17), unchanged.
- **Remaining err/warn set == the expected known-open inventory:** B4
  (`brcmfmac4330-sdio.google,steelhead.bin` + `.clm_blob` probe misses, then the
  generic fw loads: `FWID 01-cafa6b3e`), B10 `hw-breakpoint: Failed to enable
  monitor mode on CPU 0.` @0.463 s, B21 (journald BPF+ACL, L2C aux, gpmc cs0,
  pmu interrupt-affinity), B16 `ramoops: found existing invalid buffer` on the
  cold boot — plus the two NEW items below.

### NEW findings from the acceptance run

| ID | Evidence (verbatim, `#27` boot) | Analysis |
|----|--------------------------------|----------|
| **B22** | `twl: not initialized` **×22 burst @0.7797–0.7807 s**, firing immediately after patch 0013's `steelhead: vdd_mpu PMIC=TPS62361 i2c=0x60 volt_reg=0x01` @0.779 s (+2 expected retask-poll repeats @2.86/3.47 s) | The old ×4 OUT-OF-RANGE companion is gone (B12 fixed); this burst is a **different call site**: the 0013/0014 vdd_mpu init path hits `twl_i2c_*` before twl-core probes (~3.9 s). Grew from ×4 to ×22 because the path now runs further. **Top item for the next kernel batch.** |
| **B23** | `Skipping twl internal clock init and using bootloader value (unknown osc rate)` @3.567 s | Surfaced by `CONFIG_CLK_TWL=y` (B17 fix): the twl clock driver can't find its osc rate. Planned fix: twl node `clocks = <&sys_clkin_ck>; clock-names = "fck";` (38.4 MHz). |

### Diag-tooling bugs found by the acceptance run (nq-healthd, open)

Both live in `pmos/device-google-steelhead/nq-healthd`; fix in a follow-up:

1. **`led_frozen` is a PERMANENT FALSE CRIT on nexusqd r5+** — healthd
   fingerprints the led_classdev `brightness` attributes, but nexusqd commits
   frames via the **write-only `frame` bin_attr**, so the sampled `led_sum` is
   structurally 0 and the "frozen" heuristic always trips. Any current diag
   must **ignore `led_frozen`** and judge the ring by `nq_resp`/`nexusled
   status` + eyes.
2. **`vdd_mismatch` warnings are non-atomic freq/vdd sampling** — freq and
   vdd_mpu are read at different instants, so a DVFS transition between the two
   reads fabricates a mismatch. Fix: re-read freq after vdd and discard the
   sample if it moved.

### Flash-procedure notes worth keeping

- `fastboot flash boot` + `fastboot -S 100M flash userdata <all-RAW sparse>`:
  **~3 min total, 23 chunks, all OKAY**.
- A reflash **regenerates the device ssh host key** → run
  `ssh-keygen -R 172.16.42.1; ssh-keygen -R 192.168.20.175` (and any stale WiFi
  IP) on the host before the first post-flash ssh.

### Status after 2026-07-03

_(Superseded later the same day by BATCH 2 below.)_ Open, in priority order:
**B22** twl ×22 burst (next kernel batch), **B23** twl
fck clock init, the two **nq-healthd** bugs, the optional **WiFi factory-MAC**
decision, ethernet (task #17), then the untouched B4/B10/B16/B21, U5 (watch),
U6, U7, PA HDMI-audio UCM profile, deep cpuidle C2+. When released, this image
becomes **v1.6.6** (`PUBLIC_RELEASE=1`).

Raw capture: `postflash-dmesg.txt` (session scratchpad) +
`nq-captures/20260703-005812/` (report/snapshot/health series).

---

## BATCH 2 — built 2026-07-03 (kernel pkgrel 27 → uname `#28`, device r20), NOT YET FLASHED

Everything from the "Status after 2026-07-03" priority list except ethernet is
now **fixed in tree and built** — kernel `linux-google-steelhead` pkgrel
26→**27** (patches **0029–0031** added to `source=`+sha512sums; all 31 patches
apply GNU-patch-clean on pristine; next boot = `#28-postmarketOS`),
`device-google-steelhead` r19→**20**, DTS patch 0003 regenerated (842 lines;
DTB compiled, **zero twl6040 refs** verified in the binary). All build gates
green, incl. the pinned-MAC `wifi.nmconnection` (verified by exact-string grep,
content never printed) and the sparse all-RAW round-trip. **The device waits
for a manual fastboot power-cycle.** Evidence for the corrections:
`docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §6.

### Fixed in tree (awaiting flash)

| ID / item | Fix |
|-----------|-----|
| **B22** `twl: not initialized` ×22 burst @0.78 s (+2 poll repeats) | **Patch 0030**: twl-core exports **`twl_is_ready()`**; OMAP4 `omap_twl.c` gates the SMPS_OFFSET read attempt AND the patch-0014 retask poll on it; the retask work latches the real efuse once twl is up. Full call-site accounting of the ×22: per domain (IVA, CORE) 3 nonzero VC voltages ×2 read attempts + off ×1 + 2 VP limits ×2 = 11, ×2 domains = 22 — `uv_to_vsel` makes TWO read attempts per nonzero call (one direct, one via its `vsel_to_uv` range check). |
| **B23** `Skipping twl internal clock init…` | **Patch 0031**: twl-core `clocks_init()` gated to the **twl4030 class**. **Negative finding worth keeping:** the originally proposed DTS fix (twl `fck = <&sys_clkin_ck>`) was investigated and **REJECTED as actively harmful** — on twl6030 the CFG_BOOT/PROTECT_KEY offsets resolve to unrelated Phoenix PM registers (absolute `0x24`/`0x2D`, next to PHOENIX_DEV_ON); no mainline twl6030 board wires an fck; stock printed the same warning. |
| **healthd `led_frozen` false CRIT** | **Patch 0029**: `leds-steelhead-avr` `frame` bin_attr now **readable (0644)** — the system previously had NO readable ring-state source. `nq-healthd` (r20) fingerprints the frame attr (md5 + byte sum), brightness loop kept only as a pre-0029 fallback. |
| **healthd `vdd_mismatch` false warns** | `nq-healthd` (r20): `vdd_mismatch` evaluated only when `scaling_cur_freq` **holds across the vdd read** (kills the adjacent-OPP false warnings — 17/71 samples in the acceptance capture were this artifact). |
| **WiFi factory MAC** | Live driver-reload test proved **brcmfmac/fw IGNORES nvram `macaddr=`** (OTP `14:7d:c5:3a:35:b5` always wins) → the fix is **NM-layer**: baked profile + `scripts/gen-wifi-profile.sh` pin `cloned-mac-address=F8:8F:CA:20:48:E1`. After the flash the device appears under the **factory MAC** — new DHCP lease, the IP changes **one final time** from `.175`. |
| **DTS (0003 regenerated)** | **TWL6040 removal** (node + ABE sound card + `twl6040_pins` deleted, explanatory comment left; defconfig `TWL6040_CORE`/`SND_SOC_TWL6040`/`SND_SOC_OMAP_ABE_TWL6040`/`CLK_TWL6040` off); **i2c1–4 scl/sda pads `PIN_INPUT_PULLUP`→`PIN_INPUT`** (stock-exact, mux `0x100`, external pulls); **NFC comment rewritten** to the retracted/under-investigation status. |

### MAJOR CORRECTIONS (2026-07-03 stock-parity regulator audit)

1. **TWL6040 was NEVER a "dead codec" — the chip is unused/unpopulated on
   steelhead.** Stock 3.0.8 contains ZERO twl6040/AUDPWRON code (whole-image
   string+symbol sweep over `reverse-eng/vmlinux.bin`), the twldata codec pdata
   slot is NULL (`steelhead_twldata+0x24` @ `0xc0719b30`), stock i2c1 board
   info registers ONLY `twl6030@0x48`, and the removed node's
   `ti,audpwron-gpio` (gpio_127) had no stock evidence. The missing ACK at
   0x4b (2026-06-10) is **stock-correct behaviour**, not a fault.
2. **NFC "dead hardware" verdict RETRACTED** (never conclude dead hardware).
   Stock has NO software power path for the PN544 (pdata = 3 gpios only,
   `pn544_probe` makes zero regulator calls; VBAT/PVDD ride hardwired rails),
   and the full stock `steelhead_twldata` regulator array (VAUX1 3.0 V
   always-on no-consumer, VAUX2/3 boot-off, VPP/VUSIM off, VANA/V2V1/VCXIO
   always-on, VMMC→hsmmc, VDAC→hdmi_vref, VUSB→twl usb, CLK32KG boot_on
   consumer "clk32kaudio", CLK32KAUDIO slot NULL, +
   `regulator_has_full_constraints`) matches our live mainline
   `regulator_summary` **bit-for-bit**. Software parity COMPLETE → the no-ACK
   is **UNEXPLAINED**; status **"under investigation"**, NOT dead. Next
   discriminator: NFC on this unit under the **stock RAM boot**
   (`output/stock-adb-boot.img`; plan ready — unbind pn544 → sysfs gpio163 VEN
   high → `i2cdetect`/`i2ctransfer` 0x28 with pushed musl i2c-tools; stock
   kernel has i2c-dev per kallsyms), scheduled for the imminent flash cycle.

### PENDING — the flash-cycle checklist

1. **Manual fastboot power-cycle by Petr** (nothing below can happen first).
2. **Stock RAM-boot NFC discrimination test** (`fastboot boot
   output/stock-adb-boot.img`) — do it while in fastboot, before flashing.
3. **Flash `#28`** (boot + all-RAW userdata, `-S 100M`).
4. **Acceptance**: expect B22/B23 lines GONE, a clean nq-healthd capture (no
   `led_frozen`/`vdd_mismatch` artifacts, ring fingerprint via the frame attr),
   the **factory MAC `f8:8f:ca:20:48:e1` on air** (new lease — re-discover the
   IP; `.175` is stale after this), and **everything from batch 1 still
   holding** (9/10 classes gone, ondemand @ exact OPP voltages, root ssh,
   zero failed units).
