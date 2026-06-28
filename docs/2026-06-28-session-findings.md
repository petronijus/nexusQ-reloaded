# Session findings — 2026-06-28

Full-rootfs image hardening: zram swap, user namespaces, a dual-core re-confirm
on the live device, a CPU power/thermal health pass — and the hard ARMv7 python
SIGSEGV **finally root-caused AND fixed** (see §7). The settled conclusion: it is
**not** a compiler or CPython-source bug, and **not** a build-time qemu corruption
either — it is a **DEPLOYMENT (flash) bug**. `raw2simg.py` emitted all-zero blocks as
`DONT_CARE`, which the Nexus Q's non-erasing U-Boot left as STALE eMMC data,
re-corrupting libpython's should-be-zero regions on-device. **Fixed** by making the
flash byte-exact (all-RAW), and **hardware-verified** on the live device from a clean
flash.

> **CORRECTION (this section reconciled 2026-06-28): the build was never the problem;
> there was no "build fix".** Earlier in this same session §4 hypothesised a *build-time
> qemu-user mmap corruption* and a **gold-linker** workaround, framed as a "two-layer
> (gold build + all-RAW flash)" fix. That framing is **WRONG and withdrawn.** The build
> was never reproducibly corrupt — **6 independent default-linker (bfd) builds were all
> integrity-gate-clean**, and a **bfd** build (gold-note absent, libpython md5
> `79a0d4ace1358bb2d94c8a4d72479da9`) flashed via the corrected all-RAW `raw2simg` ran
> `python3 -S -c ''` **rc 0** on the real device. The qemu-build/gold theory **did NOT
> reproduce** (6/6 clean would be ≈1.6 % under a real 50 % coin-flip), so **the gold
> flag and `binutils-gold` were REMOVED** from `pmos/python3/APKBUILD` (pkgrel stays
> **r5**, default linker). The earlier "build coin-flip" evidence was almost certainly a
> **post-flash device pull** (the §7 flash bug) misread as build corruption. **Only the
> flash fix (§7) was required.** What is KEPT from §4 — and genuinely useful — is the
> build-integrity gate + Phase-7d retry + Phase-10 ship gate + pkgrel-exact apk
> selection, as a cheap **safety net** that catches zero-region corruption from any
> source (NOT "the gold fix"). The §4 sub-sections below are preserved as the
> investigation record; read them through this correction.

Several long-standing doc
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
Alpine's stock **python3-3.14.5-r2 is broken on armv7 ON THE DEVICE** (the §7 flash
bug re-corrupted it). The override is the SAME version rebuilt (started **r3**, now
**r5**) so its higher pkgrel supersedes Alpine's -r2 in the rootfs:
- drops `--with-lto` and `--enable-optimizations` (PGO) and keeps
  `--with-computed-gotos`; r5 **reverts the r4 `-O0` experiment back to stock
  `-O2`** — codegen was never the cause.
- **r5 is a plain DEFAULT-LINKER (bfd) build.** A `gold -Wl,--no-mmap-output-file`
  link was tried (to defeat a hypothesised qemu mmap build-corruption) and then
  **DROPPED as unnecessary** — `binutils-gold` and the `-fuse-ld=gold
  -Wl,--no-mmap-output-file` flags were **removed** because 6/6 bfd builds were
  integrity-gate-clean and a bfd build ran rc 0 on device (see the top correction and
  §4.8'). The actual on-device fix was the §7 all-RAW flash, not the linker.
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
- An opt-in `PYTHON3_VALIDATE_RUNS=N` harness forces N independent rebuilds + gates
  each. Used this session to test the qemu-build-corruption hypothesis: **6/6
  default-linker builds came out gate-clean** — i.e. there was no reproducible build
  coin-flip to defeat, which is why gold was dropped (§4.8').

### 3.3 `device-google-steelhead/APKBUILD` pkgrel 6 → 10 — un-mask + add debug tools
The earlier `sleep-inhibitor.service` → `/dev/null` **mask was REMOVED** (r9): we
fix the root cause (python) instead of masking the symptom — and the root cause is
now actually fixed (§4). r10 additionally adds **`gdb` (16.3)** + **`python3-dbg`**
to the device image (used this session to coredump-debug the crash on hardware).
gdb itself links `libpython`, so it SIGSEGVed for the same reason on the
flash-corrupted-python image; on the v1.6.0 all-RAW flash it links a clean libpython
and works. (The bump also picks up the deviceinfo zram algo + the un-mask.)

---

## 4. INVESTIGATION (hypothesis since DISPROVEN) — was the python3 SIGSEGV a qemu build-time corruption?

> **Status: HYPOTHESIS, DISPROVEN. The real cause is the §7 FLASH bug.** This section
> records the mid-session theory that the crash was a **build-time qemu-user mmap
> corruption** of the linker's output (qemu's mmap zero-fill of the LINKER's output
> file leaving stale garbage in libpython's `.PyRuntime` / `.data.rel.ro`), "fixed" by
> linking with **gold + `-Wl,--no-mmap-output-file`**. **That theory did NOT reproduce
> and is withdrawn:**
> - **6 independent default-linker (bfd) builds were ALL integrity-gate-clean** — there
>   was no reproducible ≈50 % build coin-flip (6/6 clean is ≈1.6 % under a real
>   coin-flip).
> - A **bfd** build (gold-note absent, libpython md5 `79a0d4ace1358bb2d94c8a4d72479da9`),
>   flashed via the corrected **all-RAW** `raw2simg`, ran `python3 -S -c ''` **rc 0** on
>   the real device (§4.8').
> - The "byte-identical `.text`, opposite outcome" / "two r4 builds" coin-flip evidence
>   below (§4.4, §4.5', §4.6) was almost certainly a **post-flash device pull** (the §7
>   flash bug) misread as a build artifact.
>
> So **gold and `binutils-gold` were REMOVED** (pkgrel stays r5, default linker), and
> **only the §7 all-RAW flash fix was actually required.** What is KEPT from this
> section is the deterministic build-integrity gate (§4.7) + Phase-7d retry +
> Phase-10 ship gate — a cheap **safety net** against zero-region corruption from any
> source, not "the gold fix". The symptom description (§4.5) and the §4.3
> disproven-hypotheses record remain accurate; read the rest of §4 as the
> investigation trail, corrected by this banner and §4.8'.

### 4.1 Symptom
Alpine **python3-3.14.5 SIGSEGVs deterministically on real ARMv7** (Cortex-A9):
even `python3 -S -c ''` returns **rc 139**, before any user bytecode, during
`Py_Initialize`. It crashes `onboard`, `blueman-applet`, `sleep-inhibitor.service`
— and now `gdb` too (gdb links `libpython`, see §5.3).

### 4.2 qemu-user gives a FALSE PASS — on-device is the only authority
The override **r3** PASSED the qemu-user gate (`pmbootstrap chroot`
`python3 -S -c ''` rc 0) but still SIGSEGVed on the device.

> **CORRECTION (2026-06-28):** the gap was **not** "qemu keeps the wild address mapped".
> r3's apk was clean; it was **flash-corrupted on the device** by the §7 `DONT_CARE`
> sparse, so qemu (running the clean build) passed while the device (running the
> flash-mangled copy) crashed. Same observation, correct cause.

> **LESSON (still stands): never gate armv7 python (or any pointer/atomic-sensitive
> native code) on the qemu chroot alone. Always validate `python3 -S -c ''` ON THE
> DEVICE** — and integrity-check what the device actually runs, not just the artifact.

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

### 4.4 finding — the crash is data/layout-dependent, not code-dependent
Two libpython copies of the **same source at the same flags** (`-O0`, pkgrel **r4**)
behaved **differently on the same device**: one ran `python3 -S -c ''` clean **6/6**,
the other SIGSEGVed **6/6**. Their **`.text` (machine code) sections are byte-for-byte
identical** — **3,528,976 bytes, `cmp` equal** — they differ **only** in ~**139 KB
of DATA sections**. Identical code, different data, opposite outcome ⇒ the crash is
**layout/data-dependent, not codegen-dependent** — this correctly retires the "-O2
codegen bug" framing.

> **CORRECTION (2026-06-28):** the *interpretation* that the crashing copy was a
> distinct **build** (a "qemu coin-flip") is withdrawn. With 6/6 default-linker builds
> later coming out gate-clean (§4.8'), the "crashing" copy here was almost certainly a
> **device-pulled** libpython that had already been **flash-corrupted** (§7) — i.e. the
> data-region difference came from the flash, not from a second link. The data-region
> conclusion is right; "two different builds" was the wrong attribution.

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

### 4.5' (WITHDRAWN theory) — "qemu-user mis-zero-fills the linker's mmap'd output"
> **WITHDRAWN 2026-06-28 — superseded by §7.** This was the session's best guess at the
> time; it did **not** reproduce (6/6 default-linker builds gate-clean, §4.8'). The
> garbage in the zero-regions came from the **flash** (stale eMMC blocks left by a
> non-erasing U-Boot, §7), not from qemu's link-time mmap. Preserved verbatim below as
> the investigation record.

The garbage is not written by CPython. The theory was that it is **baked into the
binary at link time** by **qemu-user**: the armv7 linker runs under qemu (`--no-cross`),
and qemu's `mmap()` zero-fill of the linker's **output file** was believed buggy,
non-deterministically leaving **stale page-aligned garbage** in regions the C standard
guarantees are zero — libpython's `.PyRuntime` (the `_PyRuntime` global) and
`.data.rel.ro` — so a libpython whose `num_initialized` slot is pre-loaded with
`0xf0012b00` SIGSEGVs on real HW.

**Evidence cited at the time (re-interpreted — the source was the flash, not qemu):**
- A **clean** copy (`d43b6509…`) and a **crashing** copy are **byte-identical except
  those two zero-regions** — clean = all-zero, crashing = page-aligned garbage. _(This
  is exactly the §7 flash signature: image-zero → device-garbage.)_
- The garbage even **disassembles to ARM Thumb-2 code that is absent from python** —
  i.e. it is **stale foreign memory** bled into the file. Read at the time as stale
  qemu build memory; §7 shows it is **stale eMMC content from a prior flash**.
- Consistent with §4.3 (alignment/TLS/LTO all wrong) and §4.4 (byte-identical `.text`,
  opposite outcomes ⇒ data-region, not codegen) — both of which remain correct.

(Was framed earlier in this same note as an "LDREXD 8-byte-alignment fault", then a
"GCC-15.2 `-O2` codegen bug", then a "CPython 3.14 source-level use-before-init bug /
upstream 3.14.6", then this qemu-mmap theory; **all superseded 2026-06-28** — the first
two by the byte-identical-`.text` experiment (§4.4), the last two by the §7 flash
forensics.)

### 4.6 BUILD-PIPELINE bug (FIXED) — the rootfs python ≠ the verified apk
Separate from the crash itself, the gating could read a **different** apk than the one
installed: a `python3-3.14.5-r4` (`libpython` md5 `30e88d28…`, **crashing**) appeared
alongside the Phase-7d-exported md5 `d43b6509…` (**running**). The genuine, fixed cause:
1. **A stale-artifact SELECTION bug** — the persistent work-volume repo
   (`$WORK/packages`) accumulates apks from prior runs, and Phase 7d's old
   `find python3-3.14.5-r*.apk -print -quit` glob could match a **stale r3/r4**
   instead of the apk it just built. This very bug initially produced a bogus
   "3/3 clean" reading against a stale r4 before an md5 sanity-check caught it (same
   stale-artifact class as the earlier stale-flash incident). Fixed by selecting the
   **exact `pkgver-pkgrel`** apk name (`python3-3.14.5-r5`), gating *that* file, and
   re-running the gate on the **installed** rootfs libpython at ship time (§3.2 /
   §4.7). The version-only check that green-lit a mismatched rootfs is gone.

> **CORRECTION (2026-06-28):** the `30e88d28…` "crashing build" cited above was almost
> certainly a **device pull of a flash-corrupted** libpython (§7), not a second bad
> *build*. The stale-artifact SELECTION bug was real and is genuinely fixed; the
> "two builds disagree" reading of it was not.

### 4.7 THE FIX (corrected) — the flash, plus a kept safety net
The actual fix is in **§7** (all-RAW `raw2simg.py`, byte-exact flash). The build-side
work below was originally written as "THE FIX (three layers, gold-led)"; **layer 1
(gold) was DROPPED as unnecessary** and is struck here. What remains is a genuinely
useful build-integrity **safety net** (code in tree):
1. ~~gold link of libpython~~ — **REMOVED.** `pmos/python3/APKBUILD` r5 is a plain
   **default-linker (bfd)** build (revert the `-O0` experiment to stock `-O2`); the
   `binutils-gold` makedep and `-fuse-ld=gold -Wl,--no-mmap-output-file` flags were
   deleted because 6/6 bfd builds were clean and a bfd build ran rc 0 on device (§4.8').
2. **`scripts/verify-libpython-clean.py`** (committed in `ba4e467`): a deterministic,
   optimisation-independent build-integrity gate. It flags long contiguous non-zero
   runs in `.PyRuntime`/`.data.rel.ro` outside reloc slots / the static head
   (`RUN_THRESHOLD = 256` bytes). Clean builds score `longest_run ≤ 52` B; corrupt
   builds `≥ 22000` B — the threshold sits safely between. It does **not** run the
   binary, so it works regardless of optimisation and never relies on qemu. **Kept as a
   cheap safety net** — it catches zero-region corruption from any source.
3. **`docker-build.sh`** Phase 7d gates every built libpython and rebuilds (`--force`,
   up to 4×) on any residual corruption, aborting if never clean; Phase 10 re-gates
   the **installed** rootfs libpython as a ship gate. So a corrupt apk can never reach
   a flashable image (§3.2).

### 4.8 VERIFICATION (build stage) — the build was always clean
> Originally written to "prove gold beats the qemu coin-flip". Re-read: it proves the
> **default-linker** build is clean; there was no coin-flip to beat (§4.8' below).
- The gate **passes** the r5 libpython (`.PyRuntime longest_run=4`,
  `.data.rel.ro=52` → CLEAN) and **catches** a known-corrupt sample
  (`longest_run ≥ 22368` → CORRUPT).
- The early run used **gold** rebuilds (all gate-CLEAN); their md5s differ only because
  CPython embeds a build timestamp (benign, not corruption). This was originally read as
  "gold defeats the coin-flip" — but the follow-up showed the coin-flip never existed.

### 4.8' DECISIVE — default-linker (bfd) builds are clean, on-device rc 0 (gold dropped)
- **6 independent default-linker (bfd) builds were ALL integrity-gate-CLEAN** (via the
  `PYTHON3_VALIDATE_RUNS` harness + standalone). Under a real ≈50 % build coin-flip,
  6/6 clean is ≈1.6 % — so the qemu-build-corruption hypothesis (§4.5') **did not
  reproduce**.
- **HARDWARE-VERIFIED on the live device:** a **bfd** python3.14 (gold note **absent**;
  libpython md5 `79a0d4ace1358bb2d94c8a4d72479da9`), flashed via the corrected
  **all-RAW** `raw2simg` (§7), ran `python3 -S -c ''` → **rc 0** on the real device. The
  device's pre-fix (DONT_CARE-flashed) python → `Segmentation fault` rc=139 on the same
  hardware.
- **Conclusion:** the gold flag and `binutils-gold` were **removed** from
  `pmos/python3/APKBUILD` (pkgrel stays **r5**). Only the §7 flash fix was required;
  the integrity gate is kept purely as a safety net. v1.6.0 ships the **bfd** python3.

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
> **SUPERSEDED by §7 (resolved later the same day).** The rebuild+reflash described
> here was done — and it surfaced the deployment-stage `raw2simg.py` `DONT_CARE` bug,
> now also fixed. As of the v1.6.0 flash, system python works from a clean flash with
> no live-patch. The paragraph below is preserved as the state *before* §7.

- The **fix is hardware-verified** (§4.8'): the r5 python3.14 runs `rc=0` on this
  exact device. But at this point in the session the image **installed on the device**
  was the pre-fix one, still carrying a **flash-corrupted** python (`libpython` md5
  `30e88d28`), so `onboard` /
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
- `pmos/python3/` — new override aport (APKBUILD now **r5**, plain **default-linker
  (bfd)** build, `-O0` reverted to `-O2`; the tried-then-dropped gold link
  (`-fuse-ld=gold -Wl,--no-mmap-output-file` + `binutils-gold` makedep) was **removed**;
  + 4 companion files).
- `scripts/verify-libpython-clean.py` — deterministic build-integrity gate
  (committed `ba4e467`).
- `docker-build.sh` — Phase 6 stage python3; Phase 7d gate+retry build with
  pkgrel-exact apk selection; Phase 10 ship gate on the installed rootfs libpython.
- `raw2simg.py` — encode every block as RAW (drop `DONT_CARE`) so the flash is
  byte-exact on the non-erasing U-Boot (§7).

---

## 7. ROOT CAUSE — the non-erasing flash corrupted the (clean) libpython

> **Status: ROOT-CAUSED and FIXED, permanently flash-verified on hardware
> (2026-06-28). This is THE one and only cause of the on-device python SIGSEGV.** The
> bug is in the *deployment* step, not the build: a `DONT_CARE` sparse on a non-erasing
> U-Boot left STALE eMMC bytes in libpython's zero-regions. The build was always clean
> (§4 was a disproven build-theory; gold was dropped). **Only this flash fix was
> required** — fixed by making the flash byte-exact (all-RAW).

### 7.1 Symptom — clean image, crashing device
The v1.6.0 rootfs built through the gated pipeline (§4.7) is **gate-CLEAN** —
`scripts/verify-libpython-clean.py` passes the installed `libpython` and the Phase-10
ship gate is green. Yet after flashing it and booting, the **system `python3` still
SIGSEGVed (rc 139)** — the same `.PyRuntime` garbage symptom. The image was clean; the
**device** was not.

### 7.2 Forensic signature — flash-corruption ≠ build-corruption
Comparing the **on-device** `libpython3.14.so.1.0` against the **flashed image's**
copy (the gate-CLEAN one):
- They differ in **exactly 47** 4 KiB blocks — and **every** differing block is
  **"image-zero → device-garbage"**, **0** blocks differ the other way. The image's
  zero-regions arrived on the eMMC full of stale bytes.
- The image gates **CLEAN**; the on-device file gates **CORRUPT**
  (`.PyRuntime longest_run = 30652`, far over the 256 threshold).
- **Decisive proof it was the flash, not the build:** `scp`-ing the **clean image
  libpython** over the device's copy → `python3 -S -c ''` returns **rc 0 instantly**.
  The bytes that boot to a working python existed in the image all along; the flash
  failed to write them.

§4 hypothesised the **build** wrote the garbage (qemu mmap); this forensic shows it is
the **flash** failing to write the binary's zeros onto a dirty partition — the build
artifact was clean all along. The §4 build theory is therefore disproven; the flash is
the sole cause.

### 7.3 Root cause — `DONT_CARE` chunks on a partition U-Boot never erases
`raw2simg.py` (raw ext4 → Android sparse, because the 2012 U-Boot fastboot supports
only RAW + DONT_CARE, no FILL) used to emit every all-zero 4 KiB block as a
**`DONT_CARE`** chunk to shrink the image. **fastboot SKIPS `DONT_CARE` blocks — it
does not write them** — which is correct *only on a pre-erased partition*. The Nexus
Q's U-Boot does **not** erase `userdata` before a flash, so each skipped block kept
whatever **STALE data** the eMMC already held from the *previous* flash. Wherever the
new image had zeros but the old eMMC content had garbage, that garbage survived — and
it landed in libpython's `.PyRuntime` / `.data.rel.ro` (PROGBITS, read during
`Py_Initialize`), reproducing the wild-type-index deref → SIGSEGV. The bug only bites
on a **re-flash over dirty eMMC**; a hypothetical first-ever flash onto a zeroed
partition would have masked it.

### 7.4 THE FIX — all-RAW, byte-exact flash (code done; do not re-edit `raw2simg.py`)
`raw2simg.py` now encodes **EVERY** block as **RAW** (zeros included, no `DONT_CARE`),
so the on-eMMC bytes are **identical to the source image regardless of prior eMMC
content**. The cost is no compression (the sparse is ≈ the raw size); correctness over
compression — `DONT_CARE` is intentionally never used. (RAW chunks are capped at
16384 blocks = 64 MiB to keep the chunk table tidy; `fastboot -S 100M` re-splits the
transfer anyway, so the flash command is **unchanged**.)

### 7.5 VERIFICATION — permanent, on hardware, from a clean flash
- **De-sparse round-trip:** md5 of the de-sparsed image == md5 of the raw image
  (byte-exact encode/decode).
- **On hardware:** reflashed `userdata` with the corrected all-RAW sparse, rebooted,
  and the **FRESH flash (no live-patch — confirmed by the absence of the
  `.flashcorrupt` backup)** gives:
  - `/usr/lib/libpython3.14.so.1.0` md5 **`79a0d4ace1358bb2d94c8a4d72479da9`** (the
    clean **default-linker / bfd** r5 build — gold note absent),
  - `SYSPY_OK 3.14.5 … [GCC 15.2.0]`, `SYS_PY_RC=0`.

The fix is the **all-RAW `raw2simg`** (byte-exact flash) → a working **system** python
on a **permanent** flash, with a plain bfd build feeding it. Shipped as **v1.6.0**.
(An earlier round of this same verification used a gold build, md5 `b354e75f…`; gold was
subsequently dropped as unnecessary — see the §4 banner and §4.8' — and v1.6.0 ships the
bfd build above.)

**LESSON (memory `sparse-dontcare-stale-emmc-corrupts-flash`; the
`qemu-user-corrupts-armv7-binaries` note is now marked DISPROVEN): integrity-verify what
the DEVICE runs, not just the built artifact.** A gate-CLEAN image can still arrive
corrupt if the flash path doesn't write the bytes; never trust DONT_CARE on a
non-erasing target. The build was never the problem — chasing it (gold linker) cost a
detour; the flash was.
