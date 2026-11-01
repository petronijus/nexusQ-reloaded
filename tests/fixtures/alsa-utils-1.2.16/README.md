# alsa-utils 1.2.16 — alsaloop sources, unmodified

`alsaloop/alsaloop.c`, `alsaloop/alsaloop.h`, `alsaloop/pcmjob.c` and
`include/os_compat.h` exactly as they are in
`https://alsa-project.org/files/pub/utils/alsa-utils-1.2.16.tar.bz2` (the
tarball `pmos/alsa-utils/APKBUILD` builds, sha512 `288c042f…ef02cf`). The alsaloop
files are GPL-2.0-or-later, `include/os_compat.h` is LGPL-2.1-or-later.

They are test input, not a build source: `tests/test_alsaloop_stall.py` applies
every `pmos/alsa-utils/*.patch` that touches `alsaloop/`, in `source=` order,
and runs the patched poll loop on the host. A patch that no longer applies to
upstream fails there.

When the aport moves to a new `pkgver`, replace this directory with
`tests/fixtures/alsa-utils-<pkgver>/` taken from the new tarball (the test
looks it up by `pkgver` and fails while it is missing).
