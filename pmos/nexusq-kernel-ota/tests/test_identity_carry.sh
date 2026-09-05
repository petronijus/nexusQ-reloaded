#!/usr/bin/env bash
# Tests for `nq-kernel-ota carry-identity` / `identity` — the per-unit identity
# carry-over that stage-apk performs before packing a new kernel.
#
# What is being protected: the WiFi MAC and BT address of every unit but the
# first exist ONLY as a flash-time byte patch of the DTB appended to the boot
# image. The kernel apk carries the first unit's values, so a kernel OTA without
# this step renames the device on both radios — measured on the cottage unit on
# 2026-09-05, its first kernel OTA. This proves the tool finds the real DTB
# inside a packed boot image (past the decoy magic in the zImage), touches only
# the 12 identity payload bytes, leaves everything else byte-identical, and refuses to
# guess when a property is missing or ambiguous.
#
# Runs on any host with python3: it builds synthetic FDT blobs and packs them
# with the tool's own `bootimg` command, so no device and no kernel is needed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../../../userspace/nexusq-kernel-ota/nq-kernel-ota"
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
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

PRAGUE_W=f88fca2048e1; PRAGUE_B=e54920ca8ff8   # first unit, as the DTS stores them
COTT_W=f88fca051f11;   COTT_B=9cac73ca8ff8     # cottage unit

echo "=== identity: read out of a bare DTB and out of a packed boot image ==="
mkdtb "$T/cottage.dtb" $COTT_W $COTT_B
check '[ "$(sh "$TOOL" identity "$T/cottage.dtb")" = "wifi=f8:8f:ca:05:1f:11 bt=f8:8f:ca:73:ac:9c" ]' \
      "bare DTB: wifi in order, bt reversed back into reading order"
sh "$TOOL" bootimg "$T/zImage" "$T/cottage.dtb" "$T/slotA.img" "$T/config" "$T/ramdisk" >/dev/null || bad "bootimg failed"
check '[ "$(sh "$TOOL" identity "$T/slotA.img")" = "wifi=f8:8f:ca:05:1f:11 bt=f8:8f:ca:73:ac:9c" ]' \
      "boot image: finds the real DTB past the decoy magic in the zImage"

echo "=== carry: the apk's first-unit DTB takes on the boot slot's identity ==="
mkdtb "$T/apk.dtb" $PRAGUE_W $PRAGUE_B; cp "$T/apk.dtb" "$T/apk.orig.dtb"
out=$(sh "$TOOL" carry-identity "$T/slotA.img" "$T/apk.dtb" 2>&1); rc=$?
check '[ $rc -eq 0 ]' "exit 0"
check 'echo "$out" | grep -q "local-mac-address carried over: f8:8f:ca:20:48:e1 -> f8:8f:ca:05:1f:11"' "says what it did to the WiFi MAC"
check 'echo "$out" | grep -q "local-bd-address carried over: f8:8f:ca:20:49:e5 -> f8:8f:ca:73:ac:9c"' "and to the BT address, in reading order"
check '[ "$(sh "$TOOL" identity "$T/apk.dtb")" = "wifi=f8:8f:ca:05:1f:11 bt=f8:8f:ca:73:ac:9c" ]' "the DTB now reads as the cottage unit"
check '[ "$(stat -f %z "$T/apk.dtb" 2>/dev/null || stat -c %s "$T/apk.dtb")" = "$(stat -f %z "$T/apk.orig.dtb" 2>/dev/null || stat -c %s "$T/apk.orig.dtb")" ]' "blob length unchanged (byte patch, not re-serialised)"
diffbytes=$(cmp -l "$T/apk.orig.dtb" "$T/apk.dtb" | wc -l | tr -d ' ')
# Both units share the f8:8f:ca OUI, so of the 12 payload bytes only 3 + 3 move —
# the same "expect exactly 6" the flash-time recipe checks by hand.
check '[ "$diffbytes" -eq 6 ]' "exactly 6 bytes differ — 3 of the MAC, 3 of the BD address (got $diffbytes)"
check 'cmp -s <(python3 -c "import sys;d=open(sys.argv[1],\"rb\").read();print(d.find(bytes.fromhex(\"0200deadbeef\"))>0)" "$T/apk.dtb") <(echo True)' "the ethernet mac-address decoy is untouched"

echo "=== carry: already identical is a no-op that says so ==="
out=$(sh "$TOOL" carry-identity "$T/slotA.img" "$T/apk.dtb" 2>&1); rc=$?
check '[ $rc -eq 0 ] && echo "$out" | grep -q "0 properties patched"' "second run patches nothing"
check 'echo "$out" | grep -q "local-mac-address already f8:8f:ca:05:1f:11"' "and reports the value it found"

echo "=== carry refuses to guess ==="
mkdtb "$T/dup.dtb" $PRAGUE_W $PRAGUE_B dup; cp "$T/dup.dtb" "$T/dup.orig.dtb"
out=$(sh "$TOOL" carry-identity "$T/slotA.img" "$T/dup.dtb" 2>&1); rc=$?
check '[ $rc -ne 0 ] && echo "$out" | grep -q "expected exactly one 6-byte local-mac-address, found 2"' "two local-mac-address properties: refuses"
check 'cmp -s "$T/dup.dtb" "$T/dup.orig.dtb"' "and writes nothing"
mkdtb "$T/nomac.dtb" $PRAGUE_W $PRAGUE_B nomac
out=$(sh "$TOOL" carry-identity "$T/slotA.img" "$T/nomac.dtb" 2>&1); rc=$?
check '[ $rc -ne 0 ] && echo "$out" | grep -q "found 0"' "destination without the property: refuses"
mkdtb "$T/src-nomac.dtb" $COTT_W $COTT_B nomac
mkdtb "$T/dst.dtb" $PRAGUE_W $PRAGUE_B
out=$(sh "$TOOL" carry-identity "$T/src-nomac.dtb" "$T/dst.dtb" 2>&1); rc=$?
check '[ $rc -ne 0 ]' "SOURCE without the property: refuses (a legacy slot is not an identity)"
check '[ "$(sh "$TOOL" identity "$T/src-nomac.dtb")" = "wifi=? bt=f8:8f:ca:73:ac:9c" ]' "identity prints ? for what it cannot find, not a guess"
out=$(sh "$TOOL" carry-identity "$T/slotA.img" "$T/slotA.img" 2>&1); rc=$?
check '[ $rc -ne 0 ] && echo "$out" | grep -q "must be a bare .dtb"' "a boot image is not a valid destination"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
