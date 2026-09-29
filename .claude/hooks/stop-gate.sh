#!/usr/bin/env bash
# Stop: when code changed since the last green run, run the fast lane
# (`just check`) before Claude may finish. A failure blocks the stop once
# (exit 2, the output goes back to Claude); if it still fails on the retry,
# the stop is allowed and the user sees the failure (exit 1).
set -uo pipefail

active="$(python3 -c 'import json, sys; print(json.load(sys.stdin).get("stop_hook_active", False))')"
cd "${CLAUDE_PROJECT_DIR:?}" || exit 1

# What `just check` covers; a change to docs alone does not run it.
paths=(userspace pmos scripts tools tests companion/app/lib companion/app/test companion/app/tool
  companion/app/android companion/app/pubspec.yaml companion/app/analysis_options.yaml
  docker-build.sh build-and-flash.sh make-bootimg.py raw2simg.py
  justfile lefthook.yml ruff.toml .editorconfig .shellcheckrc)
diff="$(git diff HEAD --binary -- "${paths[@]}")"
untracked="$(git ls-files --others --exclude-standard -- "${paths[@]}")"
[[ -z "$diff" && -z "$untracked" ]] && exit 0

fingerprint="$(
  {
    git rev-parse HEAD
    printf '%s' "$diff"
    while IFS= read -r f; do [[ -f "$f" ]] && { echo "== $f"; cat "$f"; }; done <<<"$untracked"
  } | shasum -a 256 | cut -d' ' -f1
)"
stamp="$(git rev-parse --git-dir)/claude-check-green"
[[ -f "$stamp" && "$(cat "$stamp")" == "$fingerprint" ]] && exit 0

log="$(mktemp "${TMPDIR:-/tmp}/check.XXXXXX")"
if just check >"$log" 2>&1; then
  echo "$fingerprint" >"$stamp"
  rm -f "$log"
  exit 0
fi

{
  echo "\`just check\` fails on the current changes. Fix it before finishing (full log: $log):"
  tail -n 60 "$log"
} >&2
[[ "$active" == "True" ]] && exit 1
exit 2
