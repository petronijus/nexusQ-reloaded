# 2026-08-08 — System OTA reports "system update failed" (postmarketos-mkinitfs / boot-deploy trigger)

Diagnosed AND **FIXED** on-device 2026-08-08 (Option A). Companion note to
`docs/2026-08-08-usb-audio-playback-delay-and-ota-publish.md` (same session). The
live device no longer reports the failure (`apk fix -s` clean); the durable build
fix is in `docker-build.sh` (verified on the next full build). See **Resolution**
below.

---

## Symptom (measured on-device)
The companion app's **"Nexus Q" System update** (`installSystemUpdate`, PROTOCOL
§12b) shows **"system update failed"**. On the device, `apk fix -s` reports:

```
(1/1) Reinstalling postmarketos-mkinitfs … 1 error
```

i.e. a **persistent pending trigger** that will re-fire and **fail on EVERY future
apk transaction**, not a one-off.

## Root cause (evidence from `/var/log/apk.log`)
```
ERROR: No kernel found in /boot (checked: vmlinuz*, linux.efi)
boot-deploy failed → exit status 1
ERROR: postmarketos-mkinitfs-2.11.1-r0.trigger: exited with error 1
```
The `postmarketos-mkinitfs` trigger runs `/usr/bin/boot-deploy`, whose `get_kernel`
requires a kernel image in `/boot`. On this device **`/boot` is an EMPTY plain dir**
— **not** a mount (`findmnt /boot` is empty; there is no boot mount). The
`linux-google-steelhead` package **does** ship `boot/vmlinuz` (+ `System.map`,
`config`, `dtbs`), but it is **stripped from the rootfs after install** because the
Q boots **ramdisk-less directly from the flashed boot partition** (see
`scripts/make-bootimg.py` / the ramdisk-less boot.img design — the running kernel
lives in the flashed boot partition, independent of `/boot`).

So boot-deploy finds no kernel → the trigger exits 1 → apk records a pending failed
trigger.

## IMPORTANT nuance — packages DO install despite the "failure"
The trigger runs at the **end** of the transaction and does **not** roll anything
back. Verified in `apk info` after the "failed" update: **`device-google-steelhead`
r63, `firmware-google-steelhead` r63, and `nexusqd` r12 all committed.** The device
is healthy and boots fine (the kernel is in the flashed boot partition, unaffected).

The failure is therefore:
- **(a) cosmetic-but-alarming** — the app says "system update failed" when the
  packages actually installed, and
- **(b) a blocker to a clean apk state** — the pending trigger re-fails on every
  subsequent apk run until it is resolved.

## Resolution — Option A (implemented + live-verified 2026-08-08)
Chosen fix: **put the kernel payload in `/boot`** so boot-deploy's `get_kernel`
succeeds. Rejected (B) as hacky and (C) as a much larger project (still the real
long-term goal for actual kernel OTA).

**Safety first — confirmed boot-deploy NEVER touches the real boot partition.** Read
`/usr/bin/boot-deploy` main(): the only partition-write is `flash_updated_boot_parts`
(line 64), which is `[ "${deviceinfo_flash_kernel_on_update}" = "true" ] || return 0`.
`deviceinfo_flash_kernel_on_update` is **unset** in this device's deviceinfo (which
DOES have `deviceinfo_generate_bootimg="true"` + `flash_method="fastboot"`), so
boot-deploy only ever *generates* a boot.img and copies files into `output_dir=/boot`
— it never `dd`/fastboots a partition on an `apk`-driven update. Zero brick risk; the
generated `/boot/boot.img` (~16 MB, larger than the 8 MB p9) is **inert** — the Q
boots ramdisk-less from the flashed p9 via `make-bootimg.py`, never from `/boot`.

**Live device (no reflash):** extracted the `boot/` payload (vmlinuz + dtbs +
System.map + config) from the exact installed kernel apk
`linux-google-steelhead-6.12.12-r46` (from the `nexusq-workdir` build volume), scp'd
it into `/boot`, then ran `mkinitfs` → boot-deploy completed (exit 0: appended the
omap4-steelhead DTB, generated boot.img, installed to /boot, **no flash**). `apk fix`
re-ran the pending trigger → **`OK: … 982 packages`**, and `apk fix -s` is now clean
(0 errors). `systemctl is-system-running` = `running`. The app's System update will
no longer report failure.

**Durable (build):** `docker-build.sh` Phase-10 post-processing now copies
`$ROOTFS/boot/{vmlinuz,dtbs,System.map,config}` into the exported rootfs `/boot`
before unmount (right after the fstab-strip / root-unlock, mounted at `$RP_MNT`). The
build exports only the rootfs partition, leaving pmbootstrap's separate `/boot`
partition (where the kernel apk installs) behind — this restores the payload so every
future image ships a non-empty `/boot` and the trigger succeeds from first boot.
Pending verification on the next full build.

## Still-open long-term (Phase 2, unchanged)
Option A makes the trigger *succeed*; it does **not** make the kernel itself
OTA-updatable. Real kernel OTA still needs the **(C)** userspace boot-partition (p9)
writer + recovery fallback — tracked separately as Phase 2 (see PLAN.md).

## Cross-refs
- `docs/2026-08-02-full-system-ota-and-glibc-rt-split.md` — Phase 1 System OTA (the
  kernel is deliberately excluded; a kernel apply = a boot-partition flash = Phase 2).
- `scripts/make-bootimg.py` / the ramdisk-less boot.img design — why `/boot` is empty
  on-device.
- `docs/2026-08-08-usb-audio-playback-delay-and-ota-publish.md` — the other 2026-08-08
  on-device follow-up.
