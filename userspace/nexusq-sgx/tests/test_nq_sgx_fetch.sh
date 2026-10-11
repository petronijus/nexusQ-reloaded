#!/bin/sh
# nq-sgx-fetch against a fake wget serving fixture files: the whole pinned
# set or nothing, the per-file fallback origin, idempotence, and that a bad
# download never replaces an installed set.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tool="$here/../nq-sgx-fetch"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0

# Fixture "blobs": small files, with a sums list made from them.
mkdir -p "$work/ti" "$work/maemo"
for n in libsrv_um libsrv_init libusc libglslcompiler libGLESv2_PVR_MESA libpvr_dri_support libpvr2d; do
	printf '%s fixture\n' "$n" >"$work/ti/$n.so.1.17.4948957"
	cp "$work/ti/$n.so.1.17.4948957" "$work/maemo/"
done
printf 'TI TSPA fixture\n' >"$work/ti/LICENSE"
(cd "$work/ti" && sha256sum ./* | sed 's#\./##') >"$work/sums"

# Fake wget: -O <out> <url>; serves https://ti/...<file>?id=... from $work/ti
# and https://maemo/...<file> from $work/maemo, by basename.
cat >"$work/wget" <<'W'
#!/bin/sh
while [ $# -gt 1 ]; do
	case $1 in -O) out=$2; shift 2 ;; *) shift ;; esac
done
url=$1
file=${url%%\?*}
file=${file##*/}
case $url in
https://ti/*) src=$FIX/ti/$file ;;
https://maemo/*) src=$FIX/maemo/$file ;;
*) exit 1 ;;
esac
[ -f "$src" ] || exit 8
cp "$src" "$out"
W
chmod +x "$work/wget"

run() {
	FIX=$work NQ_SGX_DIR="$work/state" NQ_SGX_SUMS="$work/sums" NQ_SGX_WGET="$work/wget" \
		NQ_SGX_TI_URL=https://ti NQ_SGX_MAEMO_URL=https://maemo sh "$tool" >"$work/out" 2>&1
}

check() {
	if [ "$1" -eq 0 ]; then echo "PASS $2"; else echo "FAIL $2"; sed 's/^/    /' "$work/out"; fails=$((fails + 1)); fi
}

run
rc=$?
[ $rc -eq 0 ] && [ -f "$work/state/lib/.complete" ] && [ -L "$work/state/lib/libsrv_um.so.1" ] &&
	[ "$(readlink "$work/state/lib/libusc.so")" = libusc.so.1.17.4948957 ] && [ -f "$work/state/lib/LICENSE" ]
check $? "installs the verified set with its .so.1/.so names"

run
grep -q "already installed" "$work/out"
check $? "a second run finds the set complete and fetches nothing"

rm -rf "$work/state"
printf 'tampered\n' >"$work/ti/libusc.so.1.17.4948957"
run
rc=$?
[ $rc -eq 0 ] && [ -f "$work/state/lib/.complete" ] && cmp -s "$work/state/lib/libusc.so.1.17.4948957" "$work/maemo/libusc.so.1.17.4948957"
check $? "a file that fails its hash at TI is taken from the fallback origin"

printf 'tampered too\n' >"$work/maemo/libusc.so.1.17.4948957"
rm -f "$work/state/lib/.complete"
run
rc=$?
[ $rc -eq 1 ] && [ -f "$work/state/lib/libsrv_um.so.1.17.4948957" ] && [ ! -f "$work/state/lib/.complete" ]
check $? "no origin with the pinned file: exit 1, the installed set stays"

rm -rf "$work/state"
run
rc=$?
[ $rc -eq 1 ] && [ ! -d "$work/state/lib" ] && [ -z "$(ls -A "$work/state")" ]
check $? "a failed first fetch leaves no partial set and no temp dir"

mkdir -p "$work/state/.fetch.stale1" "$work/state/lib.old"
: >"$work/state/.fetch.stale1/partial"
cp "$work/maemo/libusc.so.1.17.4948957" "$work/ti/libusc.so.1.17.4948957"
printf 'libusc fixture\n' >"$work/ti/libusc.so.1.17.4948957"
printf 'libusc fixture\n' >"$work/maemo/libusc.so.1.17.4948957"
run
rc=$?
[ $rc -eq 0 ] && [ ! -e "$work/state/.fetch.stale1" ] && [ ! -e "$work/state/lib.old" ] && [ -f "$work/state/lib/.complete" ]
check $? "temp dirs a killed run left behind are removed"

[ $fails -eq 0 ] && echo "PASS all" || echo "FAIL $fails"
exit $((fails != 0))
