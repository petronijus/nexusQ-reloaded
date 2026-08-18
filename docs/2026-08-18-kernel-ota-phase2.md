# 2026-08-18 — Kernel OTA (Phase 2): the trial-slot design, and what the bootloader will and won't do

Phase 1 (apk OTA) has shipped userspace since 2026-08-02. **Phase 2 — applying a
kernel without a cable — was never started**: it was scoped out on day one
("applying a kernel is a boot-partition flash, not an `apk upgrade`") and stayed
out, because `fastboot-over-ssh` (patch 0044, 2026-07-30) appeared to have solved
the problem: `systemctl reboot --reboot-argument=bootloader` lands in fastboot, so
"no more mains power-cycle".

**That assumption broke on 2026-08-18.** The Q lives on WiFi with nothing plugged
into its micro-USB. Sending it to the bootloader worked perfectly — and left it
unreachable, because fastboot needs a USB host and there wasn't one. Getting it
back took the mute-sensor power-on trick and a cable. So "kernel updates are
software-only" was never true; it was true only while a cable happened to be
attached.

## eMMC layout (measured, not assumed)

| part | size | contents |
|---|---|---|
| p1 | 95 KiB | **u-boot environment** — `bootcmd=booti`, `bootdelay=0`, `fastboot_unlocked=1` |
| p2 | 16 KiB | all zero |
| p3 | 384 KiB | SPL / `U-Boot 2011.09-rc1`, `PRIMAPP`/`KEYS`/`CertPK` |
| p4, p6 | 512 KiB each | u-boot (two copies) |
| p5 | 512 KiB | **device_info** — WiFi/BT/eth MACs, `androidboot.serialno=AW1S12241020` |
| p7 | 512 KiB | all zero |
| **p8** | **8 MiB** | **recovery** — stock Android (its ramdisk has `etc/recovery.fstab`, `sbin/adbd`) |
| **p9** | **8 MiB** | **boot** — our ramdisk-less image (kernel 5 543 872 B, `ramdisk_size=0`) |
| p10 | 8 MiB | a filesystem containing `/factory` |
| p11 / p12 / p13 | 1 GiB / 512 MiB / 13.4 GiB | system / cache / **rootfs** |

Bootloader: `U-Boot 2011.09-rc1 (Apr 17 2012)`, `version-bootloader:
steelheadB4H0J`, fastboot serial `AW1S12241020`, `product: steelhead`.

## The design

The industry pattern for this problem — SWUpdate, RAUC, Mender — is a second
slot plus a trial boot: write the new image to the inactive slot, boot it once,
and only mark it good if it came up. U-Boot supports that natively through
`bootcount`/`bootlimit`/`altbootcmd`.

**We cannot use any of that**: the bootloader is a 2012 Android u-boot we do not
build. What it *does* give us is a second bootable slot and a way to select it:

- **slot A = p9 (`boot`)** — the kernel known to work. Never written with an
  image that has not booted.
- **slot B = p8 (`recovery`)** — the trial slot. u-boot boots it when the reboot
  reason in SAR RAM (`0x4A326A0C`) reads `recovery`; kernel patch 0044 writes
  that string, reproducing the stock `steelhead_reboot_notifier_handler`.

    stage    write the image to slot B, read it back, compare md5
    try      set the reason, reboot — u-boot runs the new kernel from slot B
    promote  on the next successful boot, copy B→A and clear the reason

A kernel that does not boot therefore cannot cost us the kernel that does.
Implemented in `userspace/nexusq-kernel-ota/nq-kernel-ota`.

Userspace can read *and* write the reason directly (`/dev/mem`, since the kernel
has `CONFIG_DEVMEM=y` and does **not** set `CONFIG_STRICT_DEVMEM`), so `promote`
can disarm the trial itself rather than hoping something else does.

## ⚠️ What the bootloader will NOT do (measured, and it cost us an outage)

**Stock u-boot does not fall back when the trial image is unbootable.** Tested
2026-08-18 by zeroing p8's Android header and setting the reason to `recovery`:
the device did not return within 5 minutes, and **a power-cycle at that moment did
not bring it back either**. It took the documented hardware path — cover the mute
sensor at power-on for fastboot — plus `fastboot -s AW1S12241020 flash recovery`
from the backup to restore it. Total downtime ≈ 40 minutes of someone's evening.

Consequences that must survive into the design:

1. **A failed trial boot needs hands on the device.** Not a reboot command — a
   mute-sensor fastboot session, or a long power-off. `nq-kernel-ota try` refuses
   to run without an interactive `YES` and prints exactly this, because the one
   thing worse than a manual rescue is a *surprise* manual rescue.
2. **A kernel update must never be silent or automatic**, unlike the userspace
   OTA which can run unattended. It belongs behind a deliberate action, ideally
   only when someone is near the device.
3. Do not repeat the diagnosis error: after the failure I claimed the recovery
   request was persisted in eMMC, reasoning from the u-boot string *"starting
   recovery because of SAVED reboot flag"*. **The data does not support that** —
   the u-boot environment is clean, p2/p7 are entirely zero and SAR RAM reads
   empty after a normal boot. The likelier explanation is that SAR RAM sits in the
   always-on domain and a brief mains interruption does not drain it. Unresolved,
   and it should stay written down as unresolved.

## ⛔ Blocker before the first real run: module trees collide

`CONFIG_MODVERSIONS=y` and the WiFi stack is modular (`CONFIG_CFG80211=m`), while
both kernels call themselves `6.12.12` — so both install into
`/lib/modules/6.12.12`. Installing the new kernel's modules **overwrites the
running kernel's**, which poisons the very fallback the design exists to protect:
roll back to slot A and its modules are gone, i.e. no WiFi, i.e. no way in.

The fix is a distinct version string for the new kernel (`CONFIG_LOCALVERSION`,
e.g. `-nq2`) so its modules live in their own directory and both trees coexist.
**Phase 2 must not be exercised end-to-end until that lands.**

Related: the kernel apk is deliberately absent from the OTA repo
(`scripts/publish-ota-repo.sh`, "the kernel stays flash-only"). Phase 2 needs it
published, because that apk is what delivers the matching modules and the `/boot`
payload.

## Status

- ✅ layout mapped; p8/p9 backed up to `reverse-eng/factory/partitions/`
- ✅ `nq-kernel-ota` written; `status` verified on the live device (reads both
  slots and the SAR reason)
- ✅ trial-slot selection proven to work — including its failure mode
- ⛔ `LOCALVERSION` split, kernel-in-OTA-repo, the promotion systemd unit, and the
  app-side action are not done
- ⛔ no end-to-end run has been performed, and must not be until the module
  collision is fixed
