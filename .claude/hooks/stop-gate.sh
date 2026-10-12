#!/usr/bin/env bash
# Stop: when code changed since the last green run, run the fast lane before
# Claude may finish — `just check-affected` when the justfile has it (the
# lane narrowed to what a change reaches; see the harness CHANGELOG, 11),
# else `just check`. A failure blocks the stop once (exit 2, the output goes
# back to Claude); if it still fails on the retry, the stop is allowed and
# the user sees the failure (exit 1).
#
# This repo has no `check-affected`: its components (userspace daemons, pmos
# packages, scripts, the companion app) name each other in code, packaging
# and tests, so what a change reaches is the whole repo.
#
# Skipped while background agents of this session are still working
# (`background_tasks` in the hook input: a subagent, teammate or workflow):
# their half-finished edits would fail the check and spend minutes of CPU on
# every turn. The turn in which the last of them reports back ends with an
# empty list, and the check runs then.
set -uo pipefail

read -r active busy < <(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    data = {}
tasks = data.get("background_tasks") or []
busy = sum(1 for t in tasks if isinstance(t, dict) and t.get("type") in ("subagent", "teammate", "workflow"))
print(data.get("stop_hook_active", False), busy)
')
[[ "${busy:-0}" -gt 0 ]] && exit 0
cd "${CLAUDE_PROJECT_DIR:?}" || exit 1

# What `just check` covers; a change to docs alone does not run it.
paths=(userspace pmos scripts tools tests companion/app/lib companion/app/test companion/app/tool
  companion/app/android companion/app/pubspec.yaml companion/app/analysis_options.yaml
  docker-build.sh build-and-flash.sh make-bootimg.py raw2simg.py
  justfile lefthook.yml ruff.toml .editorconfig .shellcheckrc)
# Before the first commit there is no HEAD: compare with the empty tree.
base="$(git rev-parse -q --verify HEAD)" || base="$(git hash-object -t tree /dev/null)"
# A git failure must not read as "nothing changed": run the check, uncached.
if ! diff="$(git diff "$base" --binary -- "${paths[@]}")" ||
  ! untracked="$(git ls-files --others --exclude-standard -- "${paths[@]}")"; then
  diff="" untracked="" base=""
fi
[[ -n "$base" && -z "$diff" && -z "$untracked" ]] && exit 0

fingerprint="$(
  {
    echo "$base"
    printf '%s' "$diff"
    while IFS= read -r f; do [[ -f "$f" ]] && { echo "== $f"; cat "$f"; }; done <<<"$untracked"
  } | shasum -a 256 | cut -d' ' -f1
)"
stamp="$(git rev-parse --git-dir)/claude-check-green"
[[ -n "$base" && -f "$stamp" && "$(cat "$stamp")" == "$fingerprint" ]] && exit 0

recipe=check
just --show check-affected >/dev/null 2>&1 && recipe=check-affected
log="$(mktemp "${TMPDIR:-/tmp}/check.XXXXXX")"
if just "$recipe" >"$log" 2>&1; then
  [[ -n "$base" ]] && echo "$fingerprint" >"$stamp"
  rm -f "$log"
  exit 0
fi

{
  echo "\`just $recipe\` fails on the current changes. Fix it before finishing (full log: $log):"
  tail -n 60 "$log"
} >&2
[[ "$active" == "True" ]] && exit 1
exit 2
