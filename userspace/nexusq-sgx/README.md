# nexusq-sgx — the PowerVR SGX540 userspace on musl

The Nexus Q's GPU (SGX540 rev 120, OMAP4460) runs the TI DDK 1.17.4948957:
the kernel half is `pvrsrvkm_omap4_sgx540_120` in `linux-google-steelhead`
(patches 0063-0074), the userspace half is TI's closed `ti443x` libraries,
built for glibc. The rootfs is musl. This package is the open glue that runs
those libraries, unmodified, in musl processes; the GL/EGL/GBM front end is
`nexusq-sgx-mesa`.

| Piece | What it does |
|---|---|
| `nq-sgx-fetch` (+ `.service`, `.timer`, `97-nexusq-sgx.preset`) | Downloads the seven TI libraries and TI's licence once per unit, from TI's git at the pinned commit `84a396a4` (Maemo Leste's mirror of the same files as the per-file fallback), verifies each against `ti443x.sha256` and installs the set in `/var/lib/sgx-ddk/lib` atomically. The blobs are never in an image or the OTA repo. |
| `ld-linux-armhf.so.3` (`nq-glibc-compat.c`, `-abi.c`, `-mmap.S`) | The glibc ABI the blobs need on musl: their `DT_NEEDED ld-linux-armhf.so.3`, the nine fortify `__*_chk` functions, and per-caller `mmap`/`strerror_r` (glibc's 32-bit-offset `mmap@GLIBC_2.4` and GNU `strerror_r` for code linked against `libc.so.6`, musl's own for everyone else). Must be preloaded. |
| `pvrsrvinit` | Calls the DDK's `SrvInit()` (microkernel upload) once per module load. Ours, MIT; TI's tool is closed and Maemo's copy carries no licence. |
| `libdbm.so.1` | Maemo Leste's open (LGPL) buffer manager the DDK's `libpvr_dri_support` needs, built from the pinned Maemo source. |
| `nexusq-sgx.service` | `modprobe` + `pvrsrvinit`. Not enabled; a GPU consumer (the desktop session) pulls it in. |
| `sgx-env` | Sourced by a GPU client's launcher: `nq_sgx_ready` (kill switch `/etc/nexusq/gpu-off`, blobs, mesa-sgx, unit active), `nq_sgx_export` (private library path + the preload, for the one exec'd process: `NQ_SGX_SCOPE=process` makes the shim put the earlier values back so children never inherit them). |
| `nexusq-sgx-labwc` → `/usr/libexec/nexusq-sgx/bin/labwc` | labwc with the GPU environment and `WLR_RENDERER=gles2`; the desktop session puts its directory first on `PATH`. |

Design and measurements: `docs/gpu-sgx540/route-a-musl-2026-10-12.md`,
`docs/gpu-sgx540/reverse-engineering.md` §3 (what musl does with the blobs).

Tests: `make test` (caller classification, fortify semantics; host) and
`tests/test_nq_sgx_fetch.sh` (the fetcher against a fake origin). The ARM
`mmap`/`strerror_r` half is exercised on a unit: `pvrsrvinit` and the B2
dma-buf probe under musl.
