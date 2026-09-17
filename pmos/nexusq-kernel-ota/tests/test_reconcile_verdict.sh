#!/usr/bin/env bash
# Tests for `nq-kernel-ota reconcile` — the step that makes the package database
# and /boot describe the kernel that is actually running.
#
# What is being protected: `apk add --upgrade` exits 0 when there is nothing
# newer to fetch, so its exit code says "apk ran", not "apk agrees". Measured on
# 2026-09-17: a kernel staged from a LOCAL apk (scp'd to the device, then
# `stage-apk`) promoted correctly, and the reconcile logged
#   "apk now agrees: linux-google-steelhead-6.18.48-r1"
# while `uname -r` was 6.18.48-r2 — the OTA repo had not published r2 yet, so the
# upgrade was a successful no-op. /boot was left describing r1, which is exactly
# the failure the WARNING branch is written about, and the only signal there was
# said the opposite. Anything rebuilding an image from /boot (verify-self, the
# rescue builder) would have used the wrong kernel.
#
# Runs on any host: `apk` and `uname` are stubbed on PATH, so no device, no
# kernel and no root are needed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../../../userspace/nexusq-kernel-ota/nq-kernel-ota"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

# stubs <running-kernel> <what-apk-reports-before> <what-apk-reports-after>
# A tiny fake apk whose `add --upgrade` succeeds while leaving `info -v` at
# <after> — the real no-op behaviour when the repo has nothing newer.
stubs() {
    mkdir -p "$T/bin"
    printf '%s\n' "$2" > "$T/before"
    printf '%s\n' "$3" > "$T/after"
    cat > "$T/bin/apk" <<STUB
#!/bin/sh
case "\$1" in
  info) if [ -f "$T/upgraded" ]; then echo "linux-google-steelhead-\$(cat "$T/after")"
        else echo "linux-google-steelhead-\$(cat "$T/before")"; fi ;;
  add)  touch "$T/upgraded"; exit 0 ;;          # exit 0 even when nothing moved
esac
exit 0
STUB
    cat > "$T/bin/uname" <<STUB
#!/bin/sh
[ "\${1:-}" = "-r" ] && { echo "$1"; exit 0; }
exec /bin/uname "\$@"
STUB
    chmod +x "$T/bin/apk" "$T/bin/uname"
    rm -f "$T/upgraded"
}

run() { PATH="$T/bin:$PATH" sh "$TOOL" reconcile 2>&1; }

# --- 1. the measured 2026-09-17 case: apk succeeds, database still disagrees ---
stubs 6.18.48-r2 6.18.48-r1 6.18.48-r1
OUT=$(run)
if printf '%s' "$OUT" | grep -q "WARNING: the package database still says linux-google-steelhead-6.18.48-r1"; then
    ok "repo has nothing newer -> WARNS instead of claiming agreement"
else
    bad "repo has nothing newer -> should WARN; got: $(printf '%s' "$OUT" | tr '\n' '|')"
fi
if printf '%s' "$OUT" | grep -q "apk now agrees"; then
    bad "must NOT claim agreement when uname -r and the database differ"
else
    ok "does not claim agreement while the database names another kernel"
fi
if printf '%s' "$OUT" | grep -q "the running kernel is 6.18.48-r2"; then
    ok "names the running kernel, so the mismatch is actionable"
else
    bad "the warning should name the running kernel"
fi

# --- 2. the upgrade really lands: database ends up on the running kernel -------
stubs 6.18.48-r2 6.18.48-r1 6.18.48-r2
OUT=$(run)
if printf '%s' "$OUT" | grep -q "apk now agrees: linux-google-steelhead-6.18.48-r2"; then
    ok "upgrade lands -> reports agreement on the running kernel"
else
    bad "upgrade lands -> should report agreement; got: $(printf '%s' "$OUT" | tr '\n' '|')"
fi

# --- 3. already in agreement: no apk call at all ------------------------------
stubs 6.18.48-r2 6.18.48-r2 6.18.48-r2
OUT=$(run)
if printf '%s' "$OUT" | grep -q "package database already agrees"; then
    ok "already in agreement -> short-circuits before touching the network"
else
    bad "already in agreement -> should short-circuit; got: $(printf '%s' "$OUT" | tr '\n' '|')"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
