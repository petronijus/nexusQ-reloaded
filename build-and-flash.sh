#!/bin/bash
# build-and-flash.sh -- Build and flash postmarketOS for Google Nexus Q
#
# Prerequisites:
#   - pmbootstrap installed (pip3 install pmbootstrap)
#   - Nexus Q in fastboot mode (cover mute LED during power-on -> solid red)
#   - USB cable connected to micro-USB service port
#
# WARNING: NEVER flash the bootloader partition. Only boot/system are safe.

set -euo pipefail

PMAPORTS=""
DEVICE="google-steelhead"
UI="sway"

echo "=== Nexus Q postmarketOS Build & Flash ==="
echo ""

# Step 1: Check pmbootstrap
if ! command -v pmbootstrap &>/dev/null; then
	echo "ERROR: pmbootstrap not found. Install with: pip3 install pmbootstrap"
	exit 1
fi

# Step 2: Initialize pmbootstrap (if not already done)
if ! pmbootstrap config device 2>/dev/null | grep -q "$DEVICE"; then
	echo "[1/6] Initializing pmbootstrap..."
	echo "  When prompted, select:"
	echo "    Vendor: google"
	echo "    Device: steelhead"
	echo "    UI: $UI"
	echo ""
	pmbootstrap init
fi

# Step 3: Copy our device packages into pmaports
echo "[2/6] Installing device packages into pmaports..."
PMAPORTS=$(pmbootstrap config aports)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for pkg in device-google-steelhead linux-google-steelhead firmware-google-steelhead; do
	target_dir="$PMAPORTS/device/testing/$pkg"
	mkdir -p "$target_dir"
	cp -r "$SCRIPT_DIR/pmos/$pkg/"* "$target_dir/"
done

# Copy kernel config with the expected name
cp "$SCRIPT_DIR/kernel/configs/steelhead_defconfig" \
	"$PMAPORTS/device/testing/linux-google-steelhead/config-google-steelhead.armv7"

# Copy kernel patches
for patch in "$SCRIPT_DIR/kernel/patches/"*.patch; do
	cp "$patch" "$PMAPORTS/device/testing/linux-google-steelhead/"
done

# Step 4: Build
echo "[3/6] Building kernel..."
pmbootstrap build linux-google-steelhead

echo "[4/6] Building device package..."
pmbootstrap build device-google-steelhead

echo "[5/6] Creating installation image..."
pmbootstrap install

# Step 5: Export and flash
echo "[6/6] Exporting boot image..."
pmbootstrap export

echo ""
echo "=== Build complete! ==="
echo ""
echo "To TEMPORARILY boot (non-destructive, recommended first):"
echo "  fastboot boot /tmp/postmarketOS-export/boot.img"
echo ""
echo "To PERMANENTLY flash (reversible via fastboot):"
echo "  pmbootstrap flasher flash_kernel"
echo "  pmbootstrap flasher flash_rootfs"
echo ""
echo "Recovery: cover mute LED during power-on -> solid red = fastboot mode"
echo "NEVER flash the bootloader partition!"
