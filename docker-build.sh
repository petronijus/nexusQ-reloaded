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
    "$SRC/pmos/nexusq-glibc-rt/APKBUILD" \
    "$SRC/pmos/linux-google-steelhead/APKBUILD" \
    "$SRC/pmos/firmware-google-steelhead/APKBUILD" \
    "$SRC/pmos/nexusqd/APKBUILD" \
    "$SRC/pmos/nexusq-control/APKBUILD" \
    "$SRC/pmos/nexusq-setupd/APKBUILD" \
    "$SRC/pmos/nexusq-btagent/APKBUILD" \
    "$SRC/pmos/nexusq-mqtt/APKBUILD"; do
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
PMAPORTS_URL="https://gitlab.postmarketos.org/postmarketOS/pmaports.git"
# PINNED, deliberately — see the Dockerfile's PMBOOTSTRAP_REF for the other half.
# This used to be an unpinned `--depth=1` clone of HEAD, which made every build
# depend on whatever upstream had merged that morning. On 2026-08-16 upstream
# bumped pmaports' `required_pmbootstrap_version` to 3.11.0 and EVERY build --
# OTA and full -- died in Phase 7b, mid-run, after all the staging work.
# Set PMAPORTS_REF=main (or any ref) to deliberately track upstream again; bump
# this pin together with PMBOOTSTRAP_REF, and re-verify that the four pmbootstrap
# monkey patches in Phase 6b still apply (they only WARN when they miss, and
# backend.py is load-bearing: without it abuild hangs in fakeroot under qemu).
PMAPORTS_REF="${PMAPORTS_REF:-11e89dfbb2f8ecc9bcc074ca4d62a609ffa50bf6}"
if [ ! -d "$PMAPORTS" ]; then
    # A --depth=1 clone cannot check out an arbitrary commit, so fetch exactly
    # the pinned object. If the server refuses a by-SHA fetch (uploadpack
    # .allowReachableSHA1InWant disabled), fall back to a blobless full-history
    # clone, which can always resolve it.
    echo "  pmaports pin: $PMAPORTS_REF"
    if git init -q "$PMAPORTS" \
       && git -C "$PMAPORTS" remote add origin "$PMAPORTS_URL" \
       && git -C "$PMAPORTS" fetch -q --depth=1 origin "$PMAPORTS_REF" 2>/dev/null \
       && git -C "$PMAPORTS" checkout -q FETCH_HEAD; then
        echo "  pmaports: fetched pinned commit directly (shallow)"
    else
        echo "  pmaports: by-SHA fetch unavailable, falling back to a blobless clone"
        rm -rf "$PMAPORTS"
        git clone -q --filter=blob:none "$PMAPORTS_URL" "$PMAPORTS" 2>&1 | tail -3
        git -C "$PMAPORTS" checkout -q "$PMAPORTS_REF"
    fi
    echo "  pmaports at $(git -C "$PMAPORTS" rev-parse --short HEAD)"
fi

# Fail EARLY and legibly on a toolchain mismatch. Without this the run dies in
# Phase 7b -- after cloning, staging every aport and fixing ownership -- with
# pmbootstrap's own "Please update your pmbootstrap version" and no hint that
# the fix is a one-line pin bump. Comparison is `sort -V`, not string equality:
# any pmbootstrap at or above what pmaports demands is fine.
_pmb_have="$(pmbootstrap --version 2>/dev/null | tr -d '[:space:]')"
# The key is `pmbootstrap_min_version` (pmaports.cfg, [pmaports] section).
# `required_pmbootstrap_version` is accepted too in case upstream renames it
# back -- and if NEITHER is found the check says so out loud, because a guard
# that skips silently is worse than no guard: the first version of this read the
# wrong key, matched nothing, and sailed straight past a real mismatch.
_pmb_need="$(sed -n -e 's/^pmbootstrap_min_version[[:space:]]*=[[:space:]]*//p' \
                    -e 's/^required_pmbootstrap_version[[:space:]]*=[[:space:]]*//p' \
             "$PMAPORTS/pmaports.cfg" 2>/dev/null | head -1 | tr -d '[:space:]')"
if [ -z "$_pmb_need" ] || [ -z "$_pmb_have" ]; then
    echo "  ⚠ toolchain check SKIPPED (pmaports requirement='$_pmb_need'," \
         "pmbootstrap version='$_pmb_have') -- did pmaports.cfg change its keys?"
elif [ "$(printf '%s\n%s\n' "$_pmb_need" "$_pmb_have" | sort -V | head -1)" != "$_pmb_need" ]; then
    echo ""
    echo "=== TOOLCHAIN MISMATCH ==="
    echo "  pmaports $(git -C "$PMAPORTS" rev-parse --short HEAD) requires pmbootstrap >= $_pmb_need"
    echo "  this image has $_pmb_have"
    echo "  Fix: bump ARG PMBOOTSTRAP_REF in the Dockerfile to >= $_pmb_need,"
    echo "       rebuild the image (docker build -t nexusq-builder .), and re-check"
    echo "       that Phase 6b still reports all FOUR patches as applied."
    echo "  (Or pin PMAPORTS_REF to an older pmaports commit.)"
    exit 1
else
    echo "  toolchain OK: pmbootstrap $_pmb_have >= pmaports' required $_pmb_need"
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
for pkg in device-google-steelhead nexusq-glibc-rt linux-google-steelhead firmware-google-steelhead; do
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

# BCM4330 WiFi (brcmfmac) + Bluetooth firmware. The mainline kernel drives this
# chip with brcmfmac + hci_uart_bcm, which request these EXACT names under
# /lib/firmware/brcm (verified live on the device):
#   brcm/brcmfmac4330-sdio.bin  WiFi base fw  (redistributable, upstream linux-firmware)
#   brcm/brcmfmac4330-sdio.txt  WiFi NVRAM    (the device's bcmdhd.cal -- key=value NVRAM)
#   brcm/BCM4330B1.hcd          BT patchram   (proprietary, from the device)
# Without them: "brcmfmac ... Direct firmware load ... -2" (no WiFi) and
# "BCM: firmware Patch file not found" (no BT). The two proprietary blobs live in
# ./firmware (gitignored, maintainer/private-overlay provided); the brcmfmac base
# fw is redistributable and cached in ./firmware (or fetched on demand). Stage all
# three into the firmware aport so firmware-google-steelhead installs them.
# Baked-in device access (ssh authorized_keys + the WiFi connection profile).
# The WiFi PSK is a secret and the ssh pubkeys are personal, so both live in
# the PRIVATE overlay (./private/access) — never in the public tree. Stage them
# into the device aport (the APKBUILD installs non-empty files to
# /root/.ssh + /etc/skel/.ssh and /etc/NetworkManager/system-connections).
# A public clone gets EMPTY placeholders: the build still succeeds, the image
# just bakes no access (configure ssh/WiFi by hand after flashing). This is
# what makes a clean reflash come up reachable — access config lives in the
# rootfs, which every flash wipes (bitten 2026-06-28 and 2026-07-02).
# PUBLIC_RELEASE=1 forces a CLEAN image (nothing personal baked) even when the
# private overlay is present — releases publish the rootfs on GitHub, and a
# personally-built image would ship the WiFi PSK + authorized_keys to the
# world. scripts/release-preflight-no-secrets.sh additionally hard-fails the
# release if a candidate image contains either file.
DEV_APORT="$PMAPORTS/device/testing/device-google-steelhead"
if [ "${PUBLIC_RELEASE:-0}" = "1" ]; then
    : > "$DEV_APORT/ssh-authorized-keys"
    : > "$DEV_APORT/wifi.nmconnection"
    echo "  PUBLIC_RELEASE=1 -> access staging SKIPPED (clean release image)"
elif [ -f "$SRC/private/access/authorized_keys" ]; then
    cp "$SRC/private/access/authorized_keys" "$DEV_APORT/ssh-authorized-keys"
    echo "  Staged ssh-authorized-keys (private overlay)"
else
    : > "$DEV_APORT/ssh-authorized-keys"
    echo "  WARNING: private/access/authorized_keys absent -> no ssh keys baked"
fi
if [ "${PUBLIC_RELEASE:-0}" = "1" ]; then
    # Already truncated above -- NEVER stage the WiFi PSK into a release image.
    # (This guard must mirror the ssh one: a bare `if -f private/...` here once
    # re-staged the PSK right over the truncated placeholder. 2026-07-04.)
    :
elif [ -f "$SRC/private/access/wifi.nmconnection" ]; then
    cp "$SRC/private/access/wifi.nmconnection" "$DEV_APORT/wifi.nmconnection"
    echo "  Staged wifi.nmconnection (private overlay)"
else
    : > "$DEV_APORT/wifi.nmconnection"
    echo "  WARNING: private/access/wifi.nmconnection absent -> WiFi not preconfigured"
fi

FW_APORT="$PMAPORTS/device/testing/firmware-google-steelhead"
BRCMFMAC_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/brcm/brcmfmac4330-sdio.bin"
if [ -f "$SRC/firmware/bcm4330.hcd" ] && [ -f "$SRC/firmware/bcmdhd.cal" ]; then
    cp "$SRC/firmware/bcm4330.hcd" "$FW_APORT/BCM4330B1.hcd"
    cp "$SRC/firmware/bcmdhd.cal"  "$FW_APORT/brcmfmac4330-sdio.txt"
    if [ -f "$SRC/firmware/brcmfmac4330-sdio.bin" ]; then
        cp "$SRC/firmware/brcmfmac4330-sdio.bin" "$FW_APORT/brcmfmac4330-sdio.bin"
        echo "  Staged BCM4330 firmware: BT .hcd + WiFi .txt + brcmfmac .bin (local cache)"
    else
        echo "  Fetching redistributable brcmfmac4330-sdio.bin from upstream linux-firmware..."
        curl -fsSL "$BRCMFMAC_URL" -o "$FW_APORT/brcmfmac4330-sdio.bin" \
            && echo "  Staged BCM4330 firmware: BT .hcd + WiFi .txt + brcmfmac .bin (downloaded)" \
            || { echo "  ERROR: could not fetch brcmfmac4330-sdio.bin -- WiFi firmware will be missing"; rm -f "$FW_APORT/brcmfmac4330-sdio.bin"; }
    fi
fi
if [ ! -f "$FW_APORT/BCM4330B1.hcd" ] || [ ! -f "$FW_APORT/brcmfmac4330-sdio.bin" ]; then
    # Public clone without the firmware overlay (or a failed fetch): fall back to an
    # EMPTY firmware package so the build still succeeds (WiFi/BT just get no firmware).
    echo "  WARNING: BCM4330 firmware blobs incomplete -> building EMPTY firmware-google-steelhead"
    rm -f "$FW_APORT"/brcmfmac4330-sdio.* "$FW_APORT"/BCM4330B1.hcd
    cat > "$FW_APORT/APKBUILD" <<'FWEMPTY'
pkgname=firmware-google-steelhead
pkgver=1
pkgrel=1
pkgdesc="Google Nexus Q BCM4330 firmware (blobs not provided -- empty)"
url="https://postmarketos.org"
arch="armv7"
license="proprietary"
depends="firmware-aosp-broadcom-wlan"
options="!strip !check !archcheck !spdx !tracedeps"
build() { true; }
package() { mkdir -p "$pkgdir"; }
sha512sums=""
FWEMPTY
fi

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

# nexusq-control: the companion LAN control bridge (pure-Python). Stage the
# aport + the two python scripts + the systemd unit next to its APKBUILD.
NEXUSQCTL_DIR="$PMAPORTS/main/nexusq-control"
mkdir -p "$NEXUSQCTL_DIR"
cp "$SRC/pmos/nexusq-control/APKBUILD"             "$NEXUSQCTL_DIR/"
cp "$SRC/userspace/nexusq-control/nexusq-control"  "$NEXUSQCTL_DIR/"
cp "$SRC/userspace/nexusq-control/nexusq-onevent"  "$NEXUSQCTL_DIR/"
cp "$SRC/userspace/nexusq-control/nexusq-control.service" "$NEXUSQCTL_DIR/"
echo "  Installed: nexusq-control (aport + bridge -> main/nexusq-control)"

# nexusq-setupd: the BT provisioning daemon (pure staging, like nexusq-control).
NEXUSQSETUP_DIR="$PMAPORTS/main/nexusq-setupd"
mkdir -p "$NEXUSQSETUP_DIR"
cp "$SRC/pmos/nexusq-setupd/APKBUILD"                     "$NEXUSQSETUP_DIR/"
cp "$SRC/userspace/nexusq-setupd/nexusq-setupd"           "$NEXUSQSETUP_DIR/"
cp "$SRC/userspace/nexusq-setupd/nexusq-setupd.service"   "$NEXUSQSETUP_DIR/"
cp "$SRC/userspace/nexusq-setupd/nexusq-setup-needed"     "$NEXUSQSETUP_DIR/"
echo "  Installed: nexusq-setupd (aport + daemon -> main/nexusq-setupd)"

# nexusq-btagent: the permanent BlueZ Just-Works agent (pure staging).
NEXUSQBTA_DIR="$PMAPORTS/main/nexusq-btagent"
mkdir -p "$NEXUSQBTA_DIR"
cp "$SRC/pmos/nexusq-btagent/APKBUILD"                    "$NEXUSQBTA_DIR/"
cp "$SRC/userspace/nexusq-btagent/nexusq-btagent"         "$NEXUSQBTA_DIR/"
cp "$SRC/userspace/nexusq-btagent/nexusq-btagent.service" "$NEXUSQBTA_DIR/"
cp "$SRC/userspace/nexusq-btagent/README.md"              "$NEXUSQBTA_DIR/"
echo "  Installed: nexusq-btagent (aport + agent -> main/nexusq-btagent)"

# nexusq-mqtt: the MQTT health telemetry publisher (pure staging, like the rest).
NEXUSQMQTT_DIR="$PMAPORTS/main/nexusq-mqtt"
mkdir -p "$NEXUSQMQTT_DIR"
cp "$SRC/pmos/nexusq-mqtt/APKBUILD"                       "$NEXUSQMQTT_DIR/"
cp "$SRC/userspace/nexusq-mqtt/nexusq-mqtt"               "$NEXUSQMQTT_DIR/"
cp "$SRC/userspace/nexusq-mqtt/nexusq-mqtt.service"       "$NEXUSQMQTT_DIR/"
cp "$SRC/userspace/nexusq-mqtt/96-nexusq-mqtt.preset"     "$NEXUSQMQTT_DIR/"
echo "  Installed: nexusq-mqtt (aport + daemon -> main/nexusq-mqtt)"

# python3: NO local override any more (retired 2026-08-17).
# We used to stage pmos/python3 over pmaports main/python3 (a rebuild at a higher
# pkgrel, LTO+PGO dropped) because Alpine's stock python3 SIGSEGVed on armv7. That
# root cause was settled on 2026-06-28 and it was NOT the build: raw2simg.py marked
# all-zero blocks as fastboot DONT_CARE, the device does not pre-erase userdata, and
# stale garbage showed through libpython's should-be-zero regions AFTER flashing. The
# built apk was always clean. raw2simg.py now writes every block RAW.
#
# The override then quietly went inert: Alpine edge moved to python3 3.14.7 and apk
# compares pkgver BEFORE pkgrel, so our 3.14.5-r5 stopped winning. The 2026-08-17 cold
# build still built it, still gate-passed it, still exported it -- and the rootfs
# installed Alpine's 3.14.7-r0 regardless (proved by libpython md5). A safety net that
# silently stops being installed is worse than none, so it is gone; what remains is the
# Phase 10 SHIP GATE, which checks the libpython actually present in the rootfs
# whatever its provenance. To resurrect the override: git revert this commit.

echo "  Converting line endings (CRLF -> LF)..."
find "$PMAPORTS/device/testing/" "$NEXUSQD_DIR" "$NEXUSQCTL_DIR" "$NEXUSQSETUP_DIR" "$NEXUSQBTA_DIR" "$NEXUSQMQTT_DIR" "$PYTHON3_DIR" -type f \( -name "APKBUILD" -o -name "deviceinfo" -o -name "modules-initfs" -o -name "*.patch" -o -name "config-*" -o -name "*.c" -o -name "*.h" -o -name "Makefile" -o -name "*.service" -o -name "*.json" -o -name "*.preset" -o -name "nexusq-control" -o -name "nexusq-onevent" -o -name "nexusq-setupd" -o -name "nexusq-setup-needed" -o -name "nexusq-btagent" -o -name "nexusq-mqtt" \) -exec dos2unix -q {} +
echo "  Done."

echo ""
echo "=== Phase 6b: Patch pmbootstrap for Docker compatibility ==="

APK_PY="/usr/lib/python3.12/site-packages/pmb/helpers/apk.py"
PART_PY="/usr/lib/python3.12/site-packages/pmb/install/partition.py"
LOSETUP_PY="/usr/lib/python3.12/site-packages/pmb/install/losetup.py"
BACKEND_PY="/usr/lib/python3.12/site-packages/pmb/build/backend.py"
BLOCKDEV_PY="/usr/lib/python3.12/site-packages/pmb/install/blockdevice.py"

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

sudo python3 << 'PATCH_PARTITIONS_MOUNT'
# Phase 9 "File did not appear: /dev/loopNp2" fix. A docker container's /dev is
# a STATIC tmpfs populated once at container start (no devtmpfs/udev), so the
# partition nodes the kernel creates for `losetup -P` after start never appear
# in the container; partitions_mount()'s wait_until_exists() then times out.
# Fix: before waiting, mknod the missing node ourselves from sysfs, which is
# authoritative for the partition's major:minor and appears synchronously.
path = "/usr/lib/python3.12/site-packages/pmb/install/partition.py"
with open(path) as f:
    content = f.read()

old = """    for i in partitions:
        source = Path(f"{partition_prefix}{i}")
        pmb.helpers.file.wait_until_exists(source)"""

new = """    for i in partitions:
        source = Path(f"{partition_prefix}{i}")
        if not source.exists():
            # Docker: static tmpfs /dev -- create the partition node from sysfs.
            import subprocess
            import time as _time
            sysfs_dev = Path(f"/sys/block/{disk.name}/{source.name}/dev")
            for _ in range(10):
                if sysfs_dev.exists():
                    break
                _time.sleep(0.5)
            if sysfs_dev.exists():
                major, minor = sysfs_dev.read_text().strip().split(":")
                subprocess.run(["sudo", "mknod", str(source), "b", major, minor], check=False)
                logging.info(f"Created partition node {source} (from sysfs {major}:{minor})")
        pmb.helpers.file.wait_until_exists(source)"""

if old in content:
    content = content.replace(old, new)
    with open(path, "w") as f:
        f.write(content)
    print("  Patched partition.py: mknod-from-sysfs fallback in partitions_mount")
else:
    print("  partition.py partitions_mount: PATTERN NOT FOUND (pmbootstrap changed?)")
PATCH_PARTITIONS_MOUNT

sudo python3 << 'PATCH_BLOCKDEV'
# THE Phase 9 "PREPARE INSTALL BLOCKDEVICE" fix. ROOT CAUSE of the install
# aborting at "(native) % busybox su pmos -c HOME=/home/pmos mkdir -p
# /home/pmos/rootfs" (exit 125): pmbootstrap-in-Docker runs the native chroot's
# `pmos` user as uid 12345 (its sandbox uid), while that chroot's /home/pmos is
# owned by uid 1000 -> the ONE user-level mkdir (blockdevice.create_and_mount_image)
# hits EPERM. A pre-`install` host-side chown does NOT survive, because `install`
# itself re-creates ("PREPARE NATIVE CHROOT / Creating chroot") the native chroot
# and resets /home/pmos back to 1000 *after* our chown, then fails on the mkdir.
#
# The clean, correct fix (not a workaround): run just that mkdir as root. It only
# needs the directory to EXIST -- every operation that follows in the same function
# (truncate, losetup, mount, and later the rsync of the rootfs into the image) is
# ALREADY `pmb.chroot.root(...)`, so nothing depends on the dir being pmos-owned.
# Running mkdir as root succeeds regardless of /home/pmos ownership and removes the
# uid-drift dependency entirely -- exactly parallel to the abuild-as-root fix above.
path = "/usr/lib/python3.12/site-packages/pmb/install/blockdevice.py"
with open(path) as f:
    content = f.read()

old = 'pmb.chroot.user(["mkdir", "-p", "/home/pmos/rootfs"])'
new = 'pmb.chroot.root(["mkdir", "-p", "/home/pmos/rootfs"])'

if new in content:
    print("  blockdevice.py: already patched (idempotent re-run)")
elif old in content:
    content = content.replace(old, new)
    with open(path, "w") as f:
        f.write(content)
    print("  Patched blockdevice.py: mkdir /home/pmos/rootfs runs as root -> no uid-12345 EPERM")
else:
    print("  blockdevice.py: PATTERN NOT FOUND (pmbootstrap changed the mkdir call!)")
PATCH_BLOCKDEV

sudo python3 << 'PATCH_BACKEND'
# THE fakeroot fix. ROOT CAUSE of the build hanging forever at
# ">>> <pkg>: Entering fakeroot..." (device-google-steelhead reliably; any
# package whose package() actually runs): abuild wraps package()+create_apks in
# fakeroot, whose `faked` daemon — run through qemu-arm because we build armv7 in
# emulation — busy-loops at ~100% CPU under qemu and never makes progress, so the
# package step never returns. This is NOT the SysV-IPC issue an earlier revision
# tried to dodge with fakeroot-tcp: the installed faked is ALREADY the TCP variant
# (verified: 0 sysv syscalls, 7 socket syscalls) and it spins just the same. The
# qemu emulation of faked's daemon loop is the problem, regardless of sysv/tcp.
#
# abuild itself gives the clean way out (abuild source ~line 2992):
#     if [ $(id -u) -eq 0 ] && [ -z "$FAKEROOTKEY" ]; then FAKEROOT= ; fi
# i.e. when abuild runs AS ROOT it sets FAKEROOT empty and skips fakeroot/faked
# entirely — and because it is really root, package() creates real root:root files,
# so the resulting .apk has correct ownership (NOT a shortcut — ownership is right).
#
# pmbootstrap runs abuild as the unprivileged `pmos` user (pmb/build/backend.py:
# `pmb.chroot.user(cmd, ...)`), which forces the fakeroot path. We flip that one
# call to run as root and pass abuild `-F` (required: abuild refuses to run as root
# without it). We must ALSO pin HOME=/home/pmos in the env, or root would look for
# the package-signing key in /root/.abuild (where pmbootstrap never put it) and
# create_apks would fail to sign. This eliminates faked for EVERY package (kernel,
# nexusqd, device, firmware) — no qemu busy-loop, reliably.
path = "/usr/lib/python3.12/site-packages/pmb/build/backend.py"
with open(path) as f:
    content = f.read()

reps = [
    # 1) run abuild as root, not as the pmos user (root => abuild drops fakeroot)
    (
        'pmb.chroot.user(cmd, buildchroot, Path("/home/pmos/build"), env=env)',
        'pmb.chroot.root(cmd, buildchroot, Path("/home/pmos/build"), env=env)',
    ),
    # 2) -F: let abuild run as root; without it abuild aborts ("don't run as root")
    (
        'cmd = ["abuild", "-d", "-D", "postmarketOS"]',
        'cmd = ["abuild", "-F", "-d", "-D", "postmarketOS"]',
    ),
    # 3) HOME=/home/pmos so root finds the .abuild signing key + abuild.conf.
    # Match only the SUDO_APK prefix and inject HOME right after it, so this stays
    # robust to pmbootstrap adding further keys to the env dict (3.10.1 appended
    # `, "PMB_CROSS": str(cross)}` -- which broke an exact full-literal match).
    (
        'env: Env = {"SUDO_APK": "abuild-apk --no-progress"',
        'env: Env = {"SUDO_APK": "abuild-apk --no-progress", "HOME": "/home/pmos"',
    ),
]

applied = 0
for old, new in reps:
    if new in content:
        applied += 1  # already patched (idempotent re-run)
    elif old in content:
        content = content.replace(old, new)
        applied += 1
    else:
        print(f"  backend.py: PATTERN NOT FOUND -> {old!r} (pmbootstrap changed?)")

if applied == len(reps):
    with open(path, "w") as f:
        f.write(content)
    print(f"  Patched backend.py: abuild runs as root (-F, HOME=/home/pmos) -> no fakeroot/faked, no qemu hang")
else:
    print(f"  backend.py: only {applied}/{len(reps)} patterns matched -- NOT writing (fakeroot hang risk!)")
PATCH_BACKEND

echo "  Compiling patched files..."
sudo python3 -c "import py_compile; py_compile.compile('$APK_PY', doraise=True)" && echo "    apk.py: OK"
sudo python3 -c "import py_compile; py_compile.compile('$PART_PY', doraise=True)" && echo "    partition.py: OK"
sudo python3 -c "import py_compile; py_compile.compile('$BACKEND_PY', doraise=True)" && echo "    backend.py: OK"
sudo python3 -c "import py_compile; py_compile.compile('$BLOCKDEV_PY', doraise=True)" && echo "    blockdevice.py: OK"

echo ""
echo "=== Phase 6c: Pre-create /dev/loop* nodes (docker static /dev) ==="
# A docker container's /dev is a STATIC tmpfs snapshot taken at container start
# (no devtmpfs, no udev), so ANY device node the kernel creates afterwards never
# shows up inside the container. `losetup -f` asks the kernel for the next free
# loop index via ioctl(LOOP_CTL_GET_FREE) and then opens /dev/loop<idx>. On a
# host whose low loop indices are all consumed -- this build machine's snapd
# keeps ~47 squashfs mounts alive -- the kernel hands back an index that was
# only materialised as a node on the HOST, after our container started:
#     losetup: .../google-steelhead.img: failed to set up loop device: No such file or directory
#     losetup: device node /dev/loop47 (7:47) is lost. You may use mknod(1) to recover it.
# pmbootstrap calls losetup with check=False, so the only symptom is Phase 9
# dying at "(3/4) PREPARE INSTALL BLOCKDEVICE" with
#     ERROR: Failed to find loop device for /home/pmos/rootfs/google-steelhead.img
# (hit 2026-08-17 on the cold verification build). Exactly the same class as the
# partitions_mount() mknod-from-sysfs patch above -- fix it the same way, but
# up-front: materialise the whole loop-major node range ourselves. Loop nodes are
# inert until configured, so pre-creating unused ones costs nothing, and it makes
# the build independent of how many loop devices the host happens to be using.
_loop_made=0
for _i in $(seq 0 255); do
    [ -e "/dev/loop$_i" ] && continue
    sudo mknod -m 660 "/dev/loop$_i" b 7 "$_i" 2>/dev/null && _loop_made=$((_loop_made + 1))
done
echo "  Created $_loop_made missing node(s); /dev now has $(ls -d /dev/loop[0-9]* 2>/dev/null | wc -l) loop nodes"
echo "  Next free loop device: $(sudo losetup -f 2>&1)"

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
# Full Wayland desktop on the HDMI port: LXQt-Wayland, running on labwc as the
# compositor (no GPU driver yet — see docs/2026-06-19-gpu-sgx540-acceleration-
# research.md). The device package forces the wlroots Pixman SW renderer
# (/etc/profile.d), pins the labwc compositor (/etc/xdg/lxqt/session.conf) and
# wires the LXQt-Wayland tinydm session; weston is kept as a fallback session.
# Needs musl >= 1.2.6 (renameat2) for Qt6 — a fresh edge build pulls that.
# NOTE: postmarketos-ui-lxqt is X11-by-default (drags in xorg-server, unused
# under our Wayland session); the device package adds lxqt-wayland-session +
# labwc and makes the LXQt-Wayland session the tinydm default. A future cleanup
# could switch to 'ui = none' + an explicit Wayland-only LXQt depends to drop X11.
# Replaced the bare weston desktop (2026-06-20). See memory: nexusq-desktop-lxqt.
ui = lxqt
build_pkgs_on_install = True
hostname = steelhead
extra_packages = none
is_default_channel = True
boot_size = 512
build_default_device_arch = False
ccache_size = 5G
extra_space = 0
jobs = $(nproc)
kernel = stable
locale = en_US.UTF-8
qemu_redir_stdio = False
ssh_keys = False
sudo_timer = False
# pmbootstrap RENAMED this key: it was 'systemd = always' up to 3.10.x and is
# 'service_manager = systemd' (default|openrc|systemd) from 3.11.0. NB: this
# heredoc's delimiter is UNQUOTED (values below interpolate $PMAPORTS etc.), so
# backticks here would run as command substitution -- they did, once. The old key
# is not rejected, it is SILENTLY IGNORED — so the 2026-08-16 cold build fell
# back to the ui default (postmarketos-ui-lxqt -> openrc) and was on course to
# produce an OpenRC rootfs with no nexusqd and no sshd. That is exactly the
# v1.5.0 disaster, which shipped because a build "succeeded". The guard right
# after this config write is what makes the rename non-silent; do not remove it.
service_manager = systemd
# Switching the service manager flips the apk channel (edge -> systemd-edge). A warm
# nexusq-workdir volume left over from an older 'edge' (OpenRC) build then holds
# misconfigured chroots, and pmbootstrap aborts ("Chroot is for the 'edge'
# channel, but you are on 'systemd-edge'"). Let it auto-delete those stale
# chroots and rebuild clean on the correct channel instead of failing.
auto_zap_misconfigured_chroots = silently
timezone = Europe/Prague
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

# --- the init-system gate (v1.5.0, and again 2026-08-16) ---------------------
# ASSERT the service manager actually took, do not assume the config was read.
# v1.5.0 shipped an OpenRC rootfs (no nexusqd, no sshd) that built and checksummed
# cleanly; on 2026-08-16 pmbootstrap 3.11.0 renamed `systemd` -> `service_manager`
# and SILENTLY ignored the old key, putting a cold build back on that same road.
# A config option we merely write is a hope; one we read back is a fact.
# Step 1 — does this pmbootstrap even KNOW the key we just wrote? argparse lists
# every valid config name in `config --help`, and it needs no work dir, so this
# works at any point in the run. This is the check that catches a rename: today
# `service_manager` is listed and the old `systemd` is not.
if ! pmbootstrap config --help 2>&1 | grep -q '\bservice_manager\b'; then
    echo ""
    echo "=== INIT SYSTEM OPTION RENAMED ==="
    echo "  This pmbootstrap does not accept 'service_manager'. The config we"
    echo "  write would be SILENTLY IGNORED and the build would fall back to the"
    echo "  ui default (openrc) -> an OpenRC rootfs with no nexusqd and no sshd,"
    echo "  which is exactly how v1.5.0 shipped broken."
    echo "  Valid names in this version:"
    pmbootstrap config --help 2>&1 | sed -n 's/.*choose from \(.*\))/    \1/p'
    exit 1
fi
# Step 2 — best effort read-back. Needs an initialised work dir, so an empty
# answer is not treated as failure; a WRONG answer is.
_svc="$(pmbootstrap config service_manager 2>/dev/null | tail -1 | tr -d '[:space:]')"
if [ -n "$_svc" ] && [ "$_svc" != "systemd" ]; then
    echo ""
    echo "=== INIT SYSTEM MISCONFIGURED ==="
    echo "  wanted service_manager=systemd, pmbootstrap reports: '$_svc'"
    echo "  Refusing to continue — this builds an OpenRC rootfs."
    exit 1
fi
echo "  init system: service_manager=systemd (key accepted${_svc:+, read back as $_svc})"

echo ""
echo "=== Phase 7a: Fix abuild REPODEST ownership on the work volume ==="
# ROOT CAUSE of the recurring "can't create .../pmos/armv7/...apk: Permission
# denied" in abuild's create_apks step:
#
# Inside the buildroot chroot, abuild's REPODEST is /home/pmos/packages, where
# pmbootstrap symlinks .../packages/pmos -> /mnt/pmbootstrap/packages/<channel>,
# a bind mount of this work dir's $WORK/packages/<channel> (on the persistent
# nexusq-workdir volume). The chroot's abuild user is uid 12345
# (pmb.config.chroot_uid_user), NOT the container's pmos (uid 1000). So abuild
# writes the .apk as uid 12345 into $WORK/packages/<channel>/armv7/.
#
# pmbootstrap (pmb/build/backend.py) only chowns $WORK/packages to 12345 when
# $WORK/packages/<channel> does NOT yet exist. On a *reused* work volume that
# dir already exists, and the broad `sudo chown -R pmos:pmos /home/pmos` in
# Phase 5 above has (re)set the whole tree to uid 1000 (mode 0755, no group/
# other write). uid 12345 can then no longer create files there -> create_apks
# fails with EACCES and rootpkg/create_apks aborts even though the kernel,
# modules and DTBs compiled fine into the pkgdir.
#
# Fix: hand $WORK/packages to the chroot's abuild uid (12345) explicitly, every
# run, so abuild can always write its .apk. This mirrors exactly what
# pmbootstrap's own (only-if-missing) chown does, just unconditionally and after
# the Phase 5 chown that would otherwise clobber it. mkdir -p covers a fresh
# volume; the chown re-asserts ownership on a reused one.
sudo mkdir -p "$WORK/packages"
sudo chown -R 12345:12345 "$WORK/packages"
echo "  $WORK/packages now owned by uid 12345 (chroot abuild user):"
ls -lan "$WORK/packages" | head

# Same EACCES root cause applies to the armv7 ccache dir: abuild inside the
# chroot (uid 12345) writes ccache objects into $WORK/cache_ccache_armv7, but the
# broad `sudo chown -R pmos:pmos /home/pmos` in Phase 5 (re)sets it to uid 1000
# (mode 0755, no group/other write). uid 12345 then cannot recreate ccache's
# bucket dirs -> `make olddefconfig` aborts with "ccache: error: Permission
# denied". (Especially after the cache contents were cleared out-of-band, which
# leaves only the uid-1000 parent + ccache.conf behind.) Hand it to uid 12345
# unconditionally, mirroring the $WORK/packages fix above.
sudo mkdir -p "$WORK/cache_ccache_armv7"
sudo chown -R 12345:12345 "$WORK/cache_ccache_armv7"
echo "  $WORK/cache_ccache_armv7 now owned by uid 12345 (chroot abuild user)"

# Same EACCES root cause, third spot: the abuild *package-signing key*.
# pmbootstrap (pmb/build/init.py) generates the key by running `abuild-keygen`
# INSIDE the chroot as the chroot's pmos user (uid 12345), writing it into
# $WORK/config_abuild (bind-mounted at the chroot's /home/pmos/.abuild). The
# private key lands as `pmos@local-<id>.rsa`, mode 0600, owner uid 12345 — and
# abuild later reads it (still as uid 12345) to sign control.tar.gz in
# create_apks. But the broad `sudo chown -R pmos:pmos /home/pmos` in Phase 5
# (re)sets config_abuild to uid 1000, so the in-chroot uid 12345 can no longer
# read its own 0600 key -> openssl BIO_new_file "Permission denied" ->
# "failed to sign .../control.tar.gz" -> create_apks/rootpkg fail, even though
# the package itself built fine. (Only bites when the device package actually
# needs a *rebuild*; a cached .apk skips signing.) Re-assert uid 12345 on the
# whole key dir, exactly as for packages/ccache above. mkdir -p covers a fresh
# volume (keys are then generated as 12345 during the build and need no fixup).
sudo mkdir -p "$WORK/config_abuild"
sudo chown -R 12345:12345 "$WORK/config_abuild"
echo "  $WORK/config_abuild now owned by uid 12345 (chroot abuild signing key)"

# Same EACCES root cause, fourth spot: the shared distfiles cache. abuild-fetch
# (run inside the buildroot chroot as uid 12345) creates a `<tarball>.lock` file
# in /var/cache/distfiles (bind-mounted from $WORK/cache_distfiles) before it
# fetches/checksums a source tarball (e.g. the 148 MB linux-6.12.12.tar.xz). The
# broad `sudo chown -R pmos:pmos /home/pmos` in Phase 5 (re)sets that dir to uid
# 1000 (mode 0755), so uid 12345 cannot create the .lock -> "abuild-fetch:
# .../linux-6.12.12.tar.xz.lock: Permission denied" -> "checksum failed" then
# "fetch failed" -> the kernel package fails to build (exit 3), even though the
# tarball itself is already present in the cache. Hand the dir to uid 12345 too.
sudo mkdir -p "$WORK/cache_distfiles"
sudo chown -R 12345:12345 "$WORK/cache_distfiles"
echo "  $WORK/cache_distfiles now owned by uid 12345 (chroot abuild-fetch lock)"

echo ""
echo "=== Phase 7b: Generate checksums ==="
# EVERY aport we stage gets its checksums here, BEFORE any build phase runs —
# not per-phase, next to each build.
#
# Our APKBUILDs ship sha512sums="SKIP" placeholders, so each one must be
# regenerated against the sources Phase 6 just staged. Doing that inside each
# build phase silently made phase ORDER part of the contract: pmbootstrap
# resolves a package's `depends=` and builds them from inside that build, so a
# dependency whose own phase had not run yet was still carrying the placeholder
# and abuild hard-failed the phase that triggered it:
#     >>> ERROR: <dep>: <dep> is missing in checksums     (exit 3)
# That is why 7c3 had to precede 7c4 (nexusq-setupd depends= nexusq-btagent,
# found 2026-07-15), and the same trap reappeared on 2026-08-13 in the
# OTA_PACKAGES_ONLY path (device-google-steelhead depends= nexusq-mqtt).
# Checksumming everything up front removes the ordering constraint entirely
# instead of documenting it — a build phase can no longer be defeated by which
# phase happens to run first.
#
# The kernel is listed first only because it is the slow one (it fetches a
# ~148 MB tarball); nothing depends on that position.
echo "Generating checksums for kernel package..."
pmbootstrap checksum linux-google-steelhead 2>&1 || {
    echo "WARNING: checksum generation failed, will try building anyway"
}
for _ck_pkg in device-google-steelhead nexusq-glibc-rt firmware-google-steelhead \
               nexusqd nexusq-control nexusq-btagent nexusq-setupd nexusq-mqtt; do
    echo "Generating checksums for $_ck_pkg..."
    pmbootstrap checksum "$_ck_pkg" 2>&1 || true
done

# --- OTA_PACKAGES_ONLY: targeted two-package OTA build -------------------------
# For an OTA that ships ONLY config/daemon apks (not a fresh rootfs/boot.img),
# rebuilding the whole rootfs is wasteful. Set OTA_PACKAGES_ONLY=1 to build just
# nexusqd + device-google-steelhead (both --force so a bumped pkgrel is actually
# re-packed into the work-volume repo), sign them with the volume's existing
# abuild key (config_abuild, re-owned to uid 12345 in Phase 7a above), export the
# freshly-built apks to /tmp/output, and exit. All the load-bearing setup (Phase
# 5 aports staging, 6b abuild-as-root patch, 7 config, 7a REPODEST ownership, 7b
# checksums) has already run verbatim above, so the apks land in
# $WORK/packages/<channel>/armv7 exactly as a full build would produce them --
# ready for scripts/publish-ota-repo.sh. The two apks' runtime depends
# (nexusq-glibc-rt, control/btagent/setupd, firmware, python3) are NOT rebuilt:
# they are unchanged and already cached in the warm volume; abuild only needs
# them at rootfs-install time, not to build these two packages.
if [ "${OTA_PACKAGES_ONLY:-0}" = "1" ]; then
    echo ""
    # OTA_PACKAGES lets a caller target a different set of aports (each must live
    # at $SRC/pmos/<name>/APKBUILD). Default = the two-package rootfs-less OTA.
    _ota_list="${OTA_PACKAGES:-nexusqd device-google-steelhead}"
    echo "=== OTA_PACKAGES_ONLY=1: building ONLY: $_ota_list ==="
    sudo mkdir -p /tmp/output && sudo chown pmos:pmos /tmp/output

    # Checksum EVERY requested package BEFORE building any of them. Interleaving
    # (checksum A; build A; checksum B; build B) breaks whenever A depends on B:
    # pmbootstrap resolves the dep and builds B from within A's build, while B's
    # aport still carries the sha512sums="SKIP" placeholder ->
    #   ">>> ERROR: <B>: <B> is missing in checksums"
    # and the whole run dies with exit 3. That made the caller's package ORDER
    # load-bearing, which nothing documented and nothing enforced: it bit
    # nexusq-btagent -> nexusq-setupd, then again on 2026-08-13 with
    # device-google-steelhead -> nexusq-mqtt. A separate first pass makes order
    # irrelevant, which is the only version of this that stays fixed.
    for _ota_pkg in $_ota_list; do
        set +e
        # The aports ship sha512sums="SKIP" placeholders; regenerate them against
        # the just-staged sources. Failure here is not fatal on its own — the
        # build below reports the real error with context.
        pmbootstrap checksum "$_ota_pkg" 2>&1 || true
        set -e
    done

    _ota_fail=0
    for _ota_pkg in $_ota_list; do
        echo ""
        echo "--- OTA build: $_ota_pkg ---"
        set +e
        # --force: a bumped pkgrel must not be skipped by a stale same-name apk
        # in the warm repo.
        pmbootstrap --no-cross build "$_ota_pkg" --arch armv7 --force 2>&1
        _ota_rc=$?
        set -e
        echo "=== $_ota_pkg build exit code: $_ota_rc ==="
        if [ $_ota_rc -ne 0 ]; then
            echo "  ERROR: $_ota_pkg build FAILED (exit $_ota_rc). Key log lines:"
            grep -n "ERROR\|error:\|FAILED" "$WORK/log.txt" 2>/dev/null | tail -30
            _ota_fail=1
            continue
        fi
        # pkgrel-EXACT export (mirrors the Phase 7c logic): the persistent
        # work-volume repo accumulates stale apks, so match the precise
        # pkgver-r<pkgrel> from the staged APKBUILD, not a bare name glob.
        _ota_pv=$(sed -n 's/^pkgver=//p' "$SRC/pmos/$_ota_pkg/APKBUILD" | head -1)
        _ota_pr=$(sed -n 's/^pkgrel=//p' "$SRC/pmos/$_ota_pkg/APKBUILD" | head -1)
        _ota_apk=$(find "$WORK/packages" -name "${_ota_pkg}-${_ota_pv}-r${_ota_pr}.apk" -print -quit 2>/dev/null)
        if [ -n "$_ota_apk" ]; then
            cp "$_ota_apk" /tmp/output/ && echo "  Exported: $(basename "$_ota_apk")  ($(du -h "$_ota_apk" | cut -f1))"
            echo "  In-volume repo path: $_ota_apk"
        else
            echo "  ERROR: $_ota_pkg built but ${_ota_pkg}-${_ota_pv}-r${_ota_pr}.apk not found under $WORK/packages"
            _ota_fail=1
        fi
    done
    echo ""
    echo "=== OTA_PACKAGES_ONLY summary ==="
    for _ota_pkg in $_ota_list; do
        ls -1 "$WORK"/packages/*/armv7/"${_ota_pkg}"-*.apk 2>/dev/null | sort -V
    done
    if [ $_ota_fail -ne 0 ]; then
        echo "=== OTA BUILD FAILED ==="
        exit 1
    fi
    echo "=== OTA BUILD COMPLETE (all apks in the work-volume repo, signed) ==="
    exit 0
fi

# NOTE: there is intentionally no fakeroot workaround here anymore. A previous
# revision installed `fakeroot-tcp` into the armv7 buildroot believing the build
# hung on fakeroot's *SysV-IPC* daemon under qemu. That diagnosis was wrong: the
# faked binary was already the TCP variant and it busy-looped at 100% CPU under
# qemu-arm just the same. The real fix lives in Phase 6b — we patch pmbootstrap to
# run abuild AS ROOT (-F), so abuild sets FAKEROOT="" and skips fakeroot/faked
# entirely for every package. No qemu fakeroot daemon ever runs, so nothing to
# work around here.

echo ""
echo "=== Phase 7c: Build nexusqd app package (armv7/musl) ==="
sudo mkdir -p /tmp/output && sudo chown pmos:pmos /tmp/output
set +e
# Checksums for every aport were regenerated in Phase 7b (the nexusqd sources are
# staged flat into the aport — frame.c, fx_*.c, ... — under a sha512sums="SKIP"
# placeholder that abuild would otherwise reject).
# --no-cross (qemu-only), matching Phase 8: crossdirect (the default cross-compile
# accelerator) is broken in this image -- it cannot exec cc1 ("cc: fatal error:
# cannot execute 'cc1': posix_spawnp: No such file or directory") and the build
# fails (exit 3). Forcing qemu-only sidesteps the broken crossdirect toolchain and
# builds nexusqd reliably, exactly as the real Phase 8 build already does.
pmbootstrap --no-cross build nexusqd --arch armv7 --force 2>&1
NEXUSQD_RC=$?
set -e
echo "=== nexusqd build exit code: $NEXUSQD_RC ==="
if [ $NEXUSQD_RC -eq 0 ]; then
    # pkgrel-EXACT (mirrors the python3 PY3_APK_NAME logic): $WORK/packages is the
    # persistent work-volume repo and accumulates stale apks from earlier runs
    # (nexusqd-...-r1, -r2, ...), so a bare nexusqd-*.apk glob with -print -quit can
    # export an OLD pkgrel instead of the one this build produced (observed: it
    # exported r1 while the rootfs correctly installed r2). Match the precise
    # pkgver-r<pkgrel> from the staged APKBUILD so the exported standalone apk is
    # always the freshly-built one.
    _nqd_pv=$(sed -n 's/^pkgver=//p' "$SRC/pmos/nexusqd/APKBUILD" | head -1)
    _nqd_pr=$(sed -n 's/^pkgrel=//p' "$SRC/pmos/nexusqd/APKBUILD" | head -1)
    NEXUSQD_APK=$(find "$WORK/packages" -name "nexusqd-${_nqd_pv}-r${_nqd_pr}.apk" -print -quit 2>/dev/null)
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
echo "=== Phase 7c2: Build nexusq-control package (noarch) ==="
set +e
# Pure-Python (stdlib) bridge; noarch, no compiler/qemu needed. Checksums: 7b.
pmbootstrap --no-cross build nexusq-control --arch armv7 --force 2>&1
NEXUSQCTL_RC=$?
set -e
echo "=== nexusq-control build exit code: $NEXUSQCTL_RC ==="
if [ $NEXUSQCTL_RC -eq 0 ]; then
    # pkgrel-EXACT (see the nexusqd note above): avoid exporting a stale
    # nexusq-control-...-rN.apk from the persistent work-volume repo.
    _nqc_pv=$(sed -n 's/^pkgver=//p' "$SRC/pmos/nexusq-control/APKBUILD" | head -1)
    _nqc_pr=$(sed -n 's/^pkgrel=//p' "$SRC/pmos/nexusq-control/APKBUILD" | head -1)
    NEXUSQCTL_APK=$(find "$WORK/packages" -name "nexusq-control-${_nqc_pv}-r${_nqc_pr}.apk" -print -quit 2>/dev/null)
    if [ -n "$NEXUSQCTL_APK" ]; then
        cp "$NEXUSQCTL_APK" /tmp/output/ && echo "  Exported: $(basename "$NEXUSQCTL_APK")"
    else
        echo "  WARNING: nexusq-control apk built but not found under $WORK/packages"
    fi
else
    echo "  WARNING: nexusq-control build failed -- key log lines:"
    grep -n "ERROR\|error:\|FAILED" "$WORK/log.txt" 2>/dev/null | tail -30
fi

echo ""
echo "=== Phase 7c3: Build nexusq-btagent package (noarch) ==="
set +e
# Pure-Python (py3-dbus/py3-gobject3) BlueZ agent; noarch, no compiler/qemu.
# --force guards the stale-apk-from-warm-volume trap; checksums: 7b.
#
# Order note (historical): this phase used to be REQUIRED to precede 7c4,
# because nexusq-setupd `depends=` nexusq-btagent and pmbootstrap builds that
# dep from inside the setupd build -- while btagent still carried its
# sha512sums="SKIP" placeholder, which abuild rejects (found 2026-07-15). Since
# Phase 7b checksums every aport up front, that constraint is GONE: the phases
# may run in any order. The dependency-first sequence is kept only because it
# reads naturally.
pmbootstrap --no-cross build nexusq-btagent --arch armv7 --force 2>&1
NEXUSQBTA_RC=$?
set -e
echo "=== nexusq-btagent build exit code: $NEXUSQBTA_RC ==="
if [ $NEXUSQBTA_RC -eq 0 ]; then
    # pkgrel-EXACT: never export a stale nexusq-btagent-...-rN.apk.
    _nqb_pv=$(sed -n 's/^pkgver=//p' "$SRC/pmos/nexusq-btagent/APKBUILD" | head -1)
    _nqb_pr=$(sed -n 's/^pkgrel=//p' "$SRC/pmos/nexusq-btagent/APKBUILD" | head -1)
    NEXUSQBTA_APK=$(find "$WORK/packages" -name "nexusq-btagent-${_nqb_pv}-r${_nqb_pr}.apk" -print -quit 2>/dev/null)
    if [ -n "$NEXUSQBTA_APK" ]; then
        cp "$NEXUSQBTA_APK" /tmp/output/ && echo "  Exported: $(basename "$NEXUSQBTA_APK")"
    else
        echo "  WARNING: nexusq-btagent apk built but not found under $WORK/packages"
    fi
else
    echo "  WARNING: nexusq-btagent build failed -- key log lines:"
    grep -n "ERROR\|error:\|FAILED" "$WORK/log.txt" 2>/dev/null | tail -30
fi

echo ""
echo "=== Phase 7c4: Build nexusq-setupd package (noarch) ==="
set +e
# Pure-Python (py3-dbus/py3-gobject3) BT provisioning daemon; noarch, no
# compiler/qemu needed. Checksums: 7b -- which is also what makes it safe for
# this to sit after 7c3 by convention rather than by necessity (it `depends=`
# nexusq-btagent; see the order note there).
pmbootstrap --no-cross build nexusq-setupd --arch armv7 --force 2>&1
NEXUSQSETUP_RC=$?
set -e
echo "=== nexusq-setupd build exit code: $NEXUSQSETUP_RC ==="
if [ $NEXUSQSETUP_RC -eq 0 ]; then
    # pkgrel-EXACT (see the nexusqd note above): avoid exporting a stale
    # nexusq-setupd-...-rN.apk from the persistent work-volume repo.
    _nqs_pv=$(sed -n 's/^pkgver=//p' "$SRC/pmos/nexusq-setupd/APKBUILD" | head -1)
    _nqs_pr=$(sed -n 's/^pkgrel=//p' "$SRC/pmos/nexusq-setupd/APKBUILD" | head -1)
    NEXUSQSETUP_APK=$(find "$WORK/packages" -name "nexusq-setupd-${_nqs_pv}-r${_nqs_pr}.apk" -print -quit 2>/dev/null)
    if [ -n "$NEXUSQSETUP_APK" ]; then
        cp "$NEXUSQSETUP_APK" /tmp/output/ && echo "  Exported: $(basename "$NEXUSQSETUP_APK")"
    else
        echo "  WARNING: nexusq-setupd apk built but not found under $WORK/packages"
    fi
else
    echo "  WARNING: nexusq-setupd build failed -- key log lines:"
    grep -n "ERROR\|error:\|FAILED" "$WORK/log.txt" 2>/dev/null | tail -30
fi

echo ""
echo "=== Phase 7c5: Build nexusq-mqtt package (noarch) ==="
set +e
# Pure-Python (stdlib-only) MQTT health telemetry publisher; noarch.
# Checksums: 7b. device-google-steelhead `depends=` this package, so before 7b
# covered everything, building the device package first would drag this one in
# unchecksummed and fail the run (2026-08-13, the OTA path).
pmbootstrap --no-cross build nexusq-mqtt --arch armv7 --force 2>&1
NEXUSQMQTT_RC=$?
set -e
echo "=== nexusq-mqtt build exit code: $NEXUSQMQTT_RC ==="
if [ $NEXUSQMQTT_RC -eq 0 ]; then
    # pkgrel-EXACT (see the nexusqd note above): avoid exporting a stale
    # nexusq-mqtt-...-rN.apk from the persistent work-volume repo.
    _nqm_pv=$(sed -n 's/^pkgver=//p' "$SRC/pmos/nexusq-mqtt/APKBUILD" | head -1)
    _nqm_pr=$(sed -n 's/^pkgrel=//p' "$SRC/pmos/nexusq-mqtt/APKBUILD" | head -1)
    NEXUSQMQTT_APK=$(find "$WORK/packages" -name "nexusq-mqtt-${_nqm_pv}-r${_nqm_pr}.apk" -print -quit 2>/dev/null)
    if [ -n "$NEXUSQMQTT_APK" ]; then
        cp "$NEXUSQMQTT_APK" /tmp/output/ && echo "  Exported: $(basename "$NEXUSQMQTT_APK")"
    else
        echo "  WARNING: nexusq-mqtt apk built but not found under $WORK/packages"
    fi
else
    echo "  WARNING: nexusq-mqtt build failed -- key log lines:"
    grep -n "ERROR\|error:\|FAILED" "$WORK/log.txt" 2>/dev/null | tail -30
fi

echo ""

echo ""
echo "=== Phase 8: Build all packages ==="
echo "Running: pmbootstrap --no-cross build firmware-google-steelhead device-google-steelhead"
# firmware-google-steelhead must be built EXPLICITLY. It is a SEPARATE aport that
# nothing build-depends on: it is only a *runtime* depend of the
# device-google-steelhead-nonfree-firmware SUBPACKAGE. So `build device-google-steelhead`
# builds the device pkg + its subpackages (incl. ...-nonfree-firmware) but never
# compiles firmware-google-steelhead itself. On a WARM nexusq-workdir it was already
# cached from an earlier run, hiding this; a COLD build (fresh volume) then fails at
# Phase 9 install with "firmware-google-steelhead (no such package): required by
# device-google-steelhead-nonfree-firmware". Build it here so cold builds work too.
# --force: defeat the persistent nexusq-workdir cache. pkgver/pkgrel may collide
# with a previously-built apk in the work volume; without --force pmbootstrap can
# skip the rebuild and reuse a stale kernel/DTB (this is exactly how build #1
# shipped the pre-fix DTB). Force a rebuild so the current patches always apply.
set +e
pmbootstrap --no-cross build --force firmware-google-steelhead device-google-steelhead 2>&1
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
    # A failed package build MUST abort the pipeline with a nonzero exit —
    # falling through used to reach "=== BUILD COMPLETE ===" and exit 0,
    # masking the failure from any caller that (correctly) trusts the rc.
    exit 1
fi

if [ $BUILD_RC -eq 0 ]; then
    echo ""
    echo "=== Phase 8b: Pre-build systemd (avoid a mid-install build+zap) ==="
    # ROOT CAUSE of the "chroot: cannot change root directory to
    # '.../chroot_native': No such file or directory" (exit 125) failure at
    # Phase 9 "PREPARE INSTALL BLOCKDEVICE" (mkdir -p /home/pmos/rootfs):
    #
    # `pmbootstrap install` resolves the full rootfs dependency closure and, if
    # ANY package in it is not already cached in the work-volume repo, builds it
    # inline. pmbootstrap's inline `pmb build` finishes with a STRICT-mode zap
    # ("Zapping buildroots ...") that does `rm -rf .../chroot_native`. When that
    # build happens MID-install (after install has already created chroot_native
    # in its "(1/4) PREPARE NATIVE CHROOT" step), the zap deletes the very
    # chroot_native that install's next step (blockdevice create -> chroot mkdir)
    # relies on -> exit 125, install aborts.
    #
    # This is invisible on a warm volume where every dep is already cached, but
    # bites whenever upstream pmaports bumps a base package: on 2026-07-08 the
    # systemd-edge channel moved systemd to 261.1-r2, so install compiled systemd
    # (20 min) and the post-build strict zap nuked chroot_native.
    #
    # The durable fix is to pre-build the heavy base package(s) HERE, before
    # install: this build's own post-build zap only removes chroot_native while
    # NOTHING needs it (install re-creates it fresh in step 1/4), and by the time
    # install runs the systemd apk is cached, so install builds nothing and its
    # chroot_native survives to the blockdevice step. No --force: a warm volume
    # with systemd already cached skips this in seconds; it only compiles when
    # pmaports actually bumped systemd.
    # --arch armv7 is REQUIRED: systemd is a generic aport (not a device aport),
    # so a bare `build systemd` would default to the native x86_64 arch (install
    # x86_64 makedepends into chroot_native -> apk exit 13) and build the WRONG
    # arch. install needs the armv7 systemd, exactly like the python3 override
    # (Phase 7d) which also passes --arch armv7. No --force here: warm volumes
    # with the armv7 systemd apk already cached skip the compile.
    set +e
    pmbootstrap --no-cross build systemd --arch armv7 2>&1
    SYSTEMD_RC=$?
    set -e
    echo "=== systemd pre-build exit code: $SYSTEMD_RC ==="
    if [ $SYSTEMD_RC -ne 0 ]; then
        echo "=== systemd PRE-BUILD FAILED (exit $SYSTEMD_RC) ==="
        tail -80 "$WORK/log.txt" 2>/dev/null
        exit 1
    fi

    echo ""
    echo "=== Phase 9: Install image ==="
    set +e
    # Start the rootfs install from a CLEAN chroot. ROOT CAUSE of the
    # "etc/apk/commit_hooks.d/postmarketos-base-systemd: can't create
    # /var/lib/systemd-apk/installed.units: Permission denied" install failure:
    #
    # pmbootstrap builds chroot_rootfs_google-steelhead as a real root filesystem
    # — apk (run via sudo, as root) extracts packages preserving their intended
    # per-file ownership (root + a handful of system uids). The systemd base
    # package's apk pre-commit hook then runs (as root) and writes the unit list
    # to /var/lib/systemd-apk/installed.units. On a FRESH chroot that all works.
    #
    # But on a *reused* nexusq-workdir volume a stale rootfs chroot from a prior
    # run persists, and the broad `sudo chown -R pmos:pmos /home/pmos` in Phase 5
    # has flattened every file in it to uid 1000 (mode 0644). The hook can no
    # longer truncate the pre-existing uid-1000 installed.units -> "Permission
    # denied" -> the hook exits 1 -> apk add postmarketos-base-systemd fails (99)
    # -> install aborts. (A blanket chown back to root is NOT correct — a real
    # rootfs legitimately has non-root system uids — so the only clean fix is to
    # let pmbootstrap rebuild the rootfs from scratch.) Cold builds never hit this
    # because no stale rootfs chroot exists; this only bites warm-volume rebuilds,
    # and only since the systemd switch (the old OpenRC postmarketos-base shipped
    # no such commit hook). Remove the stale rootfs chroot so `install` recreates
    # it clean with correct ownership; packages live in $WORK/packages, so nothing
    # is recompiled.
    sudo rm -rf /home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead
    echo "  Removed stale rootfs chroot (forces a clean, root-owned rebuild)"
    # pmbootstrap-in-Docker uid drift: the native chroot's `pmos` user is uid 12345
    # (pmbootstrap's sandbox uid) while its /home/pmos is owned by 1000, so the install
    # step `mkdir -p /home/pmos/rootfs` (run as pmos) fails with EPERM. The chroot is
    # fully built by now and `install` only adds packages into it, so re-aligning the
    # ownership here sticks through the mkdir. (A pre-build chown does NOT survive --
    # Phase 5/8 re-create the native chroot and reset it back to 1000.)
    sudo chown 12345:12345 /home/pmos/.local/var/pmbootstrap/chroot_native/home/pmos 2>/dev/null || true
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

        # pmbootstrap bundles a ~7.6 MB pmOS initramfs into boot/boot.img and points
        # its cmdline at the root by UUID. But the Nexus Q boots RAMDISK-LESS: the
        # kernel mounts the ext4 rootfs directly via its built-in CONFIG_CMDLINE
        # (root=/dev/mmcblk0p13, forced by CONFIG_CMDLINE_FORCE=y), so the initramfs is
        # dead weight -- and a 12.6 MB boot.img does NOT fit the 8 MB boot partition
        # (fastboot: "Writing 'boot' FAILED! error=-27"). Re-pack the SAME kernel
        # (zImage + appended DTB, lifted verbatim out of pmbootstrap's boot.img so it is
        # byte-for-byte the kernel that was just built) into a ramdisk-less Android boot
        # image with the authoritative defconfig cmdline, via the project's own
        # make-bootimg.py (which also hard-guards the 8 MB ceiling).
        PM_BOOTIMG="$ROOTFS/boot/boot.img"
        BOOT_CMDLINE=$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "$SRC/kernel/configs/steelhead_defconfig")
        python3 - "$PM_BOOTIMG" /tmp/zImage-dtb <<'PYEOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
if d[:8] != b'ANDROID!':
    sys.exit(f"ERROR: {sys.argv[1]} is not an Android boot image (magic={d[:8]!r})")
ks, ka, rs, ra, ss, sa, tags, ps = struct.unpack('<8I', d[8:40])
open(sys.argv[2], 'wb').write(d[ps:ps + ks])   # kernel = zImage+DTB, starts at page 1
print(f"  pmOS boot.img: kernel={ks} B, ramdisk={rs} B (initramfs dropped for ramdisk-less boot)")
PYEOF
        python3 "$SRC/make-bootimg.py" /tmp/zImage-dtb /tmp/output/boot.img - "$BOOT_CMDLINE" \
            && echo "  Exported: boot.img (ramdisk-less, fits 8 MB boot partition)"

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

        # The Nexus Q boots RAMDISK-LESS from a single flashed partition
        # (root=/dev/mmcblk0p13) — we flash ONLY this rootfs partition to userdata,
        # never pmbootstrap's two-partition disk. But pmbootstrap still generates an
        # /etc/fstab with a `/boot` entry (the disk's boot partition, by UUID) that
        # does NOT exist on the device. systemd then times out on
        # /dev/disk/by-uuid/<boot> → "Dependency failed for /boot" →
        # "Dependency failed for Local File Systems" → it drops to emergency.target,
        # and because root is locked, "Cannot open access to console". (OpenRC just
        # logged the failed mount and continued — that's why it "booted" before.)
        # Fix: strip the /boot line from fstab; also unlock root with the same
        # password as `user` so the ACM serial console + emergency mode are usable.
        # NOTE: this whole block runs as the unprivileged `pmos` user, but losetup,
        # mount, and editing the root-owned /etc/fstab + /etc/shadow all need root —
        # so each privileged step is run via sudo (passwordless in this image). This
        # was a latent bug: every prior build failed earlier (at the fakeroot hang),
        # so Phase 10 post-processing never actually ran until that was fixed.
        echo "  Post-processing rootfs (strip /boot fstab entry, unlock root)..."
        RP_LOOP=$(sudo losetup -f --show /tmp/output/google-steelhead.img)
        RP_MNT=$(mktemp -d)
        sudo mount "$RP_LOOP" "$RP_MNT"
        # SHIP GATE: the definitive integrity check. Gate the ACTUAL libpython that
        # will ship in this rootfs (not just the Phase 7d apk) -- this catches a stale
        # or raced apk slipping into the install, the exact failure that flashed a
        # crashing python earlier. If it is qemu-corrupted, refuse to emit a flashable
        # image. See scripts/verify-libpython-clean.py + the qemu-user-corrupts note.
        SHIP_LIBPY="$RP_MNT/usr/lib/libpython3.14.so.1.0"
        # PROVENANCE FIRST, then integrity. The 2026-08-17 cold build shipped a
        # python nobody had chosen: our override went inert when Alpine moved to
        # 3.14.7 (apk compares pkgver before pkgrel) and the gate still said PASS,
        # because it checks the FILE and never asked where it came from. Say out
        # loud which python3 is actually in the rootfs, every build.
        # RS="" reads apk's db one PACKAGE per record; FS="\n" then makes each
        # field a line, so "P:" and "V:" can be compared exactly. (Matching
        # /^P:python3$/ in paragraph mode does NOT work -- ^ and $ anchor to the
        # whole record, not to a line, so it silently never matches.)
        _ship_py="$(sudo awk -v RS="" -v FS="\n" '
            { pkg = ""; ver = ""
              for (i = 1; i <= NF; i++) {
                  if ($i == "P:python3")            pkg = 1
                  else if (substr($i, 1, 2) == "V:") ver = substr($i, 3)
              }
              if (pkg && ver) { print ver; exit } }' \
            "$RP_MNT/lib/apk/db/installed" 2>/dev/null)"
        echo "  SHIP GATE: rootfs python3 = ${_ship_py:-<not installed>}"
        if [ -f "$SHIP_LIBPY" ]; then
            if python3 "$SRC/scripts/verify-libpython-clean.py" "$SHIP_LIBPY"; then
                echo "  SHIP GATE: installed libpython is clean."
            else
                echo "  SHIP GATE FAILED: the rootfs libpython is qemu-corrupted --"
                echo "  refusing to emit a flashable image. Re-run the build."
                sync; sudo umount "$RP_MNT"; sudo losetup -d "$RP_LOOP"; rmdir "$RP_MNT"
                exit 1
            fi
        else
            # Not a warning: nexusq-control, nexusq-mqtt, nexusq-btagent and
            # nexusq-nfc are all stdlib-python daemons. An image without python3
            # is an image whose companion bridge, telemetry, pairing agent and NFC
            # reader are all dead -- do not let that reach a flash.
            echo "  SHIP GATE FAILED: no $SHIP_LIBPY in the rootfs -- python3 is"
            echo "  missing, which kills control/mqtt/btagent/nfc. Refusing to emit"
            echo "  a flashable image."
            sync; sudo umount "$RP_MNT"; sudo losetup -d "$RP_LOOP"; rmdir "$RP_MNT"
            exit 1
        fi
        sudo sed -i '/[[:space:]]\/boot[[:space:]]/d' "$RP_MNT/etc/fstab"
        sudo python3 - "$RP_MNT/etc/shadow" <<'PYEOF'
import sys
lines = open(sys.argv[1]).read().splitlines()
uhash = next(l.split(":")[1] for l in lines if l.startswith("user:"))
out = []
for l in lines:
    f = l.split(":")
    if f and f[0] == "root":
        f[1] = uhash            # unlock root, same password as `user` (147147)
        l = ":".join(f)
    out.append(l)
open(sys.argv[1], "w").write("\n".join(out) + "\n")
PYEOF
        # Populate the shipped rootfs /boot with the kernel payload (vmlinuz +
        # dtbs). We export ONLY the rootfs partition from pmbootstrap's two-part
        # disk; the kernel apk installs its /boot to the disk's SEPARATE /boot
        # partition, which we never flash -> the shipped rootfs /boot is EMPTY.
        # On-device that makes the `postmarketos-mkinitfs` trigger fail on EVERY
        # apk transaction: it runs boot-deploy, whose get_kernel aborts with
        # "No kernel found in /boot" (exit 1) -> the app reports "system update
        # failed". Packages still install and NOTHING is flashed (boot-deploy's
        # flash_updated_boot_parts is gated on deviceinfo_flash_kernel_on_update,
        # which is unset), but the pending trigger re-fails forever. Copy the
        # kernel's /boot payload from the build chroot ($ROOTFS/boot, which has
        # it) so the trigger succeeds. The boot.img boot-deploy then generates in
        # /boot is INERT -- the Q boots ramdisk-less from the flashed p9 (see
        # make-bootimg.py), never from /boot. See
        # docs/2026-08-08-system-ota-mkinitfs-trigger-failure.md.
        if [ -f "$ROOTFS/boot/vmlinuz" ]; then
            sudo cp -a "$ROOTFS/boot/vmlinuz" "$RP_MNT/boot/"
            [ -d "$ROOTFS/boot/dtbs" ] && sudo cp -a "$ROOTFS/boot/dtbs" "$RP_MNT/boot/"
            for _bf in System.map config; do
                [ -f "$ROOTFS/boot/$_bf" ] && sudo cp -a "$ROOTFS/boot/$_bf" "$RP_MNT/boot/"
            done
            echo "  Populated rootfs /boot with the kernel payload (vmlinuz + dtbs) so the mkinitfs trigger succeeds on-device"
        else
            echo "  WARNING: $ROOTFS/boot/vmlinuz not found -- shipped /boot stays EMPTY, the mkinitfs trigger WILL fail on-device"
        fi
        sync
        sudo umount "$RP_MNT"; sudo losetup -d "$RP_LOOP"; rmdir "$RP_MNT"
        echo "  Rootfs post-processed: /boot fstab entry dropped, root unlocked, /boot kernel payload restored"

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
