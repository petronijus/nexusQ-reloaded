# Session findings — 2026-06-28

Full-rootfs image hardening: zram swap, user namespaces, a dual-core re-confirm
on the live device, a CPU power/thermal health pass — and a hard, still-**open**
ARMv7 python SIGSEGV run to ground (now narrowed from "miscompile" to a CPython
source-level init bug — see §4). Several long-standing doc claims turned out
to be stale and are corrected here (GCC-13.3-only, SMP "groundwork", idle settling
at 350 MHz). Diag capture: `nq-captures/20260628-124159/` (verdict CRIT — driven
by the dark-but-responsive LED ring + the failed python unit, **not** a true hang).

---

## 1. Landed + VERIFIED on device (real wins)

### 1.1 zram swap works
- Kernel: `CONFIG_ZRAM=m` (defconfig). The mainline 6.12 ZRAM module here only
  carries the **lzo / lzo-rle** backend, not zstd.
- Device: `deviceinfo_zram_swap_algo="lzo-rle"`. postmarketos-zram-swap's
  `zramstart` otherwise defaults to **zstd**, which the kernel rejects:
  `zramctl: failed to set algorithm: Invalid argument`, and swap never comes up.
  lzo-rle is also the right pick for this slow Cortex-A9 (CPU-cheap).
- Verified live: `/dev/zram0` = lzo-rle, **1.4 G**, active `[SWAP]`;
  `postmarketos-zram-swap.service` active.
- `pmos/linux-google-steelhead/APKBUILD` pkgrel **23 → 24**.

### 1.2 User namespaces enabled
- `CONFIG_USER_NS=y` (was `# CONFIG_USER_NS is not set`).
- Verified live: `max_user_namespaces=7716`; `unshare --user` works.

### 1.3 SMP — BOTH cores online (re-confirmed on the full-rootfs image)
- `nproc=2`, `/sys/devices/system/cpu/online = 0-1`, `cpu1/online = 1`, two
  Cortex-A9 in `/proc/cpuinfo`.
- This **re-confirms** dual-core (first shipped in v1.2.0, patch `0009` SEV +
  `cpuidle.off=1`) on the current image, and **corrects** any lingering "CPU1 not
  brought up / SMP is groundwork" framing — SMP second-core bring-up is **done and
  working** here, not pending. See `docs/SMP-second-core.md`.

### 1.4 CPU freq + power + thermal health confirmed
- Scales **350 / 700 / 920 / 1200 MHz**; reaches **1.2 GHz** under load.
- VDD_MPU tracks the OPP exactly: 1200→**1380 mV**, 920→**1317 mV**, 350→**1025 mV**;
  `abb_mpu` FBB @ Nitro = **1375 mV**. Matches the stock open-loop table
  (`docs/2026-06-25-cpufreq-vdd-mpu-findings.md`).
- Governor **`conservative`** (v1.5.0 default).
- Thermal: idle ~**70 °C**, peak **95 °C** under sustained 2-core load (100 °C
  passive trip — not reached, **no throttle** observed).

**Correction (idle frequency).** The v1.5.0 CHANGELOG says the `conservative`
governor makes idle "settle at 350 MHz". On the live device idle actually hovers
**~920 MHz** — `nexusqd`'s LED-ring polling keeps the CPU busy enough that the
governor holds a high clock, dipping to 350 MHz only briefly. (Was "settles at
350 MHz", now "hovers ~920 MHz, 350 only briefly" as of 2026-06-28.)

**Diagnostic gap.** `CONFIG_CPU_FREQ_STAT` is **not** enabled — there is no
`cpufreq/stats/time_in_state`, so the diag tooling must build OPP residency by
sampling `scaling_cur_freq` over time. Candidate to enable for cheap residency
accounting.

---

## 2. GCC correction — the shipping kernel is built with GCC 15.2.0

`/proc/version` on the booted device:
`cc (Alpine 15.2.0) 15.2.0`. The kernel boots and runs fine.

This **contradicts** the old "Arm GNU Toolchain 13.3.Rel1 only / GCC 15.x kernels
do not boot (black screen)" finding (HANDOFF.md 2026-06-10, INSTALL.md, PLAN.md,
nexusq-boot-constraints memory). That conclusion was about an **out-of-tree, hand
cross-compiled** kernel early in the port; the **current in-tree pmbootstrap build
compiles with Alpine's GCC 15.2 and the result boots**. The 13.3-only constraint
is **stale** for this build path. (Evidence preserved; claim marked superseded —
not deleted.)

---

## 3. Build-infra changes (uncommitted, in tree)

### 3.1 New local override aport `pmos/python3/`
Alpine's stock **python3-3.14.5-r2 is broken on armv7** (see §4). The override is
the SAME version rebuilt (started **r3**, now **r4**) so its higher pkgrel
supersedes Alpine's -r2 in the rootfs:
- drops `--with-lto` and `--enable-optimizations` (PGO); r4 additionally builds the
  interpreter core at `-O0` (`CFLAGS_NODIST`). NB: §4.4 since proved the crash is
  **independent of optimization level**, so `-O0` is now just the current
  experiment state, not the fix — keeps `--with-computed-gotos`;
- removes the `!gettext-dev` makedepends token — abuild understands `!pkg`, but
  pmbootstrap pre-installs makedepends with its own apk wrapper which rejects any
  `!`-prefixed entry (`packages with '!' are not supported!`). It is a no-op guard
  here (nothing in the closure pulls gettext-dev; `musl-libintl` is explicit).
- ships 4 vendored Alpine companion files (`idle.desktop`, `externally-managed`,
  `musl-find_library.patch`, `s390x-c-stack-size.patch`).
- `options="net !check"` — the upstream test suite is too slow / hangs under qemu;
  correctness is gated on `python3 -S -c ''` (rc 0) instead. **NB: that qemu gate
  gives a FALSE PASS for this bug — see §4.**

### 3.2 `docker-build.sh` — stage + build the override
- **Phase 6** stages `pmos/python3/*` → `$PMAPORTS/main/python3` (+ dos2unix),
  mirroring the nexusqd Phase 6 pattern.
- New **Phase 7d** builds it: `pmbootstrap --no-cross build python3 --arch armv7`
  (full CPython compile under qemu; `--no-cross` because crossdirect cannot exec
  `cc1` in this image — same reason as the nexusqd Phase 7c). With PGO dropped it
  no longer runs the miscompiled instrumented interpreter mid-build, so it
  completes; the r4 apk is exported and is meant to supersede Alpine's r2 at rootfs
  assembly. **But §4.6 found the rootfs ships a DIFFERENT r4 than the exported apk**
  — the export/install pipeline still needs reconciling and md5-verifying.

### 3.3 `device-google-steelhead/APKBUILD` pkgrel 6 → 10 — un-mask + add debug tools
The earlier `sleep-inhibitor.service` → `/dev/null` **mask was REMOVED** (r9): we
fix the root cause (python) instead of masking the symptom. r10 additionally adds
**`gdb` (16.3)** + **`python3-dbg`** to the device image to debug the crash on
hardware. ⚠️ gdb itself links `libpython`, so **gdb only works once python is fixed**
— on the current image it SIGSEGVs on launch for the same reason. (The bump also
picks up the deviceinfo zram algo + the un-mask.)

---

## 4. OPEN problem (NOT fixed) — python3-3.14.5 SIGSEGVs on real ARMv7

> **Status: OPEN / in progress.** Do not treat python as working. Neither override
> **r3** (LTO/PGO dropped) nor **r4** (-O0) fixes it on hardware. As of late
> 2026-06-28 the crash is understood to be a **CPython 3.14 source-level
> use-before-init / garbage-pointer read**, NOT a compiler problem. A focused
> investigation is running to pinpoint the exact init ordering and find the upstream
> fix (candidate: 3.14.6).

### 4.1 Symptom
Alpine **python3-3.14.5 SIGSEGVs deterministically on real ARMv7** (Cortex-A9):
even `python3 -S -c ''` returns **rc 139**, before any user bytecode, during
`Py_Initialize`. It crashes `onboard`, `blueman-applet`, `sleep-inhibitor.service`
— and now `gdb` too (gdb links `libpython`, see §5.3).

### 4.2 qemu-user gives a FALSE PASS — on-device is the only authority
The override **r3** PASSED the qemu-user gate (`pmbootstrap chroot`
`python3 -S -c ''` rc 0) but still SIGSEGVs on the device. The faulting deref
(§4.5) lands on a garbage address that **qemu-user happens to keep mapped** while
the real device does **not** — so qemu silently "passes".

> **LESSON: never gate armv7 python (or any pointer/atomic-sensitive native code)
> on the qemu chroot alone. Always validate `python3 -S -c ''` ON THE DEVICE.**

### 4.3 Hypotheses DISPROVEN (recorded so they are not re-tread)
Earlier revisions of this note and the `pmos/python3/APKBUILD` header blamed, in
turn, LTO/PGO → LDREXD misalignment → a GCC `-O2` codegen bug. **All four are now
disproven, with evidence:**
1. **NOT LTO/PGO** — r3 dropped both; still crashes.
2. **NOT LDREXD misalignment** — the coredump shows the faulting address is
   **8-byte aligned but UNMAPPED** → **SIGSEGV, not SIGBUS**. The fault is the bad
   *address*, not its alignment.
3. **NOT the gnu2/TLSDESC TLS dialect** — the binary uses traditional TLS
   (`__tls_get_addr`, **zero** `R_ARM_TLS_DESC` relocs).
4. **NOT a GCC `-O2` codegen bug, and NOT an optimization-level issue at all** —
   killed outright by the decisive finding next.

### 4.4 DECISIVE finding — the crash is data/layout-dependent, not code-dependent
Two builds of the **same source at the same flags** (`-O0`, pkgrel **r4**) behave
**differently on the same device**: one runs `python3 -S -c ''` clean **6/6**, the
other SIGSEGVs **6/6**. Their **`.text` (machine code) sections are byte-for-byte
identical** — **3,528,976 bytes, `cmp` equal** — they differ **only** in ~**139 KB
of DATA sections**. Identical code, different data, opposite outcome ⇒ the crash is
**layout/data-dependent, not codegen-dependent**, and therefore **independent of
optimization level**. This retires the "compiler miscompiled the eval loop / -O2
codegen bug" framing for good.

### 4.5 Root-cause understanding (current)
During `Py_Initialize`, `_PyStaticType_InitBuiltin` /
`managed_static_type_state_init` reads a **garbage type-index**:
`interp->types.builtins.num_initialized` comes back as **`0xf0012b00`**, far
outside the valid `0..~tens` range. It then indexes
`_PyRuntime.types.managed_static.types[idx].interp_count` and issues a 64-bit
`LDREXD` against that wild address. The deref faults **only where the garbage
address is unmapped** (real hardware); qemu-user keeps it mapped, hence the false
pass. This is a **CPython 3.14 source-level uninitialized / use-before-init /
wrong-pointer read** (CPython, or CPython × musl) — **not** a compiler-flag issue.
The fix must come from **source / upstream** (candidate: 3.14.6), not a `-O`/`-f`
flag. **OPEN** — a focused investigation is pinning down the exact init ordering /
struct member and the upstream fix.

(Was framed earlier in this same note as an "LDREXD 8-byte-alignment fault", then as
a "GCC-15.2 `-O2` codegen bug"; both superseded 2026-06-28 by the
byte-identical-`.text` experiment in §4.4.)

### 4.6 BUILD-PIPELINE bug — the rootfs python ≠ the verified apk
Separate from the crash itself: the build shipped the **wrong** python.
- the **rootfs** ended up with a `python3-3.14.5-r4` whose `libpython` md5 is
  **`30e88d28…`** — the **crashing** one;
- while the apk **Phase 7d built and exported** to `output/` for verification has
  md5 **`d43b6509…`** — a **running** one.

So `docker-build.sh` builds/exports one python3 apk in Phase 7d but the **Phase 9
rootfs install pulls a different r4 build**. The build's verification only checked
the apk DB **version** (`python3-3.14.5-r4` present) — **not** the libpython md5 —
so it green-lit a rootfs whose python differs from the verified/exported apk.
**Action items (both OPEN, under investigation):**
1. Byte-verify the rootfs `libpython` (md5/sha) against the **exported** apk, not
   just the version string.
2. Determine **why two r4 builds exist** / why Phase 9 does not install the exact
   Phase 7d apk.

---

## 5. Still-open known issues (carried forward)

### 5.1 Ethernet still DOWN
No `eth0` netdev. `smsc95xx` registers but the LAN9500A never enumerates — the
known **v1.4.0 cpufreq boot-timing regression** (CHANGELOG 1.4.0 / task #17),
unchanged this session. WiFi + the USB gadget remain the links.

### 5.2 LED ring dark but nexusqd RESPONSIVE — NOT a hang
The ring is dark all-window, **but** `nexusqd` answers its control socket
(`nq_resp=1`, no socket hang). This is **NOT** the classic nexusqd dead-socket
hang (`nexusqd_hang`) — it is most likely **idle-off** (the ring blanks after the
idle timeout). A dark ring with a **responsive** socket must not be reported as a
hang. The diag report.json verdict was **CRIT** only because the dark-but-
responsive ring + the failed python unit tripped the heuristics, not because the
daemon wedged.

### 5.3 Currently-flashed image ships the CRASHING python; WiFi creds wiped by flash
- The image **on the device right now** carries the **crashing** python (`libpython`
  md5 `30e88d28`), so `onboard` / `blueman-applet` / `sleep-inhibitor.service` /
  `gdb` are all down (gdb via the libpython link). Working on this device regardless:
  **SMP dual-core**, **cpufreq to 1.2 GHz** with correct VDD_MPU, **BT** (BCM4330
  patchram), the **WiFi radio** (firmware OK), **zram** (lzo-rle), **USER_NS**.
- **WiFi is unconfigured after a clean flash.** The radio + firmware are fine, but
  WiFi creds added **live** are **wiped by the next reflash** (access config lives in
  the rootfs). To persist them they must go in a **PRIVATE overlay** — the PSK is a
  secret, **never** the public repo. See `private/README.md`.

---

## 6. Files touched this session (code, for reference)
- `kernel/configs/steelhead_defconfig` — `CONFIG_ZRAM=m`, `CONFIG_USER_NS=y`.
- `pmos/linux-google-steelhead/APKBUILD` — pkgrel 23 → 24.
- `pmos/device-google-steelhead/deviceinfo` — `deviceinfo_zram_swap_algo="lzo-rle"`.
- `pmos/device-google-steelhead/APKBUILD` — pkgrel 6 → 10 (sleep-inhibitor mask
  removed; +gdb +python3-dbg for on-device debugging).
- `pmos/python3/` — new override aport (APKBUILD now r4 + 4 companion files).
- `docker-build.sh` — Phase 6 stage python3 + Phase 7d build python3.
