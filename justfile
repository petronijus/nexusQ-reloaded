# nexusQ-reloaded task runner — https://just.systems. `just` lists the recipes.
# The fast lane (`just check`) is what the pre-push hook and the Claude Code
# Stop hook run; `just ci` is the full gate before a change counts as done.
# There is no hosted CI: these recipes are the CI, run on the Linux desktop or
# the MacBook. Building and flashing the image stays with docker-build.sh and
# the nexusq-build agent (INSTALL.md); nothing here touches a device.

set shell := ["bash", "-euo", "pipefail", "-c"]

# The device's python3 minor; the host tests run on the same one (uv fetches it).

python := "3.14"

# List the recipes
default:
    @just --list --unsorted

# ── setup ────────────────────────────────────────────────────────────────

# One-time setup of a clone on a new machine (idempotent)
setup:
    uv python install {{ python }}
    lefthook install
    git config blame.ignoreRevsFile .git-blame-ignore-revs
    cd companion/app && flutter pub get
    tools/dev/doctor.sh

# Check this machine against the pinned toolchain
doctor:
    tools/dev/doctor.sh

# ── fast lane (≲ 1 min, no device, no container, no build) ───────────────

# Formatting, static analysis and every unit test that needs no build
check: fmt-check lint test-py test-c test-dart test-sh

# Format every source file in place
fmt:
    tools/dev/format.sh --all

# Fail if a source file is not formatted or a linter (ruff, shellcheck, ktlint) complains
fmt-check:
    tools/dev/format.sh --check --all

# Static analysis beyond the formatters: the companion app's analyzer
lint:
    cd companion/app && flutter analyze --fatal-infos

# Python unit tests: the daemons, device tools, diag scripts and repo tripwires
test-py:
    #!/usr/bin/env bash
    set -euo pipefail
    fail=0
    for d in $(git ls-files --cached --others --exclude-standard '*tests/test_*.py' | xargs -n1 dirname | sort -u); do
      echo "── $d"
      uv run --no-project --quiet --python {{ python }} python -m unittest discover -s "$d" -t "$d" || fail=1
    done
    exit $fail

# C unit tests: nexusqd, nq-healthd, the alsa volume scale (host cc on Linux, Alpine elsewhere)
test-c:
    tools/dev/test-c.sh

# Companion app unit and widget tests
test-dart:
    cd companion/app && flutter test

# Shell test suites that run on this machine
test-sh:
    tools/dev/test-shell.sh host

# ── full gate ────────────────────────────────────────────────────────────

# Everything. OS-aware: the iOS build runs on macOS and is skipped loudly elsewhere.
ci: check test-sh-docker test-alsa-integration build-apk
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "$(uname)" == Darwin ]]; then
      just build-ios
    else
      echo "ci: build-ios SKIPPED on $(uname) — run just ci on the MacBook for it." >&2
    fi

# Shell suites that run the code in an Alpine container playing the device
test-sh-docker: _docker
    tools/dev/test-shell.sh docker

# The ALSA volume plugin against a real PulseAudio, in Alpine
test-alsa-integration: _docker
    sh userspace/nexusq-alsa-vol/tests/run-integration.sh

# Compile the companion app for Android (debug; release builds: companion/app/build-apk.sh)
build-apk:
    cd companion/app && flutter build apk --debug

# Compile the companion app for iOS (debug, unsigned; TestFlight: the nexusq-ios-release agent)
build-ios: _macos
    cd companion/app && flutter build ios --debug --no-codesign

# ── guards (private; fail with the fix) ──────────────────────────────────

_docker:
    @docker info >/dev/null 2>&1 || { echo "this recipe needs a running Docker (just doctor)" >&2; exit 1; }

_macos:
    @[[ "$(uname)" == Darwin ]] || { echo "this recipe needs macOS and Xcode" >&2; exit 1; }
