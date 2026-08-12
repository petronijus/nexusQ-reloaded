#!/usr/bin/env bash
# build-stock-adb-boot.sh — (re)build output/stock-adb-boot.img, the stock-kernel
# RAM-boot diagnostic image used for reverse engineering / stock-parity checks.
#
# WHAT IT IS: the Google factory Nexus Q boot.img (stock 3.0.8 kernel + stock
# ramdisk) with the ramdisk patched for an insecure ROOT adb shell, so you can
# `fastboot boot output/stock-adb-boot.img` (RAM-only, non-destructive — p9 keeps
# pmOS) and get `adb shell` as root on the KNOWN-GOOD stock kernel to read live
# registers / dmesg. See docs/2026-06-24-ethernet-stock-proven-its-our-sw.md and
# docs/2026-08-12-rebuild-stock-adb-boot.md.
#
# WHY A SCRIPT: the prebuilt output/stock-adb-boot.img is gitignored and was once
# deleted by an over-broad build-prune `rm *.img` (2026-08-12). It is not
# irreplaceable — this script regenerates it from local, preserved inputs:
#   - reverse-eng/factory/tungsten-ian67k/boot.img   (the stock kernel + ramdisk)
#   - reverse-eng/stock-adb-parts/{busybox-armhf,ld-musl-armhf.so.1}  (the shell)
#   - make-bootimg.py                                 (the repacker)
# All three are kept locally (the factory image is also Google's public factory
# image for codename "tungsten"/steelhead), so this never depends on the device.
#
# The mods (faithful to the original recipe):
#   default.prop: ro.secure=0, ro.adb.secure=0, ro.debuggable=1,
#                 persist.sys.usb.config=adb  (the property chain brings adbd up)
#   init.rc:      the stock yaffs2 mtd@ mounts in `on fs` are disabled (those
#                 partitions hold pmOS now, not stock — don't block/panic on them)
#   ramdisk:      /system/bin/sh = busybox (+ a useful applet set) with its musl
#                 loader at /lib/ld-musl-armhf.so.1, because the stock ramdisk has
#                 no shell and /system is never mounted. adbd + init are static.
#
# VERIFY (needs hardware): enter fastboot (cover the mute sensor at power-on →
# solid red), then `fastboot boot output/stock-adb-boot.img` → `adb shell`. RAM
# only; `adb reboot` returns to pmOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FACTORY="reverse-eng/factory/tungsten-ian67k/boot.img"
PARTS="reverse-eng/stock-adb-parts"
OUT="output/stock-adb-boot.img"
CMDLINE='console=ttyFIQ0 androidboot.console=ttyFIQ0 mem=1G vmalloc=768M omap_wdt.timer_margin=30 no_console_suspend androidboot.bootloader=steelheadB4H0J androidboot.wifi_macaddr=f8:8f:ca:20:48:e1 smsc95xx.mac_addr=f8:8f:ca:20:3e:97 board_steelhead_bluetooth.btaddr=f8:8f:ca:20:49:e5 androidboot.serialno=AW1S12241020 board_steelhead.steelhead_hw_rev=10 omap_temp_sensor.bgap_threshold_t_hot=83000 omap_temp_sensor.bgap_threshold_t_cold=76000'

for f in "$FACTORY" "$PARTS/busybox-armhf" "$PARTS/ld-musl-armhf.so.1" make-bootimg.py; do
	[ -f "$f" ] || { echo "MISSING input: $f" >&2; exit 1; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
RD="$WORK/rd"; mkdir -p "$RD"

echo "=== extract stock kernel + ramdisk from the factory boot.img ==="
python3 - "$FACTORY" "$WORK" <<'PY'
import struct, sys, os
img, work = sys.argv[1], sys.argv[2]
b = open(img, "rb").read()
assert b[:8] == b"ANDROID!", "not an Android boot image"
ks, ka, rs, ra, ss, sa, ta, pg = struct.unpack("<8I", b[8:40])
np = lambda n: (n + pg - 1) // pg
koff = pg
roff = pg + np(ks) * pg
open(os.path.join(work, "stock-kernel"), "wb").write(b[koff:koff+ks])
open(os.path.join(work, "stock-ramdisk.gz"), "wb").write(b[roff:roff+rs])
print(f"kernel {ks} B, ramdisk {rs} B, page {pg}")
PY

echo "=== unpack the stock ramdisk ==="
( cd "$RD" && zcat "$WORK/stock-ramdisk.gz" | cpio -idmu --quiet )

echo "=== patch: default.prop (insecure root adb) ==="
cat > "$RD/default.prop" <<'EOF'
#
# ADDITIONAL_DEFAULT_PROPERTIES
#
ro.secure=0
ro.allow.mock.location=0
ro.debuggable=1
ro.adb.secure=0
persist.sys.usb.config=adb
EOF

echo "=== patch: disable stock yaffs2 mtd mounts in on fs ==="
sed -i -E 's|^([[:space:]]*)mount yaffs2 mtd@|\1#mount yaffs2 mtd@|' "$RD/init.rc"

echo "=== add busybox shell + musl loader ==="
mkdir -p "$RD/lib" "$RD/system/bin"
install -m0755 "$PARTS/ld-musl-armhf.so.1" "$RD/lib/ld-musl-armhf.so.1"
install -m0755 "$PARTS/busybox-armhf" "$RD/system/bin/busybox"
( cd "$RD/system/bin"
  for a in sh ash ls cat mount umount dmesg grep sed awk cut head tail dd cp mv rm \
           ln mkdir chmod chown echo sleep ps od hexdump insmod lsmod rmmod free df \
           mountpoint printf test which find sync reboot; do
	ln -sf busybox "$a"
  done )

echo "=== repack ramdisk (newc, root-owned) + build the boot image ==="
( cd "$RD" && find . | cpio -o -H newc --owner=0:0 2>/dev/null | gzip -9 > "$WORK/adb-ramdisk.gz" )
python3 make-bootimg.py "$WORK/stock-kernel" "$OUT" "$WORK/adb-ramdisk.gz" "$CMDLINE"
sha256sum "$OUT"
echo "=== done: $OUT (fastboot boot it; RAM-only, non-destructive) ==="
