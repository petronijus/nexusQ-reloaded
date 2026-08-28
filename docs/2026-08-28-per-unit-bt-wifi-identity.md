# 2026-08-28 — A second Nexus Q, and the identity the DTS hardcodes for all of them

A second unit (serial `AW1S12251417`) was flashed at the cottage. It came up
fine — and with **the same Bluetooth address and the same WiFi MAC as the first
one**, because both are hardcoded, per-device values living in a DTS that every
build shares:

```
kernel/dts/omap4-steelhead.dts:664   local-mac-address = [f8 8f ca 20 48 e1]   # WiFi
kernel/dts/omap4-steelhead.dts:712   local-bd-address  = [e5 49 20 ca 8f f8]   # BT f8:8f:ca:20:49:e5
```

The comments beside them already say "Per-device factory WiFi MAC" and "Real
per-device BT MAC". They are right; the storage is the problem.

## Why the hardware cannot just report its own address

It does not have one. `btbcm` without `local-bd-address` leaves the BCM4330B1
`.hcd` placeholder `43:30:A0:00:00:00` — identical on every unit AND malformed
(MSB `0x43` sets the multicast bit, an invalid unicast address). `brcmfmac` has
no on-device source either: nvram is a placeholder and OTP holds a generic
Murata MAC.

Stock got the real values from the **bootloader**, on the kernel cmdline:

```
androidboot.wifi_macaddr=…  smsc95xx.mac_addr=…  board_steelhead_bluetooth.btaddr=…
```

We never see them, because our defconfig sets **`CONFIG_CMDLINE_FORCE=y`** — the
kernel discards the bootloader's cmdline entirely. That is deliberate (the
ramdisk-less boot depends on the built-in `root=/dev/mmcblk0p13`), but it means
the one channel carrying per-unit identity is closed.

⚠️ **Ethernet is NOT affected.** The `ethernet@1` node (`:768`) has no
`mac-address` property, so smsc95xx uses the LAN9500A's own EEPROM. Only two
identities collide, not three.

## What was done — patch the DTB in boot.img, no kernel rebuild

The appended DTB is editable in place. Full recipe:

1. **Find it.** Split the Android boot image (page size 2048; kernel at page 1),
   then scan the kernel for FDT magic `d00dfeed`. ⚠️ **The first hit is a decoy** —
   `0xd00dfeed` occurs by chance inside the compressed zImage, with a nonsense
   `totalsize` (204 MB). Validate: the real one has a plausible `totalsize` and
   **ends exactly at the end of the kernel**. Here: offset `5451400`, total
   `95760`, `5451400 + 95760 = 5547160` = the kernel size.
2. **Derive per-unit addresses** from the unit's own serial, so they are
   deterministic and reproducible:
   `f8:8f:ca` (the same Google OUI the factory used) + first 3 bytes of
   `sha256("nexusq/<bt|wifi>/<serial>")`. For `AW1S12251417`:
   BT `f8:8f:ca:73:ac:9c`, WiFi `f8:8f:ca:05:1f:11`.
   These are SYNTHESIZED, not the factory values — see "recovering the real
   ones" below.
3. **Byte-patch, do not re-serialize.** Both properties are 6 fixed bytes and
   each byte string occurs **exactly once** in the blob (check this first). A
   byte patch keeps the DTB length and layout identical; `fdtput` would rewrite
   the whole blob. Note `local-bd-address` is stored **reversed** in the DT
   (`f8:8f:ca:20:49:e5` → `[e5 49 20 ca 8f f8]`); `local-mac-address` is not.
4. **Verify** by decompiling the patched blob with `dtc -I dtb -O dts`.
5. **Repack** `zImage + patched DTB` with `make-bootimg.py`, passing the ORIGINAL
   ramdisk (this boot.img carries the ~958 KB A/B initramfs) and the original
   cmdline (read it from the header at offset 64, 512 bytes).
6. **Diff against the original before flashing.** Expect exactly **26 bytes**:
   3 + 3 payload bytes, plus the 20-byte SHA1 id field the packer recomputes.
   Anything else means something went wrong.
7. `fastboot flash boot` — and nothing else. Rootfs is untouched.

## 🔴 The trap on the other side: the NM profile overrode it right back

After the flash, BT read the new address — and **WiFi still read the OLD one**.
The baked WiFi profile carried `cloned-mac-address=F8:8F:CA:20:48:E1`, a line
kept "as harmless belt-and-braces" since the DTS pin made it redundant. It is
not harmless: it overrode the correct per-unit MAC with the first unit's, and
nothing logged a thing. Two boxes, one MAC, no error anywhere.

Fixed to `cloned-mac-address=permanent` — which `eth-lan` and `eth-direct` have
always used — on the device and in `scripts/gen-wifi-profile.sh`.

**The lesson: a redundant override is not harmless the moment the value it
duplicates becomes per-device.**

## Recovering the REAL factory addresses (not done)

The synthesized addresses solve the collision, which was the actual problem. If
the true factory identity is ever wanted, it is readable only from the
bootloader's cmdline under **stock**, and stock's adb is off. The tool for it is
`scripts/build-stock-adb-boot.sh` → `fastboot boot output/stock-adb-boot.img`
(RAM-only, non-destructive) → `adb shell cat /proc/cmdline`. It needs the
`reverse-eng/` inputs, which live on the desktop only.
⚠️ That image bakes the FIRST unit's cmdline, so check `androidboot.serialno` in
the output: if it reads the unit you booted, U-Boot injected the real values; if
it reads `AW1S12241020`, you are looking at the baked cmdline and learned
nothing.

## The proper fix, for whenever a third unit shows up

Switch the defconfig from `CONFIG_CMDLINE_FORCE=y` to `CONFIG_CMDLINE_EXTEND`
and program both addresses from the bootloader-supplied cmdline, so **every unit
identifies itself** and none of the above is needed again. ⚠️ Not a drive-by:
`CMDLINE_EXTEND` appends the bootloader's arguments after the built-in ones, and
stock U-Boot passes its own `root=`/init arguments — which could break the
ramdisk-less boot. Test on hardware with a rescue path ready.

## Verified on the device

```
Controller F8:8F:CA:73:AC:9C sumperak [default]
wlan0      f8:8f:ca:05:1f:11
Sumperak-Internety:wlan0:activated
```
