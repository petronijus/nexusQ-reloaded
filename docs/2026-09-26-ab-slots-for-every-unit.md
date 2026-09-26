# 2026-09-26 — A/B rootfs slots for every unit, from a flash or over the air

## Why

A/B rootfs was built in August (the A/B initramfs in the boot image,
`nq-rootfs-ab`, `nq-slot`, `deploy-rootfs-slot.sh`), but slot B itself, p14, was
made **once, by hand**: the Prague Q, repartitioned from a rescue shell on
2026-08-20 (`docs/2026-08-20-rescue-initramfs-and-ramdisk-address.md`). Nothing
in the image, the install guide or any OTA ever did it again. The cottage Q, and
every Q flashed from a GitHub release, carried the whole machinery with
`slot b: /dev/mmcblk0p14 label=- uuid=-`. It surfaced when sizing a Spotify cache
cap: the answer depends on whether a slot is 13 GB or 6.6 GB.

## Two paths, one table

Both write the table in `userspace/nexusq-rootfs-ab/ab-lib.sh` (`ab_layout`,
`ab_table`), which reproduces the Prague split on this eMMC:
`p13 3200000 +13788160`, `p14 16988160 +13789151`, last usable LBA `30777310`.
Letting sfdisk recompute `last-lba` puts the backup GPT at the real end of the
disk, and that fixes **B8** (`Alternate GPT is invalid`, from the factory p13
running to the last sector) as a side effect.

### A fresh flash — online, on the first boot (`nexusq-resize-rootfs`)

After a flash the ext4 in p13 is the image's size (~2.8 GiB) inside a 13 GiB
partition, so the space behind it is empty and p13 can be shortened while
mounted. The sequence and its guards:

1. `sfdisk --no-reread --no-tell-kernel` writes the new table.
2. `resizepart`/`partx -a` update the kernel over BLKPG. A table re-read is
   refused while a partition is mounted.
3. **Verify** that the kernel now sees exactly the new sizes. Only then:
4. format p14, but only because a `.ab-split-pending` marker written before
   step 1 says this script created it. A p14 it did not create is somebody's
   rootfs and is never touched.
5. grow slot A's ext4 to the new, smaller p13.

If step 3 fails, the ext4 is not grown, because the kernel's stale view would
let it run into slot B. The next boot reads the table from disk, finds p14 and
the marker, and finishes. Tested with `tests/test_ab_split.sh` on a
`--privileged` container, using a sparse image of the eMMC's size that carries
a factory primary GPT copied off a unit (fixture
`gpt-primary-factory.bin`). The cases are: fresh flash, idempotence, the kernel
refusing the update, and an ext4 that already fills p13 (no split). **Not yet
run on hardware**: no unit without p14 is left to flash.

### A unit in the field — offline, once (`nq-rootfs-ab split`, `init-split`)

An ext4 that fills p13 cannot be shrunk while mounted, so this reuses the
rescue mechanism: a boot image in the kernel trial slot, selected once through
the SAR reboot reason (`nq-kernel-ota rescue`). What is new is that the unit
builds the image **itself**:

- slot A's kernel section, so its own WiFi/BT identity in the DTB;
- `init-split` and `ab-lib.sh`;
- its own `e2fsck`, `resize2fs`, `dumpe2fs` and `sfdisk`, collected by the
  repo's single initramfs collector, `make-ab-initramfs.py`, which the package
  ships.

The result is 7.55 MB, within the 8 MiB slot. `init-split` makes itself
single-shot (slot A → p8). It then runs `e2fsck -f`, the fit check, the shrink,
`e2fsck -n` and the table write, records the result on p13 and reboots. The
normal boot formats slot B through the same pending marker.

It starts automatically, as the second half of the storage check (next
section). `split --auto` checks the preconditions and simply returns if the
answer is "not now". The preconditions are:

- no playback running (ALSA `state: RUNNING`);
- apk idle (`flock` on its lock);
- no kernel trial pending;
- the fit (see below), checked after clearing the Spotify and apk caches. Fewer
  blocks for resize2fs to move means a shorter window in which a power cut
  would matter.

A unit gets at most one automatic attempt per OTA: it is recorded, with the
apk database's generation, before the reboot.

### After every OTA: `nq-rootfs-ab ensure` (r4)

The state every unit should be in is slots A and B, with the root ext4 filling
its slot. `ensure` gets there from wherever the unit is, and it splits before
it grows. Grow-then-split would reach the same end, but it would force the
offline shrink on units that never needed it, and the shrink is the one step
where a power cut hurts. The order is:

1. the online check (`nexusq-resize-rootfs`, the same code the boot runs):
   split while mounted if the ext4 is still small, then grow;
2. if slot B is still missing, the offline split above.

`nexusq-storage-check.timer` runs it 10 min after boot or install, then every
30 min. A run that finds everything in order records the apk generation
(`stat -c %Y-%s /lib/apk/db/installed`, which every apk transaction changes),
and later runs return after that one stat until the next OTA. The boot-time
unit runs at every boot too, no longer once behind a flag.
`tests/test_ensure.sh` covers the gating: nothing runs while the generation is
unchanged, everything runs after an OTA, nothing runs while apk holds its lock,
and the offline half is taken only when slot B is still missing.

Found while writing this: **the v1.19.0 image shipped `nexusq-resize-rootfs`
not enabled**. It relied on a preset, and preset-all leaves local `/etc` units
alone. A fresh flash of v1.19.0 therefore never grew its root. Device r113
ships the static link, and `verify-rootfs.sh` section 8, now a mandatory gate
in `package-release.sh`, checks that the image will split and grow on its first
boot.

Failure paths, all tested in `userspace/nexusq-rootfs-ab/tests/test_init_split.sh`
on the same factory-GPT replica, including the boot that follows:

| failure | what happens |
|---|---|
| does not fit | nothing is changed |
| shrink fails | the table stays as it was; the resize flag is dropped, so the next boot grows the ext4 back over p13 and the unit is exactly as before (verified) |
| p14 already exists | refused at once |
| success | user data verified by checksum after the shrink |

### The fit rule, and the first attempt it got wrong

`ab_fits <min> <used> <slot A> <reserve>` passes when both hold:

- `resize2fs -P`'s minimum fits in slot A;
- the blocks in use plus 1 GiB fit in slot A.

The first version (r2) added the reserve to the **minimum** instead. On the
cottage Q the minimum was 1 611 267 blocks against 1 411 685 used, with
1 723 520 available in slot A. The first automatic attempt booted the
maintenance image, found no room, changed nothing and came back: safe, but
wrong. r3 measures the reserve from the blocks in use, and `split` makes the
same check before rebooting (`resize2fs -P` works on the mounted root, measured).

## The cottage Q, over the air

Installed r112/r3 from local apks. The timer fired at 12:37. The unit was
offline from 12:39:43 to 12:41:19.

```
[ab-split] ext4: 3447168 blocks of 4096 B, 773288 used, minimum 958465; slot A holds 1723520
[ab-split] shrinking the ext4 to 1723520 blocks -- do not cut the power
[ab-split] shrunk and checked
[ab-split] A/B table written
[ab-split] result: ok                                  (40.5 s after the maintenance boot)
nexusq-resize-rootfs: formatting slot B /dev/mmcblk0p14 (ext4, label pmOS_root_b)
```

The table is identical to Prague's, `sfdisk -V` is clean, and the boot log no
longer has the B8 line. `/` is 6.3 GB with 2.5 GB used. Everything else came
back unchanged: hostname, `device.json`, WiFi (same address), the four bind
mounts, the ssh host keys and MQTT (from the store, see below). No failed units.
Captures are in `nq-captures/ab-split/`. The first attempt's files are kept on
the unit as `ab-migrate.*.first`.

## Also in this change

- **`mqtt.json` in the persist store.** It is per-site (broker, credentials,
  prefix), not a fleet value, so a flash lost it. It is now stored as
  `site/mqtt.json`, with `/etc/nexusq/mqtt.json` a symlink to it, and
  nexusq-control writes through the link. On the cottage Q it was seeded into
  the store on the first boot after the upgrade.
- **The librespot audio cache is capped** at 5 GiB, lowered at each start so
  the slot keeps 1.5 GiB free. That comes to ~2 GiB per unit with A/B slots.

## Open

- The first-boot online split has not yet run on hardware (see above). The
  first unit flashed with a v1.20 image is the test: watch
  `journalctl -u nexusq-resize-rootfs` on its first boot.
- A power cut during `resize2fs` in the maintenance boot is the one failure
  nothing can undo; a reflash (persist store keeps the unit's state) recovers it.
