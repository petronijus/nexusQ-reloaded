#!/bin/sh
# The container half of scripts/ota-repo-gate.sh — read that file first; the
# checks are numbered the same. Runs in an Alpine edge container with:
#   /ours            the staged repo (armv7/*.apk, APKINDEX.tar.gz)
#   /units/<n>/      unit states: lib/apk/db/, etc/apk/world
#   $LABELS          "<n><TAB><name of unit n>" per line
#   $LISTED          the names in pmos/ota-packages.list
#   $PROVIDES        image-only <name>=<version> pairs
#   $REPOS           upstream repositories, one per line
#   $PULL            0 = offline (do not upgrade apk-tools)
# Exit 0 pass, 1 refused. Warnings that do not refuse go to stderr with "!!?".
set -u

say() { echo "$@" >&2; }
indent() { sed "s/^/     /" >&2; }
KERNEL=linux-google-steelhead   # a System update --ignore's it (nexusq-control _ota_upgrade_args)
ACTION='(Upgrading|Downgrading|Replacing|Reinstalling|Installing|Purging)'

# The image lags edge (alpine:edge carried apk-tools 3.0.7 on 2026-11-16 while
# the units ran 3.0.9): resolve with the apk a unit has today.
if [ "$PULL" != 0 ] && ! apk upgrade --no-cache -q apk-tools > /tmp/apkup 2>&1; then
    say "  !! could not bring the container's apk up to edge:"
    indent < /tmp/apkup
    exit 1
fi

echo /ours > /tmp/ours
{ echo /ours; printf '%s\n' "$REPOS"; } > /tmp/all
printf '%s\n' "$REPOS" > /tmp/upstream

# Every index is fetched ONCE, into a cache every simulation below reads, so a
# fetch failing later cannot pass for something else.
# update <root> <repositories-file> <log>: one retry, so a single CDN hiccup
# does not refuse a correct publish.
CACHE=/cache
mkdir -p $CACHE
update() {
    apk --root "$1" --arch armv7 --allow-untrusted --no-interactive --cache-dir $CACHE \
        --repositories-file "$2" update > "$3" 2>&1 \
        || { sleep 5; apk --root "$1" --arch armv7 --allow-untrusted --no-interactive --cache-dir $CACHE \
                 --repositories-file "$2" update > "$3" 2>&1; }
}

R=/sim
mkdir -p $R
A="apk --root $R --arch armv7 --allow-untrusted --no-interactive --cache-dir $CACHE"
if ! $A --repositories-file /tmp/all --initdb add > /tmp/init 2>&1; then
    say "  !! could not set up an armv7 root:"
    indent < /tmp/init
    exit 1
fi

# 0. every repository answers
if ! update $R /tmp/all /tmp/update; then
    say "  !! a repository a unit uses did not answer; a unit would refuse to update"
    say "     now, and the checks below would resolve without it. apk says:"
    indent < /tmp/update
    exit 1
fi

# What the repo carries: "name version" per line.
$A --repositories-file /tmp/ours list --available 2>/dev/null \
    | awk '{print $1}' | sed -E 's/^(.+)-([^-]+-r[0-9]+)$/\1 \2/' > /tmp/carried
if [ ! -s /tmp/carried ]; then
    say "  !! the staged repo carries no packages"
    exit 1
fi
fail=0

# 1. complete
missing=""
for p in $LISTED; do
    awk -v p="$p" '$1 == p {f=1} END {exit !f}' /tmp/carried || missing="$missing $p"
done
if [ -n "$missing" ]; then
    say "  !! listed in pmos/ota-packages.list but not in the repo:$missing"
    say "     (no build of it on the volume, or skipped as too big above). A unit would"
    say "     keep an older or upstream build, or hold back whatever depends on it."
    say "     Build it and publish again."
    fail=1
fi

# 2. installable from scratch, on a root that has what every image has
: > $R/lib/apk/db/installed
: > $R/etc/apk/world
for pv in $PROVIDES; do
    printf 'C:Q1AAAAAAAAAAAAAAAAAAAAAAAAAAA=\nP:%s\nV:%s\nA:armv7\nS:1\nI:1\nT:installed from the image\nU:none\nL:none\no:%s\n\n' \
        "${pv%%=*}" "${pv#*=}" "${pv%%=*}" >> $R/lib/apk/db/installed
    echo "${pv%%=*}" >> $R/etc/apk/world
done
names=$(awk '{print $1}' /tmp/carried | tr '\n' ' ')
# shellcheck disable=SC2086
if ! $A --repositories-file /tmp/all add --simulate $names > /tmp/sim 2>&1; then
    say "  !! a unit could not install this repo; apk says:"
    grep -v ") Installing " /tmp/sim | indent
    exit 1
fi

# 3. ours wins
while read -r name ver; do
    grep -qF ") Installing $name ($ver)" /tmp/sim && continue
    got=$(sed -n "s/.*) Installing $name (\\(.*\\))\$/\\1/p" /tmp/sim | head -1)
    say "  !! $name: the repo carries $ver but a unit would install ${got:-nothing}"
    fail=1
done < /tmp/carried
[ "$fail" -eq 0 ] || exit 1
echo "  ok: all listed packages present; the $(wc -l < /tmp/carried) carried install as published ($(grep -c ") Installing " /tmp/sim) packages from scratch)"

# 4. each unit's own System update
OUR_URL='petronijus.github.io/nexusQ-reloaded/nexusq'
# simulate <unit-dir> <root> <repositories-file> <log>; indexes come from the cache
simulate() {
    rm -rf "$2"
    mkdir -p "$2/lib/apk" "$2/etc/apk"
    cp -a "$1/lib/apk/db" "$2/lib/apk/"
    cp "$1/etc/apk/world" "$2/etc/apk/world"
    apk --root "$2" --arch armv7 --allow-untrusted --no-interactive --cache-dir $CACHE \
        --repositories-file "$3" upgrade --available --ignore $KERNEL --simulate > "$4" 2>&1
}
# Where each package ends: "name version" or "name purged" (else the installed one).
ends() {  # ends <log>
    sed -nE "s/^\\([ 0-9]+\\/[0-9]+\\) (Upgrading|Downgrading|Replacing|Reinstalling|Installing) ([^ ]+) \\((.* -> )?([^ )]+)\\)\$/\\2 \\4/p" \
        "$1" > /tmp/moved
    sed -nE "s/^\\([ 0-9]+\\/[0-9]+\\) Purging ([^ ]+) .*/\\1 purged/p" "$1" >> /tmp/moved
}
errors() { grep -E '^(ERROR|  )' "$1" | grep -vE ") $ACTION " | awk '!seen[$0]++'; }

units=0
for u in /units/*; do
    [ -d "$u" ] || continue
    units=$((units + 1))
    label=$(printf '%s' "$LABELS" | awk -F '\t' -v n="$(basename "$u")" '$1 == n {print $2}')
    [ -n "$label" ] || label="unit $(basename "$u")"
    awk '/^P:/{p=substr($0,3)} /^V:/{print p, substr($0,3)}' "$u/lib/apk/db/installed" > /tmp/had

    # The unit's own repositories when they were recorded (ours replaced by the
    # staged repo), else the default set.
    if [ -s "$u/etc/apk/repositories" ]; then
        grep -vE '^[[:space:]]*(#|$)' "$u/etc/apk/repositories" | grep -vF "$OUR_URL" > /tmp/u-upstream || true
        if ! cmp -s /tmp/u-upstream /tmp/upstream; then
            say "  note: $label uses other upstream repositories than the default; simulating with its own"
            { echo /ours; cat /tmp/u-upstream; } > /tmp/u-all
            if ! update /sim /tmp/u-all /tmp/u-update; then
                say "  !! $label: a repository it uses did not answer; apk says:"
                indent < /tmp/u-update
                fail=1
                continue
            fi
        fi
    else
        cp /tmp/upstream /tmp/u-upstream
    fi
    { echo /ours; cat /tmp/u-upstream; } > /tmp/u-all

    # Upstream alone as the baseline: what fails without this repo is not its
    # doing, and refusing it would block every publish (a hotfix too).
    base=0; simulate "$u" /base /tmp/u-upstream /tmp/base || base=1
    if ! simulate "$u" /u /tmp/u-all /tmp/unit; then
        if [ "$base" -eq 0 ]; then
            say "  !! $label: its System update fails with this repo (and succeeds without it); apk says:"
            grep -vE ") $ACTION " /tmp/unit | indent
            fail=1
            continue
        fi
        errors /tmp/base > /tmp/base.err
        errors /tmp/unit > /tmp/unit.err
        if grep -qvxFf /tmp/base.err /tmp/unit.err; then
            say "  !! $label: its System update already fails without this repo, and this repo adds:"
            grep -vxFf /tmp/base.err /tmp/unit.err | indent
            fail=1
            continue
        fi
        say "  !!? $label: NOT JUDGED: its System update fails even without this repo (upstream"
        say "      breaks units today), and this repo adds no error of its own. apk says:"
        indent < /tmp/unit.err
        continue
    fi
    [ "$base" -eq 0 ] || say "  note: $label: its System update fails without this repo and succeeds with it"
    ends /tmp/unit
    bad=0
    while read -r name ver; do
        [ "$name" = "$KERNEL" ] && continue
        was=$(awk -v n="$name" '$1 == n {print $2}' /tmp/had)
        end=$(awk -v n="$name" '$1 == n {v=$2} END {print v}' /tmp/moved)
        [ -n "$end" ] || end=$was
        [ -n "$end" ] || continue                     # not on this unit, and not pulled in
        if [ "$end" = purged ]; then
            say "  !! $label: $name would be REMOVED from the unit: nothing it has installed"
            say "     depends on it any more, yet the repo still publishes it"
            bad=1
        elif [ "$end" != "$ver" ]; then
            say "  !! $label: $name: the repo carries $ver but the unit (${was:-without it}) would end at $end"
            bad=1
        elif [ -n "$was" ] && [ "$was" != "$ver" ] && grep -qE ") Downgrading $name \\(" /tmp/unit; then
            say "  !! $label: $name would be ROLLED BACK from $was to $ver: either the build volume"
            say "     is behind what the unit runs, or the unit carries a test build never"
            say "     published. Publish from the newer build, or re-capture the unit after"
            say "     it changes (scripts/capture-unit-apk-state.sh)."
            bad=1
        fi
    done < /tmp/carried
    if [ "$bad" -eq 0 ]; then
        echo "  ok: $label: System update succeeds and ends at the published versions ($(grep -cE ") $ACTION " /tmp/unit) changes)"
    else
        fail=1
    fi
done
[ "$units" -gt 0 ] || say "  !!? no unit state given: a unit's System update was not simulated"
[ "$fail" -eq 0 ] || exit 1
echo "  ok: [$(apk --version | cut -d, -f1)]"
