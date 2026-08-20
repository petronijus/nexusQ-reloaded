# The ramdisk was never ignored — it was loaded on top of the kernel

*2026-08-20 — while building an offline root for the A/B rootfs split*

## Why this was being built

p13 holds the rootfs and is mounted as `/`. Nothing that needs the rootfs
offline — the A/B split, a factory reset, repairing a rootfs that will not
boot — can be done from the running system. That needs an environment which
does not live on p13: kernel + initramfs, in RAM.

## The finding

`scripts/build-rescue-initramfs.sh` produced a valid image, `fastboot boot`
reported `OKAY`, and the device came up **on the normal system**: full rootfs
mounted, the normal USB gadget, 25 mounts. The obvious reading was the one this
repo had already written down in two places — *"u-boot ignores the ramdisk
section"* — and on that reading the whole approach was dead.

It is wrong. The previous boot's kernel log says exactly what happened:

```
INITRD: 0x81000000+0x001ab000 overlaps in-use memory region
 - disabling initrd
```

`0x1ab000` is 1 748 992 B — our ramdisk, to the byte. **U-Boot passed it.** The
kernel threw it away, because the address we asked for is inside the kernel's
own memory. From `/proc/iomem` on the running device:

```
80008000-80efffff : Kernel code
81000000-811585cf : Kernel data
```

`make-bootimg.py` used `base + 0x01000000` = `0x81000000` for the ramdisk. That
is the Android-stock offset for this board, and it was fine for the stock 3.0.8
kernel, which was small. Our mainline 6.12 kernel is far bigger and its image now
runs past the 16 MB mark, so the stock ramdisk address lands in the middle of it.
The kernel notices, disables the initrd, and — having `CONFIG_CMDLINE_FORCE` with
`root=/dev/mmcblk0p13` — falls straight through to the normal system.

That fall-through is why this looked like "the bootloader ignored it" rather than
an error: the failure mode of a dropped initrd on this device is a perfectly
normal boot.

### Fix

`make-bootimg.py` now uses `base + 0x04000000` = `0x84000000` **when a ramdisk is
actually present** — ~40 MB clear of the kernel end and its appended DTB
(reserved to `0x8165ffdc`), far below the lowest carveout (`0xaf3f0000`), inside
the contiguous `0x80000000-0xafdfffff` bank. Images without a ramdisk keep the
stock value, so every ramdisk-less image stays byte-identical to what is already
flashed — which is what `nq-kernel-ota verify-self` compares against.

## Second finding: `promote` never reconciled the package database

`nq-kernel-ota promote` was documented from the start as ending with
`apk add --upgrade linux-google-steelhead`, to hand the new kernel over to the
package manager once it had proven itself. That step **existed only as a
comment** — the code never did it.

It was silent and it was real. After the first promotion the device booted
`6.12.12-r48` from slot A while `apk info` still said `r46` and `/boot/vmlinuz`
still held r46's kernel. Anything rebuilding an image from `/boot` quietly used
the wrong kernel — which is how the first rescue image ended up carrying r46, and
`verify-self` would have started reporting MISMATCH against a perfectly good
slot A.

Implemented in `cmd_promote`, and the live device reconciled by hand
(`apk add` from a local .apk — it has no default route on the USB link).
`verify-self` now matches: `d27dcafe2b341e53e8e49bf04c532b19`.

## Third finding: the rescue image needs its own subcommand

`autopromote` decides whether a trial boot succeeded by comparing `uname -r`
against the release recorded in the pending file. A rescue image is built from
the *running* kernel, so it has the **same release**. Staging it with
`nq-kernel-ota stage` would make the next normal boot conclude that the trial had
succeeded and copy the rescue image over slot A — a device that boots to a rescue
shell for good.

Added `nq-kernel-ota rescue <img>`: same slot, same bootloader trick,
deliberately no pending marker. (The `uname -r` check remains sound for real OTA
kernels — every release bumps pkgrel and `CONFIG_LOCALVERSION` puts it in
`uname -r`.)

## Four things the rescue image got wrong before it ever booted

Found by inspecting the built cpio and then running every binary in a **chroot on
the device** — none of these would have announced itself, they would just have
produced a black box with no serial console to ask.

1. **`telnetd` is not a busybox applet on Alpine.** It ships in
   `busybox-extras`; `busybox --list` confirms it is absent. The script linked
   `telnetd -> /bin/busybox`, so the only way into the environment would have
   silently failed to start.
2. **No `/dev/pts`.** telnetd allocates a pty per connection; without devpts it
   accepts and immediately drops every session.
3. **`libc.musl-armv7.so.1` was missing.** `ldd` prints the loader as
   `/lib/ld-musl-armhf.so.1` and the libc as `libc.musl-armv7.so.1=> /lib/...`;
   the path-extracting loop only saw the first form, so the name every binary
   records in its `NEEDED` entry was not in the image.
4. **`devmem` does not exist** in Alpine's busybox, and `dd` on `/dev/mem` cannot
   reach the SAR register either: on ARM the char-mem driver gates read/write
   through `valid_phys_addr_range()`, which admits RAM only. Measured, not
   assumed — the read returned 0 bytes.

(4) turned out not to need solving. Kernel patch 0044 writes the reboot reason
from the machine `.restart` hook on **every** restart, and with a NULL command it
writes the stock default `"normal"` — so a plain `reboot` out of the rescue shell
disarms the bootloader on its way down by itself.

## Safety properties of the resulting image

- **Reached without a cable**: staged into the trial slot (p8) and selected via
  the SAR reboot reason, the same mechanism the kernel OTA already proves.
- **A failed initramfs boots the normal system.** As established above, a kernel
  that cannot use its initrd falls through to `root=p13`.
- **Single-shot by construction**: `/init` copies slot A over the trial slot at
  startup, so no reboot can land back in the rescue image whatever the reason
  word says. Costs 8 MB of eMMC writes; p13 is not touched.
- **Dead-man timer**: the one failure it cannot report is a gadget that does not
  enumerate, and there is no serial console to fall back on. So it assumes nobody
  arrives and reboots itself into the normal system after 600 s unless someone
  runs `stay`.

## State

`output/rescue/rescue-boot.img`, 7 362 560 B (fits the 8 MiB trial slot),
uploaded to the device at `/tmp/rescue-boot.img`, md5
`b69a6961c7961ebf3b44eb6f714c04c7`, verified against the host copy. Every binary
in it has been run in a chroot on the device. Not yet booted.

---

# The A/B split, done

*same session, later*

The rescue image booted out of the trial slot on the first attempt — the host
saw the gadget come up as **"Nexus Q RESCUE"**, which is the proof the ramdisk
address was the whole problem.

Two things about the environment that only showed up live:

- **The `telnet` client cannot drive it.** It connects, negotiates and closes
  immediately with piped stdin. `nc` works perfectly: it gets the `~ #` prompt
  and command output. The IAC negotiation bytes at the head of the stream are
  cosmetic. Use `nc`, and keep stdin open a few seconds past the last command so
  the output has time to arrive.
- **`chmod` was not in the applet list**, so `/init`'s own `chmod +x /bin/stay`
  failed silently and `stay` came out mode 644. `touch /tmp/keep` does the same
  job. Added `chmod`, `wc` and `cut` to the list.

## What was done, in order

Everything below ran with **p13 not mounted** (`P13MOUNTED:0`).

1. `sfdisk -d /dev/mmcblk0` dumped to the host as
   `output/rescue/backup/gpt-dump-before.txt`.
2. `e2fsck -f -y /dev/mmcblk0p13` → clean, `EXIT=0`,
   `122921/1665472 files, 970495/3447163 blocks`.
3. `resize2fs -P` reported a minimum of 1 155 526 blocks; shrunk to
   **1 723 520 4K blocks = 6.57 GiB** (~4 min), `EXIT=0`.
4. New GPT built on the host from the dump — every other partition kept
   byte-for-byte including its UUID — validated for overlap and end-of-disk,
   transferred over the telnet channel and **md5-compared before use**
   (`10173d64a6c1f52b2cdae035eda5f58a`).
5. `sfdisk --force --wipe never --wipe-partitions never` (the explicit `never`s
   so it could not touch the ext4 signature it was about to shrink around),
   `EXIT=0`, kernel re-read the table.
6. `e2fsck -f -y` again → clean, **122 921 files, same count as before**.
7. `reboot -f`, normal system back in ~45 s.

## Result

```
p13  start=3200000   size=13788160  6.57 GiB  name="userdata"     slot A, in use
p14  start=16988160  size=13789151  6.57 GiB  name="userdata_b"   slot B, new
```

`df`: 6.3G total, 3.2G used, **54 %** — roughly 2× headroom on each slot.
Slot B formatted `mkfs.ext4 -L pmOS_root_b -m 0`. p11 `system` (1 GiB) and p12
`cache` (512 MiB) were deliberately left alone: they are unused by us, but they
are stock Android partitions that u-boot enumerates by name for fastboot, and
1.5 GiB was not worth changing more of the table than necessary.

Post-reboot health: `systemctl is-system-running` = running, no failed units,
nexusqd / nexusq-control / nexusq-mqtt / nq-healthd / sshd all active, dmesg
clean apart from the usual `twl_rtc … Power up reset detected`, governor
`conservative`, 58.6 °C.

## Open question

After returning from the rescue image the reboot reason reads **empty**, not the
`"normal"` that patch 0044 writes for a NULL command. Either u-boot clears the
word after consuming it, or the restart took a path that does not reach
`omap44xx_restart()`. Empty is the safe value either way, and the device booted
slot A, so nothing is broken — but the mechanism is load-bearing for the kernel
OTA and the assumption that the reason *persists* has never actually been
verified across a boot. Worth a deliberate test before anything else relies on
it.

## What is still needed for A/B rootfs

The partitions exist; booting from slot B does not work yet, and the reason is
`CONFIG_CMDLINE_FORCE`: the kernel hardcodes `root=/dev/mmcblk0p13`, so a second
rootfs cannot be selected at boot no matter what is on p14.

Now that ramdisks are known to work, the clean answer is the Android one. Put a
small initramfs in the boot image whose only job is to read a slot marker and
mount p13 or p14 as root. There is already a partition for exactly that: **p7,
1 MiB, named `misc`, unused** — which is where Android's bootloader control block
lives. That keeps a single kernel image for both slots and makes the switch a
one-sector write, with the same trial/promote/rollback shape the kernel OTA
already has.

---

# A/B rootfs, working end to end

*same session, later still*

The partitions were only half of it. `CONFIG_CMDLINE_FORCE` pins
`root=/dev/mmcblk0p13` into the kernel, so the second slot could not be selected
at boot no matter what was on it. It is selected by an initramfs instead — which
is only possible at all because the ramdisk address bug above turned out to be a
bug and not a bootloader limitation.

## The pieces

- **`nq-slot`** — a 512-byte record at offset 256 KiB in p7 `misc` (verified
  byte-for-byte zero before first use; the 2 KiB Android BCB header at the start
  is left untouched, and was md5-compared before and after to prove it).
  `NQSLOT1 / slot=<a|b> / try=<none|a|b>`. Anything unrecognised or corrupt reads
  as slot A — the slot that is known to work.
- **`scripts/build-ab-bootimg.sh` + `scripts/initramfs/init-ab`** — the boot
  image. `nq-slot consume` returns the device to mount *and clears a one-shot
  trial in the same step*, before that rootfs gets any chance to run. That
  ordering is the whole safety property: a slot that hangs, panics or never
  reaches userspace costs one reboot, with no bootcount in the bootloader and no
  help from userspace. If neither slot mounts, it brings up the gadget and
  telnetd rather than panicking at a board with no serial console.
- **`nq-rootfs-ab`** — populate the inactive slot from the running one
  (`tar --one-file-system --xattrs --acls --sparse`, journal excluded), drive the
  trial, and `autopromote` at boot.
- **`nexusq-rootfs-ab-promote.service`** — runs every boot, does nothing unless
  the slot that booted is not the committed one. That can only mean a trial is in
  flight, because the initramfs already consumed the marker on the way up.

All of it is packaged (`pmos/nexusq-rootfs-ab`, wired into `docker-build.sh`, a
dependency of the device package) so a rebuild keeps it.

## Measured, in order

1. A/B image trial-booted from the trial slot: `[nq-ab] slot marker selects
   /dev/mmcblk0p13`, `mounted`, and `/` became `/dev/mmcblk0p13` instead of
   `/dev/root` — which is the proof `switch_root` ran.
2. Slot B populated from the live slot A: 123 203 files, `/sbin/init ->
   systemd`, fstab rewritten to slot B's own UUID. ~13 min.
3. Slot B trial-booted: `/` = `/dev/mmcblk0p14`, label `pmOS_root_b`, systemd
   running, no failed units, every service active. Marker consumed, committed
   still A, so the next boot returned to A on its own.
4. A/B image promoted into slot A through the kernel-OTA flow
   (`stage` + `try` + health-gated `autopromote`). A **plain** reboot now runs
   the initramfs.
5. Automatic rootfs promotion, both directions:
   `booted slot b but slot a is committed — this is a trial` →
   `healthy after 10s — committing slot b`, then the same back to A.

Final state: running slot A, committed slot A, no trial pending, both boot slots
holding the A/B image, `systemctl is-system-running` = running.

## Three things this cost, worth writing down

- **`printf` is not an ash builtin** in Alpine's busybox. `nq-slot`'s record
  writer used it, so under `set -e` it exited silently and wrote nothing. Caught
  by running the image's own binaries in a chroot on the device, not by booting
  it — the boot would have looked like "the marker does not work".
- **Padding from `/dev/zero` made the tool untestable.** Rewritten to
  `dd conv=notrunc,sync`, which NUL-pads the single short block: same result, no
  `/dev` needed, so it can be tested anywhere.
- **Setting the reboot reason and then rebooting normally does not work.** Patch
  0044 rewrites the reason from the machine `.restart` hook on *every* restart,
  so a plain reboot clobbers it with the default `"normal"` on the way down. Only
  `systemctl reboot --reboot-argument=recovery` survives. Measured the hard way:
  a trial that quietly booted slot A instead. `nq-kernel-ota reason` now says so
  when it sets a value.

## The health gate had to be corrected, not bypassed

`nq-kernel-ota`'s promote gate required a default route and a pingable gateway,
and refused to promote: `NOT healthy after 180s`. The gate was right to fire —
the device genuinely had no route — but its rule was stricter than its purpose.
The purpose is "this kernel produced a system somebody can still reach", and this
device spends much of its life on the USB gadget link with no route at all; that
link is how it is administered and how it would be rescued. The gate now accepts
either a working gateway **or** a `usb0` that is `LOWER_UP` (a host has actually
enumerated it, not merely that we brought the interface up) with an address.

## Open, and Petr's call

**The Q has no network but the USB cable.** `wlan0` is disconnected and the saved
profile is `Svatovitske-Internety-5g`, which does **not appear in a scan** from
where the device now sits — while `Svatovitske-Internety`, `Svatovitske-IoT` and
`Svatovitske-Internety_EXT` all do, on 2.4 GHz only. 5 GHz scanning itself works
(other 5 GHz networks show up). eth0 has no carrier. So the 5 GHz AP does not
reach the Q's new position. Joining the 2.4 GHz SSID would fix connectivity but
2.4 GHz is the band that stalls Bluetooth bulk transfers on this chip, and that
is a trade to make deliberately, not silently.

## Still to do

The **boot image the build produces does not carry the A/B initramfs** — it is
currently assembled from the running device by `scripts/build-ab-bootimg.sh`. A
freshly flashed image therefore boots without slot selection. That degrades
safely (the kernel mounts p13, which is slot A) but it means a reflash silently
turns the feature off until the image is rebuilt from the device. Folding the
initramfs into the build's own boot.img is the next piece.
