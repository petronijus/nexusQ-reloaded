# SGX540 groundwork 6/7: Power, clocks, idle and thermal when the GFX domain comes on

> **Status (2026-10-11):** research and planning only. Nothing in this note was
> built, flashed or committed, and no unit was touched except where a section
> says so explicitly (one read-only probe in [power-clocks-pm.md](power-clocks-pm.md)).
> An independent adversarial pass re-checked every claim the same day; its
> corrections are folded into the text (marked *Corrected 2026-10-11*) and its
> full record is the **Verification (2026-10-11)** section at the end. Where the
> two disagree, the verification section wins.
>
> Part of the GPU groundwork set: the summary, decision matrix and roadmap are in
> [../2026-10-11-gpu-sgx540-groundwork.md](../2026-10-11-gpu-sgx540-groundwork.md);
> the folder index is [README.md](README.md). Inside this note, "workstream NN" or
> "report NN" refers to:
>
> | NN | Detail note |
> |---|---|
> | 01 | [stock-ground-truth.md](stock-ground-truth.md) |
> | 02 | [mainline-6.18.md](mainline-6.18.md) |
> | 03 | [kernel-driver-port.md](kernel-driver-port.md) |
> | 04 | [userspace-blobs.md](userspace-blobs.md) |
> | 05 | [compositor-display.md](compositor-display.md) |
> | 06 | [power-clocks-pm.md](power-clocks-pm.md) |
> | 07 | [usecases-roadmap.md](usecases-roadmap.md) |
>
> Paths under `<session scratch>/` were scratch copies made during the research
> session (extracted blobs, clones, venvs); they were not kept. Everything they held
> can be re-derived from the sources listed at the end.

*Original working title: 06 — GPU groundwork: power, clocks, idle and thermal when the GFX domain comes on*

Workstream 6 of the SGX540 groundwork. Date: 2026-10-11. Research only: nothing
was built, flashed or committed. One read-only probe of the Prague Q (hostname
`steelhead`, kernel `6.18.48-r20`, uptime 611 401 s ≈ 7.1 d) was run over WiFi
(`192.168.20.246`) on 2026-10-11 around 00:35 CEST.

Evidence tags used below:
- **[SRC path:line]**: mainline Linux **v6.18.48** (stable tag, commit
  `5bbb9c9f8f808710e2123f2b30f0d61d7d698f52`, "Linux 6.18.48", committed 2026-08-28),
  sparse-cloned from `git.kernel.org/.../stable/linux.git` for this note.
- **[REPO path:line]**: this repository at `dc988b9`.
- **[STOCK sym @addr]**: `reverse-eng/vmlinux.bin` (stock steelhead 3.0.8, kallsyms
  in `reverse-eng/tools/kallsyms.txt`), read with `nqdis.py` / `dump.py` /
  `callers.py`.
- **[LIVE]**: the 2026-10-11 read-only probe of the Prague unit.
- **[PVR117 path:line]**: `openpvrsgx-devgroup/linux_openpvrsgx`, branch
  `letux/pvrsrvkm-1.17.4948957`, commit `584dd33a1557dde5365d6fce536c107aa6f56d59`
  (2025-05-05, "drm: pvrsgx: fix for 6.15-rc1 ..."), path prefix
  `drivers/gpu/drm/pvrsgx/1.17.4948957/eurasia_km/`.
- **[GLUE10]**: same repo, branch `letux/omap-pvr-soc-glue-v10`, commit
  `57c9a409ba706f683ef093c821d3e46992c31b0e` (2026-08-17, on Linux 7.2.0).
- **UNVERIFIED (...)**: an inference, with the reasoning in brackets.

---

## TL;DR

1. **The GFX power domain is already wired into mainline and is already OFF at
   idle.** `omap4.dtsi` ships an enabled `sgx_module: target-module@56000000`
   (ti-sysc, `power-domains = <&prm_gfx>`). It has no `status = "disabled"`, and
   the steelhead DTS does not disable it [SRC arch/arm/boot/dts/ti/omap/omap4.dtsi:484-509].
   On the live unit, `prm_gfx` reads `off-0`, the target module is
   runtime-`suspended`, and `gfx_pwrdm` was ON for **1.19 s in 7.1 days**. Runtime
   PM counted only **60 ms** of that as active [LIVE]. Enabling a GPU driver does not
   "turn the domain on". Power is only spent while a driver holds the module
   runtime-active.
2. **The SGX clock source on our 4460 is wrong for stock parity.** Today the
   GPU fck comes from `dpll_core_m7x2_ck` = **266.67 MHz** (1600/6) [LIVE clk_summary].
   Stock reparents `gpu_fck` to **`dpll_per_m7x2_ck`** in
   `omap4_steelhead_display_init` [STOCK @0xc0075f08..0xc0075f40]. Mainline does
   that only for the 4430 (`omap443x.dtsi`, 307.2 MHz), not for the 4460
   [SRC omap443x.dtsi:78-86, omap4460.dtsi has no sgx entry].
   `dpll_per_m7x2_ck` already runs at **307.2 MHz** (1536/5) and nothing uses it [LIVE].
3. **Stock GPU OPPs (ground truth):** 153.6 MHz @ VDD_CORE 962 mV, 307.2 MHz @
   1127 mV, **384 MHz @ 1250 mV (CORE "OPP100-OV")**. All three are from `dpll_per_m7x2_ck`,
   and on steelhead **all three are marked available** [STOCK omap446x_opp_def_list
   @0xc0043e94-0xc0043ed8]. The Galaxy Nexus tree marks 384 MHz *unavailable*
   (`false`), so steelhead enabled it on purpose.
4. **Stock had real GPU DVFS and mainline has none.** Stock `pvrsrvkm` is built-in. It builds a
   frequency list from the gpu OPPs (`SysDvfsInitialize`) and switches between min and max through
   `pdata->device_scale = omap_device_scale` (`RequestSGXFreq`). `omap_device_scale`
   scales VDD_CORE as the max over all requests. The policy is Google's
   `sgx_idle_mode=2` (adaptive), `sgx_idle_timeout=1 000 000` ns, and APM latency
   `sgx_apm_latency=100` ms [STOCK @0xc0290f80, 0xc0290c28, 0xc029091c,
   0xc0725b9c-0xc0725ba4]. So stock ran **384 MHz with VDD_CORE at 1.25 V while busy** and
   dropped to 153.6 MHz when idle.
   Mainline has no VDD_CORE regulator or scaling, no L3 OPPs, no GPU OPP table,
   `CONFIG_PM_DEVFREQ` is off, and SmartReflex is off.
   The letux 1.17 `sgxfreq` is DRA7/OMAP5-family-specific and is not built for OMAP4:
   `SYS_OMAP_HAS_DVFS_FRAMEWORK` is never defined, and `sgxfreq*.o` needs
   `CONFIG_OMAP_SGX_FREQ`, which is not in Kconfig
   [PVR117 Makefile:69-78, 213-222; services4/system/omap/sgxfreq.c:488-516].
5. **Mainline runs CORE at OPP100 frequencies permanently.** L3 runs at 200 MHz [LIVE].
   Per the data manual that is OPP100 *or* OPP119: both run L3 at 200 MHz, and stock has
   200 MHz L3 rows at both 1127 mV and 1250 mV. The L3 rate therefore says nothing about
   the CORE voltage. Nothing in 6.18 scales VDD_CORE or sets an
   initial CORE voltage [SRC pm.c:137-161]. **Recommendation:** fixed SGX at
   **307.2 MHz from `dpll_per_m7x2_ck`**, which is within the OPP100 rating, with no DVFS in
   phase 1. **Never 384 MHz** until a VDD_CORE regulator can raise the rail to 1.25 V.
6. **Measure the VDD_CORE voltage itself before the first GPU boot.** We know the
   frequencies are OPP100. We do not know the voltage the bootloader set,
   because Linux exposes no VDD_CORE regulator [LIVE regulator_summary].
   Patch 0027's 1.2 V is only the VC *ON* target.
7. **CORE retention is not at stake today.** `core_pwrdm` has never left ON
   (RET 0, INA 0 over 7 days) [LIVE], because USB/L3INIT pins it (Petr's
   2026-09-23 decision: mirror stock and keep Ethernet up) [REPO
   docs/2026-09-20-sleep-states-design.md §4u]. An idle SGX in smart-standby is not
   expected to veto CORE. An SGX that is rendering is an L3_2 initiator and does
   [STOCK omap44xx_gpu_masters → omap44xx_gpu__l3_main_2]. GPU use also implies HDMI
   scan-out, and DSS DMA already keeps L3/EMIF busy.
8. **What can still hurt the tuned idle is wakeups and leakage, not the domain.**
   1. While SGX is powered, the DDK runs a host timer every 50 ms (1000·50/uKernelFreq)
      [PVR117 services4/srvkm/devices/sgx/sgxpower.c:53-70].
   2. Each frame raises GPU IRQs (GIC SPI 21).
   3. A compositor that redraws needlessly costs CPU time.
   4. A driver that never runtime-suspends would keep GFX ON (leakage) indefinitely.

   Active Power Management (`SUPPORT_ACTIVE_POWER_MANAGEMENT`) has to work for C3's
   86-93 % idle share to survive. **Corrected 2026-10-11 (verification):** the letux 1.17
   OMAP *system layer* calls `pm_runtime_get_sync()` and never `pm_runtime_enable()`
   [PVR117 services4/system/omap/sysutils_linux.c:214], but the openpvrsgx DRM glue
   `drivers/gpu/drm/pvrsgx/pvr-drv.c` (outside the versioned DDK directory) does enable it:
   `pvr_probe()` calls `pm_runtime_enable()` and then `pm_runtime_get_sync()` on the same
   `pdev` that becomes `gpsPVRLDMDev` [openpvrsgx `pvrsrvkm-6.18-rc6` @ `d2f1e031`, and
   identical on `pvrsrvkm-7.2` @ `2342ce92` (2026-08-26): pvr-drv.c:440-441, 465]. **That
   probe reference is only dropped on the error path and in `pvr_remove()`
   [pvr-drv.c:476, 488].** The DDK's own get/put (`EnableSGXClocks` get_sync,
   `DisableSGXClocks` `pm_runtime_put_autosuspend` [sysutils_linux.c:214, 260-261]) only
   moves the usage count between 2 and 1. UNVERIFIED on hardware, but it follows from the
   code: **with the openpvrsgx glue as it stands, the GFX domain stays ON for as long as the
   driver is bound**, and APM only stops the 50 ms timer and the ukernel. This is the single
   biggest power risk in phase 1. Fix it in the glue (drop the probe reference, or
   `pm_runtime_put_autosuspend()` after `drm_dev_register()`), then verify with §8.3 step 3.
9. **Instrumentation gap:** `pm_debug/count|time` sample `gfx_pwrdm` only at MPUSS
   low-power entry/exit (`pwrdm_pre/post_transition(NULL)` in
   `omap-mpuss-lowpower.c:260/305`). Genpd turns `prm_gfx` on and off behind the legacy
   framework's back. The authoritative GPU residency is genpd `prm_gfx` and the
   target module's `runtime_active_time`. That attribute is in sysfs, so healthd can
   read it without forking or using debugfs.
10. A **measurement protocol** is in §9: five arms (A0-A4) with passive collection and
    pass/fail criteria tied to C3 share, 350 MHz residency, VDD_MPU-vs-OPP and die
    temperature. The wall-power instrument is a known gap: the Solight meter has a
    1 W step. Get a ≥0.1 W meter before claiming any watts.

---

## 1. Where the GPU sits in the OMAP4460 power tree

### 1.1 Mainline 6.18 data (facts)

| Item | Value | Evidence |
|---|---|---|
| Power domain | `gfx_pwrdm`, voltdm **`core`**, `pwrsts = PWRSTS_OFF_ON` (no RET, no INA), 1 mem bank `gfx_mem` (ret OFF, on ON), `PWRDM_HAS_LOWPOWERSTATECHANGE` | [SRC arch/arm/mach-omap2/powerdomains44xx_data.c:56-71] |
| Clock domain | `l3_gfx_clkdm`, CM2 inst `0x1200`, `CLKDM_CAN_HWSUP_SWSUP` | [SRC clockdomains44xx_data.c:184-194] |
| Possible static deps | `l3_gfx → {ivahd, l3_1, l3_emif}` (the list of deps the register *can* carry) | [SRC clockdomains44xx_data.c:97-102] |
| Static deps actually set | **none for GFX**. `clkdm_complete_init()` clears every clkdm's wk/sleep deps, and `omap4_static_dep_map` only adds `mpuss→{emif,l3_1,l3_2}` and `ducati→{l3_1,l3_2}` | [SRC clockdomain.c:477-494; pm44xx.c:172-179] |
| genpd provider | `prm_gfx` @ `0x4a307200`, dmap `omap_prm_onoff_noauto` (ON or OFF only) | [SRC drivers/pmdomain/ti/omap_prm.c:125-128, 196-199] |
| Target module | `sgx_module: target-module@56000000`, `ti,sysc-omap4`, rev `0x5600fe00`, sysc `0x5600fe10`, midle/sidle `{FORCE,NO,SMART,SMART_WKUP}`, `clocks = <&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 0>` | [SRC omap4.dtsi:484-502] |
| GPU child | `gpu@0 { compatible = "ti,omap4430-gpu", "img,powervr-sgx540"; reg 32 MB; GIC SPI 21 }` | [SRC omap4.dtsi:504-508] |
| DT binding | `img,powervr-sgx.yaml` is in 6.18; for `ti,omap4430-gpu` it forbids `power-domains` and `clocks` on the child (they belong on the target module) | [SRC Documentation/devicetree/bindings/gpu/img,powervr-sgx.yaml]; same file in GLUE10 |
| ti-sysc SGX quirk | `SYSC_QUIRK("gpu", 0x50000000, 0xfe00, 0xfe10, ..., 0x40000000, SYSC_MODULE_QUIRK_SGX)` with `THALIA_INT_BYPASS`, keyed to base `0x50000000` (OMAP3). On OMAP4 (`0x56000000`) the generic `("gpu", 0, 0xfe00, 0xfe10, …, 0x40000000)` entry matches **without** the quirk | [SRC drivers/bus/ti-sysc.c:1534-1536, 1609-1610, 1948-1955] |
| Idle mode on disable | ti-sysc picks the best mode: **SMART_WKUP** for both MIDLE and SIDLE unless a SWSUP/FORCE quirk applies | [SRC ti-sysc.c:1125-1205] |
| Functional clock | `OMAP4_GPU_CLKCTRL` (`0x4a009220`), `CLKF_SW_SUP`; bit 24 mux parents `{dpll_core_m7x2_ck, dpll_per_m7x2_ck}` | [SRC drivers/clk/ti/clk-44xx.c:327-340, 703] |
| 4430 clock setup | `assigned-clock-parents = <&dpll_per_m7x2_ck>`, rate **307.2 MHz** ("like droid4 stock v3.0.8") | [SRC omap443x.dtsi:78-86] |
| 4460 clock setup | **none**: the mux stays at reset (`dpll_core_m7x2_ck`) | [SRC omap4460.dtsi, no sgx entry] |
| ABB | `abb_mpu`, `abb_iva` only. **No ABB on VDD_CORE** | [SRC omap4460.dtsi:42,60] |

GLUE10, the newest OMAP GPU integration branch (Linux 7.2.0, 2026-08-17), has
byte-identical `omap4.dtsi`, `omap4460.dtsi` and `omap443x.dtsi` (diffed for this
note). Upstream has nothing newer on OMAP4 GPU power.

### 1.2 Stock 3.0.8 data (facts)

| Item | Stock value | Evidence |
|---|---|---|
| `gfx_44xx_pwrdm.pwrsts` | **0x0d = OFF \| INACTIVE \| ON** (mainline OFF_ON). The decoding was checked against `core_44xx_pwrdm`, which reads 0x0e = RET\|INA\|ON exactly as patch 0054 says | [STOCK gfx_44xx_pwrdm @0xc070abc8 +0x12; core_44xx_pwrdm @0xc070aa98 +0x12] |
| gpu hwmod sysconfig | rev `0xfe00`, sysc `0xfe10`, `SIDLEMODE\|MIDLEMODE`, idlemodes 0xff (all four), sysc_type2. This matches mainline's DT | [STOCK omap44xx_gpu_sysc @0xc07181ec] |
| gpu initiator port | `omap44xx_gpu__l3_main_2` (the GPU masters on **L3_2**, part of CORE) | [STOCK kallsyms 0xc0717c60] |
| gpu_fck parent | reparented to `dpll_per_m7x2_ck` in `omap4_steelhead_display_init`; error strings "failed to set gpu_fck to dpll_per_m7x2_ck" | [STOCK @0xc0075f08-0xc0075f48, strings @0xc065a444] |
| static deps for GFX | no code in stock references `l3_gfx_clkdm` outside the clkdm data and the `mpuss`/`ducati` dep tables | [STOCK xref of "l3_gfx_clkdm" @0xc06580a4: only data refs] |
| GPU platform data | `omap_init_gpu` → `pdata->device_scale = omap_device_scale`, `device_enable/idle/shutdown = omap_device_*`, `ovfreqs = 1` on 0x446 | [STOCK omap_init_gpu @0xc0556b54-0xc0556b9c] |

UNVERIFIED (consequence of stock's INACTIVE): stock *could* hold GFX clock-gated
but powered. Nothing found requests it. The generic PM init would program the
lowest state, OFF. This is parity trivia, not a mechanism to copy.

### 1.3 The live unit (facts, 2026-10-11)

```
pm_genpd_summary:   prm_gfx  off-0   ;  5600fe00.target-module  suspended  SW
runtime PM:         runtime_status=suspended  runtime_active_time=60 (ms)
                    runtime_suspended_time=611399290 (ms)
pm_debug/count:     gfx_pwrdm (OFF),OFF:3,RET:0,INA:0,ON:2
pm_debug/time (ns): gfx_pwrdm OFF:611644385528560  ON:1194366454   (≈1.19 s ON)
                    dss_pwrdm OFF:611626705078120  ON:18874847412  (≈18.9 s ON)
                    core_pwrdm ON:611645579895015 (never RET/INA)
                    mpu_pwrdm  RET:342087171143369 INA:5997002288983 ON:263561406584733
                    l3init_pwrdm ON for the whole uptime
pm_debug/count:     core_pwrdm (ON) OFF:0 RET:0 INA:0 ON:1
                    mpu_pwrdm (ON) RET:101628938 INA:3303160
                    clkdm usecounts: l3_gfx_clkdm 0, l3_1 1, l3_2 1, l3_emif 2, l3_instr 1, l4_cfg 1
clk_summary:        dpll_core_x2_ck 1600000000; dpll_core_m7x2_ck 266666667 (en 0, prep 1)
                      └ l3-gfx-clkctrl:0000:24 266666667 → l3-gfx-clkctrl:0000:0 266666667 hw-enable N
                        consumer 5600fe00.target-module "fck"
                    dpll_per_x2_ck 1536000000; dpll_per_m7x2_ck 307200000 (en 0, prep 0)
                    dpll_core_m5x2_ck 400000000 → div_core_ck 400000000 → l3_div_ck 200000000
/proc/device-tree:  ocp/target-module@56000000 present, no status (= okay),
                    gpu@0 compatible "ti,omap4430-gpu img,powervr-sgx540", no status
dmesg | grep -i 'sgx|gpu|56000000|gfx': nothing
```

Reading of the probe:
- The ti-sysc probe briefly powers GFX at boot to read the revision. Genpd then
  powers it down, and with no driver bound to `gpu@0` it stays down. This is the
  baseline state the GPU work starts from. It costs nothing.
- `pm_debug` attributes ~1.19 s ON to GFX against runtime PM's 60 ms. UNVERIFIED
  (inference from the sampling code in §6.1): the difference is boot-time ON between
  `pm_dbg_init` and the first `pwrdm_pre/post_transition()` sample after genpd powered GFX
  off. `pm_dbg_update_time()` charges the whole interval to the cached previous state,
  which is ON. It is not a leak.
- Timebase caveat (found in verification): the `pm_debug/time` sums (≈ 611 645.6 s for
  `core_pwrdm` and for MPU RET+INA+ON) exceed both the quoted uptime (611 401 s) and
  runtime PM's total (611 399.35 s) by ≈ 245 s (0.04 %). `pm_debug` uses `sched_clock()`,
  runtime PM uses the monotonic clock. Either the reads were minutes apart or the two
  clocks drift. Use deltas within one source only; never mix `pm_debug` and runtime PM
  numbers in one ratio.

---

## 2. Clocks: what the SGX540 should run at on this board

### 2.1 Clock tree today and options

| Source | Rate | Users | Verdict |
|---|---|---|---|
| `dpll_core_m7x2_ck` (DPLL_CORE ×2 = 1600 MHz, HSDIV M7) | /6 = **266.67 MHz** now [LIVE]; /5 = 320 MHz; /4 = 400 MHz | only the SGX mux | Not stock. 320 MHz would be above the 307.2 MHz OPP100 rating (UNVERIFIED: no TI rating for 320 found; stock never uses it) |
| `dpll_per_m7x2_ck` (DPLL_PER ×2 = 1536 MHz, HSDIV M7) | /5 = **307.2 MHz** now [LIVE]; /4 = 384 MHz; /10 = 153.6 MHz | only the SGX mux | **Stock source.** All three stock GPU OPPs are integer dividers of it |

Both DPLLs are locked all the time anyway: CORE feeds L3/EMIF, PER feeds the 96/48 MHz
functional clocks. Picking PER adds no DPLL lock power. The only extra is the M7
HSDIVIDER output, which has `ti,autoidle-shift = <8>` and gates when unused
[SRC omap44xx-clocks.dtsi:367-377, 734-744].

**Recommended DT change (for the kernel workstream, not done here):** in the steelhead
DTS, mirror `omap443x.dtsi`:

```dts
&sgx_module {
	assigned-clocks = <&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 24>,
			  <&dpll_per_m7x2_ck>;
	assigned-clock-rates = <0>, <307200000>;
	assigned-clock-parents = <&dpll_per_m7x2_ck>;
};
```

This is stock parity: stock reparents `gpu_fck` to `dpll_per_m7x2_ck`. Stock's
runtime rate came from DVFS. 307.2 MHz is the highest OPP whose VDD_CORE
(1127 mV) mainline already provides.

### 2.2 Stock OPP tables (verified from the binary)

`omap446x_opp_def_list` @ `0xc0043d5c` [STOCK]. Format: hwmod, voltdm, clk, freq, µV, available.

| Device | Clock | Freq | VDD | µV | Avail |
|---|---|---|---|---|---|
| gpu | `dpll_per_m7x2_ck` | 153.6 MHz | core | 962 000 | 1 |
| gpu | `dpll_per_m7x2_ck` | 307.2 MHz | core | 1 127 000 | 1 |
| gpu | `dpll_per_m7x2_ck` | **384.0 MHz** | core | **1 250 000** | **1** |
| l3_main_1 | `virt_l3_ck` | 100 MHz | core | 962 000 | 1 |
| l3_main_1 | `virt_l3_ck` | 200 MHz | core | 1 127 000 | 1 |
| l3_main_1 | `virt_l3_ck` | 200 MHz | core | 1 250 000 | 1 |
| fdif | `fdif_fck` | 32/64/128 MHz | core | 962/962/1127 mV | 1 |
| mpu | `virt_dpll_mpu_ck` | 350/700/920/1200/1500 | mpu | 1025/1203/1317/1380/1380 mV | 1/1/1/0/0 |
| iva | `dpll_iva_m5x2_ck` | 133/266.1/332/430/500 | iva | 950/1140/1291/1375/1375 mV | 1/1/0/0/0 |

Cross-check: the Android `kernel/omap` tree, branch `android-omap-tuna-3.0-jb-mr2`,
`arch/arm/mach-omap2/opp4xxx_data.c`, fetched 2026-10-11. It has the same voltages
(`OMAP4460_VDD_CORE_OPP50_UV 962000`, `OPP100_UV 1127000`, `OPP100_OV_UV 1250000`)
and the same GPU and L3 rows, **but the tuna 384 MHz row is `false`**. Its
`omap446x_vdd_core_volt_data` uses `OMAP_ABB_NONE` on every CORE OPP. Steelhead's
binary flips 384 MHz to available.

Stock voltage-domain **dependencies** [STOCK omap446x_vddmpu_dep_info @0xc0706900 →
omap446x_vdd_mpu_core_dep_data @0xc0706c50; omap446x_vddiva_dep_info @0xc07068e0]:

| VDD_MPU | requires VDD_CORE ≥ |
|---|---|
| 1025 mV (350 MHz) | 962 mV |
| 1203 mV (700 MHz) | 1127 mV |
| 1317 mV (920 MHz) | 1127 mV |
| 1380 mV (1200 MHz) | 1127 mV |

| VDD_IVA | requires VDD_CORE ≥ |
|---|---|
| 950 mV | 962 mV |
| 1140 mV | 1127 mV |
| 1291 mV | 1127 mV |

Data-manual context (TI SWPS046A, OMAP4460 ES1.x DM, public, downloaded 2026-10-11):
- `vdd_core` max current is **1200 mA "including in overdrive mode – OPP119%"**
  (Table 3-2).
- "At OPP100, L3 clock is 200 MHz and at OPP50, L3 clock is 100 MHz".
- The device boots at "OPPBoot". The CORE OPP **voltages are in a separate "DM
  Operating Condition Addendum"**, which was not found publicly. So the voltage
  numbers here come from the stock binary, not from TI's sheet.

### 2.3 What mainline lacks, item by item

| Stock had | Mainline 6.18 + our patches | Evidence |
|---|---|---|
| `omap_device_scale` per-device DVFS with voltdm max-aggregation | gone, along with OMAP4 hwmod data (`omap_hwmod_44xx_data.c` no longer exists) | [SRC arch/arm/mach-omap2/ listing] |
| VDD_CORE scaling (VP force-update via VC to TWL6030 VCORE1) | **none**. `omap2_common_pm_late_init` only inits the voltage layer and SmartReflex. No CORE regulator exists. Patch 0015 built a VC-bridge regulator for **MPU only** | [SRC pm.c:137-161; REPO kernel/patches/0015-…vc-mpu-bridge-regulator.patch] |
| L3 OPP50 (`virt_l3_ck` 100 MHz) when bus throughput allows (`omap_pm_apply_min_bus_tput*`) | L3 fixed at 200 MHz [LIVE] | [STOCK omap_pm_apply_min_bus_tput_helper_l @0xc008454c calls omap_device_scale] |
| GPU OPP table + `SysDvfsInitialize`/`RequestSGXFreq` | no OPP for the GPU in DT; `CONFIG_PM_DEVFREQ` not set; letux `sgxfreq` is the DRA7/OMAP5-family variant (`dpll_gpu_m2_ck`, `dpll_core_h14x2_ck`, `gpu_core_gclk_mux`). `SYS_OMAP_HAS_DVFS_FRAMEWORK` is never defined for any target: its only mention is a `ccflags-n` line inside the `ifeq ($(SGX),sgx544)` block. The `sgxfreq*.o` objects are only built with `CONFIG_OMAP_SGX_FREQ`, which is "not in Kconfig" | [REPO kernel/configs/steelhead_defconfig; PVR117 Makefile:69-78, 213-222; sgxfreq.c:488-516] |
| SmartReflex class 1.5 recalibration (`sr_class1p5_voltdm_recal`) | `# CONFIG_POWER_AVS_OMAP is not set` | [STOCK kallsyms 0xc006bec4; REPO defconfig] |
| GPU cooling | none in stock either (no `sgxfreq_cool`). Mainline cooling map cools `cpu0` only | [SRC omap4-cpu-thermal.dtsi] |

**Consequence:** phase 1 must not depend on any of these.
1. Fix the SGX rate at 307.2 MHz.
2. Rely on VDD_CORE staying where the bootloader left it. The L3 rate shows only the
   OPP100/OPP119 frequency band, not the voltage. §4 says how to measure the voltage.
3. Use runtime PM + genpd for all the idle saving.

384 MHz is a phase-3 option that needs a VDD_CORE regulator.

---

## 3. Stock's GPU power policy, decoded

Every row below is [STOCK]. The source-file names are those embedded in the strings:
`drivers/gpu/pvr/omap4/sysutils_linux.c` and `drivers/gpu/pvr/omap4/sysconfig.c`.

| Function / variable | What it does |
|---|---|
| `SysDvfsInitialize` @0xc0290f80 | `opp_get_opp_count(gpu dev)` → kmalloc a list of count+1 → `opp_find_freq_ceil` loop → stores list/count/current in sys-specific data (+0x34/+0x30/+0x38) |
| `RequestSGXFreq(sysdata, bMax)` @0xc0290c28 | index = `bMax ? count-1 : 0`. If the index changed, it calls `pdata->device_scale(dev, dev, freq_list[idx])`. On `-EBUSY` it logs "Unable to scale SGX frequency (EBUSY)" |
| `EnableSGXClocks` @0xc0290d18 | if `sgx_idle_mode == 0`: `RequestSGXFreq(max)`; then `pm_runtime_get_sync` → `SysEnableSGXInterrupts` |
| `DisableSGXClocks` @0xc0290dec | `SysDisableSGXInterrupts` → `pm_runtime_put_sync`; if `sgx_idle_mode == 0`: `RequestSGXFreq(min)` |
| `SysSGXIdleTransition(bIdle)` @0xc029091c | **active:** cancel `sgx_idle_timer` + `sgx_idle_work`, then `RequestSGXFreq(max)`. **idle:** mode 1 arms an hrtimer of `sgx_idle_timeout`; mode 2 (adaptive) uses timeout = 3 000 000 ns − (time since the last idle→active) when that gap is < 2 ms, else `sgx_idle_timeout` |
| `sgx_idle_work_func` @0xc028fa54 | `RequestSGXFreq(min)` once the idle timer expires |
| called from | `SGXTestActivePowerEvent` @0xc0295b4c/0xc0295bb8, the ukernel's idle/active events |
| `sgx_idle_mode` @0xc0725ba4 | **2** (default) |
| `sgx_idle_timeout` @0xc0725ba0 | **1 000 000** (ns, so 1 ms) |
| `sgx_apm_latency` @0xc0725b9c | **100** (ms; module param `pvrsrvkm.sgx_apm_latency`) |
| `SysGetSGXTimingInformation` @0xc0290bb0 | CoreClockSpeed = current list entry, HWRecoveryFreq = **100**, bEnableActivePM = **1**, ActivePowManLatencyms = `sgx_apm_latency`, uKernelFreq = **1000** |
| `gfx_l3_rates` @0xc05633e0 | **Not OMAP4 GPU data (corrected in verification).** It is the OMAP2/3 `struct clksel_rate` table from `clock_common_data.c` for the OMAP3 `gfx_l3_fck` divider: {div 1..4, val 1..4, flags `RATE_IN_24XX\|RATE_IN_3XXX` (0x1f) or `RATE_IN_243X\|RATE_IN_3XXX` (0x1e)}. The stock binary is multi-platform, and its neighbours `dsp_ick_rates`, `gpt_sys_rates`, `gpt_32k_rates` are the same file's tables. Irrelevant to OMAP4. [torvalds/linux v3.0 arch/arm/mach-omap2/clock_common_data.c and clock3xxx_data.c `gfx_l3_clksel`, fetched 2026-10-11] |

Interpretation:
- Stock had **two independent savers**:
  - (a) **frequency/voltage** drop to 153.6 MHz @ 962 mV ~1-3 ms after the GPU goes idle;
  - (b) **APM** power-off of the whole GFX domain 100 ms after the ukernel reports idle
    (`DisableSGXClocks` → `pm_runtime_put_sync` → hwmod idle → GFX OFF).
- (a) only lowers VDD_CORE if every other CORE user also allows OPP50. L3 at
  100 MHz and MPU at ≤350 MHz satisfy the dependency table above. While HDMI scans
  out, DSS bandwidth requests most likely keep L3 at 200 MHz (UNVERIFIED).
- **(b) is the saver that matters for an idle box, and mainline can reproduce it
  exactly** with runtime PM + genpd. (a) mainly cuts energy *while animating*.
- For a visualizer that renders at 60 fps all the time, neither saver
  engages: the GPU never reaches 100 ms of idle. The relevant numbers then are
  frame-time × voltage² × frequency, plus leakage at VDD_CORE OPP100.

---

## 4. VDD_CORE: what we know, what we do not, how to find out

Facts:
- `gfx_pwrdm` is in the `core` voltage domain [SRC powerdomains44xx_data.c:59].
  On the 4460 the CORE VC channel targets TWL6030 **VCORE1**, SR addr 0x12,
  volt/cmd regs 0x55/0x56 [REPO kernel/patches/0027-…; docs/2026-07-02-stock-parity-voltage-wifi-idle.md §1].
- Patch 0027 sets CORE VC **ON/ONLP = 1 200 000 µV**. That is the value the VC sends
  on wakeup from a retention request, and only if `AUTO_CTRL` commands are
  enabled. Patch 0055 notes that mainline's `VDD_*_I2C_DISABLE` bits mean
  AUTO_CTRL sends no command [REPO 0055 header]. So **1.2 V is not proven to be
  the running voltage**.
- L3 = 200 MHz [LIVE] means CORE runs at OPP100/OPP119 frequencies (TI DM footnote 17,
  "At OPP100, L3 clock is 200 MHz and at OPP50, L3 clock is 100 MHz"; the DM's timing
  tables group OPP100 and OPP119 in one column). Stock's L3 200 MHz OPP sits at 1127 mV
  (or 1250 mV OV).
- No `regulator` in `/sys/kernel/debug/regulator/regulator_summary` covers
  VDD_CORE/VCORE1 [LIVE].

Not known: the actual VCORE1 output voltage the bootloader (U-Boot 2011.09
`steelheadB4H0J`) left. UNVERIFIED (expectation: U-Boot's `scale_vcores()`
puts CORE at an OPP100 voltage ≥ 1127 mV, because the kernel runs L3 at 200 MHz
without complaint. That is an inference, not a measurement). *(Corrected
2026-10-11: the x-loader, not U-Boot, sets it. It programs vsel 0x23 =
1 139 440 µV for a 1127 mV target, U-Boot skips its copy, and nothing in our
kernel rewrites it. Expected value, not measured; see the Addendum "Live VDD_CORE
without a device".)*

How to measure it, all read-only, ordered by safety. Not run today, because the probe
brief limited commands.
1. **PRM VP_CORE registers.** PRM base `0x4a306000` + PRM_DEVICE inst `0x1b00`
   [SRC prm44xx.h:28,53] gives:
   - `PRM_VP_CORE_CONFIG = 0x4a307b40` (INITVOLTAGE in bits 15:8, VPENABLE bit 0);
   - `PRM_VP_CORE_VOLTAGE = 0x4a307b4c`;
   - `PRM_VP_CORE_STATUS = 0x4a307b44` [SRC prm44xx.h:85-90].

   **Corrected in verification: this read is expected to be useless.** Mainline's
   `omap_vp_init()` writes `VP_CONFIG` as `erroroffset | timeouten` only, so INITVOLTAGE
   ends up 0 [SRC arch/arm/mach-omap2/vp.c:72-79]. Nothing in 6.18 calls `voltdm_scale()`
   on the `core` domain; its only in-tree caller is `voltdm_reset()` [SRC voltage.c:139].
   So `VP_CORE_VOLTAGE` is never driven by a force-update either. Read the registers once
   to confirm (PRM is in the always-on WKUP domain, so the read is safe), but do not
   expect a voltage from them. The VC's programmed ON value (`PRM_VC_VAL_CMD_VDD_CORE_L`)
   is only patch 0027's 1.2 V target, not the rail.
2. **TWL6030 VCORE1 register over the control i2c** (`i2cget -y 0 0x48 <reg>`). The
   project has read TWL efuses this way before (2026-07-02 SMPS_OFFSET/SMPS_MULT).
   The exact VCORE1 voltage register address on the control interface still has to
   be confirmed from the TWL6030 TRM before anyone reads it (UNVERIFIED; 0x55/0x56
   are the *SR-interface* offsets). *(Corrected 2026-10-11: derived without the
   TRM. The VCORE1 block is 0x52-0x57 on 0x48, and the read is
   `i2cget -y -f <twl6030 bus> 0x48 0x55 b` plus 0x56. `-f` is required, not just
   likely. Expected `0x23`. See the Addendum.)* *(Corrected again 2026-10-11 by a
   live read: 0x55 and 0x56 both read `0x00` while VCORE1 is on, so this register pair
   does not show the SmartReflex-programmed setpoint. **No read-only path to VDD_CORE
   exists**; see the Addendum, §6 "Live read".)* A wrong address on a read is harmless on the
   TWL6030 (UNVERIFIED but low risk), but it would give a wrong answer. Note (UNVERIFIED,
   from twl-core behaviour): the bound twl driver claims the TWL slave addresses, so
   `i2cget` will most likely need `-f`. Also, do not confuse it with the TMP101, which
   is also at 0x48 but on I2C2 [REPO kernel/patches/0003…:608-628].
3. **Multimeter on VCORE1's output inductor/cap** (hands-on, Petr). Definitive. *(2026-10-11:
   now the only read-only method. Measure on the output side of VCORE1's inductor
   (1 µH typ) or its 10 µF output capacitor, which sit next to the TWL6030; the
   VCORE1_FDBK ball is L2 [TWL6030 datasheet SWCS045C, pin table and SMPS
   characteristics]. Where these parts sit on the steelhead board is not documented
   (UNVERIFIED; no schematic).)*

Then convert vsel to µV with the TWL6030 ES1.1+ map: `SMPS_OFFSET=0x7f` → 0.7-1.4 V scale,
12.66 mV/step [REPO docs/2026-07-02-…§1, patch 0023].

**Gate:** the first GPU boot only proceeds if VDD_CORE ≥ 1127 mV (stock's 307.2 MHz
voltage) or the SGX is limited to 153.6 MHz (`assigned-clock-rates = <0>, <153600000>`,
stock's OPP50 point, 962 mV).

---

## 5. Does an enabled-but-idle SGX block idle states?

### 5.1 MPU C2/C3 (what runs today: C3 is 86-93 % of idle)

- No hardware dependency from GFX to the MPU power domain was found. The steelhead C-states
  program MPU INA/CSWR and CORE INA/CSWR [REPO 0056]. CORE is ON regardless (§5.2).
- The costs come through **wakeups**:
  1. **DDK host timer.** `SGXAddTimer` registers `SGXOSTimer` every
     `1000*50/ui32uKernelFreq` ms = **50 ms (20 Hz)** with uKernelFreq = 1000
     [PVR117 sgxpower.c:53-70; STOCK uKernelFreq = 1000]. It is enabled in
     `SGXStartTimer` and disabled in `SGXPrePowerState` on any non-ON transition
     [PVR117 sgxpower.c:200-225, 300-325]. So it **only ticks while SGX is powered**.
     With APM working it disappears at idle. Without APM it is 20 extra wakeups/s,
     which is ~6 % of today's 353 idle exits/s [REPO docs/2026-09-26-idle-audit-five-pollers.md §4].
  2. **GPU IRQs** (GIC SPI 21, [SRC omap4.dtsi:507]). Each finished render or
     transfer job raises at least one. At 60 fps expect O(60-200)/s while animating
     (UNVERIFIED estimate: one TA + one 3D completion per frame, plus flips).
     Default affinity is CPU0. Coupled idle means a CPU0 wake breaks both CPUs'
     C3 rendezvous ("coupled-cpuidle poke" IPIs [REPO idle audit §2]).
  3. **The compositor / client.** labwc + LXQt with pixman today; a GLES client
     tomorrow. The CPU-side EGL/driver overhead runs on the A9s and pulls the
     `conservative` governor up the OPP ladder. This is the biggest risk to
     "350 MHz residency ≈ 99.8 %" while the GPU is in use [REPO idle audit §1].
  4. **Runtime PM churn.** With APM latency L ms, an animation with gaps
     > L power-cycles GFX. Each cycle costs a genpd PRM transition (polled, ≤
     `PRM_STATE_MAX_WAIT`) plus the ukernel state save/restore. Stock chose 100 ms.
     The letux AM headers default to 2 ms [PVR117 services4/system/omap/sysconfig-am4.h:72-73].
     **Use 100 ms (stock)** unless measurement says otherwise.
- `cpu_latency_qos`: the 1.17 OMAP glue adds no CPU-latency QoS request (no
  `pm_qos`/`cpu_latency_qos` in the OMAP system layer; only s5pc110 has one) [PVR117
  grep]. C2/C3 exit latencies (1100/1200 µs) are therefore not vetoed by the driver.
  Healthd's `qos_us` field will show it if that changes [REPO
  userspace/nq-healthd/nq-healthd.c:225-233].

### 5.2 CORE INA/CSWR/OSWR (stock C2/C3/C4 targets)

- Today CORE **never** leaves ON: RET 0, INA 0 over 7 days [LIVE]. The cause is
  USB_HOST/USB_OTG/USB_TLL with STBYST=0, i.e. L3INIT masters never stand by
  [REPO docs/2026-09-20-sleep-states-design.md §4u]. Petr decided to mirror stock
  (Ethernet stays powered, CORE stays ON) [same doc, "Decision (Petr, 2026-09-23)"].
- So **the GPU cannot regress CORE idle today**. For a future in which CORE idles:
  - The GPU's initiator port is on **L3_MAIN_2** [STOCK omap44xx_gpu__l3_main_2].
    While SGX masters traffic (MStandby deasserted), L3_2 cannot idle, so CORE cannot
    reach INA/CSWR. That is inherent to rendering and correct.
  - When SGX is idle but powered (runtime-active), the module is in the state
    `sysc_enable_module()` left it in, which picks `fls(midlemodes) - 1` = SMART_WKUP for
    MIDLE (and SIDLE) [SRC ti-sysc.c:1055-1103]. The disable path
    [ti-sysc.c:1125-1205] also picks SMART_WKUP, but it only runs on runtime suspend. The SGX OCP wrapper then asserts MStandby whenever the core
    has no outstanding transactions. UNVERIFIED (expectation from the OMAP4 TRM's
    smart-standby semantics; not measured on SGX): it does not veto CORE.
  - GFX static deps to L3_1/EMIF are **cleared** [SRC clockdomain.c:489-492]; only
    hardware dynamic dependencies remain. UNVERIFIED (CM_GFX_DYNAMICDEP at CM2
    `0x4a009200 + 0x8` per the TRM's per-clkdm register layout; the 6.18 headers
    define only `OMAP4_CM_STATICDEP = 0x4` [SRC cm44xx.h:21]). A read-only devmem of
    `0x4a009204` (STATICDEP) and `0x4a009208` belongs in the bring-up diag (§8).
  - The **GPU use case implies HDMI**. DSS scan-out DMA (the framebuffer at 60 Hz)
    keeps L3/EMIF active by itself. CORE cannot idle while the desktop or visualizer
    is on screen, with or without the GPU. The GPU's incremental CORE cost
    in that state is zero. When HDMI is off, nothing should hold the GPU awake, and
    that is the thing to verify (§9 arm A1).
- Stock parity on cpuidle: stock had no bus-master check before deep states (no
  `*bm_check*` symbols; only `omap4_enter_idle(_wfi)`) [STOCK kallsyms 0xc0067c8c,
  0xc0067e50]. Nothing GPU-specific to port into the cpuidle table.

### 5.3 Suspend (R3/R4 of the sleep-states ladder)

Out of scope for phase 1. `freeze` is blocked by the TWL6030 wake path
[REPO sleep-states design §4b/4c]. Requirements for later:
- the GPU driver's system-suspend path (`PVRSRVDriverSuspend`/`Resume`, both
  present in stock [STOCK @0xc0276034/0xc0276004]) must leave GFX OFF;
- genpd `prm_gfx` must report off before `syscore_suspend()`.

---

## 6. Repo-side knobs and instrumentation that exist today

### 6.1 Kernel knobs (patches 0024, 0048, 0054-0058)

| Patch | What it gives the GPU work |
|---|---|
| 0054 | INACTIVE allowed for MPU and CORE (stock parity). Not GFX. GFX stays OFF_ON in mainline, which is fine (§1.2) |
| 0055 | MPU/CORE rest at ON; `PRM_PWRREQCTRL=3`, `PRM_CLKREQCTRL=2`; RTA export disabled. Irrelevant to GFX, but `PWRREQ` behaviour matters if CORE ever retains while GFX is OFF (it would still be OFF) |
| 0056 | stock C1-C3 table (C2 = MPU INA + CORE INA, C3 = MPU CSWR + CORE CSWR). CORE is programmed on CPU0's entry. Exit latencies 1100/1200 µs |
| 0057 | `prm_mpu`/`prm_core` removed from genpd; **`prm_gfx` keeps its genpd** (needed for GPU runtime PM) |
| 0058 | C2/C3 enabled by default; `echo 1 > /sys/devices/system/cpu/cpu*/cpuidle/state{1,2}/disable` takes them out at runtime |
| 0048 | `/sys/module/cpuidle44xx/parameters/{skip_cpu1_wait,keep_mpu_on,keep_core_on,skip_lowpower}`: escape hatches for bisecting a GPU-induced idle hang |
| 0024 | (history) states registered with CPUIDLE_FLAG_OFF; superseded by 0058 |

**pm_debug semantics caveat** [SRC arch/arm/mach-omap2/powerdomain.c,
`_pwrdm_state_switch`; omap-mpuss-lowpower.c:260,305]:
- `pm_debug/count` and `pm_debug/time` update a domain's counters **only when
  `pwrdm_pre/post_transition()` runs**. On OMAP4 that is inside
  `omap4_enter_lowpower()`, i.e. on MPUSS deep-idle entry and exit.
- The genpd driver writes `PM_GFX_PWRSTCTRL` directly
  [SRC drivers/pmdomain/ti/omap_prm.c:566-604] and does not call into the legacy
  framework.
- So GFX transitions are *sampled* at C2/C3 entry and exit (~150/s at idle, far
  fewer while busy) and time is attributed between samples. Good enough for idle;
  biased while animating. Reading `pm_debug/time` is itself a sample:
  `pwrdm_dbg_show_timer()` calls `pwrdm_state_switch()` for every domain first
  [SRC pm-debug.c, `pwrdm_dbg_show_timer`; powerdomain.c:974-995].
- **Authoritative GPU residency:**
  - `/sys/devices/platform/ocp/5600fe00.target-module/power/runtime_active_time`
    (ms, sysfs, no debugfs);
  - `/sys/kernel/debug/pm_genpd/prm_gfx/{current_state,active_time,total_idle_time}`;
  - for ground truth, a PRM read of `PM_GFX_PWRSTST` (`0x4a307204`; PRM inst
    `0x1200` [SRC prm44xx.h:45]), which carries LASTPOWERSTATEENTERED.

### 6.2 healthd / MQTT fields usable as-is

`nq-healthd` JSONL [REPO userspace/nq-healthd/nq-healthd.c:1658-1688], every 5 s:
- `freq`, `opp_ms` (time_in_state delta), `opp_trans`;
- `temp_mC` (bandgap), `cool`;
- `vdd_uV`, `vdd_exp_uV`, `vdd_mismatch`, `abb_uV` (VDD_MPU vs OPP; the owner's key metric);
- `cstate_ms`, `cstate_n`, `cstate_armed`, `qos_us`;
- `busy_ms`, `irqs`, `forks`, `nice_ms`, `load1`;
- per-unit `unit_us` every 12th sample.

`nexusq-mqtt` republishes it with rolling 1 h OPP windows, and `ha-opp-window.py`
reads them passively from HA [REPO scripts/diag/README.md]. That is all the
CPU-side impact data the protocol needs.

Missing, and proposed here (schema is append-only per healthd's own rule
[REPO nq-healthd.c:1641-1645]):

| New field | Source | Cost | Why |
|---|---|---|---|
| `gpu_active_ms` | delta of `.../5600fe00.target-module/power/runtime_active_time` | one sysfs read | GFX-ON time per sample, robust against the pm_debug sampling bias |
| `gpu_rpm` | `.../power/runtime_status` (`active`/`suspended`) | one sysfs read | state at sample time |
| `gpu_irqs` | the GIC-21 / pvr line of `/proc/interrupts` (already parsed for `irqs`) | none extra | per-frame wake cost |
| `dss_active_ms` | `58000000.target-module/power/runtime_active_time` | one sysfs read | "is HDMI scanning out", which explains CORE/L3 activity |
| `die2_mC` (optional) | `tmp101@48` hwmon | one read | second temperature point (board) |

Keep healthd's hard-won rule: no forks, no debugfs on the 5 s path.

### 6.3 diag coverage today

- `nq-diag-snapshot` dumps the whole `clk_summary` [REPO
  pmos/device-google-steelhead/nq-diag-snapshot:94], regulators, the VDD_MPU-vs-OPP
  check, and thermal. It does **not** dump `pm_debug/count|time` or
  `pm_genpd_summary`.
- `nq-deep-idle-ladder.sh` greps `pm_debug/count` for mpu/core/cpu0/cpu1 only
  [REPO scripts/diag/nq-deep-idle-ladder.sh:129,147].
- `analyze-opp-snaps.py` has a C·V²·f dynamic-power index for the MPU [REPO
  scripts/diag/README.md]. There is no GPU or VDD_CORE equivalent.

---

## 7. Thermal

- One on-die sensor: the OMAP4460 bandgap, `thermal_zone0`, coefficients
  `<348 -9301>` [SRC omap4460.dtsi]. Passive trip 100 °C, critical 125 °C, and the
  cooling map cools `cpu0` only [SRC omap4-cpu-thermal.dtsi]. The board also
  has a TMP101 at i2c `0x48` [REPO kernel/patches/0003…:624-628].
- Measured context: idle die median 40.3 °C (cottage) and 48.9 °C (Prague)
  [REPO idle audit §1]; 56 °C during Spotify; **74-79 °C, up to 82.6 °C, with an ssh
  session open** [REPO scripts/diag/README.md, "two traps"].
- The GPU's heat goes into the same die. UNVERIFIED (no published SGX540 power figure
  was found; searched 2026-10-11): continuous 307.2 MHz rendering plus the CPU-side
  driver load could take the die into the 80s °C. The 100 °C passive trip would then
  throttle **the CPU, not the GPU**. Under combined load that is backwards: it would
  starve the EGL client and lower the frame rate instead of the GPU clock.
- Recommendation:
  - Phase 1: no GPU cooling device. Measure die temperature under arm A3 (§9).
    Cap the visualizer's frame rate (e.g. 30 fps) if the die goes above 85 °C.
  - Phase 3: if DVFS is ever added via devfreq, `devfreq_cooling` can hang the GPU
    off the same thermal zone (needs `CONFIG_PM_DEVFREQ`, `CONFIG_DEVFREQ_THERMAL`).
    Stock never did this.

---

## 8. Proposed diag checks (spec only; nothing written)

### 8.1 `nq-diag-snapshot`: new section `POWER_DOMAINS_GPU`

All read-only and cheap; wrap in `timeout 5 nice -n 19`.

```sh
sub "pm_debug count";  catf /sys/kernel/debug/pm_debug/count
sub "pm_debug time";   catf /sys/kernel/debug/pm_debug/time
sub "genpd summary";   catf /sys/kernel/debug/pm_genpd/pm_genpd_summary
sub "genpd prm_gfx";   for f in current_state active_time total_idle_time devices; do
                          printf '%s=' "$f"; catf /sys/kernel/debug/pm_genpd/prm_gfx/$f; done
sub "gpu target-module rpm"
for f in runtime_status runtime_active_time runtime_suspended_time control; do
  printf '%s=' "$f"; cat /sys/devices/platform/ocp/5600fe00.target-module/power/$f
done
sub "gpu clocks"
grep -E 'dpll_(core|per)_m7x2_ck|l3-gfx-clkctrl|l3_div_ck' /sys/kernel/debug/clk/clk_summary
sub "gpu irq"; grep -E ' 53:|pvr|sgx' /proc/interrupts     # GIC SPI 21 = hwirq 53; Linux irq number differs
sub "gpu driver"; ls /sys/bus/platform/drivers/ | grep -i -E 'pvr|sgx'; lsmod | grep -i pvr
```

PRM/CM register reads, only where `devmem` exists. **PRM and CM addresses only**
(always accessible):

| Register | Address | Meaning |
|---|---|---|
| `PM_GFX_PWRSTCTRL` | `0x4a307200` | programmed state |
| `PM_GFX_PWRSTST` | `0x4a307204` | current state + LASTPOWERSTATEENTERED |
| `CM_GFX_CLKSTCTRL` | `0x4a009200` | CLKTRCTRL + GFX_*_GFCLK activity bits |
| `CM_GFX_STATICDEP` | `0x4a009204` | expected 0 |
| `CM_GFX_GFX_CLKCTRL` | `0x4a009220` | MODULEMODE, IDLEST, STBYST, CLKSEL (bit 24) |
| `PRM_VP_CORE_CONFIG/STATUS/VOLTAGE` | `0x4a307b40/44/4c` | §4 |

⚠️ **Never `devmem` inside `0x5600_0000-0x57ff_ffff` (SGX registers, incl. the
`0x5600fe00/fe10` OCP wrapper) unless `PM_GFX_PWRSTST` says ON and the clkctrl
says functional.** An access to a powered-down L3 target raises an L3 error and
can cause an imprecise external abort. On a 2-core box that can mean a reboot.

### 8.2 `nq-health-report`: new findings

- `gpu_awake_headless`: `gpu_active_ms` > 1 % of the window while
  `dss_active_ms` == 0 (HDMI off). Something is holding the GPU, probably a client
  that never released its context, or APM not working. Severity: warn.
- `gpu_never_sleeps`: `gpu_rpm == active` in every sample for more than 10 min.
  Points at missing runtime-PM enable or an APM regression. Severity: warn.
- `gpu_c3_drop`: C3 share drop > 5 pp against the last clean idle window with
  `gpu_active_ms > 0`. Severity: info, plus attribution of the `gpu_irqs` rate.
- **VDD_MPU-vs-OPP under GPU load**: reuse the existing `vdd_mismatch` event. Flag any
  mismatch in a window with `gpu_active_ms > 0` separately. A CORE-side droop would
  not show on VDD_MPU, but board-level PSU sag would.

### 8.3 Bring-up checklist for the first GPU boot (read-only verification)

1. `gpu fck`: the parent must be `dpll_per_m7x2_ck`, rate 307 200 000 (or 153 600 000
   per §4's gate).
2. VDD_CORE was measured (§4) and recorded in the bring-up doc.
3. After `pvrsrvkm` loads **and `pvrsrvinit` has completed** (*corrected 2026-10-11,
   Addendum APM:* before `pvrsrvinit` the device is OFF by default, so that reading
   proves only patch (d)), with no client: within 1 s, `prm_gfx` is `off-0` and
   `runtime_status=suspended`. If not, APM or runtime PM is broken; do not proceed to
   soak. Expect this step to **fail** with the unmodified openpvrsgx `pvr-drv.c`: its
   probe-time `pm_runtime_get_sync()` reference is never dropped (see TL;DR 8). Check
   `power/runtime_usage` on the `gpu@0` device as well (it should be 0 at idle).
4. During `kmscube`/visualizer: `prm_gfx on`, `gpu_irqs` rate plausible,
   `CM_GFX_GFX_CLKCTRL.IDLEST = functional`.
5. After the client exits: back to `off-0` within `sgx_apm_latency` + ε. (*Corrected
   2026-10-11, Addendum APM:* this needs microkernel APM events or (h). The client's
   clean-up kicks power the device ON, and runtime-PM autosuspend alone never ends
   that.)
6. `dmesg` clean (no `EnableSGXClocks: pm_runtime_get_sync failed`, no L3 errors,
   no `omap_prm … timed out`).
7. The full nexusq-diag sweep, including CPU frequency and VDD_MPU vs OPP, per the
   standing rule.

---

## 9. Measurement protocol: idle and active cost of turning GFX on

### 9.1 Principles (already learned in this repo)

- **No ssh session during a window.** An open session drags the die to 74-79 °C and
  the OPP upward [REPO scripts/diag/README.md]. Use `systemd-run` detached samplers
  writing to files, and HA passive history (`ha-opp-window.py`).
- **Nothing playing.** Check `pactl list sink-inputs` before any window. Audio has its
  own 1312 µs QoS and changes the C-state mix [REPO 0058 header].
- **Same boot or same image for A/B where possible.** Arm transitions are module
  load/unload and client start/stop, not reflashes.
- **Settle ≥ 15 min** after any change. **Window ≥ 60 min** for idle arms, ≥ 15 min
  for active arms.
- **Counters, not samples:** take cumulative counters at window start and end. Use
  deltas only.
- **A result must be able to fail:** run each arm twice, and re-run A0 after A4 to
  check for drift (ambient, uptime).

### 9.2 Instruments per window (start/end snapshots, read-only)

| Instrument | Source |
|---|---|
| CPU idle | `/sys/devices/system/cpu/cpu{0,1}/cpuidle/state*/{usage,time}` |
| CPU freq | `cpufreq/policy0/stats/time_in_state`, `total_trans` |
| VDD_MPU | regulator `vdd_mpu` µV + `abb_mpu` (as healthd does) |
| Domains | `pm_debug/count`, `pm_debug/time`, `pm_genpd/prm_gfx/*`, `pm_genpd/prm_dss/*` |
| GPU rpm | `5600fe00.target-module/power/runtime_{active,suspended}_time` |
| IRQs | `/proc/interrupts` (GPU line, DSS line, totals), `/proc/softirqs` |
| Exits | 60 s `power:cpu_idle` + `sched:sched_switch` + `irq:*` + `ipi:*` trace at the window midpoint, as in the 2026-09-26 audit |
| Temp | `thermal_zone0/temp` (1 Hz in the sampler), TMP101 |
| Clocks | `clk_summary` filtered (§8.1) at start and end |
| Rail | VDD_CORE per §4: once per arm (it must not change) |
| Wall | wall power, see §9.4 |

`scripts/diag/nq-opp-study2.sh` already captures interrupts, softirqs, cpuidle and
time_in_state with playback guards [REPO scripts/diag/README.md]. Extend its snapshot
list with the GPU items instead of writing a new sampler (the README says so
explicitly: "do not hand-roll a one-off sampler").

### 9.3 Arms

| Arm | State | HDMI | What it isolates |
|---|---|---|---|
| **A0** | current image, no GPU driver (today) | unplugged (DSS off) | baseline: C3 share, exits/s, 350 MHz %, die °C, W |
| **A0h** | as A0 | plugged, LXQt/labwc on pixman, static desktop | the DSS/HDMI scan-out cost alone (CORE/L3 busy), so it is never blamed on the GPU |
| **A1** | `pvrsrvkm` loaded, services initialised, **no client** | unplugged | the driver's idle cost: should equal A0 (`gpu_active_ms` ≈ 0, no 20 Hz timer, prm_gfx off) |
| **A2** | GLES compositor (labwc on GLES2) idle, static desktop | plugged | idle compositor on the GPU vs A0h. Expect APM to power GFX off between damage events |
| **A3** | GPU visualizer at a fixed frame rate (30 and 60 fps sub-arms) | plugged | active cost: die °C, CPU OPP residency, exits/s, GPU IRQ/s, W |
| **A4** | same visualizer, software render (pixman/llvmpipe), same fps target | plugged | the comparison that justifies the GPU: CPU busy %, OPP residency, W, achieved fps |

For A3/A4, also record achieved fps and frame-time p95 from the client.

### 9.4 Wall power

- The Solight meter reads whole watts. 2026-09-23 runs could only say "3 W, flickers
  to 2 W" [REPO sleep-states design, "First wall readings"].
- The idle GPU effect (A1 vs A0) is expected to be at most tenths of a watt, so a
  **≥0.1 W-resolution meter is a prerequisite**. Otherwise report "below instrument
  resolution" and rely on residency and IRQ deltas.
- Ask Petr for the instrument. Options: a lab-grade plug meter, or a DC shunt between
  the internal PSU and the board, which is a hands-on modification and his call.
  Integrate energy over the whole window (Wh / h), not instantaneous readings.

### 9.5 Pass/fail criteria (proposed)

| Check | Pass |
|---|---|
| A1 vs A0 (idle, HDMI off) | ΔC3 share ≥ −1 pp; Δidle exits/s ≤ +5 %; `gpu_active_ms` ≤ 0.1 % of window; `prm_gfx` `off-0` at window end; Δ350 MHz residency ≥ −0.5 pp; ΔW below meter resolution |
| A2 vs A0h (idle desktop) | `gpu_active_ms` ≤ 2 % of window; ΔC3 share ≥ −3 pp; no new IRQ source > 5/s at a static screen |
| A3 | die temperature < 85 °C steady at 30 fps; no `vdd_mismatch`; no XRUN if audio is later layered on (separate test, Petr drives listening); frame pacing stable |
| A3 vs A4 | the GPU arm uses less CPU (busy %) **and** spends more time at 350 MHz than the SW arm at the same fps. If not, the GPU path does not pay for itself |
| All | the full diag sweep is clean after each arm, CPU frequency and VDD_MPU vs OPP included |

### 9.6 Order and safety

1. A0 and A0h on the current image (they double as the baseline the GPU work is
   judged against). This can be done today, without a GPU driver.
2. VDD_CORE measurement (§4) before any GPU kernel is booted.
3. A1 in the kernel-OTA trial slot (a hang costs a power cycle, not a reflash
   [REPO 0058 header]), with the hardware watchdog armed as in
   `nq-deep-idle-ladder.sh`.
4. A2-A4 only after A1 passes.
5. Wrap every device-side command in `timeout` + `nice`. No unbounded loops. No test
   tones.

---

## 10. Recommended phasing (power view)

1. **Phase 0 (no GPU code):**
   - DT `assigned-clocks` → `dpll_per_m7x2_ck` @ 307.2 MHz (stock parity; inert while
     no driver runs);
   - healthd `gpu_active_ms` / `gpu_rpm` / `dss_active_ms`;
   - nq-diag-snapshot `POWER_DOMAINS_GPU`;
   - measure VDD_CORE;
   - run A0/A0h.
2. **Phase 1:**
   - KM with **APM on, latency 100 ms** (the letux AM4 default is 2 ms), and the glue's
     probe-time runtime-PM reference dropped so that `gpu@0` can actually suspend
     (Maemo `2cd8d74ec61a`); if the Addendum APM observation shows no microkernel APM
     events, add (h), the host-side idle power-down;
   - fixed 307.2 MHz, no DVFS;
   - run arms A1-A4.
3. **Phase 2 (only if A3 shows the CPU-side cost matters):** frame-rate capping in
   the visualizer, IRQ affinity experiments, compositor damage tuning.
4. **Phase 3 (optional, beyond phase-1 parity):**
   - a `steelhead,vc-core-supply` regulator modelled on patch 0015's VC bridge (VP
     force-update on the `core` voltdm);
   - an OPP-v2 table on the GPU node {153.6 MHz @ 962 mV, 307.2 MHz @ 1127 mV,
     opt-in 384 MHz @ 1250 mV};
   - devfreq (simple_ondemand) with `devfreq_cooling`;
   - the regulator framework's max-of-consumers aggregation reproduces stock's voltdm
     semantics;
   - **any VDD_CORE scaling must also enforce stock's MPU→CORE dependency** (MPU
     ≥ 700 MHz ⇒ CORE ≥ 1127 mV), or cpufreq to 1.2 GHz breaks the stock rule.

   This also opens the bigger, GPU-independent idle win: CORE OPP50 (L3 100 MHz,
   962 mV) at idle, which stock could reach and we cannot. It needs its own
   stock-parity audit (DDR/EMIF at L3 100 MHz, DSS bandwidth). It is high risk and
   should not ride along with the GPU.

---

## Open questions

1. What is VDD_CORE (VCORE1) actually at on our units? (§4) It decides between
   307.2 MHz and 153.6 MHz for phase 1.
2. ~~Does the KM build call `pm_runtime_enable()`?~~ **Answered in verification:** yes.
   The openpvrsgx glue `pvr-drv.c` `pvr_probe()` enables runtime PM, but it also keeps a
   `pm_runtime_get_sync()` reference for the device's lifetime (pvr-drv.c:440-465). The
   open question is now: patch the glue to drop that reference after probe, and confirm
   on hardware that `prm_gfx` then reaches `off-0` between frames and at idle.
3. ~~Which AM_VERSION header?~~ **Answered in verification:** the top-level
   `drivers/gpu/drm/pvrsgx/Makefile:95` builds OMAP4/SGX540 rev 120 with `AM_VERSION=4`,
   so `sysconfig-am4.h` applies: `SYS_SGX_CLOCK_SPEED 200000000`, PDS timer 1000 Hz,
   HW recovery 50 Hz, `SYS_SGX_ACTIVE_POWER_LATENCY_MS 2`. The `=100` override sits in a
   `ccflags-n` (disabled) list [PVR117 Makefile:301-304]. Still open: `SYS_SGX_CLOCK_SPEED`
   must be changed to match the real 307.2 MHz (or taken from `clk_get_rate`), and the
   APM latency raised to stock's 100 ms.
4. Does SGX smart-standby (MIDLE=SMART_WKUP) actually let L3_2/CORE idle when SGX
   is powered but idle? This is moot today (CORE pinned by USB) but needed if
   Ethernet power-down is ever done. Measure with `CM_L3_2_CLKSTCTRL` activity bits
   and GFX powered, client idle.
5. ~~What does stock's `gfx_l3_rates` encode?~~ **Answered in verification:** it is
   OMAP2/3 clock data (the `gfx_l3_fck` clksel rate table) compiled into the
   multi-platform stock kernel. It has nothing to do with OMAP4 and no mainline gap.
6. Did stock actually reach VDD_CORE OPP50 / L3 100 MHz at idle? Check with a stock
   RAM boot (`stock-adb-boot.img`) by reading `CM_CLKSEL_CORE` / `l3_div` and the
   VCORE1 vsel. This sizes the possible phase-3 idle win independently of the GPU.
7. Is the APM power cycle (GFX OFF→ON) at 30-60 fps with gaps > 100 ms ever
   triggered by the visualizer? If yes, what is the cost in µs per cycle (PRM
   transition + ukernel restore)?
8. Wall-power instrument: which ≥0.1 W meter does Petr have or want, and is a DC-side
   shunt acceptable?
9. Die temperature under A3. Is a frame-rate cap needed to stay under ~85 °C next to
   librespot/PulseAudio load?
10. Did stock steelhead (Android 4.x / Nexus Q UI) actually spend time at 384 MHz,
    or did its UI rarely hit max? Not answerable without a stock runtime trace
    (`/proc/.../sgx_idle` log exists in stock: the `sgx_idle_log*` symbols).

---

## Sources

### Repository (dc988b9)
- `docs/2026-06-19-gpu-sgx540-acceleration-research.md` (prior feasibility; 6.12-era)
- `docs/2026-09-20-sleep-states-design.md` §4u (CORE never idles; USB/L3INIT;
  Petr's decision), "Power target" and "First wall readings" (Solight, 1 W step), §4m
  (QoS), 2026-09-25 status (C3 86 %)
- `docs/2026-09-26-idle-audit-five-pollers.md` §1-4 (C3 89.6/92.7 %, 350 MHz
  99.82 %, 353 exits/s, coupled-idle IPIs)
- `docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §1 (VDD domains, VCORE1 0x55/0x56,
  SMPS_OFFSET)
- `kernel/patches/0015-…vc-mpu-bridge-regulator.patch` (VC-bridge pattern),
  `0024`, `0027`, `0048`, `0054`-`0058` (headers read), `0003-…steelhead.patch:624-628,
  916-933` (TMP101, cpu0 OPPs)
- `kernel/configs/steelhead_defconfig` (`# CONFIG_PM_DEVFREQ is not set`,
  `# CONFIG_POWER_AVS_OMAP is not set`, `CONFIG_PM_OPP=y`, `CONFIG_TI_SYSC=y`, thermal set)
- `userspace/nq-healthd/nq-healthd.c:225-330, 1641-1688`
- `pmos/device-google-steelhead/nq-diag-snapshot:94-122`, `nexusq-wayland.sh`
- `scripts/diag/README.md`, `scripts/diag/nq-deep-idle-ladder.sh:129,147`
- `PLAN.md` §4 GUI (line 2160ff)

### Stock firmware (reverse-eng/vmlinux.bin, 3.0.8-gad584da)
- `omap446x_opp_def_list` @0xc0043d5c (gpu/l3/mpu/iva/fdif/dsp OPPs)
- `omap446x_vddmpu_dep_info` @0xc0706900, `omap446x_vdd_mpu_core_dep_data` @0xc0706c50,
  `omap446x_vddiva_dep_info` @0xc07068e0, `omap446x_vdd_iva_core_dep_data` @0xc0706c38
- `SysDvfsInitialize` @0xc0290f80, `RequestSGXFreq` @0xc0290c28, `EnableSGXClocks`
  @0xc0290d18, `DisableSGXClocks` @0xc0290dec, `SysSGXIdleTransition` @0xc029091c,
  `sgx_idle_work_func` @0xc028fa54, `sgx_idle_timer_callback` @0xc028f700,
  `SysGetSGXTimingInformation` @0xc0290bb0, `SysDevicePre/PostPowerState`
  @0xc0290820/0xc0290878
- `sgx_apm_latency` @0xc0725b9c = 100, `sgx_idle_timeout` @0xc0725ba0 = 1 000 000,
  `sgx_idle_mode` @0xc0725ba4 = 2; module param strings `pvrsrvkm.sgx_*` (file offset 0x57a17c…)
- `omap_init_gpu` @0xc0556ac0; `omap4_steelhead_display_init` @0xc0075ef8 (gpu_fck →
  dpll_per_m7x2_ck)
- `gfx_44xx_pwrdm` @0xc070abc8, `core_44xx_pwrdm` @0xc070aa98, `dss_44xx_pwrdm`,
  `ivahd_44xx_pwrdm`; `omap44xx_gpu_hwmod` @0xc0715264, `omap44xx_gpu_sysc` @0xc07181ec,
  `omap44xx_gpu__l3_main_2` @0xc0717c60; `gfx_l3_rates` @0xc05633e0

### Mainline Linux v6.18.48 (commit 5bbb9c9f8f80, git.kernel.org stable)
- `arch/arm/mach-omap2/powerdomains44xx_data.c:56-71`, `clockdomains44xx_data.c:97-102,184-194`,
  `clockdomain.c:470-494`, `pm44xx.c:172-179,265-275`, `pm.c:137-161`, `powerdomain.c`
  (`_pwrdm_state_switch`), `omap-mpuss-lowpower.c:260,305`, `pm-debug.c:52,231-232`,
  `prm44xx.h:28,45,53,77-112`, `cm2_44xx.h:26,39,57`, `cm44xx.h:21`
- `arch/arm/boot/dts/ti/omap/omap4.dtsi:484-509,805-822`, `omap443x.dtsi:78-86`,
  `omap4460.dtsi:11-77`, `omap44xx-clocks.dtsi:367-377,734-744,1395-1410`,
  `omap4-cpu-thermal.dtsi`
- `drivers/clk/ti/clk-44xx.c:327-340,703`, `drivers/clk/ti/clkctrl.c` (`_omap4_clkctrl_clk_enable`)
- `drivers/bus/ti-sysc.c:1001,1125-1205,1534-1536,1609-1610,1948-1955,2379-2420`
- `drivers/pmdomain/ti/omap_prm.c:104-133,158-220,566-604`
- `Documentation/devicetree/bindings/gpu/img,powervr-sgx.yaml`

### External (opened 2026-10-11)
- https://github.com/openpvrsgx-devgroup/linux_openpvrsgx: branch list via
  `git ls-remote`; `letux/pvrsrvkm-1.17.4948957` @ `584dd33a` (2025-05-05) cloned:
  `eurasia_km/Makefile:100-132,200-240,219` (APM on, `SYS_OMAP_HAS_DVFS_FRAMEWORK` in
  `ccflags-n`), `services4/system/omap/sysutils_linux.c:150-265`,
  `services4/system/omap/sgxfreq.c:394-540` (DRA7 clocks),
  `services4/system/omap/sysconfig*.h` (AM_VERSION headers, 200 MHz / 2 ms),
  `services4/srvkm/devices/sgx/sgxpower.c:53-70,200-225,300-325`;
  `letux/omap-pvr-soc-glue-v10` @ `57c9a409` (2026-08-17, Linux 7.2.0): OMAP4 dtsi files
  identical to 6.18.48.
- Added in verification (2026-10-11): openpvrsgx `drivers/gpu/drm/pvrsgx/pvr-drv.c` and
  `drivers/gpu/drm/pvrsgx/Makefile` from branch `pvrsrvkm-6.18-rc6` @ `d2f1e031` (pvr-drv.c
  last changed in `e24a724f`, 2025-11-16). The same pvr-drv.c, omap4.dtsi, omap4460.dtsi and
  OMAP `sysutils_linux.c` were fetched from branch `pvrsrvkm-7.2` @ `2342ce92`
  (2026-08-26), which merges `letux/omap-sysc-prm-gfx` and
  `letux/pvrsrvkm-1.17.4948957-v3` (@ `e5de7556`, 2026-08-21). Its `omap_prm.c` is
  identical to 6.18.48, and its `ti-sysc.c` differs only in `kzalloc_obj()` conversions.
- https://raw.githubusercontent.com/torvalds/linux/v3.0/arch/arm/mach-omap2/clock_common_data.c
  (`gfx_l3_rates`) and `clock3xxx_data.c` (`gfx_l3_clksel` → `gfx_l3_fck`).
- https://android.googlesource.com/kernel/omap/+/refs/heads/android-omap-tuna-3.0-jb-mr2/arch/arm/mach-omap2/powerdomains44xx_data.c
  (`gfx_44xx_pwrdm` OFF/INA/ON; `core_44xx_pwrdm` `PWRSTS_RET_INA_ON`) and `cpuidle44xx.c`
  (no bus-master or activity check before deep states).
- https://android.googlesource.com/kernel/omap/+/refs/heads/android-omap-tuna-3.0-jb-mr2/arch/arm/mach-omap2/opp4xxx_data.c:
  OMAP4460 VDD_CORE 962/1127/1250 mV; gpu and l3 OPP rows; the 384 MHz gpu row is `false`
  in tuna; `OMAP_ABB_NONE` on CORE.
- https://www.ti.com/pdfs/wtbu/OMAP4460_ES1.x_DM_Public_Book_V_A.pdf: TI SWPS046A
  (Jan 2012). Table 3-2 vdd_core 1200 mA incl. OPP119 % overdrive; "At OPP100, L3 clock is
  200 MHz and at OPP50, L3 clock is 100 MHz"; OPPBoot; CORE voltages deferred to the
  "DM Operating Condition Addendum" (not found).
- Searches for a published SGX540 / OMAP4 GFX power figure (2026-10-11) found none.
  Hits only gave whole-chip or system numbers:
  [OMAP4 product bulletin](https://www.ti.com/pdfs/wtbu/SWPT034A.pdf),
  [Google Glass energy study](https://arxiv.org/pdf/1404.1320),
  [XDA thread on 4460 SGX at 384 MHz](https://xdaforums.com/t/erm-shouldnt-omap-4460s-sgx-be-clocked-at-384-mhz.1368873/page-2),
  [Pandaboard ES SRM (VCORE1 1200 mA)](https://www.mouser.com/datasheet/2/668/Panda_Board_Spec_DOC-21054_REV0_1-471101.pdf).

### Live probe (2026-10-11 ~00:35 CEST, Prague Q, `hostname` = `steelhead`, 6.18.48-r20)
- Read-only, each command in `timeout` + `nice -n 19`: `clk_summary` grep, `pm_debug/count`,
  `pm_debug/time` (gfx/core/mpu/dss/l3init lines), `pm_genpd_summary` grep, `runtime_*`
  of `5600fe00.target-module`, `/proc/device-tree/ocp/target-module@56000000` listing,
  `dmesg | grep` (no hits), `regulator_summary` grep (no VDD_CORE regulator).
  Nothing was written, loaded or played. USB (`172.16.43.1`) and eth-direct (`10.42.0.2`)
  timed out; WiFi `192.168.20.246` answered.

---

## Verification (2026-10-11)

This is an adversarial re-check of the claims above against the cited sources:
- the v6.18.48 git tree (`5bbb9c9f8f80`, "Linux 6.18.48", committed 2026-08-28), re-read;
- `reverse-eng/vmlinux.bin`, re-disassembled with `nqdis.py`/`dump.py`/`callers.py`;
- the openpvrsgx clones, plus a fresh `git ls-remote` and raw fetches;
- the repo at `dc988b9`;
- the TI DM PDF, the Android tuna tree and Linux v3.0.

**No device was touched.** All [LIVE] numbers are therefore *not reproduced*. They were
only checked for internal consistency (see the timebase caveat in §1.3).

### Confirmed

- `sgx_module: target-module@56000000` with ti-sysc, `prm_gfx`, `OMAP4_GPU_CLKCTRL` fck,
  `gpu@0` "ti,omap4430-gpu","img,powervr-sgx540", GIC SPI 21, no `status` [6.18.48
  omap4.dtsi:484-509]. No patch in `kernel/patches/` touches sgx/gpu (only 0007 matches,
  and that is a clk-composite patch).
- 443x reparents to `dpll_per_m7x2_ck` at 307.2 MHz [omap443x.dtsi:78-86]; omap4460.dtsi
  has no sgx entry and only `abb_mpu`/`abb_iva`.
- GPU mux parents `{dpll_core_m7x2_ck, dpll_per_m7x2_ck}`, bit 24, `CLKF_SW_SUP`, clkctrl
  at 0x4a009220 [clk-44xx.c:327-340, 703]. M7 HSDIVs carry `ti,autoidle-shift = <8>`.
- Stock `omap4_steelhead_display_init` does `clk_get(NULL,"dpll_per_m7x2_ck")`,
  `clk_get(NULL,"gpu_fck")` and `clk_set_parent` at 0xc0075f08-0xc0075f48.
- Stock `omap446x_opp_def_list` decoded entry by entry: gpu 153.6/307.2/384 MHz @
  962/1127/1250 mV, all available; l3_main_1 100@962, 200@1127, 200@1250. `omap4_opp_init`
  passes all 22 rows (0x16) and only additionally enables MPU 1.2 GHz behind a feature
  bit. Tuna's 384 MHz row is `false`; its CORE uses `OMAP_ABB_NONE` (googlesource,
  fetched today).
- MPU→CORE dependency (4 rows) and IVA→CORE (3 rows) from @0xc0706c50 / @0xc0706c38.
- Stock GPU policy: `sgx_apm_latency`=100, `sgx_idle_timeout`=1 000 000, `sgx_idle_mode`=2.
  `SysGetSGXTimingInformation` stores HWRecoveryFreq 100, uKernelFreq 1000,
  bEnableActivePM 1. `omap_init_gpu` stores `device_scale=omap_device_scale`,
  enable/idle/shutdown, and `ovfreqs=1` on 0x446.
  Enable/Disable use `__pm_runtime_resume/idle(dev, RPM_GET_PUT)` (sync), and call
  `RequestSGXFreq` only when `sgx_idle_mode == 0`. The adaptive branch computes
  3 000 000 − gap when the gap is ≤ 1 999 999 ns.
- **Upgraded from "likely" to verified:** `RequestSGXFreq` picks `list[(count+1)-2]` =
  the highest *available* OPP (384 MHz) for max and `list[0]` (153.6 MHz) for min.
  `SysDvfsInitialize` allocates count+1 entries, duplicates the max as a sentinel and
  starts at the sentinel index. So the CoreClockSpeed first reported to the ukernel is
  384 MHz.
- `gfx_44xx_pwrdm.pwrsts` 0x0d (core 0x0e). It matches tuna source
  `PWRSTS_OFF_INA_ON` / `PWRSTS_RET_INA_ON`.
- Mainline: `gfx_pwrdm` is in voltdm core, `PWRSTS_OFF_ON`. `clkdm_complete_init()`
  clears all deps, and `omap4_static_dep_map` adds only mpuss/ducati. Stock: the
  `l3_gfx_clkdm` string is referenced only from clkdm data, the mpuss/ducati possible-dep
  lists and the `gpu_fck` clock.
- `prm_gfx` is `omap_prm_onoff_noauto` at 0x4a307200. Patch 0057 removes only
  prm_mpu/prm_core from genpd.
- `pm_debug` sampling: `pwrdm_pre/post_transition(NULL)` at omap-mpuss-lowpower.c:260/305;
  genpd writes PWRSTCTRL directly (`omap_prm_domain_power_on/off`, omap_prm.c:522-604).
- The PVR 1.17 host timer is `1000*50/uKernelFreq` ms. It is disabled on any non-ON
  transition and re-enabled on ON. The letux AM4 header also uses uKernelFreq 1000, so
  the period is 50 ms there too.
- No `pm_qos`/`cpu_latency_qos` in the 1.17 tree outside s5pc110 or in `pvr-drv.c`.
- GLUE10 `57c9a409` is Linux 7.2.0, and its omap4/4460/443x dtsi are byte-identical to
  6.18.48. The same holds on `pvrsrvkm-7.2` @ `2342ce92` (2026-08-26). The
  `letux/omap-sysc-prm-gfx` branch (head `5c31c028`, 2026-08-16, an OMAP5 IVA clkctrl
  commit) leaves omap_prm.c identical and changes only `kzalloc_obj()` in ti-sysc.c.
  "No newer upstream OMAP4 GPU power work" stands.
- Thermal: one zone, passive 100 °C, critical 125 °C, cooling map `cpu0` only. The
  steelhead DTS patch has no thermal override. No sgxfreq/devfreq symbols in stock
  kallsyms. (The letux tree has a `sgxfreq_cool.c`, but it is not built, see §2.3.)
- Defconfig: `# CONFIG_PM_DEVFREQ is not set` (4208), `# CONFIG_POWER_AVS_OMAP is not set`
  (331), `CONFIG_PM_OPP=y`, `CONFIG_TI_SYSC=y`.
- Patch 0027 (CORE VC ON/ONLP 1.2 V, VCORE1 0x55/0x56) and the 0055 header
  (`VDD_*_I2C_DISABLE` ⇒ AUTO_CTRL sends nothing) say what the report says.
- healthd schema fields and the append-only rule [nq-healthd.c:1641-1688].
  `nq-diag-snapshot` has no `pm_debug`/`genpd` dump. Idle-audit numbers: C3
  89.6/92.7 % (cottage), 86 % (Prague); 350 MHz 99.82 %; 353 exits/s on r111; die
  40.3 °C cottage / 48.9 °C Prague. Sleep-states §4u, the 2026-09-23 decision, and the
  Solight whole-watt readings.
- TI SWPS046A (Jan 2012): vdd_core 1200 mA incl. OPP119 %; footnote (17) "At OPP100, L3
  clock is 200 MHz and at OPP50, L3 clock is 100 MHz"; CORE voltages deferred to the
  "DM Operating Condition Addendum".
- `img,powervr-sgx.yaml` forbids `clocks` and `power-domains` on `ti,omap4430-gpu`.
- Tuna `cpuidle44xx.c` has no bus-master or activity check before deep states. This
  backs the kallsyms-only argument in §5.2, since a static helper could have been
  inlined.

### Corrected

1. **openpvrsgx runtime PM (claim 17, refuted as stated).** The OMAP system layer indeed
   never calls `pm_runtime_enable()`, but the DRM glue `pvr-drv.c` does, in `pvr_probe()`.
   The real defect is the opposite one: the probe's `pm_runtime_get_sync()` reference is
   never released on success. With that glue, GFX would stay ON while the driver is bound
   (code inference, not measured). TL;DR 8, §8.3 step 3, open question 2 and phase 1 are
   updated.
2. **`gfx_l3_rates` is OMAP2/3 `clksel_rate` data**, not an OMAP4 GFX firewall/QoS
   table. §3 and open question 5 are fixed.
3. **"L3 200 MHz = OPP100"** is now "OPP100 or OPP119 frequency band". It proves nothing
   about the CORE voltage (TL;DR 5, §2.3, §4).
4. **VP_CORE register read (§4 method 1)**: mainline's `omap_vp_init()` leaves
   INITVOLTAGE 0, and nothing force-updates the core VP. The read is now marked as
   expected to be uninformative.
5. **`SYS_OMAP_HAS_DVFS_FRAMEWORK` "in ccflags-n"**: it is never defined for any target.
   Its `ccflags-n` mention sits inside the sgx544-only block. `sgxfreq*.o` builds only with
   the non-existent `CONFIG_OMAP_SGX_FREQ`. The conclusion (no DVFS on OMAP4) stands.
6. **Open question 3 answered**: OMAP4/SGX540 builds with `AM_VERSION=4` → 200 MHz core
   clock, 2 ms APM latency. The 100 ms override is disabled (`ccflags-n`).
7. **ti-sysc citation for "idle but powered"**: that state is set by
   `sysc_enable_module()` (also SMART_WKUP), not by the disable path cited.
8. **1.19 s vs 60 ms explanation** is now marked as an inference, and a ≈245 s `pm_debug`
   vs runtime-PM/uptime timebase discrepancy in the [LIVE] data is noted. Reading
   `pm_debug/time` is itself a sample point.
9. Added: `i2cget` on the TWL6030 most likely needs `-f`, and the TMP101 shares address
   0x48 on a different bus.

### Could not reproduce or still unverified

- Every [LIVE] value: `prm_gfx off-0`, `runtime_active_time` 60 ms, the `pm_debug`
  counts and times, the clk rates 266.67/307.2/200 MHz, `regulator_summary` without
  VDD_CORE, and the device-tree listing. The brief did not allow device access. They are
  plausible and mutually consistent apart from the timebase note.
- That smart-standby SGX does not veto CORE idle (TRM semantics, never measured).
- The TWL6030 VCORE1 control-interface register address.
- That stock's `omap_device_scale` actually raised VDD_CORE to 1.25 V at 384 MHz. The
  code path is verified, a runtime trace is not.
- "No public per-block SGX540/GFX power figure": a re-search on 2026-10-11 again found only
  whole-system numbers (Notebookcheck GFXBench system power; Imagination/TI launch PR
  without figures). Absence of evidence stays UNVERIFIED.
- The stock pvrsrvkm string at "@0xc065a444": the "failed to set gpu_fck" text itself
  starts at 0xc065a44b. That is consistent with a 7-byte `"<3>%s: "` prefix, but the
  prefix was not dumped.

---

## Addendum (2026-10-11): Does GFX ever power off with the ti443x microkernel (built without APM, bit 15 = 0)?

**Verdict.** In the 1.17 KM, the only thing that powers the SGX device off at run time
is an active-power request **raised by the microkernel**. The KM has no idle timer of
its own. Before `pvrsrvinit` runs, the KM leaves the device OFF. `pvrsrvinit`'s
compatibility check then powers it ON, and so does every later kick, including the
clean-up kicks when a client exits. After that, only a microkernel APM event, system
suspend or module unload turns it OFF again. **So if the `ti443x` microkernel does not
raise APM events, GFX stays ON from `SGXInit` until suspend, with or without patch (d).**

Whether it raises them is still **UNVERIFIED**, and the evidence points both ways (Q1).
The plan therefore needs a KM-side fallback that is ready before Phase 1 (proposal (h)
below), and the Phase 1 exit has to be measured *after* `pvrsrvinit`, not merely after
`modprobe`.

Sources: openpvrsgx `pvrsrvkm-6.18-rc6` @ `d2f1e031d58a` (cited `ops:`, paths relative to
`drivers/gpu/drm/pvrsgx/1.17.4948957/eurasia_km/`, `pvr-drv.c` relative to
`drivers/gpu/drm/pvrsgx/`); TI `omap5-sgx-ddk-linux` branch `ti-img-sgx/1.17.4948957/k6.1`
@ `bfd9edef3f97` (cited `ti:`, relative to `eurasia_km/`); Maemo `droid4-linux` tag
`maemo-kernel-6.18.51.1` @ `db432aff895b` (cited `mae:`). All three were fetched on
2026-10-11 and read as text only. Maemo's `sgxutils.c`, `sgxinit.c`, `sgxpower.c`,
`power.c`, `module.c`, `sysconfig.c`, `sysutils_linux.c`, `sysconfig-am4.h`,
`sgx_options.h` and `Makefile` are byte-identical to openpvrsgx (`diff`). The only
difference is `pvr-drv.c`.

### Q1. Who raises the active-power event?

- **The microkernel, and only the microkernel.** The host writes
  `ui32ActivePowManSampleRate = uKernelFreq × latency_ms / 1000 + 1` into the shared
  `SGXMKIF_HOST_CTL` when `bEnableActivePM` is set. The source comment says: "The
  ukernel timer routine decrements the value of ui32ActivePowerCounter … When the
  ukernel timer decrements ui32ActivePowerCounter from 1 to 0, the ukernel timer will
  request power down" [ops: services4/srvkm/devices/sgx/sgxpower.c:169-187].
  The request is the bit `PVRSRV_USSE_EDM_INTERRUPT_ACTIVE_POWER` in
  `ui32InterruptFlags`, documented as "EDM requesting to be powered down"
  [ops: services4/include/sgx_mkif_km.h:122-124, 299]. No KM file writes
  `ui32InterruptFlags`: every match in `services4/` is a read (grep). The KM only sets
  the *clear* flags [ops: sgxutils.c:191, 606-610].
- **The consumer.** `SGXTestActivePowerEvent()` sees the flag, sets the clear bit and
  calls `PVRSRVSetDevicePowerStateKM(…, PVRSRV_DEV_POWER_STATE_OFF)`
  [ops: sgxutils.c:138-224, 205-206]. Its only caller is the MISR
  [ops: sgxinit.c:2103-2120], which is why 84db121f1016 also needed
  `SYS_USING_INTERRUPTS` ("otherwise sgx won't get idled").
- **The host timer is not a substitute.** `SGXOSTimer` (20 Hz) does HW-lockup detection
  only; it reads the power state and never changes it [ops: sgxinit.c:1816-1840].
- **Does the `ti443x` microkernel contain the counter code?** This cannot be settled from
  GPL sources. The microkernel is a binary inside TI's `libsrv_init.so`, and
  disassembling it was out of scope.
  - Evidence that it does not: its options word `0x00360018` lacks bit 15 [fw §3].
    TI's build file disables APM for **every** OMAP/AM target in the tree
    (`SUPPORT_ACTIVE_POWER_MANAGEMENT := 0` under "# Disable active power management",
    shared by ti335x, ti437x, jacinto6evm, omap5uevm, ti654x, ti443x, ti343x)
    [ti: eurasiacon/build/linux2/omap_linux/Makefile:90-98]. That the microkernel
    assembly is conditional on that define is UNVERIFIED (reasoning: the options word is
    a constant compiled into the microkernel, so the define was off when the microkernel
    was built; whether it gates the counter code is not visible to us).
  - Evidence that it does: two commit messages by Tony Lindgren for the Droid 4
    (OMAP4430, SGX540-120, the same `ti443x` userspace). Neither is a measurement.
    `84db121f1016` (2020-12-13) says "This seems to work just fine for PM as tested on
    droid4 with sway". But `pvr-drv.c` then already held its probe-time reference
    (`0ed3c444d68c`: `pm_runtime_get_sync()` at :322, released only at :357/:369). So
    that test cannot have seen genpd OFF. At most it saw the KM's device state change.
    Maemo `2cd8d74ec61a` (2023-11-14), "gpu: pvr: Enable runtime PM autosuspend for
    pvr-drv", says "This allows idling the pvr sgx hardware when not in use" and
    "depends on … 'Force enable limited runtime PM support for ddk 1.17'". After
    `pvrsrvinit`, that idling can only come from microkernel APM events, so the message
    implies they arrive. It is a claim, not a recorded reading.
  - No reply on the openpvrsgx list carries a power reading (thread 2020-12 #452,
    fetched 2026-10-11). In March 2020, Jonathan Bakker's S5PV210 1.17 port kept "the
    clock and power domain always enabled at probe" because "active power management is
    disabled for the blobs" (openpvrsgx-devgroup 2020-March/000257).

### Q2. Power state after `SGX_DEVINITPART2` and after the last client closes

| Moment | What the KM does | Evidence |
|---|---|---|
| `SysInitialise` (module load, APM compiled in) | enables SGX clocks for device init, then `DisableSGXClocks()`: "SGX defaults to D3 power state" | ops: services4/system/omap/sysconfig.c:464-473, 485-488 |
| `DevInitSGXPart2KM` | sets `POWMAN_NO_WORK`; registers the device with current **and default** state `OFF`, unconditionally (TI identical) | ops: sgxinit.c:1043-1052; ti: same lines |
| `PVRSRVFinaliseSystem` (reached only from `pvrsrvinit`'s `INITSRV_DISCONNECT`) | `SysFinalise` enables, then disables the clocks again; devices are set to DEFAULT (= OFF); then `SGXDevInitCompatCheck` → `SGXGetMiscInfoUkernel` → `SGXScheduleCCBCommandKM(GETMISCINFO)`, which **powers the device ON** before the kick | ops: bridged/bridged_pvr_bridge.c:3784; common/pvrsrv.c:699-716, 747-775; sysconfig.c:528-535, 568-571; sgxinit.c:2745, 2887-2925; sgxutils.c:712-714 |
| ON → `SysDevicePostPowerState` | `EnableSGXClocks()` → `pm_runtime_get_sync()`: the DDK now holds one runtime-PM reference | ops: sysconfig.c:1145-1153; sysutils_linux.c:211-217 |
| Client exits | resource-manager clean-up calls `SGXCleanupRequest()`, which kicks `SGXMKIF_CMD_CLEANUP` through `SGXScheduleCCBCommandKM()`: power **ON** again, never OFF | ops: sgxutils.c:851-890, 966, 1033, 1586 |
| Paths to OFF | (1) APM event via the MISR [sgxutils.c:205]; (2) system suspend `PVRSRVSetPowerStateKM(D3)` via `pvr_pm_ops` (noirq) [module.c:574-596; pvr-drv.c:245-261]; resume returns the device to DEFAULT = OFF [power.c:536-560, 612-640]; (3) unload [pvrsrv.c:946-947]; (4) `/proc/pvr/power_control`, only if `DEBUG && PVR_MANUAL_POWER_CONTROL` [module.c:700-750] | grep of all `POWER_STATE_OFF`/`SetPowerStateKM` call sites |

So with the module bound, `pvrsrvinit` run and no microkernel APM events:

- the DDK keeps its own `pm_runtime_get_sync()` reference, so `runtime_usage` ≥ 1;
- `prm_gfx` stays ON;
- the 20 Hz `SGXOSTimer` keeps ticking, because it is only disabled in `SGXPrePowerState`
  on a non-ON transition [sgxpower.c:300-320];

and this holds whether or not patch (d) is applied. Patch (d) removes only the
*probe's* reference. **Before** `pvrsrvinit`, a module with (d) applied should reach
`off-0` regardless of APM (code inference, UNVERIFIED on hardware).

### Q3. How TI and Lindgren gated the clock

- **TI (APM = 0) did not gate it at run time at all.** Without APM,
  `EnableSystemClocksWrap()` turns the SGX clocks on at `SysInitialise` ("The SGX Clocks
  are enabled separately if active power management is enabled")
  [ti: services4/system/omap/sysconfig.c:107-123]. `SysDevicePrePowerState` and
  `SysDevicePostPowerState` are no-ops without APM [ti: sysconfig.c:1159-1219]. The clocks
  are dropped only by `DisableSystemClocks()` → `DisableSGXClocks()` →
  `pm_runtime_put_sync()`, which happens at system D3 and unload
  [ti: sysconfig.c:1040-1076, 671; sysutils_linux.c:262, 623-636]. TI's products keep
  SGX powered from module load to suspend.
- **Lindgren** did it in two steps:
  1. `84db121f1016` compiles APM and `SYS_USING_INTERRUPTS` into the KM, hides bit 15
     from the userspace check, and turns `DisableSGXClocks` into
     `pm_runtime_mark_last_busy()` + `pm_runtime_put_autosuspend()` (GitHub API diff,
     fetched 2026-10-11).
  2. `2cd8d74ec61a` (Maemo only, not in openpvrsgx at `d2f1e031`) balances the probe:
     `pm_runtime_use_autosuspend()`, a **2000 ms** delay, and
     `pm_runtime_mark_last_busy()` + `pm_runtime_put_autosuspend()` after
     `drm_dev_register()` [mae: pvr-drv.c:440-443, 469-470].

  The power-off itself still waits for the microkernel's APM event. **"Gate on screen
  blank" works only because a blanked compositor stops kicking the GPU and the
  microkernel then requests power-down.** Nothing in the KM watches the screen.
- **Patch (d) already exists.** Maemo `2cd8d74ec61a` is our patch (d). Adopt it and
  change the delay to 100 ms; do not write a new one. Its `pvr_remove()`
  [mae: pvr-drv.c:488-504] takes a `get_sync` and then puts twice when the device was
  already active. Whether that underflows the usage count, given the DDK's own put
  during `pvr_drm_unload()`, is UNVERIFIED (reasoning only). Review it at the compile
  gate together with the existing remove-order fix.

### What to do if APM is dead: proposal (h), a host-side APM

Ranked by how fully each option restores stock behaviour (GFX OFF ~100 ms after the
last job, between frames and at idle):

1. **(h) KM-side idle power-down, in our system layer.** This is preferred. Use the two
   empty system hooks:
   - `SysSGXCommandPending()` runs on every kick [ops: sgxutils.c:733]. It
     (re)arms a delayed work item at `sgx_apm_latency` (100 ms).
   - `SysSGXIdleEntered()` [ops: services4/system/omap/sysutils_linux.c:704-718] stays
     as it is.

   The work item does what `SGXTestActivePowerEvent` does:
   `PVRSRVPowerLock(KERNEL_ID, IMG_FALSE)` → `PVRSRVSetDevicePowerStateKM(OFF)` →
   the `SGXPostActivePowerEvent` restart check → unlock.

   Why it is safe: `SGXPrePowerState` sends the microkernel `PVRSRV_POWERCMD_POWEROFF`
   and polls for `POWMAN_POWEROFF_COMPLETE` [sgxpower.c:296-345]. That is the same
   host-initiated command system suspend uses, so it does not depend on the APM counter
   (UNVERIFIED that the `ti443x` microkernel implements it; suspend on the Droid 4
   implies it does). The next kick powers the device back ON by itself
   [sgxutils.c:712-714].

   - Hazard: a job that is still running when the timer fires makes the poll wait up to
     `MAX_HW_TIME_US` while holding the power lock. Re-arm the timer from the MISR as
     well, so it measures time since the last *completion*.
   - Gate: (h) runs only when the observation below shows no APM events. A module
     parameter `sgx_host_apm` (default: auto) keeps it out of the way if stock-style
     APM works.
   - Instrumentation: count the events for both paths (microkernel
     `ui32NumActivePowerEvents`, our forced-off count) in a read-only module parameter,
     so that healthd can read them without debugfs.
2. **Forced D3 on last-client close** (a `drm_driver.postclose` hook when the open count
   reaches 0, after the clean-up kicks). This covers the Phase 1 and Phase 4 exits, but
   not idle *between* frames of a live client. It is a subset of (h).
3. **An explicit idle ioctl or sysfs knob** called by the visualizer and the
   screensaver. It works, but it moves power policy into userspace and fails open when a
   client crashes. Use it only as a debugging aid; the DDK's own
   `/proc/pvr/power_control` is the precedent and is DEBUG-only.
4. **Unload the module when the visualizer stops.** This is correct by construction:
   unload ends at OFF and the probe reference is released. But every start then costs a
   `modprobe` + `pvrsrvinit`, and the 10-cycle Phase 1 test becomes a product path. It is
   the last resort.

### The observation that settles it (re §10 item 5, made concrete)

1. On the trial slot, with patch (d) applied and (h) disabled:
   1. `modprobe`, then read genpd `prm_gfx` and `gpu@0` `power/runtime_usage`.
      Expected `off-0` / 0. This proves (d).
   2. Run `pvrsrvinit` (`SGXInit … [ OK ]`), wait 1 s, and read the same pair.
   3. With a no-op client (open the device node, close it) and 1 s idle, read the pair
      again.
2. Count microkernel APM events. Our KM gets a one-line counter in
   `SGXTestActivePowerEvent`'s APM branch (sgxutils.c:187-210); the in-tree
   `SGX_MISC_INFO_REQUEST_ACTIVEPOWER` [sgxinit.c:3295-3297] needs a UM client, so it is
   not the probe.
3. Read the result:
   - `off-0`, `runtime_usage` 0 and a counter > 0 mean APM works, and (h) stays off.
   - ON, `runtime_usage` 1 and a counter of 0 mean APM is dead, and (h) is required.
4. Seen failing: run step 1.2 once with the counter patch and (h) disabled.
   Whichever answer comes out, one of the two builds goes red.

### Corrections this needs (applied in place, 2026-10-11)

- **Groundwork §4 Phase 1 exit:** "with the module loaded and no client" now reads
  "after `pvrsrvinit` completed and with no client". Before `pvrsrvinit` the criterion
  passes trivially (default state OFF), so it would test (d) and not APM. If APM is dead,
  the exit needs (h).
- **Groundwork §4 Phase 4 exit:** the earlier note "without APM the bound is presumably
  the runtime-PM autosuspend after the client closes" is **wrong**. The client's
  clean-up kicks power the device ON, and the DDK's reference blocks autosuspend. Without
  APM the bound is (h)'s latency, or never.
- **Groundwork §2 patch (d) and §5 P1:** (d) = adopt Maemo `2cd8d74ec61a` with the delay
  set to 100 ms. P1's fix is necessary but not sufficient: after `SGXInit`, GFX OFF also
  needs APM or (h).
- **Groundwork §5 P3:** the mitigation "without APM, close the client when not visible
  so runtime PM powers GFX off" is **wrong**, for the same reason. It now reads: (h).
- **Groundwork §5 P9:** not moot without APM. With (h), the same churn applies at (h)'s
  latency.
- **RE master §4.4 and §12.1 row 6:** the KM side is now settled (microkernel-only
  producer, no KM timer, TI keeps the clocks on). Only the microkernel side stays
  UNVERIFIED, with Lindgren's two claims as evidence for it.
- **This note:** §8.3 steps 3 and 5 and §10 phase 1 were updated to match.
- **`kernel-driver-port.md`:**
  - §11 "Expect APM power-down after `SYS_SGX_ACTIVE_POWER_LATENCY_MS`" is now
    conditional.
  - §8 d's "Contradicting evidence" is resolved: the 2020 claim predates the probe fix.
    The fix is Maemo `2cd8d74ec61a` (2023).

### Not reproduced, or still open

- Whether the `ti443x` microkernel decrements `ui32ActivePowerCounter` and raises
  `ACTIVE_POWER` (the microkernel was not disassembled, by brief).
- Whether it handles the host `POWERCMD_POWEROFF` (implied by working suspend on Droid 4
  or Kindle Fire; not measured by anyone in a source we found).
- Whether the Droid 4 under Maemo really reaches GFX OFF at idle. Only commit messages
  say so. A Maemo bug report or a `/sys/kernel/debug/pm_genpd` dump from a Droid 4 would
  settle it without our hardware.
- The Maemo `pvr_remove()` double put (above).
- Whether the IDLE event (`PVRSRV_USSE_EDM_INTERRUPT_IDLE`), which stock used for
  `sgx_idle`, arrives from the `ti443x` microkernel. If it does, it would be a better
  trigger for (h) than kick time. Unknown.

---

## Addendum (2026-10-11): Live VDD_CORE without a device: derive it from the stock bootloader and the TWL6030 register map

*(Corrected 2026-10-11, same day: the live read in §6 below did not return `0x23`.
0x55 and 0x56 on 0x48 both read `0x00` while VCORE1 is on. The x-loader analysis
(§1-§3) stands; the read path in §4 does not. VDD_CORE is not readable from Linux,
and the gate needs a multimeter.)*

**Verdict.** The stock x-loader programs TWL6030 VCORE1 (VDD_CORE) to **vsel 0x23 =
1 139 440 µV** on every boot. It writes the target **1127 mV** (the 4460 CORE OPP100
nominal) through `PRM_VC_VAL_BYPASS`, slave 0x12, reg 0x55. The stock U-Boot carries
the same routine but skips it, because it runs from SDRAM. No code in 6.18.48 or in
our patches writes VCORE1's voltage after boot. The SR read-back path is already
excluded (§4). So the expected running VDD_CORE is **1.139 V**: 12.4 mV above the
1.127 V gate, so **307.2 MHz is allowed**. That margin is one SMPS step (12.66 mV)
and is smaller than any plausible DC accuracy of the SMPS (UNVERIFIED, no datasheet
figure). The gate still needs one live read; the multimeter is now only a cross-check.
**Expected readout:** `i2cget -y -f <bus> 0x48 0x55 b` → `0x23`, where `<bus>` is the
adapter of the `twl6030` client (i2c-0 on today's units). The probe now does this
(`nexusq-gpu-probe.sh --pmic`).

### 1. The x-loader (`xloader-phantasm-ian67k.img`, 47 984 bytes)

Mapping: file offset = VA − 0x40300000 + 0x200. Check: the string "OMAP%x ES%x.%x" at
file 0xb36b is loaded as literal `0x4030b16b` (file 0x5454). This is the same mapping
as `sys` §3.5's DPLL table (VA 0x4030a7cc, entry [6] at file 0xaa2c). Disassembled
with `arm-none-eabi-objdump -b binary -m arm --adjust-vma=0x40300000` over the image
without its 0x200-byte header.

| VA | What it is | Evidence |
|---|---|---|
| 0x40304860 | VC bypass write `(slave, reg, data)`: `word = (slave & 0x7f) \| reg<<8 \| data<<16` is stored at `*(0x4030a930) + 0x303aa0`, then stored again with bit 24 (VALID) set, then polled until VALID clears (0xffff tries). `*(0x4030a930)` = **0x4a004100** (file 0xab30). 0x4a004100 + 0x303aa0 = **0x4a307ba0 = `PRM_VC_VAL_BYPASS`** | 0x40304860-0x403048c0; literal 0x00303aa0 at 0x403048c8. A plain literal scan finds no `0x4a307ba0`; the address is base + offset, which explains why it was missed |
| 0x40305424 | `do_scale_vcore(reg, mV)`: compares the SoC revision with 0x44300100 (4430 ES1.0); otherwise `uV − 709 000` (0xad000 + 0x188); then `(x + 12 659) / 12 660 + 1`; then `bypass(0x12, reg, vsel)`. On failure it prints "Scaling voltage failed for 0x%x" (VA 0x4030b1a4) | 0x40305424-0x40305490; literals 0x3174 = 12 660, 0xfff6ba2c = −607 700 at 0x4030549c-0x403054a0. **Instruction for instruction, this is** U-Boot v2011.09 `do_scale_vcore()` ([clocks.c:501-530](https://raw.githubusercontent.com/u-boot/u-boot/v2011.09/arch/arm/cpu/armv7/omap4/clocks.c)): `PHOENIX_SMPS_BASE_VOLT_STD_MODE_WITH_OFFSET_UV 709000`, `offset_code = (offset + step − 1) / step; offset_code++` |
| 0x40305954 | **`do_scale_vcore(0x55, 0x467 = 1127)`** → VCORE1 | `mov r0,#0x55`; literal 0x467 at 0x40305ab8 (file 0x5cb8) |
| 0x40305960 | `printf("Setting TPS to %dmV", 0x4ba = 1210)`; `gpio_direction_output(7, 0)`; `bypass(0x60, 0x01, 0x47)` (TPS62361 SET1, 500 + 71·10 = **1210 mV**); on failure "Scaling voltage failed for vdd_mpu from TPS"; `gpio_set_value(7, 1)` | 0x40305960-0x403059a0; strings at VA 0x4030b2a0/0x4030b2b5 |
| 0x403059a4 | **`do_scale_vcore(0x5b, 0x45a = 1114)`** → VCORE2 (VDD_IVA) | literal 0x45a at 0x40305ac8 |
| 0x403057c8 | the function containing all of this (`prcm_init`-like; DPLLs follow at 0x403059b0+). It is called from 0x403051a0 **without any condition** | 0x40305160-0x403051a8 |

vsel for 1127 mV: ⌈(1 127 000 − 709 000) / 12 660⌉ + 1 = ⌈33.02⌉ + 1 = **35 = 0x23**.
Mainline's inverse (`twl6030_vsel_to_uv`, SMPS_OFFSET bit 3 set,
[omap_twl.c:82-83 @v6.18](https://raw.githubusercontent.com/torvalds/linux/v6.18/arch/arm/mach-omap2/omap_twl.c))
gives ((35 − 1)·1266 + 70 900)·10 = **1 139 440 µV**. VCORE2 1114 mV → vsel 0x21 =
1 114 120 µV. The 4460 offset branch is right for our unit: the efuse reads
`SMPS_OFFSET=0x7f` (bit 3 set) [docs/2026-07-02 §1].

Google's build differs from upstream in the voltages. Upstream v2011.09 sets VCORE1 to
1200 mV and the TPS to 1430 mV; v2011.12 and v2012.04 set the TPS to 1313 and 1203 mV
and keep VCORE1 at 1200 mV ([clocks.c:539-600 @v2011.09](https://raw.githubusercontent.com/u-boot/u-boot/v2011.09/arch/arm/cpu/armv7/omap4/clocks.c);
v2011.12/v2012.04 lines 283-317). Google uses the OPP100 nominals instead: CORE 1127,
IVA 1114, MPU 1210 ≈ 1203 rounded up to the TPS 10 mV grid. It also removes the
4430 branches (VCORE3 is never written). Upstream's comment on VCORE1:
"4430 : supplies vdd_mpu … 4460 : supplies vdd_core" (v2011.09 clocks.c:568-578).

### 2. The second-stage bootloader (`bootloader-phantasm-steelheadb4h0j.img`)

A uImage, "U-Boot 2011.09-rc1 for tungsten" (load 0x80100000, 0x40-byte header). It
contains the same routine: `do_scale_vcore` at 0x80101768, and the calls with 0x55 /
1127 (literal at file 0x1e4c), TPS 0x60/0x01/0x47 and 0x5b / 1114 (file 0x1e50) at
0x80101cc0-0x80101cfc. But its enclosing function (0x80101ad0, reached from
0x80101568) starts with `mov r3,pc; add r3,r3,#0x80000000; cmn r3,#0xb0000001; bls
0x80101df4`, and 0x80101df4 is the epilogue. While U-Boot runs from SDRAM (0x8xxxxxxx)
**the whole block, scale_vcores included, is skipped**. This is upstream's
`omap_hw_init_context()` gate: only `OMAP_INIT_CONTEXT_SPL / _UBOOT_FROM_NOR /
_UBOOT_AFTER_CH` run `scale_vcores()` (v2011.09 clocks.c:929-933). U-Boot's other
TWL6030 writes on 0x48 with immediate register numbers are to 0x98-0x9b, 0xa2, 0xe4,
0xe5 and 0xfa (0x80115764-0x80115bd8); none touches 0x52-0x57. This check is
heuristic: it only sees immediate operands. The only other `#0x55` in U-Boot is the
MBR signature byte (0x80100fa8).

So the last VCORE1 write before Linux is the x-loader's 0x23. The x-loader runs on
every boot, cold or warm, because the ROM loads it [AGENTS.md: those partitions are
never replaced].

### 3. Nothing in 6.18.48 plus our patches rewrites VCORE1

| Path | What it writes | Verdict |
|---|---|---|
| `omap_voltage_late_init` → `omap_vc_init_channel`, `omap_vp_init` | PRM VC/VP registers only (`SMPS_SA`, `VOL_RA`, `CMD_RA`, `VAL_CMD`, timings, VP config). No bypass and no PMIC transfer | [voltage.c:236-270, vc.c:805-880, vp.c:39-90 @v6.18](https://raw.githubusercontent.com/torvalds/linux/v6.18/arch/arm/mach-omap2/vc.c) |
| `voltdm_scale` on `core` | only via `voltdm_reset` (voltage.c:123-139), whose only users are SmartReflex paths; `CONFIG_POWER_AVS_OMAP` is not set [REPO kernel/configs/steelhead_defconfig:331] | not reached |
| VC AUTO_CTRL (patch 0027's ON 1.2 V, RET/OFF) | `OMAP4_VDD_DEFAULT_VAL` keeps all three `VDD_*_I2C_DISABLE` bits (vc.c:36-49). The only writer of the RET value, `omap4_vc_set_pmic_signaling()` (vc.c:305-323), is called only from `pmic-cpcap.c` (GitHub code search in torvalds/linux, 2026-10-11) | no command is sent; the 1.2 V is never applied [agrees with 0055's header] |
| patch 0014 phase A, 0015 bridge, 0017 | VC bypass or VP force-update on the **mpu** channel, slave **0x60** (TPS62361) | not VCORE1 |
| patch 0014 phase B | TWL6030 0x48 regs 0xB3/0xB4 (SYSEN) and 0x5E/0x64 (VCORE3/VMEM GRP) | not VCORE1's voltage |
| patches 0023/0030 | read 0xE0 (SMPS_OFFSET) | read-only |
| twl6030-regulator | `VDD1-3` use `twl6030coresmps_ops`, whose set/get return `-ENODEV` ([twl6030-regulator.c:242-251, 587-589](https://raw.githubusercontent.com/torvalds/linux/v6.18/drivers/regulator/twl6030-regulator.c)); `twl6030.dtsi` has no vdd1-3 nodes | nothing registered |
| TWL6030 SLEEP state (VCORE1 → its sleep setting) | would need PREQ1 to drop, which needs CORE RET/OFF. CORE is held ON (patch 0055, DTS patch 0057) | not reached today; **re-check** when CORE RET is enabled |

### 4. Where VCORE1 sits on the control interface

- **Slave 0x48 (TWL6030 ID0, "POWER")**, never 0x12. The SR interface is the PRM VC's
  own bus and is not visible on `/dev/i2c-*` [docs/2026-06-25-cpufreq-vdd-mpu-findings.md:44:
  0x60 "Read failed" on every normal bus]. Mainline maps ID0 with base 0x0000
  ([twl-core.c:100-106, 358](https://raw.githubusercontent.com/torvalds/linux/v6.18/drivers/mfd/twl-core.c)).
- **VCORE1 block = 0x52..0x57.** Primary evidence: stock `omap4460_twl6030_setup`
  (@0xc003eb00, consumed by `_twl_set_regs` @0xc0011aa4, which calls the write helper @0xc02ae980 with module 13, `(value, reg)` taken from bytes 1 and 0 of each 8-byte entry; 13 = `TWL6030_MODULE_ID0` in the 3.0 enum is UNVERIFIED, but patch 0014 read the sibling 0x5E on live stock at 0x48) writes
  **0x52 ← 0x01 "Pull VCORE1 down along with App processor's PREQ1"** (@0xc0651344) and
  **0x53 ← 0x01 "VCORE1OFF=OFF SLEEP=OFF ACT=AUTO"** (@0xc0651378), then 0x58/0x59 for
  VCORE2. The 4430 table (@0xc003eb28) adds 0x5E/0x5F for VCORE3. So the stride is 6:
  VCORE1 0x52, VCORE2 0x58, VCORE3 0x5E, VMEM 0x64 (patch 0014's 0x5E/0x64). The SR
  offsets match `base + 3 / base + 4`: VCORE1 0x55/0x56, VCORE2 0x5B/0x5C, VCORE3
  0x61/0x62 ([omap_twl.c:31-37](https://raw.githubusercontent.com/torvalds/linux/v6.18/arch/arm/mach-omap2/omap_twl.c)).
  The same SMPS layout appears in mainline's TWL6032 driver, where the voltage register
  is at `base + 4` (`VREG_VOLTAGE_SMPS 4`, twl6030-regulator.c:52; SMPS3 at relative
  0x34 = absolute 0x64).
- **0x55 vs 0x56.** 0x55 is the register the x-loader, U-Boot and the OMAP VP / VC
  bypass write to set the voltage (`volt_reg`). 0x56 is the VC command register
  (`cmd_reg`). The TRM names (UNVERIFIED: commonly FORCE = +3, VOLTAGE = +4) and the
  exact precedence rule are not public: mainline says "the specification is not
  public" (twl6030-regulator.c:586), and no TRM was found. The probe therefore reads
  both. It decodes 0x55 when its vsel is non-zero, and 0x56 otherwise.
- **`-f` is required.** `i2cdev_check()` returns `-EBUSY` for an address whose client
  has a bound driver, and `I2C_SLAVE` (without FORCE) refuses it
  ([i2c-dev.c:188-196, 409-415 @v6.18](https://raw.githubusercontent.com/torvalds/linux/v6.18/drivers/i2c/i2c-dev.c)).
  twl-core is bound to 0x48. `-f` only skips that check. The transfer is one
  adapter-locked SMBus byte read, so it does not interleave with the driver's traffic.
- **Bus.** The `twl6030` client's adapter, found by name under
  `/sys/bus/i2c/devices/*-0048`. The TMP101 is also 0x48, on I2C2 [REPO
  kernel/patches/0003…:608-628]. `i2c-tools` is in the image [REPO
  pmos/device-google-steelhead/APKBUILD:75].

The read-only command:

```sh
bus=$(for c in /sys/bus/i2c/devices/*-0048; do [ "$(cat $c/name)" = twl6030 ] && basename $c; done | cut -d- -f1)
for r in 0xe0 0x52 0x53 0x54 0x55 0x56; do printf '%s=%s ' $r "$(i2cget -y -f $bus 0x48 $r b)"; done; echo
```

Conversion (SMPS_OFFSET 0xE0 bit 3 set; for vsel 0x01..0x39, low 6 bits):
**µV = 709 000 + (vsel − 1) × 12 660**. With bit 3 clear the base is 607 700. 0x3A is
1 350 000 µV (mainline's only mapped discrete code); 0 means not set. Expected:
`0xe0=0x7f … 0x55=0x23` → 1 139 440 µV, PASS on the gate. If 0x55 reads `0x28`
(1 202 740 µV), something sent patch 0027's VC ON value and §3 is wrong somewhere. Any
other value is a finding.

### 5. Probe change

`scripts/diag/nexusq-gpu-probe.sh` gets `--pmic` (opt-in, root, i2c-tools). It does the
reads above, decodes the value with `vsel_uv()`, and reports `vdd_core_pmic` as PASS
(≥ 1 127 000 µV), WARN (below 1 127 000 µV, or not decodable) or SKIP. Checks done on
2026-10-11: `shellcheck` 0.11.0 is clean. `vsel_uv` was run on the host under `bash
--posix` (busybox ash was not available): 0x23/0x7f → 1 139 440, 0x21 → 1 114 120,
0x28 → 1 202 740, 0x3a → 1 350 000, 0x3b → empty (not decodable), 0x23 with
offset 0x00 → 1 038 140. The last one is the WARN branch, seen on the host only.

### Corrections this needs (applied in place, 2026-10-11)

- **This note, §4:** the expectation now names the x-loader instead of U-Boot (U-Boot
  skips `scale_vcores`), and the register, `-f` and the bus are filled in.
- **Groundwork TL;DR 5, Phase 0 step 3, §8 q1, §9 step 3 and risk P8:** "TRM-confirmed
  register" is replaced by the derived read (`--pmic`). The expected value is 1.139 V,
  and P8's likelihood is lowered to L.
- **`mainline-6.18.md` VDD_CORE row and open question 3:** the rail is expected at
  1.139 V from the x-loader, not at the 1.2 V VC ON value. That value is never sent.
- **`re/stock-sysconfig.md` line 81 note and rows #10/#30:** the SMPS→rail
  disagreement is resolved in favour of VCORE1 = VDD_CORE (below). The expected value
  is filled in.
- **`reverse-engineering.md` §11 licence row and rows 10/30:** the bootloader images
  are U-Boot (GPL-2.0+) code; see the row for the PPA caveat.
- **`drafts/measurement-protocol.md` row 7 and §9:** the register question is closed.
- **`docs/2026-06-25-cpufreq-vdd-mpu-findings.md`:** the claim "at boot the TWL6030
  VCORE1 SMPS feeds VDD_MPU … VCORE1 is what feeds VDD_MPU (~1025 mV)" is contradicted.
  The evidence is four independent sources:
  - stock `omap446x_core_pmic` uses VCORE1 for CORE [docs/2026-07-02 §1];
  - stock's 4460 TWL setup only puts VCORE1 in the APE PREQ1 group. "Pull VCORE1
    down along with App processor's PREQ1" is sleep grouping, not a rail hand-over.
    This string is the likely origin of the "retask" reading (UNVERIFIED that it was
    the source);
  - the x-loader sets VCORE1 to the CORE OPP100 voltage and the TPS62361 to the MPU
    OPP100 voltage;
  - upstream U-Boot says "4460 : supplies vdd_core".

  The note gets a dated correction marker, and its text is left as written. **Not
  editable under this task's rules:** the same claim sits in patch 0014's header and
  comments ("VDD_MPU is still physically driven by the TWL6030 VCORE1 SMPS") and in
  `kernel/dts/omap4-steelhead.dts:515` ("The TPS is dormant (VCORE1 drives
  VDD_MPU)"). They need the same correction by whoever next touches those files.
  Consequence (UNVERIFIED, inference): on mainline, VDD_MPU sits at the x-loader's
  1210 mV TPS SET1 until patch 0014 commands 1025 mV, and the hand-over is a
  downward step, not a no-step transition. That is harmless at 350 MHz.

### 6. Live read (2026-10-11, Prague unit): the control interface does not show the setpoint

Run on `steelhead` (Prague unit, 6.18.48-r20, `hostname` checked first). The twl6030
client is `0-0048`; the TMP101 is `1-0048`. Every read is a single
`timeout 5 nice -n 19 i2cget -y -f 0 0x48 <reg> b`. The PM receiver blocks
0x40..0x69 and 0xE0..0xE3 were read; nothing was written.

| Block (base) | +0 GRP | +1 TRANS | +2 STATE | +3 | +4 | +5 |
|---|---|---|---|---|---|---|
| 0x40 (V1V29, UNVERIFIED name) | 0x07 | 0x05 | 0x55 | 0x00 | **0x2b** | 0x00 |
| 0x46 V1V8 | 0x07 | 0x05 | 0x55 | 0x00 | **0x3c** = 1.8 V | 0x00 |
| 0x4C V2V1 | 0x07 | 0x05 | 0x55 | 0x00 | **0x3e** = 2.1 V | 0x00 |
| 0x52 **VCORE1** (VDD_CORE) | 0x07 | 0x05 | 0x55 | **0x00** | **0x00** | 0x06 |
| 0x58 VCORE2 (VDD_IVA) | 0x07 | 0x05 | 0x55 | 0x00 | 0x00 | 0x06 |
| 0x5E VCORE3 (unused on 4460) | 0x06 | 0x05 | 0x00 | 0x00 | 0x00 | 0x06 |
| 0x64 VMEM | 0x06 | 0x05 | 0x00 | 0x00 | 0x2b | 0x00 |

`0xE0` (SMPS_OFFSET) = 0x7f, `0xE1..0xE3` = 0x00.

What this shows:
- **The block layout is confirmed.** The fixed SMPSs sit where mainline puts them:
  V1V8 at PM_RECEIVER + 0x16 = 0x46 and V2V1 at + 0x1c = 0x4C
  ([twl6030-regulator.c:610-611](https://raw.githubusercontent.com/torvalds/linux/v6.18/drivers/regulator/twl6030-regulator.c);
  PM_RECEIVER base 0x30 on slave index 0, [twl-core.c:104, 350](https://raw.githubusercontent.com/torvalds/linux/v6.18/drivers/mfd/twl-core.c)).
  Their `+4` register (`VREG_VOLTAGE_SMPS`, twl6030-regulator.c:52) holds their real
  setpoint: 0x3c and 0x3e are the 1.8 V and 2.1 V codes of the SMPS map
  (`twl6030smps_list_voltage` codes 60 and 62, twl6030-regulator.c:333-341). So `+4` read over 0x48 does return a
  live voltage code for an SMPS that is programmed through this interface.
- **VCORE1 is on.** STATE 0x55: bits 3:2 (APP state) = 01 = ON
  (`TWL6030_CFG_STATE_APP`, twl6030-regulator.c:63-70). VCORE3, which the 4460 does
  not use, reads STATE 0x00, so the decode tells on from off. The SoC is also running.
- **VCORE1's `+3` (0x55) and `+4` (0x56) are both 0x00, and so are VCORE2's 0x5B/0x5C.**
  The x-loader wrote 0x23 to VCORE1 and 0x21 to VCORE2 over the SmartReflex interface
  (§1). Neither value appears here, and nothing in Linux writes these registers (§3).
  A vsel of 0 is 0 V in every TWL6030 SMPS map (`twl6030_vsel_to_uv` returns 0 for it,
  omap_twl.c:70-71; code 0 is 0 V in `twl6030smps_list_voltage`, twl6030-regulator.c:323-325), which a live rail cannot have. So **0 here means "not programmed
  through the control interface", not a voltage.** The setpoint the SR interface
  (slave 0x12) wrote lives somewhere the control interface does not expose, or the
  two interfaces address different registers at the same offsets. Which of the two
  is true needs the TWL6030 TRM (not public). UNVERIFIED either way; the practical
  result is the same.
- The x-loader's write is not proven to have succeeded either. If it failed, VCORE1
  runs at its OTP boot default, which is not readable from anywhere (UNVERIFIED).
- **TRANS 0x05 and GRP 0x07** are the values nobody wrote. Stock wrote 0x52 ← 0x01 and
  0x53 ← 0x01 ("VCORE1OFF=OFF SLEEP=OFF ACT=AUTO") at boot; mainline does neither. That
  is a stock-parity difference for the CORE RET/OFF work, not for the GPU gate.

**Other read-only paths, checked:**
- **OMAP VC.** `PRM_VC_VAL_BYPASS` has SLAVEADDR, REGADDR, DATA and VALID, with no read
  or direction bit; mainline only ever writes it and polls VALID
  ([vc.c:190-235 @v6.18](https://raw.githubusercontent.com/torvalds/linux/v6.18/arch/arm/mach-omap2/vc.c)).
  The SR I2C is write-only from the SoC side. Reading the register back would show only
  the last command sent (on our kernel, an MPU command to 0x60), not VCORE1. Using the VC
  needs a PRM **write**, so it is not a read path.
- **PRM VP_CORE.** Not driven on mainline (§4 method 1). `devmem` is not in today's
  image (neither as a command nor as a busybox applet), so it was not read.
- **TWL6030 GPADC.** The internal channels are battery, backup battery, charger input,
  VBUS, VBUS current, die temperature and USB ID
  ([twl6030-gpadc.c:150-235](https://raw.githubusercontent.com/torvalds/linux/v6.18/drivers/iio/adc/twl6030-gpadc.c)).
  None is VCORE1. Channels 2, 3, 5 and 6 are external, and their wiring on steelhead is
  unknown. A conversion also starts with a GPADC control write, so it is not read-only.
- **Linux views.** No regulator, debugfs or sysfs file covers VCORE1 (§4; the
  `twl6030_gpadc` IIO device is the only TWL ADC view).

**Consequence for the gate.** VDD_CORE is not readable from Linux. The 307.2 MHz gate
needs one of:
1. **a multimeter on VCORE1's output** (§4 method 3), definitive and read-only; or
2. **a method that writes**, which Petr must approve first: re-sending the x-loader's
   own `bypass(0x12, 0x55, 0x23)` through `PRM_VC_VAL_BYPASS` makes the setpoint known
   by construction, but it is a PMIC write on a live rail.

Until then the SGX is limited to **153.6 MHz** (§4 gate).

The accuracy figure that was missing is in the public datasheet: total DC output
accuracy is −1.2 %/+2.4 % around a typical value that sits above nominal (1.1 V row:
min 1.101, typ 1.114, max 1.141 V) [TWL6030 datasheet SWCS045C, "Switched-mode
regulators", TDCOV]. If the setpoint is 0x23 (1.139 V), the minimum stays above
1.127 V. How the table's nominal column maps to a vsel code is UNVERIFIED.

### Not reproduced, or still open

- ~~**No live read.**~~ *(2026-10-11: done, §6. It did not confirm the expected 0x23;
  0x55/0x56 read 0x00.)* Every value in §1-§5 is derived from images and sources.
- That slave 0x48's 0x55 is the same register the SR interface (0x12) writes. The
  evidence is the shared block layout (stock 0x52/0x53/0x58/0x59/0x5E and patch
  0014's 0x5E/0x64 on 0x48, versus the SR 0x55/0x5B/0x61). If 0x55 reads 0 or junk,
  the answer is in 0x56 or the TRM, and the multimeter decides.
- The precedence between 0x55 and 0x56, and the meaning of bits 6-7 (the probe
  decodes bits 5:0 only).
- Load-line droop under GPU load. The DC accuracy is now known (§6). The multimeter
  reading is no longer a cross-check: it is the gate.
- Whether `SMPS_MULT=0x52`, bit 4 (meaning not in mainline, which defines only bits
  0, 1 and 6) applies a multiplier to any VCORE. If it did, the x-loader's own
  conversion would be wrong too. The x-loader ignores MULT.
- That the x-loader's bypass writes succeed. The failure text goes to the serial
  console, and no stock boot log is in `reverse-eng/`.
- The U-Boot check for other VCORE1 writers covers immediate operands only (§2).
- The licence of the x-loader's TI HS header and PPA blob ("PPA", "CertPK_"
  strings at the start of the image). Only the U-Boot-derived code was analysed.

### 7. Setpoint by construction (2026-10-11 15:45, Prague unit, approved by Petr)

With no read-only path, the x-loader's own write was re-sent once from Linux so that
VCORE1's setpoint is known by construction rather than assumed:

- **What was sent:** `PRM_VC_VAL_BYPASS` (0x4a307ba0) ← `0x00235512` (slave 0x12, reg
  0x55, vsel 0x23 = 1 139 440 µV), then the same word with VALID (bit 24), polled until
  VALID cleared. This is byte-for-byte what `do_scale_vcore` in the stock x-loader does
  on every boot (§1).
- **Guards:** `hostname` = `steelhead` checked first; the bypass register read before
  the write showed no transaction in flight (`0x00000500`, VALID clear; the last
  transaction was the TPS62361 init to slave 0x60); the staged word was read back
  before VALID was set; cpufreq policy0 was pinned to 700 MHz for the duration so no
  VP-driven MPU transition could run, then restored to 350-1200 MHz `conservative`.
- **Result:** VALID cleared after 2 polls; the register then read `0x00235512`.
  `PRM_IRQSTATUS_MPU` read `0x80004100` before and after, so no new VC error status was
  raised. The unit stayed `running`, 56.8 °C, dmesg quiet.
- **One failed attempt first (harmless):** `struct.pack_into()` on the `/dev/mem` mmap
  goes through `memcpy` and took an alignment fault (`Unhandled fault: alignment
  exception (0x811) at …eba1`, Bus error). Only a staging byte changed
  (`0x560` → `0x500`); VALID was never set, so nothing was sent. **PRM registers need
  single aligned 32-bit accesses:** use `memoryview(mmap).cast("I")`, never
  `struct.pack_into`/`unpack_from`.

**Gate verdict:** VDD_CORE = 1.139 V by construction on this boot (the VC accepted the
transaction; the TWL6030 ACK is implied by VALID clearing without an error status, not
observed directly). Every boot re-applies the same value through the x-loader, so
**307.2 MHz is allowed**. A multimeter reading stays a cross-check, not a gate. The
proper fix is in the build, not in a one-off: the kernel should send the stock CORE ON
voltage itself (patch 0027 sets the VC ON value but it is never transmitted), tracked
as a Phase 0 item.

---

## Addendum 2026-10-13: VDD_CORE against stock, before any GPU DVFS

Stock-parity audit (reverse-eng/vmlinux.bin) with read-only PRM reads on the
Prague unit (kernel r27). What it settles:

- **Routing matches stock:** VDD_CORE is TWL6030 VCORE1 on the SR-I2C (slave
  0x12, volt/cmd 0x55/0x56), `VC_SMPS_SA`=0x00601212, `RA_VOL`=0x00015b55,
  `RA_CMD`=0x00015c56; vsel → µV = 709000 + (vsel−1)·12660 (SMPS_OFFSET set);
  VP limits 830-1200 mV, vstep 1/4, scale method VP force-update — all as stock.
- **It cannot be read today.** `PRM_VP_CORE_VOLTAGE` (0x4a307b4c) reads vsel
  0x00 because the VP has never driven CORE (`VP_CORE_CONFIG`=0x8, VP off);
  the rail sits at whatever the x-loader set (vsel 0x23 = 1 139 440 µV by
  construction, not observed). The TWL6030 control-bus pair 0x55/0x56 does not
  show the SR-written setpoint. A real number needs a multimeter on VCORE1, or a
  stock RAM boot reading `/sys/kernel/debug/voltage/vdd_core/curr_*`.
- **Three gaps before a VDD_CORE regulator is safe:**
  1. Mainline's 4460 CORE table is 1025/1200/1250 mV; stock's is
     **962/1127/1250 mV** (`omap446x_vdd_core_volt_data` @0xc0706920).
     `voltdm_scale()` rounds up to a table entry, so 1127 mV would become 1.2 V
     — the trap patch 0016 fixed for the MPU.
  2. Nothing sets a boot voltage for CORE; stock calls
     `omap2_set_init_voltage("core", "virt_l3_ck")` → VP force-update to 1127 mV.
     Doing the same would make `VP_CORE_VOLTAGE` a live readback.
  3. The VP ceiling VDDMAX 0x28 (1.2027 V) is below OPP-OV's 1.25 V (0x2c), in
     stock too; whether the limiter clamps a force-update is not established.
- Smaller mismatches: CORE slew 4000 vs stock 9000 (we ramp slower, benign);
  VC RET/OFF 837.5/0 mV vs stock 830/830 and TWL6030 0x52/0x53 not written —
  dormant until CORE retention is enabled.
- **Design, in order:** stock CORE table → kernel-side init voltage 1127 mV →
  VP ceiling (or prove it does not clamp) → a VDD_CORE regulator on the patch
  0015 pattern (min 1127 mV, max 1250 mV) → 384 MHz only inside the GPU's
  runtime PM, voltage up before the clock and down after it, never a static
  1.25 V → an OPP table 153.6/307.2/384 MHz with `dev_pm_opp_set_rate()` and a
  devfreq policy plus `devfreq_cooling`. 153.6 MHz cannot lower the voltage on
  mainline (L3 stays at 200 MHz, CORE ≥ 1127 mV): it saves dynamic power only.

**Implemented 2026-10-13 (kernel r28, patch 0076):** steps 1 and 2 above — the
stock CORE table and the boot-time CORE voltage. Trial boot on the Prague Q:
`steelhead: VDD_CORE set to 1127000 uV through the core VP (stock OPP100)`,
`VP_CORE_CONFIG` = 0x00162308 (INITVOLTAGE 0x23), `VP_CORE_VOLTAGE` = vsel
0x23 = 1 139 440 µV (r27: 0x00), `VC_VAL_CMD_VDD_CORE_L` ON = 0x23, no
TRANXDONE timeout. 1127 mV rounds up to the x-loader's own vsel, so the rail
itself did not move. Next: the VP ceiling, then the VDD_CORE regulator.

**Stock's VDD_CORE, measured 2026-10-14** (stock 3.0.8 RAM boot,
`fastboot boot output/stock-adb-boot.img`, idle, no GL client):
`/sys/kernel/debug/voltage/vdd_core`: `curr_nominal_volt` 1 127 000,
`curr_dyn_nominal_volt` 1 126 140, `curr_margin_volt` 13 000,
**`curr_calibrated_volt` = `curr_vp_volt` = 1 076 140 µV**; `sr_core` `autocomp=1`;
PRM `VP_CORE_VOLTAGE` 0x0001111E (vsel 0x1E), `VP_CORE_CONFIG` 0x00161E08,
`VC_VAL_CMD_VDD_CORE_L` 0x1E1E0B0B (ON/ONLP 0x1E, RET/OFF 0x0B = 830 mV).
(VDD_MPU at 1.2 GHz: nominal 1 380 000, calibrated 1 230 000.) So stock ran
CORE 63 mV *below* our open-loop 1 139 440 µV once SmartReflex class 1.5 had
calibrated it: we sit on the safe side, and the nominal table is the right
ceiling for an open-loop kernel. Whether stock's VP reaches 1.25 V under GPU
load was not measurable here (no `/system`, so no GL client in the RAM boot).
Kernel r29 (patch 0076, after the review) logs the VP readback:
`steelhead: VDD_CORE at vsel 0x23 = 1139440 uV through the core VP (stock
OPP100, 1127000 uV)`.

**VDD_CORE regulator and the VP ceiling, 2026-10-14 (kernel r30, patch 0077).**
Trial-booted and autopromoted on the Prague Q at 11:15. The regulator probes at
0.9 s (`steelhead: VDD_CORE VC-bridge regulator registered (VP reads 1139440
uV)`) and `/sys/class/regulator/*/` `vdd_core` reads 1 139 440 µV. The ceiling
test, at uptime 61 s through debugfs `steelhead_vdd_core/request_uV`:

| request | rc | `VP_CORE_VOLTAGE` | `VP_CORE_CONFIG` | `VC_VAL_CMD_VDD_CORE_L` |
|---|---|---|---|---|
| 1 250 000 µV | 0 | 0x0001112C, vsel **0x2c = 1 253 380 µV** | 0x00162C08 | 0x2C280C00 |
| 1 127 000 µV | 0 | 0x00011123, vsel 0x23 = 1 139 440 µV | 0x00162308 | 0x23280C00 |

`VLIMITTO` stayed 0x280B1E00 (VDDMAX 0x28, VDDMIN 0x0B). **VDDMAX does not
clamp a force-update:** the VP sent 0x2c, above its 0x28 limit, and TRANXDONE
arrived (rc 0, no timeout in the log). That is consistent with VLIMITTO bounding the
SmartReflex-driven (auto-compensation) updates only (not checked in the TRM),
which mainline does not run for CORE. 1.25 V for
OPP100-OV therefore needs no VP-limit change. The full diag after the boot was
clean apart from the known intermittent keypad clkctrl failure, which hit this
boot (`l4-wkup-clkctrl:0058:0: failed to enable`); capture
`nq-captures/20261014-111625/`.

**GPU DVFS, 2026-10-14 (kernel r31, patches 0078-0080; r32 after the review).**
Trial-booted and autopromoted on the Prague Q at 12:13. When the desktop loads
the SGX module: `pvrsrvkm 56000000.gpu: SGX DVFS: 3 OPPs 153600000..384000000
Hz, starts at 307200000 Hz, simple_ondemand, cooling device`; idle it parks at
153.6 MHz with VDD_CORE back at vsel 0x23. Under glmark2 at 384 MHz the VP read
vsel 0x2c = 1 253 380 µV, read together with the clock (rail, clock, rail in
one `cat`: 1253380 / 384000000 / 1253380). Benchmark: 81 at 307.2 MHz, 91 at
384 MHz and 91 with DVFS (`performance-2026-10-13.md`), die peak 89.4 °C.

Fleet-safety review of r31, fixed for r32:
- `omap_vp_forceupdate_scale()` logged a missing TRANXDONE and returned 0, so
  a lost SR-I2C transaction could leave the rail low while the OPP core raised
  the clock. It now returns -ETIMEDOUT (VDD_MPU too: cpufreq stays at the old
  OPP), and the VDD_CORE regulator fails with -EIO unless the VP reads back at
  least the voltage asked for.
- The debugfs `request_uV` knob wrote the VP behind the regulator core's back
  (a write of 1127 mV under a 384 MHz GPU would have stuck). Removed; `vp` is
  read-only.
- devfreq 6.18 sets `resume_freq` on every transition, the suspend one
  included, so every runtime resume started at 153.6 MHz and waited a 50 ms
  window to ramp. The glue now restores the OPP it ran at before suspend,
  clamped to the PM QoS limits (cooling device, sysfs min/max_freq).
