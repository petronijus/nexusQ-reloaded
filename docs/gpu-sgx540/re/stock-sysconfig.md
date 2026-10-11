# SGX540 RE 4/7: the stock SGX540 system layer (clocks, DVFS, IRQ, PM) against mainline 6.18 and the letux glue

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

- The three GPU OPPs (153.6 / 307.2 / 384 MHz at 962 / 1127 / 1250 mV) were
  decoded independently a second time by the visualizer workstream
  ([visualizer-gl.md](visualizer-gl.md) §6, Verification row 14).
- The build-option word of letux 1.8.869593 (`0x00360018`, missing only
  `0x8004` against stock) agrees with [km-um-bridge-abi.md](km-um-bridge-abi.md)
  and [firmware-microkernel.md](firmware-microkernel.md).
- Open question "is the Google `sgx_idle` source published?": the AOSP
  `kernel/omap` branch `android-omap-steelhead-3.0-ics-aah` @ `03a9286b`
  (found by [stock-android-blobs-libhybris.md](stock-android-blobs-libhybris.md))
  is the obvious candidate; its `drivers/gpu/pvr/omap4/` files were not opened in
  this session (UNVERIFIED).
- The verification pass could not run the capstone-based `reverse-eng/tools/nqdis.py`
  on this host and re-derived everything with `arm-none-eabi-objdump`.

---

Date: 2026-10-11. Scope: disassembly-level RE of the stock kernel's PowerVR
system layer (`drivers/gpu/pvr/omap4/sysconfig.c` + `sysutils_linux.c`), the
OMAP4 platform data (hwmod `gpu`, `gpu_fck`, the OPP table, `omap_init_gpu`),
and the bootloader clock setup that feeds it. Each item is compared with
mainline v6.18.48 DT + clock data, our steelhead DTS/defconfig, and the letux
`openpvrsgx` glue. Nothing was built, flashed or committed, and no device was
touched.

## TL;DR

- The stock system layer is the stock **TI DDK 1.8 `omap4` system layer**
  (`sgxddk 18 1.8@785978`) with a Google-only DVFS add-on (`sgx_idle`). Its
  `SYS_SPECIFIC_DATA` layout, flag bits and OCP-IRQ code match
  `1.8.869593/.../system/omap4` in the letux tree word for word. The add-on is
  module parameters `sgx_idle_mode=2`, `sgx_idle_timeout=1 ms` and
  `sgx_apm_latency=100 ms`, plus an hrtimer and a workqueue.
- **Clock (highest-impact finding).** The stock *board* code
  (`omap4_steelhead_display_init`, `0xc0075f08..0xc0075f58`) runs
  `clk_set_parent(gpu_fck, dpll_per_m7x2_ck)`. Both stock bootloaders lock
  DPLL_PER at M=20 N=0 with **M7=5**, so `dpll_per_m7x2_ck` = 1536/5 =
  **307.2 MHz** at boot. Mainline `omap4460.dtsi` and our
  `omap4-steelhead.dts` assign nothing. (Only `omap443x.dtsi` does, with
  exactly this per@307.2 MHz assignment.) So on our kernel the mux keeps its
  reset/bootloader value. If that value is the CORE path, as stock's static
  `gpu_fck.parent` suggests (reset value not verified), the clock is
  `dpll_core_m7x2_ck` = 1600/6 = **266.67 MHz**, and the source differs from
  stock. **Fix:** copy the 443x `&sgx_module` assigned-clocks block into the
  steelhead DTS.
- **DVFS.** Stock scales the GPU over **153.6 / 307.2 / 384 MHz** at VDD_CORE
  **962 / 1127 / 1250 mV** (`omap446x_opp_def_list`, `0xc0043e94..0xc0043ed8`).
  It does this through `omap_device_scale()`, which changes both the
  `dpll_per_m7x2_ck` divider and VDD_CORE. Mainline has no GPU OPP table, no
  devfreq (`# CONFIG_PM_DEVFREQ is not set`) and no core DVFS: VDD_CORE is
  static, and patch 0027 sets the VC ON voltage to 1.200 V. **Do not run
  384 MHz** without core-voltage scaling, because it needs 1.25 V. Stay at
  307.2 MHz, which needs 1.127 V (≤ 1.2 V). *(Verification 2026-10-11:
  1.2 V is only the VC ON/ONLP target that patch 0027 programs for the
  VCORE1 channel; the runtime VDD_CORE on our kernel was never measured,
  and the repo notes disagree about which TWL6030 SMPS feeds which rail on
  mainline (`docs/2026-06-25-cpufreq-vdd-mpu-findings.md` says VCORE1 feeds
  VDD_MPU at ~1025 mV; `docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §1
  maps VCORE1 to VDD_CORE). "307.2 MHz is safe" is therefore UNVERIFIED until
  VDD_CORE ≥ 1.127 V is measured live; see parity row #30.)* *(2026-10-11: the
  disagreement is resolved for VCORE1 = VDD_CORE. Stock's 4460 TWL setup, the
  x-loader (VCORE1 → 1127 mV target, vsel 0x23 = 1.139 V; TPS62361 → 1210 mV) and
  upstream U-Boot ("4460 : supplies vdd_core") all agree. Live read still pending
  [pm Addendum "Live VDD_CORE without a device"].)*
- **Timing values for the microkernel.**
  - Stock passes: core clock = the current OPP frequency (384 MHz when busy),
    HW recovery 100 Hz, ukernel timer 1000 Hz, active PM on, APM latency
    100 ms (101 ticks).
  - The letux 1.17 `omap` layer, when built for OMAP4 (`AM_VERSION=4`),
    pulls in **`sysconfig-am4.h` (AM437x values)**: 200 MHz, 50 Hz HWR, 2 ms
    APM. That mismatches the real clock.
  - *(Corrected 2026-10-11.)* The letux 1.14.3699939 `omap` layer has no
    `sysconfig-am4.h`. Built for OMAP4 it gives 200 MHz (`sysinfo.h:46-54`,
    non-AM5 branch), **100 Hz** HWR (`sysconfig.h:57`) and **APM disabled**
    for SGX540: its Makefile sets `SUPPORT_ACTIVE_POWER_MANAGEMENT` only for
    sgx544 and jz4780 (lines 217, 225), so `bEnableActivePM = IMG_FALSE`
    (`sysutils_linux.c:177-181`).
  - The letux 1.8 `omap4` layer hard-codes 307.2 MHz, 100 Hz HWR and 2 ms APM.
- **IRQ / OCP.**
  - Stock uses GIC SPI 21 (Linux irq 53), the OCP wrapper at `+0xFE00` and
    `SGX_OCP_NO_INT_BYPASS`. It writes only `IRQSTATUS_2`,
    `IRQENABLE_SET_2` and `IRQENABLE_CLR_2`, and **never** `DEBUG_CONFIG`
    (`0xFF08`).
  - Letux `pvr-drv.c` `pvr_runtime_resume()` also sets
    `DEBUG_CONFIG = BIT(31)` (THALIA_INT_BYPASS). That is a behavioural
    difference from stock.
  - Mainline DT IRQ, register base, sysc offsets, idle modes, clkctrl and
    power domain all **match** stock.
- **KM ↔ UM coupling, a hard gate for the stock blobs.** The stock KM accepts
  only a microkernel with DDK `0x00010812` (1.8.18) **and build 785978**
  (`0xBFE3A`), and build options exactly **`0x0036801C`**
  (`SGXDevInitCompatCheck`, `0xc0292f58`, `0xc0292ff4..0xc0293034`).
  - The letux 1.8 tree is build **869593**.
  - *(Corrected 2026-10-11.)* Its Kbuild produces options **`0x00360018`**,
    not `0x00260018`. `SUPPORT_SGX_LOW_LATENCY_SCHEDULING` makes
    `sgxfeaturedefs.h:242-243` define `SUPPORT_SGX_PRIORITY_SCHEDULING`, and
    `sgxinit.c` includes `sgxdefs.h` (→ `sgxfeaturedefs.h`, line 29) before
    `sgx_options.h` (line 50), so bit 20 is set. It lacks only
    EDM_STATUS_DEBUG and SUPPORT_ACTIVE_POWER_MANAGEMENT (**`0x8004`**).
  - So neither letux 1.8 as built nor 1.14/1.17 can pair with the IAN67K
    `pvrsrvinit`/`libsrv_um` without changes.
- Other differences:
  - Stock was `SMP PREEMPT`; our defconfig is `CONFIG_PREEMPT_NONE=y`, and
    letux states the PVR build needs PREEMPT or PREEMPT_VOLUNTARY.
  - Stock gets an ION client at probe; mainline has no ION.
  - Stock HZ=128, ours 100. This is minor.

Parity count (stock vs mainline 6.18.48 + our DTS/defconfig + letux glue),
from the 31 rows of the table in §6: **12 MATCH, 11 MISMATCH, 4 MISSING, 1 EXTRA, 3 UNKNOWN**.

## 1. Method and evidence base

- Stock kernel: `reverse-eng/vmlinux.bin` (3.0.8-gad584da, "SMP PREEMPT",
  build string at `0xc055f4b0`), load VA `0xc0008000`. Symbols come from
  `reverse-eng/tools/kallsyms.txt` (45 617 symbols). Disassembly uses
  `reverse-eng/tools/nqdis.py`, data uses `reverse-eng/tools/dump.py` and call sites use
  `reverse-eng/tools/callers.py` (capstone 5.0.7).
- Stock bootloaders: `reverse-eng/factory/tungsten-ian67k/xloader-phantasm-ian67k.img`
  (load base derived as **0x402FFE00**: the five string literals at file
  offsets `0x5620..0x5b90` all land on NUL-preceded strings with that base)
  and `bootloader-phantasm-steelheadb4h0j.img`.
- Mainline: the v6.18.48 tree at `<session scratch>/gpu/src/kernel/linux-6.18.48`
  (`Makefile` VERSION 6 / PATCHLEVEL 18 / SUBLEVEL 48). This tree is
  partial: it has no `drivers/soc/ti/omap_prm.c`.
- Letux: the `openpvrsgx-devgroup/linux_openpvrsgx` clone at
  `<session scratch>/gpu/src/openpvrsgx`, HEAD `d2f1e031d58aca97bc4b62367f0d7bef4a7559c3`
  (branch `pvrsrvkm-6.18-rc6`, "Merge branches 'letux/omap-sysc-prm-gfx',
  'letux/omap-pvr-soc-glue-v10', … into pvrsrvkm-6.18-rc6", 2025-11-21).
  Base is `6a23ae0a` (Linux 6.18-rc6). Outside the pvrsgx tree, the glue
  differs from 6.18-rc6 only in:
  - `Documentation/.../img,powervr-sgx.yaml`
  - `arch/arm/mach-omap2/pdata-quirks.c` (`OF_DEV_AUXDATA` for
    `ti,omap4-prm-inst`, `ti,omap5-prm-inst` and others)
  - `arch/arm/boot/dts/ti/omap/omap4470.dtsi` (new)
  - `omap54xx-clocks.dtsi`, `am33xx.dtsi`
  - `mm/vmalloc.c` (`EXPORT_SYMBOL(__vmalloc_node_range_noprof)`)
  - defconfigs

  The output of `git diff --name-status 6a23ae0a d2f1e031 -- arch drivers/bus …`
  is reproduced in Sources. **`omap4.dtsi`, `omap443x.dtsi`, `omap4460.dtsi`
  and `omap446x-clocks.dtsi` are byte-identical** between letux and v6.18.48
  (plain `diff`, empty output). The letux OMAP4 GPU DT is therefore the
  mainline one.
- Our port: `kernel/dts/omap4-steelhead.dts` (includes `omap4460.dtsi` at
  line 29; `grep -i 'sgx\|gpu\|l3_gfx\|m7x2'` gives no hits),
  `kernel/configs/steelhead_defconfig`, and `kernel/patches/0027-*`.

## 2. Stock system layer, function by function

All addresses are kernel VAs in `vmlinux.bin`. The globals sit in one `.bss`
block based at `0xc07b7a38` (`r5`/`r7` in the code):

| Offset | VA | kallsyms name | Meaning (DDK 1.8 omap4) |
|---|---|---|---|
| +0x0c0 | 0xc07b7af8 | `gpsSysData` | `SYS_DATA *` |
| +0x128 | 0xc07b7b60 | `gsSysSpecificData` | `SYS_SPECIFIC_DATA` (flags at +0) |
| +0x164 | 0xc07b7b9c | `gsSGXDeviceMap` | reg phys base stored at +0x168/+0x16c, size at +0x174, IRQ at +0x188 |
| +0x18c | 0xc07b7bc4 | `gpsSGXDevNode` | SGX device node |
| +0x190 | 0xc07b7bc8 | `gpsSysSpecificData` | pointer to the struct at +0x128 |
| +0x194 | 0xc07b7bcc | `gui32SGXDeviceID` | |
| +0x198 | 0xc07b7bd0 | `gsSGXRegsCPUVAddr` | ioremapped regs; +0x19c holds the same pointer (OCP base) |
| +0x2c8 | 0xc07b7d00 | `sgx_idle_timer` | hrtimer (`.function` stored at +0x2e8) |
| +0x2f8 | 0xc07b7d30 | `sgx_idle_last_busy` | ktime of the last busy transition |

`SYS_SPECIFIC_DATA` field offsets used by the code are +0x10
`bSysClocksOneTimeInit`, +0x14 `sSGXClocksEnabled`, +0x18 `sPowerLock` (mutex),
+0x30 `ui32SGXFreqListSize`, +0x34 `pui32SGXFreqList` and +0x38
`ui32SGXFreqListIndex`. +0x08 `bSGXInitComplete` is set to 1 at
`0xc028fb9c`. This is identical to `_SYS_SPECIFIC_DATA_TAG_` in letux
`1.8.869593/eurasia_km/services4/system/omap4/syslocal.h` (with
`PVR_LINUX_USING_WORKQUEUES`, no DEBUG/TIMING).

The flag bits seen in stock match that header's `SYS_SPECIFIC_DATA_*` defines
(`0xc028fef4..0xc0290348`, `0xc0290630..0xc0290800`):

| Bit | Name |
|---|---|
| 0x1 | ENABLE_SYSCLOCKS |
| 0x2 | ENABLE_LISR |
| 0x4 | ENABLE_MISR |
| 0x8 | ENABLE_ENVDATA |
| 0x20 | ENABLE_REGDEV |
| 0x80 | ENABLE_INITDEV |
| 0x100 | ENABLE_LOCATEDEV |
| 0x200 | PM_UNINSTALL_LISR (stock usage) |
| 0x400 | PM_DISABLE_SYSCLOCKS (stock usage) |
| 0x1000 | ENABLE_PM_RUNTIME |
| 0x2000 | IRQ_ENABLED |
| 0x4000 | DVFS_INIT |

### 2.1 `SysInitialise` @ 0xc028fef4 (source "drivers/gpu/pvr/omap4/sysconfig.c")

The order is:

1. `OSInitEnvData`, then set the device count = 15 (`mov r1,#0xf` at
   `0xc028ff68`), then `PVRSRVInit`.
2. **SysLocateDevices (inlined).**
   - `platform_get_resource(gpsPVRLDMDev, IORESOURCE_MEM=0x200, 0)` at
     `0xc028ffd0` and `platform_get_irq(…,0)` at `0xc028ffe8`.
   - Trace output: "SGX register base: 0x%lx", "SGX register size: %d" (size
     = end-start = **0xFFFF**, off by one like the DDK), "SGX IRQ: %d".
   - `OSMapPhysToLin(base, size, 0xA000 = KERNEL_ONLY|UNCACHED)` at
     `0xc0290044`. The same pointer is used for the regs and the OCP base.
3. `SysPMRuntimeRegister` (`pm_runtime_enable(&pdev->dev)`, `0xc0290f48`),
   then `SysDvfsInitialize` (§2.6).
4. `PVRSRVRegisterDevice(…, SGXRegisterDevice, 1, &gui32SGXDeviceID)` at
   `0xc02900ac`. The device node of type 7 (SGX) is found.
5. `EnableSystemClocks` (`0xc0290eb0`): mutex init only; the GPT11
   timing-timer code is not compiled.
6. `EnableSGXClocks`, then `PVRSRVInitialiseDevice`, then `DisableSGXClocks`.
7. Create debugfs `sgx_idle` (mode `0x124`, `sgx_idle_log_fops`).
   `hrtimer_init(&sgx_idle_timer, clock 0, HRTIMER_MODE_REL)`.
   `.function = sgx_idle_timer_callback`. Workqueue
   `alloc_workqueue("sgx_idle", flags 0x12, max_active 1)` (`0xc0290324`),
   with work `sgx_idle_work_func`.

### 2.2 `SysFinalise` @ 0xc028fa80

1. `EnableSGXClocks`.
2. `OSInstallMISR`.
3. `OSInstallDeviceLISR(psSysData, irq, "SGX ISR", gpsSGXDevNode)`.
4. Map the regs again and read **`0x24` (EUR_CR_CORE_REVISION)**. Format it
   as "SGX revision = %u.%u.%u" (bits 23:16, 15:8, 7:0, `0xc028fb24..0xc028fb44`).
5. Unmap the regs, then `DisableSGXClocks`, then set `bSGXInitComplete=1`.

### 2.3 Interrupt glue (SGX_OCP_REGS_ENABLED + SGX_OCP_NO_INT_BYPASS)

| Function | VA | Register writes (offsets from the SGX reg base) |
|---|---|---|
| `SysEnableSGXInterrupts` | 0xc0290590 | if `(flags & 0x2002) == 0x2`: `0xFE38`(OCP_IRQSTATUS_2) ← 1, `0xFE44`(OCP_IRQENABLE_SET_2) ← 1; then set 0x2000 |
| `SysDisableSGXInterrupts` | 0xc02905ec | if 0x2000: `0xFE50`(OCP_IRQENABLE_CLR_2) ← 1; then clear 0x2000 |
| `SysClearInterrupts` | 0xc0290554 | `0xFE38` ← 1; read `0x134` (EUR_CR_EVENT_HOST_CLEAR, flush) via the devinfo reg base |
| `SysGetInterruptSource` | 0xc0290540 | returns `psDeviceNode->ui32SOCInterruptBit` (+0x78) |

A full scan of `0xc0272000..0xc029a000` for `#0xfeXX` immediates finds only
`0xfe38/0xfe44/0xfe50`, the DDK build number `0xfe3a`, and two OMAPLFB values.
**Nothing writes `0xFE10` (OCP SYSCONFIG) or `0xFF08` (OCP DEBUG_CONFIG).**
The hwmod (§3) owns SYSCONFIG.

### 2.4 Power state hooks

| Function | VA | Behaviour |
|---|---|---|
| `SysSystemPrePowerState(D3=3)` | 0xc0290630 | Trace "Entering state D3"; if LISR is installed, uninstall it (flag 0x200); if SYSCLOCKS, `DisableSystemClocks` (= `DisableSGXClocks`), flag 0x400 |
| `SysSystemPostPowerState(D0=0)` | 0xc029070c | Reverse order: `EnableSystemClocks`, reinstall LISR "SGX ISR" |
| `SysDevicePrePowerState(dev, new=OFF(2))` | 0xc0290820 | "SGX Entering state D3", then `DisableSGXClocks` |
| `SysDevicePostPowerState(dev, new, old=OFF(2))` | 0xc0290878 | "SGX Leaving state D3", then `EnableSGXClocks` |
| `PVRSRVDriverSuspend` / `Resume` | 0xc0276034 / 0xc0276004 | `PVRSRVSetPowerStateKM(3)` / `(0)` |

### 2.5 `EnableSGXClocks` @ 0xc0290d18 / `DisableSGXClocks` @ 0xc0290dec (source "sysutils_linux.c")

```
EnableSGXClocks:  if (sSGXClocksEnabled) return OK;
                  if (sgx_idle_mode == 0) RequestSGXFreq(psSysData, MAX);
                  __pm_runtime_resume(&pdev->dev, RPM_GET_PUT=4)   // pm_runtime_get_sync
                       -> fail: "pm_runtime_get_sync failed", return 0xAF
                  SysEnableSGXInterrupts(); sSGXClocksEnabled = 1; sgx_idle_log_on()
DisableSGXClocks: if (!sSGXClocksEnabled) return;
                  sgx_idle_log_off(); SysDisableSGXInterrupts();
                  __pm_runtime_idle(&pdev->dev, RPM_GET_PUT=4)      // pm_runtime_put_sync
                  if (sgx_idle_mode == 0) RequestSGXFreq(psSysData, MIN);
                  sSGXClocksEnabled = 0
```

The runtime-PM callbacks of the omap_device are `omap_gpu_latency[]` at
`0xc0705500`: `{0, 0, omap_device_idle_hwmods, 0, 0, omap_device_enable_hwmods,
flags=2}`. Flag 2 is presumably OMAP_DEVICE_LATENCY_AUTO_ADJUST. Runtime PM
therefore enables and idles the `gpu` hwmod: CLKCTRL MODULEMODE, SYSCONFIG and
the clock domain.

### 2.6 DVFS: `SysDvfsInitialize` @ 0xc0290f80 and `RequestSGXFreq` @ 0xc0290c28

- `SysDvfsInitialize` takes `rcu_read_lock`, then `n = opp_get_opp_count(&pdev->dev)`.
  It allocates `(n+1)*4` bytes and loops `opp_find_freq_ceil` from 0 to
  collect the frequencies. Then `list[n] = list[n-1]` (the last entry is
  duplicated), `size = n+1` and `index = n` (= max).
- `RequestSGXFreq(psSysData, bMax)`:
  - The target index is `bMax ? size-2 : 0`.
  - If it differs from the current index, it calls
    `pdata->device_scale(&pdev->dev, &pdev->dev, list[idx])` (pdata at
    `pdev->dev.platform_data` = `[pdev+0x5c]`; `device_scale` at pdata+8).
  - On `-EBUSY` or another error, the index is set to `size-1`.
  - **`pdata->ovfreqs` (pdata+0) is never read**, so stock uses the OV OPP
    (384 MHz) as "max".
- `SysGetSGXTimingInformation` @ 0xc0290bb0 fills the timing struct:

| Field | Value | Evidence |
|---|---|---|
| `ui32CoreClockSpeed` | `list[index]` | `0xc0290be4..0xc0290bec` |
| `ui32HWRecoveryFreq` | 100 | `mov r2,#0x64` |
| `bEnableActivePM` | 1 | |
| `ui32ActivePowManLatencyms` | `sgx_apm_latency` | |
| `ui32uKernelFreq` | 1000 | `mov r2,#0x3e8` |

### 2.7 Steelhead/Google add-on: `sgx_idle` (not in any public DDK tree examined)

Module parameters (`__param_*` at `0xc06ec8b4..0xc06ec8f4`, names `pvrsrvkm.*`
at `0xc058217c..0xc05821e8`) and their initial `.data` values:

| Parameter | Address | Initial value |
|---|---|---|
| `sgx_apm_latency` | 0xc0725b9c | **100** (ms) |
| `sgx_idle_timeout` | 0xc0725ba0 | **1 000 000** (ns) |
| `sgx_idle_mode` | 0xc0725ba4 | **2** |
| `sgx_idle_logging` | 0xc07822e0 (bss) | 0 |
| `gPVRDebugLevel` | — | — |

`SysSGXIdleTransition(bIdle)` @ 0xc029091c is called only from
`SGXTestActivePowerEvent` (`0xc0295b4c`, `0xc0295bb8`). That function watches
the host-control interrupt flag bit 0x4 (microkernel idle).

- **Busy (bIdle=0):** if mode≠0, `hrtimer_cancel` and `cancel_work_sync`, then
  `RequestSGXFreq(MAX)`. Record `ktime_get()` in `sgx_idle_last_busy`.
- **Idle (bIdle=1):**
  - mode 0: nothing. Frequency follows clock gating in
    Enable/DisableSGXClocks instead.
  - mode 1: `hrtimer_start(sgx_idle_timeout = 1 ms, REL)`.
  - mode 2 (default): if `now - last_busy ≤ 1 999 999 ns`, the timeout is
    `3 000 000 ns - delta`; otherwise it is `sgx_idle_timeout` (1 ms)
    (`0xc0290a08..0xc0290a44`).
- The timer queues `sgx_idle_work_func` (`0xc028fa54`), which calls
  `RequestSGXFreq(MIN)` (153.6 MHz).
- `sgx_idle_log_*` is a 0x2800-entry ring of (event, ktime). The events are
  1 idle, 2 busy, 3 flip (from `dsscomp_proxy_cmdcomplete`), 4 work, 5 cancel,
  6 clk off and 7 clk on. It is read through debugfs `sgx_idle`.

There are **no `sgxfreq*` symbols** (no onoff/activeidle/userspace/cool/
on3demand governors) in the stock kernel. TI's sgxfreq framework is a later
DDK 1.9+ OMAP addition.

### 2.8 SGX core power and timing (sgxpower.c, sgxinit.c, sgxreset.c)

- `SGXUpdateTimingInfo` @ 0xc0294da8 (DDK formulas):

| Quantity | Formula | Stock value |
|---|---|---|
| Host `SGXOSTimer` period | `50000 / uKernelFreq` ms (`movw r0,#0xc350`) | **50 ms** |
| `HWRecoverySampleRate` | uKernelFreq / HWRecoveryFreq | 10 |
| `uKernelTimerClock` | core / 1000 | 384 000 at 384 MHz; 307 200 at 307.2 MHz |
| `ActivePowManSampleRate` | uKernelFreq × latency / 1000 + 1 (`0x10624dd3` mul = /1000) | **101** |

- HW recovery: `HWRecoveryResetSGX` is called from `SGXOSTimer+0x11c` (lockup
  detector) and `SGX_MISRHandler+0x54`. SUPPORT_HW_RECOVERY is compiled in
  (build-option bit 3).
- `SGXReset` @ 0xc02954bc:
  - `EUR_CR_SOFT_RESET(0x80)` is written 0x3FFFF, then 0x3FFFE, then 0.
  - Each wait is `OSWaitus(100 000 000 / ui32CoreClockSpeed)`.
  - BIF: `0xC00` BIF_CTRL (INVALDC = 8), `0xC84` DIR_LIST_BASE0, `0xC04`
    INT_STAT, `0xC08` FAULT, and a `0xCA8` MEM_REQ_STAT poll with mask 0xFF.
  - There is a page-fault dummy-PD loop.
  - The **double write of `0xC84`** (`0xc0295698`, `0xc02956b4`) is the
    `FIX_HW_BRN_28011` block (letux 1.8 `sgxreset.c:141`).
- BRNs: DDK 1.8 `sgxerrata.h` gives SGX540 rev 120 = BRN 26620, 28011 and
  34028. 26620 and 34028 only take effect under `SGX_FEATURE_SYSTEM_CACHE`,
  which SGX540 lacks, so they produce no KM code. 28011 is present.
  Rev 101/110/121 share 28011, so the KM binary alone narrows the core rev to
  {101,110,120,121}. The rev-120 identity comes from the UM blob names
  (`*_SGX540_120.so`) and the letux Makefile `SGX_REV=120` for omap4.
  *(Refined 2026-10-11.)* The KM narrows further, to **{120,121}**: rev 101
  and 110 define `FIX_HW_BRN_25503`, which removes the
  `PVRSRV_MEM_EDM_PROTECT (0x40) → SGX_MMU_PTE_EDMPROTECT (0x10)` mapping in
  `MMU_MapPage` (letux 1.8 `mmu.c:2864`). Stock `MMU_MapPage` still has it:
  `tst r5,#0x40; orrne r7,r7,#0x10` at `0xc0296d48`/`0xc0296d50`. This
  assumes that stock 1.8@785978 has the same BRN conditional as letux
  1.8@869593 (same 1.8 branch). 120 and 121 cannot be told apart from the KM,
  because 26620 produces no SGX540 KM code.
- `SGXDevInitCompatCheck` @ 0xc0292f1c compiles in these constants:
  - KM build options **`0x0036801C`** (`movw/movt` at `0xc0292f58`,
    `0xc0293364`). Decoded with `include4/sgx_options.h`:

    | Bit | Value | Option |
    |---|---|---|
    | 2 | 0x4 | PVRSRV_USSE_EDM_STATUS_DEBUG |
    | 3 | 0x8 | SUPPORT_HW_RECOVERY |
    | 4 | 0x10 | PVR_SECURE_HANDLES |
    | 15 | 0x8000 | SUPPORT_ACTIVE_POWER_MANAGEMENT |
    | 17 | 0x20000 | SUPPORT_PERCONTEXT_PB |
    | 18 | 0x40000 | SUPPORT_SGX_HWPERF |
    | 20 | 0x100000 | SUPPORT_SGX_PRIORITY_SCHEDULING |
    | 21 | 0x200000 | SUPPORT_SGX_LOW_LATENCY_SCHEDULING |

  - DDK version **`0x00010812`** (1.8.18) and build **`0xBFE3A` = 785978**,
    both required to be *equal* to the microkernel's.
  - The core-rev exception pair `{0x10100, 0x10101}` (`0xc0293064..0xc02930a8`).
  - Its SGXMKIF structure-size checks are listed in the disassembly. The KM
    therefore holds no numeric SGX_CORE_REV. The compare is HW reg `0x24`
    against the microkernel's `ui32CoreRevSW`.
- The DDK identity string at `0xc0680738` is
  `CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978`.

### 2.9 Driver model (module.c)

- `PVRCore_Init` (initcall `0xc003cf54`): `platform_driver_register(&powervr_driver)`,
  `__register_chrdev(…,"pvrsrvkm", pvrsrv_fops)`, `class_create`,
  `device_create`. The interface is the **/dev/pvrsrvkm char device**, not DRM.
- `PVRSRVDriverProbe` @ 0xc0276114: `SysInitialise()` (skipped when
  `gpsSysData` is already set), then
  `ion_client_create(omap_ion_device, 0x14, "pvr")`. *(Corrected
  2026-10-11: the client name literal at `0xc02761d4` is `"pvr"`, not
  `"pvrsrvkm"`.)* On a NULL or `IS_ERR` result it prints
  "PVRSRVDriverProbe: Couldn't create ion client" (`0xc06805d4`) and returns
  the client value itself (`ldr r0,[r4,#28]` at `0xc02761bc`). An `ERR_PTR`
  therefore fails the probe, but a NULL would return 0 (success).

## 3. Stock OMAP4 platform data (arch/arm/mach-omap2)

### 3.1 `omap_init_gpu` @ 0xc0556ac0 ("arch/arm/mach-omap2/devices.c")

- It calls `omap_hwmod_lookup("gpu")` and `kzalloc(24)` (GFP 0x80d0 = zeroing)
  for `struct gpu_platform_data`:

| Offset | Field | Value |
|---|---|---|
| +0x00 | `ovfreqs` | **1 if `omap_rev()>>20 == 0x446`** (`0xc0556b80..0xc0556b9c`), else 0 |
| +0x04 | `set_min_bus_tput` | NULL |
| +0x08 | `device_scale` | `omap_device_scale` (0xc006f60c) |
| +0x0c | `device_enable` | `omap_device_enable` |
| +0x10 | `device_shutdown` | `omap_device_shutdown` |
| +0x14 | `device_idle` | `omap_device_idle` |

- Then `omap_device_build("pvrsrvkm", 0, oh, pdata, 0x18, omap_gpu_latency, 1, 0)`
  is called, so the device is `pvrsrvkm.0`.
- Then `platform_device_register(&omap_omaplfb_device)`.

### 3.2 hwmod `omap44xx_gpu_hwmod` @ 0xc0715264

| Field | Value | Evidence |
|---|---|---|
| name / class | "gpu" / `omap44xx_gpu_hwmod_class` → sysc `omap44xx_gpu_sysc` | 0xc0715264, 0xc071726c |
| mpu_irqs | **53** (= GIC SPI 21 + 32) | `omap44xx_gpu_irqs` @ 0xc0717280 = {name NULL, irq 53 at +4 = 0xc0717284} |
| prcm.omap4.clkctrl_reg | `0xfc009220` = PA **0x4A009220** (CM_GFX_GFX_CLKCTRL) | hwmod+0x1c |
| main_clk | "gpu_fck" | hwmod+0x2c |
| masters / slaves | `omap44xx_gpu__l3_main_2` (clk "l3_div_ck") / `omap44xx_l3_main_2__gpu` | 0xc0717c60, 0xc07181fc |
| addr space | **0x56000000–0x5600FFFF**, flags 2 (ADDR_TYPE_RT) | `omap44xx_gpu_addrs` 0xc0718d30 |
| sysc | rev_offs **0xFE00**, sysc_offs **0xFE10**, syss 0, sysc_flags **0x60** (SIDLEMODE\|MIDLEMODE), idlemodes **0xFF** (all four SIDLE and all four MSTANDBY modes), fields `omap_hwmod_sysc_type2` | 0xc07181ec..0xc07181f8 |
| other words | +0x60 = 1, +0x64 = 0x101, +0x6c = 0x1b900 (likely omap_chip / flags; not decoded) | — |

### 3.3 Clocks

- **`gpu_fck` @ 0xc07115a4** (struct clk, 3.0 layout):
  - ops `clkops_omap4_dflt_wait`
  - static parent **`dpll_core_m7x2_ck`**
  - enable_reg `0x4A009220`, enable_bit 1 (MODULEMODE = SWCTRL)
  - recalc `omap2_clksel_recalc`; init `omap2_init_clksel_parent` (reads the
    hardware mux at boot)
  - clksel_reg `0x4A009220`, mask **0x01000000** (bit 24 CLKSEL_SGX_FCLK)
  - clksel `sgx_clk_mux_sel` = {`dpll_core_m7x2_ck`/`div_1_0_rates`,
    `dpll_per_m7x2_ck`/`div_1_1_rates`}
  - clkdm "l3_gfx_clkdm"
  - **No set_rate/round_rate.** The rate changes on the parent divider.
- **Board override.** `omap4_steelhead_display_init` @ 0xc0075ef8 does
  `clk_get(NULL,"dpll_per_m7x2_ck")`, `clk_get(NULL,"gpu_fck")` and
  **`clk_set_parent(gpu_fck, dpll_per_m7x2_ck)`** (`0xc0075f40`). The error
  string is "failed to set gpu_fck to dpll_per_m7x2_ck" (0xc065a444).
  `gpu_fck`'s only other code reference is the hwmod.
- **Power domain.**
  - `gfx_44xx_pwrdm` @ 0xc070abc8: "gfx_pwrdm", voltdm "core", prcm offs
    `0x1200` (PRM_GFX). The remaining raw words (`0x000d1200`, `0x00010104`,
    `0x08000000`) are not decoded.
  - Debug descriptors `pd_sgx`/`cd_sgx`/`mod_sgx` ("PD_SGX"/"CD_SGX"/"SGX",
    clkctrl `0xfc009220`) at 0xc0707150/0xc0707bc8/0xc0708658.

### 3.4 OPP table for the GPU (`omap446x_opp_def_list` @ 0xc0043d5c)

Entry format: `{hwmod, voltdm, clk, freq, u_volt, default_available}`
(24 bytes).

| VA | hwmod | voltdm | clk | Freq | VDD_CORE | Available |
|---|---|---|---|---|---|---|
| 0xc0043e94 | gpu | core | dpll_per_m7x2_ck | **153 600 000** | **962 000 µV** | 1 |
| 0xc0043eac | gpu | core | dpll_per_m7x2_ck | **307 200 000** | **1 127 000 µV** | 1 |
| 0xc0043ec4 | gpu | core | dpll_per_m7x2_ck | **384 000 000** | **1 250 000 µV** | 1 |

For comparison, the same table holds L3 at 100 MHz@962 mV, 200 MHz@1127 mV
and 200 MHz@1250 mV. `omap443x_opp_def_list` @ 0xc0043bc4 has only the gpu
153.6 MHz and 307.2 MHz entries. The OPPs are registered with DVFS by
`omap_init_opp_table` (`omap_dvfs_register_device` caller at
`0xc0012a2c`). `omap_device_scale` (0xc006f60c) does
`opp_find_freq_ceil`, then `opp_get_voltage`, then `_add_freq_request`,
`_add_vdd_user` and `_dvfs_scale`. That raises VDD_CORE to the maximum
requested by all core users, then calls `clk_set_rate` on the OPP clock.

### 3.5 Bootloader clock setup (the 2026-07-12 lesson)

- **x-loader.** The DPLL configure routine is at file offsets `0x57e0..0x588c`.
  It writes M2..M7 to CLKMODE base+0x10..+0x24 and skips negative values.
  `struct dpll_params {u32 m; u32 n; s8 m2..m7;}` uses a 16-byte stride and is
  indexed by `CM_SYS_CLKSEL-1` (index 6 = 38.4 MHz).
  - **DPLL_PER** (base 0x4A008140, table VA 0x4030a7cc, file 0xaa2c, entry
    [6]): **M=20, N=0, M2=8, M3=6, M4=12, M5=9, M6=4, M7=5** → DCO×2 =
    2·20·38.4 = 1536 MHz, **`dpll_per_m7x2_ck` = 307.2 MHz**.
  - **DPLL_CORE** for a non-4430 part (`0x54b0` selects table 0x4030a83c
    unless the rev is 0x44300100/0x44300200; file 0xaa9c, entry [6]):
    **M=125, N=5, M2=1, M3=5, M4=8, M5=4, M6=6, M7=6** → DCO×2 =
    2·125/6·38.4 = 1600 MHz, **`dpll_core_m7x2_ck` = 266.67 MHz**.
- **Second-stage bootloader.** The byte-identical PER entry is at file 0x21f28
  and the CORE entry at file 0x21dd4.
- **CM_GFX.** Neither image references `0x4A009220`, `0x4A009200`,
  `0x4A008164` or `0x4A004144` as literals. Base 0x4A009000 is used for the
  `+0x400/+0x540/+0x548/+0x550` writes (L4PER clkstctrl, GPIO clkctrls;
  x-loader 0x5578..0x55d8, bootloader 0x1740..0x17a0). *(Corrected
  2026-10-11: these are not the only uses.)* A second load of the same base
  (x-loader literal at file 0x5cac, used from VA 0x40305800; bootloader
  literal at file 0x1e40, used from 0x1b5c) also does read-modify-write at
  `+0x470`, `+0x328`, `+0x330` and `+0x3e0` (L3INIT/L4PER clkctrls). No
  0x4A0092xx word occurs anywhere in either image (2-byte-aligned scan). No
  ARM or Thumb store with a `#0x220` offset uses a CM2 base. The only
  `#0x220` stores are fp/sp-relative (bootloader 0x1048 `str r4,[fp,#544]`,
  a stack struct).
  So **CLKSEL_SGX_FCLK (bit 24) is left at its reset value by both
  bootloaders.** The reset value itself (0 = CORE according to the static
  parent) is not verified against the TRM.

## 4. Mainline v6.18.48 and our DTS

- `omap4.dtsi:484-509`:
  ```
  sgx_module: target-module@56000000 {
      compatible = "ti,sysc-omap4", "ti,sysc";
      reg = <0x5600fe00 0x4>, <0x5600fe10 0x4>; reg-names = "rev", "sysc";
      ti,sysc-midle = <SYSC_IDLE_FORCE>, <SYSC_IDLE_NO>, <SYSC_IDLE_SMART>, <SYSC_IDLE_SMART_WKUP>;
      ti,sysc-sidle = (same four);
      power-domains = <&prm_gfx>;
      clocks = <&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 0>; clock-names = "fck";
      ranges = <0 0x56000000 0x2000000>;
      gpu@0 { compatible = "ti,omap4430-gpu", "img,powervr-sgx540";
              reg = <0x0 0x2000000>; interrupts = <GIC_SPI 21 IRQ_TYPE_LEVEL_HIGH>; };
  };
  ```
- `omap44xx-clocks.dtsi`:
  - `l3_gfx_cm@1200` → `l3_gfx_clkctrl: clk@20` (lines 1395-1408), i.e.
    0x4A009220.
  - `dpll_core_m7x2_ck@144` (line 367) and `dpll_per_m7x2_ck@164` (line 734)
    are `ti,divider-clock` with max-div 31. Nothing else consumes either
    output.
- `drivers/clk/ti/clk-44xx.c:327-340`: `omap4_sgx_clk_mux_parents =
  {dpll_core_m7x2_ck, dpll_per_m7x2_ck}` is a bit-24 TI_CLK_MUX on
  `OMAP4_GPU_CLKCTRL` (CLKF_SW_SUP). Line 763 adds the alias `sgx_clk_mux`.
- `omap443x.dtsi:78-86`, **for 4430 only**:
  ```
  /* Use dpll_per for sgx at 307.2MHz like droid4 stock v3.0.8 Android kernel */
  &sgx_module {
      assigned-clocks = <&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 24>, <&dpll_per_m7x2_ck>;
      assigned-clock-rates = <0>, <307200000>;
      assigned-clock-parents = <&dpll_per_m7x2_ck>;
  };
  ```
  `omap4460.dtsi` has no `sgx`/`gpu` lines, and neither does our
  `omap4-steelhead.dts`.
- `img,powervr-sgx.yaml`:
  - `ti,omap4430-gpu # Rev 120` + `img,powervr-sgx540`.
  - For non-am6548 parts `power-domains: false`; for non-sun6i/jz4780 parts
    `clocks: false`; `additionalProperties: false`.
  - So **an `operating-points-v2` on `gpu@0` would fail the binding**. Clock
    and power control belong on the parent target-module.
- No 6.18 driver binds `ti,omap4430-gpu` or `img,powervr-sgx540`
  (`grep -rn` over `drivers/` is empty).
- Our defconfig:
  - `CONFIG_TI_SYSC=y` (1436), `CONFIG_PM_GENERIC_DOMAINS(_OF)=y` (583, 586),
    `CONFIG_PM_OPP=y` (4896).
  - `# CONFIG_PM_DEVFREQ is not set` (4208).
  - `CONFIG_PREEMPT_NONE=y` (100), `CONFIG_HZ=100` (451).
  - `CONFIG_DRM_OMAP=y` (2869).
- Core voltage: patch `0027-ARM-OMAP4-stock-parity-vc-on-voltages-4460-core-vcore1.patch`
  defines `OMAP4_CORE_ON_VOLTAGE_UV 1200000` (patch line 75). There is no
  core OPP/DVFS in mainline OMAP4.

## 5. Letux glue (openpvrsgx @ d2f1e031)

- `drivers/gpu/drm/pvrsgx/Makefile:95` (top level): OMAP4430/60 is built with
  `SOC_VENDOR=ti SOC_FAMILY=omap SOC=omap4 SGX=sgx540 SGX_FLAG=SGX540
  SGX_REV=120 AM_VERSION=4`. The Makefile comments say only 1.14.3699939 and
  1.17.4948957 are "working".
- `pvr-drv.c` (the DRM front end, used for 1.14/1.17):
  - Match `ti,omap4430-gpu` → `pvr_omap4430 = {ocp_offset 0xfe00, quirks
    PVR_QUIRK_OMAP4, 540, 120}`.
  - Probe: `devm_platform_ioremap_resource(pdev,0)` maps **32 MiB**, then
    `pm_runtime_enable` + `pm_runtime_get_sync`.
  - `pvr_runtime_resume` writes `SGX_OCP_DEBUG_CONFIG(0x108) = BIT(31)`, then
    `IRQSTATUS_2 = 1` and `IRQENABLE_SET_2 = 1`.
  - `pvr_runtime_suspend` writes `IRQENABLE_CLR_2 = 1`.
- 1.17 `services4/system/omap`:
  - `sysconfig.h` → `AM_VERSION==4` → **`sysconfig-am4.h`**, which defines
    `VS_PRODUCT_NAME "TI437x"`, `SYS_SGX_CLOCK_SPEED 200000000`,
    `HWRECOVERY 50`, `PDS_TIMER 1000` and `ACTIVE_POWER_LATENCY_MS 2`.
  - `sysutils_linux.c:171-182` uses those values.
    `SYS_OMAP_HAS_DVFS_FRAMEWORK` is `ccflags-n` (1.17 Makefile:219), so
    sgxfreq is not built. `CONFIG_OMAP_SGX_FREQ` is not in Kconfig.
  - Clocks: `pm_runtime_get_sync` / `pm_runtime_put_autosuspend` (lines
    214, 260-261). `syslocal.h:106,114` defines `SGX_OCP_REGS_ENABLED` and
    `SGX_OCP_NO_INT_BYPASS`.
  - Build options: 1.17 Makefile lines 109-132 enable PERCONTEXT_PB,
    HW_RECOVERY, SECURE_HANDLES, SGX_HWPERF, LOW_LATENCY_SCHEDULING and
    ACTIVE_POWER_MANAGEMENT. `PVRSRV_USSE_EDM_STATUS_DEBUG` is `ccflags-n`
    (line 308).
- 1.8.869593 `services4/system/omap4` (Google/TI Android 1.8 layout, closest
  to stock):
  - `SYS_SGX_CLOCK_SPEED 307200000` for SGX540 rev 120, `HWRECOVERY 100`,
    `PDS 1000`, `APM 2`, `SGX_REGS 0x56000000/0xFFFF`, `IRQ 53`.
  - `EnableSGXClocks` = stock mode-0 behaviour (`device_scale` to
    `size-2`/0 around `pm_runtime_get/put_sync`, under
    `SYS_OMAP4_HAS_DVFS_FRAMEWORK`).
  - The in-tree Kbuild (1.8 Makefile) uses `SOC_FAMILY=omap`, but
    `1.8.869593/eurasia_km/services4/system/` contains only `include` and
    `omap4`, so as shipped it does not select the omap4 layer.
  - That Kbuild's options are HW_RECOVERY, SECURE_HANDLES, PERCONTEXT_PB,
    SGX_HWPERF and LOW_LATENCY_SCHEDULING (lines 96-130). LOW_LATENCY
    implies PRIORITY_SCHEDULING (`hwdefs/sgxfeaturedefs.h:242-243`), so a
    release build gives **0x00360018**. *(Corrected 2026-10-11; it was given
    as 0x00260018.)* A `CONFIG_SGX_DEBUG` build adds bit 0 (`-DDEBUG`,
    Makefile:146). ACTIVE_PM is only set for sgx544/jz4780 (lines 218, 226),
    and EDM_STATUS_DEBUG is `ccflags-n`.
- 1.14.3699939 `services4/system/omap` *(added 2026-10-11)*:
  - There is no `sysconfig-am4.h`. `sysinfo.h` gives
    `SYS_SGX_CLOCK_SPEED 200000000` for every `AM_VERSION` except 5.
  - `sysconfig.h:57` sets HWRECOVERY to 100 Hz; `:62` sets APM latency to
    2 ms.
  - ACTIVE_PM is defined only for sgx544/jz4780 (Makefile 217, 225), so for
    SGX540 `bEnableActivePM` is false.
- Commit `0affbb5a7` "ARM: omap2plus_defconfig: PVR/SGX build now needs
  CONFIG_PREEMPT=y or CONFIG_PREEMPT_VOLUNTARY=y".

## 6. Parity table

`PARITY: 12 match, 11 mismatch, 4 missing, 1 extra, 3 unknown`

"Mainline" means v6.18.48 DT/clock data + our DTS/defconfig. "Letux" means the
openpvrsgx glue (1.17/1.14 `omap`, 1.8 `omap4` noted where it differs). There
was no live column; the device was not touched.

| # | Item | Stock (evidence) | Mainline / letux (evidence) | Verdict | Why it matters / what to add |
|---|---|---|---|---|---|
| 1 | Register base | 0x56000000 (hwmod addrs 0xc0718d30; "SGX register base" trace) | target-module `ranges <0 0x56000000 …>`, gpu@0 reg 0 | MATCH | — |
| 2 | Register window size | 64 KiB (0x5600FFFF end; mapped 0xFFFF) | 32 MiB (`reg = <0x0 0x2000000>`); letux ioremaps all of resource 0 (pvr-drv.c:433) | MISMATCH | Benign functionally. 32 MiB of ioremap/vmalloc space on a 1 GiB lowmem system. Optional: no change needed. |
| 3 | IRQ | Linux irq 53 = GIC SPI 21 (0xc0717284) | `GIC_SPI 21 IRQ_TYPE_LEVEL_HIGH` | MATCH | — |
| 4 | OCP sysc regs / idle modes | rev 0xFE00, sysc 0xFE10, SIDLE+MIDLE, idlemodes 0xFF, type2 (0xc07181ec) | `reg 0x5600fe00/0x5600fe10`, midle/sidle force/no/smart/smart-wkup | MATCH | — |
| 5 | Module clkctrl | CM_GFX_GFX_CLKCTRL 0x4A009220, MODULEMODE SW (gpu_fck enable_bit 1) | `l3_gfx_clkctrl` clk@20 in cm@1200, CLKF_SW_SUP (clk-44xx.c:339) | MATCH | — |
| 6 | Power domain | gfx_pwrdm, voltdm core, PRM 0x1200 (0xc070abc8) | `power-domains = <&prm_gfx>` (prm@1200); legacy pwrdm PWRSTS_OFF_ON | MATCH | omap_prm GFX instance data not verified (tree partial). |
| 7 | SGX functional clock source (mux bit 24) | **dpll_per_m7x2_ck**, set by board code `clk_set_parent` @0xc0075f40 | 4460/steelhead: **no assignment** (only omap443x.dtsi:81-86) → bootloader/reset value, presumably CORE (*corrected 2026-10-11:* measured CORE, `dpll_core_m7x2_ck` → `l3-gfx-clkctrl:0000:24` at 266666667, `nq-captures/20261010-185940/snapshot.txt:467-470` [re §12.1 row 12]) | **MISMATCH** | GPU would run from DPLL_CORE M7 = 266.67 MHz instead of PER 307.2 MHz, and a later DVFS on `dpll_per_m7x2_ck` would not reach it. **Add the 443x `&sgx_module` assigned-clocks block to omap4-steelhead.dts.** |
| 8 | Boot rate of dpll_per_m7x2_ck | 307.2 MHz (x-loader + bootloader PER M7=5; §3.5) | divider clock inherits HW; 443x block would assert 307200000 | MATCH | Make it explicit via `assigned-clock-rates`. |
| 9 | GPU OPP table | 153.6 MHz@962 mV, 307.2@1127, 384@1250 on vdd core (0xc0043e94..) | none; binding forbids clocks/OPP on ti gpu node; `PM_DEVFREQ` off | **MISSING** | No GPU DVFS. Keep a fixed 307.2 MHz until a core-voltage-aware scheme exists. A devfreq table would have to live in a driver or on the target-module (binding extension). |
| 10 | VDD_CORE scaling coupled to GPU OPP | omap_device_scale → `_dvfs_scale` raises vdd_core (0xc006f60c..) | static; VC ON 1.200 V (patch 0027) | **MISSING** | 384 MHz needs 1.25 V. **Never select 384 MHz on our kernel.** 307.2 MHz needs 1.127 V. That is ≤ the 1.2 V VC ON target, but the runtime VDD_CORE is unmeasured (#30), so 307.2 MHz is safe only once VDD_CORE ≥ 1.127 V is confirmed live. |
| 11 | DVFS policy | sgx_idle mode 2: idle → 153.6 MHz after (3 ms − busy delta) or 1 ms; busy → max immediately (§2.7) | letux: sgxfreq compiled out (`ccflags-n SYS_OMAP_HAS_DVFS_FRAMEWORK`); fixed clock | MISSING | Power/thermal only. Optional later: a simple idle-downclock in the glue using `clk_set_rate(dpll_per_m7x2_ck)` 307.2 ↔ 153.6 (both ≤ 1.127 V). |
| 12 | sgxfreq governors (onoff/activeidle/userspace/cool) | **absent** in stock (no symbols) | present in letux source but not built | MATCH | Both effectively have none. |
| 13 | Core clock reported to the ukernel | current OPP freq (`list[index]`, 0xc0290be4) | letux 1.17 OMAP4: **200 MHz** (sysconfig-am4.h, AM437x values); letux 1.14 OMAP4: 200 MHz (sysinfo.h); letux 1.8 omap4: 307.2 MHz | **MISMATCH** | The ukernel timer tick and APM/HWR timeouts scale with it. At 200 MHz reported against 266.7/307.2 MHz actual, the 1 kHz tick runs about 1.33–1.54× fast. **Override `SYS_SGX_CLOCK_SPEED` to 307200000 for OMAP4**, or better, read `clk_get_rate()` of the module fck. |
| 14 | HW recovery frequency | 100 Hz (0xc0290bf0) | letux 1.17 am4: 50 Hz; 1.14 omap: 100 Hz; 1.8 omap4: 100 Hz | MISMATCH (1.17 only) | Lockup detection cadence. Set 100 for OMAP4. |
| 15 | ukernel timer freq | 1000 Hz | 1000 Hz (all letux layers) | MATCH | — |
| 16 | Active power management | enabled, latency `sgx_apm_latency` = 100 ms → sample rate 101 | 1.17: enabled, 2 ms; 1.14 and 1.8 Kbuild: disabled for SGX540 | MISMATCH | 2 ms APM makes the GPU power-cycle constantly (each cycle is ukernel save/restore + pm_runtime). Stock chose 100 ms. Pass `-DSYS_SGX_ACTIVE_POWER_LATENCY_MS=100`. |
| 17 | pm_runtime coupling | `pm_runtime_get_sync` / `put_sync` around clock enable; omap_device enable/idle hwmods | `get_sync` / `put_autosuspend` + ti-sysc | MATCH | Functionally equivalent. ti-sysc replaces hwmod. *Corrected 2026-10-11:* at the sysconfig layer only; the letux glue `pvr_probe()` takes a `pm_runtime_get_sync()` that is dropped only on error and in `pvr_remove()` (`pvr-drv.c:440-441, 476, 488` at `d2f1e031`), so GFX stays ON while bound [pm TL;DR 8, kdp §8 d; re §12.1 row 13]. |
| 18 | OCP IRQ path | NO_INT_BYPASS: IRQSTATUS_2 / IRQENABLE_SET_2 / CLR_2 only; never DEBUG_CONFIG 0xFF08 | pvr-drv `pvr_runtime_resume` sets **DEBUG_CONFIG = BIT(31) (THALIA_INT_BYPASS)** too | **MISMATCH** | Bypass routes the core IRQ around the OCP wrapper while the wrapper IRQ is also enabled. Stock never did this. If spurious, lost or double IRQs show up, drop the BIT(31) write for the OMAP4 quirk. |
| 19 | OCP SYSCONFIG ownership | hwmod only (driver never writes 0xFE10) | ti-sysc only | MATCH | — |
| 20 | Platform data / device_scale hook | `gpu_platform_data` {ovfreqs=1 on 4460, device_scale=omap_device_scale, …} (0xc0556b54..) | none (DT only) | MISSING | No DVFS hook. Only needed if DVFS is reintroduced. `ovfreqs` was ignored by stock anyway. |
| 21 | Device binding | omap_device "pvrsrvkm".0 from hwmod "gpu" | `ti,omap4430-gpu` matched by letux pvr-drv (build `ti_omap4_sgx540_120`) | MATCH | — |
| 22 | UM interface | `/dev/pvrsrvkm` char device + ION client at probe (0xc0276144) | letux 1.14/1.17: DRM "pvr" ioctls; no ION in mainline | MISMATCH | The stock bionic UM expects `/dev/pvrsrvkm` and ION-backed gralloc. That is a separate workstream (bridge/UM pairing). |
| 23 | DDK version/build gate | ukernel must be 0x10812 **and** build 785978 (0xc0292ff4..0xc0293034) | letux 1.8 = 869593; 1.14/1.17 different | MISMATCH | Stock IAN67K `pvrsrvinit`/microkernel will be refused ("Incompatible driver DDK revision"). The KM must be built as 1.8.18 build 785978, or the UM must come from the matching DDK. |
| 24 | KM build options | **0x0036801C** (0xc0292f58) | letux 1.8 Kbuild ⇒ **0x00360018** (missing 0x8004; PRIORITY_SCHEDULING is implied by LOW_LATENCY, sgxfeaturedefs.h:242-243) *(corrected 2026-10-11)* | MISMATCH | "Mismatch in client-side and KM driver build options". Add `-DPVRSRV_USSE_EDM_STATUS_DEBUG -DSUPPORT_ACTIVE_POWER_MANAGEMENT` when pairing with stock UM. `SUPPORT_SGX_PRIORITY_SCHEDULING` is already set. |
| 25 | SGX core rev compiled for | not in KM; BRN28011 double DIR_LIST_BASE0 write present (0xc0295698/0xc02956b4); EDMPROTECT PTE mapping present (no BRN25503, 0xc0296d48) ⇒ rev ∈ {120,121}; UM blobs `_SGX540_120` | `SGX_REV=120` (Makefile:95) | MATCH | — |
| 26 | Kernel preemption model | "SMP PREEMPT" (0xc055f4b0) | `CONFIG_PREEMPT_NONE=y`; letux 0affbb5a7 says PREEMPT or PREEMPT_VOLUNTARY is required | MISMATCH | The DDK's locking assumes preemption points (*refined 2026-10-11 [kdp Addendum B.2]:* no; its busy-waits have no scheduling point under any model, and every wait on a workqueue sleeps; the requirement is IMG's blanket `#error`) (UNVERIFIED reasoning: the letux commit body gives no reason, and the pvrsgx Kconfig has no PREEMPT dependency, so nothing enforces it; *corrected 2026-10-11:* wrong, the build enforces it: `eurasia_km/Makefile:124,238` define `PVR_LINUX_USING_WORKQUEUES` and `services4/srvkm/env/linux/osfunc.c:126-135` stops with `#error "A preemptible Linux kernel is required when using workqueues"` unless `CONFIG_PREEMPTION` or `CONFIG_PREEMPT_VOLUNTARY`, at `d2f1e031` [kdp TL;DR 8; re §12.1 row 11]). Needs `CONFIG_PREEMPT_VOLUNTARY=y` (or PREEMPT) in steelhead_defconfig before building pvrsrvkm. Re-check audio latency after the change. |
| 27 | Tick rate | HZ=128 | `CONFIG_HZ=100` | MISMATCH | Minor: `OSAddTimer` 50 ms rounds to 5 jiffies instead of 6.4. No action. |
| 28 | Steelhead `sgx_idle` params/debugfs | `sgx_apm_latency=100`, `sgx_idle_timeout=1 ms`, `sgx_idle_mode=2`, `sgx_idle_logging`, debugfs `sgx_idle` | absent | EXTRA (stock-only) | Not required for function. Port only the 100 ms APM value (#16). |
| 29 | Reset value of CLKSEL_SGX_FCLK on this unit | — (bootloaders do not write it; static parent suggests CORE) | — | UNKNOWN (*answered 2026-10-11 for the live value:* CORE, 266666667 on 6.18.48-r20, `nq-captures/20261010-185940/snapshot.txt:467-470` [re §12.1 row 12]; it equals the reset value only if nothing wrote bit 24 since reset, which §3.5 and the missing 4460 DT assignment suggest) | Confirm with a live read of `0x4A009220` bit 24, or `/sys/kernel/debug/clk/clk_summary` for `l3-gfx-clkctrl:0000:24`. |
| 30 | Actual VDD_CORE at runtime on our kernel | 0.962–1.25 V per OPP | ON value 1.2 V (never sent); runtime value expected 1.139 V (x-loader vsel 0x23), not measured | UNKNOWN | Read TWL6030 VCORE1 VSEL live (`i2cget -y -f <bus> 0x48 0x55`, `nexusq-gpu-probe.sh --pmic`) before raising the GPU clock [pm Addendum "Live VDD_CORE without a device"]. |
| 31 | `omap_prm` GFX instance (reset/pwrst) in 6.18 | stock pwrdm gfx | DT `prm_gfx` present; source not in the partial tree | UNKNOWN | Check `drivers/soc/ti/omap_prm.c` for an omap4 "gfx" entry; letux's `omap-sysc-prm-gfx` branch suggests it is upstream. |

Count:

- MATCH: #1, 3, 4, 5, 6, 8, 12, 15, 17, 19, 21, 25 (12)
- MISMATCH: #2, 7, 13, 14, 16, 18, 22, 23, 24, 26, 27 (11)
- MISSING: #9, 10, 11, 20 (4)
- EXTRA: #28 (1)
- UNKNOWN: #29–31 (3)

## 7. Recommendations, ordered by impact (recommendations only, nothing edited)

1. **GPU clock source and rate (DTS, one hunk).** In
   `kernel/dts/omap4-steelhead.dts`, matching stock board code and the 443x
   precedent:
   ```
   /* stock: omap4_steelhead_display_init clk_set_parent(gpu_fck, dpll_per_m7x2_ck);
      x-loader/bootloader lock DPLL_PER M7=5 -> 307.2 MHz */
   &sgx_module {
       assigned-clocks = <&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 24>, <&dpll_per_m7x2_ck>;
       assigned-clock-rates = <0>, <307200000>;
       assigned-clock-parents = <&dpll_per_m7x2_ck>;
   };
   ```
2. **Do not exceed 307.2 MHz** while VDD_CORE is static at 1.2 V. 384 MHz
   needs 1.25 V (stock OPP @0xc0043ed4).
3. **Timing values in the glue** (letux 1.17/1.14 `omap`, AM_VERSION=4):
   - Replace the AM437x header values for OMAP4 with `SYS_SGX_CLOCK_SPEED
     307200000` (or `clk_get_rate` of the parent fck), `HWRECOVERY 100` and
     `SYS_SGX_ACTIVE_POWER_LATENCY_MS 100`.
   - If 1.8 is used instead, port `services4/system/omap4` with the same
     values and `SUPPORT_ACTIVE_POWER_MANAGEMENT`.
4. **Preemption.** Set `CONFIG_PREEMPT_VOLUNTARY=y` in `steelhead_defconfig`
   when pvrsrvkm is added (letux 0affbb5a7; stock was PREEMPT). *Superseded
   2026-10-11 [kdp Addendum B.4]:* `CONFIG_PREEMPT=y` if the host build fits the
   boot image, VOLUNTARY only as the fallback. Re-check
   audio XRUNs.
5. **OCP IRQ.** For `PVR_QUIRK_OMAP4`, match stock and do not set
   `SGX_OCP_DEBUG_CONFIG` BIT(31). Keep the IRQSTATUS_2/IRQENABLE_SET_2/CLR_2
   sequence. Do this only if IRQ anomalies appear; letux reports working
   OMAP4 setups with the bypass bit (not verified here).
6. **For stock-UM pairing** (feeds the KM/UM workstream): the KM must report
   DDK 1.8.18 build **785978** and build options **0x0036801C**. Letux 1.8
   (869593, 0x00360018, missing EDM_STATUS_DEBUG and ACTIVE_PM) needs both
   changed and an omap4 system-layer
   selection fix (its Kbuild points at a non-existent `system/omap`).
7. **Optional later: idle down-clock.** Mimic `sgx_idle` with 307.2 ↔ 153.6
   MHz (both within 1.127 V) via `clk_set_rate(dpll_per_m7x2_ck)` from
   `SysSGXIdleEntered` / `SysSGXCommandPending` hooks. Full 3-OPP DVFS needs
   core-voltage scaling, which mainline OMAP4 lacks.

## Open questions

- What is the reset or as-booted value of CM_GFX_GFX_CLKCTRL bit 24 on this
  unit, and therefore the actual mainline GPU rate today? Neither bootloader
  writes it; this needs a live read or the TRM.
- What is VDD_CORE at runtime on our kernel (TWL6030 VCORE1 VSEL)? The ON
  value is 1.2 V. Is a 307.2 MHz GPU plus L3 at 200 MHz fully covered?
- Does mainline 6.18 `omap_prm` have the OMAP4 "gfx" instance with pwrst
  control? The partial source tree lacks `drivers/soc/ti/omap_prm.c`.
- The hwmod words at +0x60/+0x64/+0x6c (1, 0x101, 0x1b900) and the gfx_pwrdm
  raw words (`0x000d1200`, `0x00010104`, `0x08000000`) are not decoded. Did
  stock allow GFX INACTIVE/RET states that mainline's PWRSTS_OFF_ON does not?
  *Answered 2026-10-11 for `pwrsts`:* 0x0d = OFF | INACTIVE | ON, no RET
  [pm §1.2; re §12.1 row 10]. The other words stay undecoded.
- Does letux's THALIA_INT_BYPASS write misbehave on OMAP4460 in practice?
  This needs a test once a KM exists.
- `SGX_FEATURE`-level ukernel options (e.g. `SGX_FAST_DPM_INIT`) and the
  SGXMKIF struct sizes the stock ukernel expects are covered by the
  srvinit/UM workstream, not here.
- Is the Google `sgx_idle` code available as source (e.g. an
  `android-omap-steelhead-3.0` branch)? It was not searched; no web tools
  were available in this run.

## Sources

- `reverse-eng/vmlinux.bin` + `reverse-eng/tools/kallsyms.txt`. Disassembly
  via `reverse-eng/tools/nqdis.py`, data via `dump.py`, call sites via
  `callers.py` (capstone 5.0.7). Functions:
  - System layer: `SysInitialise` 0xc028fef4, `SysFinalise` 0xc028fa80,
    `SysDeinitialise` 0xc028fc4c, `SysGetDeviceMemoryMap` 0xc0290478,
    `SysEnable/DisableSGXInterrupts` 0xc0290590/0xc02905ec,
    `SysClearInterrupts` 0xc0290554, `SysSystemPre/PostPowerState`
    0xc0290630/0xc029070c, `SysDevicePre/PostPowerState`
    0xc0290820/0xc0290878.
  - DVFS and idle: `SysSGXIdleTransition` 0xc029091c,
    `SysGetSGXTimingInformation` 0xc0290bb0, `RequestSGXFreq` 0xc0290c28,
    `Enable/DisableSGXClocks` 0xc0290d18/0xc0290dec,
    `EnableSystemClocks` 0xc0290eb0, `SysPMRuntimeRegister` 0xc0290f2c,
    `SysDvfsInitialize` 0xc0290f80, `sgx_idle_*` 0xc028f668..0xc028fa54.
  - SGX core: `SGXDevInitCompatCheck` 0xc0292f1c, `SGXUpdateTimingInfo`
    0xc0294da8, `SGXPre/PostPowerState` 0xc0294f40/0xc0295154,
    `SGXReset` 0xc02954bc, `SGXTestActivePowerEvent` 0xc0295ae8.
  - Driver model: `PVRSRVDriverProbe` 0xc0276114, `PVRCore_Init` 0xc0025920.
  - Platform data: `omap_init_gpu` 0xc0556ac0,
    `omap4_steelhead_display_init` 0xc0075ef8, `omap_device_scale` 0xc006f60c.
  - Data: `omap446x_opp_def_list` 0xc0043d5c, `omap443x_opp_def_list`
    0xc0043bc4, `omap44xx_gpu_hwmod` 0xc0715264, `gpu_fck` 0xc07115a4,
    `sgx_clk_mux_sel` 0xc05636b8, `omap_gpu_latency` 0xc0705500,
    `gfx_44xx_pwrdm` 0xc070abc8, and the DDK string at 0xc0680738.
- `reverse-eng/factory/tungsten-ian67k/xloader-phantasm-ian67k.img`
  (base 0x402FFE00; DPLL routine file 0x57e0; PER table file 0xaa2c; CORE
  file 0xaa9c) and `bootloader-phantasm-steelheadb4h0j.img` (PER file
  0x21f28, CORE file 0x21dd4). Decoded with capstone and Python `-I`.
- Mainline v6.18.48 tree (scratch, `Makefile` 6.18.48):
  `arch/arm/boot/dts/ti/omap/omap4.dtsi:484-509`,
  `omap443x.dtsi:78-86`, `omap4460.dtsi`, `omap44xx-clocks.dtsi:367,734,1395-1408`,
  `drivers/clk/ti/clk-44xx.c:327-340,763`,
  `Documentation/devicetree/bindings/gpu/img,powervr-sgx.yaml`,
  `arch/arm/mach-omap2/powerdomains44xx_data.c:57-71`, `prm44xx.h:45`.
- Letux: https://github.com/openpvrsgx-devgroup/linux_openpvrsgx (and
  https://git.goldelico.com/letux-kernel.git as remote `letux`), local
  clone HEAD `d2f1e031d58aca97bc4b62367f0d7bef4a7559c3` (pvrsrvkm-6.18-rc6).
  Files:
  - `drivers/gpu/drm/pvrsgx/{Makefile,Kconfig,pvr-drv.c,pvr-drv.h}`
  - `1.17.4948957/eurasia_km/{Makefile,services4/system/omap/{sysconfig.h,sysconfig-am4.h,sysconfig.c,sysutils_linux.c,syslocal.h}}`
  - `1.14.3699939/eurasia_km/Makefile`
  - `1.8.869593/eurasia_km/{Makefile,include4/sgx_options.h,services4/srvkm/hwdefs/ocpdefs.h,services4/srvkm/devices/sgx/{sgxinit.c,sgxreset.c},services4/system/omap4/{sysconfig.h,sysconfig.c,sysutils_linux.c,syslocal.h,sysinfo.h}}`
  - The errata header `sgxerrata.h` (1.8)
  - Commit 0affbb5a7 (defconfig PREEMPT note)
  - `git diff --name-status 6a23ae0a d2f1e031 -- arch drivers/bus drivers/soc drivers/clk Documentation include mm`
- Repo: `kernel/dts/omap4-steelhead.dts` (line 29 includes omap4460.dtsi;
  no GPU nodes), `kernel/configs/steelhead_defconfig` (lines 100, 451, 583,
  586, 1436, 2869, 4208, 4896),
  `kernel/patches/0027-ARM-OMAP4-stock-parity-vc-on-voltages-4460-core-vcore1.patch`
  (line 75), `docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §1.

## Verification (2026-10-11)

An adversarial re-check of the 20 key claims. Everything was re-derived
independently:

- The capstone-based `reverse-eng/tools/nqdis.py` cannot run on this host
  (no `capstone` Python module), so stock code was disassembled with
  `arm-none-eabi-objdump -D -b binary -m arm --adjust-vma=0xc0008000`.
- Symbols come from `reverse-eng/tools/kallsyms.txt`.
- Data words were read with a Python `-I` reader of `vmlinux.bin`.
- The bootloaders were disassembled with `--adjust-vma=0x402FFE00`
  (x-loader) and as raw ARM and forced Thumb.
- Source was re-read in the scratch v6.18.48 tree and the openpvrsgx clone
  at `d2f1e031d58aca97bc4b62367f0d7bef4a7559c3`.
- Helper scripts are in `<session scratch>/gpu/re/tmp/rv04/` (`d.sh`, `m.py`,
  `callers.py`).

### Reproduced as stated

| # | Claim | Re-check evidence |
|---|---|---|
| 1 | Board code sets the gpu_fck parent to dpll_per_m7x2_ck | `0xc0075f08 ldr r1,=0xc0654328 'dpll_per_m7x2_ck'` → `bl clk_get` (r4). `0xc0075f24 ldr r1,=0xc0658c1c 'gpu_fck'` → `bl clk_get` (r0=r5). `0xc0075f3c mov r1,r4; 0xc0075f40 bl clk_set_parent` (= `clk_set_parent(gpu_fck, dpll_per_m7x2_ck)`). Error string at 0xc065a444. `gpu_fck`+0x10 = 0xc070ccc4 `dpll_core_m7x2_ck`; +0x40 clksel_reg 0xfc009220; +0x44 mask 0x01000000; +0x48 `sgx_clk_mux_sel` 0xc05636b8 = {core_m7x2/div_1_0_rates, per_m7x2/div_1_1_rates}. |
| 2 | DPLL params | x-loader file 0xaa2c = `14 00 00 00 00 00 00 00 08 06 0c 09 04 05` (M=20 N=0 M2..M7=8,6,12,9,4,5). File 0xaa9c = M=125 N=5 M2..M7=1,5,8,4,6,6. Bootloader 0x21f28 and 0x21dd4 are byte-identical. The routine at VA 0x403055e0 writes the `ldrsb [r5,#8..#13]` values to `[r4,#0x10..#0x24]`, skipping negatives. Caller: PER table 0x4030a7cc with base 0x4a008140 (literals at file 0x5cd8/0x5cdc). CORE table chooser at VA 0x403052b0: rev 0x44300200 or -1 → 0x4030a75c; 0x44300100 → 0x4030a6ec; otherwise 0x4030a83c. Entry [0] of the PER table is M=64 for 12 MHz, consistent with index 6 = 38.4 MHz. |
| 4 | Mainline/letux DT has no SGX clock assignment for 4460 | `omap443x.dtsi` holds the `&sgx_module` per@307.2 MHz block. `omap4460.dtsi` has no sgx/gpu lines. `kernel/dts/omap4-steelhead.dts` greps empty and includes `omap4460.dtsi` at line 29. `omap4.dtsi`, `omap443x.dtsi`, `omap4460.dtsi`, `omap446x-clocks.dtsi` and `omap44xx-clocks.dtsi` are identical between letux d2f1e031 and v6.18.48 (`diff -q`). |
| 5 | GPU OPPs | Decoded all of `omap446x_opp_def_list`: gpu/core/dpll_per_m7x2_ck at 153.6 MHz/962 mV, 307.2 MHz/1127 mV and 384 MHz/1250 mV, all with default_available=1, at 0xc0043e94/eac/ec4. The only `opp_disable` caller is `omap_init_opp_table+0x174`. |
| 7 | Binding | `img,powervr-sgx.yaml`: `power-domains: false` unless am6548; `clocks/clock-names: false` unless sun6i/jz4780; `additionalProperties: false`. This is a schema/`dtbs_check` restriction; dtc and the kernel would not reject such a node at runtime. |
| 8 | Timing info | `SysGetSGXTimingInformation`: +0 = `list[idx]` (0xc0290be4..bec), +4 = 100, +8 = 1, +0xc = `[sgx_apm_latency]`, +0x10 = 1000. `.data` 0xc0725b9c = 0x64. `SGXUpdateTimingInfo`: `OSAddTimer(SGXOSTimer, …, 50000/uKernelFreq)` (0xc0294e08); APM rate = latency×freq/1000+1 (`0x10624dd3` umull, `lsr #6`, `+1` at 0xc0294e98..eac). |
| 9 (1.17) | AM437x values | `sysconfig.h:50-51` (AM_VERSION 4 → `sysconfig-am4.h`); `sysconfig-am4.h:66` "TI437x", `:68` 50 Hz, `:69` 200000000, `:73` 2 ms. 1.17 Makefile:304 `-DSYS_SGX_ACTIVE_POWER_LATENCY_MS=100` is under `ccflags-n`, so it is not applied. |
| 10 | sgx_idle mode 2 | `SysSGXIdleTransition` idle path: mode≠2 → `hrtimer_start(&sgx_idle_timer, sgx_idle_timeout, HRTIMER_MODE_REL=1)`. Mode 2: `delta = ktime_get() − sgx_idle_last_busy`; if `delta ≤ 0x1e847f` (1 999 999) the timeout is `0x2dc000+0x6c0 − delta` = 3 000 000 − delta (0xc0290a2c..a44). Busy path: `hrtimer_cancel`, `cancel_work_sync`, `RequestSGXFreq(…,1)`. `sgx_idle_work_func` → `RequestSGXFreq(gpsSysData, 0)`. The only kallsyms match for `sgxfreq` (case-insensitive) is `RequestSGXFreq`. |
| 11 | RequestSGXFreq / ovfreqs | `subne r5,r5,#2` (0xc0290c50); `device_scale` = `[[pdev+0x5c]+8]` called via `blx r3`; pdata+0 is never loaded. `SysDvfsInitialize` stores `list[n] = list[n-1]`, size n+1, index n. `omap_init_gpu` 0xc0556b7c..b9c: `omap_rev()>>20 == 0x446` → `[pdata]=1`. |
| 12 | Register/IRQ/sysc parity | `omap44xx_gpu_addrs` {0, 0x56000000, 0x5600ffff, flags 2}. `omap44xx_gpu_irqs` is at **0xc0717280** (irq field at +4 = 53). sysc words `0xfe10fe00`, `0x00600000`, `0x00ff0000`, `omap_hwmod_sysc_type2`. hwmod+0x1c = 0xfc009220, +0x2c = 'gpu_fck'. `gfx_44xx_pwrdm` {'gfx_pwrdm', 'core', …, 0x000d1200}. Mainline `omap4.dtsi:484-509`, `l3_gfx_cm@1200`/`clk@20`, and `clk-44xx.c` bit-24 mux {core, per} all match. |
| 13 | OCP IRQ writes | `SysClearInterrupts`/`SysEnableSGXInterrupts`/`SysDisableSGXInterrupts` write only 0xfe38, 0xfe38+0xfe44, and 0xfe50. A `movw` scan of 0xc0272000..0xc029a000 finds 0xfe0c/0xfe0e (`ProcessFlipV1`+0xac/+0xbc), 0xfe38×2, 0xfe3a×3 (build number), 0xfe44, 0xfe50, and no 0xfe10 or 0xff08 literal word. Letux `pvr_runtime_resume` (`pvr-drv.c:227-240`) writes `BIT(31)` to `SGX_OCP_DEBUG_CONFIG` (0x108). In the DDK, that bit (`EUR_CR_OCP_DEBUG_CONFIG_THALIA_INT_BYPASS_MASK`, `ocpdefs.h:179`) is written only on the `!SGX_OCP_NO_INT_BYPASS` path (`1.8 omap4/sysconfig.c:71-76`), i.e. instead of the IRQSTATUS_2/ENABLE_2 path, never together with it. |
| 14 | Compat gate | `movw/movt 0x36801c` at 0xc0292f58/5c and 0xc0293364/68. The first is compared with the client-side options `[devinfo+0xa4]` (any XOR difference → error 26). `0x10812` vs misc-info +0xc (DDK version) at 0xc0292ff4; `0xbfe3a` vs +0x10 (build) at 0xc0293028. Messages at 0xc029340c ("Incompatible driver DDK revision"). DDK string at 0xc0680738 = `CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978`. The bit decode matches letux 1.8 `include4/sgx_options.h` (bit 4 = `PVR_SECURE_HANDLES`/SID, bits 20/21 = priority/low-latency). |
| 16 | 1.8 system dir | `git ls-tree -d d2f1e031 …/1.8.869593/eurasia_km/services4/system/` lists only `include` and `omap4`, while Makefile:62-68 uses `services4/system/$(SOC_FAMILY)` with `SOC_FAMILY=omap`. The build would fail to find `system/omap/sysconfig.c`, rather than silently picking another layer. |
| 17 | Core rev / BRN 28011 | `SysFinalise` `mov r1,#0x24; bl OSReadHWReg` (0xc028fb0c), ubfx 23:16/15:8/7:0. Double `OSWriteHWReg(…,0xc84,…)` at 0xc02956a4/0xc02956b4 (the movw at 0xc0295698/0xc02956ac). Exception pair 0x10100/0x10101 at 0xc0293064..0xc02930a8. The comparison is the ukernel-reported `ui32CoreRev` (misc-info +4) against `ui32CoreRevSW` (+0x18), skipped when SW = 0. |
| 18 | Runtime PM | `EnableSGXClocks`: `__pm_runtime_resume(dev, 4)` (0xc0290d7c). `DisableSGXClocks`: `__pm_runtime_idle(dev, 4)` (0xc0290e48). `omap_gpu_latency` = {0, 0, `omap_device_idle_hwmods`, 0, 0, `omap_device_enable_hwmods`, 2}. `SysDevicePrePowerState` → `DisableSGXClocks` (0xc0290864); Post → `EnableSGXClocks` (0xc02908c0). |
| 19 | PREEMPT | String at 0xc055f4b0 "… #1 SMP PREEMPT Fri Jun 29 15:12:17 PDT 2012". `steelhead_defconfig:100` `CONFIG_PREEMPT_NONE=y`. Letux commit `0affbb5a7b9502649f044699fbd464c86af44e7b` subject confirmed and an ancestor of d2f1e031. Its body only explains why VOLUNTARY was chosen, and `drivers/gpu/drm/pvrsgx/Kconfig` has no PREEMPT dependency. |
| 20 | Platform device / chrdev | `omap_device_build('pvrsrvkm', 0, oh, pdata, 24, omap_gpu_latency, 1, 0)` at 0xc0556bc0. pdata +8/+0xc/+0x10/+0x14 = `omap_device_scale`/`_enable`/`_shutdown`/`_idle` (literal pool 0xc0556c20..2c). `__register_chrdev(…, 256, 'pvrsrvkm', pvrsrv_fops)` at 0xc00259c0, class "pvr". Letux `pvr-drv.c:448 drm_dev_alloc`. |

### Corrected

| Claim | What was wrong | Correction (evidence) |
|---|---|---|
| 15: letux 1.8 options `0x00260018`, missing `0x108004` | It ignored `sgxfeaturedefs.h:242-243` (`LOW_LATENCY` ⇒ `#define SUPPORT_SGX_PRIORITY_SCHEDULING`), which `sgxinit.c` sees through `sgxdefs.h` (line 29) before `sgx_options.h` (line 50). | A release build gives **0x00360018**, missing only **0x8004** (EDM_STATUS_DEBUG + ACTIVE_PM). Parity row #24 and recommendation #6 are fixed; adding `-DSUPPORT_SGX_PRIORITY_SCHEDULING` is unnecessary. The build-number mismatch (869593 ≠ 785978) stands. |
| 9: "Letux 1.17/**1.14** … use sysconfig-am4.h: 200 MHz, 50 Hz, 2 ms" | 1.14.3699939 has no `sysconfig-am4.h`. | 1.14 OMAP4: 200 MHz (`sysinfo.h`), **100 Hz** HWR (`sysconfig.h:57`), APM **disabled** for SGX540 (Makefile 217/225 define it only for sgx544/jz4780). The 1.17 half of the claim stands. |
| 3: "base 0x4A009000 is used only for +0x400/+0x540/+0x548/+0x550" | A second use of the same base exists in both images. | It also covers `+0x470/+0x328/+0x330/+0x3e0` (x-loader VA 0x40305800.., bootloader 0x1b5c..). The conclusion (CM_GFX_GFX_CLKCTRL is never written, so bit 24 keeps its reset value) still holds: no 0x4A0092xx word and no CM2-based `#0x220` store in either image. The reset value itself remains unverified (TRM not checked). |
| 6: "static VDD_CORE (VC ON 1.2 V) … 307.2 MHz within 1.2 V" | 1.2 V is only the VC ON/ONLP target from patch 0027 (line 75). The runtime VDD_CORE was never measured, and the repo notes disagree on the mainline SMPS→rail mapping (2026-06-25 note: VCORE1 feeds VDD_MPU at ~1025 mV; 2026-07-02 note and patch 0027: VCORE1 = VDD_CORE). | The mechanism part is verified: `omap_device_scale` → `opp_find_freq_ceil`/`opp_get_voltage`/`_add_freq_request`/`_add_vdd_user`/`_dvfs_scale.isra.4`, and `# CONFIG_PM_DEVFREQ is not set` at defconfig:4208. The "307.2 MHz is safe" verdict is downgraded to **likely, pending a live VDD_CORE read** (row #30). |
| 17 (refinement): KM narrows the core rev to {101,110,120,121} | Too wide. | Stock `MMU_MapPage` maps `PVRSRV_MEM_EDM_PROTECT` → `SGX_MMU_PTE_EDMPROTECT` (`tst r5,#0x40; orrne r7,#0x10`, 0xc0296d48/50). That code is compiled out under `FIX_HW_BRN_25503` (rev 101/110, letux 1.8 `mmu.c:2864`), so the KM implies rev ∈ **{120,121}**. This assumes the same conditional in stock 1.8@785978. |
| 20 (detail): ION client name `"pvrsrvkm"` | Wrong literal. | `ion_client_create(omap_ion_device, 0x14, "pvr")` (literal 0xc02761d4 → 'pvr'). On failure the probe returns the client value (0xc02761bc), so a NULL return would make the probe succeed; only an `ERR_PTR` fails it. |
| 12 (detail): `omap44xx_gpu_irqs` at 0xc0717284 | Off by 4. | The symbol is at 0xc0717280; the irq field (53) is at +4 = 0xc0717284. |

### Not re-verified / still open

- The reset value of CM_GFX_GFX_CLKCTRL bit 24 (TRM not consulted). The
  "presumably CORE" inference comes only from stock's static
  `gpu_fck.parent`. *2026-10-11:* the live value under 6.18.48-r20 is CORE
  (row 29); the TRM reset value itself stays unconsulted.
- Whether stock 1.8@785978 uses exactly the same `sgx_options.h` bit
  positions as letux 1.8@869593 (the same branch makes this likely).
  `0x36801C` itself is a disassembled constant and is certain.
- Stock HZ=128 (§1/§6 #27) was not re-checked in this pass.
- Device-side facts (live clock mux, VDD_CORE) need the unit; no device was
  touched.
