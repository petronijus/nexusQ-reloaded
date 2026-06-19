#!/bin/sh
# Build snd-aloop.ko (ALSA loopback) as an out-of-tree module against the prepared
# 6.12.12 kernel tree (configured from the device's .config). Prints the .ko path.
#
# Why: the device defconfig has `# CONFIG_SND_ALOOP is not set`, so the loopback
# card is not in the shipped kernel. nexusqd's Plan 3b audio tap needs a capturable
# audio stream; snd-aloop gives one with no speakers — play to hw:Loopback,0 and the
# daemon captures the same PCM from hw:Loopback,1.
#
# Load on device (auto-loads at boot via /etc/modules-load.d/snd-aloop.conf):
#   scp snd-aloop.ko root@DEVICE:/lib/modules/6.12.12/extra/ && ssh root@DEVICE \
#     'depmod -a && modprobe snd-aloop'
# Plain modprobe works: the module carries no __versions CRCs (KBUILD_MODPOST_WARN)
# so there is no version mismatch, and its vermagic matches the running kernel.
set -e

TREE="${LINUX_TREE:-/home/petronijus/nexusq-build/linux-6.12.12}"
TCBIN="${ARM_TCBIN:-/home/petronijus/nexusq-build/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-linux-gnueabihf/bin}"
MB="${MODBUILD:-/home/petronijus/nexusq-build/modbuild-aloop}"

# The tree must already be configured (device .config + CONFIG_SND_ALOOP=m) and
# `make ARCH=arm CROSS_COMPILE=$TCBIN/arm-none-linux-gnueabihf- modules_prepare` run.
mkdir -p "$MB"
cp "$TREE/sound/drivers/aloop.c" "$MB/"
printf 'snd-aloop-y := aloop.o\nobj-m := snd-aloop.o\n' > "$MB/Kbuild"

make -C "$TREE" ARCH=arm CROSS_COMPILE="$TCBIN/arm-none-linux-gnueabihf-" \
     KBUILD_MODPOST_WARN=1 M="$MB" modules

echo "MODULE: $MB/snd-aloop.ko"
