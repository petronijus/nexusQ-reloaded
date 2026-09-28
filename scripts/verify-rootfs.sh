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
    unreadable=""
    for prof in "$NMDIR"/*.nmconnection; do
        [ -f "$prof" ] || continue
        # These are mode 600 root-owned, so a non-root run cannot read them --
        # and an unreadable file yields an EMPTY cloned-mac-address, which the
        # test below would happily accept as "absent is fine". A gate that
        # reports PASS precisely when it could not look is worse than no gate;
        # caught 2026-08-30 on the r89 build, where section 4 printed
        # "Permission denied" for every profile and passed anyway.
        if [ ! -r "$prof" ]; then
            unreadable="$unreadable $(basename "$prof")"
            continue
        fi
        val=$(sed -n 's/^cloned-mac-address=//p' "$prof" | head -1)
        # absent is fine (NM's wifi-stable-mac.conf default applies); a literal
        # address is not. `permanent`/`preserve` name the hardware, they do not
        # override it.
        case "${val:-}" in
            ""|permanent|preserve) ;;
            *) bad_mac="$bad_mac $(basename "$prof")=$val" ;;
        esac
    done
    if [ -n "$unreadable" ]; then
        bad "no profile pins a literal MAC" \
            "could not READ:$unreadable — re-run as root; this gate cannot judge what it cannot open"
    elif [ -n "$bad_mac" ]; then
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
# Resolved from THIS script's location, not the cwd. As a bare relative path it
# silently did nothing whenever the script was run from anywhere but the repo
# root -- and it announced that with `say`, which counts as neither pass nor
# fail, so the run just quietly had one gate fewer (2026-08-30, r89 build).
GATE="$(dirname "$0")/verify-libpython-clean.py"
LIBPY="$(find "$MNT/usr/lib" -maxdepth 1 -name 'libpython3*.so*' -type f 2>/dev/null | head -1)"
if [ ! -f "$GATE" ]; then
    bad "libpython clean" "gate script missing: $GATE"
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
say "=== 8. A/B slots: the first boot splits the eMMC (device r112, 2026-09-26) ==="
# Every unit flashed from a release gets its slot B (p14) on its first boot, from
# nexusq-resize-rootfs, while the flashed ext4 is still only the image's size.
# Nothing else would ever give a fresh flash A/B, and every way this can break
# is SILENT -- the unit boots fine, it just never gets slot B:
#   - the unit not enabled, or its script missing;
#   - per-unit storage state baked into the image. The worst of it is
#     .ab-split-pending: it licenses formatting p14, so on a unit whose slot B
#     holds a rootfs it would format that rootfs. The rest (the check's record,
#     the offline split's attempt and result) would misreport or skip a check;
#   - the shared layout code (nexusq-rootfs-ab's ab-lib.sh) absent, in which
#     case the script only grows;
#   - an image whose ext4 is too large to fit the smaller slot A with the
#     script's 256 MiB margin, which it then refuses to split.
# The OTA path for units already in the field (nexusq-storage-check.timer) is
# checked here too: a release that dropped it would strand every such unit
# without slot B.
chk_has usr/bin/nexusq-resize-rootfs                                 "first-boot split + grow script"
if compgen -G "$MNT/etc/systemd/system/*.target.wants/nexusq-resize-rootfs.service" >/dev/null 2>&1 \
   || compgen -G "$MNT/usr/lib/systemd/system/*.target.wants/nexusq-resize-rootfs.service" >/dev/null 2>&1; then
    ok "nexusq-resize-rootfs is enabled"
else
    bad "nexusq-resize-rootfs is enabled" "no *.target.wants link -- the first boot neither splits nor grows"
fi
for f in .ab-split-pending .rootfs-resized storage-ok ab-migrate.attempted ab-migrate.result; do
    if has "var/lib/nexusq/$f"; then
        bad "no per-unit storage state baked: $f" "present in the image -- it belongs to a unit, not to a release"
    else
        ok "no per-unit storage state baked: $f"
    fi
done
# The saved random seed is CREDITED at boot since device r114 (boot no longer
# waits 17-74 s for the CRNG). A seed baked into a release image would then be
# credited on every unit flashed from it -- the same "entropy" everywhere. The
# image must carry none; each unit writes its own on its first boot.
if has var/lib/systemd/random-seed; then
    bad "no random seed baked" "var/lib/systemd/random-seed is in the image and would be credited on every unit"
else
    ok "no random seed baked"
fi
chk_has usr/lib/systemd/system/systemd-random-seed.service.d/10-nexusq-random-seed-credit.conf \
                                                                     "seed crediting drop-in"
chk_has usr/lib/nexusq-rootfs-ab/ab-lib.sh                           "A/B layout code (ab-lib.sh)"
if grep -q '/usr/lib/nexusq-rootfs-ab/ab-lib.sh' "$MNT/usr/bin/nexusq-resize-rootfs" 2>/dev/null \
   && grep -q '^ab_layout()' "$MNT/usr/lib/nexusq-rootfs-ab/ab-lib.sh" 2>/dev/null \
   && grep -q '^ab_table()' "$MNT/usr/lib/nexusq-rootfs-ab/ab-lib.sh" 2>/dev/null; then
    ok "the first-boot script uses ab_layout/ab_table"
else
    bad "the first-boot script uses ab_layout/ab_table" "the script or ab-lib.sh does not match -- no split"
fi
# The ext4's own size, read the way nexusq-resize-rootfs reads it (dumpe2fs block
# count x block size; statfs would under-report by the metadata overhead). Slot A
# on the Nexus Q's eMMC is 13788160 sectors (ab_layout of 30777344 sectors from
# 3200000); the script splits only if the ext4 plus 256 MiB fits in it.
_blocks=$(dumpe2fs -h "$IMG" 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,"",$2);print $2}')
_bsize=$(dumpe2fs -h "$IMG" 2>/dev/null | awk -F: '/^Block size/{gsub(/ /,"",$2);print $2}')
if [ -z "$_blocks" ] || [ -z "$_bsize" ]; then
    read -r _blocks _bsize < <(stat -f -c '%b %S' "$MNT")     # no dumpe2fs: statfs, a lower bound
fi
_fs=$(( _blocks * _bsize )); _slot=$(( 13788160 * 512 ))
if [ $(( _fs + 268435456 )) -le "$_slot" ]; then
    ok "the image's ext4 fits slot A for the online split" "$((_fs / 1048576)) MiB of $((_slot / 1048576)) MiB"
else
    bad "the image's ext4 fits slot A for the online split" \
        "$((_fs / 1048576)) MiB + 256 MiB > $((_slot / 1048576)) MiB -- a fresh flash would not split"
fi
chk_has usr/lib/nexusq-rootfs-ab/init-split                          "OTA split: maintenance init"
chk_has usr/lib/nexusq-rootfs-ab/make-ab-initramfs.py                "OTA split: initramfs collector"
chk_has usr/lib/systemd/system/timers.target.wants/nexusq-storage-check.timer "storage check after every OTA: timer enabled"

say ""
say "=== 9. one volume: the players drive the PulseAudio sink (device r117) ==="
# librespot and shairport-sync move the Q's volume through the nexusq_vol ALSA
# control. Every way this breaks is quiet: without the plugin or its conf.d
# entry librespot fails to open its mixer and Spotify disappears; without the
# mixer arguments the players fall back to their own software volume -- the
# two-stage volume this replaced -- and nothing reports it. And librespot
# started with a fixed --initial-volume would reset the Q's volume at every
# boot. docs/2026-09-27-one-volume.md.
chk_has usr/lib/alsa-lib/libasound_module_ctl_nexusq_vol.so          "nexusq_vol ALSA control plugin"
if grep -qs '^ctl\.nexusq_vol' "$MNT/etc/alsa/conf.d/60-nexusq-vol.conf"; then
    ok "ctl.nexusq_vol is defined for alsa-lib"
else
    bad "ctl.nexusq_vol is defined for alsa-lib" "no /etc/alsa/conf.d/60-nexusq-vol.conf -- librespot cannot open its mixer"
fi
chk_has usr/lib/nexusq/nq-pulse.sh                                   "launchers' PulseAudio helper"
if grep -qs -- '--mixer alsa --alsa-mixer-device nexusq_vol' "$MNT/usr/bin/librespot-nexusq" \
   && grep -qs -- '--initial-volume "\$VOL"' "$MNT/usr/bin/librespot-nexusq"; then
    ok "librespot drives nexusq_vol, starting at the sink's volume"
else
    bad "librespot drives nexusq_vol, starting at the sink's volume" "librespot-nexusq attenuates on its own or resets the volume"
fi
if grep -qs '^[[:space:]]*mixer_device = "nexusq_vol";' "$MNT/etc/nexusq/shairport-sync.conf"; then
    ok "shairport-sync drives nexusq_vol"
else
    bad "shairport-sync drives nexusq_vol" "AirPlay attenuates on its own again"
fi

say ""
say "=== 10. the USB-net gadget is off pmOS's shared subnet (device r120) ==="
# Every pmOS gadget answers on 172.16.42.1, so with the Q and Petr's Lumia on one
# host that address reaches whichever interface wins the route (2026-09-28). The
# Q is 172.16.43.1. The gadget script takes its address from unudhcpd's own
# config, so a missing or reverted file puts it back on .42 without a word.
if grep -qs '^UNUDHCPD_SERVER=172\.16\.43\.1$' "$MNT/etc/unudhcpd.conf" \
   && grep -qs '^UNUDHCPD_CLIENT=172\.16\.43\.2$' "$MNT/etc/unudhcpd.conf"; then
    ok "unudhcpd serves 172.16.43.0/24"
else
    bad "unudhcpd serves 172.16.43.0/24" "/etc/unudhcpd.conf missing or not .43 -- the gadget falls back to pmOS's 172.16.42.1"
fi
if grep -qs '\. /etc/unudhcpd.conf' "$MNT/usr/bin/nexusq-usb-gadget.sh" \
   && ! grep -qs '172\.16\.42\.' "$MNT/usr/bin/nexusq-usb-gadget.sh"; then
    ok "the gadget script takes its address from unudhcpd.conf"
else
    bad "the gadget script takes its address from unudhcpd.conf" "it hardcodes an address or ignores the file"
fi
# PulseAudio must leave the UAC2 gadget card to nexusq-uac2-in's alsaloop, or the
# first open at boot fails EBUSY and USB Audio starts late (2026-09-19, -28).
if grep -qs '^SUBSYSTEM=="sound", KERNEL=="card\*", SUBSYSTEMS=="gadget", ENV{PULSE_IGNORE}="1"$' \
        "$MNT/etc/udev/rules.d/91-pulseaudio-hdmi-ignore.rules"; then
    ok "PulseAudio ignores the UAC2 gadget card"
else
    bad "PulseAudio ignores the UAC2 gadget card" "no gadget PULSE_IGNORE rule -- PA claims hw:UAC2Gadget at boot"
fi

say ""
say "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
