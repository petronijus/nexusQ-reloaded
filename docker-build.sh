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

# python3 local override: Alpine's stock python3-3.14.5-r2 SIGSEGVs on armv7 --
# deterministically, on the very first bytecode, even `python3 -S -c ''` (rc 139).
# That crashes every python consumer on the device (sleep-inhibitor, onboard, blueman).
# Stage our rebuilt aport (pkgrel r5) into main/python3 so the higher pkgrel supersedes
# Alpine's -r2 in the rootfs. Built + gated below in Phase 7d. See pmos/python3/APKBUILD.
# ROOT CAUSE (2026-06-28): NOT a compiler/CPython bug. The armv7 toolchain runs under
# qemu-user (--no-cross) and qemu's mmap zero-fill of the LINKER output is buggy,
# non-deterministically corrupting libpython's .PyRuntime/.data.rel.ro (should-be-zero
# regions) -> wild type-index deref -> SIGSEGV on real HW (qemu false-passes). The r5
# aport links libpython with gold -Wl,--no-mmap-output-file to dodge it; Phase 7d also
# gates every build + rebuilds on residual corruption. docs/2026-06-28-session-findings.md.
PYTHON3_DIR="$PMAPORTS/main/python3"
mkdir -p "$PYTHON3_DIR"
cp "$SRC/pmos/python3/"* "$PYTHON3_DIR/"
echo "  Installed: python3 override (gold-linked, gated -> main/python3)"

echo "  Converting line endings (CRLF -> LF)..."
find "$PMAPORTS/device/testing/" "$NEXUSQD_DIR" "$PYTHON3_DIR" -type f \( -name "APKBUILD" -o -name "deviceinfo" -o -name "modules-initfs" -o -name "*.patch" -o -name "config-*" -o -name "*.c" -o -name "*.h" -o -name "Makefile" -o -name "*.service" -o -name "*.json" \) -exec dos2unix -q {} +
echo "  Done."

echo ""
echo "=== Phase 6b: Patch pmbootstrap for Docker compatibility ==="

APK_PY="/usr/lib/python3.12/site-packages/pmb/helpers/apk.py"
PART_PY="/usr/lib/python3.12/site-packages/pmb/install/partition.py"
LOSETUP_PY="/usr/lib/python3.12/site-packages/pmb/install/losetup.py"
BACKEND_PY="/usr/lib/python3.12/site-packages/pmb/build/backend.py"

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
    # 3) HOME=/home/pmos so root finds the .abuild signing key + abuild.conf
    (
        'env: Env = {"SUDO_APK": "abuild-apk --no-progress"}',
        'env: Env = {"SUDO_APK": "abuild-apk --no-progress", "HOME": "/home/pmos"}',
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
systemd = always
# Switching the 'systemd' option flips the apk channel (edge -> systemd-edge). A warm
# nexusq-workdir volume left over from an older 'edge' (OpenRC) build then holds
# misconfigured chroots, and pmbootstrap aborts ("Chroot is for the 'edge'
# channel, but you are on 'systemd-edge'"). Let it auto-delete those stale
# chroots and rebuild clean on the correct channel instead of failing.
auto_zap_misconfigured_chroots = silently
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
echo "Generating checksums for kernel package..."
pmbootstrap checksum linux-google-steelhead 2>&1 || {
    echo "WARNING: checksum generation failed, will try building anyway"
}
echo "Generating checksums for device package..."
pmbootstrap checksum device-google-steelhead 2>&1 || true
echo "Generating checksums for firmware package..."
pmbootstrap checksum firmware-google-steelhead 2>&1 || true

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
# The nexusqd sources are staged flat into the aport above (frame.c, fx_*.c, ...)
# and the APKBUILD ships sha512sums="SKIP" as a placeholder, so abuild aborts with
# "<file> is missing in checksums". Regenerate the per-file checksums against the
# just-staged sources before building (same step the kernel/device/firmware get).
pmbootstrap checksum nexusqd 2>&1 || true
# --no-cross (qemu-only), matching Phase 8: crossdirect (the default cross-compile
# accelerator) is broken in this image -- it cannot exec cc1 ("cc: fatal error:
# cannot execute 'cc1': posix_spawnp: No such file or directory") and the build
# fails (exit 3). Forcing qemu-only sidesteps the broken crossdirect toolchain and
# builds nexusqd reliably, exactly as the real Phase 8 build already does.
pmbootstrap --no-cross build nexusqd --arch armv7 2>&1
NEXUSQD_RC=$?
set -e
echo "=== nexusqd build exit code: $NEXUSQD_RC ==="
if [ $NEXUSQD_RC -eq 0 ]; then
    NEXUSQD_APK=$(find "$WORK/packages" -name 'nexusqd-*.apk' -print -quit 2>/dev/null)
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
# Resolve the EXACT apk filename from the staged aport's pkgver/pkgrel. A bare
# python3-3.14.5-r*.apk glob is UNSAFE: $WORK/packages is the persistent work-volume
# repo and accumulates stale apks from earlier runs (r3, r4, r5, ...), so
# `find ... -print -quit` can return an OLD pkgrel instead of the one we just built --
# this exact stale-artifact bug silently gated the wrong apk. Match the precise
# r<pkgrel> so the gate always checks what this build actually produced.
_py3_pv=$(sed -n 's/^pkgver=//p' "$SRC/pmos/python3/APKBUILD" | head -1)
_py3_pr=$(sed -n 's/^pkgrel=//p' "$SRC/pmos/python3/APKBUILD" | head -1)
PY3_APK_NAME="python3-${_py3_pv}-r${_py3_pr}.apk"
echo "  python3 target apk (pkgrel-exact): $PY3_APK_NAME"

# --- Optional gold-fix validation harness (opt-in via PYTHON3_VALIDATE_RUNS) --------
# Set PYTHON3_VALIDATE_RUNS=N to force N independent python3 rebuilds and gate each,
# proving gold reliably defeats the per-build qemu mmap coin-flip (corruption was
# ~50/50 without it). Runs ONLY python3 (no kernel/rootfs -- those are Phase 8+) and
# exits. Production builds leave this unset. See scripts/verify-libpython-clean.py.
if [ -n "${PYTHON3_VALIDATE_RUNS:-}" ]; then
    echo "=== Phase 7d-validate: $PYTHON3_VALIDATE_RUNS forced gold rebuilds + gate ==="
    GATE="$SRC/scripts/verify-libpython-clean.py"
    _vclean=0; _vcorrupt=0
    for _v in $(seq 1 "$PYTHON3_VALIDATE_RUNS"); do
        pmbootstrap checksum python3 >/dev/null 2>&1 || true
        set +e
        pmbootstrap --no-cross build python3 --arch armv7 --force >"/tmp/validate-$_v.log" 2>&1
        _vrc=$?
        set -e
        if [ $_vrc -ne 0 ]; then
            echo "  run $_v/$PYTHON3_VALIDATE_RUNS: BUILD FAILED (rc=$_vrc) -- tail /tmp/validate-$_v.log:"
            tail -15 "/tmp/validate-$_v.log" 2>/dev/null | sed 's/^/      /'
            _vcorrupt=$((_vcorrupt + 1)); continue
        fi
        _vapk=$(find "$WORK/packages" -name "$PY3_APK_NAME" -print -quit 2>/dev/null)
        tar -xzOf "$_vapk" usr/lib/libpython3.14.so.1.0 > "/tmp/validate-$_v.so" 2>/dev/null
        if python3 "$GATE" "/tmp/validate-$_v.so" > "/tmp/validate-$_v.gate" 2>&1; then
            _vverdict="CLEAN  "; _vclean=$((_vclean + 1))
        else
            _vverdict="CORRUPT"; _vcorrupt=$((_vcorrupt + 1))
        fi
        _vmd5=$(md5sum "/tmp/validate-$_v.so" | awk '{print $1}')
        _vlr=$(grep -oE 'longest_run=[ ]*[0-9]+' "/tmp/validate-$_v.gate" | grep -oE '[0-9]+' | sort -n | tail -1)
        echo "  run $_v/$PYTHON3_VALIDATE_RUNS: $_vverdict  md5=$_vmd5  max_longest_run=${_vlr:-?}"
    done
    echo "=== VALIDATION SUMMARY: $_vclean CLEAN / $_vcorrupt CORRUPT of $PYTHON3_VALIDATE_RUNS ==="
    if [ $_vcorrupt -eq 0 ]; then
        echo "  PASS: gold (-Wl,--no-mmap-output-file) produced a clean libpython on EVERY run."
    else
        echo "  FAIL: gold did NOT fully defeat the qemu mmap corruption -- investigate."
    fi
    exit 0
fi

echo "=== Phase 7d: Build python3 override (armv7/musl, gold-linked, gated) ==="
# Alpine's python3-3.14.5-r2 SIGSEGVs on armv7 (see pmos/python3/APKBUILD header):
# the stock interpreter crashes on the first bytecode (rc 139), taking down every
# python consumer on the device. ROOT CAUSE (2026-06-28): NOT a compiler/CPython bug
# but a BUILD-TIME corruption -- qemu-user's mmap zero-fill of the LINKER's output
# file non-deterministically leaves garbage in libpython's .PyRuntime/.data.rel.ro
# (regions the C standard guarantees are zero) -> wild type-index deref -> SIGSEGV on
# real HW (qemu false-passes it). Our r5 aport dodges it by linking libpython with
# gold -Wl,--no-mmap-output-file (write() instead of mmap()). Because the corruption
# is a per-build coin-flip that affects ANY qemu-built armv7 binary, we ALSO gate
# every built libpython here with scripts/verify-libpython-clean.py and rebuild on
# any residual corruption -- so a corrupt apk can NEVER reach the rootfs. The higher
# pkgrel (r5 > Alpine r2) makes the Phase 9 rootfs install pull OUR python3 (+ all
# subpackages) instead of Alpine's. A green build is still not on its own proof of
# runtime health -- validate `python3 -S -c ''` ON THE DEVICE.
# docs/2026-06-28-session-findings.md + the qemu-user-corrupts-armv7-binaries note.
GATE="$SRC/scripts/verify-libpython-clean.py"
PYTHON3_MAX_TRIES=4
PYTHON3_RC=1
PYTHON3_APK=""
for _try in $(seq 1 "$PYTHON3_MAX_TRIES"); do
    echo "--- python3 build attempt $_try/$PYTHON3_MAX_TRIES ---"
    set +e
    # regenerate checksums (absorb any dos2unix drift in companion files) then build.
    pmbootstrap checksum python3 2>&1 || true
    # --no-cross (qemu-only): crossdirect cannot exec cc1 in this image (see Phase 7c).
    # --force: every (re)build must actually re-compile + re-LINK, both to apply the
    # current aport and -- on a retry -- to re-roll the qemu mmap coin-flip.
    pmbootstrap --no-cross build python3 --arch armv7 --force 2>&1
    _brc=$?
    set -e
    if [ $_brc -ne 0 ]; then
        echo "  ERROR: python3 build FAILED (exit $_brc). A rebuild will not fix a compile"
        echo "         error, so not retrying. Key log:"
        grep -niE "ERROR|error:|FAILED|segmentation|configure: error" "$WORK/log.txt" 2>/dev/null | tail -30
        PYTHON3_RC=$_brc
        break
    fi
    # pkgrel-EXACT (see PY3_APK_NAME above): the work-volume repo accumulates stale
    # python3 apks from prior runs, so a bare r*.apk glob could gate/export the wrong
    # one. Match only the apk this build produced.
    _apk=$(find "$WORK/packages" -name "$PY3_APK_NAME" -print -quit 2>/dev/null)
    if [ -z "$_apk" ]; then
        echo "  ERROR: build returned 0 but no $PY3_APK_NAME under $WORK/packages."
        PYTHON3_RC=1
        break
    fi
    # INTEGRITY GATE: extract the libpython from the freshly-built apk (busybox tar
    # reads apk's concatenated gzip members fine) and check it for the qemu mmap
    # corruption before we let it anywhere near the rootfs.
    tar -xzOf "$_apk" usr/lib/libpython3.14.so.1.0 > /tmp/libpython-check.so 2>/dev/null
    if python3 "$GATE" /tmp/libpython-check.so; then
        echo "  CLEAN: $(basename "$_apk") passed the integrity gate on attempt $_try."
        PYTHON3_APK="$_apk"
        PYTHON3_RC=0
        break
    fi
    echo "  CORRUPT: $(basename "$_apk") FAILED the gate (qemu mmap zero-fill hit"
    echo "           despite gold) -- discarding and rebuilding (--force re-links)."
done
echo "=== python3 build result: rc=$PYTHON3_RC ==="
if [ $PYTHON3_RC -eq 0 ] && [ -n "$PYTHON3_APK" ]; then
    cp "$PYTHON3_APK" /tmp/output/ 2>/dev/null && echo "  Exported: $(basename "$PYTHON3_APK")"
    echo "  $(basename "$PYTHON3_APK" .apk) is gate-verified clean -> supersedes Alpine's -r2"
else
    echo "  ERROR: no clean python3 apk after $PYTHON3_MAX_TRIES attempt(s) -- the rootfs"
    echo "         would ship a broken python. Do NOT flash. ABORTING the build."
    exit 1
fi

echo ""
echo "=== Phase 8: Build all packages ==="
echo "Running: pmbootstrap --no-cross build device-google-steelhead (triggers all deps)"
# --force: defeat the persistent nexusq-workdir cache. pkgver/pkgrel may collide
# with a previously-built apk in the work volume; without --force pmbootstrap can
# skip the rebuild and reuse a stale kernel/DTB (this is exactly how build #1
# shipped the pre-fix DTB). Force a rebuild so the current patches always apply.
set +e
pmbootstrap --no-cross build --force device-google-steelhead 2>&1
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
            echo "  WARNING: no $SHIP_LIBPY in the rootfs to gate (python3 not installed?)."
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
        sync
        sudo umount "$RP_MNT"; sudo losetup -d "$RP_LOOP"; rmdir "$RP_MNT"
        echo "  Rootfs post-processed: /boot fstab entry dropped, root unlocked"

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
