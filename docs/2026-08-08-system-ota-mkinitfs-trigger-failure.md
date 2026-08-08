# 2026-08-08 — System OTA reports "system update failed" (postmarketos-mkinitfs / boot-deploy trigger)

Diagnosed on-device 2026-08-08. Companion note to
`docs/2026-08-08-usb-audio-playback-delay-and-ota-publish.md` (same session).
This is **Phase-2 (kernel/boot OTA)** territory — recorded as a follow-up, **NOT
fixed**.

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

The **live reference device currently carries this pending failing trigger.**

## Candidate fixes (NOT yet implemented — need a build + careful validation)
Any fix must first verify that **boot-deploy does NOT touch the real boot
partition**. With the current minimal `/etc/deviceinfo`, boot-deploy's default
output dir is `/boot` — i.e. it would write harmless files into a plain dir, not the
flashed p9. Options:

- **(A)** Stop stripping `/boot/vmlinuz` (+ friends) from the rootfs, so boot-deploy
  finds a kernel and the trigger **succeeds as a harmless no-op** (deploys into the
  plain `/boot` dir, never the boot partition). Also lays groundwork for real kernel
  OTA.
- **(B)** Neutralize / override the mkinitfs trigger on this device via the device
  package (`device-google-steelhead`), so the trigger is a no-op on this appliance.
- **(C)** Full **Phase 2** — a userspace **boot-partition (p9) writer** + a recovery
  fallback so boot-deploy actually deploys a new kernel/initramfs and the kernel can
  update over OTA (the currently-unsolved "System" track).

Whichever is chosen must ship in `device-google-steelhead` (or the build) and be
validated end-to-end (System update from the app succeeds; `apk fix -s` clean; the
device still boots from the flashed partition).

## Cross-refs
- `docs/2026-08-02-full-system-ota-and-glibc-rt-split.md` — Phase 1 System OTA (the
  kernel is deliberately excluded; a kernel apply = a boot-partition flash = Phase 2).
- `scripts/make-bootimg.py` / the ramdisk-less boot.img design — why `/boot` is empty
  on-device.
- `docs/2026-08-08-usb-audio-playback-delay-and-ota-publish.md` — the other 2026-08-08
  on-device follow-up.
