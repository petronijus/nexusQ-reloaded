#!/bin/sh
# Route B first-light runner: run one command inside the glibc GPU sandbox
# (/var/lib/nexusq-gpu-sandbox/root, a copy of /opt/glibc-rt plus Maemo
# daedalus SGX userspace). Host /tmp/gpu-out is visible as /out.
# Usage: run.sh <timeout-seconds> <command> [args...]
set -eu
ROOT=/var/lib/nexusq-gpu-sandbox/root
T=$1
shift
mkdir -p /tmp/gpu-out
exec timeout "$T" nice -n 10 bwrap \
	--bind "$ROOT" / \
	--dev /dev \
	--dev-bind /dev/dri /dev/dri \
	--proc /proc \
	--ro-bind /sys /sys \
	--tmpfs /tmp \
	--tmpfs /run \
	--bind /tmp/gpu-out /out \
	--clearenv \
	--setenv PATH /usr/sbin:/usr/bin:/sbin:/bin \
	--setenv HOME /root \
	--setenv MESA_LOADER_DRIVER_OVERRIDE pvr \
	--setenv __EGL_VENDOR_LIBRARY_FILENAMES /usr/share/glvnd/egl_vendor.d/50_mesa.json \
	"$@"
