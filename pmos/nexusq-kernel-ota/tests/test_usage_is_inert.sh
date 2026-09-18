#!/usr/bin/env bash
# Tests that printing help cannot DO anything — above all, cannot reboot the Q.
#
# What is being protected: `usage()` wrote its text with an UNQUOTED heredoc
# (`cat <<EOF`), and the help text names the rescue shell's way out as
# `reboot` — in backticks. An unquoted heredoc performs command substitution,
# so the backticks were not punctuation, they were a command, and the shell ran
# `reboot` before `cat` ever printed a line. Every invalid invocation — a typo,
# a wrong subcommand, or just `nq-kernel-ota` on its own to see what it takes —
# rebooted the device.
#
# Measured on the cottage Q on 2026-09-18: `nq-kernel-ota` with no arguments,
# run to read its usage, took the box down mid-session. `sh -x` showed the
# order plainly:
#
#     + usage
#     + reboot          <- the backticks in the help text
#     + cat
#
# The two other heredocs (`rescue`, `try`) held no backticks at the time and so
# were inert by luck rather than by construction; both print warnings to someone
# about to reboot a device deliberately, which is the worst place to leave a
# latent one. All three are quoted now.
#
# Runs on any host: `reboot` is shimmed onto PATH, nothing is staged, no device,
# no kernel and no root are needed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../../../userspace/nexusq-kernel-ota/nq-kernel-ota"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

# A PATH full of the things a help text must never be able to set off. Each
# records the call instead of performing it, so the test reports the bug rather
# than reproducing it.
mkdir -p "$T/bin"
for danger in reboot shutdown halt poweroff systemctl dd; do
    cat > "$T/bin/$danger" <<STUB
#!/bin/sh
echo "$danger \$*" >> "$T/fired"
exit 0
STUB
    chmod +x "$T/bin/$danger"
done

# --- 1. the reachable heredoc: usage, via every path that reaches it ---------
for args in "" "--help" "definitely-not-a-command" "stat"; do
    rm -f "$T/fired"
    out=$(PATH="$T/bin:$PATH" sh "$TOOL" $args 2>&1); rc=$?
    label=${args:-<no arguments>}

    if [ -s "$T/fired" ]; then
        bad "$label ran: $(tr '\n' ';' < "$T/fired")"
    else
        ok "$label set nothing off"
    fi

    case "$out" in
        *"usage: nq-kernel-ota"*) ok "$label printed the usage text" ;;
        *) bad "$label printed no usage (rc=$rc): $(printf '%s' "$out" | head -1)" ;;
    esac

    # The backticked word must survive to the output verbatim — quoting the
    # heredoc is only correct if it also stopped mangling the text.
    case "$out" in
        *'`reboot`'*) ok "$label kept \`reboot\` as text" ;;
        *) bad "$label lost the backticked reboot from its help" ;;
    esac
done

# --- 2. the heredocs a test cannot reach without a device --------------------
# `rescue` and `try` print theirs only after writing the trial slot, so no
# assertion can run them here. Read them structurally instead: an unquoted
# delimiter is the defect itself, whether or not today's text exploits it.
unquoted=$(grep -n '<<[A-Za-z_][A-Za-z_0-9]*$' "$TOOL" || true)
if [ -n "$unquoted" ]; then
    bad "unquoted heredoc delimiter(s) — substitution is live inside: $unquoted"
else
    ok "every heredoc delimiter is quoted"
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
