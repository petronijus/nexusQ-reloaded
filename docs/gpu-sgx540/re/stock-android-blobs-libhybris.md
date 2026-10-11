# SGX540 RE 2/7: the Nexus Q's own Android SGX540 userspace, and the libhybris path

> **Status (2026-10-11):** static reverse engineering only. Nothing in this note was
> built, flashed or committed, and no Nexus Q was touched. Downloads were kept as
> untrusted data and only read (readelf, objdump, nm, strings, Python run with `-I`).
> A second, adversarial agent re-checked every key claim the same day. Its
> corrections are folded into the text (marked *Corrected* / *Verification
> 2026-10-11*) and its full record is the **Verification (2026-10-11)** section at
> the end. **Where the body and the verification section disagree, the
> verification section wins.**
>
> Part of the reverse-engineering set; the synthesis, the decision-relevant
> verdicts and the ordered work list are in
> [../reverse-engineering.md](../reverse-engineering.md).
>
> Paths under `<session scratch>/` were scratch copies made during the research
> session (extracted blobs, disassembly listings, helper scripts, clones). They
> were not kept and are not in the repo. Every one of them can be re-derived from
> the sources listed in the note: the gitignored `reverse-eng/` tree (stock
> factory image, `vmlinux.bin`, `kallsyms.txt`) and the public URLs with the
> commits given. Paths written as `owner/repo:path` are files in that external
> repository, not in this one.

## Synthesis notes (cross-workstream, 2026-10-11)

- **The KM source match is a version match, not a proven byte match.** The AOSP
  `kernel/omap` branch `android-omap-steelhead-3.0-ics-aah` @ `03a9286b` carries
  `PVRVERSION_BUILD 785978`, its preprocessed dispatch table equals the one
  registered in `vmlinux.bin` (41/41 anchors, [km-um-bridge-abi.md](km-um-bridge-abi.md)),
  and its options evaluate to `0x0036801C`. The stock kernel banner is
  `3.0.8-gad584da`, and `ad584da` is not in AOSP `kernel/omap` (Verification row 3).
- The bridge numbering was reproduced independently three times: here (87 call
  sites, 81 distinct ids), in [km-um-bridge-abi.md](km-um-bridge-abi.md) (vmlinux
  registrations) and in [firmware-microkernel.md](firmware-microkernel.md)
  (`SGX_DEVINITPART2` = 101 at `0xc0292c60`).
- The softfp verdict was confirmed independently by
  [open-driver-feasibility.md](open-driver-feasibility.md) (all 12 IMG blobs:
  e_flags `0x5000002`, no `Tag_ABI_VFP_args`) and by
  [visualizer-gl.md](visualizer-gl.md) (`libvisualizer.so`,
  `libaudioeffect_jni.so`). The TI 1.9/1.17 Linux drops, by contrast, are
  hard-float glibc ([blob-abi.md](blob-abi.md)).
- The Google `sgx_idle` add-on documented in [stock-sysconfig.md](stock-sysconfig.md)
  is presumably in the same AOSP branch; nobody opened those files in this
  session (UNVERIFIED).

---

## TL;DR


1. **The stock userspace is DDK `1.8@785978`, branch 18, "CustomerGoogle_Android_ogles1_ogles2_GPL"**, and the
   stock kernel's built-in `pvrsrvkm` is the exact same revision. Both sides carry identical
   compatibility constants: DDK word `0x00010812`, build `785978` (`0xBFE3A`) and
   SGX build-options word `0x0036801c`. Evidence: `libsrv_um.so` literal pool at `0x9fc8`/`0x9fcc`/`0x9fb4`,
   and stock `SGXDevInitCompatCheck` `movw/movt` at `0xc0292f58`, `0xc0292ff4`, `0xc0293010`.
2. **All 13 IMG blobs on the Q are byte-identical to Google's public Galaxy Nexus package**
   `imgtec-maguro-imm76d-0f59ea74.tgz` (13/13 `cmp` equal). Only `hwcomposer.omap4.so` is Q-specific
   (TI).
3. **A kernel driver source of the same PVR revision is public.** AOSP `kernel/omap`, branch
   `android-omap-steelhead-3.0-ics-aah` (tip `03a9286bb61a`, 2012-06-11), `drivers/gpu/pvr/pvrversion.h`:
   `PVRVERSION_BUILD 785978`. (Verification 2026-10-11: the stock kernel is `3.0.8-gad584da`, built
   2012-06-29, and commit `ad584da` is NOT in AOSP `kernel/omap`; the PVR revision and compat constants
   match, but bit-for-bit source identity with the shipped KM is unproven.) Its bridge enumeration explains every one of the **81 distinct
   `/dev/pvrsrvkm` ioctl commands** that `libsrv_um.so` issues, all of the form `0xC01C67nn`.
4. **openpvrsgx's only DDK-1.8 KM (`letux/pvrsrvkm-1.8.869593`) is NOT ABI-compatible** with these
   blobs. Its `PVRSRV_BRIDGE_CORE_CMD_LAST` is 40 against 30 in stock, so every bridge ID from 31 upward is shifted
   (e.g. `GET_MISC_INFO` 38 → 48, `SGX_DOKICK` 88 → 97, `SGX_DEVINITPART2` 101 → 110). Its compat
   check also wants build 869593. A KM for these blobs means porting the steelhead
   `drivers/gpu/pvr` (785978) to 6.18, or re-numbering and re-structuring the 869593 port to match.
5. **The blobs are pure bionic, softfp ARM.** All lack `Tag_ABI_VFP_args`, so they use the base AAPCS:
   float arguments go in core registers. They were built with GCC 4.4.3 and have no SONAME, `RPATH /system/lib`
   and `DT_NEEDED libc.so/libdl.so/libcutils.so/...`. They import bionic-only ABI: `__errno`,
   `__isthreaded`, `__srget`, `__sF`, `__assert2`, `__page_size`, `__libc_init`, 4-byte bionic
   `pthread_mutex_t`/`pthread_cond_t` and bionic `jmp_buf`. musl's `ld.so` cannot load them. Only a bionic
   linker can: libhybris in-process, or the stock ICS `/system/bin/linker` (39660 B, in `system.raw.img`) running
   a separate, purely bionic process (e.g. `pvrsrvinit` as-is). The latter is UNTESTED on a 6.18 kernel.
6. **The graphics stack never opens `/dev/ion`.** The kernel interfaces it actually uses:
   * `/dev/pvrsrvkm`: 81 bridge ioctls, plus `mmap2` via raw `syscall(192)` and `clock_nanosleep` via `syscall(265)`.
   * `/dev/graphics/fb0`: `FBIOGET_VSCREENINFO`.
   * hwcomposer only: `/dev/dsscomp` (`DSSCIOC_QUERY_DISPLAY 0xC06C4F83`, `DSSCIOC_SETUP_DISPC 0x427C4F85`,
     `DSSCIOC_SETUP_DISPLAY 0x403C4F86`), fb0/fb1 (`FBIOGET_FSCREENINFO`, `FBIOBLANK`,
     `FBIO_WAITFORVSYNC`) and `/sys/class/switch/{hdmi,dock}/state`.
   * The display path additionally needs the PVR display-class driver `omaplfb` (OMAPLFB_* symbols in
     the stock kernel) sitting on omapfb plus dsscomp. None of dsscomp, omaplfb or the 3.0 ION exist in mainline.
7. **libhybris in 2026 is alive but this path is not.**
   * Upstream master (`7079712a42ea`, 2026-06-24) still ships the `jb` linker for 32-bit ARM; it is selected for SDK < 21 (`hooks.c` l.3658-3661), hence ICS (SDK 15), with only `hooks_common` + `hooks_properties` applied (the `hooks_mm` table needs SDK > 21).
   * It wraps softfp correctly via `FP_ATTRIB = __attribute__((pcs("aapcs")))` (41 uses in `binding.h`; `strtod` hook).
   * postmarketOS **removed** all hybris packages on 2020-08-03 (pmaports `e1a3324e`, "nobody is willing to put in the effort to maintain this properly").
   * Its musl patch predates musl 1.2's 64-bit `time_t`.
   * Upstream `hooks.c` has zero time64 handling.
8. **Hazards specific to our rootfs, verified in disassembly:**
   * Stock bionic `__errno` = `mrc p15,0,r0,c13,c0,3; adds r0,#8`. On musl/ARM (`GAP_ABOVE_TP 8`), `TP+8` is the first word of static TLS, and every failing *unhooked* bionic syscall stub (`ioctl`, `fcntl`, `poll`, ...) writes there.
   * Stock Android `libEGL.so` writes `TP+12` (`setGlThreadSpecific` @ `0xb280`) and reads it (`getGlThreadSpecific` @ `0xb28c`).
   * libhybris master hooks `pthread_cond_timedwait` with the bionic 8-byte `timespec` passed straight to the host. That is wrong on time64 musl.
9. **Verdict: partly viable at best, and only offscreen.**
   * GLES2 via libhybris on the "null"/pbuffer platform could work **if** we first port the 785978 KM
     (non-DRM `/dev/pvrsrvkm`) to 6.18, revive libhybris-on-musl ourselves and add TLS and time64 shims.
   * Zero-copy on-screen output through these blobs is **dead on mainline as shipped**. gralloc's framebuffer HAL needs `omaplfb`, and the stock omaplfb calls
     `dsscomp_gralloc_queue` (verified `bl` sites `0xc0299500`, `0xc0299a44`, `0xc029ad18`). `hwcomposer.omap4` needs `/dev/dsscomp`
     and implements the legacy HWC device API 0.1 (`common.version = 1`). (Corrected 2026-10-11: HWC 0.x itself is not the
     blocker; Sailfish's `qt5-qpa-hwcomposer-plugin` @ `31f4f650` still has `HwComposerBackend_v0` for HWC 0.1–0.3. The
     blocker is `/dev/dsscomp`.) A slow fallback (offscreen render + CPU copy into an omapdrm dumb buffer) is not ruled out.
   * Recommendation: do not make it the primary path. Keep the 785978 blob + KM-source pair as a **known-good
     ABI oracle** for bring-up: same SoC and same core rev, with the uKernel embedded in `libsrv_init.so` `.rodata`.

---

## 0. Scope and artefacts

Date: 2026-10-11. Scope: the stock IAN67K (Android 4.0.4, API 15) PowerVR userspace from
`reverse-eng/factory/tungsten-ian67k/system.raw.img`, the kernel interfaces it expects, and
whether libhybris can run it on our mainline 6.18 / postmarketOS (musl, armv7 hard-float).
Nothing was built, flashed or committed. No Nexus Q was touched.

Scratch artefacts (outside the repo):
`<session scratch>/gpu/re/`.
Key files there: `stock-blobs/` (debugfs dumps), `stock-blobs.sha256`, `srv_um.dis`,
`bridge_calls.txt`, `bridge_sizes.txt`, `enum_785978.txt`, `enum_869593.txt` and
`scripts/bridgeids.py|bridgesizes.py|bridgeenum.py`. Downloads, kept as untrusted data and never
executed, are in `<session scratch>/gpu/re-downloads/`.

---

## 1. Inventory of the stock graphics files

Extracted with `debugfs -R "dump <path> <out>" system.raw.img`. The ext4 is mounted as `/system`, so
`/vendor/...` in the image means `/system/vendor/...` on the device.

| Path (on device) | Size | SHA-256 | Role |
|---|---:|---|---|
| /system/vendor/bin/pvrsrvinit | 5432 | 0e22700666cf4021d75cab7bd16cb5e2ad6bc14fe4ddb879f2fed219c430ec80 | one-shot init; calls `SrvInit()` |
| /system/vendor/lib/libsrv_um.so | 190204 | f177b896e7b37e6afd6e82a1eeef8923035fec15d15af64c32bb127db4b946fa | services client (all ioctls) |
| /system/vendor/lib/libsrv_init.so | 115708 | c4dee422fb9c3364ff8128958c077da847f2eb18c4b43e2d47b198f849691926 | SGX init + uKernel (`.rodata` 0x194a8 B) |
| /system/vendor/lib/libIMGegl.so | 71532 | dddc3f7dbc75a83d41d104b9bd4eada59a37889869f0876b2fe9cfbfce424a38 | IMG EGL core ("1.4 build 1.8@785978") |
| /system/vendor/lib/libpvr2d.so | 21708 | b8b99b0a9123e4bde6723454b4343cd14373b6ac1e7c753e7efc7034f2b45c23 | PVR2D (blits, flip chains) |
| /system/vendor/lib/libpvrANDROID_WSEGL.so | 13600 | f14d2555c3078f162a2d954a57fc4a92690cf61bd377af10c61c5e5c7ca03eb2 | window-system glue → ANativeWindow + gralloc |
| /system/vendor/lib/libPVRScopeServices.so | 9192 | 2bb828400047742b47c0eadeb310d7addf9adfd2f6c6488cf3cceea4958580ae | HW perf counters |
| /system/vendor/lib/libusc.so | 898564 | f94c73b7206ec306e81e4585ae7621cef3eb5a65a20642a16420178d538a1740 | USSE shader backend (UniFlex) |
| /system/vendor/lib/libglslcompiler.so | 253264 | bd921d395704180e982ec16c2a8fe7418956b2677d468bf3779de29097d6b6b1 | GLSL ES 1.00 front end |
| /system/vendor/lib/egl/libEGL_POWERVR_SGX540_120.so | 5140 | 0af93f70d07b1329db1eda29d14d6d4370926148d09f7e424e699ddfe426de75 | EGL entry (forwards to IMGegl*) |
| /system/vendor/lib/egl/libGLESv1_CM_POWERVR_SGX540_120.so | 446184 | d61b2565e8b0330f968161e5a7f7480810c5f07c15eee84cc51935d231d1ddda | GLES 1.1 |
| /system/vendor/lib/egl/libGLESv2_POWERVR_SGX540_120.so | 372324 | 229988dd811c2b8b12e6d2b785b982c443fcf187f364ab438afd7f3dd0c0bcc8 | GLES 2.0 ("OpenGL ES 2.0 build 1.8@785978") |
| /system/vendor/lib/hw/gralloc.omap4.so | 35300 | 815c2e9ca04527d212730114924214cc578bfd0deed9f5904782a2dec2f3b549 | gralloc HAL, `HMI` name "IMG SGX Graphics HAL", author "Imagination Technologies" |
| /system/vendor/lib/hw/hwcomposer.omap4.so | 92260 | 83774096fad6f627bed2d232954b15f6bbff461d7b96dcbae149b4dc9a9d5007 | HWC HAL, "OMAP 44xx Hardware Composer HAL", author "Texas Instruments" |
| /system/lib/egl/egl.cfg | 36 | 83325b3ba0ccf444194b4921d063edc9b8e9e1c37479b444316a5e495453900c | `0 0 android` / `0 1 POWERVR_SGX540_120` |
| /system/lib/egl/libGLES_android.so | 81512 | d8bd8cefd0e412593ee24f3305cbce3b27c55bdd9c6e9c1d4e4794c4dff70cb6 | AOSP software GL |
| /system/lib/libEGL.so | 144624 | a2623daaa23c9bef9606f176fb8cc67fdd99da8c1974a5eb0c4b8626668c5371 | AOSP EGL loader/wrapper |
| /system/lib/libc.so | 282248 | a42d93104ff3785261913edbd2fda4d5e49099c4de72d0a2a4daee76c06b8a34 | ICS bionic |

* No `/system/lib/hw/gralloc.omap4.so` and no `hwcomposer.omap4*` exist under `/system/lib/hw`. That directory
  only holds `gralloc.default.so` (10260 B), audio, camera, nfc and local_time.
* No `libion`, `libsync`, `libdsswb` or `libtimemmgr` is needed by any graphics blob (see §3).
* `build.prop`: `ro.build.version.sdk=15`, `ro.build.version.release=4.0.4`, `ro.build.id=IAN67K`,
  `ro.product.cpu.abi=armeabi-v7a`, `ro.board.platform=omap4`, `ro.opengles.version=131072` (GLES 2.0).
* Stock init (`boot.img` ramdisk, extracted from the `ANDROID!` header):
  * `init.steelhead.rc` has `chmod 0666 /dev/pvrsrvkm` (line 32), `chmod 0777 /dev/ion` (line 56) and
    `service pvrsrvinit /vendor/bin/pvrsrvinit`, `class core`, `user root`, `oneshot` (line 89).
  * `ueventd.steelhead.rc` has `/dev/dsscomp 0666 system system` and `/dev/tiler 0666 system system`.
  * `ueventd.rc:29` has `/dev/graphics/* 0660 root graphics`.

### 1.1 Provenance: the Q's IMG blobs are Google's public Galaxy Nexus 4.0.4 package

* `https://dl.google.com/dl/android/aosp/imgtec-maguro-imm76d-0f59ea74.tgz` (sha256
  `ec12671795a8a39b7a781463982001b5f2e63d2f58458074ccfa6b64496a1174`) contains a self-extracting
  `extract-imgtec-maguro.sh`. The payload starts at `tail -n +269`. It was extracted with `tail | tar`, never executed.
* Its 13 `proprietary/*` files are **byte-identical** (`cmp`, 13 of 13) to the Q's `/system/vendor` files above.
* The install paths in `device-maguro.mk` are the same (`system/vendor/lib/egl/...`).
* License (in the extractor, line 40): "The term 'Authorized Android Enabled Device' means only the device identified on
  the site from which You downloaded the Software". This is a Galaxy-Nexus-only, non-commercial licence.
  Redistributing these blobs in our image is a **legal** blocker independent of feasibility. The Q's own
  factory image carries the same bytes under Google's factory-image terms (UNVERIFIED: those terms were not read).
  Note also §3.b(i) of the same licence: no right to "disassemble, decompile, reverse engineer" the Software. Whether that
  clause binds this interoperability analysis (e.g. under EU Directive 2009/24/EC art. 6) is a legal question, UNVERIFIED, not answered here.

Other OMAP4 SGX540 packages on the same page, all fetched as data (DDK from `strings`):

| Package | GLES2 version string |
|---|---|
| imgtec-maguro-iml74k-a796ffae (4.0.3) | build 1.8@785978 |
| imgtec-panda-20120430-67545da7 (PandaBoard) | build 1.8@785978 |
| imgtec-maguro-jro03h-827bcb4c (4.1.1) | build 1.8@905891 |
| imgtec-panda-20130603-539d1ac3 | build 1.8@905891 |
| imgtec-maguro-jdq39-bb3c4e4e (4.2.2) | build 1.8.GOOGLENEXUS.ED945322@2198402 |
| imgtec-maguro-jwr66y-b0a4a1ef (4.3) | build 1.8.GOOGLENEXUS.ED945322@2198402 |

So three distinct 1.8 UMs exist publicly for OMAP4/SGX540-120. Each needs its own KM: 785978, 905891, or
ED945322@2198402. The last two are UNVERIFIED as to KM source location: they should be the
`android-omap-tuna-3.0-jb-*` branches, which were not fetched.

---

## 2. ELF / ABI facts (per blob)

Commands: `readelf -h/-d/-A`, `readelf -p .comment`, `nm -D --undefined-only`.

### 2.1 Float ABI: softfp everywhere

All 13 IMG blobs, `hwcomposer.omap4.so`, `libEGL.so` and `libGLES_android.so` carry:

```
Tag_CPU_name: "ARM v7"   Tag_CPU_arch: v7   Tag_THUMB_ISA_use: Thumb-2
Tag_FP_arch: VFPv3       Tag_Advanced_SIMD_arch: NEONv1
Tag_ABI_align_needed: 8-byte   Tag_ABI_enum_size: int   Tag_ABI_HardFP_use: Deprecated
```

* **No `Tag_ABI_VFP_args`** in any of them. Absent means base AAPCS, so float and double arguments and returns go in
  r0–r3. This is Android armeabi-v7a softfp. They use VFP/NEON instructions internally.
* ELF header flags: `0x5000002` (IMG blobs) and `0x5000000` (Google-built). Neither has
  `EF_ARM_ABI_FLOAT_HARD` (0x400) nor `EF_ARM_ABI_FLOAT_SOFT` (0x200).
* Compiler: `.comment` = `GCC: (GNU) 4.4.3`. `hwcomposer.omap4.so` has `.note.gnu.gold-version` "gold 1.9".
* `hwcomposer.omap4.so`, `libEGL.so` and `libGLES_android.so` have `DT_TEXTREL`. The IMG blobs do not.

Our rootfs is armv7 hard-float (`armhf`/`armv7` Alpine, `__ARM_PCS_VFP`). A hard-float caller passing
`float` to a softfp callee puts it in `s0`, and the callee reads `r0`, so the value is wrong. Calls without float arguments are
ABI-compatible.

### 2.2 Dynamic section

* The IMG blobs have **no `DT_SONAME`** and use `DT_RPATH /system/lib`.
* `pvrsrvinit` is `ET_EXEC` with `PT_INTERP /system/bin/linker`, entry `0x8410`, and imports only
  `__libc_init`, `PVRSRVDebugPrintf` and `SrvInit`.

| Blob | DT_NEEDED |
|---|---|
| libsrv_um.so | libc.so libdl.so libcutils.so **libhardware.so** |
| libsrv_init.so | libc libdl libcutils libsrv_um |
| libIMGegl.so | libc libdl libcutils libsrv_um |
| libpvr2d.so | libc libdl libcutils libsrv_um |
| libpvrANDROID_WSEGL.so | libc libdl libcutils libsrv_um **libhardware** |
| libPVRScopeServices.so | libc libdl libcutils libsrv_um libstdc++ |
| libusc.so | libc libdl libcutils |
| libglslcompiler.so | libc libdl libcutils libsrv_um libusc libm |
| libEGL_POWERVR_SGX540_120.so | libc libdl libcutils libIMGegl |
| libGLESv1_CM_POWERVR_SGX540_120.so | libc libdl libcutils libsrv_um libIMGegl libusc libm |
| libGLESv2_POWERVR_SGX540_120.so | libc libdl libcutils libsrv_um libIMGegl libm **libcrypto** (SHA256_* for program binaries) |
| gralloc.omap4.so | libc libdl libcutils libsrv_um libpvr2d |
| hwcomposer.omap4.so | liblog libEGL libcutils libutils libhardware libhardware_legacy libz libc libstdc++ libm |
| pvrsrvinit | libc libdl libcutils libsrv_init libsrv_um |

**Transitive bionic closure** from stock `/system/lib`, computed by walking `DT_NEEDED` and resolving vendor
libs first. Sizes in bytes:

`libc.so` 282248, `libm.so` 87412, `libdl.so` 9548, `libcutils.so` 63912, `liblog.so` 13892,
`libhardware.so` 5620, `libhardware_legacy.so` 18276, `libnetutils.so` 22096, `libwpa_client.so` 9736,
`libutils.so` 190184, `libstdc++.so` 5524, `libstlport.so` 211180, `libz.so` 95988,
`libcrypto.so` 826288, `libEGL.so` 144624, `libGLESv2_dbg.so` 136856.

That is about 2.1 MB (2,123,384 B) of AOSP libs plus about 2.5 MB (2,530,412 B, the 13 IMG blobs + `hwcomposer.omap4.so`) of IMG/TI blobs. No library was missing.

### 2.3 Hard-coded paths and files

| String | Where (file offset) |
|---|---|
| `/dev/pvrsrvkm` | libsrv_um.so `0x2285c` ("OpenServices: Cannot open device driver /dev/pvrsrvkm." `0x228d5`) |
| `/etc/powervr.ini` (AppHints) | libsrv_um.so `0x22705` |
| `/proc/self/cmdline` | libsrv_um.so `0x22475`, gralloc.omap4.so `0x725c` |
| `gralloc` (`hw_get_module` id) | libsrv_um.so `0x2438d`, libpvrANDROID_WSEGL.so `0x2205`, hwcomposer `0x12ea4` |
| `/system/vendor/lib/egl/libGLESv2_POWERVR_SGX540_120.so` | libIMGegl.so: only inside the error string at `0xfbdd` ("LoadOGLES2AndGetFunctions: Couldn't load OGL module /system/..."), path tail at `0xfc11`; the dlopen argument is presumably that merged tail (UNVERIFIED) |
| `/system/vendor/lib/egl/libGLESv1_CM_POWERVR_SGX540_120.so` | libIMGegl.so `0xfcfd`, gralloc.omap4.so `0x6687` |
| `libpvrANDROID_WSEGL.so` (dlopen by name) | libIMGegl.so `0xfe20` |
| `libglslcompiler.so` (dlopen) | libGLESv2_POWERVR `0x51743` |
| `/dev/graphics/fb0` | gralloc.omap4.so `0x6466`, hwcomposer `0x12f50` |
| `/dev/graphics/fb1` | hwcomposer `0x12fc8` |
| `/dev/dsscomp` | hwcomposer `0x12f24` |
| `/sys/class/switch/hdmi/state`, `/sys/class/switch/dock/state` | hwcomposer `0x130fc`, `0x1311c` |
| properties `persist.hwc.*`, `debug.hwc.*` | hwcomposer `0x12d2c`..`0x130a4` |

`libpvrANDROID_WSEGL.so` checks the ANativeWindow / buffer magic ("%s: Unrecognized magic") and uses
`DEFAULT_WIDTH`/`DEFAULT_HEIGHT`/`TRANSFORM_HINT` queries plus dequeue/lock/queue/cancel.
`libIMGegl.so` advertises:

* `EGL_ANDROID_blob_cache`, `EGL_ANDROID_image_native_buffer`, `EGL_ANDROID_recordable`
* `EGL_IMG_context_priority`, `EGL_KHR_fence_sync`
* `EGL_KHR_image(_base)`, `EGL_KHR_gl_{texture_2D,texture_cubemap,renderbuffer}_image`, `EGL_KHR_vg_parent_image`

The GLES2 extensions include `GL_OES_EGL_image_external`, `GL_IMG_texture_stream2`, `GL_OES_get_program_binary`,
`GL_IMG_program_binary` and `GL_IMG_texture_compression_pvrtc`.

### 2.4 Imports: what only bionic provides

The union of undefined dynamic symbols over all IMG blobs plus hwcomposer, excluding PVR/SGX/IMG/KEGL/PVR2D/png
internals, is **156 symbols** (`imports_all.txt`). Bionic-only ABI among them:

| Symbol | Importer(s) | Why it is bionic-only |
|---|---|---|
| `__errno` | libsrv_um, hwcomposer | glibc/musl export `__errno_location` |
| `__isthreaded`, `__srget` | libsrv_um (from the `getc` macro) | BSD-stdio internals of bionic `FILE` |
| `__sF` | hwcomposer | bionic `stdin/stdout/stderr` array |
| `__assert2` | libusc, GLESv1 | bionic assert |
| `__page_size` | gralloc.omap4 | bionic global |
| `__libc_init` | pvrsrvinit | bionic executable entry |
| `setjmp`/`longjmp` | libusc, GLESv1, hwcomposer | bionic `jmp_buf` layout |
| `pthread_mutex_*`, `pthread_cond_*`, `pthread_key_*`, `pthread_once` | many | bionic `pthread_mutex_t`/`pthread_cond_t` are 4 bytes on 32-bit |
| `native_handle_create/delete`, `property_get/set`, `uevent_*` | gralloc, hwcomposer | libcutils / libhardware_legacy |
| `hw_get_module` | libsrv_um, WSEGL, hwcomposer | libhardware (Android HAL loader) |
| `__android_log_print` | libsrv_um, hwcomposer | liblog |
| `SHA256_Init/Update/Final` | GLESv2 | Android libcrypto (OpenSSL 1.0.0-era) |
| `__aeabi_*` (31 symbols) | most | RTABI helpers; bionic `libc.so` exports them |

Raw `syscall()` uses in libsrv_um (resolved `r0` at the call site):

* `0x00d1b8` (in `PVRSRVDebugPrintf+…`): `syscall(0xC0 = 192)`. On ARM EABI that is `mmap2`. This is the
  services mmap path, bypassing libc `mmap`.
* `0x00bb38` (in `PVRSRVWaitus`): `syscall(0x109 = 265)`. On ARM EABI that is `clock_nanosleep`, with a 32-bit `timespec`.
* `fcntl(fd, 2 /*F_SETFD*/, 1 /*FD_CLOEXEC*/)` after `open` (args set at `0xcbd4`, call at `0xcbdc`).

Our `steelhead_defconfig` has `CONFIG_COMPAT_32BIT_TIME=y`, so 32-bit-time syscalls still exist.

---

## 3. The kernel ABI these blobs expect

### 3.1 Version and compat constants: proven pair

* UM `libsrv_um.so`, `SGXConnectionCheck`: a static function at `0x9e9c`, labelled `SGXGetMiscInfo+0x108` by objdump.
  It calls `SGXGetMiscInfo` with request 2, then compares:
  * build options against `0x0036801c` (literal at `0x9fb4`; error string "SGXConnectionCheck: Build option mismatch …" at
    `0x218d4`);
  * the DDK word against `0x00010812` (literal `0x9fc8` = major 1, minor 8, branch 0x12 = 18);
  * the build number against `785978` (literal `0x9fcc` = `0x000bfe3a`; "Incompatible client DDK revision (%d)/device DDK
    revision (%d)" at `0x219a6`).
  * Failure returns `25`/`26` (`PVRSRV_ERROR_*` codes; the error strings `PVRSRV_ERROR_DDK_VERSION_MISMATCH` and
    `PVRSRV_ERROR_BUILD_MISMATCH` are at `0x22e1a`/`0x22e3c`).
* The constant 785978 also sits as a word at `libglslcompiler.so` `0x77d0` and `libGLESv2_POWERVR` `0x9c78`.
* KM (stock `vmlinux.bin`, `SGXDevInitCompatCheck` @ `0xc0292f1c`, from `kallsyms.txt`):
  * `movw/movt 0x0036801c` @ `0xc0292f58`/`0xc0292f5c` and `0xc0292f7c`/`0xc0292f80`;
  * `movw/movt 0x00010812` @ `0xc0292ff4`/`0xc0292ff8`;
  * `movw/movt 0x000bfe3a` @ `0xc0293010`/`0xc0293018` and `0xc0293028`/`0xc029302c`;
  * strings "SGXInit: Mismatch in client-side and KM driver build options …",
    "SGXInit: Client-side and KM driver build options match. [ OK ]" and `drivers/gpu/pvr/sgx/sgxinit.c`.
* Kernel version string at file offset `0x678738`: **`CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978`**.
  The module parameters are `pvrsrvkm.sgx_apm_latency`, `.sgx_idle_timeout`, `.sgx_idle_mode`, `.sgx_idle_logging` and
  `.gPVRDebugLevel` (`0x57a17c`..). The KM is built in (`drivers/gpu/pvr/…`), not DRM (no `drm_*` PVR glue in kallsyms).
  Its dispatcher is `PVRSRV_BridgeDispatchKM`.
* Public KM source of exactly this revision: AOSP `kernel/omap` `android-omap-steelhead-3.0-ics-aah`
  @ `03a9286bb61a9acd28027206c4937990ac817f1b`. Its `drivers/gpu/pvr/pvrversion.h` has
  `PVRVERSION_MAJ 1`, `MIN 8`, `BRANCH 18`, `BUILD 785978` and the same `PVRVERSION_STRING`.

### 3.2 `/dev/pvrsrvkm` bridge: the call mechanism

There is exactly one `ioctl@plt` call site in `libsrv_um.so` (`0xc6b4`), inside a 6-argument wrapper at
`0xc674` (r0–r3 plus two stack arguments at `[sp+56]`/`[sp+60]` after a 56-byte frame), `PVRSRVBridgeCall`-like:

```
c680: mov lr,#28              ; ui32Size = sizeof(PVRSRV_BRIDGE_PACKAGE) = 28
c6ac: str r1,[sp,#12]         ; ui32BridgeID  (= the ioctl cmd itself)
c684: str r2,[sp,#20]         ; pvParamIn
c694: str r3,[sp,#24]         ; ui32InBufferSize
c6a4: str [sp+56],[sp,#28]    ; pvParamOut
c6b0: str [sp+60],[sp,#32]    ; ui32OutBufferSize
c6a0: str [r0+4],[sp,#36]     ; hKernelServices
c68c: ldr r0,[r0]             ; fd of /dev/pvrsrvkm
c6b4: bl ioctl(fd, ui32BridgeID, &pkg)
```

This matches `PVRSRV_BRIDGE_PACKAGE` in the steelhead `pvr_bridge.h`: seven 32-bit fields with `IMG_HANDLE`
(no `SUPPORT_SID_INTERFACE`). The command is `PVRSRV_IOWR(n) = _IOWR('g', n, PVRSRV_BRIDGE_PACKAGE)`,
which gives **`0xC01C6700 | n`**. The wrapper is called from 87 sites (`bridge_calls.txt`).
All 87 `r1` values were statically resolved (`<session scratch>/gpu/re/scripts/bridgeids.py`), giving **81 distinct IDs**. Every one maps to a
define in the steelhead headers, which were evaluated with `PDUMP`, `SUPPORT_OVERLAY_ROTATE_BLIT` and
`SGX_FEATURE_2D_HARDWARE` undefined and `TRANSFER_QUEUE` defined (`<session scratch>/gpu/re/scripts/bridgeenum.py`).

Table columns:

* "in"/"out": in/out buffer sizes resolved at the call site (`<session scratch>/gpu/re/scripts/bridgesizes.py`, heuristic; it
  takes the last constant written before the call). "(runtime)" means computed in a register, "?" means not
  resolved. Treat sizes as **leads to be checked against `sizeof()` in the steelhead headers**, not as facts.
* "869593 nr": the number the same command has in openpvrsgx `letux/pvrsrvkm-1.8.869593` @ `214f07dd8fe4`.

| nr | ioctl cmd | PVRSRV_BRIDGE_… | in | out | 869593 nr |
|---:|---|---|---|---|---|
| 0 | 0xC01C6700 | ENUM_DEVICES | (runtime) | 328 | 0 |
| 1 | 0xC01C6701 | ACQUIRE_DEVICEINFO | 12 | 8 | 1 |
| 3 | 0xC01C6703 | CREATE_DEVMEMCONTEXT | 8 | 780 | 3 |
| 4 | 0xC01C6704 | DESTROY_DEVMEMCONTEXT | 12 | 8 | 4 |
| 5 | 0xC01C6705 | GET_DEVMEM_HEAPINFO | 12 | 776 | 5 |
| 6 | 0xC01C6706 | ALLOC_DEVICEMEM | 32 | 96 | 6 |
| 7 | 0xC01C6707 | FREE_DEVICEMEM | 80 | 8 | 7 |
| 11 | 0xC01C670B | MHANDLE_TO_MMAP_DATA | 8 | 20 | 11 |
| 12 | 0xC01C670C | CONNECT_SERVICES | (runtime) | 8 | 12 |
| 13 | 0xC01C670D | DISCONNECT_SERVICES | (runtime) | 8 | 13 |
| 20 | 0xC01C6714 | MAP_DEV_MEMORY | 12 | 96 | 20 |
| 21 | 0xC01C6715 | UNMAP_DEV_MEMORY | 96 | 8 | 21 |
| 22 | 0xC01C6716 | MAP_DEVICECLASS_MEMORY | 12 | 104 | 22 |
| 23 | 0xC01C6717 | UNMAP_DEVICECLASS_MEMORY | 96 | 8 | 23 |
| 26 | 0xC01C671A | EXPORT_DEVICEMEM | 12 | 16 | 26 |
| 27 | 0xC01C671B | RELEASE_MMAP_DATA | 8 | 16 | 27 |
| 29 | 0xC01C671D | MAP_DEV_MEMORY_2 | 12 | 96 | 29 |
| 30 | 0xC01C671E | EXPORT_DEVICEMEM_2 | 12 | 16 | 30 |
| 34 | 0xC01C6722 | MAPPHYSTOUSERSPACE | ? | 12 | 44 |
| 35 | 0xC01C6723 | UNMAPPHYSTOUSERSPACE | 16 | ? | 45 |
| 38 | 0xC01C6726 | GET_MISC_INFO | (runtime) | 148 | 48 |
| 41 | 0xC01C6729 | ENUM_CLASS | 8 | ? | 51 |
| 42 | 0xC01C672A | OPEN_DISPCLASS_DEVICE | 12 | 8 | 52 |
| 43 | 0xC01C672B | CLOSE_DISPCLASS_DEVICE | (runtime) | 8 | 53 |
| 44 | 0xC01C672C | ENUM_DISPCLASS_FORMATS | 8 | 48 | 54 |
| 45 | 0xC01C672D | ENUM_DISPCLASS_DIMS | 12 | 128 | 55 |
| 47 | 0xC01C672F | GET_DISPCLASS_INFO | 8 | 80 | 57 |
| 48 | 0xC01C6730 | CREATE_DISPCLASS_SWAPCHAIN | 56 | 12 | 58 |
| 49 | 0xC01C6731 | DESTROY_DISPCLASS_SWAPCHAIN | 12 | 8 | 59 |
| 50 | 0xC01C6732 | SET_DISPCLASS_DSTRECT | ? | 8 | 60 |
| 51 | 0xC01C6733 | SET_DISPCLASS_SRCRECT | ? | 8 | 61 |
| 52 | 0xC01C6734 | SET_DISPCLASS_DSTCOLOURKEY | 16 | 8 | 62 |
| 53 | 0xC01C6735 | SET_DISPCLASS_SRCCOLOURKEY | 16 | 8 | 63 |
| 54 | 0xC01C6736 | GET_DISPCLASS_BUFFERS | 12 | 40 | 64 |
| 55 | 0xC01C6737 | SWAP_DISPCLASS_TO_BUFFER | ? | 8 | 65 |
| 56 | 0xC01C6738 | SWAP_DISPCLASS_TO_BUFFER2 | ? | 8 | 66 |
| 57 | 0xC01C6739 | SWAP_DISPCLASS_TO_SYSTEM | 12 | 8 | 67 |
| 58 | 0xC01C673A | OPEN_BUFFERCLASS_DEVICE | 12 | 8 | 68 |
| 59 | 0xC01C673B | CLOSE_BUFFERCLASS_DEVICE | (runtime) | 8 | 69 |
| 60 | 0xC01C673C | GET_BUFFERCLASS_INFO | 8 | 84 | 70 |
| 61 | 0xC01C673D | GET_BUFFERCLASS_BUFFER | 12 | 8 | 71 |
| 62 | 0xC01C673E | WRAP_EXT_MEMORY | 40 | ? | 72 |
| 63 | 0xC01C673F | UNWRAP_EXT_MEMORY | 96 | 8 | 73 |
| 64 | 0xC01C6740 | ALLOC_SHARED_SYS_MEM | 12 | 72 | 74 |
| 65 | 0xC01C6741 | FREE_SHARED_SYS_MEM | 72 | 4 | 75 |
| 66 | 0xC01C6742 | MAP_MEMINFO_MEM | 8 | ? | 76 |
| 68 | 0xC01C6744 | GETMMU_PD_DEVPADDR | 8 | ? | absent |
| 69 | 0xC01C6745 | INITSRV_CONNECT | (runtime) | 8 | 78 |
| 70 | 0xC01C6746 | INITSRV_DISCONNECT | 8 | ? | 79 |
| 71 | 0xC01C6747 | EVENT_OBJECT_WAIT | (runtime) | 8 | 80 |
| 72 | 0xC01C6748 | EVENT_OBJECT_OPEN | 56 | 8 | 81 |
| 73 | 0xC01C6749 | EVENT_OBJECT_CLOSE | 60 | 8 | 82 |
| 74 | 0xC01C674A | CREATE_SYNC_INFO_MOD_OBJ | (runtime) | 8 | 83 |
| 75 | 0xC01C674B | DESTROY_SYNC_INFO_MOD_OBJ | (runtime) | 8 | 84 |
| 76 | 0xC01C674C | MODIFY_PENDING_SYNC_OPS | (runtime) | 16 | 85 |
| 77 | 0xC01C674D | MODIFY_COMPLETE_SYNC_OPS | (runtime) | 8 | 86 |
| 78 | 0xC01C674E | SYNC_OPS_TAKE_TOKEN | 8 | 16 | 87 |
| 79 | 0xC01C674F | SYNC_OPS_FLUSH_TO_TOKEN | 20 | 8 | 88 |
| 80 | 0xC01C6750 | SYNC_OPS_FLUSH_TO_MOD_OBJ | (runtime) | 8 | 89 |
| 81 | 0xC01C6751 | SYNC_OPS_FLUSH_TO_DELTA | 12 | 8 | 90 |
| 82 | 0xC01C6752 | ALLOC_SYNC_INFO | (runtime) | 8 | 91 |
| 83 | 0xC01C6753 | FREE_SYNC_INFO | (runtime) | 8 | 92 |
| 85 | 0xC01C6755 | SGX_GETCLIENTINFO | 8 | ? | 94 |
| 86 | 0xC01C6756 | SGX_RELEASECLIENTINFO | 256 | 8 | 95 |
| 87 | 0xC01C6757 | SGX_GETINTERNALDEVINFO | 8 | ? | 96 |
| 88 | 0xC01C6758 | SGX_DOKICK | 564 | ? | 97 |
| 94 | 0xC01C675E | SGX_2DQUERYBLTSCOMPLETE | 16 | 8 | 103 |
| 98 | 0xC01C6762 | SGX_SUBMITTRANSFER | 88 | ? | 107 |
| 99 | 0xC01C6763 | SGX_GETMISCINFO | 12 | 8 | 108 |
| 100 | 0xC01C6764 | SGXINFO_FOR_SRVINIT | ? | 776 | 109 |
| 101 | 0xC01C6765 | SGX_DEVINITPART2 | 2072 | 8 | 110 |
| 102 | 0xC01C6766 | SGX_FINDSHAREDPBDESC | 16 | 72 | 111 |
| 103 | 0xC01C6767 | SGX_UNREFSHAREDPBDESC | ? | 4 | 112 |
| 104 | 0xC01C6768 | SGX_ADDSHAREDPBDESC | 40 | 8 | 113 |
| 105 | 0xC01C6769 | SGX_REGISTER_HW_RENDER_CONTEXT | 12 | 8 | 114 |
| 106 | 0xC01C676A | SGX_FLUSH_HW_RENDER_TARGET | 12 | 8 | 115 |
| 107 | 0xC01C676B | SGX_UNREGISTER_HW_RENDER_CONTEXT | 16 | 8 | 116 |
| 111 | 0xC01C676F | SGX_REGISTER_HW_TRANSFER_CONTEXT | 12 | 8 | 120 |
| 112 | 0xC01C6770 | SGX_UNREGISTER_HW_TRANSFER_CONTEXT | 16 | 8 | 121 |
| 113 | 0xC01C6771 | SGX_SCHEDULE_PROCESS_QUEUES | (runtime) | 8 | 122 |
| 115 | 0xC01C6773 | SGX_READ_HWPERF_CB | (runtime) | 16 | 123 |

The full steelhead numbering (106 defines) is in `enum_785978.txt`.

* Core block 0–30 ends at `EXPORT_DEVICEMEM_2`. Then SIM 31–33, MAPPING 34–36, STATS 37, MISC 38–39, OEM 40,
  DEVCLASS 41, DISPCLASS 42–57, BUFCLASS 58–61, WRAP 62–63, SHAREDMEM 64–67, `GETMMU_PD_DEVPADDR` 68,
  INITSRV 69–70, EVENT 71–73, SYNC_OPS 74–83 and `LAST_NON_DEVICE` 84. The SGX base is 85.
* The 869593 tree has CORE 0–40 (adds `REMAP_TO_DEV`, `UNMAP_FROM_DEV`, `MULTI_MANAGE_DEV_MEM` and
  `CORE_CMD_RESERVED_1..7`) and has no `GETMMU_PD_DEVPADDR`. The resulting offset is +10 up to nr 67 and +9 from 69.
* The SGX block is relative to `LAST_NON_DEVICE+1` in both trees, so it inherits the +9 shift.

Interpretation:

* **The KM ABI is defined by the steelhead 785978 tree, not by any openpvrsgx branch.**
* Even with renumbering, struct layouts must be re-verified. One example is `SGX_DOKICK` in = 564 bytes; another is
  `SGX_DEVINITPART2` in = 2072 bytes, which embeds `SGX_INIT_INFO` and the uKernel addresses.
* In 1.8 the **uKernel is supplied by userspace**. `libsrv_init.so` `SetupuKernel` strings ("Failed to allocate 0x%x bytes for %s USE
  program") sit in a 103 KB `.rodata`. So the 785978 UM and KM are self-contained: no separate firmware file.

### 3.3 Other device interfaces

| Node / path | Who | ioctl / op | Value | Mainline 6.18 status |
|---|---|---|---|---|
| `/dev/pvrsrvkm` | libsrv_um | 81 bridge ioctls `0xC01C67nn`; `mmap2` (raw syscall 192) with handle offsets | §3.2 | absent; needs an out-of-tree KM at exactly 785978 ABI, **non-DRM char-dev mode** |
| `/dev/graphics/fb0` | gralloc.omap4 (1 site @ `0x1cc4`) | `FBIOGET_VSCREENINFO` | `0x4600` | `/dev/fb0` exists via omapdrm fbdev emulation (`CONFIG_DRM_FBDEV_EMULATION=y`); path differs (`/dev/graphics/` symlink needed) |
| `/dev/graphics/fb0`,`fb1` | hwcomposer | `FBIOGET_FSCREENINFO` / `FBIOBLANK` / `FBIO_WAITFORVSYNC` | `0x4602` / `0x4611` / `0x40044620` | fb0 only (DRM fbdev emu); no fb1 |
| `/dev/dsscomp` | hwcomposer (sites `0x40c4`, `0x43f0`, `0x49ec`, `0x53b0`, `0x6104`) | `DSSCIOC_SETUP_DISPC _IOW('O',133, 636 B)`, `DSSCIOC_QUERY_DISPLAY _IOWR('O',131, 108 B)`, `DSSCIOC_SETUP_DISPLAY _IOW('O',134, 60 B)` | `0x427C4F85`, `0xC06C4F83`, `0x403C4F86` | **does not exist** (TI 3.0 Android-only; stock syms `dsscomp_*`, `dsscomp_gralloc_queue_ioctl`) |
| `/sys/class/switch/{hdmi,dock}/state` | hwcomposer | read | — | Android switch class; not in mainline |
| PVR display class (41 `OMAPLFB*` syms + data `omap_omaplfb_device` = 42 case-insensitive `omaplfb` hits in stock kallsyms; `__initcall_OMAPLFB_Init7`) | gralloc via `PVR2DCreateFlipChain`/`PVR2DPresentFlip`/`PVRSRVSwapToDCBuffer2` → bridge 42–57 | — | — | omaplfb is part of the PVR tree but built on omapfb + dsscomp of 3.0; needs re-implementation over omapdrm |
| `/dev/ion` | **no graphics blob** (no string in any of the 14) | — | — | stock kernel's ION is the early API (`ion_share`, `ion_share_mmap`, `omap_ion_ioctl`, `omap_tiler_heap_*`); used by camera/video (libdomx), not GL |
| `/dev/tiler` | not referenced by graphics blobs | — | — | n/a for GL |
| sync / `sw_sync` | none (ICS predates Android fences) | — | — | n/a |

dsscomp command names and numbers are from the steelhead `include/video/dsscomp.h` lines 636–643. The sizes above
come from the ioctl words themselves.

HAL module headers (`HMI` decoded):

* `gralloc.omap4.so` `HMI@0x83a0`: tag `0x48574d54` ('HWMT'), module API 1.0, id `gralloc`.
* `hwcomposer.omap4.so` `HMI@0x16284`: module API 1.0, id `hwcomposer`. Its `open()` (`0x5e24`) allocates a
  1108-byte device (`malloc(0x454)` @ `0x5f00`) with tag `0x48574454` ('HWDT'). It stores `common.version = 1`
  (`stmib r4,{r7,r8}` @ `0x5f80`, r7 = 1), which is **HWC device API 0.1**, the ICS `hwc_layer_list_t` API.
  It then opens `/dev/dsscomp` and fb0 and calls `FBIOGET_FSCREENINFO` @ `0x5fb0`.

---

## 4. libhybris: state of the art (2026-10-11)

### 4.1 Upstream

* `github.com/libhybris/libhybris` master @ `7079712a42ea2754adf747e70c6cc75764c8596e` (2026-06-24, "Merge pull request #611").
  Earlier commits: `02f9f626` (2026-03-25, "Merge pull request #609 from mlehtima/a16"), so Android 16 work is active.
  It is maintained by the Sailfish (mer-hybris) and Droidian/FuriLabs communities (UNVERIFIED as to who; inferred from PR
  authors).
* README: "allows you to load drivers that link against the bionic c library inside processes whose native c library is e.g.
  glibc, musl" and "**In general Android is patched to remove TLS accesses in bionic c library which usually cause problems with glibc TLS
  slots**". It points to `mer-hybris/hybris-patches` and `halium/hybris-patches`.
* Linkers (`hybris/common/`): `jb`, `mm`, `n`, `o`, `q`, plus `stub`.
  * `common/Makefile.am` builds `jb` whenever the arch is not arm64/x86_64.
  * `mm`/`n`/`o`/`q` are built only with Android ≥ 6/7/8/10 headers.
  * `hooks.c` defaults: `LINKER_VERSION_DEFAULT 18` for `jb`. The SDK comes from `ro.build.version.sdk` or
    `HYBRIS_ANDROID_SDK_VERSION`.
  * Hook tables `hooks_mm` (sdk > 21), `hooks_n` (> 23) and `hooks_p` (> 27) override `hooks_common`. The `jb` linker is
    chosen for sdk **< 21** (`hooks.c` l.3658-3661). **ICS (SDK 15) falls into `jb` + `hooks_common` (+ `hooks_properties`,
    sdk < 27)**, which is the oldest supported path. ICS is not a separately named linker.
    Whether `jb` handles every ICS ELF quirk is UNVERIFIED, but ICS objects are plain `ET_DYN` with REL relocs and
    `DT_TEXTREL` where present.
* The `jb` linker **skips `libc.so` constructors** (`hybris/common/jb/linker.c:1650`: "HYBRIS: =============> Skipping libc.so").
  This matters because stock bionic's `.init_array[0]` = `0x16559` = `__libc_preinit`, which reads `TP+12` and writes 0 to it (§4.4).

### 4.2 softfp blobs in a hard-float process: how libhybris does it

* `hybris/include/hybris/common/floating_point_abi.h`:
  `#ifdef __ARM_PCS_VFP` / `#define FP_ATTRIB __attribute__((pcs("aapcs")))`.
* `hybris/include/hybris/common/binding.h` uses `FP_ATTRIB` 41 times, on every function-pointer type in the
  `HYBRIS_IMPLEMENT_*FUNCTION*` macros. The GLES wrappers (`hybris/glesv2/glesv2.c`, e.g. `glBlendColor(GLfloat×4)`) therefore call the
  blob with base-AAPCS convention.
* Host-side hooks that take or return floating point carry `FP_ATTRIB`, e.g. `_hybris_hook_strtod`
  (`hooks.c:2209`) and the variadic `fprintf`/`fscanf` hooks. Variadic calls are base-AAPCS on armhf anyway.
* Float math called *by* the blobs (`sinf`, `sqrtf`, `pow`, `__aeabi_f*`, …) is not hooked, so it resolves to **bionic's own softfp
  libm/libc**. That is consistent.
* So hard-float host + softfp blobs **is** what Ubuntu Touch and Sailfish (armv7hl) ran. It works only through
  libhybris's wrappers. A hard-float program can never link these blobs directly.

### 4.3 Hook coverage for this blob set

Against `hooks.c` @ `7079712a`, by name match of `HOOK_*(sym)`:

* **60 of 156 imports are hooked at SDK 15** (corrected 2026-10-11; the earlier "65" counted every table, including
  `hooks_mm`, which is only consulted for SDK > 21): `malloc`/`free`/stdio/`FILE`/`__sF`/
  `__isthreaded`, `__errno → __errno_location` (`hooks.c:3190`, in `hooks_common`), all `pthread_*` used, `open`, `getenv`,
  `strtod`, `property_get/set`, `dlopen`/`dlsym`, and others. `close`, `mmap`, `munmap`, `setlocale` and `strtol` are hooked
  **only in `hooks_mm`** (`hooks.c` l.3281-3387), so at SDK 15 they are NOT hooked.
* **96 resolve to stock bionic** inside the hybris namespace. Every one was found in the closure of §2.2
  (first-match order libc, libm, libz, libstdc++, libcrypto, libcutils, libhardware_legacy, libhardware, libEGL):
  51 in `libc.so`, 24 in `libm.so`, 6 in `libz.so`, 4 in `libstdc++.so`, 3 each in `libcrypto.so`/`libcutils.so`/
  `libhardware_legacy.so`, and 1 each in `libhardware.so`/`libEGL.so`. These include `ioctl`, `fcntl`, `syscall`,
  `read`/`write`/`poll`/`pipe`, `close`, `mmap`/`munmap`, `clock_gettime`, `sleep`, `setjmp`/`longjmp`, `qsort`, `hw_get_module`, `native_handle_*`,
  `__android_log_print` and `__stack_chk_guard`.

### 4.4 Hazards on our rootfs (musl 1.2.x, armv7, time64)

1. **bionic TLS slots vs musl TLS.**
   * musl `arch/arm/pthread_arch.h` (v1.2.5) defines `TLS_ABOVE_TP` and `GAP_ABOVE_TP 8`, so static TLS starts at `TP+8`.
   * Stock bionic `__errno` (`libc.so` `0x13020`): `mrc p15,0,r0,c13,c0,3; adds r0,#8; bx lr`, so the bionic errno lives at `TP+8`.
   * `__set_errno` (`0x262f8`) calls it with a direct `bl 13020`, not through the PLT, so the libhybris `__errno` hook cannot catch it.
     The syscall stubs reach it entirely inside `libc.so`: e.g. `__ioctl` (`0xc684`, `svc 0`, r7=54) → on error `b 0x39ae4`
     (ARM veneer `ldr ip,[pc,#4]; add ip,pc,ip; bx ip`, literal `0xfffec819` → `0x26309`) → `__set_syscall_errno`-like code at
     `0x26308` (`cmn r0,#255; negs r0; bl __set_errno`). ICS `bionic_tls.h` (tag `android-4.0.4_r2.1`): `TLS_SLOT_ERRNO 2`.
   * Every **unhooked** bionic syscall stub that fails therefore writes errno into the host's first static-TLS
     word. Examples are `ioctl` (EAGAIN/EINTR from the bridge), `fcntl` and `poll`.
   * The blob then reads the host errno via the hooked `__errno`, which is **wrong**. That breaks
     `PVRSRVBridgeCall`'s `strerror(*__errno())` path at `0xc6c0`.
   * Stock `libEGL.so` writes `TP+12` (`getGlThreadSpecific`, Thumb `mrc` at `0xb282`/`0xb28c`).
     `libGLES_android.so` also reads it (128 hits in ARM decode, 66 in Thumb decode; decode mode not separated). The IMG blobs themselves have **0** `TPIDRURO` reads (checked in ARM and Thumb decode).
   * Mitigations (UNVERIFIED, design ideas):
     * Load the vendor EGL/GLES directly (`LIBEGL=libEGL_POWERVR_SGX540_120.so`,
       `LIBGLESV2=libGLESv2_POWERVR_SGX540_120.so`). Both export the plain `egl*` names (34 EGL entry points) and 142 `gl*` names.
       This bypasses AOSP `libEGL.so`.
     * Make the host executable's first TLS object a ≥ 24-byte pad covering bionic slots 2–7.
     * Add `hybris_set_hook_callback()` hooks for `ioctl`/`fcntl`/`poll`/`read`/`write`/`syscall` so they use musl's errno.
2. **time64.**
   * pmaports' `0001-Make-libhybris-compile-with-musl.patch` (698 lines) targeted libhybris `605f294d` (`pkgver=1.0_git20200117`).
     That is before musl 1.2.0 (2020-02-20, "moves all 32-bit archs to 64-bit time_t").
   * Upstream `hooks.c` has 0 hits for `time64`/`_TIME_BITS`/`__GLIBC__`/`musl`.
   * `_hybris_hook_pthread_cond_timedwait` (`hooks.c:1057`) forwards the bionic 8-byte `timespec*` unchanged to the host. On time64
     musl that is misread.
   * The IMG blobs import only `pthread_cond_wait` (untimed), so they are not hit directly. AOSP `libutils`
     (`Condition::waitRelative`) is.
   * Bionic's own `clock_gettime` (syscall 263, 32-bit) works because `CONFIG_COMPAT_32BIT_TIME=y`.
3. **mmap.** The pmaports musl patch disables the `mmap`/`munmap` hooks ("mmap from musl considers offsets from gralloc to be
   invalid"). At SDK 15 those hooks are inactive anyway (they live in `hooks_mm`), so `hwcomposer`'s `mmap` goes to bionic.
   `libsrv_um` uses raw `syscall(192)` (bionic `syscall`, unhooked) for its mmaps.
4. **`__sigsetjmp`.** (Corrected 2026-10-11.) `hooks.c:3375` (`{"sigsetjmp", __sigsetjmp}`) sits inside an `#if 0` block of
   `hooks_mm`, so it is dead code. It does not matter: no blob imports `sigsetjmp` (`nm -D --undefined-only`, 0 hits). The blobs
   import plain `setjmp`/`longjmp`, which resolve to bionic, consistently.
5. **pvrsrvinit.** It is a bionic `ET_EXEC` that needs `/system/bin/linker`. Either run it natively with the stock ICS
   `/system/bin/linker` + `/system/lib` in a separate process (no libhybris; UNTESTED on 6.18), or have a small musl
   program `android_dlopen("libsrv_init.so")` under libhybris and call `SrvInit()` (exported `T SrvInit` @ `0x1e60`, the only real export).

### 4.5 Packaging state

* **postmarketOS:**
  * pmaports had `hybris/{libhybris, android-headers-4.4, -7.1, -9.0, hybris-base, lxc-android, drihybris,
    glamor-hybris, xf86-video-hwcomposer, pulseaudio-modules-droid, …}` until commit
    `e1a3324e5a9b2c7d61681b3acb6079530271872a` (2020-08-03, "hybris: remove … nobody is willing to put in the effort to maintain
    this properly"; closes #703/#700/#678).
  * The last APKBUILD (parent `124f740a`) was `arch="armhf aarch64"`, with Android 9.0/7.1/4.4 header variants only (no 4.0).
  * `options="!check !strip !tracedeps"`.
* **Alpine:** the package search for `*hybris*` on edge returned zero rows (2026-10-11).
* **Android headers:** libhybris builds against headers extracted with `utils/extract-headers.sh`. pmaports only ever had 4.4/7.1/9.0. An
  ICS (4.0.4) header set would need extracting from AOSP `android-4.0.4_r*`. Whether libhybris's
  `ANDROID_VERSION_*` conditionals still compile for 4.0 is UNVERIFIED.

### 4.6 What a libhybris EGL stack offers, and who used it

* EGL platforms in master: `hybris/egl/platforms/{null, fbdev, hwcomposer, wayland}` (+ `common`). The X11 platform was a
  pmaports patch.
  * `null`: offscreen pbuffers, no window system.
  * `fbdev`: `fbdev_window` uses gralloc's framebuffer HAL (`framebuffer_open`) and posts through gralloc.
  * `hwcomposer`: a window whose buffers are handed to an HWC1/HWC2 implementation by the compositor.
  * `wayland`: client side; with `--enable-wayland_serverside_buffers` (default yes) the compositor allocates gralloc
    buffers and shares `native_handle`s over the `android_wlegl` protocol.
* Compositors that used it:
  * Sailfish Lipstick, via `qt5-qpa-hwcomposer-plugin` (UNVERIFIED, from memory).
  * Ubuntu Touch Mir (android platform), later Lomiri/Mir (UNVERIFIED).
  * KWin's hwcomposer backend for Plasma Mobile. Plasma Mobile **dropped Halium support** on 2020-12-14
    (plasma-mobile.org: "we have decided to drop support for Halium devices"; "the hwcomposer backend might be broken").
* For us:
  * **fbdev platform** → gralloc.omap4 framebuffer HAL → `PVR2DCreateFlipChain`/`PVRSRVSwapToDCBuffer2` →
    bridge 42–57 → KM **omaplfb** display class → 3.0 omapfb + `dsscomp_gralloc_queue`. This is dead on mainline unless we
    write a new PVR display-class driver over omapdrm.
  * **hwcomposer platform** → `hwcomposer.omap4.so` is HWC **0.1** (ICS) and needs `/dev/dsscomp`, so it is dead on mainline. (Corrected 2026-10-11: HWC 0.1 alone would not be fatal; `mer-hybris/qt5-qpa-hwcomposer-plugin` @ `31f4f6506702` still ships `HwComposerBackend_v0`, selected for `hwc_device->version` 0.1–0.3, `hwcomposer_backend.cpp` l.142-150. The dsscomp dependency is the real blocker.)
  * **wayland platform** still needs a compositor that can scan out or compose gralloc buffers, so it reduces to the two cases above.
  * **null platform** (pbuffer/FBO, `glReadPixels`) needs only `/dev/pvrsrvkm`. This is the only one viable with a KM port and nothing else.
  * A dma-buf bridge to omapdrm does not exist in 1.8 (no `PVRSRV_BRIDGE_*DMABUF*` define in the 785978 enum).

---

## 5. Verdict

**Partly viable, and only offscreen. As a production path: not recommended.**

| Layer | Requirement for the stock-blob + libhybris path | Status |
|---|---|---|
| KM | `pvrsrvkm` speaking the **785978** bridge (81 IDs above, `0xC01C67nn`), build options `0x0036801c`, non-DRM `/dev/pvrsrvkm`, `mmap2` handle offsets | source exists (AOSP steelhead 3.0) but must be ported 3.0 → 6.18. openpvrsgx 1.8.869593 is a different ABI (+10/+9 shift) |
| Firmware | uKernel | embedded in `libsrv_init.so` (UM): no extra file |
| Loader | libhybris `jb` linker + `hooks_common` on musl armv7 | upstream alive for glibc/Android 9–16. musl support was a pmaports patch, dropped 2020; no time64 handling |
| Bionic | ~2.1 MB AOSP ICS `/system/lib` closure + 2.6 MB IMG blobs | available from the factory image; **licence**: IMG blobs are Galaxy-Nexus-only, non-commercial |
| TLS | bionic errno at `TP+8` via direct `bl __errno` | needs host-side TLS pad + extra hooks (design, untested) |
| Float ABI | softfp blobs in an armhf process | solved by libhybris `FP_ATTRIB` |
| Offscreen GLES2 | `null` platform, pbuffers/FBOs | plausible once the above holds |
| On-screen | gralloc fb HAL → omaplfb → dsscomp; or hwcomposer.omap4 → dsscomp (HWC 0.1) | **zero-copy scanout dead on mainline** without re-creating omaplfb/dsscomp (HWC 0.1 itself is consumable: qt5-qpa-hwcomposer-plugin `HwComposerBackend_v0`); offscreen + CPU copy to an omapdrm dumb buffer remains possible but slow (UNVERIFIED) |
| API level | GLES 2.0, GLSL ES 1.00, EGL 1.4 (`EGL_KHR_image`, `EGL_ANDROID_*`) | no `EGL_EXT_image_dma_buf_import`, no Mesa/GBM interop |

Value we keep from this workstream regardless:

* A **known-good, byte-exact UM/KM pair for SGX540 rev 120 on OMAP4**, with public KM source (steelhead `03a9286b`) and public UM
  (Google `imgtec-maguro-imm76d`).
* A full bridge table with call-site evidence.
* The microkernel in `libsrv_init.so`.

It is the reference to diff the primary path's KM (openpvrsgx 1.9/1.14/1.17) against, e.g. power and clock
handling (`sgx_idle_*`, `sgx_apm_latency`, `sgx_clk_mux_sel`, `omap_gpu_latency` in stock kallsyms).

---

## Open questions

1. Struct layouts of the 785978 bridge IN/OUT structs vs the heuristically resolved sizes in §3.2 (e.g. `SGX_DOKICK` 564 B,
   `SGX_DEVINITPART2` 2072 B, `GET_MISC_INFO` out 148 B). Needs `sizeof()` from the steelhead headers with the stock build
   defines. `sgx_options.h` must reproduce `0x0036801c`.
2. How much of steelhead `drivers/gpu/pvr` (785978) differs from openpvrsgx `1.8.869593` beyond the bridge numbering. A
   tree diff would tell whether "re-number the 869593 port" or "port 785978 fresh" is cheaper.
3. Whether libhybris's `jb` linker loads ICS libs cleanly, e.g. `DT_TEXTREL` in AOSP libs and `__aeabi_unwind_cpp_pr*`
   resolution. Nobody has tested this on musl since 2020. Needs an ICS header extraction (`utils/extract-headers.sh` on AOSP 4.0.4).
4. The TLS pad idea (§4.4.1): does musl place the main executable's TLS block exactly at `TP+8` with our toolchain and
   alignment, and do bionic slots 0/1 (`TP+0`/`TP+4`, musl gap) get read by any *unhooked* bionic code path the blobs reach?
5. Whether the KM for the 905891 (JB 4.1) and ED945322@2198402 (JB 4.2/4.3) Galaxy Nexus UMs is in AOSP
   `android-omap-tuna-3.0-jb-*`. Those UMs have newer GLES fixes and might pair better with a port.
6. Licence: can any of these IMG blobs legally ship in a public pmOS image for the Nexus Q (factory-image terms vs the
   imgtec "Authorized Android Enabled Device" clause)? Probably only "fetch-from-your-own-device" tooling, like our `private/` overlay.
7. libhybris's `__get_tls_hooks` hook (`hooks.c:3239`) only serves Halium-patched AOSP. Is there any non-patched-bionic
   deployment of libhybris still alive in 2026 to learn from?

## Sources

Local evidence (gitignored `reverse-eng/`):

* `reverse-eng/factory/tungsten-ian67k/system.raw.img` (debugfs dumps listed in §1)
* `reverse-eng/factory/tungsten-ian67k/boot.img` (ramdisk `init.steelhead.rc`, `ueventd.steelhead.rc`)
* `reverse-eng/vmlinux.bin` + `reverse-eng/tools/kallsyms.txt` (`SGXDevInitCompatCheck` `0xc0292f1c`, version string at file offset
  `0x678738`)

Web:

* AOSP kernel/omap, branch `android-omap-steelhead-3.0-ics-aah` @ `03a9286bb61a9acd28027206c4937990ac817f1b`:
  * https://android.googlesource.com/kernel/omap/+/refs/heads/android-omap-steelhead-3.0-ics-aah/drivers/gpu/pvr/pvrversion.h
  * https://android.googlesource.com/kernel/omap/+/refs/heads/android-omap-steelhead-3.0-ics-aah/drivers/gpu/pvr/pvr_bridge.h
  * https://android.googlesource.com/kernel/omap/+/refs/heads/android-omap-steelhead-3.0-ics-aah/drivers/gpu/pvr/sgx_bridge.h
  * https://android.googlesource.com/kernel/omap/+/refs/heads/android-omap-steelhead-3.0-ics-aah/include/video/dsscomp.h
  * branch list: https://android.googlesource.com/kernel/omap/+refs
* openpvrsgx, `letux/pvrsrvkm-1.8.869593` @ `214f07dd8fe4d9dae7f9e4e42c9472bf08756a1f`:
  `drivers/gpu/drm/pvrsgx/1.8.869593/eurasia_km/{include4/pvrversion.h, services4/include/pvr_bridge.h, services4/include/sgx_bridge.h}`
  — https://github.com/openpvrsgx-devgroup/linux_openpvrsgx (branch list via GitHub API)
* Google driver binaries: https://developers.google.com/android/drivers
  * https://dl.google.com/dl/android/aosp/imgtec-maguro-imm76d-0f59ea74.tgz
  * imgtec-maguro-iml74k-a796ffae, -jro03h-827bcb4c, -jdq39-bb3c4e4e, -jwr66y-b0a4a1ef
  * imgtec-panda-20120430-67545da7, -20130603-539d1ac3 (same URL pattern)
* libhybris master @ `7079712a42ea2754adf747e70c6cc75764c8596e`: https://github.com/libhybris/libhybris
  * `README.md`, `hybris/common/hooks.c`, `hybris/common/Makefile.am`, `hybris/common/jb/linker.c`, `hybris/configure.ac`
  * `hybris/include/hybris/common/floating_point_abi.h`, `hybris/include/hybris/common/binding.h`
  * `hybris/egl/egl.c`, `hybris/glesv2/glesv2.c`
* pmaports hybris removal: https://gitlab.postmarketos.org/postmarketOS/pmaports/-/commit/e1a3324e5a9b2c7d61681b3acb6079530271872a
  * last APKBUILD and `0001-Make-libhybris-compile-with-musl.patch` at parent `124f740af89be7fb703fce68beebf8a29ac844ee`, path `hybris/libhybris/`
* pmaports issue "too little usecases for Halium in pmOS" (#703): https://gitlab.com/postmarketOS/pmaports/-/work_items/703
* mer-hybris "Regression test for EGL-glibc TLS conflict": https://github.com/mer-hybris/libhybris/pull/5/files
* musl: https://musl.libc.org/releases.html (1.2.0, 2020-02-20, 64-bit `time_t`; latest 1.2.6, 2026-03-20)
  * https://git.musl-libc.org/cgit/musl/plain/arch/arm/pthread_arch.h?h=v1.2.5
  * https://git.musl-libc.org/cgit/musl/plain/src/signal/arm/sigsetjmp.s?h=v1.2.5
* Plasma Mobile dropping Halium (2020-12-14): https://plasma-mobile.org/2020/12/14/plasma-mobile-technical-debt/
* Phoronix on the same: https://www.phoronix.com/news/Plasma-Mobile-Drops-Halium
* "1.8@785978" in other OMAP4/S5PV210 Android ports (context only):
  * https://github.com/fat-tire/android_device_bn_encore/wiki
  * https://groups.google.com/g/android-porting/c/0ulSrWG3uSA
  * https://xdaforums.com/t/kernel-build-galaxy-tab-2-jb-kernel-from-source.1859227/
* Prior note: `docs/2026-06-19-gpu-sgx540-acceleration-research.md` (repo)

## Verification (2026-10-11)

Adversarial re-check of the 19 key claims. Every blob was re-extracted fresh from
`reverse-eng/factory/tungsten-ian67k/system.raw.img` with `debugfs -R dump` into `re/verify02/fresh/` (all 18 SHA-256 in §1
reproduced). Downloads were re-fetched into new `re-downloads/verify02-*` directories and only read
(readelf/objdump/nm/strings, `python3 -I` from outside). Nothing was executed from them.

| # | Claim | Verdict | Evidence of the re-check |
|---|---|---|---|
| 1 | Stock UM and KM are 1.8@785978 with matching constants | **confirmed** | `objdump` of `libsrv_um.so` `0x9e9c`: `ldr r5,[pc]` → `0x9fb4`=`0x0036801c`, `0x9fc8`=`0x00010812`, `0x9fcc`=`0x000bfe3a`; DDK mismatch → `mov r4,#25`, build mismatch → `#26` (error-string order puts `DDK_VERSION_MISMATCH` 25th, `BUILD_MISMATCH` 26th after `PVRSRV_OK`). `vmlinux.bin` (VA base `0xc0008000`): `movw/movt` at `0xc0292f58/5c`, `0xc0292f7c/80` (`0x36801c`), `0xc0292ff4/f8` (`0x10812`), `0xc0293010/18`, `0xc0293028/2c` (`0xbfe3a`); string at file `0x678738` exact; `SGXDevInitCompatCheck` = `c0292f1c` in kallsyms. GLESv2 `0x50472` "OpenGL ES 2.0 build 1.8@785978". |
| 2 | 13 IMG blobs byte-identical to `imgtec-maguro-imm76d-0f59ea74.tgz` | **confirmed** | tgz sha256 `ec126717…a1174`; `tail -n +269` (the script itself says `tail -n +269 $0 \| tar zxv` at line 256) piped to `tar`, never executed; `cmp` 13/13 equal; `device-maguro.mk` l.20-31 install to `system/vendor/...`. |
| 3 | Exact matching KM source public at steelhead `03a9286bb61a` | **partly** (downgrade to *likely*) | `git`/gitiles JSON: branch tip `03a9286bb61a9acd28027206c4937990ac817f1b`, Mike J. Chen, 2012-06-11; re-fetched `pvrversion.h`/`pvr_bridge.h`/`sgx_bridge.h` are byte-identical to the report's copies, `PVRVERSION_BUILD 785978`. But the stock kernel banner is `Linux version 3.0.8-gad584da … Fri Jun 29 15:12:17 PDT 2012`, and gitiles returns NOT_FOUND for `ad584da` in `kernel/omap`. Same PVR revision, not provably the same source. |
| 4 | 81 distinct bridge ioctls via one wrapper, `0xC01C6700\|n`, all mapped | **confirmed** (one wording fix) | Own resolver (`re/verify02/ids.py`): 87 `bl c674` sites, 87/87 resolved, 81 distinct, all `0xC01C67nn`; the set is identical to the §3.2 table. Re-derived the enum by hand from steelhead `pvr_bridge.h`/`sgx_bridge.h`: CORE 0-30 … SYNC 74-83, SGX base 85; DOKICK 88, DEVINITPART2 101, READ_HWPERF_CB 115. Package layout `pvr_bridge.h` l.235-249 matches the stores at `sp+12..36`. Fix: the wrapper takes **6** arguments, not 7. |
| 5 | openpvrsgx 1.8.869593 not ABI-compatible (+10/+9) | **confirmed** | `git ls-remote`: `letux/pvrsrvkm-1.8.869593` = `214f07dd8fe4…` (still the tip, and the only 1.8 branch). Raw files at that commit: `CORE_CMD_LAST (FIRST+40)` with `REMAP_TO_DEV`/`UNMAP_FROM_DEV`/`MULTI_MANAGE_DEV_MEM`/`RESERVED_1..7`, no `GETMMU_PD_DEVPADDR`; `PVRVERSION_BUILD 869593`. That gives GET_MISC_INFO 48, INITSRV 78 (+9), SGX base 94 → DOKICK 97, DEVINITPART2 110. |
| 6 | All blobs softfp, GCC 4.4.3, no SONAME, RPATH, linker interp | **confirmed** | `readelf -A`: `Tag_ABI_VFP_args` absent in all 17 checked (13 IMG + hwcomposer + libc/libEGL/libGLES_android); flags `0x5000002`/`0x5000000`; `.comment` "GCC: (GNU) 4.4.3"; IMG blobs: 0 SONAME, `RPATH [/system/lib]`, 0 TEXTREL; hwcomposer/libEGL/libGLES_android/libc have TEXTREL; `pvrsrvinit` `ET_EXEC`, entry `0x8410`, `PT_INTERP /system/bin/linker`, imports `__libc_init`/`PVRSRVDebugPrintf`/`SrvInit`. |
| 7 | bionic-only imports; only a bionic linker such as libhybris can load them | **confirmed, conclusion narrowed** | `nm -D --undefined-only`: `__errno` (libsrv_um, hwcomposer), `__isthreaded`/`__srget` (libsrv_um), `__sF` (hwcomposer), `__assert2` (GLESv1, libusc), `__page_size` (gralloc), `__libc_init` (pvrsrvinit). ICS bionic `pthread.h` (tag `android-4.0.4_r2.1`): mutex/cond = `int volatile value` (4 B). Overreach fixed: the stock `/system/bin/linker` (39660 B in the image) can also run them in a separate bionic process. |
| 8 | No `/dev/ion`; kernel interfaces and ioctl numbers | **confirmed** | libsrv_um `0x2285c` `/dev/pvrsrvkm`; `syscall(192, …, 3, 1, fd, pgoff)` at `0xd1b8` (mmap2), `syscall(265, 1, 0, …)` at `0xbb38` (clock_nanosleep); gralloc `mov r1,#0x4600` + `ioctl` at `0x1cc4`; hwcomposer movw/movt pairs give `0x427C4F85` (`0x40ac`), `0xC06C4F83` (`0x43d4`, `0x538c`, `0x60f4`), `0x403C4F86` (`0x49dc`), `0x40044620` (`0x4120`), `0x4611`, `0x4602` (`0x5fb0`); 11 `ioctl@plt` sites. These equal `_IOWR('O',131,108)`, `_IOW('O',133,636)`, `_IOW('O',134,60)` with `dsscomp.h` l.636-643. |
| 9 | Display path needs omaplfb on omapfb + dsscomp | **confirmed** (upgrade to *verified*) | gralloc imports `PVR2DCreateFlipChain`/`PVR2DPresentFlip`/`PVRSRVSwapToDCBuffer2`. Stock omaplfb calls `dsscomp_gralloc_queue` (`c024e188`) from `0xc0299500`, `0xc0299a44`, `0xc029ad18`. Count fix: 41 `OMAPLFB*` symbols + `omap_omaplfb_device` = 42. |
| 10 | hwcomposer is HWC 0.1, which libhybris's hwcomposer platform does not support | **partly wrong** | First half confirmed: `open()` `0x5e24`: `movw r0,#0x454` → `malloc`; tag `0x48574454` stored at `[r4]`; `mov r7,#1` @ `0x5f64`, `stmib r4,{r7,r8}` @ `0x5f80`; `HMI` @ `0x16284` = tag `0x48574d54`, version 1.0. Second half wrong: `mer-hybris/qt5-qpa-hwcomposer-plugin` @ `31f4f6506702` (2026-08-13) has `hwcomposer_backend_v0.cpp`, chosen for device version 0.1/0.2/0.3 (`hwcomposer_backend.cpp` l.142-158). HWC 0.1 is consumable; `/dev/dsscomp` is the actual blocker. |
| 11 | libhybris master `7079712a`, jb on 32-bit ARM, SDK ≤ 22 → jb + hooks_common; jb skips libc ctors | **partly** (threshold wrong) | `git ls-remote` master = `7079712a42ea…`; `Makefile.am` adds `jb` unless ARM64/X86_64; `jb/linker.c` l.1651 "Skipping libc.so". But jb is selected for **sdk < 21** (`hooks.c` l.3658-3661), and `hooks_mm` is consulted for sdk > 21. ICS 15 → jb + `hooks_common` + `hooks_properties`. Stock libc `.init_array[0]` = `0x16559` = `__libc_preinit` (reads/clears `TP+12`, calls `__libc_init_common`) confirmed. |
| 12 | `FP_ATTRIB = pcs("aapcs")` makes softfp callable | **confirmed** | `floating_point_abi.h`: `#ifdef __ARM_PCS_VFP` → `__attribute__((pcs("aapcs")))`; `binding.h` 41 occurrences; `hooks.c:2209` `FP_ATTRIB … _hybris_hook_strtod`. |
| 13 | pmOS hybris removal, musl patch base predates time64, no time64 handling | **confirmed** | GitLab API: `e1a3324e…` 2020-08-03, "hybris: remove … nobody is willing to put in the effort to maintain this properly", closes #703/#700/#678, parent `124f740a…`; `APKBUILD` `_commit=605f294d…`, `pkgver=1.0_git20200117`, `arch="armhf aarch64"`, headers 9.0/7.1/4.4; musl patch 698 lines, mmap comment at l.238; musl.libc.org: 1.2.0 on February 20, 2020, "moves all 32-bit archs to 64-bit time_t"; `hooks.c` 0 hits for time64/_TIME_BITS/musl; `_hybris_hook_pthread_cond_timedwait` (l.1057) ends `return pthread_cond_timedwait(realcond, realmutex, abstime);`. No IMG blob imports `pthread_cond_timedwait`. Alpine edge `*hybris*`: 0 rows on armv7/armhf/aarch64. |
| 14 | ICS `__errno` = TP+8, `__set_errno` direct, musl GAP_ABOVE_TP 8 | **confirmed** | `libc.so` `0x13020`: `mrc p15,0,r0,c13,c0,3; adds r0,#8; bx lr`; `0x262fc`: `bl 13020`; full error path traced (see §4.4.1). musl v1.2.5 `arch/arm/pthread_arch.h`: `TLS_ABOVE_TP`, `GAP_ABOVE_TP 8`. ioctl/fcntl/poll/syscall/read/write absent from all hook tables. |
| 15 | IMG blobs never read TPIDRURO; vendor EGL/GLES export plain names | **confirmed** | `mrc 15,0,*,cr13,cr0,{3}` in default, forced-ARM and forced-Thumb objdump, plus a raw byte-pattern scan: 0 hits in all 13 IMG blobs and in hwcomposer; libEGL 66, libGLES_android 128 (mapped decode). `nm -D`: libEGL_POWERVR 34 `egl*` (all core EGL 1.4, forwarding to `IMGegl*`), GLESv2 142 `gl*`, GLESv1 145 `gl*`. |
| 16 | uKernel in libsrv_init `.rodata`, DEVINITPART2 in 2072 B, SrvInit only export | **confirmed** | `readelf -S`: `.rodata` size `0x194a8` (103,592 B); `SetupuKernel …` strings `0x1ad6c`-`0x1afaa`, "SGX ukernel" `0x1b03b`; only `T SrvInit` @ `0x1e60`; libsrv_um `SGXDevInitPart2` call: `ldr r1` = `0xC01C6765`, `movw r3,#2072`, out size 8 (`0xafdc`-`0xaff8`). That the bulk of `.rodata` is uKernel code remains *likely*. |
| 17 | ~2.1 MB AOSP closure + ~2.6 MB blobs; all unhooked imports resolve | **confirmed with corrections** | `debugfs stat` sizes sum 2,123,384 B (AOSP). The IMG+TI sum is **2,530,412 B (~2.5 MB)**, not 2.6. With SDK-15 hook tables there are **96** unhooked imports (not 91); all 96 resolve (libc 51, libm 24, libz 6, libstdc++ 4, libcutils 3, libcrypto 3, libhardware_legacy 3, libhardware 1, libEGL 1). |
| 18 | Licence: Authorized Device only, non-commercial | **confirmed + addition** | Extractor l.40-41 and §2.a "non-commercial use on an Authorized Android Enabled Device". Added: §3.b(i) also withholds the right to "disassemble, decompile, reverse engineer". The legal reach of that is UNVERIFIED. |
| 19 | Other public OMAP4 UMs: 905891, ED945322@2198402 | **confirmed** | `strings` on the GLESv2 in each downloaded package: iml74k/panda-20120430 `1.8@785978`; jro03h/panda-20130603 `1.8@905891`; jdq39/jwr66y `1.8.GOOGLENEXUS.ED945322@2198402`. |
| V | Verdict | **holds, softened** | Not recommended as the primary path still stands. Corrected: (a) HWC 0.1 is not a libhybris dead end; dsscomp is. (b) "only libhybris" ignores a separate native-bionic process. (c) "on-screen dead" applies to zero-copy scanout; an offscreen + CPU-copy path is not excluded. |

Other spot checks confirmed: `build.prop` (`sdk=15`, `4.0.4`, `IAN67K`, `ro.opengles.version=131072`); `/system/lib/hw` has `gralloc.default.so` 10260 B and no omap4 gralloc/hwc. The ramdisk re-extracted from `boot.img` (`ANDROID!` header, gzip, cpio) has an `init.steelhead.rc` byte-identical to the report's (`sha256 79153010…`; l.32 `chmod 0666 /dev/pvrsrvkm`, l.56 `chmod 0777 /dev/ion`, l.89 `service pvrsrvinit`) and `ueventd.steelhead.rc` l.2-3. Also confirmed: `CONFIG_COMPAT_32BIT_TIME=y` at `kernel/configs/steelhead_defconfig:662`; Plasma Mobile 2020-12-14 post quoting "drop support for Halium devices"; musl 1.2.6 on March 20, 2026; `libsrv_um` `fcntl(fd, 2, 1)` at `0xcbdc` (report said `0xcbd4`, the `mov r1,#2`).

Not re-checked: whether the ~103 KB of `libsrv_init` `.rodata` is uKernel code rather than tables; the Halium/Ubuntu Touch history in §4.6 (still marked UNVERIFIED); whether ICS bionic and `/system/bin/linker` actually run on a 6.18 kernel.

New risk found: `jb` skips all `libc.so` constructors, so `__libc_init_common` and `malloc_debug_init` (called from `__libc_preinit` @ `0x16558`) never run. The 96 unhooked bionic functions therefore run against a bionic libc whose globals were never initialised. Impact is UNVERIFIED.
