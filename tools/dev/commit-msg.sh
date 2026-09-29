#!/usr/bin/env bash
# commit-msg hook: Conventional Commits (https://www.conventionalcommits.org).
#   type(scope)!: summary     e.g. `fix(wifi): the watchdog reconnects a stranded wlan0`
#
# Also accepted, because tools write them: git's own Merge/Revert/fixup!
# subjects, and ai-config's project-sync, which commits this repo as
# `autosync(<branch>): <host> <time>` at the end of a session.
set -euo pipefail

subject="$(head -n1 "$1")"
types="feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert"

if [[ "$subject" =~ ^(Merge|Revert|fixup!|squash!|amend!) ]]; then exit 0; fi
if [[ "$subject" =~ ^autosync\([^\)]+\):\ .+ ]]; then exit 0; fi
if [[ "$subject" =~ ^($types)(\([a-z0-9,/._-]+\))?!?:\ .+ ]]; then
  if ((${#subject} > 72)); then
    echo "commit-msg: subject is ${#subject} characters; keep it within 72 (the detail goes in the body)." >&2
    exit 1
  fi
  exit 0
fi

cat >&2 <<MSG
commit-msg: "$subject"
is not a Conventional Commit. Use  type(scope)!: summary
  types:  ${types//|/, }
  scopes: kernel, dts, device, firmware, control, mqtt, setupd, btagent,
          nexusqd, healthd, alsa-vol, kernel-ota, rootfs-ab, ota, build,
          diag, app, ios, android, release, dev, docs (optional)
MSG
exit 1
