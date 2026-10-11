# Route A: the SGX540 userspace on musl, 2026-10-12

Route B (first light, the B1/B2 work) ran the GPU userspace in a glibc
sandbox. The product is route A: the TI DDK blobs, unmodified, in the musl
rootfs, loaded by Mesa's sgx frontend built for musl, so that labwc (Alpine's,
unpatched) can render the HDMI desktop on the SGX540. This note records how
that works and what was measured on the Prague unit (kernel 6.18.48-r25,
trial slot B).

## Result

| Test (musl, native rootfs, no sandbox) | Result |
|---|---|
| `pvrsrvinit` (ours, musl) + the TI `libsrv_init`, after `rmmod`/`modprobe` | `UM DDK-(4948957) and KM DDK-(4948957) match. [ OK ]` |
| same without the shim on the library path | fails: `Error loading shared library ld-linux-armhf.so.3` (control) |
| B2 probe, GBM buffer, 200 frames | PASS, 0 mismatches (glReadPixels and dma-buf mmap) |
| B2 probe, omapdrm dumb buffer, 200 frames | PASS, 0 mismatches |
| B2 probe without the preloaded shim (control) | `PVRSRVMapDmaBuf: Failed to acquire user CPU mapping (errno 22)`: the `mmap@GLIBC_2.4` hazard, observed |
| B1 test (15 checks) | PASS |
| wlroots 0.20 GL/EGL/GBM imports vs mesa-sgx 24.0.9 exports | all 80 present (groundwork question 20) |
| kernel log over all of it | no warning |

## The pieces

### What musl already does with glibc objects

`docs/gpu-sgx540/reverse-engineering.md` §3.3 holds the analysis; confirmed
here by running it. musl maps `libc.so.6`/`libm.so.6` to itself, ignores
symbol versions, remaps the LFS64 names and keeps time32 compat symbols.
Against Alpine edge's armv7 musl (1726 exports) the seven shipped blobs import
only these names musl lacks: the nine fortify `__*_chk` functions, the LFS64
trio (remapped), C++ `new`/`delete` (only `libPVRScopeServices`, not
shipped) and weak `_ITM_*`/`__gmon_start__`.

### `nq-glibc-compat` (SONAME `ld-linux-armhf.so.3`), `userspace/nexusq-sgx/`

Option 1 of reverse-engineering.md §3.3, extended. Every blob has
`DT_NEEDED ld-linux-armhf.so.3`, a name musl does not reserve, so a small musl
library with that SONAME on the private path satisfies it: no gcompat, no
symlink to the loader. It provides the fortify functions with glibc's
semantics (an overflow aborts) and the two imports whose ABI differs:

- **`mmap@GLIBC_2.4`** passes a 32-bit `off_t` at `[sp+4]`; musl's `mmap`
  reads a 64-bit one at `[sp+8]`. Observed, not hypothetical: without the shim
  `PVRSRVMapDmaBuf` fails with `EINVAL` on every GBM buffer (table above), so
  route A without it has no dma-buf import and no wlroots.
- **`strerror_r`** is GNU in glibc, XSI in musl.

musl binds a blob's `mmap` to the first definition in the global scope, so the
shim is **preloaded** (`LD_PRELOAD`) and decides per call: code in an object
with `DT_NEEDED libc.so.6` (found with `dl_iterate_phdr` from the return
address) gets glibc's ABI, everything else gets musl's own function unchanged
(looked up through musl's reserved `libc.so` handle, never the shim itself).
`mmap64` is defined too: musl resolves an unknown `*64` name by retrying
without the suffix, which would otherwise land a glibc `mmap64` (64-bit
offset) on the 32-bit-offset path.

**The entry point is assembly** (`nq-glibc-compat-mmap.S`). The first build
had it in C, declared to read both stack layouts, and GCC turned it into a
sibling call that stored the computed 64-bit offset into `[sp+8..15]` before
jumping to musl's `mmap`. For a glibc caller those words are its locals:
`PVRSRVMapDmaBuf` then crashed on `str r4, [r3]` with `r3` loaded from the
overwritten `[sp+12]` (gdb, 2026-10-12). No C flag guarantees a callee leaves
its incoming argument area alone, so the entry only reads the caller's stack
and passes its address and the return address to C in a frame of its own.

No blob is modified: no patchelf, no symbol renaming (the TSPA allows only
unmodified binaries).

### The blobs: fetched on the unit, never shipped

Petr's decision (groundwork §8): no TI binary in an image or the OTA repo.
`nq-sgx-fetch` downloads the seven libraries and TI's LICENSE per file from
TI's git at `84a396a4` (`targetfs/ti443x_linux/lws-generic/release/usr/lib/`),
with Maemo Leste's mirror of the same files (`a9dbdc75`) as the per-file
fallback, checks each against `ti443x.sha256` and swaps the set into
`/var/lib/sgx-ddk/lib` in one rename; any failure leaves the previous set and
no temp dir. A timer starts it 2 min after boot; on failure the service
retries every 15 min until complete, then the condition skips it, so it costs
no periodic wakeup. All seven TI downloads matched the pins on 2026-10-11 and
are identical to the files route B ran. After a reflash the unit fetches them
again.

### `pvrsrvinit` and `libdbm`

Ours (MIT): `dlopen("libsrv_init.so.1")` + `SrvInit()`, exit status per
failure. Maemo's copy has no licence. `libdbm` is Maemo's LGPL buffer manager
(two C files from the pinned Maemo archive), built as pre-C23 code
(`-std=gnu17`: its `void (*free)()` takes the device pointer, which C23 would
read as "no parameters") with an empty `config.h` (it uses nothing from it).

### mesa-sgx for musl, `pmos/nexusq-sgx-mesa`

Maemo `leste-upstream-forks/mesa` `powervr-24.0.9` @ `72c93be7`, pinned by
sha512 in `unpack()`, plus the B1 and B2 patches
([b1-b2-desktop-blockers-2026-10-11.md](b1-b2-desktop-blockers-2026-10-11.md)),
built with `-Dglvnd=false` (Alpine's Mesa has no glvnd), only the `sgx`
gallium driver, `-Dplatforms=wayland`, into `/usr/lib/sgx-mesa`: no headers,
no pkg-config, no `/usr/share`, so nothing collides with Alpine's Mesa, which
stays what every other program uses. `scripts/bump-sgx-mesa.sh` moves the pin
(branch, tag or commit; test-applies the patches with the aport's own
`unpack()`; refuses a pinned archive whose bytes changed).
`scripts/tests/test-bump-sgx-mesa.sh` covers it, including a tag-resolution
bug the first version had (an annotated tag resolved to the tag object).

### The desktop session (device r127)

- `tinydm.service.d/50-nexusq-sgx.conf`: `Wants=`/`After=nexusq-sgx.service`
  (modprobe + `pvrsrvinit`). Only the desktop brings the GPU up; the module
  stays blacklisted at boot.
- `lxqt-wayland-nexusq.desktop` → `/usr/libexec/nexusq-desktop-session`. When
  `nq_sgx_ready` (not switched off by `/etc/nexusq/gpu-off`, blobs fetched,
  mesa-sgx installed, unit active) it runs `startlxqtwayland` with
  `/usr/libexec/nexusq-sgx/bin` first on `PATH`, where a `labwc` wrapper sets
  the GPU environment and `WLR_RENDERER=gles2` for **labwc alone**: the shim,
  preloaded into labwc, puts `LD_PRELOAD`/`LD_LIBRARY_PATH` back to their
  earlier values as it loads (`NQ_SGX_SCOPE=process`; musl has already read
  both), so lxqt-session, the apps and anything they push into the systemd
  user manager (lxqt-session calls `dbus-update-activation-environment`) never
  see them. Clients render to `wl_shm` with the system Mesa, as before.
- A GPU session that exits with an error within 30 s is a failed start: the
  wrapper records it for this kernel + mesa-sgx build in
  `~/.local/state/nexusq/gpu-session-failed` and starts the Pixman session at
  once; later starts go straight to Pixman until the kernel or mesa-sgx
  changes. `tests/test_desktop_session_wrapper.sh`.
- `.post-install` makes it the default session; `.post-upgrade` moves only
  units still on the stock `lxqt-wayland.desktop` (a hand-picked session
  stays). `tests/test_desktop_session_default.sh` (docker lane).

### Release gate: no TI binary

`scripts/release-preflight-no-secrets.sh` fails an image that carries any TI
SGX library name in `/usr/lib` or `/usr/lib/sgx-ddk`, or anything in
`/var/lib/sgx-ddk/lib` (seen failing on fixture images with one blob in each
place).

## Open

- **The runtime hardware watchdog is not armed on the units**
  (`RuntimeWatchdogUSec=0`; only the reboot watchdog, 10 min). A pvrsrvkm hang
  in the kernel would not recover by itself. Arming it is a fleet-wide
  decision, separate from this change.

- labwc on the GPU on a unit (needs the built packages installed), then the
  measured gate: compositor CPU, artefacts, audio XRUNs and power, the fleet
  release condition (groundwork §4 Phase 5).
- The cost of the preload in every session process: one `dl_iterate_phdr` per
  explicit `mmap`/`strerror_r` call (musl's malloc does not go through the
  exported symbol). Measured with the gate.
- `strerror_r` GNU path: exercised only by blob error paths; covered by the
  classification test, not yet by a provoked DDK error.
