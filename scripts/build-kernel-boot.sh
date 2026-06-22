#!/bin/bash
# build-kernel-boot.sh -- rebuild ONLY the linux-google-steelhead kernel apk and
# repack a kernel-only boot.img (zImage + appended DTB, no ramdisk), reusing the
# warm pmbootstrap workdir volume (toolchain + chroots + ccache from a prior
# docker-build.sh run). Skips the full rootfs build/install (phases 9-10): the
# rootfs already lives on the device's userdata partition, so kernel iteration
# only needs a fresh boot.img.
#
# This mirrors docker-build.sh phases 5/6/6b/7 + the extract-and-repack repack,
# and follows build-nexusqd-only.sh's "reuse warm volume" rules (no chown -R
# /home/pmos, which would break the chroots).
#
# Run the same way as docker-build.sh / build-nexusqd-only.sh:
#   docker run --rm --privileged -v "${PWD}:/src:ro" \
#       -v nexusq-output:/tmp/output -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap \
#       nexusq-builder /src/scripts/build-kernel-boot.sh [out-name.img]
#
# Output: /tmp/output/<out-name.img> (default boot-smp-test.img), plus the raw
# vmlinuz + dtb alongside it. Extract from the nexusq-output volume afterwards.
set -euo pipefail
SRC="/src"
OUT_NAME="${1:-boot-smp-test.img}"

echo "=== Phase 5: Initialize pmbootstrap ==="
export XDG_CONFIG_HOME=/home/pmos/.config
export XDG_DATA_HOME=/home/pmos/.local/share
export XDG_CACHE_HOME=/home/pmos/.cache
# Do NOT chown -R /home/pmos on a reused volume (breaks chroot /bin/sh perms);
# see build-nexusqd-only.sh for the rationale.
sudo mkdir -p /home/pmos/.local/var/pmbootstrap
echo "pmbootstrap version: $(pmbootstrap --version)"

PMAPORTS="/home/pmos/pmaports"
if [ ! -d "$PMAPORTS" ]; then
    echo "Cloning pmaports..."
    git clone --depth=1 https://gitlab.postmarketos.org/postmarketOS/pmaports.git "$PMAPORTS" 2>&1 | tail -3
fi
# master->main alias (pmbootstrap reads channels.cfg from origin/master)
if git -C "$PMAPORTS" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    git -C "$PMAPORTS" update-ref refs/remotes/origin/master refs/remotes/origin/main
fi
export PMB_CHANNELS_CFG="$PMAPORTS/channels.cfg"

echo "=== Phase 6: Install device + kernel package into pmaports ==="
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
find "$PMAPORTS/device/testing/" -type f \( -name "APKBUILD" -o -name "deviceinfo" \
    -o -name "modules-initfs" -o -name "*.patch" -o -name "config-*" \) \
    -exec dos2unix -q {} + 2>/dev/null || true
echo "  staged kernel aport (config + $(ls "$SRC"/kernel/patches/*.patch | wc -l) patches)"

echo "=== Phase 6b: Patch pmbootstrap apk.py (tolerate chroot socket errors) ==="
sudo python3 - <<'PATCH_APK'
path = "/usr/lib/python3.12/site-packages/pmb/helpers/apk.py"
with open(path) as f: content = f.read()
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
    open(path,"w").write(content.replace(old,new)); print("  patched apk.py")
else: print("  apk.py already patched / pattern changed")
PATCH_APK

echo "=== Phase 7: pmbootstrap config ==="
WORK="/home/pmos/.local/var/pmbootstrap"
mkdir -p "$XDG_CONFIG_HOME" "$WORK"
echo "8" > "$WORK/version"
cat > "$XDG_CONFIG_HOME/pmbootstrap_v3.cfg" <<CFGEOF
[pmbootstrap]
aports = $PMAPORTS
work = $WORK
device = google-steelhead
ui = weston
build_pkgs_on_install = True
hostname = steelhead
is_default_channel = True
build_default_device_arch = False
ccache_size = 5G
jobs = $(nproc)
kernel = stable
locale = en_US.UTF-8
ssh_keys = False
sudo_timer = False
systemd = default
timezone = GMT
user = user
[providers]
[mirrors]
alpine = http://dl-cdn.alpinelinux.org/alpine/
pmaports = http://mirror.postmarketos.org/postmarketos/
systemd = http://mirror.postmarketos.org/postmarketos/extra-repos/systemd/
CFGEOF
pmbootstrap config device 2>&1 || true

echo "=== Phase 7b: Zap chroots (clean recreate; keeps built pkgs + ccache) ==="
pmbootstrap -y zap 2>&1 | tail -3 || true

echo "=== Phase 7a: Fix abuild REPODEST ownership on the work volume ==="
sudo mkdir -p "$WORK/packages"
sudo chown -R 12345:12345 "$WORK/packages"
# ccache dir must also be writable by the chroot abuild uid (docker-build Phase 7a)
[ -d "$WORK/cache_ccache_armv7" ] && sudo chown -R 12345:12345 "$WORK/cache_ccache_armv7" || true

echo "=== Phase 8: Build linux-google-steelhead (armv7) ==="
sudo mkdir -p /tmp/output && sudo chown pmos:pmos /tmp/output
pmbootstrap checksum linux-google-steelhead 2>&1 || true
set +e
pmbootstrap build linux-google-steelhead --arch armv7 --force 2>&1
RC=$?
set -e
echo "=== kernel build exit: $RC ==="
if [ $RC -ne 0 ]; then
    echo "--- key error lines ---"
    grep -n "ERROR\|error:\|FAILED" "$WORK/log.txt" 2>/dev/null | tail -25
    exit $RC
fi

echo "=== Phase 9: Repack kernel-only boot.img from the built apk ==="
# abuild cleans the pkgdir after creating the .apk, so extract vmlinuz + dtb
# straight from the freshly built package instead of the (now empty) pkgdir.
APK=$(ls -t "$WORK"/packages/*/armv7/linux-google-steelhead-*.apk 2>/dev/null | head -1)
[ -n "$APK" ] || { echo "no linux-google-steelhead apk under $WORK/packages"; exit 1; }
echo "  apk: $APK"
EX=/tmp/kapk; rm -rf "$EX"; mkdir -p "$EX"
tar xzf "$APK" -C "$EX" boot/vmlinuz boot/dtbs/omap4-steelhead.dtb 2>/dev/null
VM="$EX/boot/vmlinuz"
DTB="$EX/boot/dtbs/omap4-steelhead.dtb"
[ -f "$VM" ]  || { echo "missing vmlinuz in apk"; tar tzf "$APK" | grep -i vmlinuz; exit 1; }
[ -f "$DTB" ] || { echo "missing dtb in apk"; tar tzf "$APK" | grep -i steelhead.dtb; exit 1; }

# Authoritative cmdline read straight from the staged defconfig CONFIG_CMDLINE.
# NOTE: CONFIG_CMDLINE_FORCE=y, so the kernel uses its built-in cmdline regardless
# of what we bake here -- this value is cosmetic but kept in sync for clarity.
CMDLINE=$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "$SRC/kernel/configs/steelhead_defconfig")
echo "  cmdline: $CMDLINE"

echo "=== CPU-node sanity in built DTB (expect cpu@0 AND cpu@1 for SMP) ==="
dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -nE "cpu@[0-9]" || echo "  (no cpu@ match!)"

echo "=== sizes ==="
echo "  vmlinuz: $(stat -c%s "$VM") bytes   dtb: $(stat -c%s "$DTB") bytes"
cat "$VM" "$DTB" > /tmp/zImage-dtb
ZDTB=$(stat -c%s /tmp/zImage-dtb)
echo "  zImage+DTB: $ZDTB bytes ($((ZDTB/1024)) KB)"

OUT="/tmp/output/$OUT_NAME"
# clear any stale (possibly root-owned) artifact from a prior run so the pmos
# user can rewrite it
rm -f "$OUT" 2>/dev/null || sudo rm -f "$OUT"
python3 /src/make-bootimg.py /tmp/zImage-dtb "$OUT" - "$CMDLINE"
cp "$VM"  "/tmp/output/vmlinuz-smp"
cp "$DTB" "/tmp/output/omap4-steelhead-smp.dtb"

IMG_SZ=$(stat -c%s "$OUT")
echo "=== output ==="
ls -lh "$OUT"
echo "  boot.img: $IMG_SZ bytes ($((IMG_SZ/1024)) KB)   U-Boot ceiling ~6656 KB / partition 8192 KB"
if [ "$IMG_SZ" -gt 6815744 ]; then
    echo "  !!! WARNING: image > 6656 KB ceiling -- may not boot from p9. Consider KERNEL_XZ or trimming."
fi
sha256sum "$OUT"
echo "=== DONE ($OUT_NAME) ==="
