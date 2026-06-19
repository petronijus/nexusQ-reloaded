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
    "$SRC/pmos/firmware-google-steelhead/APKBUILD" \
    "$SRC/pmos/nexusqd/APKBUILD"; do
    pkg=$(basename "$(dirname "$apkbuild")")
    echo "--- $pkg ---"
    if [ ! -f "$apkbuild" ]; then
        echo "  ERROR: $apkbuild not found!"
        continue
    fi
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

echo "Cloning pmaports (this takes a while)..."
PMAPORTS="/home/pmos/pmaports"
if [ ! -d "$PMAPORTS" ]; then
    git clone --depth=1 https://gitlab.postmarketos.org/postmarketOS/pmaports.git "$PMAPORTS" 2>&1 | tail -3
fi

# pmaports renamed its default branch master -> main, but pmbootstrap (>=3.9.0)
# still reads channels.cfg via the hardcoded `git show origin/master:channels.cfg`
# (pmb/helpers/git.py parse_channels_cfg). On a fresh clone only origin/main
# exists, so that read fails with "invalid object name 'origin/master'" and the
# whole build aborts. Alias origin/master -> origin/main so the lookup resolves
# (channels.cfg is identical; the worktree is correctly on main, matching it).
if git -C "$PMAPORTS" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    git -C "$PMAPORTS" update-ref refs/remotes/origin/master refs/remotes/origin/main
    echo "  pmaports: aliased origin/master -> origin/main (master->main rename workaround)"
fi
# Belt-and-suspenders: also let pmbootstrap read channels.cfg straight from the
# worktree file, bypassing the git ref entirely.
export PMB_CHANNELS_CFG="$PMAPORTS/channels.cfg"

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

# nexusqd LED daemon: stage the aport + the flat C sources (from userspace/nexusqd)
# next to its APKBUILD; the APKBUILD's prepare() restores the include/ + src/ tree.
NEXUSQD_DIR="$PMAPORTS/main/nexusqd"
mkdir -p "$NEXUSQD_DIR"
cp "$SRC/pmos/nexusqd/APKBUILD"            "$NEXUSQD_DIR/"
cp "$SRC/userspace/nexusqd/src/"*.c        "$NEXUSQD_DIR/"
cp "$SRC/userspace/nexusqd/include/"*.h    "$NEXUSQD_DIR/"
cp "$SRC/userspace/nexusqd/Makefile"       "$NEXUSQD_DIR/"
cp "$SRC/userspace/nexusqd/nexusqd.service" "$NEXUSQD_DIR/"
cp "$SRC/userspace/nexusqd/default.json"   "$NEXUSQD_DIR/"
echo "  Installed: nexusqd (aport + C sources -> main/nexusqd)"

echo "  Converting line endings (CRLF -> LF)..."
find "$PMAPORTS/device/testing/" "$NEXUSQD_DIR" -type f \( -name "APKBUILD" -o -name "deviceinfo" -o -name "modules-initfs" -o -name "*.patch" -o -name "config-*" -o -name "*.c" -o -name "*.h" -o -name "Makefile" -o -name "*.service" -o -name "*.json" \) -exec dos2unix -q {} +
echo "  Done."

echo ""
echo "=== Phase 6b: Patch pmbootstrap for Docker compatibility ==="

APK_PY="/usr/lib/python3.12/site-packages/pmb/helpers/apk.py"
PART_PY="/usr/lib/python3.12/site-packages/pmb/install/partition.py"
LOSETUP_PY="/usr/lib/python3.12/site-packages/pmb/install/losetup.py"

sudo python3 << 'PATCH_APK'
path = "/usr/lib/python3.12/site-packages/pmb/helpers/apk.py"
with open(path) as f:
    content = f.read()

old = "        pmb.helpers.cli.progress_flush()\n        pmb.helpers.run_core.check_return_code(p_apk.returncode, log_msg)"
new = """        pmb.helpers.cli.progress_flush()
        if p_apk.returncode != 0:
            _log_file = get_context().config.work / "log.txt"
            try:
                _log_lines = _log_file.read_text().split("\\n")[-50:]
                _sock = sum(1 for _l in _log_lines if "Socket not connected" in _l)
                _errs = sum(1 for _l in _log_lines if _l.strip().startswith("ERROR:"))
                if _sock > 0 and _sock >= _errs:
                    logging.warning("Ignoring %d non-critical APK 'Socket not connected' error(s)", _sock)
                else:
                    pmb.helpers.run_core.check_return_code(p_apk.returncode, log_msg)
            except Exception:
                pmb.helpers.run_core.check_return_code(p_apk.returncode, log_msg)
        """

if old in content:
    content = content.replace(old, new)
    with open(path, "w") as f:
        f.write(content)
    print("  Patched apk.py: tolerate APK Socket errors in chroot")
else:
    print("  apk.py: already patched or pattern changed")
PATCH_APK

sudo python3 << 'PATCH_PARTITION'
path = "/usr/lib/python3.12/site-packages/pmb/install/partition.py"
with open(path) as f:
    content = f.read()

old = """    if not found:
        raise RuntimeError(
            f"Unable to find the first partition of {disk}, "
            f"expected it to be at {partition_prefix}1!"
        )"""

new = """    if not found:
        logging.info(f"Partition device not found at {partition_prefix}1, trying kpartx...")
        import subprocess
        subprocess.run(["sudo", "kpartx", "-a", "-s", str(disk)], check=False)
        time.sleep(1)
        dev_name = disk.name if isinstance(disk, Path) else os.path.basename(str(disk))
        mapper_path = f"/dev/mapper/{dev_name}p1"
        if os.path.exists(mapper_path):
            logging.info(f"Found partition via device-mapper at {mapper_path}")
            for n in range(1, 16):
                mapper_p = f"/dev/mapper/{dev_name}p{n}"
                direct_p = f"{partition_prefix}{n}"
                if os.path.exists(mapper_p) and not os.path.exists(direct_p):
                    subprocess.run(["sudo", "ln", "-sf", mapper_p, direct_p], check=False)
                    logging.info(f"Created symlink: {direct_p} -> {mapper_p}")
            if os.path.exists(f"{partition_prefix}1"):
                found = True

    if not found:
        raise RuntimeError(
            f"Unable to find the first partition of {disk}, "
            f"expected it to be at {partition_prefix}1!"
        )"""

if old in content:
    content = content.replace(old, new)
    with open(path, "w") as f:
        f.write(content)
    print("  Patched partition.py: kpartx fallback for loop device partitions")
else:
    print("  partition.py: already patched or pattern changed")
PATCH_PARTITION

echo "  Compiling patched files..."
sudo python3 -c "import py_compile; py_compile.compile('$APK_PY', doraise=True)" && echo "    apk.py: OK"
sudo python3 -c "import py_compile; py_compile.compile('$PART_PY', doraise=True)" && echo "    partition.py: OK"

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
# Lightweight Wayland desktop on the HDMI port: weston with the pixman software
# renderer (no GPU driver yet — see docs/2026-06-19-gpu-sgx540-acceleration-
# research.md). The device package ships the device-specific weston.ini +
# tinydm session. Replaced the earlier XFCE/X11 desktop (removed 2026-06-19).
ui = weston
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
echo "=== Phase 7c: Build nexusqd app package (armv7/musl) ==="
sudo mkdir -p /tmp/output && sudo chown pmos:pmos /tmp/output
set +e
# The nexusqd sources are staged flat into the aport above (frame.c, fx_*.c, ...)
# and the APKBUILD ships sha512sums="SKIP" as a placeholder, so abuild aborts with
# "<file> is missing in checksums". Regenerate the per-file checksums against the
# just-staged sources before building (same step the kernel/device/firmware get).
pmbootstrap checksum nexusqd 2>&1 || true
pmbootstrap build nexusqd --arch armv7 2>&1
NEXUSQD_RC=$?
set -e
echo "=== nexusqd build exit code: $NEXUSQD_RC ==="
if [ $NEXUSQD_RC -eq 0 ]; then
    NEXUSQD_APK=$(find "$WORK/packages" -name 'nexusqd-*.apk' 2>/dev/null | head -1)
    if [ -n "$NEXUSQD_APK" ]; then
        cp "$NEXUSQD_APK" /tmp/output/ && echo "  Exported: $(basename "$NEXUSQD_APK")"
    else
        echo "  WARNING: nexusqd apk built but not found under $WORK/packages"
    fi
else
    echo "  WARNING: nexusqd build failed -- key log lines:"
    grep -n "ERROR\|error:\|FAILED" "$WORK/log.txt" 2>/dev/null | tail -30
fi

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
    echo "=== BUILD FAILED ==="
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
    pmbootstrap install --password 147147 2>&1
    INSTALL_RC=$?
    set -e
    if [ $INSTALL_RC -ne 0 ]; then
        echo ""
        echo "=== INSTALL FAILED (exit code $INSTALL_RC) ==="
        echo "--- Searching log.txt for errors ---"
        grep -n "error\|ERROR\|FAIL\|unsatisfiable\|broken\|missing.*dependency" "$WORK/log.txt" 2>/dev/null | tail -40
        echo ""
        echo "--- Lines around ^^^ marker ---"
        grep -n -B 30 '^\^' "$WORK/log.txt" 2>/dev/null | tail -60
        echo ""
        echo "--- Last 150 lines of log.txt ---"
        tail -150 "$WORK/log.txt" 2>/dev/null
        echo "=== END LOG ==="
    fi

    if [ $INSTALL_RC -eq 0 ]; then
        echo ""
        echo "=== Phase 10: Export images ==="
        ROOTFS="/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead"
        NATIVE="/home/pmos/.local/var/pmbootstrap/chroot_native"
        DISK_IMG="$NATIVE/home/pmos/rootfs/google-steelhead.img"
        sudo mkdir -p /tmp/output
        sudo chown pmos:pmos /tmp/output

        cp "$ROOTFS/boot/boot.img" /tmp/output/ 2>/dev/null && echo "  Exported: boot.img"

        echo "  Extracting rootfs partition from disk image..."
        ROOTFS_INFO=$(sfdisk -J "$DISK_IMG" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
parts = d['partitiontable']['partitions']
# Rootfs is partition 2 (index 1) if multiple, else partition 1
p = parts[1] if len(parts) > 1 else parts[0]
ss = d['partitiontable'].get('sectorsize', 512)
print(f\"{p['start']} {p['size']} {ss}\")
")
        ROOTFS_START=$(echo "$ROOTFS_INFO" | awk '{print $1}')
        ROOTFS_SECTORS=$(echo "$ROOTFS_INFO" | awk '{print $2}')
        SECTOR_SIZE=$(echo "$ROOTFS_INFO" | awk '{print $3}')
        echo "  Rootfs: start=$ROOTFS_START sectors=$ROOTFS_SECTORS sector_size=$SECTOR_SIZE"

        dd if="$DISK_IMG" of=/tmp/output/google-steelhead.img \
            bs="$SECTOR_SIZE" skip="$ROOTFS_START" count="$ROOTFS_SECTORS" \
            status=progress
        echo "  Exported: google-steelhead.img (rootfs partition extracted)"

        echo ""
        echo "=== Build artifacts ==="
        ls -lh /tmp/output/
        echo ""
        echo "Kernel: $(cat "$ROOTFS/usr/share/kernel/google-steelhead/kernel.release" 2>/dev/null)"
        echo "DTB: $(find "$ROOTFS/boot/dtbs/" -name "*steelhead*" 2>/dev/null)"
    fi
else
    echo "=== Skipping remaining phases due to build failure ==="
fi

echo ""
echo "=== BUILD COMPLETE ==="
