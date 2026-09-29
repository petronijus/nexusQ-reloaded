#!/usr/bin/env bash
# PostToolUse (Edit|Write|NotebookEdit|Bash): format every repo file the call
# wrote — with an edit tool or from the shell (redirections, sed -i, tee, cp,
# heredocs; see tool_paths.py) — using the same tools/dev/format.sh the
# pre-commit hook uses. Exit 2 hands a complaint it cannot fix back to Claude.
set -uo pipefail

root="${CLAUDE_PROJECT_DIR:?}"
input="$(cat)"

files=()
while IFS=$'\t' read -r kind path; do
  [[ "$kind" != R && "$path" == "$root/"* && -f "$path" ]] && files+=("${path#"$root/"}")
done < <(printf '%s' "$input" | python3 "$(dirname "$0")/tool_paths.py")
((${#files[@]})) || exit 0

if ! out="$("$root/tools/dev/format.sh" "${files[@]}" 2>&1)"; then
  printf 'Formatting %s reported problems it could not fix:\n%s\n' "${files[*]}" "$out" >&2
  exit 2
fi
exit 0
