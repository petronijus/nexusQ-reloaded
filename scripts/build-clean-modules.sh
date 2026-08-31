#!/bin/sh
# Proper out-of-the-box build: fresh linux-$KVER tree + the early repo patches
# + steelhead_defconfig, build vmlinux + modules to get a real
# Module.symvers, yielding clean-CRC modules that load WITHOUT force on the
# device's matching #3 kernel. WSL only, no Docker.
set -e

KVER="${KVER:-6.18.48}"
BASE="/home/petronijus/nexusq-build"
TCBIN="$BASE/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-linux-gnueabihf/bin"
REPO="/mnt/d/nexusQ-reloaded"
BD="$BASE/clean"

export ARCH=arm
export CROSS_COMPILE="$TCBIN/arm-none-linux-gnueabihf-"

echo "=== fresh tree ==="
rm -rf "$BD"; mkdir -p "$BD"; cd "$BD"
tar xf "$BASE/linux-$KVER.tar.xz"
cd "linux-$KVER"

echo "=== apply the early patches ==="
# 0004 is deliberately absent: upstream fixed it at the 6.18 bump.
for p in 0001 0002 0003 0005; do
    f=$(ls "$REPO"/kernel/patches/${p}-*.patch)
    echo "  applying $(basename "$f")"
    patch -p1 < "$f"
done

echo "=== config ==="
cp "$REPO/kernel/configs/steelhead_defconfig" .config
# Module-only build: we don't need the embedded initramfs (data, not symbols).
./scripts/config --set-str INITRAMFS_SOURCE ""
make olddefconfig >/dev/null

echo "=== build vmlinux + modules (this is the long part) ==="
make -j"$(nproc)" vmlinux modules

echo "=== artifacts ==="
ls -la Module.symvers \
    drivers/leds/leds-steelhead-avr.ko \
    drivers/leds/led-class-multicolor.ko \
    drivers/input/evdev.ko 2>&1
echo "--- vermagic ---"
for m in drivers/leds/leds-steelhead-avr.ko drivers/leds/led-class-multicolor.ko drivers/input/evdev.ko; do
    echo "$m: $(modinfo "$m" 2>/dev/null | awk '/^vermagic/{ $1=""; print }')"
done
echo CLEAN_BUILD_DONE
