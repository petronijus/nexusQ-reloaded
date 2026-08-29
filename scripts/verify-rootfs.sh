#!/usr/bin/env bash
# verify-rootfs.sh — prove a built rootfs is actually what we think it is.
#
# A green build exit code is NOT success. v1.5.0 silently shipped an **OpenRC**
# rootfs with no nexusqd and no sshd, and it passed the build AND the checksums;
# the only thing that would have caught it is mounting the image and looking.
# These gates lived as prose in .claude/agents/nexusq-build.md, which is exactly
# why they were skippable — this makes them runnable and exit-coded.
#
# Usage:
#   scripts/verify-rootfs.sh <rootfs.img|rootfs-sparse.img> [boot.img]
#
# Read-only: mounts the image with -o ro and never writes to it. Needs sudo for
# the loop mount (SUDO_PASS via op-cache is picked up automatically if present).
set -uo pipefail

IMG="${1:?usage: verify-rootfs.sh <rootfs.img> [boot.img]}"
BOOTIMG="${2:-}"
MNT="$(mktemp -d)"
RAW=""
PASS=0
FAIL=0

cleanup() {
    mountpoint -q "$MNT" 2>/dev/null && sudo umount "$MNT"
    rmdir "$MNT" 2>/dev/null
    [ -n "$RAW" ] && [ -f "$RAW" ] && rm -f "$RAW"
}
trap cleanup EXIT

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-52s %s\n' "$1" "${2:-}"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %-52s %s\n' "$1" "${2:-}"; }
has()  { [ -e "$MNT/$1" ]; }
chk_has() { if has "$1"; then ok "$2" "$1"; else bad "$2" "missing: $1"; fi; }

# --- sparse -> raw if needed --------------------------------------------------
# Android sparse magic is 0xed26ff3a (little-endian on disk). Read it as a
# number instead of grepping binary, which is locale- and NUL-sensitive.
if [ "$(od -An -tx4 -N4 "$IMG" | tr -d ' ')" = "ed26ff3a" ]; then
    RAW="$(mktemp --suffix=.img)"
    say "sparse image detected, converting -> $RAW"
    simg2img "$IMG" "$RAW" || { say "simg2img failed"; exit 2; }
    IMG="$RAW"
fi

say "=== mounting $IMG read-only ==="
sudo mount -o loop,ro "$IMG" "$MNT" || { say "mount failed"; exit 2; }

say ""
say "=== 1. init system (the v1.5.0 gate) ==="
init_target="$(readlink -f "$MNT/sbin/init" 2>/dev/null || echo '?')"
case "$init_target" in
    *systemd*) ok "/sbin/init is systemd" "${init_target#$MNT}" ;;
    *busybox*) bad "/sbin/init is systemd" "resolves to busybox -> OpenRC image!" ;;
    *)         bad "/sbin/init is systemd" "unresolved: $init_target" ;;
esac
if grep -qE '^(openrc|busybox-openrc|postmarketos-base-openrc)$' \
        <(awk -F: '/^P:/{print $2}' "$MNT/lib/apk/db/installed" 2>/dev/null); then
    bad "no OpenRC packages installed" "openrc present in apk db"
else
    ok "no OpenRC packages installed"
fi
if has etc/runlevels; then bad "no /etc/runlevels"; else ok "no /etc/runlevels"; fi

say ""
say "=== 2. the daemons that must exist ==="
chk_has usr/bin/nexusqd                                              "nexusqd binary"
chk_has usr/lib/systemd/system/multi-user.target.wants/nexusqd.service "nexusqd enabled"
chk_has usr/sbin/sshd                                                "sshd (server)"
chk_has usr/bin/ssh                                                  "ssh (client)"
chk_has usr/bin/nq-healthd                                           "nq-healthd"
chk_has etc/systemd/system/nq-healthd.service                        "nq-healthd unit"
chk_has usr/bin/nexusq-control                                       "nexusq-control"
chk_has usr/bin/nexusq-mqtt                                          "nexusq-mqtt"

say ""
say "=== 3. idle-power set (device r73, 2026-08-16) ==="
chk_has usr/bin/nexusq-cpufreq-tune                                  "cpufreq-tune script"
chk_has etc/systemd/system/nexusq-cpufreq-tune.service               "cpufreq-tune unit"
chk_has etc/systemd/system/multi-user.target.wants/nexusq-cpufreq-tune.service \
                                                                     "cpufreq-tune enabled"
for u in etc/systemd/system/nq-healthd.service \
         etc/systemd/system/nexusq-wifi-watchdog.service \
         etc/systemd/system/nexusq-nfc.service \
         usr/lib/systemd/system/nexusq-mqtt.service \
         usr/lib/systemd/system/nexusq-btagent.service; do
    if [ -f "$MNT/$u" ]; then
        if grep -q '^Nice=19' "$MNT/$u"; then ok "Nice=19 in $(basename "$u")"
        else bad "Nice=19 in $(basename "$u")" "found: $(grep -m1 '^Nice=' "$MNT/$u" || echo none)"; fi
    else
        bad "Nice=19 in $(basename "$u")" "unit missing"
    fi
done
# nexusq-control must NOT be nice'd — it serves the app's volume RPC
if [ -f "$MNT/usr/lib/systemd/system/nexusq-control.service" ]; then
    if grep -q '^Nice=' "$MNT/usr/lib/systemd/system/nexusq-control.service"; then
        bad "nexusq-control NOT nice'd" "$(grep -m1 '^Nice=' "$MNT/usr/lib/systemd/system/nexusq-control.service")"
    else
        ok "nexusq-control NOT nice'd" "(deliberate: app volume RPC)"
    fi
fi
if [ -f "$MNT/usr/bin/nexusq-btagent" ]; then
    if grep -q 'SETUPD_CGROUP' "$MNT/usr/bin/nexusq-btagent"; then
        ok "btagent uses the cgroup test" "no systemctl polling"
    else
        bad "btagent uses the cgroup test" "SETUPD_CGROUP absent -> old r4 code"
    fi
fi

say ""
say "=== 4. per-unit network identity ==="
# No baked connection profile may pin a literal MAC. Since v1.10.1 the factory
# WiFi MAC comes from the DRIVER (DTS, kernel patch 0043) and a second unit gets
# its own address by the in-place DTB patch; a `cloned-mac-address=<literal>`
# in a profile silently overrides that and hands the second box the first one's
# identity, with nothing logged (2026-08-28).
#
# This gate exists because the fix did not reach a profile that had ALREADY been
# written. `wifi-sumperak-internety.nmconnection` was generated in the few hours
# between 1fb7f33 (multi-site, still hardcoded) and 50e57c0 (permanent) and was
# never regenerated, so the cottage Q ran the Prague Q's MAC until 2026-08-29 --
# both boxes then shared one Home Assistant device.
# docs/2026-08-29-mqtt-at-the-cottage-and-a-cloned-mac.md
NMDIR="$MNT/etc/NetworkManager/system-connections"
if [ -d "$NMDIR" ]; then
    bad_mac=""
    for prof in "$NMDIR"/*.nmconnection; do
        [ -f "$prof" ] || continue
        val=$(sed -n 's/^cloned-mac-address=//p' "$prof" | head -1)
        # absent is fine (NM's wifi-stable-mac.conf default applies); a literal
        # address is not. `permanent`/`preserve` name the hardware, they do not
        # override it.
        case "${val:-}" in
            ""|permanent|preserve) ;;
            *) bad_mac="$bad_mac $(basename "$prof")=$val" ;;
        esac
    done
    if [ -n "$bad_mac" ]; then
        bad "no profile pins a literal MAC" "$bad_mac"
    else
        ok "no profile pins a literal MAC" "$(ls "$NMDIR" 2>/dev/null | tr '\n' ' ')"
    fi
else
    say "  (no /etc/NetworkManager/system-connections in this image)"
fi

say ""
say "=== 5. streaming / Roon layout ==="
chk_has opt/glibc-rt/bin/bash                                        "glibc-rt present"
if has opt/glibc-rt/opt/RoonBridge; then
    bad "RoonBridge NOT baked" "present — must be lazy-fetched at runtime"
else
    ok "RoonBridge NOT baked"
fi
if compgen -G "$MNT/usr/lib/systemd/*/*wants*/roon.service" >/dev/null 2>&1 \
   || compgen -G "$MNT/etc/systemd/*/*wants*/roon.service" >/dev/null 2>&1; then
    bad "Roon is default-OFF" "an enable symlink exists"
else
    ok "Roon is default-OFF"
fi

say ""
say "=== 6. python3 integrity gate ==="
# The gate takes the .so itself, not a rootfs root — find it inside the image.
# This is the [[sparse-dontcare-stale-emmc-corrupts-flash]] backstop: a
# libpython whose zero-regions came back as device garbage SIGSEGVs on boot.
GATE=scripts/verify-libpython-clean.py
LIBPY="$(find "$MNT/usr/lib" -maxdepth 1 -name 'libpython3*.so*' -type f 2>/dev/null | head -1)"
if [ ! -f "$GATE" ]; then
    say "  (skipped: $GATE not found)"
elif [ -z "$LIBPY" ]; then
    bad "libpython present" "no libpython3*.so under usr/lib"
elif python3 "$GATE" "$LIBPY" >/dev/null 2>&1; then
    ok "libpython clean" "$(basename "$LIBPY")"
else
    bad "libpython clean" "run: python3 $GATE '$LIBPY' --verbose"
fi

say ""
say "=== 7. boot.img ==="
if [ -n "$BOOTIMG" ] && [ -f "$BOOTIMG" ]; then
    sz=$(stat -c %s "$BOOTIMG")
    if [ "$sz" -le $((8*1024*1024)) ]; then
        ok "boot.img <= 8 MB" "$((sz/1024)) KiB"
    else
        bad "boot.img <= 8 MB" "$((sz/1024)) KiB — will fail fastboot with error=-27"
    fi
    # ramdisk size at 0x10, ramdisk load address at 0x14, in the Android header.
    #
    # This gate used to demand ramdisk_size=0, because pmbootstrap's own 7.6 MB
    # initramfs made a 12.6 MB image that could not fit the 8 MB boot partition.
    # It now demands the OPPOSITE: the boot image carries the A/B initramfs that
    # picks the rootfs slot, and without it the kernel falls back to its forced
    # root=p13 and slot switching silently stops working -- a failure that looks
    # exactly like a normal, healthy boot.
    rd=$(od -An -tu4 -j16 -N4 "$BOOTIMG" | tr -d ' ')
    if [ "${rd:-0}" -gt 0 ]; then
        ok "boot.img carries the A/B initramfs" "ramdisk_size=$((rd/1024)) KiB"
    else
        bad "boot.img carries the A/B initramfs" \
            "ramdisk_size=0 — a flash of this image cannot switch rootfs slots"
    fi

    # And it has to be loaded somewhere the kernel will accept. 0x81000000 is the
    # Android-stock address and it sits inside our kernel's own memory, so the
    # kernel drops the initrd and boots as if it were never there.
    ra=$(od -An -tu4 -j20 -N4 "$BOOTIMG" | tr -d ' ')
    if [ "${rd:-0}" -gt 0 ]; then
        if [ "$ra" -ge $((0x83000000)) ]; then
            ok "ramdisk load address is clear of the kernel" "$(printf '0x%08x' "$ra")"
        else
            bad "ramdisk load address is clear of the kernel" \
                "$(printf '0x%08x' "$ra") — kernel will disable the initrd"
        fi
    fi
else
    say "  (no boot.img given — pass it as the 2nd argument to check size/ramdisk)"
fi

say ""
say "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
