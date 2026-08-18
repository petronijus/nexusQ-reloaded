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

## ✅ Blocker found and closed before the first real run: module trees collided

`CONFIG_MODVERSIONS=y` and the WiFi stack is modular (`CONFIG_CFG80211=m`), while
both kernels call themselves `6.12.12` — so both install into
`/lib/modules/6.12.12`. Installing the new kernel's modules **overwrites the
running kernel's**, which poisons the very fallback the design exists to protect:
roll back to slot A and its modules are gone, i.e. no WiFi, i.e. no way in.

Fixed in kernel **r48**: `prepare()` injects `CONFIG_LOCALVERSION="-r$pkgrel"`
(and the defconfig turns `LOCALVERSION_AUTO` off so the string is deterministic),
so every build gets its own release and its own module directory. Keyed on
pkgrel rather than a fixed suffix, so the update after this one does not collide
either. Verified on the built apk: `kernel.release` = `6.12.12-r48`, modules in
`/lib/modules/6.12.12-r48`.

Related: the kernel apk is deliberately absent from the OTA repo
(`scripts/publish-ota-repo.sh`, "the kernel stays flash-only"). Phase 2 needs it
published, because that apk is what delivers the matching modules and the `/boot`
payload.

## The second half of the module trap: `apk upgrade` deletes the old tree

`CONFIG_LOCALVERSION=-r<pkgrel>` (kernel r48) makes the two module trees
*coexist* — `/lib/modules/6.12.12` and `/lib/modules/6.12.12-r48`. Verified on
the built apk. **That alone is not enough.**

If the kernel apk is simply published and `apk upgrade` installs it, apk removes
the OLD package's files as part of the upgrade — including
`/lib/modules/6.12.12`, the running kernel's modules. The rollback path is
poisoned again, just one step later: slot A still boots, but the kernel it boots
no longer has modules.

So the OTA flow must **not** upgrade the package until the new kernel has proven
itself:

1. `stage` extracts the new kernel's `/boot` payload and
   `/lib/modules/<new release>` **out of the apk, by hand**, leaving the
   installed package (and its module tree) untouched
2. build/write the boot image into the trial slot, trial-boot it
3. **only on promote** run the real `apk add --upgrade linux-google-steelhead`,
   so the package database catches up once the new kernel is the running one
4. on rollback nothing needs restoring — the old package was never removed

This is why `nq-kernel-ota` grows a `stage-apk` mode rather than leaning on
`apk upgrade`; the apk in the OTA repo is a *payload source*, not something the
device installs on sight.

## ✅ Proven end to end on the live device (2026-08-18)

First kernel ever applied to this Q without a cable — `6.12.12` → `6.12.12-r48`:

| step | what happened |
|---|---|
| `stage-apk` | modules installed to `/lib/modules/6.12.12-r48`, the running kernel's `/lib/modules/6.12.12` left intact — **both trees present**; boot image packed, written to the trial slot, read-back verified |
| `try` | armed the SAR reason, rebooted |
| **trial boot** | SSH back in **36 s** running `6.12.12-r48 #49` **from the trial slot**; system `running`, WiFi up on the same address, and `schedutil` finally in `scaling_available_governors` |
| `autopromote` | recognised the staged release, health gate passed at 0 s (services + a real ping through the default route), copied trial → boot, disarmed |
| plain reboot | came up on the promoted kernel from slot A in **30 s**, no flag involved |

Slot A was never written with an image that had not already booted.

### Defects this run exposed (all fixed)

- `sar()` called `m.flush()` on a MAP_SHARED mapping of `/dev/mem`, where
  `msync()` returns EINVAL — printing a Python traceback on **every** arm and
  disarm. The store had already landed, so it worked, but a traceback on the code
  path that rewrites boot state is precisely what buries the next real failure.
- The device APKBUILD's `depends=` is a **shell string**: the explanatory `#`
  lines added inside it became literal dependencies
  (`ERROR: device-google-steelhead: dependency not found: #`). Comments belong
  above the string, and there is now a note there saying so.
- The aport depended on `iputils`/`iproute2` for a `ping -c1` and an `ip route`
  the device already has (`ping` is busybox's). That pulled in
  `iputils-tracepath`, and the install failed the moment a mirror hiccupped —
  on a device whose whole point is updating itself over the network. Now
  `depends="python3"`.

## Packaging

`pmos/nexusq-kernel-ota/` (aport) + `userspace/nexusq-kernel-ota/`
(tool, unit, preset). Installed and verified on the device: `/usr/bin/nq-kernel-ota`,
`nexusq-kernel-ota-promote.service` **enabled** via `97-nexusq-kernel-ota.preset`,
state in `/var/lib/nexusq-kernel-ota/`. `device-google-steelhead` r75 depends on
it, and `scripts/publish-ota-repo.sh` ships it.

## How to update a kernel now

```sh
# on the device, with someone near it
nq-kernel-ota stage-apk /path/to/linux-google-steelhead-<ver>.apk
nq-kernel-ota status          # slot A must still be the old image
nq-kernel-ota try             # asks for YES, then reboots into the trial slot
# after it comes back:
nq-kernel-ota status          # or let nexusq-kernel-ota-promote.service do it
```

`restore` puts slot A back from the pre-stage backup. If the trial kernel never
comes up, slot A is untouched — but getting there needs hands on the device
(mute sensor at power-on → fastboot).

## The device could not reach the OTA repo at all — no RTC, so no DNS

Publishing the kernel exposed a fault that had nothing to do with kernels:
`apk update` reported "6 stale" and `wget` said **`bad address
'petronijus.github.io'`**, which looks like a network failure and is not one.

    resolvectl query petronijus.github.io
    ... resolve call failed: DNSSEC validation failed: signature-expired

The clock read **2000-01-01**. This board has no usable RTC (`hwclock -r` times
out), so every boot starts 26 years in the past; systemd-resolved validates
DNSSEC, and against that clock every signature is "expired". Meanwhile
systemd-timesyncd shipped only `FallbackNTPServers=*.pool.ntp.org` — **hostnames**.
So: no time → no DNS → cannot resolve an NTP server → no time. A closed loop the
device cannot leave on its own, and the reason it had worked until now is simply
that it had been *up* for 6.9 days with a clock synced before the reboots.

Fixed in **device r76** with `/etc/systemd/timesyncd.conf.d/10-nexusq-ntp-by-ip.conf`:
NTP servers as **IP literals** (LAN gateway first, then Cloudflare/Google
anycast), so timesyncd reaches one before DNS is involved at all. Verified on the
device: it synced from `162.159.200.1` and `System clock synchronized: yes`,
after which DNS resolved immediately and the OTA upgrade went through.

**This matters beyond kernels**: every OTA the device performs depends on it, and
the failure mode is misleading — it presents as a dead network.

## The kernel exclusion was a comment, not code

`install_system_update()` in nexusq-control documented "EXCEPT the kernel", but
the implementation was a plain `apk upgrade --available`. The kernel was excluded
only by not existing in any repo the device reads — and publishing it as a
payload source removed exactly that protection. A "System update" tap would then
have installed the kernel package: deleting the RUNNING kernel's `/lib/modules`
and writing nothing to the boot partition, so the next boot comes up on the old
kernel with no modules — no cfg80211, no WiFi, no way back in.

**nexusq-control r30** now passes `--ignore linux-google-steelhead` (apk-tools
3.0.7: "Upgrade all other packages than the ones listed"), verified on the device.
The check path already filtered it; now both halves agree, and the kernel is
applied only by `nq-kernel-ota`.

## Post-swap diagnostic and two things it caught

A full sweep on r48 came back **PASS with no regressions** — every DTS-dependent
fix survived the rebuild (factory WiFi MAC / patch 0043, ethernet pad mux / #17,
DPLL_ABE / 0042, BT baud / 0040), modules resolve against
`/lib/modules/6.12.12-r48` with zero vermagic or symbol complaints, VDD_MPU
tracks the OPP exactly at all three points (`vdd_mismatch` 0 of 5439 samples),
1.2 GHz is reached, no throttling, and the boot log is *quieter* than the kernel
it replaced. Capture: `nq-captures/20260818-230118/`.

Two findings worth carrying forward:

**`CPU_IDLE_GOV_TEO=y` builds TEO but does not select it — a no-op as shipped.**
The cpuidle governor is chosen by rating and `menu` (20) outranks `teo` (19);
there is no `CONFIG_CPU_IDLE_GOV_DEFAULT_*` in this tree, so it would take
`cpuidle.governor=teo` on the kernel cmdline. **Deliberately not doing that**:
this board exposes exactly one idle state (`C1, MPUSS ON`), so the governor has
nothing to choose between and TEO cannot pay for itself. It only becomes
interesting if deep C2/C3 ever land, which is blocked without a serial console.
Recorded as a dead end rather than a to-do.

**The promotion unit had never executed once**, so its boot behaviour was
unproven — the package happened to install after `multi-user.target` on the boot
that introduced it. Reviewing it then turned up two real defects, both fixed in
**nexusq-kernel-ota r2**: it was `WantedBy=multi-user.target` *and*
`After=multi-user.target` (the same self-ordering shape that once made systemd
resolve a dependency by deleting nexusq-control's start job), and it ordered
itself `After=network-online.target`, a target that is **inactive** on this
device and therefore guarantees nothing. Both `After=` lines are gone: the unit
only has to run, because `autopromote` does its own waiting. **Its boot behaviour
still needs verifying on the next reboot.**

## Status

- ✅ layout mapped; p8/p9 backed up to `reverse-eng/factory/partitions/`
- ✅ `nq-kernel-ota` written; `status` verified on the live device (reads both
  slots and the SAR reason)
- ✅ trial-slot selection proven to work — including its failure mode
- ✅ `LOCALVERSION` split (kernel r48), `stage-apk`, the promotion unit, the
  aport + preset, and OTA-repo inclusion are all done and installed
- ✅ **end-to-end run completed on hardware** — see above
- ✅ the kernel apk **is** published to the OTA repo as a payload source, and
  `nq-kernel-ota stage-latest` fetches it over the network (`apk fetch`, never
  `apk add`) — verified end to end on the device, including its refusal to stage
  the kernel that is already running
- ⛔ no app-side action yet (the update is CLI-only, which given the
  attended-only requirement is arguably the right default for now)
- ⛔ the SAR-RAM-vs-power-cycle question from the failed-trial test remains
  unresolved, and the failure path still needs physical access
