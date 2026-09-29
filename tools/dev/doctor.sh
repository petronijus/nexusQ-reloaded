#!/usr/bin/env bash
# Checks this machine against the toolchain pinned in AGENTS.md and prints the
# fix for anything missing. Exit 1 when something `just check` needs is wrong;
# what only the full gate or the image build needs is a warning.
# Plain bash 3.2 (macOS /bin/bash) compatible.
set -uo pipefail

# Formatter output changes between releases, so these are exact: two machines
# on different versions would reformat each other's commits.
FLUTTER=3.47.5 # dart format (tall style) and the app's analyzer
KTLINT=1.8.0
# The device runs Alpine's python3 3.14; the host tests run the same minor.
PYTHON=3.14
# ruff is pinned in tools/dev/format.sh and fetched by uvx on first use.

fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n      → %s\n' "$1" "$2"; fail=1; }
warn() { printf '  \033[33m!\033[0m %s\n      → %s\n' "$1" "$2"; }
has() { command -v "$1" >/dev/null 2>&1; }
if [[ "$(uname)" == Darwin ]]; then pkg="brew install"; else pkg="brew install (or your distro's package)"; fi

echo "Dev tools"
for t in just lefthook gitleaks uv shellcheck; do
  has "$t" && ok "$t" || bad "$t missing" "$pkg $t"
done
if has ktlint; then
  v="$(ktlint --version 2>/dev/null | awk '{print $NF}')"
  [[ "$v" == "$KTLINT" ]] && ok "ktlint $v" || bad "ktlint $v (want $KTLINT: its output changes between releases)" "$pkg ktlint (pin $KTLINT)"
else
  bad "ktlint missing" "$pkg ktlint"
fi
has python3 && ok "python3 $(python3 -c 'import sys; print(sys.version.split()[0])') (Claude Code hooks)" \
  || bad "python3 missing (the Claude Code hooks need it)" "$pkg python3"

echo "Toolchain"
if has uv; then
  if v="$(uv python find "$PYTHON" 2>/dev/null)"; then ok "Python $PYTHON for the host tests ($v)"
  else bad "no Python $PYTHON for the host tests (the device runs $PYTHON)" "uv python install $PYTHON"; fi
fi
if has flutter; then
  v="$(flutter --version --machine 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin)["frameworkVersion"])' 2>/dev/null)"
  [[ "$v" == "$FLUTTER" ]] && ok "Flutter $v" \
    || bad "Flutter ${v:-?} (want $FLUTTER: dart format output is tied to the SDK)" \
      "cd \"\$(dirname \"\$(dirname \"\$(command -v flutter)\")\")\" && git fetch --tags && git checkout $FLUTTER"
else
  bad "flutter missing" "install Flutter $FLUTTER as a git checkout of the tag"
fi
if [[ "$(uname)" == Linux ]]; then
  if has cc && has make; then ok "C compiler and make (nexusqd, nq-healthd, alsa-vol unit tests)"
  else bad "cc or make missing (the C unit tests build on the host)" "apt install build-essential"; fi
  if printf '#include <pulse/volume.h>\n' | cc -E -x c - >/dev/null 2>&1; then ok "PulseAudio headers (alsa-vol scale test)"
  else bad "pulse/volume.h missing (the alsa-vol scale test includes it)" "apt install libpulse-dev"; fi
else
  # The daemons use Linux APIs: off Linux, tools/dev/test-c.sh builds them in Alpine.
  if docker info >/dev/null 2>&1; then ok "Docker running (the C unit tests build in Alpine off Linux)"
  else bad "Docker not running (off Linux the C unit tests build in an Alpine container)" "start Docker Desktop"; fi
fi

e2fs=""
has brew && e2fs="$(brew --prefix e2fsprogs 2>/dev/null)"
if has mkfs.ext4 && has debugfs; then ok "e2fsprogs (mkfs.ext4, debugfs)"
elif [[ -n "$e2fs" && -x "$e2fs/sbin/mkfs.ext4" ]]; then ok "e2fsprogs (Homebrew, keg-only; tools/dev/test-shell.sh adds it to PATH)"
else bad "e2fsprogs missing (the OTA-parity and A/B suites build ext4 images)" "$pkg e2fsprogs"; fi

echo "Full gate and image build (warnings)"
if has docker; then
  docker info >/dev/null 2>&1 && ok "Docker running" \
    || warn "Docker installed but not running" "start Docker: the docker test lane (just ci) and the image build need it"
else
  warn "docker missing" "the docker test lane (just ci) and docker-build.sh need it"
fi
if [[ "$(uname)" == Darwin ]]; then
  has xcodebuild && ok "$(xcodebuild -version | head -1)" || warn "Xcode missing" "install Xcode (the iOS build in just ci)"
else
  warn "not macOS" "the iOS build lane of just ci runs on the MacBook or the macOS VM"
fi

echo "Project"
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
[[ -x "$root/.git/hooks/pre-commit" ]] && grep -q lefthook "$root/.git/hooks/pre-commit" \
  && ok "git hooks installed" || warn "git hooks not installed" "just setup (runs lefthook install)"
[[ -d "$root/companion/app/.dart_tool" ]] && ok "companion app dependencies fetched" \
  || warn "companion app dependencies not fetched" "just setup (runs flutter pub get)"

exit $fail
