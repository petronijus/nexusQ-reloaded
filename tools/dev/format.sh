#!/usr/bin/env bash
# Format (or, with --check, verify) files by type. The single formatter entry
# point for `just fmt`, the lefthook pre-commit hook and the Claude Code
# PostToolUse hook, so all three agree.
#
#   tools/dev/format.sh [--check] <file>...
#   tools/dev/format.sh [--check] --all
#
#   Python  ruff (pinned below): lint fixes, then format; ruff.toml
#   Dart    dart format (tall style, the app's language version)
#   Kotlin  ktlint; style in .editorconfig
#   Shell   shellcheck — lint only, there is no shell formatter here
#   justfile  just --fmt
#
# Extensionless scripts (the daemons, the device tools) are classified by
# their shebang. C and Swift are not formatted (docs/development.md says why).
#
# Exit 1 when --check finds unformatted files, a linter reports something the
# formatter cannot fix, or a required tool is missing.
# Plain bash 3.2 (macOS /bin/bash) compatible.
set -uo pipefail

# One ruff for every machine: formatter output changes between releases.
RUFF=ruff@0.16.9

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$root" || exit 1

check=false
if [[ "${1:-}" == "--check" ]]; then check=true; shift; fi

files=()
if [[ "${1:-}" == "--all" ]]; then
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files --cached --others --exclude-standard)
else
  files=("$@")
fi

# The interpreter a file's shebang names (python3, sh, bash, …), or nothing.
interpreter() {
  local line
  IFS= read -r line <"$1" 2>/dev/null || return 0
  [[ "$line" == '#!'* ]] || return 0
  line="${line#\#!}"
  set -- $line
  [[ "${1##*/}" == env ]] && shift
  echo "${1##*/}"
}

python=() dart=() kotlin=() shell=() justfiles=()
for f in ${files[@]+"${files[@]}"}; do
  [[ -f "$f" && ! -L "$f" ]] || continue
  case "$f" in
    reverse-eng/* | scratchpad/* | private/* | output/* | nq-captures/*) continue ;; # not ours
    */GeneratedPluginRegistrant.* | *.g.dart | *.freezed.dart) continue ;;           # generated
    *.py) python+=("$f") ;;
    *.dart) dart+=("$f") ;;
    *.kt | *.kts) kotlin+=("$f") ;;
    *.sh | *.pre-install | *.post-install | *.pre-upgrade | *.post-upgrade | *.post-deinstall | *.trigger)
      shell+=("$f") ;;
    justfile | */justfile) justfiles+=("$f") ;;
    */APKBUILD | APKBUILD) ;; # abuild's own dialect: its variables look unused to shellcheck
    */*.* | *.*) ;;           # some other type
    *)
      case "$(interpreter "$f")" in
        python3 | python) python+=("$f") ;;
        sh | bash | dash | ash) shell+=("$f") ;;
      esac
      ;;
  esac
done

status=0
run() { "$@" || status=1; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "format.sh: $1 is required for $2 files (just doctor)" >&2; status=1; return 1; }; }

if ((${#python[@]})) && need uvx Python; then
  if $check; then
    run uvx "$RUFF" format --check --quiet --force-exclude "${python[@]}"
    run uvx "$RUFF" check --quiet --force-exclude "${python[@]}"
  else
    # Fix lint first: removing an import can leave lines only the formatter cleans.
    run uvx "$RUFF" check --fix --quiet --force-exclude "${python[@]}"
    run uvx "$RUFF" format --quiet --force-exclude "${python[@]}"
  fi
fi

if ((${#dart[@]})) && need dart Dart; then
  if $check; then run dart format --output=none --set-exit-if-changed "${dart[@]}"
  else run dart format --show=none "${dart[@]}"; fi
fi

if ((${#kotlin[@]})) && need ktlint Kotlin; then
  if $check; then run ktlint --relative "${kotlin[@]}"
  else run ktlint --relative -F "${kotlin[@]}"; fi
fi

if ((${#shell[@]})) && need shellcheck shell; then
  run shellcheck --severity=warning --format=gcc "${shell[@]}"
fi

if ((${#justfiles[@]})) && need just justfile; then
  for j in "${justfiles[@]}"; do
    if $check; then run just --unstable --fmt --check --justfile "$j" >/dev/null
    else run just --unstable --fmt --justfile "$j"; fi
  done
fi

exit $status
