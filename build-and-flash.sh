#!/bin/bash
# build-and-flash.sh -- Build and flash postmarketOS for Google Nexus Q
#
# This script builds using Docker (required for pmbootstrap on macOS).
#
# Prerequisites:
#   - Docker Desktop installed and running
#   - Nexus Q in fastboot mode (cover mute LED during power-on -> solid red)
#   - USB cable connected to micro-USB service port
#
# WARNING: NEVER flash the bootloader partition. Only boot/system are safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="google-steelhead"

echo "=== Nexus Q postmarketOS Build & Flash ==="
echo ""

# Step 1: Build Docker image
echo "[1/4] Building Docker environment..."
docker build -t nexusq-builder "$SCRIPT_DIR" 2>&1 | tail -5

# Step 2: Run build inside Docker (--privileged needed for chroot/losetup)
echo "[2/4] Building postmarketOS image (kernel compilation takes ~70 min)..."
docker run --rm --privileged \
    -v "$SCRIPT_DIR:/src:ro" \
    -v nexusq-output:/tmp/output \
    -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap \
    --name nexusq-build \
    nexusq-builder /src/docker-build.sh 2>&1

# Step 3: Extract images
echo "[3/4] Extracting build artifacts..."
mkdir -p "$SCRIPT_DIR/output"
docker run --rm -v nexusq-output:/data -v "$SCRIPT_DIR/output:/out" \
    alpine:3.21 sh -c 'cp /data/*.img /out/ 2>/dev/null && echo "Images copied"'

echo ""
ls -lh "$SCRIPT_DIR/output/"

# Step 4: Flashing instructions
echo ""
echo "[4/4] Build complete!"
echo ""
echo "=== FLASHING INSTRUCTIONS ==="
echo ""
echo "1. Put Nexus Q in fastboot mode:"
echo "   Cover the mute LED during power-on -> solid red LED = fastboot"
echo ""
echo "2. Connect USB cable to the micro-USB service port"
echo ""
echo "3. TEMPORARILY boot (non-destructive, recommended first):"
echo "   fastboot boot output/boot.img"
echo ""
echo "4. PERMANENTLY flash rootfs to userdata partition (reversible via fastboot):"
echo "   fastboot flash userdata output/google-steelhead.img"
echo ""
echo "NOTE: boot.img ($(du -h output/boot.img 2>/dev/null | cut -f1)) exceeds the"
echo "      8 MB boot partition. Use 'fastboot boot' (RAM load) instead of"
echo "      'fastboot flash boot'. Rootfs is flashed to userdata (13 GB)"
echo "      because the system partition is only 1 GB."
echo ""
echo "Recovery: cover mute LED during power-on -> solid red = fastboot mode"
echo "WARNING: NEVER flash the bootloader partition!"
