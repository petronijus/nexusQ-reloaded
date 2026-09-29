#!/usr/bin/env bash
# shellcheck disable=SC2034  # check() evals its quoted conditions, which read $out, $rc and the fixtures
# needs: docker  (tools/dev/test-shell.sh runs it in the docker lane, `just test-sh-docker`)
# Tests for `nq-kernel-ota personalize` (nexusq-kernel-ota r8, 2026-09-26): one
# generic boot image, every unit its own WiFi MAC and BT address.
#
# What is being protected: the release boot image carries the Prague Q's
# addresses, so before this every unit flashed from a release came up as the
# Prague Q on both radios. personalize must give each unit an identity that is
# its own and stable -- the persist store's record, else what its slot already
# carries if that is not the generic one, else the generic one only on the
# Prague Q itself, else derived from its eMMC CID -- and change a boot slot only
# through the trial slot, with the repack proven to differ from the booted image
# in the identity alone, and promoted only when the running kernel reports it.
#
# BusyBox sha256sum/stat like the unit: off Linux this re-runs inside Alpine.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ "$(uname -s)" != Linux ] && [ -z "${NQ_TEST_IN_CONTAINER:-}" ]; then
    command -v docker >/dev/null || { echo "docker required off Linux" >&2; exit 2; }
    exec docker run --rm -e NQ_TEST_IN_CONTAINER=1 \
        -v "$HERE/../../..:/repo:ro" alpine:3.21 sh -c \
        'apk add -q bash python3 >/dev/null 2>&1 && bash /repo/pmos/nexusq-kernel-ota/tests/test_personalize.sh'
fi
TOOL="$HERE/../../../userspace/nexusq-kernel-ota/nq-kernel-ota"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

# mkdtb <out> <wifi-hex> <bt-hex-as-stored> [extra]  — a minimal but valid FDT
# with the two identity properties in different nodes plus a decoy `mac-address`
# on an ethernet node (smsc95xx uses its own EEPROM; it must never be touched).
#   extra=dup     -> a second local-mac-address elsewhere (ambiguous)
#   extra=nomac   -> no local-mac-address at all
mkdtb() {
python3 - "$@" <<'EOF'
import struct, sys
out, wifi, bt, extra = sys.argv[1], bytes.fromhex(sys.argv[2]), bytes.fromhex(sys.argv[3]), (sys.argv[4] if len(sys.argv) > 4 else "")
strings = bytearray(); soff = {}
def s(name):
    if name not in soff:
        soff[name] = len(strings); strings.extend(name.encode() + b"\0")
    return soff[name]
st = bytearray()
def begin(n):
    st.extend(struct.pack(">I", 1)); b = n.encode() + b"\0"; st.extend(b + b"\0" * ((4 - len(b) % 4) % 4))
def end(): st.extend(struct.pack(">I", 2))
def prop(n, v):
    st.extend(struct.pack(">III", 3, len(v), s(n))); st.extend(v + b"\0" * ((4 - len(v) % 4) % 4))
begin(""); prop("compatible", b"google,steelhead\0")
begin("ethernet@1"); prop("mac-address", bytes.fromhex("0200deadbeef")); end()
begin("mmc@0"); begin("wifi@1")
if extra != "nomac": prop("local-mac-address", wifi)
prop("status", b"okay\0"); end(); end()
begin("serial@2"); begin("bluetooth"); prop("local-bd-address", bt); end(); end()
if extra == "dup":
    begin("wifi-decoy"); prop("local-mac-address", wifi); end()
st.extend(struct.pack(">I", 4))  # a NOP, the walker must skip it
end(); st.extend(struct.pack(">I", 9))
hdr = 40; rsv = b"\0" * 16
off_struct = hdr + len(rsv); off_strings = off_struct + len(st)
total = off_strings + len(strings)
blob = struct.pack(">10I", 0xd00dfeed, total, off_struct, off_strings, hdr, 17, 16, 0, len(strings), len(st)) + rsv + bytes(st) + bytes(strings)
open(out, "wb").write(blob)
EOF
}

# A fake zImage that contains the DECOY magic with a nonsense totalsize, the way
# the real compressed kernel happens to. The tool must skip it.
python3 - "$T/zImage" <<'EOF'
import sys, struct
z = bytearray(b"\x7fELF-not-really" * 64)
z[100:108] = b"\xd0\x0d\xfe\xed" + struct.pack(">I", 204 * 1024 * 1024)   # decoy: 204 MB
open(sys.argv[1], "wb").write(bytes(z))
EOF
printf 'CONFIG_CMDLINE="console=ttyS2,115200 root=/dev/mmcblk0p13"\n' > "$T/config"
head -c 4096 /dev/urandom > "$T/ramdisk"


GEN_W=f88fca2048e1;  GEN_B=e54920ca8ff8        # the generic (Prague) identity, as stored
COTT_CID=1501004d4147344641258c0c1e662fbf      # the cottage Q's eMMC
OWNER_CID=1501004d414734464125ef8120a7ce45     # the Prague Q's eMMC
GENERIC="wifi=f8:8f:ca:20:48:e1 bt=f8:8f:ca:20:49:e5"
COTTAGE="wifi=f8:8f:ca:05:1f:11 bt=f8:8f:ca:73:ac:9c"

eval "$(sed -n '/^IDENTITY_GENERIC=/p;/^IDENTITY_OWNER_CID=/p' "$TOOL")"
eval "$(sed -n '/^# TESTABLE:derive_identity$/,/^}/p;/^# TESTABLE:wanted_identity$/,/^}/p' "$TOOL")"

echo "=== derive_identity: deterministic, the factory OUI, from the eMMC CID ==="
d1=$(derive_identity $COTT_CID)
check '[ "$d1" = "wifi=f8:8f:ca:25:d6:20 bt=f8:8f:ca:98:61:73" ]' "the cottage CID gives what the unit itself computed (2026-09-26)"
check '[ "$(derive_identity $COTT_CID)" = "$d1" ]' "same CID, same identity"
check '[ "$(derive_identity $OWNER_CID)" != "$d1" ]' "another CID, another identity"

echo "=== wanted_identity: the rules, in order ==="
check '[ "$(wanted_identity "$COTTAGE" "$GENERIC" $COTT_CID)" = "$COTTAGE" ]' "a record in the store wins over everything (a full flash comes back as itself)"
check '[ "$(wanted_identity "" "$COTTAGE" $COTT_CID)" = "$COTTAGE" ]' "no record, slot already personal: kept (the cottage Q, no rename)"
check '[ "$(wanted_identity "" "$GENERIC" $OWNER_CID)" = "$GENERIC" ]' "no record, generic slot, and this IS its owner: kept (Prague)"
check '[ "$(wanted_identity "" "$GENERIC" $COTT_CID)" = "$d1" ]' "no record, generic slot, another unit: derived from its CID"
check '[ "$(wanted_identity "" "wifi=? bt=?" $COTT_CID)" = "$d1" ]' "a slot with no identity at all: derived"

# A synthetic boot slot, trial slot and everything personalize touches.
mkdir -p "$T/bin" "$T/state" "$T/store/identity" "$T/dt/wifi" "$T/dt/bt"
printf '#!/bin/sh\n[ "${1:-}" = -r ] && { echo 6.18.48-r17; exit 0; }\nexec /bin/uname "$@"\n' > "$T/bin/uname"; chmod +x "$T/bin/uname"
printf '#!/bin/sh\n[ "$1" = is-active ] && { echo active; exit 0; }\nexit 0\n' > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
printf 'CONFIG_CMDLINE="console=ttyS2,115200 root=/dev/mmcblk0p13"\n' > "$T/config"
head -c 4096 /dev/urandom > "$T/ramdisk"
slot() {  # slot <wifi-hex> <bt-hex-stored>: a fresh boot slot and an empty trial slot
    mkdtb "$T/s.dtb" "$1" "$2"
    sh "$TOOL" bootimg "$T/zImage" "$T/s.dtb" "$T/slotA" "$T/config" "$T/ramdisk" >/dev/null
    head -c 8388608 /dev/zero > "$T/slotB"; rm -f "$T/state/pending" "$T/store/identity/radio"
}
run() { PATH="$T/bin:$PATH" NQ_KOTA_BOOT_SLOT="$T/slotA" NQ_KOTA_TRIAL_SLOT="$T/slotB" \
        NQ_KOTA_STATE_DIR="$T/state" NQ_KOTA_PERSIST_MNT=/ NQ_KOTA_IDENTITY_RECORD="$T/store/identity/radio" \
        NQ_KOTA_CID="$T/cid" NQ_KOTA_DT_ROOT="$T/dt" NQ_KOTA_HEALTH_WAIT_S=10 sh "$TOOL" "$@" 2>&1; }

echo "=== a release flashed onto another unit: its own identity, via the trial slot ==="
slot $GEN_W $GEN_B; echo $COTT_CID > "$T/cid"
out=$(run personalize --no-boot); rc=$?
check '[ $rc -eq 0 ]' "exit 0"
check 'echo "$out" | grep -q "all identity or header id"' "diffcheck passed: the repack is the booted image plus the identity"
# Outside the header's 20-byte SHA1 id (bytes 577..608 as cmp counts, which the
# random test ramdisk makes differ in 19 or 20 of them) exactly the 3+3 changed
# address bytes may differ -- deterministic, unlike the total.
nd=$(cmp -l "$T/slotA" "$T/slotB" 2>/dev/null | awk '$1 < 577 || $1 > 608' | wc -l | tr -d ' ')
check '[ "$nd" = 6 ]' "outside the header id exactly 6 bytes differ: 3 of the MAC, 3 of the BD address (got $nd)"
check '[ "$(sh "$TOOL" identity "$T/slotB")" = "$d1" ]' "the trial slot carries the derived identity"
check '[ "$(sh "$TOOL" identity "$T/slotA")" = "$GENERIC" ]' "the boot slot is untouched until the trial proves itself"
check '[ "$(awk "{print \$5}" "$T/state/pending" | tr , " ")" = "$d1" ]' "the pending marker names the identity autopromote must see"
check '[ "$(cat "$T/store/identity/radio")" = "$d1" ]' "and it is recorded in the store"

echo "=== the unit the generic identity belongs to: nothing happens ==="
slot $GEN_W $GEN_B; echo $OWNER_CID > "$T/cid"
out=$(run personalize --no-boot)
check 'echo "$out" | grep -q "identity ok: $GENERIC"' "reports ok"
check '[ ! -f "$T/state/pending" ]' "stages nothing"
check '[ "$(cat "$T/store/identity/radio")" = "$GENERIC" ]' "records its identity"

echo "=== a unit personalised before this existed (the cottage Q): no rename ==="
slot f88fca051f11 9cac73ca8ff8; echo $COTT_CID > "$T/cid"
out=$(run personalize --no-boot)
check 'echo "$out" | grep -q "identity ok: $COTTAGE"' "keeps the identity its slot carries, not the CID-derived one"
check '[ "$(cat "$T/store/identity/radio")" = "$COTTAGE" ]' "and records it"

echo "=== a full flash of a unit the store remembers: back to its own ==="
slot $GEN_W $GEN_B; echo $COTT_CID > "$T/cid"; echo "$COTTAGE" > "$T/store/identity/radio"
out=$(run personalize --no-boot)
check '[ "$(sh "$TOOL" identity "$T/slotB")" = "$COTTAGE" ]' "stages the remembered identity, not a derived one"

echo "=== a trial already pending: waits ==="
slot $GEN_W $GEN_B; echo $COTT_CID > "$T/cid"; mkdir -p "$T/state"; echo x > "$T/state/pending"
out=$(run personalize --no-boot)
check 'echo "$out" | grep -q "a trial boot is pending"' "does not stage over it"

echo "=== autopromote: only when the RUNNING kernel reports the staged identity ==="
slot $GEN_W $GEN_B; echo $COTT_CID > "$T/cid"; run personalize --no-boot >/dev/null
dtprop() { printf "$(echo "$2" | sed 's/../\\x&/g')" > "$T/dt/$1"; }
dtprop wifi/local-mac-address $GEN_W; dtprop bt/local-bd-address $GEN_B      # still the old DTB
out=$(run autopromote); rc=$?
check 'echo "$out" | grep -q "the trial slot did NOT boot"' "old identity running: the trial did not boot"
check '[ -f "$T/state/pending" ] && [ "$(sh "$TOOL" identity "$T/slotA")" = "$GENERIC" ]' "nothing promoted, the marker stays"
w=$(echo "$d1" | sed 's/.*wifi=\([^ ]*\).*/\1/;s/://g'); b=$(echo "$d1" | sed 's/.*bt=\([^ ]*\).*/\1/;s/://g')
b_rev=$(echo "$b" | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\6\5\4\3\2\1/')
dtprop wifi/local-mac-address "$w"; dtprop bt/local-bd-address "$b_rev"
out=$(run autopromote)
check 'echo "$out" | grep -q "running the staged kernel"' "new identity running: past the gate, on to the health check"
check 'echo "$out" | grep -q "healthy after 0s — promoting"' "and promoted WITHOUT a network (a fresh unit has none yet)"
check '[ ! -f "$T/state/pending" ] && [ "$(sh "$TOOL" identity "$T/slotA")" = "$d1" ]' "the boot slot now carries the unit's own identity"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
