#!/usr/bin/env bash
# Run the repo's shell test suites, one lane at a time.
#
#   tools/dev/test-shell.sh host     suites that run on this machine (fast lane)
#   tools/dev/test-shell.sh docker   suites that run the code in an Alpine
#                                    container playing the device (full gate)
#
# A suite is */tests/test_*.sh or scripts/tests/test-*.sh. It belongs to the
# docker lane when its header says so, within its first five lines:
#     # needs: docker
# Each suite prints its own PASS/FAIL lines; this prints one line per suite
# and, for a failing one, the end of its output. Exit 1 if any suite failed.
# Plain bash 3.2 (macOS /bin/bash) compatible.
set -uo pipefail

lane="${1:-}"
[[ "$lane" == host || "$lane" == docker ]] || { echo "usage: $0 host|docker" >&2; exit 2; }

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$root" || exit 1

# Suites build ext4 images (mkfs.ext4 -d, debugfs). Homebrew's e2fsprogs is
# keg-only on macOS, so it is not on PATH until put there.
if ! command -v mkfs.ext4 >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
  e2fs="$(brew --prefix e2fsprogs 2>/dev/null)"
  [[ -n "$e2fs" && -d "$e2fs/sbin" ]] && PATH="$e2fs/sbin:$e2fs/bin:$PATH"
fi

if [[ "$lane" == docker ]] && ! docker info >/dev/null 2>&1; then
  echo "test-shell: the docker lane needs a running Docker (just doctor)" >&2
  exit 1
fi

suites=()
while IFS= read -r f; do
  if head -n5 "$f" | grep -q '^# needs: docker'; then this=docker; else this=host; fi
  [[ "$this" == "$lane" ]] && suites+=("$f")
done < <(git ls-files --cached --others --exclude-standard '*/tests/test_*.sh' 'scripts/tests/test-*.sh')

failed=0
log="$(mktemp "${TMPDIR:-/tmp}/test-shell.XXXXXX")"
for s in ${suites[@]+"${suites[@]}"}; do
  start=$SECONDS
  # Each suite names its own interpreter; `sh` suites must stay POSIX.
  if "$(head -n1 "$s" | sed -E 's|^#! *(/usr/bin/env +)?||; s| .*||')" "$s" >"$log" 2>&1; then
    printf '  \033[32mok\033[0m    %-68s %3ss\n' "$s" $((SECONDS - start))
  else
    failed=$((failed + 1))
    printf '  \033[31mFAIL\033[0m  %-68s %3ss\n' "$s" $((SECONDS - start))
    tail -n 25 "$log" | sed 's/^/        /'
  fi
done
rm -f "$log"

echo "test-shell ($lane): ${#suites[@]} suites, $failed failed"
((failed == 0))
