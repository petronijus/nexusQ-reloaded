#!/usr/bin/env bash
# Tests for `nq-kernel-ota prune` — removing /lib/modules trees no kernel here
# can boot any more.
#
# What is being protected: stage-apk installs every new kernel's modules beside
# the running one's, and nothing ever took a tree away again. On 2026-10-03 the
# Prague Q held r16 to r20, 8.2 MB each, three of them owned by nothing. The
# danger runs the other way too: the slot-A backup boots its own kernel on
# `restore`, and a kernel without its tree comes up with no cfg80211 -- no WiFi
# on a box with no console (measured 2026-08-31). So a tree goes only when it
# belongs to no running kernel, no slot-A kernel, no backup, no pending trial
# and no package, and when any of those cannot be read, nothing goes at all.
#
# The release is read out of the image itself (the "Linux version" banner in
# the zImage's LZMA payload), so the images here are real Android boot images
# around a real LZMA stream, with a decoy LZMA header in front of it as the
# zImage's decompressor code may carry.
#
# Runs on any Linux host with python3 and util-linux flock: `uname` is stubbed
# on PATH, slots and the module tree are files under a temp dir. No device, no
# kernel, no root. Off Linux it re-runs inside Alpine, with the unit's busybox.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ "$(uname -s)" != Linux ] && [ -z "${NQ_TEST_IN_CONTAINER:-}" ]; then
    command -v docker >/dev/null || { echo "docker required off Linux" >&2; exit 2; }
    exec docker run --rm -e NQ_TEST_IN_CONTAINER=1 \
        -v "$HERE/../../..:/repo:ro" alpine:3.21 sh -c \
        'apk add -q bash python3 flock >/dev/null 2>&1 && bash /repo/pmos/nexusq-kernel-ota/tests/test_prune_modules.sh'
fi
TOOL="$HERE/../../../userspace/nexusq-kernel-ota/nq-kernel-ota"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

# image <out> <release|garbage>: an Android boot image whose kernel is a fake
# zImage -- code bytes with a decoy LZMA header, then an LZMA stream holding
# the version banner deep inside -- plus a ramdisk, like the slots carry.
image() {
    python3 - "$1" "$2" <<'PYEOF'
import lzma, os, random, struct, sys
out, rel = sys.argv[1], sys.argv[2]
rnd = random.Random(rel)
if rel == "garbage":
    kernel = bytes(rnd.getrandbits(8) for _ in range(200000))
else:
    body = bytes(rnd.getrandbits(8) for _ in range(300000))
    banner = b"Linux version %s (pmos@build) (gcc 15.2) #21 SMP Sat Oct 3 2026\n" % rel.encode()
    payload = body + banner + body[:100000]
    # A decoy LZMA header in the code; with BIGDECOY it claims a 3.75 GiB
    # dictionary, which a 32-bit address space cannot map.
    decoy = b"\x5d\x00\x00\x00\xf0" if os.environ.get("BIGDECOY") else b"\x5d\x00\x00\x00\x01"
    code = b"\x00" * 64 + decoy + bytes(rnd.getrandbits(8) for _ in range(4000))
    kernel = code + lzma.compress(payload, format=lzma.FORMAT_ALONE)
ramdisk = b"\x1f\x8b" + b"r" * 5000
ps = 2048
pad = lambda d: d + b"\x00" * ((ps - len(d) % ps) % ps)
hdr = struct.pack("<8s10I", b"ANDROID!", len(kernel), 0x80008000, len(ramdisk),
                  0x84000000, 0, 0x80f00000, 0x80000100, ps, 0, 0)
open(out, "wb").write(pad(hdr) + pad(kernel) + pad(ramdisk))
PYEOF
}

# setup <running>: a fresh state dir, slots, an apk db and an empty module dir
setup() {
    rm -rf "$T/s"; mkdir -p "$T/s/state" "$T/s/modules" "$T/bin"
    cat > "$T/bin/uname" <<STUB
#!/bin/sh
[ "\${1:-}" = "-r" ] && { echo "$1"; exit 0; }
exec /bin/uname "\$@"
STUB
    chmod +x "$T/bin/uname"
    : > "$T/s/apkdb"
}
# trees <release>...: in install order, one minute apart, as depmod stamps them
stamp() { python3 -c 'import os, sys; t = int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
trees() {
    _t=$(( $(date +%s) - 86400 ))
    for r in "$@"; do
        mkdir -p "$T/s/modules/$r/kernel"; : > "$T/s/modules/$r/modules.dep"
        _t=$((_t + 60)); stamp "$T/s/modules/$r" "$_t"
    done
}
owns() { printf 'P:linux-google-steelhead\nF:lib/modules/%s\nF:lib/modules/%s/kernel\n\n' "$1" "$1" >> "$T/s/apkdb"; }
have() { [ -d "$T/s/modules/$1" ]; }
run() {
    PATH="$T/bin:$PATH" NQ_KOTA_STATE_DIR="$T/s/state" NQ_KOTA_BOOT_SLOT="$T/s/slotA" \
        NQ_KOTA_TRIAL_SLOT="$T/s/slotB" NQ_KOTA_MODULES_DIR="$T/s/modules" \
        NQ_KOTA_APK_DB="${APKDB:-$T/s/apkdb}" NQ_KOTA_LOCK_WAIT_S=1 \
        NQ_KOTA_KEEP_PREVIOUS="${KEEP-0}" sh "$TOOL" "${1:-prune}" 2>&1
}
oneline() { printf '%s' "$1" | tr '\n' '|'; }

# --- 1. the Prague Q of 2026-10-03 ---------------------------------------------
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; cp "$T/s/slotA" "$T/s/slotB"
image "$T/s/state/slot-a-backup.img" 6.18.48-r19
trees 6.18.48-r16 6.18.48-r17 6.18.48-r18 6.18.48-r19 6.18.48-r20; owns 6.18.48-r20
OUT=$(run)
if ! have 6.18.48-r16 && ! have 6.18.48-r17 && ! have 6.18.48-r18; then
    ok "trees of kernels that left both slots and the backup are removed"
else
    bad "r16-r18 should be gone; got: $(oneline "$OUT")"
fi
have 6.18.48-r20 && ok "the running / slot-A kernel's tree stays" || bad "r20 must stay"
have 6.18.48-r19 && ok "the backup's tree stays, so 'restore' boots with modules" || bad "r19 (backup) must stay"
printf '%s' "$OUT" | grep -q "removed 3 tree(s)" && ok "says how many it removed" \
    || bad "should report 3 removed; got: $(oneline "$OUT")"

# --- 2. the cache answers for the same image, never for a changed one ---------
grep -q " 6.18.48-r20$" "$T/s/state/image-releases" && grep -q " 6.18.48-r19$" "$T/s/state/image-releases" \
    && ok "releases are cached by image md5" || bad "cache should hold both releases"
image "$T/s/state/slot-a-backup.img" 6.18.48-r18; trees 6.18.48-r18 6.18.48-r19
OUT=$(run)
if have 6.18.48-r18 && ! have 6.18.48-r19; then
    ok "a new backup image is read afresh: its tree stays, the old one goes"
else
    bad "the cache answered for an image it had never seen; got: $(oneline "$OUT")"
fi

# --- 3. slot A unreadable: nothing is removed ---------------------------------
setup 6.18.48-r20
image "$T/s/slotA" garbage; image "$T/s/state/slot-a-backup.img" 6.18.48-r19
trees 6.18.48-r16 6.18.48-r19 6.18.48-r20
OUT=$(run)
if have 6.18.48-r16 && printf '%s' "$OUT" | grep -q "cannot read the kernel release in slot A"; then
    ok "an unreadable slot A removes nothing, and says why"
else
    bad "must remove nothing when slot A cannot be read; got: $(oneline "$OUT")"
fi

# --- 4. backup unreadable: nothing is removed ---------------------------------
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" garbage
trees 6.18.48-r16 6.18.48-r19 6.18.48-r20
OUT=$(run)
if have 6.18.48-r16 && have 6.18.48-r19; then
    ok "an unreadable backup removes nothing: its kernel's tree may be any of them"
else
    bad "must remove nothing when the backup cannot be read; got: $(oneline "$OUT")"
fi

# --- 5. a staged trial keeps its tree, named in the marker or read from slot B -
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" 6.18.48-r20
trees 6.18.48-r19 6.18.48-r20 6.18.48-r21
echo "2026-10-03T20:42:15Z /tmp/x/boot.img abc 6.18.48-r21 " > "$T/s/state/pending"
OUT=$(run)
if have 6.18.48-r21 && ! have 6.18.48-r19; then
    ok "the pending trial's tree (from the marker) stays"
else
    bad "a staged trial's modules must stay; got: $(oneline "$OUT")"
fi
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" 6.18.48-r20
image "$T/s/slotB" 6.18.48-r21; trees 6.18.48-r19 6.18.48-r20 6.18.48-r21
echo "2026-10-03T20:42:15Z /tmp/x/boot.img abc  " > "$T/s/state/pending"
OUT=$(run)
have 6.18.48-r21 && ok "a marker without a release: the trial slot's kernel is read and kept" \
    || bad "should read the trial slot's release; got: $(oneline "$OUT")"
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" 6.18.48-r20
image "$T/s/slotB" garbage; trees 6.18.48-r19 6.18.48-r20
echo "2026-10-03T20:42:15Z /tmp/x/boot.img abc  " > "$T/s/state/pending"
OUT=$(run)
have 6.18.48-r19 && ok "a pending trial of unknown kernel removes nothing" \
    || bad "must remove nothing with an unknown pending kernel; got: $(oneline "$OUT")"

# --- 6. without a pending trial the trial slot is not consulted ---------------
# (a never-OTA'd unit still has stock recovery there, which this cannot read)
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/slotB" garbage
trees 6.18.48-r19 6.18.48-r20
OUT=$(run)
! have 6.18.48-r19 && ok "an unreadable trial slot with nothing pending does not block pruning" \
    || bad "the trial slot should not matter without a pending trial; got: $(oneline "$OUT")"

# --- 7. a package owning files in an old tree keeps it ------------------------
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" 6.18.48-r20
trees 6.18.48-r17 6.18.48-r18 6.18.48-r20
printf 'P:some-out-of-tree-module\nF:lib/modules/6.18.48-r17/extra\n\n' >> "$T/s/apkdb"
printf 'P:another\nF:lib/modules/6.18.48-r180\n\n' >> "$T/s/apkdb"
OUT=$(run)
have 6.18.48-r17 && ok "a tree a package owns files in stays" || bad "r17 is owned by a package"
! have 6.18.48-r18 && ok "ownership is matched on the whole release (r180 is not r18)" \
    || bad "r18 should go: only r180 is owned; got: $(oneline "$OUT")"

# --- 7b. the previous kernels a boot-only reflash can still boot -------------
# The default keeps the two installed most recently before the ones in use, so
# `fastboot flash boot` of an older release does not come up without WiFi.
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" 6.18.48-r19
trees 6.18.48-r15 6.18.48-r16 6.18.48-r17 6.18.48-r18 6.18.48-r19 6.18.48-r20; owns 6.18.48-r20
OUT=$(PATH="$T/bin:$PATH" NQ_KOTA_STATE_DIR="$T/s/state" NQ_KOTA_BOOT_SLOT="$T/s/slotA" \
      NQ_KOTA_TRIAL_SLOT="$T/s/slotB" NQ_KOTA_MODULES_DIR="$T/s/modules" \
      NQ_KOTA_APK_DB="$T/s/apkdb" NQ_KOTA_LOCK_WAIT_S=1 sh "$TOOL" prune 2>&1)
if have 6.18.48-r18 && have 6.18.48-r17 && ! have 6.18.48-r16 && ! have 6.18.48-r15 \
   && have 6.18.48-r19 && have 6.18.48-r20; then
    ok "by default the 2 newest previous kernels stay, older ones go"
else
    bad "default should keep r17+r18 beyond r19/r20; got: $(oneline "$OUT")"
fi
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" 6.18.48-r19
# r18 installed before r16 and r17 -- a stage-apk before NTP, on a box with
# no RTC, stamps it as the oldest. The release decides, not the clock.
trees 6.18.48-r18 6.18.48-r16 6.18.48-r17 6.18.48-r19 6.18.48-r20
OUT=$(KEEP=1 run)
have 6.18.48-r18 && ! have 6.18.48-r16 && ! have 6.18.48-r17 \
    && ok "newest means the newest release, whatever the clock said (r18 stamped oldest)" \
    || bad "should keep the highest previous release; got: $(oneline "$OUT")"
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" 6.18.48-r20
trees 6.12.12-r52 6.18.48-r2 6.18.48-r10 6.18.48-r20
OUT=$(KEEP=1 run)
have 6.18.48-r10 && ! have 6.18.48-r2 && ! have 6.12.12-r52 \
    && ok "releases compare as numbers: r10 > r2, 6.18 > 6.12.12-r52" \
    || bad "release order must be numeric; got: $(oneline "$OUT")"
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" 6.18.48-r20
trees 6.18.48-r18 6.18.48-r20
OUT=$(KEEP=bogus run)
have 6.18.48-r18 && ok "a non-numeric NQ_KOTA_KEEP_PREVIOUS falls back to 2, not to 0" \
    || bad "a bad KEEP value must not remove the spares; got: $(oneline "$OUT")"
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" 6.18.48-r20
trees 6.18.48-r18 6.18.48-r19 6.18.48-r20
printf 'P:x\nF:lib/modules/6.18.48-r19/extra\n\n' >> "$T/s/apkdb"
OUT=$(KEEP=1 run)
have 6.18.48-r19 && have 6.18.48-r18 \
    && ok "a package-owned tree does not use up a previous-kernel place" \
    || bad "r19 is owned, so r18 is the one previous kernel kept; got: $(oneline "$OUT")"

# --- 8. no apk database: every tree would look unowned, so nothing goes ------
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" 6.18.48-r20
trees 6.18.48-r18 6.18.48-r20
OUT=$(APKDB="$T/s/no-such-db" run)
have 6.18.48-r18 && printf '%s' "$OUT" | grep -q "cannot read .*no-such-db" \
    && ok "an unreadable apk database removes nothing, and says why" \
    || bad "must fail closed without the apk database; got: $(oneline "$OUT")"

# --- 9. a marker whose 4th field is not a release: the trial slot is read ----
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" 6.18.48-r20
image "$T/s/slotB" 6.18.48-r21; trees 6.18.48-r19 6.18.48-r20 6.18.48-r21
echo "2026-10-03T20:42:15Z /tmp/my boot.img d41d8cd98f00b204e9800998ecf8427e 6.18.48-r21 " > "$T/s/state/pending"
OUT=$(run)
have 6.18.48-r21 && ! have 6.18.48-r19 \
    && ok "a path with a space shifts the marker's fields: the trial slot decides" \
    || bad "the trial's tree must stay; got: $(oneline "$OUT")"

# --- 10. a decoy header the Q's address space cannot map ----------------------
setup 6.18.48-r20
BIGDECOY=1 image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" 6.18.48-r20
trees 6.18.48-r18 6.18.48-r20
OUT=$( (ulimit -v 2500000; run) )
! have 6.18.48-r18 && have 6.18.48-r20 \
    && ok "a 3.75 GiB decoy dictionary under a 32-bit-sized limit costs the decoy, not the scan" \
    || bad "the real stream behind the decoy must still be read; got: $(oneline "$OUT")"

# --- 11. promote prunes, after the slot and the database have moved on --------
setup 6.18.48-r21
image "$T/s/slotA" 6.18.48-r20; image "$T/s/slotB" 6.18.48-r21
image "$T/s/state/slot-a-backup.img" 6.18.48-r20
trees 6.18.48-r19 6.18.48-r20 6.18.48-r21
echo "2026-10-03T20:42:15Z /tmp/x/boot.img abc 6.18.48-r21 " > "$T/s/state/pending"
OUT=$(run promote)
if [ ! -f "$T/s/state/pending" ] && ! have 6.18.48-r19 && have 6.18.48-r20 && have 6.18.48-r21; then
    ok "promote ends with a prune: the new kernel and the backup's stay, the one before goes"
else
    bad "promote should prune r19 only; got: $(oneline "$OUT")"
fi

# --- 12. one writer at a time -------------------------------------------------
setup 6.18.48-r20
image "$T/s/slotA" 6.18.48-r20; image "$T/s/state/slot-a-backup.img" 6.18.48-r20
trees 6.18.48-r18 6.18.48-r20
flock "$T/s/state/lock" sleep 4 & HOLDER=$!
sleep 0.5
OUT=$(run)
wait "$HOLDER"
have 6.18.48-r18 && printf '%s' "$OUT" | grep -q "still holds .*lock" \
    && ok "a prune while another nq-kernel-ota holds the lock waits, then gives up untouched" \
    || bad "must not prune while the lock is held; got: $(oneline "$OUT")"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
