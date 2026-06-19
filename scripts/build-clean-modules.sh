#!/bin/sh
# Proper out-of-the-box build: fresh linux-6.12.12 tree + all repo patches
# (0001-0005) + steelhead_defconfig, build vmlinux + modules to get a real
# Module.symvers, yielding clean-CRC modules that load WITHOUT force on the
# device's matching #3 kernel. WSL only, no Docker.
set -e

BASE="/home/petronijus/nexusq-build"
TCBIN="$BASE/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-linux-gnueabihf/bin"
REPO="/mnt/d/nexusQ-reloaded"
BD="$BASE/clean"

export ARCH=arm
export CROSS_COMPILE="$TCBIN/arm-none-linux-gnueabihf-"

echo "=== fresh tree ==="
rm -rf "$BD"; mkdir -p "$BD"; cd "$BD"
tar xf "$BASE/linux-6.12.12.tar.xz"
cd linux-6.12.12

echo "=== apply patches 0001-0005 ==="
for p in 0001 0002 0003 0004 0005; do
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
