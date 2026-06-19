#!/bin/sh
# Build leds-steelhead-avr.ko as an out-of-tree module against the prepared
# WSL kernel tree (configured from the device's own .config). Prints the .ko
# path. Run inside WSL. The device kernel uses CONFIG_MODVERSIONS=y but also
# CONFIG_MODULE_FORCE_LOAD=y, so the resulting module is force-loaded on the
# device during development (insmod ... || modprobe --force).
set -e

TREE="${LINUX_TREE:-/home/petronijus/nexusq-build/linux-6.12.12}"
TCBIN="${ARM_TCBIN:-/home/petronijus/nexusq-build/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-linux-gnueabihf/bin}"
SRC="${REPO_DRIVERS:-/mnt/d/nexusQ-reloaded/kernel/drivers}"
MB="${MODBUILD:-/home/petronijus/nexusq-build/modbuild}"

mkdir -p "$MB"
cp "$SRC/steelhead_avr.h" "$SRC/leds-steelhead-avr.c" "$MB/"
printf 'obj-m := leds-steelhead-avr.o\n' > "$MB/Kbuild"

# modules_prepare does not produce Module.symvers; with MODVERSIONS=y modpost
# would error on undefined module_layout. KBUILD_MODPOST_WARN=1 demotes those
# to warnings so the .ko builds with empty CRCs (force-loaded on the device).
make -C "$TREE" ARCH=arm CROSS_COMPILE="$TCBIN/arm-none-linux-gnueabihf-" \
     KBUILD_MODPOST_WARN=1 M="$MB" modules

echo "MODULE: $MB/leds-steelhead-avr.ko"
