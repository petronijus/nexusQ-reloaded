#!/usr/bin/env bash
# Build and run the C unit tests: nexusqd, nq-healthd, the ALSA volume scale.
#
# The daemons are written against Linux (SOCK_CLOEXEC, /sys and /proc
# layouts), so on Linux they build with the host compiler, and anywhere else
# in an Alpine container — the device's libc (musl), not a port of the code.
#
#   tools/dev/test-c.sh              host compiler on Linux, Alpine elsewhere
#   NQ_TEST_C_CONTAINER=1 tools/dev/test-c.sh   Alpine on Linux too
#
# Plain bash 3.2 (macOS /bin/bash) compatible.
set -euo pipefail

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$root" || exit 1

dirs="nexusqd nq-healthd nexusq-alsa-vol"

if [[ "$(uname)" == Linux && "${NQ_TEST_C_CONTAINER:-0}" != 1 ]]; then
  for d in $dirs; do
    echo "── userspace/$d"
    make -s -C "userspace/$d" test
  done
  exit 0
fi

docker info >/dev/null 2>&1 || {
  echo "test-c: the daemons use Linux APIs, so off Linux their tests build in an Alpine container — start Docker (just doctor)" >&2
  exit 1
}
# The toolchain image is built once and reused: installing build-base on every
# run costs from seconds to minutes, depending on the mirror. Its tag hashes the
# recipe, so changing the recipe builds a new image.
recipe='FROM alpine:3.22
RUN apk add --no-cache build-base linux-headers pulseaudio-dev'
image="nexusq-ctest:$(printf '%s' "$recipe" | cksum | cut -d' ' -f1)"
if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "test-c: building the $image toolchain image (once)"
  printf '%s\n' "$recipe" | docker build -q -t "$image" - >/dev/null
fi

# The source is mounted read-only and copied: the Makefiles write build/ next to it.
docker run --rm -v "$root/userspace:/src:ro" -e DIRS="$dirs" "$image" sh -euc '
  cp -R /src /tmp/userspace
  rm -rf /tmp/userspace/*/build   # host objects would pass for up to date
  for d in $DIRS; do
    echo "── userspace/$d (alpine, musl)"
    make -s -C "/tmp/userspace/$d" test
  done
'
