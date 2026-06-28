# Session findings — 2026-06-28

Full-rootfs image hardening: zram swap, user namespaces, a dual-core re-confirm
on the live device, a CPU power/thermal health pass — and the hard ARMv7 python
SIGSEGV **finally root-caused AND fixed** (see §4). The breakthrough: it is **not**
a compiler or CPython-source bug at all but a **build-time qemu-user corruption** —
qemu's mmap zero-fill of the linker's output non-deterministically leaves garbage in
libpython's should-be-zero regions; **fixed** by linking with gold
(`-Wl,--no-mmap-output-file`) plus a deterministic build-integrity gate, and
**hardware-verified** on the live device. (This supersedes the earlier same-session
"CPython source-level init bug / OPEN" theory below — that framing was wrong about
the *cause*; the disproven-hypotheses record stands.) Several long-standing doc
claims also turned out stale and are corrected here (GCC-13.3-only, SMP "groundwork",
idle settling at 350 MHz). Diag capture: `nq-captures/20260628-124159/` (verdict
CRIT — driven by the dark-but-responsive LED ring + the then-failed python unit,
**not** a true hang).

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
the SAME version rebuilt (started **r3**, now **r5** — the working fix) so its
higher pkgrel supersedes Alpine's -r2 in the rootfs:
- drops `--with-lto` and `--enable-optimizations` (PGO) and keeps
  `--with-computed-gotos`; r5 **reverts the r4 `-O0` experiment back to stock
  `-O2`** — §4 proved codegen was never the cause.
- **THE FIX (r5): links libpython with gold** — `binutils-gold` added to
  makedepends, `-fuse-ld=gold -Wl,--no-mmap-output-file` added to `LDFLAGS_NODIST`.
  gold `write()`s its output file instead of `mmap()`-ing it, so qemu-user never
  gets to mis-zero-fill it and the should-be-zero regions come out actually zero
  (see §4.5/§4.7). The gold flags are deliberately kept **out of the propagated
  (DIST) LDFLAGS**, so they are not baked into `sysconfig` — on-device pip extension
  builds keep using the stock linker.
- removes the `!gettext-dev` makedepends token — abuild understands `!pkg`, but
  pmbootstrap pre-installs makedepends with its own apk wrapper which rejects any
  `!`-prefixed entry (`packages with '!' are not supported!`). It is a no-op guard
  here (nothing in the closure pulls gettext-dev; `musl-libintl` is explicit).
- ships 4 vendored Alpine companion files (`idle.desktop`, `externally-managed`,
  `musl-find_library.patch`, `s390x-c-stack-size.patch`).
- `options="net !check"` — the upstream test suite is too slow / hangs under qemu;
  correctness is gated on `python3 -S -c ''` (rc 0) instead. **NB: that qemu gate
  gives a FALSE PASS for this bug — see §4.2.** The authoritative build gate is now
  `scripts/verify-libpython-clean.py` (§4.7), which is deterministic and does not
  rely on running the binary under qemu at all.

### 3.2 `docker-build.sh` — stage, gate-build, and ship-gate the override
- **Phase 6** stages `pmos/python3/*` → `$PMAPORTS/main/python3` (+ dos2unix),
  mirroring the nexusqd Phase 6 pattern.
- **Phase 7d** now builds it in a **GATE + RETRY loop**:
  `pmbootstrap --no-cross build python3 --arch armv7 --force`, then extract the
  freshly-built `libpython3.14.so.1.0` from the apk and run it through
  `scripts/verify-libpython-clean.py` (§4.7). On any residual corruption it discards
  the apk and rebuilds (up to 4×, re-rolling the qemu mmap coin-flip via `--force`);
  if it never comes out clean it **ABORTS the build**. (`--no-cross` because
  crossdirect cannot exec `cc1` in this image — same reason as the nexusqd Phase 7c.)
- The apk is selected by its **exact `pkgver-pkgrel` filename** (`python3-3.14.5-r5`),
  not a bare `r*.apk` glob — this FIXES the §4.6 stale-artifact bug where the
  persistent work-volume repo's older apks (r3/r4) could be gated/exported instead of
  the one just built.
- **Phase 10 SHIP GATE:** before emitting a flashable image, the gate is re-run on
  the **actually-installed** rootfs `libpython` (not just the Phase 7d apk). If that
  is corrupt the build refuses to produce an image — implementing the
  "integrity-verify-before-flash" lesson and closing the §4.6 hole for good.
- An opt-in `PYTHON3_VALIDATE_RUNS=N` harness forces N independent gold rebuilds +
  gates each, to prove gold reliably defeats the coin-flip (used this session, §4.8).

### 3.3 `device-google-steelhead/APKBUILD` pkgrel 6 → 10 — un-mask + add debug tools
The earlier `sleep-inhibitor.service` → `/dev/null` **mask was REMOVED** (r9): we
fix the root cause (python) instead of masking the symptom — and the root cause is
now actually fixed (§4). r10 additionally adds **`gdb` (16.3)** + **`python3-dbg`**
to the device image (used this session to coredump-debug the crash on hardware).
gdb itself links `libpython`, so it SIGSEGVed for the same reason on the broken-python
image; with the gold r5 python it links a clean libpython and works. (The bump also
picks up the deviceinfo zram algo + the un-mask.)

---

## 4. ROOT-CAUSED + FIXED — python3-3.14.5 SIGSEGV on real ARMv7 was a qemu build-time corruption

> **Status: ROOT-CAUSED and FIXED, hardware-verified (2026-06-28).** The crash is
> **not** a compiler or CPython-source bug. The armv7 toolchain runs under
> **qemu-user** (`pmbootstrap --no-cross`) and qemu's **mmap zero-fill of the
> LINKER's output file is buggy**: it non-deterministically (≈50 % per build — a
> coin-flip) leaves stale garbage in regions the C standard guarantees are zero,
> specifically libpython's `.PyRuntime` (which holds `_PyRuntime`) and
> `.data.rel.ro`. That garbage lands on `interp->types.builtins.num_initialized`, so
> the wild type-index deref in `Py_Initialize` (§4.5) is just the *symptom*. **Fixed**
> by linking libpython with **gold + `-Wl,--no-mmap-output-file`** (§4.7) — gold
> `write()`s its output instead of `mmap()`-ing it, so qemu never mis-zero-fills it —
> backed by a deterministic build-integrity gate (§4.7) + a Phase-10 ship gate, and
> **hardware-verified on the live device** (§4.8). Affects **any** qemu-built armv7
> binary, not just python (nexusqd etc. are theoretically at risk).
>
> _(The §4 sub-sections below were written across the session as the cause was
> narrowed. The earlier "CPython 3.14 source-level use-before-init bug / fix from
> upstream 3.14.6" interpretation in §4.5 was **wrong about the cause** and is
> superseded by §4.5'/§4.7; the symptom description and the §4.3 disproven-hypotheses
> record remain accurate.)_

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

### 4.5 The symptom (where it faults)
During `Py_Initialize`, `_PyStaticType_InitBuiltin` /
`managed_static_type_state_init` reads a **garbage type-index**:
`interp->types.builtins.num_initialized` comes back as **`0xf0012b00`**, far
outside the valid `0..~tens` range. It then indexes
`_PyRuntime.types.managed_static.types[idx].interp_count` and issues a 64-bit
`LDREXD` against that wild address. The deref faults **only where the garbage
address is unmapped** (real hardware); qemu-user keeps it mapped, hence the false
pass. But `num_initialized` lives inside `.PyRuntime`, and it is **zero-initialised
data** — it should be 0 at process start. The question "why is it garbage?" is
answered in §4.5'.

### 4.5' DECISIVE root cause — qemu-user mis-zero-fills the linker's mmap'd output
The garbage is not written by CPython; it is **baked into the binary at link time**,
and the corruptor is **qemu-user**. The armv7 linker runs under qemu (`--no-cross`),
and qemu's `mmap()` zero-fill of the linker's **output file** is buggy: it
non-deterministically leaves **stale page-aligned garbage** in regions the C standard
guarantees are zero — libpython's `.PyRuntime` (the `_PyRuntime` global) and
`.data.rel.ro`. Whichever build "loses the coin-flip" ships a libpython whose
`num_initialized` slot is pre-loaded with `0xf0012b00`, and SIGSEGVs on real HW.

**Forensic proof (do NOT re-tread):**
- A **clean** build (`d43b6509…`) and a **crashing** build are **byte-identical
  except those two zero-regions** — clean = all-zero, crashing = page-aligned garbage.
- The garbage even **disassembles to ARM Thumb-2 code that is absent from python** —
  i.e. it is **stale qemu build-process memory** bled into the output file, conclusive
  that the source is the emulator's mmap, not CPython.
- This is consistent with §4.3 (alignment/TLS/LTO all wrong) and §4.4 (byte-identical
  `.text`, opposite outcomes ⇒ data-region, not codegen). It also explains the
  ≈50 % per-build incidence and why it threatens **any** qemu-built armv7 binary.

(Was framed earlier in this same note as an "LDREXD 8-byte-alignment fault", then a
"GCC-15.2 `-O2` codegen bug", then a "CPython 3.14 source-level use-before-init bug /
upstream 3.14.6"; **all three superseded 2026-06-28** — the first two by the
byte-identical-`.text` experiment (§4.4), the third by the forensic proof above.)

### 4.6 BUILD-PIPELINE bug (FIXED) — the rootfs python ≠ the verified apk
Separate from the crash itself, the build had shipped the **wrong** python: the
rootfs ended up with a `python3-3.14.5-r4` (`libpython` md5 `30e88d28…`, **crashing**)
while the apk Phase 7d exported for verification was md5 `d43b6509…` (**running**).
Two root causes, **both now fixed:**
1. **The qemu coin-flip itself** (§4.5') — "two r4 builds" were simply two rolls of
   the same dice. Fixed at source by gold (§4.7).
2. **A stale-artifact SELECTION bug** — the persistent work-volume repo
   (`$WORK/packages`) accumulates apks from prior runs, and Phase 7d's old
   `find python3-3.14.5-r*.apk -print -quit` glob could match a **stale r3/r4**
   instead of the apk it just built. This very bug initially produced a bogus
   "3/3 clean" reading against a stale r4 before an md5 sanity-check caught it (same
   stale-artifact class as the earlier stale-flash incident). Fixed by selecting the
   **exact `pkgver-pkgrel`** apk name (`python3-3.14.5-r5`), gating *that* file, and
   re-running the gate on the **installed** rootfs libpython at ship time (§3.2 /
   §4.7). The version-only check that green-lit a mismatched rootfs is gone.

### 4.7 THE FIX
Three layers, all in tree (code done; this note is the prose record):
1. **`pmos/python3/APKBUILD` → r5:** revert the `-O0` experiment to stock `-O2`, add
   `binutils-gold` to makedepends, and link libpython via
   `-fuse-ld=gold -Wl,--no-mmap-output-file` in `LDFLAGS_NODIST`. gold `write()`s its
   output file instead of `mmap()`-ing it, so qemu never gets the chance to
   mis-zero-fill it → `.PyRuntime`/`.data.rel.ro` come out genuinely zero. The gold
   flags are kept **out of the propagated (DIST) LDFLAGS** so they are not baked into
   `sysconfig` — on-device pip extension builds keep the stock linker.
2. **`scripts/verify-libpython-clean.py`** (committed in `ba4e467`): a deterministic,
   optimisation-independent build-integrity gate. It flags long contiguous non-zero
   runs in `.PyRuntime`/`.data.rel.ro` outside reloc slots / the static head
   (`RUN_THRESHOLD = 256` bytes). Clean builds score `longest_run ≤ 52` B; corrupt
   builds `≥ 22000` B — the threshold sits safely between. It does **not** run the
   binary, so it works regardless of optimisation and never relies on qemu.
3. **`docker-build.sh`** Phase 7d gates every built libpython and rebuilds (`--force`,
   up to 4×) on any residual corruption, aborting if never clean; Phase 10 re-gates
   the **installed** rootfs libpython as a ship gate. So a corrupt apk can never reach
   a flashable image (§3.2).

### 4.8 VERIFICATION (this session)
- The gate **passes** the gold r5 libpython (`.PyRuntime longest_run=4`,
  `.data.rel.ro=52` → CLEAN) and **catches** a known-corrupt sample
  (`longest_run ≥ 22368` → CORRUPT).
- **FOUR independent gold rebuilds all gate-CLEAN** (3 via the
  `PYTHON3_VALIDATE_RUNS` harness + 1 standalone). Their md5s differ only because
  CPython embeds a build timestamp (benign, not corruption) — the integrity-critical
  zero-regions are clean in every one.
- **HARDWARE-VERIFIED on the live device (USB gadget):** the device's **stock**
  python3 → `Segmentation fault (core dumped)` rc=139, while the **gold r5**
  python3.14 + gold libpython → `HWOK 3.14.5 … [GCC 15.2.0]` rc=0 — same device, same
  moment. gold defeats the qemu mmap coin-flip in practice, not just in theory.

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

### 5.3 The python fix is proven; the flashed image still needs a rebuild+reflash to carry it
- The **fix is hardware-verified** (§4.8): the gold r5 python3.14 runs `rc=0` on this
  exact device. But the verification ran the gold build deployed alongside the stock
  one — the image **installed on the device right now** is the pre-fix one and still
  carries the **crashing** python (`libpython` md5 `30e88d28`), so `onboard` /
  `blueman-applet` / `sleep-inhibitor.service` / `gdb` stay down on it until a fresh
  image (built through the gated Phase 7d, §4.7) is flashed. Working on this device
  regardless: **SMP dual-core**, **cpufreq to 1.2 GHz** with correct VDD_MPU, **BT**
  (BCM4330 patchram), the **WiFi radio** (firmware OK), **zram** (lzo-rle), **USER_NS**.
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
- `pmos/python3/` — new override aport (APKBUILD now **r5**, gold-linked
  `-fuse-ld=gold -Wl,--no-mmap-output-file` + `binutils-gold` makedep, `-O0` reverted
  to `-O2`; + 4 companion files).
- `scripts/verify-libpython-clean.py` — deterministic build-integrity gate
  (committed `ba4e467`).
- `docker-build.sh` — Phase 6 stage python3; Phase 7d gate+retry build with
  pkgrel-exact apk selection; Phase 10 ship gate on the installed rootfs libpython.
