#!/bin/bash
set -euo pipefail

DEVICE="google-steelhead"
SRC="/src"

echo "=== Phase 1: Validate DTS syntax ==="
if command -v dtc &>/dev/null; then
    cpp -nostdinc -undef -x assembler-with-cpp \
        -D__DTS__ \
        "$SRC/kernel/dts/omap4-steelhead.dts" 2>/dev/null | \
        dtc -I dts -O dtb -o /dev/null - 2>&1 && echo "DTS: basic syntax OK" || \
        echo "DTS: syntax errors found (expected -- needs kernel includes)"
else
    echo "DTS: dtc not available, skipping"
fi

echo ""
echo "=== Phase 2: Validate APKBUILD structure ==="
for apkbuild in \
    "$SRC/pmos/device-google-steelhead/APKBUILD" \
    "$SRC/pmos/linux-google-steelhead/APKBUILD" \
    "$SRC/pmos/firmware-google-steelhead/APKBUILD"; do
    pkg=$(basename "$(dirname "$apkbuild")")
    echo "--- $pkg ---"
    if [ ! -f "$apkbuild" ]; then
        echo "  ERROR: $apkbuild not found!"
        continue
    fi
    # Source the APKBUILD safely
    (
        source "$apkbuild" 2>/dev/null
        echo "  pkgname=$pkgname"
        echo "  pkgver=$pkgver"
        echo "  arch=$arch"
        echo "  depends=${depends:-none}"
        echo "  source=${source:-none}"
    ) || echo "  ERROR: failed to source APKBUILD"
done

echo ""
echo "=== Phase 3: Validate defconfig ==="
config="$SRC/kernel/configs/steelhead_defconfig"
if [ -f "$config" ]; then
    total=$(grep -c '^CONFIG_' "$config" || true)
    echo "  Total CONFIG_ entries: $total"
    
    # Critical checks
    for key in CONFIG_ARCH_OMAP4 CONFIG_SMP CONFIG_BRCMFMAC CONFIG_SND_SOC_TAS571X \
        CONFIG_DRM_OMAP CONFIG_SERIAL_8250_OMAP CONFIG_MMC_OMAP_HS CONFIG_USB_EHCI_HCD \
        CONFIG_NFC_PN544_I2C CONFIG_LEDS_LP5523 CONFIG_DEVTMPFS CONFIG_BLK_DEV_INITRD; do
        if grep -q "^${key}=" "$config"; then
            echo "  OK: $key"
        else
            echo "  MISSING: $key"
        fi
    done
else
    echo "  ERROR: defconfig not found"
fi

echo ""
echo "=== Phase 4: Validate kernel patches ==="
for patch in "$SRC/kernel/patches/"*.patch; do
    name=$(basename "$patch")
    echo "--- $name ---"
    # Basic format checks
    if head -1 "$patch" | grep -q '^From '; then
        echo "  Format: valid git format-patch header"
    else
        echo "  WARNING: missing git format-patch header"
    fi
    if grep -q '^diff --git' "$patch"; then
        echo "  Diff: contains git diff"
    else
        echo "  WARNING: no git diff found"
    fi
    additions=$(grep -c '^+' "$patch" 2>/dev/null || echo 0)
    deletions=$(grep -c '^-' "$patch" 2>/dev/null || echo 0)
    echo "  Lines: +$additions / -$deletions"
done

echo ""
echo "=== Phase 5: Initialize pmbootstrap ==="
export XDG_CONFIG_HOME=/home/pmos/.config
export XDG_DATA_HOME=/home/pmos/.local/share
export XDG_CACHE_HOME=/home/pmos/.cache

sudo mkdir -p /home/pmos/.local/var/pmbootstrap
sudo chown -R pmos:pmos /home/pmos

echo "pmbootstrap version: $(pmbootstrap --version)"

# Clone pmaports
echo "Cloning pmaports (this takes a while)..."
PMAPORTS="/home/pmos/pmaports"
if [ ! -d "$PMAPORTS" ]; then
    git clone --depth=1 https://gitlab.postmarketos.org/postmarketOS/pmaports.git "$PMAPORTS" 2>&1 | tail -3
fi

echo ""
echo "=== Phase 6: Install device packages into pmaports ==="
for pkg in device-google-steelhead linux-google-steelhead firmware-google-steelhead; do
    target_dir="$PMAPORTS/device/testing/$pkg"
    mkdir -p "$target_dir"
    cp -r "$SRC/pmos/$pkg/"* "$target_dir/"
    echo "  Installed: $pkg"
done

cp "$SRC/kernel/configs/steelhead_defconfig" \
    "$PMAPORTS/device/testing/linux-google-steelhead/config-google-steelhead.armv7"
echo "  Installed: defconfig -> config-google-steelhead.armv7"

for patch in "$SRC/kernel/patches/"*.patch; do
    cp "$patch" "$PMAPORTS/device/testing/linux-google-steelhead/"
    echo "  Installed: $(basename "$patch")"
done

echo ""
echo "=== Phase 7: Initialize pmbootstrap config ==="
WORK="/home/pmos/.local/var/pmbootstrap"
mkdir -p "$XDG_CONFIG_HOME" "$WORK"
echo "8" > "$WORK/version"

cat > "$XDG_CONFIG_HOME/pmbootstrap_v3.cfg" << CFGEOF
[pmbootstrap]
aports = $PMAPORTS
work = $WORK
device = google-steelhead
ui = console
build_pkgs_on_install = True
hostname = steelhead
extra_packages = none
is_default_channel = True
boot_size = 256
build_default_device_arch = False
ccache_size = 5G
extra_space = 0
jobs = $(nproc)
kernel = stable
locale = en_US.UTF-8
qemu_redir_stdio = False
ssh_keys = False
sudo_timer = False
systemd = default
timezone = GMT
ui_extras = False
user = user

[providers]

[mirrors]
alpine = http://dl-cdn.alpinelinux.org/alpine/
alpine_custom = none
pmaports = http://mirror.postmarketos.org/postmarketos/
pmaports_custom = none
systemd = http://mirror.postmarketos.org/postmarketos/extra-repos/systemd/
systemd_custom = none
CFGEOF

echo "  Config written. Testing..."
pmbootstrap config device 2>&1 || {
    echo "  Config read failed, showing config file:"
    cat "$XDG_CONFIG_HOME/pmbootstrap_v3.cfg"
    echo "  Attempting pmbootstrap status..."
    pmbootstrap status 2>&1 || true
}

echo ""
echo "=== Phase 7b: Generate checksums ==="
echo "Generating checksums for kernel package..."
pmbootstrap checksum linux-google-steelhead 2>&1 || {
    echo "WARNING: checksum generation failed, will try building anyway"
}
echo "Generating checksums for device package..."
pmbootstrap checksum device-google-steelhead 2>&1 || true
echo "Generating checksums for firmware package..."
pmbootstrap checksum firmware-google-steelhead 2>&1 || true

echo ""
echo "=== Phase 8: Build all packages ==="
echo "Running: pmbootstrap --no-cross build device-google-steelhead (triggers all deps)"
set +e
pmbootstrap --no-cross build device-google-steelhead 2>&1
BUILD_RC=$?
set -e
echo ""
echo "=== Build exit code: $BUILD_RC ==="
if [ $BUILD_RC -ne 0 ]; then
    echo "=== KERNEL BUILD FAILED ==="
    echo "--- Errors and key lines from log.txt ---"
    grep -n "ERROR\|error:\|FAILED\|failed.*patch\|Hunk\|^^^\|>>> \|applying patch\|ARCH_MULTI\|olddefconfig" "$WORK/log.txt" 2>/dev/null | tail -60
    echo ""
    echo "--- Last 150 lines of log.txt ---"
    tail -150 "$WORK/log.txt" 2>/dev/null
    echo ""
    echo "=== END LOG ==="
fi

if [ $BUILD_RC -eq 0 ]; then
    echo ""
    echo "=== Phase 9: Install image ==="
    set +e
    pmbootstrap install 2>&1
    INSTALL_RC=$?
    set -e
    if [ $INSTALL_RC -ne 0 ]; then
        echo ""
        echo "=== INSTALL FAILED ==="
        echo "--- Last 100 lines of log.txt ---"
        tail -100 "$WORK/log.txt" 2>/dev/null
        echo "=== END LOG ==="
    fi
else
    echo "=== Skipping remaining phases due to build failure ==="
fi

echo ""
echo "=== BUILD COMPLETE ==="
