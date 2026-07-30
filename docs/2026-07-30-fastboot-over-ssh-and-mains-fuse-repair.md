# 2026-07-30 — Fastboot over ssh (kernel patch 0044) + the device died (blown mains fuse, repaired)

Two independent developments this session: a new **software capability** (enter
fastboot over ssh, no power-cycle) and a **hardware event** (the reference unit
died stone-cold — a blown mains fuse — and was repaired with zero collateral
damage). Both are recorded here as the engineering record; the release that
carries the software fix (v1.11.0) is also now flashed and live.

---

## 1. Fastboot over ssh — `systemctl reboot --reboot-argument=bootloader`

### Why
Entering fastboot required a **mains power-cycle** (unplug, cover the top
mute-LED sensor, plug back in). That is undesirable on this appliance: it has an
**integrated ~35 W mains SMPS** and a **single slow-blow fuse** (see §2), and
every cold power-cycle stresses the primary inrush path. A software route into
fastboot removes that stress and lets an agent put the device into fastboot for a
flash over ssh, hands-free.

### Root cause (why `reboot bootloader` did nothing on mainline)
The stock OMAP4460 u-boot on this unit decides whether to enter fastboot /
recovery on a **warm** reboot by reading a NUL-terminated ASCII reason string
from **SAR RAM**. Mainline never wrote it:
`arch/arm/mach-omap2/omap4-restart.c` `omap44xx_restart()` carried the literal
TODO

```
/* XXX Should save 'cmd' into scratchpad for use after reboot */
```

and **dropped `@cmd` on the floor** — so `reboot bootloader` never reached
u-boot's fastboot path. The only way into fastboot was the mute-LED power-cycle.

### Mechanism (reverse-engineered from the stock kernel)
Disassembled `reverse-eng/vmlinux.bin` (stock 3.0.8 SMP kernel) with
`reverse-eng/tools/nqdis.py`, function **`steelhead_reboot_notifier_handler`**:

- The reason string lives in **SAR RAM at physical `0x4A326000 + 0xA0C`
  (= `0x4A326A0C`)**.
- The stock notifier, on `SYS_RESTART`, **zeroed 0x20 bytes** at that offset,
  wrote the default **`"normal"`**, then overrode it with the reboot command.
- Honoured strings: **`"normal"`** (default), **`"bootloader"`** (→ fastboot),
  **`"recovery"`**, **`"recovery:wipe_data"`**.
- SAR RAM is in the **always-on** power domain and **survives the PRM global
  *warm* SW reset** (`omap4_prminst_global_warm_sw_reset` /
  `omap_prm_reset_system()`) that OMAP4 restart issues — so a string Linux writes
  there is still present when u-boot runs on the next boot.

### Fix
`kernel/patches/0044-ARM-OMAP4-steelhead-reboot-reason-scratchpad-fastboot.patch`
(kernel **pkgrel 44 → 45**, uname `#45` → `#46`). It reimplements the stock write
in `omap44xx_restart()`, exactly where the mainline TODO asked for it:

- guarded to `of_machine_is_compatible("google,steelhead")` (touches nothing on
  any other OMAP4 board),
- uses mainline's existing `omap4_get_sar_ram_base()` (SAR RAM is already mapped —
  no allocation, safe with IRQs off in the `.restart` hook),
- clears 0x20 bytes at `+0xA0C`, writes `"normal"`, then the command string —
  offset, clear size and the four reason strings match stock **byte for byte**.

Registered in `pmos/linux-google-steelhead/APKBUILD` (`source=` +
`sha512sums SKIP`, as every steelhead patch is).

### Verified on device — 2026-07-30
- `ssh root@<Q> systemctl reboot --reboot-argument=bootloader` → the device
  entered **fastboot in ~15 s**.
- `fastboot reboot` returned to Linux with **NO reboot loop** — u-boot clears the
  flag after honouring it (the `"normal"` default takes over on the following
  boot).
- systemd 261.

### ⚠️ It must be `systemctl`, not `reboot`
The argument only reaches the kernel via systemd. The busybox / util-linux
**`reboot` command does NOT forward the argument** — use
**`systemctl reboot --reboot-argument=bootloader`**. (`systemctl reboot
bootloader` is the equivalent short form.)

### Operational impact
- INSTALL §1 now offers this as the primary way to enter fastboot on an
  already-booted, provisioned **v1.11.0+** device; the mute-LED power-cycle stays
  documented as the **fallback and the first-time bootstrap** (a fresh/unbooted
  device, or any pre-0044 image, still needs the power-cycle).
- The `nexusq-connect` agent can now drop the device into fastboot for a flash
  without asking for hands-on the power cord.

---

## 2. The device died — blown mains fuse, repaired, zero collateral damage

### Symptom
On ~2026-07-30 the reference unit went **completely dead**: LED ring dark, no USB
enumeration, dead-cold. No boot, no fastboot, nothing.

### Diagnosis (multimeter)
- **Mains fuse: OL (open)** — blown.
- Everything downstream **intact / no short**: the primary **400 V cap rail** and
  the amp **470 µF caps** all read OL / no-short. Nothing had shorted to cause the
  fuse to blow; it was a fuse failure, not a downstream fault.

### Power architecture (recorded for the next repair)
- The Nexus Q has an **integrated ~35 W mains SMPS (85–265 VAC)** on power board
  PCB **`2400-00053-4`**. There is a **single slow-blow fuse** on the primary.
- **micro-USB is service/debug ONLY** — it **cannot power the device**. A dead
  mains supply means the whole unit is dark; USB will not bring it up.
- Amp board = **TAS5713 → banana jacks**.

### The correct replacement fuse
**Schurter `0034.6614`** — **T800 mA / 250 VAC**, **TIME-LAG (T / slow-blow)**,
**TR5 radial**, MST 250 series, **5.08 mm pitch** (GME part **1511926**).

⚠️ It **must be slow-blow (T)**. A fast fuse **nuisance-blows on the SMPS inrush**
and will not survive normal power-ups. This is exactly why a mains power-cycle is
worth avoiding when a software route into fastboot exists (§1).

### Outcome
Repair **succeeded**. A **full post-repair diag sweep found ZERO collateral
damage** — the unit is fully healthy again.

---

## 3. Deployment — v1.11.0 flashed and live

**v1.11.0 is now flashed and live** on the (repaired) device — the **first**
v1.11.0 to reach the hardware. rc1–rc3 were never flashed because the device died
first.

- **rootfs `v1.11.0-rc3`** + **boot `v1.11.0-rc4`** (kernel **`#46`**, pkgrel 45,
  **44 patches** through 0044).
- Carries the step-3 streaming services (Spotify / AirPlay / Roon with the
  per-service app toggles + per-service logs), the Settings-screen restructure,
  the official service brand icons, **and now patch 0044** (fastboot over ssh).
- Companion app at **1.5.2** — versioned on its **own independent track**, NOT
  aligned to the image release.

### Artifacts
- `output/nexusq-boot-v1.11.0-rc4.img`
  sha256 `8d40e429502a6fda28b6a07454a6542edecb8e6b4426f8a0768997336ade32ed`
- pairs with `output/nexusq-rootfs-v1.11.0-rc3-sparse.img`.
