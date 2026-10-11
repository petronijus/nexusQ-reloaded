# SGX540 first light, route B (glibc sandbox), 2026-10-11

Phase 2 "first light" of [the GPU groundwork](../2026-10-11-gpu-sgx540-groundwork.md)
(§4 Phase 2, §9 step 10), run on the Prague unit. Short names as in the master
note: ub = [userspace-blobs.md](userspace-blobs.md), abi =
[re/blob-abi.md](re/blob-abi.md), cd = [compositor-display.md](compositor-display.md).

## Result in one paragraph

The TI DDK 1.17.4948957 userspace renders on our kernel. `pvrsrvinit` ran
SGXInit once (exit 0, `PVR_K: UM DDK-(4948957) and KM DDK-(4948957) match. [ OK ]`,
`/proc/pvr/version` now reports `SGX revision = 120`). A GLES2 client gets
`GL_RENDERER = PowerVR SGX 540`, `OpenGL ES 2.0 build 1.17@4948957`, and its
256×256 render read back with `glReadPixels` is bit-identical to Mesa llvmpipe
on all four paths tried (surfaceless + FBO; GBM pbuffer on `renderD129`,
`card0`, `renderD128`). The GFX power domain is ON only while work is pending:
it goes OFF within 3 s of the last frame **even with a GLES context open**, stays
OFF for 60 s idle, and a render in the same context after it went OFF is
correct. B1 (`GL_EXT_unpack_subimage`) and B2 (`EGL_EXT_image_dma_buf_import`)
are both **absent** at run time. One RE expectation is overturned: on the GBM
buffer path, `libsrv_um`'s 32-bit-offset `mmap@GLIBC_2.4` in `PVRSRVMapDmaBuf`
(abi §4, "probably not taken" for drop C) **is reached**, which matters for
route A (musl). HDMI was disconnected, so no kmscube on screen.

## Unit and preconditions

- `hostname` = `steelhead` (first command of every session), `uname -r` =
  `6.18.48-r23` (PREEMPT, trial slot), `ssh root@192.168.20.246`.
- `pvrsrvkm_omap4_sgx540_120` loaded by hand before this session
  (`[drm] Initialized pvr 1.17.4948957 for 56000000.gpu on minor 1` →
  `/dev/dri/card1` + `renderD129`); blacklisted on the cmdline
  (`modprobe.blacklist=pvrsrvkm_omap4_sgx540_120`). Not reloaded, unit not
  rebooted.
- SGX clock from `clk_summary`: `dpll_per_m7x2_ck` → `l3-gfx-clkctrl:0000:24`
  → `l3-gfx-clkctrl:0000:0` (`5600fe00.target-module` fck) at **307 200 000 Hz**.
- Audio: `pactl list short sinks` as `user` — both sinks `SUSPENDED`; the only
  sink-inputs are the two permanent `module-loopback` streams. The audio path
  was not touched.
- HDMI: `/sys/class/drm/card0-HDMI-A-1/status` = `disconnected` → offscreen only.
- Die temperature over the session: 53.5-59.7 °C (thermal_zone0). Every
  device command ran under `timeout` + `nice`.
- Disk: `/` 3.2 GB free before, 2.5 GB after (sandbox 628 MB).

## The sandbox (route B)

Never touched: `/opt/glibc-rt` (Roon's). Everything lives under
`/var/lib/nexusq-gpu-sandbox`; scratch output under `/tmp/gpu-out` on the unit.

1. `cp -a /opt/glibc-rt /var/lib/nexusq-gpu-sandbox/root` (Debian bookworm
   armhf, glibc 2.36, 487 MB, 2 min 10 s under `nice -n 19 ionice -c3`).
2. On the host, in an isolated scratch directory (nothing from it executed on
   the host): the Maemo daedalus and Debian bookworm armhf indexes, a
   dependency closure computed against the base's own `var/lib/dpkg/status`
   ([drafts/first-light/resolve.py](drafts/first-light/resolve.py)), the debs,
   and the TI tree. Unpacked with `ar p | bsdtar -x` into a staging tree,
   docs/man/locale dropped (141 MB), streamed to the unit with
   `bsdtar --uid 0 --gid 0 -cf - | ssh … tar -xf -`. No file of the staging tree
   existed in the base (checked before copying).
3. **Trap hit and fixed:** busybox `tar` replaced the sandbox's usrmerge symlink
   `lib -> usr/lib` with a real (empty) directory from a deb's `./lib/` entry, so
   `/lib/ld-linux-armhf.so.3` vanished and every exec failed with
   `execvp …: No such file or directory`. `rmdir lib && ln -s usr/lib lib`
   restored it. A packaged procedure must extract with a tar that follows
   existing directory symlinks, or extract into `usr/` only.
4. `ldconfig` inside the sandbox; `ldd` of `pvrsrvinit`, `libsrv_um.so.1`,
   `dri/pvr_dri.so`, `eglinfo`, `kmscube`: no missing library.
5. Runner: [drafts/first-light/nexusq-gpu-sandbox-run.sh](drafts/first-light/nexusq-gpu-sandbox-run.sh)
   (`timeout` + `nice -n 10` + `bwrap --bind <root> / --dev /dev --dev-bind
   /dev/dri /dev/dri --proc /proc --ro-bind /sys /sys --tmpfs /tmp --tmpfs /run
   --clearenv`, env `MESA_LOADER_DRIVER_OVERRIDE=pvr` and
   `__EGL_VENDOR_LIBRARY_FILENAMES=…/50_mesa.json`). Runs as root.
   `MESA_LOADER_DRIVER_OVERRIDE=pvr` is required with this Mesa: daedalus
   22.3.6+sgx2 ships `pvr_dri.so` and `sgx_dri.so` but no `omapdrm_dri.so`
   alias (that came with TI's 2023 alias commit, ub §3.1).
6. `/etc/powervr.ini` in the sandbox = Maemo's Droid 4 hint
   (`[default]` / `DisableHWTQTextureUpload=1`, ub §3.5). It is read (strace),
   but its effect was not A/B-tested.

### What is in it, exactly

**TI blobs, unmodified** — from the GitHub mirror
`rcn-ee/ti-omap5-sgx-ddk-um-linux`, `archive/84a396a4fb379f10931421e489ac8a199d6a9f2c.tar.gz`
(8 208 927 bytes, the size ub Addendum B.3 records). All 11
`targetfs/ti443x_linux/lws-generic/release/usr/` files match the per-file
sha256 in [drafts/sgx-ddk-um.APKBUILD.draft](drafts/sgx-ddk-um.APKBUILD.draft)
(`ti443x.sha256`), `LICENSE` matches `37507b46…ad47`. Re-hashed on the unit
after the copy: identical. These replace the `.comment`-stripped copies in
Maemo's deb (ub Addendum B.4), so the sandbox runs TI's bytes:
`libsrv_um`, `libsrv_init`, `libusc`, `libglslcompiler`, `libGLESv2_PVR_MESA`,
`libGLESv1_PVR_MESA`, `libpvr_dri_support`, `libpvr2d`, `libPVRScopeServices`,
`pvrsrvctl`. TI's closed `libdbm` is **not** used.

**Maemo open pieces (prebuilt, daedalus):** `libdbm.so.1.17.4948957` from
`sgx-ddk-um-ti443x` (13 604 bytes, sha256 `9b0b53f6271c0fbaa49771172a045ae487be7d4690da54a31b55444a191abfd7`,
Maemo's LGPL re-implementation; TI's is 9 708 bytes) and `/usr/bin/pvrsrvinit`
from `sgx-ddk-um-tools` (5 544 bytes, sha256
`91e670fe047061dc69117a4a0bc18cc01a99ea3cb26cd9ffa6153b9d93bcbb69`).
**Chosen for speed:** Maemo's prebuilt `pvrsrvinit`, not MobiAqua's MIT source
(ub §3.4 prefers the latter for the product because Maemo's file carries no
licence, ub Addendum B.1). Nothing from the sandbox ships.

**Mesa: Maemo daedalus `22.3.6+sgx2-1+4m7`**, not the chosen route A Mesa
(`powervr-24.0.9`): excalibur's 24.0.9 binaries need glibc ≥ 2.38 and the base
has 2.36 (draft route B step 2). 22.3.6+sgx2 uses the versioned callback
interface the 2024 blobs need (ub §3.1).

Index integrity: Maemo `dists/daedalus/main/binary-armhf/Packages.gz` sha256
`367d7572…78e4ef` = its `Release` entry; Debian
`dists/bookworm/main/binary-armhf/Packages.xz` sha256 `2352d9ca…41d7b` = its
`InRelease` entry (Release signatures not GPG-verified). Every deb matched its
index sha256:

| Package | Version | Origin | sha256 |
|---|---|---|---|
| `sgx-ddk-um-ti443x` | 1.17.4948957+leste15-1+4m7 | maemo | `4f7aa02b38804bb3a1dffe4b179c2a89a0666cc5ee81abd20981d443cf55b12a` |
| `sgx-ddk-um-tools` | 1.17.4948957+leste15-1+4m7 | maemo | `d326df12466cd9bbf7977a5233ad36d825f47cb2b558e070c73953e1df59d151` |
| `libegl-mesa0` | 22.3.6+sgx2-1+4m7 | maemo | `0aa823a2f9b09a1df78ca6ebc1b62873f17b44aa093e5f5646f3ac1d4e17b043` |
| `libgbm1` | 22.3.6+sgx2-1+4m7 | maemo | `d81c16188087c0b34af2d2ea5ba003bc18d21ee9aaf044e068d51ea9654fd54c` |
| `libgl1-mesa-dri` | 22.3.6+sgx2-1+4m7 | maemo | `596b6413d06db99e22338565b4c2d5cadd8658234904e2714a07f1cf48c88814` |
| `libglapi-mesa` | 22.3.6+sgx2-1+4m7 | maemo | `a85bb402cc8b5abc3c568a3c955e6a68f05c0cf7b92649fa2e344e52fa166c32` |
| `libglx-mesa0` | 22.3.6+sgx2-1+4m7 | maemo | `36bf40600de7b29298620196bd635f49a311c940d7753f294c8e37774218809b` |
| `libglvnd0` | 1.6.0-1 | debian | `07821998e430d7539081e3ebe5c07089250e51213071de5fedf37f3bcbb0c0dc` |
| `libegl1` | 1.6.0-1 | debian | `77575955e0823ff0a548d4c94fac889cebec33fd6e0161b1cfe7321d4b84ec68` |
| `libgles2` | 1.6.0-1 | debian | `4ad00b136cc9f6b10e8c9baf1ebbb744ea955a5a49a9e437d547c9bb685714a6` |
| `libgl1` | 1.6.0-1 | debian | `9b2737322484cd834303d67ce1a40a402c226e5ed620b112543b734835f8e057` |
| `libglx0` | 1.6.0-1 | debian | `69c3278a9d0a9b64858a2344e8b00a5240c2c9e579e550f49d68255e47e2d926` |
| `libllvm15` | 1:15.0.6-4+b1 | debian | `74866370e5d24d57eac839293e32b9ee5b233168c35ed988ac0f408519463e76` |
| `libz3-4` | 4.8.12-3.1 | debian | `8340deb576915aa77ed6bc73b5b56c8322e69e22e0b9bd3581ee0ec388908193` |
| `libsensors5` | 1:3.6.0-7.1 | debian | `607d974a6aec5f6e1d7b6cd9086c82452c3c4d16131716d5babd80cc9ae82bd7` |
| `libsensors-config` | 1:3.6.0-7.1 | debian | `7f3c9fbd822858a9e30335e4a7f66c9468962eb26cd375b93bc8b789660bf02f` |
| `libdrm-amdgpu1` | 2.4.114-1+b1 | debian | `aa82d8456ae2646ef4a12ee4420a806e30de6c13cd69db4b94a35fd49225fd57` |
| `libdrm-nouveau2` | 2.4.114-1+b1 | debian | `5df788e18f690d3e622f31f3a6269c532457d6adf0035ce32e464384efa58e93` |
| `libdrm-radeon1` | 2.4.114-1+b1 | debian | `45382663b8ae03f1b704224e9079a2d6c52e80d5608a3f0a0dc3f6ed96f6da93` |
| `libwayland-client0` | 1.21.0-1 | debian | `61f26daffc38ac4c0ccc0bdbc0ea6db2dd2503e801d0dacfdc5ce0b12ef6b94e` |
| `libwayland-server0` | 1.21.0-1 | debian | `f3f52aee8936d90bb903e551539f6b1299bf843447af342d7561c40cbf9f3c0a` |
| `libwayland-egl1` | 1.21.0-1 | debian | `1b3ef2c412e96a38624778eb520792a4814516d123e286d6b0ed636cf0dfa2ef` |
| `libxcb-dri2-0`, `-glx0`, `-present0`, `-randr0`, `-sync1`, `-xfixes0` | 1.15-1 | debian | `48ccdd0c…`, `3ce09ba9…`, `4e6854ab…`, `35f9ca38…`, `6acdd10a…`, `9086b017…` |
| `libxshmfence1` | 1.3-1 | debian | `7854270047611c95b28a0d68c95705293f2cf32962d52405657b4f8a99a8afb5` |
| `libxxf86vm1` | 1:1.1.4-1+b2 | debian | `71ed46504266b91fbe269c12110c8bb9e1a6d11f207e06c9201c74e5534df701` |
| `mesa-utils-bin` (eglinfo) | 8.5.0-1 | debian | `ec43e5433abb6a414aca1323f56481627b216ff09331bd403e536aee90d623a6` |
| `kmscube` | 0.0.0~git20210103-1 | debian | `44bfb2e6650b0931b37e1d903c1add4744b8c20b348f2a06e4f820d2a07c1572` |
| `strace` (no `-k` support in this build) | 6.1-0.1 | debian | `0857a4ca612692b41978cdfe81240d634bafcdb25ea600292017e07948682a27` |
| `libdw1`, `libunwind8` | 0.188-2.1, 1.6.2-3 | debian | `1e762479…`, `aa967086…` |
| `libgstreamer1.0-0`, `libgstreamer-plugins-base1.0-0`, `liborc-0.4-0` (pulled in by a filter slip, unused, 6.7 MB) | | debian | `1d6841e8…`, `20398c6a…`, `0f2dfd34…` |

`libllvm15` (100 MB) and `libz3-4` (14 MB) are 80 % of the added bytes, which is
why route B never goes into OTA (master note Phase 2).

## Step 2: pvrsrvinit / SGXInit

Before (18:31:22): `prm_gfx` `off-0`, active 2743 ms; GPU runtime-suspended,
active 2695 ms; `/proc/pvr/version` `System Version String: None`.

```
run.sh 60 strace -f -tt -o /out/pvrsrvinit.strace \
    -e trace=openat,ioctl,mmap,mmap2,munmap /usr/bin/pvrsrvinit      → exit 0
dmesg: [  830.113403] PVR_K: UM DDK-(4948957) and KM DDK-(4948957) match. [ OK ]
/proc/pvr/version: Version SGX_DDK sgxddk 1.17@4948957 (release) omap_sgx
                   System Version String: SGX revision = 120
```

No `Build options … Mismatch` and no `PVR_K:(Error)` line; the KM printed
only the DDK match. No other kernel message from the KM during the session.
`/proc/pvr/{nodes,queue,version}` exist (the openpvrsgx "TODO" in ub §10 is
answered: yes); no pvr debugfs directory beyond `dri/1/{clients,gem_names,name}`.

What `pvrsrvinit` did (strace, 239 lines, 126 ms wall):

- opened `/dev/dri/renderD128` (omapdrm, `DRM_IOCTL_VERSION` twice) and
  `/dev/dri/renderD129` (pvr); `DRM_IOCTL_DROP_MASTER` on the render node →
  `EACCES` (harmless: a render node is never master);
- the services bridge is one driver-private ioctl,
  `_IOC(_IOC_WRITE, 0x64, 0x40, 0x1c)` (= `DRM_COMMAND_BASE + 0`, 28-byte arg);
- 14 bridge mappings with **raw `mmap2`** on the pvr fd at page offsets
  `0x80000005…` (strace prints the byte offset `0x80000005000`), i.e. the
  `syscall(__NR_mmap2, …)` path of abi §4, independent of the libc ABI;
- `/etc/powervr.ini`, `/proc/self/cmdline` and `./powervr.ini` re-read for every
  apphint lookup (~40 times).

## Step 2: power (the APM question)

The ti443x reference KM config has `SUPPORT_ACTIVE_POWER_MANAGEMENT := 0`
(ub §3.7). What the domain does on our KM (with patch 0064's runtime-PM
autosuspend, delay 100 ms):

| Phase | `prm_gfx` | `gfx_pwrdm` count (OFF/ON) | active time |
|---|---|---|---|
| SrvInit (pvrsrvinit) | ON for **~223 ms**, then OFF | | prm_gfx 2743 → 2966 ms |
| 60 s idle after SGXInit, 18:31:47 → 18:32:47 | `off-0` throughout | 18/17 | +0 ms (idle +60 055 ms) |
| eglinfo (5 EGL inits) | ON briefly, OFF after | | |
| 30 fps client, 600 frames in 20.70 s | `on` for the whole run | 26/26, no transition during the run | 7606 → 28 563 ms (+21.0 s for a 20.7 s run) |
| client exits | `off-0` within 3 s | 27/26 | +96 ms after exit |
| 30 s after | `off-0` | 27/26 | +0 ms |
| client renders 1 frame, then holds its context **idle 60 s** | `off-0` within 3 s and for the full 60 s | 28/27 | +225 ms (init + frame), +0 during the hold |
| same client renders again after a 15 s idle hold | wakes, renders, OFF again | 31/30 at the end | render + readback **9 ms**, `glGetError` 0, pixels correct |

So: the GFX domain is **not** pinned ON by SGXInit or by an open context. It is
ON while frames keep coming faster than the autosuspend delay (33 ms period <
100 ms), and OFF otherwise; state survives the power-off (≥ 13 OFF→ON cycles
after SGXInit in this session, every following render correct). Whether that is
the DDK's own power-state path or only openpvrsgx's runtime-PM hooks around it,
and what an OFF→ON cycle costs in energy (master note open question 27), was
not measured. `runtime_usage` is not exposed (no `CONFIG_PM_ADVANCED_DEBUG`).

## Step 3: EGL/GLES strings, offscreen render, golden check

Full dump: [sgx540-extension-dump-2026-10-11.txt](sgx540-extension-dump-2026-10-11.txt).

```
GL_VENDOR   = Imagination Technologies
GL_RENDERER = PowerVR SGX 540
GL_VERSION  = OpenGL ES 2.0 build 1.17@4948957
GLSL        = OpenGL ES GLSL ES 1.00 build 1.17@4948957
EGL         = 1.4, Mesa Project, client APIs OpenGL_ES, driver name "pvr"
              (GBM, surfaceless and both device-platform devices)
```

- **B1 `GL_EXT_unpack_subimage`: absent.** The runtime GL extension list is
  exactly the 38 names `strings` found in `libGLESv2_PVR_MESA` (cd §3.4); no
  `GL_EXT_read_format_bgra` either. Master note open question 18 is answered.
- **B2 `EGL_EXT_image_dma_buf_import`: absent** on every platform (and no
  `…_modifiers`), as predicted from `PVR_DRI_IMAGE_VERSION 7` (ub Addendum A.1).
  Also absent: `EGL_ANDROID_native_fence_sync`, `EGL_KHR_partial_update`,
  `EGL_EXT_swap_buffers_with_damage`. Present and relevant to weston 16
  (ub Addendum A.3): `EGL_KHR_surfaceless_context`, `EGL_KHR_no_config_context`,
  `EGL_MESA_platform_gbm`/`EGL_KHR_platform_gbm`, `GL_OES_rgb8_rgba8`,
  `GL_OES_surfaceless_context`; `EGL_EXT_buffer_age` on GBM only.
- **W5** (ub Addendum A.3): the GBM platform has 12 configs with
  `win,pb` and native visuals `AR24` (0x34325241), `XR24` (0x34325258),
  `RG16` (0x36314752), with and without 24/8 depth-stencil and 4× MSAA — so a
  weston/kmscube window config exists.
- Limits: max texture / renderbuffer / viewport 2048, 8 texture units (vertex
  too), 8 vertex attribs, 128 vertex / 64 fragment uniform vectors, 8 varyings,
  point size 1-511, line width 1-16, `GL_IMPLEMENTATION_COLOR_READ_FORMAT/TYPE`
  = `GL_RGB`/`GL_UNSIGNED_SHORT_5_6_5`, 4 subpixel bits.

Probe: [drafts/first-light/sgxprobe.c](drafts/first-light/sgxprobe.c), built on
the host with `arm-linux-gnueabihf-gcc` 15.3.0
(`-std=gnu11 -O2 -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard -ldl`; highest
symbol version `GLIBC_2.34`; final source sha256 `d92afd53…17bb4`). It
dlopens libEGL/libgbm and fetches every GL entry point through
`eglGetProcAddress`. Scene: clear (0.25, 0.5, 0.75, 1), one triangle over the
lower-left half; left of x = 128 solid (1, 0, 0.5, 1), right of it a
`gl_FragCoord` gradient. Golden check
[drafts/first-light/compare.py](drafts/first-light/compare.py): renderer must
contain `PowerVR SGX 540`, every pixel within ±1 of the reference.

| Path | Result vs llvmpipe (Mesa 22.3.6, same sandbox, `LIBGL_ALWAYS_SOFTWARE=1`) |
|---|---|
| surfaceless, FBO (texture 256×256 RGBA) | PASS, max diff 0, 0/65 536 pixels off, image sha256 prefix `2ec7326c7e8540b9` |
| GBM on `renderD129`, pbuffer | PASS, identical |
| GBM on `card0`, pbuffer | PASS, identical |
| GBM on `renderD128`, pbuffer | PASS, identical |
| **seen failing 1:** llvmpipe's own run as the candidate | FAIL (`GL_RENDERER = llvmpipe (LLVM 15.0.6, 128 bits)`) |
| **seen failing 2:** one reference pixel corrupted (one byte xor 0x40) | FAIL (1/65 536 pixels, diff 64) |

This is the probe's own scene, not the master note's golden test (`particle.png`
+ `blur_distort_plain_f` into an FBO against the Phase 0 CPU reference); that
one still needs the CPU reference renderer.

## Step 3: the `mmap` path of libsrv_um (abi §4)

strace of the probe (`-e trace=openat,close,ioctl,mmap2,munmap`):

- **surfaceless:** opens `renderD129` (and `renderD128` for the omapdrm check);
  only bridge `mmap2`s (185, all on the pvr fd at `0x8000…` page offsets).
- **GBM pbuffer on `card0`:** `DRM_IOCTL_MODE_CREATE_DUMB` and
  `DRM_IOCTL_PRIME_HANDLE_TO_FD` on `card0` (libdbm allocating the 256×256
  surface on omapdrm), `GEM_CLOSE`, then
  `mmap2(NULL, 262144, PROT_READ|PROT_WRITE, MAP_SHARED, 7, 0)` on the **dma-buf
  fd**, right after Mesa resolved `gbm_bo_create`.

This strace build lacks `-k`, so the caller was pinned with an `LD_PRELOAD`
logger ([drafts/first-light/mmaplog.c](drafts/first-light/mmaplog.c), `dladdr`
on the return address):

```
mmaplog: mmap(len=262144 prot=3 flags=0x1 fd=7 off=0) = 0xabf0f000
         from /lib/arm-linux-gnueabihf/libsrv_um.so.1+0x5afb
```

Return address 0x5afb = the Thumb call at **0x5af6**, which abi §4 identifies
as `PVRSRVMapDmaBuf`'s `mmap@GLIBC_2.4` (32-bit `off_t`). **Correction to
abi §4 / master note TL;DR 9:** for drop C the branch is *taken* whenever a GBM
buffer from omapdrm is imported (offset 0, flags `MAP_SHARED`); it was
predicted "probably not taken". In the surfaceless/FBO path it is not reached.
glibc handles it correctly (it is glibc's own ABI). Under musl, the blob's
4-byte offset at `[sp+4]` would be read by musl's `mmap` as a 64-bit `off_t`
from `[sp+8..15]`, which this call site never writes (abi §4) → `EINVAL` or a
wrong offset. Route A therefore needs a 32-bit-offset `mmap` definition that
wins over musl's for `libsrv_um` (abi §7.1's own `ld-linux-armhf.so.3`-named
DSO is the natural place), or it must avoid GBM-imported buffers. Not patched,
not tried: measured only. `strerror_r` error paths were not exercised (no
error occurred).

## Step 4: kmscube / on screen

HDMI was `disconnected`, so per the plan no KMS client ran and nothing touched
the console or `nq-hdmi`. kmscube (`0.0.0~git20210103-1`, in the sandbox) needs
a connected connector even with `-x` (surfaceless), so it was not run. The
offscreen substitute is the GBM pbuffer + `glReadPixels` comparison above.

**Later the same evening (20:40-21:00), HDMI connected: on screen.**

1. The first try, on r23 after about 1 h of uptime, did not get as far as
   kmscube: `modprobe` failed with `vmalloc_node_range for size 33558528
   failed` and `SysLocateDevices: Failed to map SGX registers`. Both
   `pvr_probe()` and `SysLocateDevices()` ioremapped the whole 32 MB `gpu@0`
   resource; stock maps 64 KB (`0x56000000-0x5600FFFF`, stock-parity audit).
   That is patch 0074 (r24: the DDK half, r25: both halves), see the
   CHANGELOG.
2. On r24 (trial slot B, fresh boot) the module loaded, `pvrsrvinit` printed
   `UM DDK-(4948957) and KM DDK-(4948957) match. [ OK ]`, and kmscube on
   `card0` (omapdrm, HDMI-A-1 1280x720@60) set up EGL/GLES on the SGX
   (`PowerVR SGX 540`, `OpenGL ES 2.0 build 1.17@4948957`) but failed
   `drmModeSetCrtc` with `EINVAL`. `drm.debug=0x106` named it: `Invalid pixel
   format XR24 little-endian (0x34325258), modifier 0xffffffffffffff`. The SGX
   DRI driver has no modifier support, `gbm_bo_get_modifier()` returns
   `DRM_FORMAT_MOD_INVALID`, and this kmscube build passes any non-zero
   modifier to AddFB2 with `DRM_MODE_FB_MODIFIERS` (upstream kmscube later
   skipped `MOD_INVALID`). omapdrm is right to reject it.
3. With [drafts/first-light/kmscube-modshim.c](drafts/first-light/kmscube-modshim.c)
   (`LD_PRELOAD`, `gbm_bo_get_modifier()` returns LINEAR, so kmscube takes
   the plain AddFB2 path) **the cube rotated on the HDMI screen** for the
   60 s run (`timeout`, `nice`), confirmed by Petr. `top` showed 0 % user CPU
   during it; no kernel error or warning; `prm_gfx` back to `off-0` and the
   GPU runtime-`suspended` after exit.
4. The full diag sweep on r24 passed (capture
   `nq-captures/20261011-210212/`).

Our own renderer must not repeat the kmscube bug: create scanout buffers
without modifiers (or with `DRM_FORMAT_MOD_LINEAR`), never forward
`DRM_FORMAT_MOD_INVALID` to AddFB2.

## State left behind

- Module loaded, `prm_gfx` `off-0`, `/dev/dri/renderD129` with no clients,
  `/proc/pvr/queue` empty, SGXInit done (a reload of the module would need
  `pvrsrvinit` again). Kernel, slot and audio untouched; nothing installed by
  apk was changed.
- `/var/lib/nexusq-gpu-sandbox/` (628 MB: `root/`, `run.sh`) and
  `/tmp/gpu-out/` (14 MB of logs and PPMs) on the unit. Both are disposable;
  a reflash removes them, `rm -rf` both to reclaim the space earlier.

## Next

1. **Phase 3 on screen**: kmscube done (above); next the `nq-hdmi` hold and
   fbdev console handover per cd §4.4, with our own KMS client.
2. **Phase 2 golden test proper**: the CPU reference renderer (Phase 0 step 7)
   and the stock shaders, then the 60 s / 30 fps XRUN run with Petr listening.
3. **Route A gate item:** the `PVRSRVMapDmaBuf` 32-bit-offset `mmap` (above)
   is the first concrete musl hazard; design the shim against it and show it
   failing under plain musl first.
4. Open: per-cycle energy of GFX OFF→ON (question 27), whether the 223 ms
   SrvInit wake repeats after a module reload, `DisableHWTQTextureUpload`
   A/B.

Tools of this session (drafts, not built by anything):
[drafts/first-light/](drafts/first-light/) — `sgxprobe.c`, `mmaplog.c`,
`compare.py`, `resolve.py`, `nexusq-gpu-sandbox-run.sh`, `kmscube-modshim.c`.
