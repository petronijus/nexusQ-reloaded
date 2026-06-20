#!/bin/bash
# build-nexusqd-only.sh -- rebuild ONLY the nexusqd apk (armv7/musl), reusing the
# pmbootstrap workdir volume (toolchain + chroots already built by docker-build.sh).
# Avoids the ~40 min kernel rebuild when iterating on the userspace daemon.
# Run the same way as docker-build.sh:
#   docker run --rm --privileged -v "${PWD}:/src:ro" \
#       -v nexusq-output:/tmp/output -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap \
#       nexusq-builder /src/build-nexusqd-only.sh
set -euo pipefail
SRC="/src"

echo "=== Phase 5: Initialize pmbootstrap ==="
export XDG_CONFIG_HOME=/home/pmos/.config
export XDG_DATA_HOME=/home/pmos/.local/share
export XDG_CACHE_HOME=/home/pmos/.cache
# NOTE: do NOT `chown -R pmos:pmos /home/pmos` here. When reusing an existing
# nexusq-workdir volume, that recursively chowns the pmbootstrap chroots' root-owned
# system files (e.g. /bin/sh) to pmos, which then fail to exec inside the chroot
# ("chroot: failed to run command '/bin/sh': Permission denied"). The full
# docker-build.sh gets away with it only because it runs on a fresh (empty) volume
# where the chroots are created *after* the chown. The volume is already pmos-owned.
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

echo "=== Phase 6: Stage nexusqd aport + sources ==="
NEXUSQD_DIR="$PMAPORTS/main/nexusqd"
mkdir -p "$NEXUSQD_DIR"
cp "$SRC/pmos/nexusqd/APKBUILD"             "$NEXUSQD_DIR/"
cp "$SRC/userspace/nexusqd/src/"*.c         "$NEXUSQD_DIR/"
cp "$SRC/userspace/nexusqd/include/"*.h     "$NEXUSQD_DIR/"
cp "$SRC/userspace/nexusqd/Makefile"        "$NEXUSQD_DIR/"
cp "$SRC/userspace/nexusqd/nexusqd.service" "$NEXUSQD_DIR/"
cp "$SRC/userspace/nexusqd/default.json"    "$NEXUSQD_DIR/"
find "$NEXUSQD_DIR" -type f -exec dos2unix -q {} + 2>/dev/null || true
echo "  staged nexusqd ($(ls "$NEXUSQD_DIR"/*.c | wc -l) C files)"

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

echo "=== Phase 7b: Zap chroots (recreate clean; prior runs may have left them"
echo "    half-set-up or root-owned). Keeps built packages + caches. ==="
pmbootstrap -y zap 2>&1 | tail -3 || true

echo "=== Phase 7c: Build nexusqd (armv7/musl) ==="
sudo mkdir -p /tmp/output && sudo chown pmos:pmos /tmp/output
pmbootstrap checksum nexusqd 2>&1 || true
set +e
pmbootstrap build nexusqd --arch armv7 --force 2>&1
RC=$?
set -e
echo "=== nexusqd build exit: $RC ==="
if [ $RC -eq 0 ]; then
    APK=$(find "$WORK/packages" -name 'nexusqd-*.apk' 2>/dev/null | head -1)
    [ -n "$APK" ] && cp "$APK" /tmp/output/ && echo "  Exported: $(basename "$APK")"
else
    echo "--- key error lines ---"
    grep -n "ERROR\|error:\|FAILED" "$WORK/log.txt" 2>/dev/null | tail -20
fi
echo "=== DONE ==="
