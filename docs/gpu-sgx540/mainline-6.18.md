# SGX540 groundwork 2/7: Mainline 6.18 (and up to v7.3-rc6): what it offers for the OMAP4460 SGX540

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

*Original working title: 02 — What mainline Linux 6.18 (and up to v7.3-rc6) offers for the OMAP4460 SGX540*

**Date:** 2026-10-11 · **Workstream:** mainline kernel state for PowerVR SGX540 on the Nexus Q (steelhead)
**Kernel inspected:** `linux-6.18.48` (the exact tarball our build uses, read out of the
`nexusq-workdir` docker volume `cache_distfiles/linux-6.18.48.tar.xz` and extracted read-only into the
scratchpad), plus mainline at the **v7.3-rc6** tag (`a90ee4305c4a`, tagged 2026-10-04) through the
GitHub mirror `torvalds/linux` (`gh api`). *(Corrected 2026-10-11: an earlier revision named `3857c2fe5449`
(2026-10-09) as "v7.3-rc6". That commit is master head, 337 commits after the rc6 tag. The file
comparisons were re-run at tag ref `v7.3-rc6`.)* git.kernel.org and lore.kernel.org refused automated fetches
(HTTP 403 and an Anubis bot wall), so the mainline history below comes from the GitHub mirror, which
carries the same commit IDs.
**Nothing was built, flashed or committed. No device was touched.** Runtime facts come from the
existing on-device captures in `nq-captures/` (newest one: `20261010-185940`, kernel `6.18.48-r20`).

Evidence tags used below: `[file:line]` = repo or 6.18.48 source line; `[commit]` = mainline (or
openpvrsgx) commit ID I opened; `[stock @addr]` = address in `reverse-eng/vmlinux.bin` (stock 3.0.8);
`[capture]` = on-device snapshot; **UNVERIFIED** = my inference, with the reasoning given.

---

## TL;DR

1. **Mainline 6.18 already describes the GPU fully in DT and probes its bus glue on our board.**
   `omap4.dtsi` has `sgx_module: target-module@56000000` (ti-sysc, `power-domains = <&prm_gfx>`,
   `fck` from `l3_gfx_clkctrl OMAP4_GPU_CLKCTRL`) and a child
   `gpu@0 { compatible = "ti,omap4430-gpu", "img,powervr-sgx540"; reg 32 MB; GIC_SPI 21 }`, with no
   `status = "disabled"`. Our steelhead DTS includes `omap4460.dtsi` and does not touch the node. The live
   capture shows `5600fe00.target-module` holding `fck` (prepared, gated, so runtime-suspended).
   **Nothing is missing on the bus, clock or power side.** What is missing is a *driver* for `gpu@0`.
2. **There is no SGX/Series5 GPU driver in mainline at 6.18 or at v7.3-rc6, and no sign of one coming.**
   `drivers/gpu/drm/imagination` covers Rogue (Series6+) only and
   `depends on (ARM64 || RISCV && 64BIT)`, so it cannot even be selected on ARMv7. Mesa's
   `src/imagination` is a Rogue Vulkan driver. The SGX DT binding exists (merged in **v6.9**, Andrew
   Davis/TI), but its cover letter says outright that there is "currently no mainline driver for these
   binding[s]". I found no 2025–2026 dri-devel or Mesa work on Series5 (see §7 for how far the search
   reached).
3. **The out-of-tree driver consumes exactly this mainline DT.** The openpvrsgx `pvr-drv.c` wrapper
   (branch `letux/pvrsrvkm-v3`, rebased onto **Linux 7.2** on 2026-08-16) matches
   `"ti,omap4430-gpu"` with `sgx_revision = 120`, `ocp_offset = 0xfe00` and `PVR_QUIRK_OMAP4`, and powers
   the module through `pm_runtime_get_sync()`. That pulls in ti-sysc → clkctrl → PRM GFX genpd. DDK
   branches (1.9.2188537, 1.14.3699939, 1.17.4948957-v3, generic) were also rebased to 7.2 in August 2026.
   The 2025-05 `letux/pvrsrvkm-1.17.4948957` branch that the June research note cited has not had its
   own head moved since 2025-05. openpvrsgx also keeps **per-kernel integration branches**, and one of
   them is **`pvrsrvkm-6.18-rc6`** (`d2f1e031d58a`, 2025-11-21, Makefile 6.18.0-rc6). It merges the
   OMAP glue and every DDK branch, and it has `pvr-drv.c` with `ti,omap4430-gpu`. That makes it the
   natural base for our 6.18.48, with no 7.x backport needed (§7.1, §7.4).
4. **Clock parity gap: on our 4460 the SGX would run at 266.67 MHz from the wrong DPLL.** `omap443x.dtsi`
   re-parents the SGX mux to `dpll_per_m7x2_ck` at 307.2 MHz. `omap4460.dtsi` has no such override, so the
   mux stays at whatever it holds at boot. On our unit that is `dpll_core_m7x2_ck` = 1600/6 = **266.67 MHz**
   [capture]. Whether that is the hardware reset value or something the bootloader set is UNVERIFIED. Stock steelhead
   explicitly calls `clk_set_parent(gpu_fck, dpll_per_m7x2_ck)` in `omap4_steelhead_display_init`
   [stock @0xc0075f08–0xc0075f40]. The stock 446x OPP table has GPU at **153.6 / 307.2 / 384 MHz**, all on
   `dpll_per_m7x2_ck`, at VDD_CORE 962 / 1127 / 1250 mV [stock @0xc0043e94–0xc0043ed8]. Mainline has no
   GPU OPPs and no VDD_CORE DVFS, so **307.2 MHz is the parity target**. 384 MHz would need core
   over-voltage that mainline does not do.
5. **omapdrm in 6.18 has everything an SGX userspace needs on the display side.** It has a render node
   (`DRIVER_RENDER`) and the `OMAP_BO_*` GEM uapi (SCANOUT, WC/UNCACHED, TILED_8/16/32). PRIME import and
   export work for non-contiguous shmem buffers through DMM/TILER, and implicit dma-resv fencing on
   scanout was fixed for exactly this use case. Those fixes came from Ivaylo Dimitrov in v5.17–v5.19, tested
   with the Droid 4 SGX540. Other pieces: 4 KMS planes (GFX + VID1–3) with zpos, alpha, premultiplied blend
   and NV12/YUYV/UYVY; rotation only for TILED buffers; DMM probes on our unit [capture].
   `DRM_OMAP_GEM_CPU_PREP/FINI` are now `drm_noop`, and old SGX userspace that relies on them must not
   depend on their semantics.
6. **6.18 → v7.3-rc6 changed nothing GPU-relevant in DT, clocks, ti-sysc or PRM.** `omap4.dtsi`,
   `omap443x.dtsi`, `omap4460.dtsi`, `clk-44xx.c` and `omap_drm.h` are byte-identical. There is API churn,
   though, that an out-of-tree module must straddle: `timer_container_of()` (6.16), the `kmalloc_obj()`
   family (v7.0) and `struct drm_atomic_state → drm_atomic_commit` (v7.2). **A 7.2-based openpvrsgx branch
   therefore needs a small backport layer to build against our 6.18 LTS.** The alternative is to start
   from the `pvrsrvkm-6.18-rc6` integration branch, which needs no such layer but does not have the 2026
   `1.17.4948957-v3` work.

---

## 1. Device tree: what 6.18 ships for the GPU

### 1.1 `omap4.dtsi` (inherited by `omap4460.dtsi` → our board)

`arch/arm/boot/dts/ti/omap/omap4.dtsi:484-509` (6.18.48):

```dts
sgx_module: target-module@56000000 {
	compatible = "ti,sysc-omap4", "ti,sysc";
	reg = <0x5600fe00 0x4>,
	      <0x5600fe10 0x4>;
	reg-names = "rev", "sysc";
	ti,sysc-midle = <SYSC_IDLE_FORCE>,
			<SYSC_IDLE_NO>,
			<SYSC_IDLE_SMART>,
			<SYSC_IDLE_SMART_WKUP>;
	ti,sysc-sidle = <SYSC_IDLE_FORCE>,
			<SYSC_IDLE_NO>,
			<SYSC_IDLE_SMART>,
			<SYSC_IDLE_SMART_WKUP>;
	power-domains = <&prm_gfx>;
	clocks = <&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 0>;
	clock-names = "fck";
	#address-cells = <1>;
	#size-cells = <1>;
	ranges = <0 0x56000000 0x2000000>;

	gpu@0 {
		compatible = "ti,omap4430-gpu", "img,powervr-sgx540";
		reg = <0x0 0x2000000>; /* 32MB */
		interrupts = <GIC_SPI 21 IRQ_TYPE_LEVEL_HIGH>;
	};
};
```

- **Status:** neither node has a `status` property, so both are **enabled** by default. (The node right
  before it, at line 481, is a different, disabled module.)
- **PRM instance:** `prm_gfx: prm@1200 { compatible = "ti,omap4-prm-inst", "ti,omap-prm-inst"; reg = <0x1200 0x100>; #power-domain-cells = <0>; }`
  `[omap4.dtsi:812-816]`.
- **Clock provider:** `l3_gfx_cm: l3_gfx_cm@1200` → `l3_gfx_clkctrl: clk@20` (`ti,clkctrl`, `#clock-cells = <2>`)
  `[omap44xx-clocks.dtsi:1395-1409]`. The binding constant is `OMAP4_GPU_CLKCTRL = OMAP4_CLKCTRL_INDEX(0x20)`
  `[include/dt-bindings/clock/omap4.h:81-82]`.
- **How the node got here (mainline history, all `[commit]` via the GitHub mirror):**
  - `d23a163ebe5a` (2017-10-10, Tony Lindgren): adds the interconnect target modules, including
    `@56000000`.
  - `1b95c5a48f5e` (2019-08-26, Tony Lindgren): "Drop legacy platform data for omap4 gpu", which moves the
    module to ti-sysc. The commit message records a manual test: forcing runtime PM on, then
    `rwmem 0x56000024` → `0x00010200  # SGX540 CORE_REVISION`. With the module idled, the same read
    gives "Bus error".
  - `3e5c3c41ae92` (2019-11-24): "Fix sgx sysconfig register for omap4" moves rev/sysc from
    `0x5601fc00/0x5601fc10` to the TRM-correct `0x5600fe00/0x5600fe10`: "Otherwise the sgx module may never
    idle".
  - `345ac6b17b18` (2021-03-10): adds `power-domains = <&prm_gfx>`.
  - `c137afbe6c4e` (2024-01-09, Andrew Davis): "ARM: dts: omap4: Add device tree entry for SGX GPU"
    replaces the comment "Closed source PowerVR driver, no child device binding or driver in mainline"
    with the `gpu@0` child. The first release containing it is **v6.9** (GitHub compare: not in v6.8, in
    v6.9).
  - Nothing has changed since. The file at v7.3-rc6 is byte-identical to 6.18.48.

### 1.2 SoC-variant overrides: 443x has one, 4460 does not

`arch/arm/boot/dts/ti/omap/omap443x.dtsi:77-86`:

```dts
/*
 * Use dpll_per for sgx at 307.2MHz like droid4 stock v3.0.8 Android kernel
 */
&sgx_module {
	assigned-clocks = <&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 24>,
			  <&dpll_per_m7x2_ck>;
	assigned-clock-rates = <0>, <307200000>;
	assigned-clock-parents = <&dpll_per_m7x2_ck>;
};
```

History: `19d3e9a0bdd5` (2020-03-10) first set it to 153.6 MHz "to avoid hangs" and for thermal reasons
on the Droid 4. `fab030ac9997` (2021-01-04, Carl Philipp Klemm) corrected it to 307.2 MHz: "The Android
vendor kernel uses 307.2MHz or a divider ratio of /5 while active, 153600000 or /10 is only used when the
sgx core is inactive."

`omap4460.dtsi` (6.18.48, read in full) contains **no** `&sgx_module` override and no GPU references at
all. It holds only the CPU OPPs, the bandgap, ABB and the L4 CFG range differences, then
`/include/ "omap446x-clocks.dtsi"`, which adds only `div_ts_ck`/`bandgap_ts_fclk`. On every 4460 board in
mainline, the SGX therefore runs from whatever the `CLKSEL_SGX_FCLK` mux (bit 24 of
`CM_GFX_GFX_CLKCTRL`) holds at boot. See §3 for what that is on our unit.

### 1.3 Our DTS (`kernel/patches/0003-ARM-dts-omap4-add-steelhead.patch`)

- `#include "omap4460.dtsi"` `[0003…patch:65]`.
- A grep over the whole patch series for `sgx`, `gpu@`, `target-module@56` finds **no match**. Steelhead
  neither disables nor overrides the GPU module. Display-related nodes it does touch: `&dss`
  (`vdda_video-supply = <&vcxio>`) `[0003…patch:899-903]`, `&hdmi` + TPD12S015A + micro-HDMI connector
  `[0003…patch:178-215, 904-920]`, and `dss_hdmi_pins` `[0003…patch:325-346]`.
- Conclusion: **a GPU enablement needs no DT change for the node to exist**. The only DT change worth making is
  the clock override described in §3.4.

### 1.4 What the running kernel shows (no device access; from the newest capture)

`nq-captures/20261010-185940/snapshot.txt` (uname `6.18.48-r20 #21-postmarketOS … Oct 3 2026`):

| Line | Fact |
|---|---|
| 465 | `dpll_core_x2_ck` 1 600 000 000 Hz |
| 467 | `dpll_core_m7x2_ck` 266 666 667 Hz, prepare 1 / enable 0 |
| 468 | `l3-gfx-clkctrl:0000:24` (the SGX mux) 266 666 667 Hz, consumer `of_clk_get_from_provider` |
| 470 | `l3-gfx-clkctrl:0000:0` (gate) 266 666 667 Hz, **enable 0, prepare 1, HW-enabled N**, consumer **`5600fe00.target-module fck`** |
| 324–325 | `dpll_per_ck` 768 MHz, `dpll_per_x2_ck` 1 536 MHz |
| 333 | `dpll_per_m7x2_ck` **307 200 000 Hz**, prepare 0 / enable 0 (programmed, unused) |
| 1821 | `PM: genpd: Disabling unused power domains` (so GFX is presumably OFF; UNVERIFIED, since the capture does not dump genpd state) |

What this establishes: ti-sysc probed the GPU target module (that is what makes it the `fck` consumer).
It then runtime-suspended the module, because nothing is bound to the `gpu@0` child. **UNVERIFIED** detail:
the ti-sysc `of_platform_populate()` `[ti-sysc.c:3239]` should have created a platform device for `gpu@0`
(name most likely `56000000.gpu`) that sits unbound. The capture does not list `/sys/bus/platform/devices`,
so this needs confirming on the device.

---

## 2. DT binding `Documentation/devicetree/bindings/gpu/img,powervr-sgx.yaml`

- **Merged:** `796da8ca7e05` "dt-bindings: gpu: Add PowerVR Series5 SGX GPUs". Author **Andrew Davis
  (TI)**, authored 2024-01-09 and committed by Tony Lindgren 2024-01-26 (Message-ID
  `20240109171950.31010-3-afd@ti.com`). Reviewed by Javier Martinez Canillas and Krzysztof Kozlowski.
  The first release containing it is **v6.9**. It was patch 2/11 of the series "Device tree support
  for Imagination Series5 GPU" (cover letter 2024-01-09, base next-20240109). The series covered the
  binding, plus DT nodes for omap3/4/5, AM33xx, AM437x, DRA7xx, AM654, sun6i and jz4780, plus the
  `img,powervr` → `img,powervr-rogue` rename.
- **Cover letter quote:** "there is currently no mainline driver for these binding"; it points to the
  out-of-tree openpvrsgx project.
- **Content in 6.18.48** (the full file was read):
  - compatible pairs. SGX530: `ti,omap3430-gpu` (Rev 121), `ti,omap3630-gpu` (Rev 125). **SGX540:
    `ingenic,jz4780-gpu` (Rev 130), `ti,omap4430-gpu` (Rev 120)**. SGX544: `allwinner,sun6i-a31-gpu`
    (MP2 Rev 115), `ti,omap4470-gpu` (MP1 Rev 112), `ti,omap5432-gpu` (MP2 Rev 105), `ti,am5728-gpu`
    (MP2 Rev 116), `ti,am6548-gpu` (MP1 Rev 117).
  - **required:** `compatible`, `reg`, `interrupts`.
  - `power-domains` is required for `ti,am6548-gpu` and **forbidden (`false`) for every other compatible,
    including `ti,omap4430-gpu`**.
  - `clocks`/`clock-names` (`core`, `mem`, `sys`) are required for sun6i and jz4780 and **forbidden for
    everything else, including OMAP4**.
  - **Consequence for us:** on OMAP4 the clock and power domain belong **only on the parent ti-sysc
    target-module**, never on `gpu@0`. A steelhead override that adds `clocks =` to `gpu@0` would fail
    `dtbs_check`. Clock tuning has to go on `&sgx_module`, the way 443x does it.
- **Maintainers:** 6.18.48 lists Frank Binns. At v7.3-rc6 that changed to Alessio Belle and Luigi
  Santivetti `[diff 6.18.48 vs v7.3-rc6]`, via `8fca3d8dbebf` (2026-06-26) and `2f6f6b525f52`
  (2026-06-29, Matt Coster). MAINTAINERS puts the file under "IMGTEC POWERVR DRM DRIVER" (Supported,
  tree `gitlab.freedesktop.org/drm/misc/kernel.git`) `[MAINTAINERS:12201-12211]`.
- **The 4460 is an omap4430-gpu (rev 120):**
  - The stock steelhead `/system` ships `vendor/lib/egl/libGLESv2_POWERVR_SGX540_120.so`,
    `libEGL_POWERVR_SGX540_120.so` and `libGLESv1_CM_POWERVR_SGX540_120.so` (`debugfs -R "ls -l /vendor/lib/egl"`
    on `factory/tungsten-ian67k/system.raw.img`).
  - The stock kernel prints `SGX revision = %u.%u.%u` `[stock string @0xc068a258, loaded in SysFinalise @0xc028fb2c via its literal-pool word @0xc028fc28]`.
  - Tony's 2019 read of `0x56000024` returned `0x00010200` = core revision **1.2.0** = "120".
  - `ti,omap4430-gpu` is therefore the right compatible for our SoC. `omap4470` is a different GPU
    (SGX544).

---

## 3. Clocks: the SGX functional clock on 4460

### 3.1 Mainline clock data

- `drivers/clk/ti/clk-44xx.c:327-341`:
  ```c
  static const char * const omap4_sgx_clk_mux_parents[] __initconst = {
  	"dpll_core_m7x2_ck",
  	"dpll_per_m7x2_ck",
  	NULL,
  };
  static const struct omap_clkctrl_bit_data omap4_gpu_bit_data[] __initconst = {
  	{ 24, TI_CLK_MUX, omap4_sgx_clk_mux_parents, NULL },
  	{ 0 },
  };
  static const struct omap_clkctrl_reg_data omap4_l3_gfx_clkctrl_regs[] __initconst = {
  	{ OMAP4_GPU_CLKCTRL, omap4_gpu_bit_data, CLKF_SW_SUP, "l3-gfx-clkctrl:0000:24" },
  	{ 0 },
  };
  ```
  The provider sits at `0x4a009220` `[clk-44xx.c:703]`, with legacy alias
  `DT_CLK(NULL, "sgx_clk_mux", "l3-gfx-clkctrl:0000:24")` `[clk-44xx.c:763]`. **The module gate's parent
  is the mux** (`CLKSEL_SGX_FCLK`, bit 24). Index 0 = core M7, index 1 = per M7. The gate is SW-supervised
  (`CLKF_SW_SUP`, i.e. MODULEMODE written by software).
- `dpll_core_m7x2_ck`: `ti,divider-clock` off `dpll_core_x2_ck`, reg `0x0144`, `ti,max-div = <31>`,
  `ti,index-starts-at-one`, autoidle bit 8 inverted `[omap44xx-clocks.dtsi:367-377]`.
- `dpll_per_m7x2_ck`: same divider type off `dpll_per_x2_ck`, reg `0x0164` `[omap44xx-clocks.dtsi:734-744]`.
- Arithmetic from the live rates [capture]:
  - core_x2 = 1600 MHz; M7 = 6 → **266.67 MHz** (current SGX source).
  - per_x2 = 1536 MHz:
    - M7 = 5 → **307.2 MHz** (what the M7 output is programmed to now)
    - M7 = 4 → 384 MHz
    - M7 = 10 → 153.6 MHz

### 3.2 Power and clock domains (legacy mach-omap2 data, still used by clkctrl/PRM glue)

- `gfx_44xx_pwrdm`: `.name = "gfx_pwrdm"`, `.voltdm = "core"`, `prcm_offs = OMAP4430_PRM_GFX_INST`,
  `.pwrsts = PWRSTS_OFF_ON`, one memory bank (`gfx_mem` OFF in retention, ON when on),
  `PWRDM_HAS_LOWPOWERSTATECHANGE` `[arch/arm/mach-omap2/powerdomains44xx_data.c:56-71]`. **No retention
  state:** GFX is either fully on or off.
- `l3_gfx_44xx_clkdm`: pwrdm `gfx_pwrdm`, CM2 GFX instance, `CLKDM_CAN_HWSUP_SWSUP`, wake/sleep deps on
  `ivahd_clkdm`, `l3_1_clkdm`, `l3_emif_clkdm` `[clockdomains44xx_data.c:97-102, 184-194]`.
- **Genpd (what actually switches it):** `drivers/pmdomain/ti/omap_prm.c` (`CONFIG_OMAP2PLUS_PRM`, default
  y on ARCH_OMAP2PLUS) `[omap_prm.c:196-199]`:
  `{ .name = "gfx", .base = 0x4a307200, .pwrstctrl = 0x0, .pwrstst = 0x4, .dmap = &omap_prm_onoff_noauto }`
  with `usable_modes = ON_ACTIVE | OFF, statechange = 1` `[omap_prm.c:125-128]`. **There is no `rstctrl`
  for OMAP4 GFX** (contrast: the AM33xx/AM43xx gfx entries at `[omap_prm.c:433-436, 461-464]` have
  `rstctrl` + `clkdm_name = "gfx_l3"`). The OMAP4 SGX has no PRM reset line to drive. Reset/idle go
  through the OCP SYSCONFIG at `0xfe10`.
- `pdata-quirks.c:494-496` attaches `ti_sysc_pdata` to `ti,sysc` and `ti_prm_pdata` to
  `ti,omap-prm-inst`. The OMAP4 PRM node lists `ti,omap-prm-inst` as its second compatible, so it
  matches. The openpvrsgx branch `letux/omap-sysc-prm-gfx` carries an old Tero Kristo commit
  `ca220f520c26` (2019) that adds per-SoC `ti,omap4-prm-inst` auxdata "for reset support". For OMAP4 that
  is **redundant with mainline**: the generic compatible already matches, and GFX has no reset to
  support. **UNVERIFIED** (reasoning only, not tested): the commit is not needed for OMAP4.

### 3.3 Stock ground truth (steelhead 3.0.8, `reverse-eng/vmlinux.bin`)

- **Board init re-parents the SGX clock.** `omap4_steelhead_display_init` @`0xc0075ef8` disassembles to:
  - `clk_get(NULL, "dpll_per_m7x2_ck")` (literal @`0xc0654328`)
  - `clk_get(NULL, "gpu_fck")`
  - `clk_set_parent(gpu_fck, dpll_per_m7x2_ck)` @`0xc0075f40`, with error string
    "failed to set gpu_fck to dpll_per_m7x2_ck" @`0xc065a444`
  - then `omap_vram_set_sdram_vram(0x1000000, 0)`, i.e. a **16 MiB VRAM carve-out** for omapfb, and the
    HDMI mux/GPIO setup.

  This is steelhead-specific code, not generic OMAP4 code: stock steelhead deliberately runs the SGX
  from DPLL_PER.
- **Stock GPU OPP tables** (6-word records `{hwmod, voltdm, clk, rate, uV, default_avail}`):
  - Table at `0xc0043c9c`: `gpu/core/dpll_per_m7x2_ck`: **153.6 MHz @ 962 000 µV** (avail 1),
    **307.2 MHz @ 1 127 000 µV** (avail 1).
  - Table at `0xc0043e94…0xc0043ed8`: the same two, plus **384 MHz @ 1 250 000 µV** (avail 1).
  - That second table also carries `iva` 430 MHz and 500 MHz @ 1.375 V (avail 0), which exist only on
    446x. **Verified by symbol:** kallsyms does name both tables. `omap443x_opp_def_list` is @`0xc0043bc4`,
    so the first table is 443x, and `omap446x_opp_def_list` is @`0xc0043d5c`, so the second is 446x
    (`reverse-eng/tools/kallsyms.txt`). *(Corrected 2026-10-11: an earlier revision said the symbol was
    missing from kallsyms.)*
  - So **on the Q, stock ran the SGX at up to 384 MHz with VDD_CORE raised to 1.25 V** (core OPP-OV),
    with DVFS through `RequestSGXFreq` @`0xc0290c28`, `SysDvfsInitialize` @`0xc0290f80` and
    `omap_device_scale` @`0xc006f60c`.
- Stock DDK: kernel string `CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978`
  @`0xc0680738`, and the `/system` GLES2 blob reports `OpenGL ES 2.0 build 1.8@785978`. The stock
  services KM is built in (e.g. `PVRSRVDriverProbe` @`0xc0276114`), together with **OMAPLFB** (display
  class, `OMAPLFB_Init` @`0xc0025af0`), **dsscomp** and the **TILER/ION** allocator (`omap_tiler_alloc`
  @`0xc02719f4`). Those are the Android-era equivalents of what mainline does with omapdrm
  GEM/PRIME/DMM (§6).
- Correction to the June note: the SGX **microkernel is not a separate `sgx540_*.fw` file** in this DDK
  generation. The stock `libsrv_init.so`/`pvrsrvinit` contain `SetupuKernel`, `LoaduKernelPrograms`,
  "SGX ukernel" etc. (strings of the files extracted with `debugfs dump`). Userspace (`pvrsrvinit`)
  uploads the microkernel programs through the services bridge. **Inference** from the strings, not
  from disassembly. Another workstream should confirm it.

### 3.4 Gap analysis and what a steelhead DT override should do

| Item | Mainline 6.18 on our Q | Stock steelhead | Gap |
|---|---|---|---|
| SGX mux parent | `dpll_core_m7x2_ck` (reset default, nobody re-parents on 4460) | `dpll_per_m7x2_ck` (board init) | **parity bug-to-be**: no consumer yet, but the first GPU driver would run off CORE M7 |
| SGX rate | 266.67 MHz | 153.6 / 307.2 / 384 MHz DVFS | not a stock OPP |
| VDD_CORE | VC ON value 1.2 V (our patch 0027, stock `omap446x_core_pmic` parity), no core DVFS in mainline | 0.962 / 1.127 / 1.25 V by OPP | **384 MHz is not safely available**. 307.2 MHz needs ≥ 1.127 V by the stock table, which 1.2 V covers; that assumes the rail really sits at the VC ON value at runtime (**UNVERIFIED**: the capture has no VCORE1 readback). *(Corrected 2026-10-11: the VC ON value is never sent, because AUTO_CTRL keeps I2C_DISABLE. The rail is expected at the x-loader's vsel 0x23 = 1.139 V, still ≥ 1.127 V; not yet read live [pm Addendum "Live VDD_CORE without a device"].)* |
| GPU DVFS | none (no `operating-points` on the GPU, `CONFIG_PM_DEVFREQ` off `[steelhead_defconfig:4208]`) | `sgxfreq` governors | optional later; the openpvrsgx build has `CONFIG_OMAP_SGX_FREQ` hooks (`sgxfreq_*.o`), marked "not in Kconfig… API … missing/changed" in its Makefile |

The proposal (do not apply now; this is the input for the plan) mirrors `omap443x.dtsi` in the steelhead
DTS:

```dts
/* Stock steelhead: omap4_steelhead_display_init() re-parents gpu_fck to
 * dpll_per_m7x2_ck; 307.2 MHz is the stock OPP100 GPU rate (VDD_CORE 1.127 V). */
&sgx_module {
	assigned-clocks = <&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 24>,
			  <&dpll_per_m7x2_ck>;
	assigned-clock-rates = <0>, <307200000>;
	assigned-clock-parents = <&dpll_per_m7x2_ck>;
};
```

Side note: `dpll_core_m7x2_ck` has no other consumer in the capture's tree. Once re-parented, the CORE M7
output can autoidle. **UNVERIFIED** (the M7 HSDIVIDER autoidle behaviour has not been checked against the
TRM).

---

## 4. ti-sysc and the GPU interconnect target module

- **Quirk table entries for "gpu"** `[drivers/bus/ti-sysc.c]`:
  - L1534: `SYSC_QUIRK("gpu", 0x50000000, 0x14, -ENODEV, -ENODEV, 0x00010201, 0xffffffff, 0)` (OMAP3430,
    no sysconfig).
  - L1535-1536: `SYSC_QUIRK("gpu", 0x50000000, 0xfe00, 0xfe10, -ENODEV, 0x40000000, 0xffffffff, SYSC_MODULE_QUIRK_SGX)`
    (OMAP36xx at `0x50000000` only). The quirk `sysc_module_enable_quirk_sgx()` writes
    `OCP_DEBUG_CONFIG (0xff08) = BIT(31) THALIA_INT_BYPASS` `[L1948-1955, L2050-2051]`.
  - L1609: `SYSC_QUIRK("gpu", 0, 0x1fc00, 0x1fc10, -ENODEV, 0, 0, 0)` and L1610:
    `SYSC_QUIRK("gpu", 0, 0xfe00, 0xfe10, -ENODEV, 0x40000000, 0xffffffff, 0)`. These are **name-only
    entries**, and they sit inside the `#ifdef DEBUG` block of `sysc_revision_quirks[]` (ti-sysc.c
    L1585–1660). **They are not compiled into our kernel at all**, so on our build the module gets no "gpu"
    name whatever its REVISION reads. The L1610 pattern could only matter in a DEBUG build, and only if
    REVISION reads `0x40000000` (**UNVERIFIED** on our unit). The match logic itself is
    `sysc_init_revision_quirks()` (L1696–1723): a non-zero `base` must equal `module_pa`. **No functional quirk applies to OMAP4**: the THALIA bypass is OMAP36xx-only by base
    address.
  - `DIS_SGX` SoC feature flags exist only for OMAP3/AM35 variants without SGX `[L41, L2937-2945, L3052]`.
    OMAP4460 is not flagged, so the module is never disabled by the SoC-feature check.
- **Register layout:** `ti,sysc-omap4` → SIDLEMODE and MIDLEMODE fields, with modes force / no / smart /
  smart-wkup allowed for both `[omap4.dtsi:489-496]`. No `ti,sysc-mask`, so no SOFTRESET is described;
  ti-sysc will not soft-reset the SGX on init. **UNVERIFIED** whether stock relied on an OCP soft reset.
  The DDK resets the core itself through `EUR_CR_SOFT_RESET`.
- **Child clocks:** ti-sysc aliases the module `fck` onto children with
  `sysc_child_add_named_clock()` `[ti-sysc.c:2326-2351]`, so a GPU driver can `clk_get(dev, "fck")` to
  read or change the rate. Our patch `0025-bus-ti-sysc-child-named-clock-clkdev-add.patch` switches this
  to `clkdev_add()` to beat the 24-char `MAX_DEV_ID`. **UNVERIFIED but likely irrelevant for the GPU:**
  the child here has a `reg`, so its name is short (`56000000.gpu`, 12 chars).
- **Probe/PM chain a GPU driver would trigger:** driver `pm_runtime_get_sync(&gpu_pdev->dev)` → parent
  ti-sysc runtime resume → genpd `gfx` ON (PRM `PM_GFX_PWRSTCTRL`) → clkctrl MODULEMODE enable through
  `fck` → SYSCONFIG idle modes programmed. That is the path the openpvrsgx `pvr-drv.c` takes (§7.3). The
  capture already shows this parent device bound and holding `fck`.
- **First safe, read-only probe for later** (not run now; needs root and the Q). The procedure is the one
  Tony Lindgren used in `1b95c5a48f5e`:
  1. `echo on > /sys/bus/platform/devices/5600fe00.target-module/power/control`
  2. read `0x56000024` with `busybox devmem`; expect `0x00010200`
  3. read `0x5600fe00` (OCP REVISION). This is informational only: the L1610 name entry is DEBUG-only and
     not in our build.
  4. `echo auto > …/power/control`

  Reading while the module is idle bus-errors, so the order matters. Wrap the steps in `timeout`, per
  project rules.

---

## 5. Kernel-side GPU drivers: mainline and around it

### 5.1 `drivers/gpu/drm/imagination` (mainline "powervr")

- `Kconfig` at 6.18.48 and at v7.3-rc6 (identical):
  `tristate "Imagination Technologies PowerVR (Series 6 and later) & IMG Graphics"`,
  **`depends on (ARM64 || RISCV && 64BIT)`**, `depends on PM`, selects `DRM_GEM_SHMEM_HELPER`,
  `DRM_SCHED`, `DRM_GPUVM`, `FW_LOADER` `[drivers/gpu/drm/imagination/Kconfig:4-15]`.
- OF match `[pvr_drv.c:1490-1510]`: `thead,th1520-gpu`, `img,img-rogue`, legacy `img,img-axe`. No
  SGX compatible.
- The source tree is Rogue firmware-interface code (`pvr_rogue_fwif*.h`, `pvr_fw_meta/mips/riscv.c`,
  `pvr_vm*.c`). The SGX design is not firmware-driven in the same way (services KM + userspace-loaded
  microkernel), so there is **no architectural overlap that would let it grow SGX support**. That last
  point is inference.
- Mainline Kconfig history (the file's whole log at v7.3-rc6): `4babef070865`, `ff5f643de0bf`,
  `727538a4bbff`, `eaf01ee5ba28` (all 2023-11-22, the initial driver series),
  `6b53cf48d933` (2025-08-21, enable for RISC-V), `b4cd8f94ae7e` (2025-10-14, optional
  POWER_SEQUENCING), `3519e9ea13b4` (2026-01-13, KUnit). **Nothing about 32-bit ARM or Series5.**

### 5.2 Mesa `src/imagination`

- docs.mesa3d.org `drivers/powervr.html` (fetched 2026-10-11): "PowerVR is an open source Vulkan driver
  for Imagination Technologies PowerVR GPUs … starting with those based on the Rogue architecture", and
  "GPUs prior to Series6 do not have the hardware capabilities required to support Vulkan." The supported
  list is AXE-1-16M, BXM-4-64, BXS-4-64 (Vulkan 1.2) plus partial/unsupported 6XT/6XE/7XE/8XE/BXE parts.
  **No GLES, no SGX.**

### 5.3 Upstream activity on Series5 in 2025–2026: none found

- Web searches (standard + extended, 2026-10-11) for SGX/Series5 driver work on dri-devel, LKML and Mesa
  in 2025–2026 turned up no patch series. The only 2026 dri-devel hit for the terms was an unrelated
  drm/ci series.
- GitHub mirror commit search in `torvalds/linux` for "sgx540" / "powervr sgx": the newest SGX-related
  mainline commits are the 2024 DT series and the 2021–2022 omapdrm fixes (§6.4). **Nothing after
  that.**
- Imagination's forum position, as summarised by the search tool: "no plans for a series 5 open source
  driver". The posts are years old, and I did not open them directly; they come from the search summary.
- **Limits of this search:** lore.kernel.org blocked automated access (Anubis), and the Mesa GitLab MR
  search was not queried directly. An SGX patch posted only to a list mirror I could not reach would be
  missed. Confidence that nothing upstream-bound exists: **likely, not verified**.

### 5.4 Reverse-engineering projects (open userspace for SGX)

From search results only. I did not open or verify these repos.
- `external-mirrors/sgx540-reversing` (deepwiki mirror): documents SGX540 (Galaxy Tab 2) by
  intercepting driver calls and disassembling USSE shader binaries. State unknown.
- `gabrieelgama/SGX535-reMESA`: an early-stage attempt to reconstruct enough documentation for an
  eventual Mesa driver for the SGX535 (GMA 500).
- A 2021-era Ci20 mailing-list thread on reversing the SGX540 userspace notes that a leaked vendor
  compiler source was retracted and that the community considered using it unethical. That matters for
  any clean-room plan.
- **Assessment:** there is no usable open GLES driver for SGX540 in 2026. The practical path remains the
  GPL/MIT KM plus closed userspace blobs.

### 5.5 TI's own (downstream) SGX stack, for comparison

- meta-ti master `recipes-bsp/powervr-drivers/ti-sgx-ddk-km_1.17.4948957.bb` (git.ti.com, fetched
  2026-10-11): `SRC_URI = git://git.ti.com/git/graphics/omap5-sgx-ddk-linux.git`,
  `BRANCH = ${PV}/mesa/k6.1`, `SRCREV = 9ae0fa4998b1c624408945e062bf8fb0ea7efb9d`,
  **`COMPATIBLE_MACHINE = "ti33x|ti43x|am57xx|am65xx"`**, with `TARGET_PRODUCT` ti335x/ti437x/ti572x/ti654x
  `_linux`. **OMAP4/SGX540 is not a TI-supported target.**
- meta-ti wrynose patch "mesa-pvr: Migration from v24.0.1 -> v25.2.8" (Antonios Christidis, 2026-06-10,
  read via ratatoskr.run). It moves the TI Mesa fork to 25.2.8 **for Rogue only**: "The interface for SGX
  devices is not ready in the v25 fork". SGX stays on `mesa-pvr_24.0.1` with
  `COMPATIBLE_MACHINE = "ti33x|ti43x|am57xx|am65xx"`, and the patch adds a comment, "V24 is meant for SGX
  cores, V25 is meant for Rogue". The `,sgx` gallium append for provider `ti-sgx-ddk-km` that the patch
  shows is in the *new* `mesa-pvr_25.2.8.bb`. The 24.x recipe was only re-pointed at a renamed
  `mesa-pvr-24.inc`, which I did not open. The master version of this change is `04408c57565a` "mesa-pvr:
  Migrate mesa from v24.0.1 -> v25.2.8" (2026-07-08, GitHub mirror `YoeDistro/meta-ti`).
- **TI's 6.18 BSP has no SGX.** In `meta-ti-bsp/conf/machine/include/ti-bsp.inc` on meta-ti master
  (GitHub mirror `YoeDistro/meta-ti`, head `bd0c69b1bfb8` 2026-10-06, lines 36-47; git.ti.com refused
  the raw fetch with 403), `bsp-ti-6_18` sets only the kernel, u-boot, `BSP_ROGUE_DRIVER_*` and
  `BSP_MESA_PVR_VERSION = "25%"`. **There is no `BSP_SGX_DRIVER_PROVIDER`.** Only `bsp-ti-6_12` and
  `bsp-ti-6_6` set `BSP_SGX_DRIVER_PROVIDER = "ti-sgx-ddk-km"` / `"1.17%"` and Mesa `"24%"`. The commit
  that introduced ti-6_18 (`8267e14677d0`, 2025-12-19) never added SGX lines either. **TI's newest SGX
  stack is therefore DDK 1.17.4948957 on TI kernel 6.12** (the KM recipe tracks branch `…/mesa/k6.1`),
  with a Mesa 24.0.1 fork carrying the `sgx` gallium driver, a DRI/GBM shim over the closed GLES. It is
  still the same DDK family as openpvrsgx 1.17, so the KM and Mesa shims remain portable references,
  even though OMAP4 is not a target. *(Corrected 2026-10-11: an earlier revision claimed TI ships SGX on
  a TI 6.18 BSP. Current meta-ti master refutes that.)*

---

## 6. omapdrm in 6.18: what the SGX userspace and GBM would rely on

### 6.1 Driver features and uapi

- `drm_driver.driver_features = DRIVER_MODESET | DRIVER_GEM | DRIVER_ATOMIC | DRIVER_RENDER`. This gives
  a **render node** (`/dev/dri/renderD128`). PRIME import is `omap_gem_prime_import`, and
  `dumb_create = omap_gem_dumb_create` `[omap_drv.c:637-645]`.
- Ioctls `[omap_drv.c:605-620]`:
  - `OMAP_GET_PARAM` (RENDER_ALLOW; only `OMAP_PARAM_CHIPSET_ID` → `priv->omaprev`) `[omap_drv.c:549-567]`
  - `OMAP_SET_PARAM` = `drm_invalid_op`
  - `OMAP_GEM_NEW`
  - **`OMAP_GEM_CPU_PREP` / `OMAP_GEM_CPU_FINI` = `drm_noop`, "Deprecated, to be removed"**
  - `OMAP_GEM_INFO`
- GEM flags `[include/uapi/drm/omap_drm.h:42-54]`: `OMAP_BO_SCANOUT 0x1`; cache `CACHED 0` / `WC 0x2` /
  `UNCACHED 0x4`; `TILED_8/16/32 = 0x100/0x200/0x300`. `omap_drm.h` is unchanged at v7.3-rc6.
- **Allocation policy** `[omap_gem.c:1291-1319]`:
  - TILED → shmem pages, remapped into DMM/TILER on scanout, forced to the TILER cache flags.
  - SCANOUT **without** DMM → contiguous DMA (CMA).
  - Everything else, including SCANOUT **with** DMM, → shmem.
  - On OMAP4 (DMM present), **scanout buffers are not CMA**: they are shmem and pinned into the TILER 1D
    container at scanout (`omap_gem_pin` → `omap_gem_pin_tiler` when `!omap_gem_is_contiguous && has_dmm`,
    `[omap_gem.c:805-816, 743]`).
- **dma-buf import** `[omap_gem.c:1383-1428, omap_gem_dmabuf.c:97-143]`: a non-contiguous import is
  accepted only `if has_dmm` (true on OMAP4), so a GPU-rendered scattered buffer can be scanned out via
  TILER. **Export** sets `exp_info.resv = obj->resv` `[omap_gem_dmabuf.c:88]`, giving implicit
  fencing across drivers.
- **Implicit sync on flip:** `omap_plane_prepare_fb()` calls `drm_gem_plane_helper_prepare_fb()`, then
  `omap_framebuffer_pin()` `[omap_plane.c:45-54]`. The atomic commit therefore waits on dma-resv write
  fences that the GPU driver attaches. **Open point:** whether the SGX KM attaches dma-fences.
  openpvrsgx 1.17 has `pvr_linux_fence.c`, `pvr_sync.c` and `dmabuf.c` in `env/linux`, which suggests
  yes, but that is unverified.

### 6.2 Planes, formats, limits (DISPC on OMAP4)

- `omap44xx_dispc_feats` `[dss/dispc.c:4295-4311]`:
  - `num_mgrs = 3`, `num_ovls = 4`
  - `max_lcd_pclk` 170 MHz, `max_tv_pclk` 185.625 MHz
  - `max_downscale 4`, `max_line_width 2048`, `num_fifos 5`
- Planes: overlay 0 = PRIMARY per CRTC, the rest OVERLAY. **No CURSOR plane type** `[omap_drv.c:427-440]`,
  which is consistent with `WLR_NO_HARDWARE_CURSORS=1` in our session script
  `[pmos/device-google-steelhead/nexusq-wayland.sh:8-9]`.
- Per-plane properties: `zpos` (0…num_planes-1), `alpha`, blend mode with premultiplied support
  `[omap_plane.c:101-106, 568-569]`. The `rotation` property offers 0/90/180/270 + reflect
  `[omap_plane.c:389-394]`, but **any rotation other than 0 requires a TILED framebuffer**
  `[omap_plane.c:298-299, omap_fb.c:99-102]`.
- Formats (OMAP4 overlay caps) include XRGB/ARGB/RGBA/RGBX8888, RGB888, RGB565, the 4444/1555 variants,
  and on VID planes **NV12, YUYV, UYVY** `[dss/dispc.c:1035-1092, 1754-1761, 2002]`.
- **Our HDMI cap:** patch `0010` adds `hdmi4_bridge_mode_valid()` with `mode->clock > 75000 →
  MODE_CLOCK_HIGH` `[0010…patch]`, so the desktop is ≤ 1280×720@60 (cmdline
  `video=HDMI-A-1:1280x720@60` [capture line 9]). A 720p XRGB8888 buffer is 3.69 MB, and a
  double-buffered compositor plus clients is small next to the 32 MB of SGX address space.

### 6.3 DMM/TILER on our unit

- The driver matches `ti,omap4-dmm` → `dmm_omap4_platform_data` `[omap_dmm_tiler.c:1198-1207]`. The
  i878 DMA workaround is **DRA7-only** `[omap_dmm_tiler.c:821-831]`.
- Live: `dmm 4e000000.dmm: initialized all PAT entries` [capture line 1723]; IRQ
  `omap_dmm_irq_handler` on WUGEN 113 [capture line 1110]; `[drm] Initialized omapdrm 1.0.0 … minor 0`
  [capture line 1817].

### 6.4 The SGX-driven omapdrm fixes already in 6.18 (mainline commits, author Ivaylo Dimitrov)

| Commit | Subject | First release | Why it matters |
|---|---|---|---|
| `fe4d0b6317e3` | drm: omapdrm: Export correct scatterlist for TILER backed BOs | v5.17 | "Tested on Motorola Droid4 by using GPU (sgx540) to render." Correct sg + page alignment so the SGX MMU can map exported TILER BOs |
| `36e195467ecc` | drm: omapdrm: Fix implicit dma_buf fencing | v5.18 | fences from the importing (GPU) driver are honoured on scanout ("displaying incomplete frames" before) |
| `1948d28db621` | drm: omapdrm: Support exporting of non-contiguous GEM BOs | v5.19 | shmem BOs can be exported to a render device |
| `3ccd59f93004` | drm: omapdrm: Do no allocate non-scanout GEMs through DMM/TILER | v5.19 | stops DMM space exhaustion/fragmentation |
| `86ad0397250c` | drm: omapdrm: simplify omap_gem_pin | v5.19 | refactor of the above |

**omapdrm is the most battle-tested part of the stack for SGX.** The Droid 4 community upstreamed what
they needed.

### 6.5 Userspace-facing bits already present on our image

- Alpine `main/libdrm` APKBUILD (master, fetched 2026-10-11): `pkgver=2.4.134`, built with
  **`-Domap=enabled`**. `libdrm_omap` (`omap_bo_new*`) is therefore available for GBM shims such as
  mobiaqua `libgbm`.
- Kernel config `[kernel/configs/steelhead_defconfig]`:
  - `CONFIG_DRM_OMAP=y` (2869), `CONFIG_DMA_SHARED_BUFFER=y` (1425), `CONFIG_SYNC_FILE=y` (4005)
  - `CONFIG_SW_SYNC` off (4006); `CONFIG_DMABUF_HEAPS` off (4011); `CONFIG_UDMABUF` off (4007)
  - `CONFIG_TI_SYSC=y` (1436), `CONFIG_PM_GENERIC_DOMAINS_OF=y` (586), `CONFIG_PM_OPP=y` (4896),
    `CONFIG_PM_DEVFREQ` off (4208)
  - `CONFIG_MODULES=y` (689), `CONFIG_MODULE_SIG` off (697), `CONFIG_FW_LOADER=y` (1401)
  - `CONFIG_HIGHMEM=y` (460), `CONFIG_VMSPLIT_3G=y` (438)
  - **`CONFIG_DMA_CMA=y` with `CONFIG_CMA_SIZE_MBYTES=16` (5524-5529)**
  - `CONFIG_DRM_ACCEL` off (3042)

  An out-of-tree `pvrsrvkm` can therefore be built as a module against the shipped kernel without any
  config change beyond what the module itself needs. That is inference: the module's exact `depends`
  list must be checked against our `.config`.
- **CMA: 16 MiB, low *free* count. That does not mean low *availability*.** The figures are
  `CmaTotal: 16384 kB` and `CmaFree: 2296 kB` [capture lines 59-60], with `cma: Reserved 16 MiB at
  0xbe000000` [capture line 1383]. That range is in the **HighMem zone**
  (`HighMem [mem 0xafe00000-0xbeffffff]` [capture line 1387]), and HighMem as a whole is nearly full
  (`HighFree: 4552 kB`). The page allocator lends free CMA pageblocks to *movable* allocations: page cache
  and anonymous user pages go there "when over half of the zone's free memory is in the CMA area"
  (`mm/page_alloc.c` v6.18 L2450-2461, `__rmqueue_cma_fallback`). `cma_alloc()` migrates those pages out
  on demand. A low `CmaFree` is therefore what a busy system normally shows, not evidence that 14 MiB
  are pinned by DMA users. *(Corrected 2026-10-11: an earlier revision said "CMA is nearly full already"
  and "16 MiB is not enough". Both are **UNVERIFIED**.)* The open points still stand. The older
  openpvrsgx branch `letux/pvrsrvkm-1.17` (`e521fd7b65b0`, 2019) has "srvkm: Use CMA region as default for
  memory alloc", so a CMA-allocating KM needs its *peak* contiguous demand to fit in 16 MiB minus the
  real pinned users (omapdrm scanout on DMM boards is shmem, §6.1). Measure it with
  `CONFIG_CMA_DEBUGFS` (off today, defconfig:822) or by checking `cma_alloc` failures in dmesg.

---

## 7. The out-of-tree driver vs. mainline: how the pieces line up

(The openpvrsgx details are covered in depth by another workstream. Only the mainline-interface facts are
here.)

### 7.1 Branch state (GitHub `openpvrsgx-devgroup/linux_openpvrsgx`, read 2026-10-11)

| Branch | Kernel base (Makefile) | Head commit | Head date |
|---|---|---|---|
| `master` | 7.2.0 | `eedee3c02342` "Letux: rootfs: gpu-demo: add glxgears and glxinfo" | 2026-08-16 |
| `letux/omap-pvr-soc-glue-v10` | 7.2.0 | `57c9a409ba70` (11 commits on top of Linux 7.2 `8d3ae59288f1`) | 2026-08-16 (rebase) |
| `letux/omap-sysc-prm-gfx` | 7.2.0 | `5c31c028e783` (2 old Tero Kristo commits) | 2026-08-16 (rebase) |
| `letux/pvrsrvkm-v3` (wrapper `pvr-drv.c`) | 7.2.0 | `7865ecbcc7b5` | 2026-08-16 |
| `letux/pvrsrvkm-1.17.4948957-v3` | 7.2.0 | `e5de75568819` "1.17.4948957: more strncpy -> strscpy" (152 commits ahead of 7.2) | 2026-08-21 |
| `letux/pvrsrvkm-1.14.3699939` | 7.2.0 | `32ca371758a6` | 2026-08-21 |
| `letux/pvrsrvkm-1.9.2188537` | 7.2.0 | `e4e332159df1` "fix for 6.16-rc1: convert from_timer() to timer_container_of()" | 2026-08-16 |
| `letux/pvrsrvkm-generic` | 7.2.0 | `c017d06c1b41` "gpu: pvrsrvkm: SoC integration reconstructed from 1.17.4948957" | 2026-08-16 |
| `letux/pvrsrvkm-1.17.4948957` (cited in June note) | **6.15-rc5** | `584dd33a1557` "fix for 6.15-rc1" | 2025-05-04 (head not moved since; still merged into the per-kernel integration branches below) |
| `letux/pvrsrvkm-1.8.869593` | 7.2.0 | `214f07dd8fe4` "1.8.869593: fix Makefile for out-of-tree builds since v6.9-rc1" | 2026-08-16 (rebase) |
| **`pvrsrvkm-6.18-rc6`** (integration) | **6.18.0-rc6** | `d2f1e031d58a` merge of `omap-sysc-prm-gfx`, `omap-pvr-soc-glue-v10`, all `letux/pvrsrvkm-1.x` DDK branches (incl. 1.8.869593 and 1.17.4948957), `ddk-core`, `generic`, `pvrsrvkm-v2`, `defconfig` | 2025-11-21 |
| `pvrsrvkm-6.19-rc6`, `pvrsrvkm-7.0`, `pvrsrvkm-7.1`, `pvrsrvkm-7.2` (integration) | per name | `f0f6774c85c3`, `d44512677de0`, `c9c94731b070`, `2342ce92fdde` | 2026-01-20, 2026-07-08, 2026-06-29, 2026-08-26 |

*(Added 2026-10-11.)* The repo has 92 branches, among them integration branches for nearly every kernel
since 5.x (`pvrsrvkm-6.0` … `pvrsrvkm-7.2`). **`pvrsrvkm-6.18-rc6` is the closest base to our 6.18.48 LTS.**
Its `drivers/gpu/drm/pvrsgx/pvr-drv.c` already carries `ti,omap4430-gpu` → `pvr_omap4430` (L287, L364) and
`pm_runtime_get_sync` (L441), and its `drivers/gpu/drm/pvrsgx/` holds all DDK trees, 1.8.869593 and
1.17.4948957 among them. It merges `pvrsrvkm-v2`, not `v3`, and the non-v3 1.17 branch, so the 2026 gldrk
work (§7.2) is **not** in it.

**The OMAP4 glue branch (`soc-glue-v10`) contains nothing OMAP4-specific beyond what mainline already
has.** Its 11 commits on top of 7.2 are the binding/rename duplicates plus DT nodes for jz4780, sun6i/a31s,
sun8i-a83t, s5pv210, am33xx, omap4470 and CSR. In other words, **mainline 6.18 already contains the OMAP4
"SoC glue"** (target module, clocks, PRM, binding, `gpu@0`). The only OMAP4 DT delta still worth carrying
is the clock re-parent from §3.4.

### 7.2 Recent KM work relevant to blob choice (from commit subjects; not reviewed in depth)

On `letux/pvrsrvkm-1.17.4948957-v3`, by "gldrk", 2026-06-23 → 2026-07-19. The run starts with "Enable
Poulsbo/Cedarview support", so its focus is the Intel GMA (x86) PCI path:
- "Support DRM dumb buffers", "Allow creating FBOs from userspace", "Use sys fbdev helpers".
- "Support 1.7.862890 ABI" (a compile-time switch). Its Makefile now has
  `ccflags-$(CONFIG_PVRSGX_1_7_862890_ABI) += -DPVR_ABI_COMPAT=1,7,862890` and the same for 1.17.4948957.
- "Support alternative ioctl numbers", "Add driver ABI configuration options".

A single 1.17 KM serving more than one userspace ABI is new in 2026. It may widen which userspace blob
sets are usable, but **1.8@785978 (our stock Android set) is not one of the listed ABIs.** Only
`PVRSGX_1_7_862890_ABI` and `PVRSGX_1_17_4948957_ABI` exist (DDK Makefile L34-35, Kconfig).

*(Added 2026-10-11.)* There is a separate DDK branch, **`letux/pvrsrvkm-1.8.869593`**. Its Kconfig entry
`PVRSGX_1_8_869593` reads "DDK 1.8.869593 (TI) … This version should work on OMAP4430, 4460, 4470,
OMAP5". It is the same DDK *generation* as the stock 1.8@785978 blobs. SGX services ABIs are tied to
the exact build number, so whether a 1.8.869593 KM accepts the 1.8@785978 userspace is **UNVERIFIED**.
The bridge/ioctl structures would have to be compared.

### 7.3 Binding: wrapper vs. DDK tables

- `pvr-drv.c` on `letux/pvrsrvkm-v3` has `pvr_ids[]`, including
  `#ifdef ti_omap4_sgx540_120  { .compatible = "ti,omap4430-gpu", .data = &pvr_omap4430 }`.
  The capability struct is `pvr_omap4430 = { .ocp_offset = 0xfe00, .quirks = PVR_QUIRK_OMAP4, .sgx_version = 540, .sgx_revision = 120 }`.
- Its probe does `devm_platform_ioremap_resource(pdev, 0)`, `pm_runtime_enable` + `pm_runtime_get_sync`,
  then `drm_dev_alloc(&pvr_drm_driver, …)`, `pvr_drm_load`, `drm_dev_register` (L433-458). **It consumes
  the unmodified mainline 6.18 `gpu@0` node**, but only when the module is built for that flavour. The
  `ti,omap4430-gpu` entry is under `#ifdef ti_omap4_sgx540_120`, and the DDK Makefile defines that macro
  through `-D$(SOC_VENDOR)_$(SOC)_$(SGX)_$(SGX_REV)`.
- `PVR_QUIRK_OMAP4` is only stored and printed in `pvr-drv.c` (L410-411: `ddata->quirks = cap->quirks`,
  "Enabling quirks %08x"). Nothing in that file acts on it, so any OMAP4-specific handling would have
  to be in the DDK. Not checked.
- The legacy DDK tables (`eurasia_km/services4/srvkm/env/linux/module.c:287-295` and `pvr_drm.c:187-195`
  on the 1.17-v3 branch) still list old compatibles such as `"ti,omap4-sgx540-120"`. They sit under
  `PVR_USE_DEVICE_TREE`, while the Makefile builds the module as `pvrsrvkm_$(SOC)_$(SGX)_$(SGX_REV)` with
  `SYS_SGX_DEV_NAME="$(SOC_VENDOR),$(SOC)-$(SGX)-$(SGX_REV)"` (Makefile L38), which expands to
  `"ti,omap4-sgx540-120"` for OMAP4. The Makefile comment calls this "the compatible string which must be
  present in the DTB of the board". **Which match table is live in the final build depends on the
  build flags.** If the plan builds only the eurasia part without `pvr-drv.c`, the DT would need the
  legacy compatible, which breaks `dtbs_check`. **UNVERIFIED**; flagged as an open question.
- `config SGX_DRM … select DRM_LEGACY` survives in the openpvrsgx Kconfig, but **`DRM_LEGACY` no longer
  exists**: it is present in v6.7's `drivers/gpu/drm/Kconfig` and absent from v6.8 and 6.18.48. Kconfig
  ignores a select of an undefined symbol, and the branch builds on 7.2, so this is cosmetic. It is
  inference that nothing legacy is actually used; the branch building on 7.2 supports that.

### 7.4 API deltas a 7.2-based KM must cross to build on our 6.18 LTS

| Change | First mainline release | Evidence |
|---|---|---|
| `from_timer()` → `timer_container_of()` | v6.16 | openpvrsgx commit `e4e332159df1` "fix for 6.16-rc1" (6.18 has the new name, so this direction is fine) |
| `del_timer_sync()` → `timer_delete_sync()` | v6.15 | openpvrsgx `584dd33a1557` (fine on 6.18) |
| `kmalloc_obj()` / `kzalloc_obj()` family | **v7.0** | the macros are absent from `include/linux/slab.h` at v6.19 and present at v7.0 (L1008ff). Mainline `69050f8d6d07` (2026-02-21, Kees Cook) is the *treewide conversion* to them, not the commit that introduced them; it is in v7.0 and not in v6.19. The 6.18→7.3 ti-sysc/omapdrm diffs show the conversions. **A 7.x KM using these needs a compat shim on 6.18** |
| `struct drm_atomic_state` → `struct drm_atomic_commit` | **v7.2** | mainline `5164f7e7ff8e` (2026-04-27, Maxime Ripard), in v7.2, not v7.1. `include/drm/drm_atomic.h` at v7.3-rc6 line 483 is `struct drm_atomic_commit {`. Matters if the KM's DRM part touches atomic state |
| `vm_get_page_prot()` → `vma_get_page_prot()`, `linear_page_delta()` | 7.3 cycle | omapdrm diff 6.18.48 vs v7.3-rc6; commits `a2fdfd0080a3`, `93d23dff8eb5` (2026-07). Relevant if the KM's mmap code was converted |

Practical consequence (inference). There are two routes to build on our kernel:
- **(a)** Start from the existing **`pvrsrvkm-6.18-rc6`** integration branch (§7.1). It already builds
  against 6.18-rc6 APIs, needs no 7.x backport, and has all the DDKs. It lacks the 2026 gldrk 1.17-v3
  work. Whether it builds unchanged on 6.18.48 (stable backports) is UNVERIFIED but likely.
- **(b)** Take a 7.2-based branch and **revert its 7.x-only API conversions** or carry a small `compat.h`.

*(Corrected 2026-10-11: an earlier revision said no 6.18 branch exists. `pvrsrvkm-6.18-rc6` and
`pvrsrvkm-6.19-rc6` both exist.)*

---

## 8. 6.18 vs. newer mainline (6.19 → v7.3-rc6): anything that changes the plan?

Release dates (GitHub tag commits): v6.18 2025-11-30 (`7d0a66e4bb90`), v6.19 2026-02-08 (`05f7e89ab973`),
v7.0 2026-04-12 (`028ef9c96e96`), v7.1 2026-06-14 (`8cd9520d35a6`), v7.2 2026-08-16 (`8d3ae59288f1`),
v7.3-rc6 **2026-10-04** (`a90ee4305c4a`). *(Corrected: an earlier revision gave 2026-10-09, which is
master head `3857c2fe5449`.)*

- **Byte-identical between 6.18.48 and v7.3-rc6:** `omap4.dtsi`, `omap443x.dtsi`, `omap4460.dtsi`,
  `clk-44xx.c`, `include/uapi/drm/omap_drm.h`.
- **`ti-sysc.c`:** only the `kzalloc_obj` conversion and `6342de0aed21` (2026-06-15) "Fix /chosen node
  reference leak". Nothing GPU-related.
- **omapdrm since 2025-09:** bridge/atomic API churn only:
  - `drm_atomic_get_new_crtc_state` (`0a10e3998239`)
  - dumb-buffer sizing via `drm_mode_size_dumb()` (`9ea885b3a6bf`)
  - private-obj `atomic_create_state` (`af95bb0092fa`), hdmi4/hdmi5 `atomic_create_state` (`475ed82803ac`,
    `ecc6618af531`)
  - dpi/dsi/sdi/venc atomic bridge callbacks (2026-07)
  - the `drm_atomic_commit` rename
  - `of_drm_find_and_get_bridge` (`0a7f39ba3ffc`)

  No new GEM uapi and no TILER changes. **Note for our patch `0010`:** hdmi4 moved to
  `atomic_create_state` in `475ed82803ac` (2026-06-19), so the `.mode_valid` hunk context will need a
  rebase on a future kernel bump.
- **OMAP DTS since 2025-06: much activity, none of it GPU-related.** *(Corrected 2026-10-11: an earlier
  revision said only `omap4-epson-embt2ws` changed.)* `gh api commits?path=arch/arm/boot/dts/ti/omap`
  up to v7.3-rc6 lists about 50 commits. The OMAP4-relevant ones:
  - `omap4-l4.dtsi` edits: `1e79c330713e` watchdog node names, `68f994ec51e2` specific compatibles for SCM
    conf nodes, `7adefbf4dff3` node-pattern alignment
  - new **Samsung Galaxy Tab 2** boards, `omap4-samsung-espresso{7,10}.dts` + `espresso-common.dtsi`
    (`16dcd2c7535e`/`f1bf8f533554`/`f768d54723d1`, first in v7.1). They are another OMAP4430/SGX540 device
    in mainline, though their commits add no GPU nodes or properties.
  - `twl6032.dtsi` (`3b142fdcae78`)
  
  None of these patches contains "sgx" or "gpu". `omap4.dtsi`, `omap443x.dtsi` and `omap4460.dtsi` are
  unchanged. A future kernel bump will still need our 0003 DTS rebased over the `omap4-l4.dtsi` changes.
- **drm/imagination:** still ARM64/RISCV64, still Rogue-only (§5.1).
- **32-bit outlook (risk, not a blocker):** Arnd Bergmann's CONFIG_HIGHMEM phase-out plan (LKML
  2025-09-18) and the series "mm: increase lowmem size in linux-7.0" push toward `VMSPLIT_3G_OPT` and
  fewer highmem users. As of v7.3-rc6, `arch/arm/Kconfig` still defaults to `VMSPLIT_3G` and still offers
  `HIGHMEM`. Our unit has 224 MiB highmem ("229376K highmem" [capture line 1444]; 229376 KiB = 224 MiB),
and the 16 MiB CMA area sits inside it. An old DDK that
  `kmap()`s pages may meet friction on future kernels. Staying on 6.18 LTS avoids this for now.
  (Inference from the plan, not from a merged change.)

---

## 9. What this means for the GPU plan (mainline-side checklist)

1. **No kernel patch is needed to expose the SGX to a driver.** Build the out-of-tree KM (openpvrsgx
   `pvr-drv.c` + one DDK `eurasia_km`) as a `.ko` against 6.18.48. Start either from the
   `pvrsrvkm-6.18-rc6` integration branch, which needs no compat layer, or from a 7.2 branch with a
   7.x→6.18 compat layer (§7.4).
2. **DT delta: one `&sgx_module` assigned-clocks block** (§3.4) for stock parity, at 307.2 MHz on
   DPLL_PER M7. Do not chase 384 MHz: it needs core OPP-OV at 1.25 V, which mainline does not scale.
3. **Verify, read-only, before building anything** (needs the device; not done here):
   - GFX genpd state: `/sys/kernel/debug/pm_genpd/pm_genpd_summary`
   - the `56000000.gpu` platform device exists and is unbound
   - the CORE_REVISION read at `0x56000024` (procedure in §4)
   - the actual VDD_CORE (TWL6030 VCORE1) voltage
4. **CMA budget:** decide whether the KM allocates from CMA. If so, measure the real pinned CMA use
   (enable `CONFIG_CMA_DEBUGFS`) before sizing it. The low `CmaFree` in the capture is mostly movable
   pages borrowed from CMA (§6.5), not pinned users. Otherwise make sure the KM uses its own page
   allocator with the SGX MMU.
5. **Display integration path:**
   - GPU renders into omapdrm-allocated (or KM-allocated, PRIME-exported) shmem BOs.
   - omapdrm imports through DMM and scans out via TILER, with implicit fencing via dma-resv.
   - `libdrm_omap` is already in Alpine.
   - Rotation and NV12 need TILED BOs.
   - No cursor plane: keep the software cursor.
   - At most 4 planes. Direct scanout of a single fullscreen client is the realistic win at 720p.
6. **Thermal headroom is thin.** The capture shows `cpu_thermal` at 86.1 °C with the passive trip at
   100 °C [capture line 776]; the GFX domain shares the die. A GPU workload needs a thermal check in the
   diag sweep.

---

## Open questions

1. What does `5600fe00.target-module` read for OCP REVISION on our 4460? This is informational only: the
   ti-sysc L1610 "gpu" name entry is `#ifdef DEBUG` and not in our build. Does `0x56000024` read
   `0x00010200`? (Needs read-only device access.)
2. Is the GFX genpd actually OFF after boot? Does the unbound `gpu@0` platform device exist under the
   name `56000000.gpu`?
3. What is the real VDD_CORE (TWL6030 VCORE1) voltage at runtime on mainline? Is 1.2 V (VC ON, patch
   0027) what the rail sits at, or only the wake target? This decides whether 307.2 MHz is within the
   stock OPP voltage (≥ 1.127 V). *(2026-10-11: neither. Expected 1.139 V from the x-loader; read with
   `nexusq-gpu-probe.sh --pmic` [pm Addendum "Live VDD_CORE without a device"].)*
4. How much of the 16 MiB CMA is *pinned* (not merely borrowed by movable pages) today? Does the chosen
   openpvrsgx DDK branch allocate SGX memory from CMA? (`CONFIG_CMA_DEBUGFS` is off in our defconfig.)
5. In the openpvrsgx build, which match table is live for OMAP4: `pvr-drv.c` (`ti,omap4430-gpu`) or
   the DDK's `PVR_USE_DEVICE_TREE` tables (`ti,omap4-sgx540-120`)? Does any 7.2 DDK branch build
   without the `pvrsrvkm-v3` wrapper?
6. Does the KM publish dma-fences into the exported buffer's dma-resv, so that omapdrm's
   `drm_gem_plane_helper_prepare_fb()` actually synchronises scanout with GPU rendering?
7. Is the stock steelhead microkernel really uploaded by `pvrsrvinit` from `libsrv_init.so` (no
   separate firmware file)? This needs disassembly of `pvrsrvinit`/`libsrv_init.so`, not just strings.
8. Is there any 2025–2026 SGX/Series5 patch on dri-devel or in Mesa GitLab that the blocked
   lore.kernel.org search would have shown? A manual browser check is suggested.
9. Do the M7 HSDIVIDER outputs autoidle once the SGX mux moves off `dpll_core_m7x2_ck`, or does CORE M7
   need explicit gating?
10. Can a `letux/pvrsrvkm-1.8.869593` KM serve the stock 1.8@785978 userspace blobs, or does the
    services bridge ABI differ between the two 1.8 builds?
11. Does the `pvrsrvkm-6.18-rc6` integration branch build unchanged as an external module against
    6.18.48?

## Sources

**Local, read 2026-10-11**
- `linux-6.18.48` tarball from docker volume `nexusq-workdir:/cache_distfiles/linux-6.18.48.tar.xz`. Files
  cited: `arch/arm/boot/dts/ti/omap/{omap4.dtsi, omap443x.dtsi, omap4460.dtsi, omap446x-clocks.dtsi, omap44xx-clocks.dtsi}`,
  `Documentation/devicetree/bindings/gpu/img,powervr-sgx.yaml`, `drivers/clk/ti/clk-44xx.c`,
  `drivers/bus/ti-sysc.c`, `drivers/pmdomain/ti/{omap_prm.c,Kconfig}`,
  `arch/arm/mach-omap2/{powerdomains44xx_data.c, clockdomains44xx_data.c, pdata-quirks.c}`,
  `drivers/gpu/drm/imagination/{Kconfig,pvr_drv.c}`,
  `drivers/gpu/drm/omapdrm/{omap_drv.c, omap_gem.c, omap_gem_dmabuf.c, omap_plane.c, omap_fb.c, omap_dmm_tiler.c, dss/dispc.c, TODO}`,
  `include/uapi/drm/omap_drm.h`, `include/dt-bindings/clock/omap4.h`, `MAINTAINERS`.
- Repo:
  - `docs/2026-06-19-gpu-sgx540-acceleration-research.md`, `docs/2026-06-19-particle-screensaver-RE.md`,
    `PLAN.md` §4 (line 2160ff)
  - `kernel/patches/0003-…steelhead.patch`, `0010-…hdmi4-cap-pixel-clock…patch`,
    `0025-…ti-sysc-child-named-clock…patch`, `0027-…vc-on-voltages…patch`
  - `kernel/configs/steelhead_defconfig`, `pmos/device-google-steelhead/nexusq-wayland.sh`
  - `nq-captures/20261010-185940/snapshot.txt` (and the same clock values in every capture since
    2026-07-03)
- Stock ground truth:
  - `reverse-eng/vmlinux.bin` (3.0.8). Symbols from `reverse-eng/tools/kallsyms.txt`, disassembly via
    `reverse-eng/tools/nqdis.py` (capstone in a scratch venv). Addresses: `omap4_steelhead_display_init`
    0xc0075ef8; OPP records 0xc0043c9c, 0xc0043e94; strings 0xc065a444, 0xc0680738, 0xc068a258.
  - `reverse-eng/factory/tungsten-ian67k/system.raw.img` via `debugfs -R ls/dump`: `/vendor/lib/egl/*SGX540_120.so`,
    `/vendor/lib/libsrv_um.so`, `libsrv_init.so`, `/vendor/bin/pvrsrvinit`.

**Mainline (GitHub mirror `github.com/torvalds/linux`, via `gh api`, 2026-10-11)**
- Commits opened:
  - SGX binding and DT: `796da8ca7e05` (binding, v6.9), `c137afbe6c4e` (omap4 gpu@0, v6.9),
    `8fca3d8dbebf`, `2f6f6b525f52` (binding maintainers 2026-06)
  - OMAP4 GPU module history: `1b95c5a48f5e`, `3e5c3c41ae92`, `345ac6b17b18`, `19d3e9a0bdd5`, `fab030ac9997`
  - omapdrm SGX fixes: `fe4d0b6317e3`, `36e195467ecc`, `1948d28db621`, `3ccd59f93004`, `86ad0397250c`
  - API churn: `69050f8d6d07` (kmalloc_obj, v7.0), `5164f7e7ff8e` (drm_atomic_commit, v7.2)
  - drm/imagination Kconfig: `6b53cf48d933`, `b4cd8f94ae7e`, `3519e9ea13b4`
  - ti-sysc: `6342de0aed21`
- File contents at tag `v7.3-rc6` for the 6.18-vs-head diffs; `arch/arm/Kconfig` at v7.3-rc6;
  `drivers/gpu/drm/Kconfig` at v6.7/v6.8 (DRM_LEGACY).

**openpvrsgx (`github.com/openpvrsgx-devgroup/linux_openpvrsgx`, via `gh api`, 2026-10-11)**
- Branch heads and Makefiles listed in §7.1.
- `drivers/gpu/drm/pvrsgx/pvr-drv.c` and `Kconfig` at `letux/pvrsrvkm-v3`.
- `…/1.17.4948957/eurasia_km/Makefile`, `…/env/linux/{module.c,pvr_drm.c}` at
  `letux/pvrsrvkm-1.17.4948957-v3`.
- Commits `ca220f520c26`, `b9b0a1cd50dc`, `15b675c69c87`, `bc3a02e44c41`.

**Web (fetched or searched 2026-10-11)**
- Andrew Davis, "[PATCH 00/11] Device tree support for Imagination Series5 GPU", 2024-01-09:
  https://lkml.rescloud.iu.edu/2401.1/02082.html
- RFC predecessor on dri-devel (2023-12): https://lists.freedesktop.org/archives/dri-devel/2023-December/433971.html
  (search result only, not opened)
- Mesa PowerVR driver docs: https://docs.mesa3d.org/drivers/powervr.html
- meta-ti `ti-sgx-ddk-km_1.17.4948957.bb`:
  https://git.ti.com/cgit/arago-project/meta-ti/tree/meta-ti-bsp/recipes-bsp/powervr-drivers/ti-sgx-ddk-km_1.17.4948957.bb
- meta-ti "mesa-pvr: Migration from v24.0.1 -> v25.2.8" (2026-06-10): https://ratatoskr.run/yocto-meta-ti/2026/06/17117185/t
- Alpine libdrm APKBUILD: https://gitlab.alpinelinux.org/alpine/aports/-/raw/master/main/libdrm/APKBUILD
- Imagination forum, "Open source older gpus": https://forums.imgtec.com/t/open-source-older-gpus/3425 (search
  summary only)
- RE projects (search summary only, not opened): https://deepwiki.com/external-mirrors/sgx540-reversing ,
  https://github.com/gabrieelgama/SGX535-reMESA ,
  https://groups.google.com/g/mips-creator-ci20-dev/c/XNBWlAb8DX8
- pmaports MR !1868 "PowerVR SGX Acceleration": https://gitlab.com/postmarketOS/pmaports/-/merge_requests/1868
  (search result; covered by another workstream)
- Arnd Bergmann, "Reaching consensus on CONFIG_HIGHMEM phaseout" (2025-09-18): https://lkml.org/lkml/2025/9/18/987 ;
  "mm: increase lowmem size in linux-7.0": https://ratatoskr.run/linux-arm-kernel/2025/12/334698/t (search summaries)
- **Could not open:** git.kernel.org cgit (HTTP 403) and lore.kernel.org search (Anubis bot wall). The
  mainline history comes from the GitHub mirror instead.

---

## Verification (2026-10-11)

An independent adversarial fact-check re-opened every cited source. Local sources: the `linux-6.18.48`
extract, the repo, `nq-captures/20261010-185940/snapshot.txt`, and `reverse-eng/vmlinux.bin` through
`nqdis.py` and a record dump. Stock `/system` was read with `debugfs`. Remote sources: GitHub
`torvalds/linux` and `openpvrsgx-devgroup/linux_openpvrsgx` through `gh api`, the GitHub mirror
`YoeDistro/meta-ti`, git.ti.com, ratatoskr.run, docs.mesa3d.org, Alpine GitLab and lkml.rescloud.iu.edu.

### Confirmed (reproduced)
- **`omap4.dtsi` SGX node:** `omap4.dtsi:484-509` matches character for character: `sgx_module`
  rev/sysc `0x5600fe00/0x5600fe10`, `power-domains = <&prm_gfx>`, `fck` =
  `<&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 0>`, and `gpu@0` with compatible
  `"ti,omap4430-gpu","img,powervr-sgx540"`, 32 MB, `GIC_SPI 21`. Neither node has a `status`.
  `prm_gfx` is at `omap4.dtsi:812-816`.
- **`c137afbe6c4e` and `796da8ca7e05`:** both Andrew Davis, authored 2024-01-09, committed by Tony
  Lindgren 2024-01-26. Both are "diverged" against v6.8 and "behind" (contained) at v6.9. The binding
  commit carries Message-ID `20240109171950.31010-3-afd@ti.com`.
- **Our DTS:** patch 0003 L65 is `#include "omap4460.dtsi"`. A grep for sgx/gpu over `kernel/patches/`
  hits only the omapdrm *path* in patch 0010, no GPU node.
- **Capture clock tree** (snapshot.txt:465-470 and 324-333, column order checked against the header at
  L145-146): `l3-gfx-clkctrl:0000:0` reads enable 0 / prepare 1 / HW N, consumer `5600fe00.target-module
  fck`. The mux and gate run at 266 666 667 Hz under `dpll_core_m7x2_ck`. `dpll_per_m7x2_ck` is at
  307.2 MHz with prepare 0 and enable 0.
- **Clock data and DT:** `clk-44xx.c:327-341, 703, 763` and `omap443x.dtsi:77-86` are as quoted.
  `omap4460.dtsi` and `omap446x-clocks.dtsi` contain no sgx/gpu reference.
- **Stock board code:** `omap4_steelhead_display_init` @0xc0075ef8 disassembles exactly as described:
  `clk_get("dpll_per_m7x2_ck")` @0xc0075f08, `clk_get("gpu_fck")` @0xc0075f24, `clk_set_parent`
  @0xc0075f40, `omap_vram_set_sdram_vram(0x1000000, 0)` @0xc0075f64. The error string @0xc065a444 reads
  "failed to set gpu_fck to dpll_per_m7x2_ck".
- **Stock OPP records** (6-word layout): @0xc0043c9c/0xc0043cb4 hold gpu 153.6 MHz/962 mV and
  307.2 MHz/1127 mV; @0xc0043e94/0xc0043eac/0xc0043ec4 hold 153.6/307.2/384 MHz at 962/1127/1250 mV, all
  avail=1. The iva 430/500 MHz @1.375 V records are avail=0. **Upgraded from "likely" to verified:**
  kallsyms names the tables `omap443x_opp_def_list` (0xc0043bc4) and `omap446x_opp_def_list` (0xc0043d5c).
- **Binding file:** `img,powervr-sgx.yaml` at 6.18.48 is as described: required properties, and
  power-domains/clocks forbidden for `ti,omap4430-gpu`. Its maintainer changed by v7.3-rc6, confirmed
  by diff and by `8fca3d8dbebf`/`2f6f6b525f52`.
- **Rev 120:** the stock `/vendor/lib/egl/*_SGX540_120.so` files exist (debugfs). Commit `1b95c5a48f5e`
  quotes `0x56000024 = 0x00010200 # SGX540 CORE_REVISION` and "Bus error" when idled.
- **drm/imagination:** Kconfig at 6.18.48 and at v7.3-rc6 says `depends on (ARM64 || RISCV && 64BIT)`.
  The OF table holds only `thead,th1520-gpu`, `img,img-rogue` and `img,img-axe`.
- **Mesa docs:** fetched again. They read "GPUs prior to Series6 do not have the hardware capabilities
  required to support Vulkan … cannot be supported by this driver".
- **Absence of upstream SGX work:** a fresh extended web search found no 2025-2026 SGX/Series5 patch.
  This stays **likely, not verified**, because lore.kernel.org was still not queried directly.
- **OMAP PRM and powerdomain:** `omap_prm.c:125-128` (`omap_prm_onoff_noauto`) and `196-199` (gfx
  `0x4a307200`, no rstctrl). The AM33xx/AM43xx gfx entries have rstctrl. `powerdomains44xx_data.c:56-71`
  sets `PWRSTS_OFF_ON`. All match.
- **ti-sysc quirk lines:** L1534-1536, 1609-1610, 1948-1955 and 2050-2051 are as quoted.
- **omapdrm:** the ioctls (`omap_drv.c:605-620`, CPU_PREP/FINI = `drm_noop`), `DRIVER_RENDER`, the
  `omap_drm.h` flags, the allocation policy (`omap_gem.c:1291-1319`), import `has_dmm` gating,
  `exp_info.resv = obj->resv` (`omap_gem_dmabuf.c:88`), `prepare_fb` calling
  `drm_gem_plane_helper_prepare_fb`, `dispc.c` (4 ovls, 3 mgrs, line width 2048), the plane/rotation
  code and `omap_fb.c:99-102` all match.
- **omapdrm SGX fixes:** `fe4d0b6317e3` (v5.17, "Tested on Motorola Droid4 by using GPU (sgx540) to
  render"), `36e195467ecc` (v5.18), and `1948d28db621`/`3ccd59f93004`/`86ad0397250c` (v5.19), all Ivaylo
  Dimitrov. Each was checked by tag compare.
- **Byte-identical files:** `omap4.dtsi`, `omap443x.dtsi`, `omap4460.dtsi`, `omap44xx-clocks.dtsi`,
  `clk-44xx.c`, `omap_drm.h` and `omap_prm.c` are identical between 6.18.48 and the **v7.3-rc6 tag**
  (re-diffed).
- **API deltas:** `5164f7e7ff8e` is in v7.2 and not in v7.1, and `struct drm_atomic_commit {` is at
  `drm_atomic.h:483` (v7.3-rc6). `timer_container_of` arrived in v6.16. `DRM_LEGACY` is in v6.7 Kconfig
  and absent from v6.8.
- **openpvrsgx branch table:** every head SHA, date and Makefile base in §7.1 matches. `1.17-v3` is 152
  commits ahead of v7.2. `soc-glue-v10` is 11 commits ahead of v7.2 with exactly the subjects listed.
  `omap-sysc-prm-gfx` is 2 Tero Kristo commits. `ca220f520c26` only adds per-SoC `*-prm-inst` auxdata,
  which is redundant for OMAP4 given `pdata-quirks.c:494-496`.
- **pvr-drv.c on `letux/pvrsrvkm-v3`:** `pvr_omap4430` at L287-292, the compatible at L363-364, and
  probe at L433-458.
- **DDK tables:** `module.c:287-295` and `pvr_drm.c:187-195` list `"ti,omap4-sgx540-120"` under
  `PVR_USE_DEVICE_TREE`.
- **meta-ti recipe:** `ti-sgx-ddk-km_1.17.4948957.bb` (git.ti.com) has BRANCH `${PV}/mesa/k6.1`, SRCREV
  `9ae0fa49…`, and COMPATIBLE_MACHINE `ti33x|ti43x|am57xx|am65xx`. The ratatoskr patch exists (Antonios
  Christidis, 2026-06-10) with the quoted SGX sentence.
- **Stock DDK:** the vmlinux string @0xc0680738 is `…sgxddk 18 1.8@785978`. The GLES2 blob reads
  "OpenGL ES 2.0 build 1.8@785978". `libsrv_init.so` contains `SetupuKernel`, `LoaduKernelPrograms` and
  "SGX ukernel". `/vendor/firmware` holds no SGX file. The microkernel-upload conclusion stays
  **inference (likely)**.
- **Other repo facts:** the defconfig lines cited in §6.5 and the Alpine libdrm APKBUILD
  (`pkgver=2.4.134`, `-Domap=enabled`) were re-checked. So were the cover-letter quote, its 11-patch
  list and its base `next-20240109`, and the capture lines 9, 1110, 1383, 1444, 1723, 1817, 1821 and 776
  (86.1 °C, passive trip at 100 °C).

### Corrected
1. **v7.3-rc6 identity and date.** The tag is `a90ee4305c4a`, dated 2026-10-04. `3857c2fe5449`
   (2026-10-09) is master head, 337 commits past rc6. Fixed in the header and in §8.
2. **"The 446x OPP symbol is not in kallsyms" was wrong.** Both table symbols are present, so the claim
   was upgraded to verified (§3.3).
3. **SGX revision string location:** it is referenced from `SysFinalise` @0xc028fb2c, and 0xc028fc28 is
   the literal-pool word (§2).
4. **ti-sysc "gpu" name entries:** L1609/L1610 are inside `#ifdef DEBUG` (L1585-1660), so they are not
   compiled into our kernel. §4, the probe procedure and open question 1 were adjusted.
5. **"No 6.18 openpvrsgx branch exists" was wrong.** `pvrsrvkm-6.18-rc6` (`d2f1e031d58a`, 2025-11-21)
   exists, along with `-6.19-rc6`, `-7.0`, `-7.1` and `-7.2`. It is the natural base for 6.18.48 and has
   `ti,omap4430-gpu` in `pvr-drv.c`. Updated in the TL;DR, §7.1, §7.4 and §9.
6. **A 1.8-generation DDK branch was missed.** `letux/pvrsrvkm-1.8.869593` is TI's 1.8 DDK, and its
   Kconfig names OMAP4430/4460. It was added to §7.1/§7.2 with open question 10.
7. **The CMA reasoning was wrong.** The CMA area (0xbe000000) lies in the HighMem zone, and the
   allocator lends CMA pages to movable allocations (`mm/page_alloc.c` v6.18 L2450-2461). A low
   `CmaFree` is therefore not exhaustion. "Nearly full" and "16 MiB is not enough" are now
   **UNVERIFIED** (§6.5, §9.4, open question 4).
8. **TI does not ship SGX on its 6.18 BSP.** In meta-ti master `ti-bsp.inc`, `bsp-ti-6_18` is
   Rogue-only, and SGX (`ti-sgx-ddk-km` 1.17) appears only for `bsp-ti-6_12` and `bsp-ti-6_6`. The `,sgx`
   gallium append is in the new 25.2.8 recipe, not in 24.0.1 (§5.5).
9. **OMAP DTS since 2025-06** saw far more than `embt2ws`: `omap4-l4.dtsi` edits, the Galaxy Tab 2
   boards and `twl6032.dtsi`. None of it is GPU-related. Fixed in §8.
10. **Highmem size:** 229376 KiB is 224 MiB, not 229 MiB.
11. **`69050f8d6d07`** is the treewide *conversion* to `kmalloc_obj`, not its introduction. The v7.0
    boundary itself holds.
12. **Minor fixes:** the drm/imagination Kconfig log has 3 more initial-series commits; gldrk's 1.17-v3
    series starts on 2026-06-23 and is Poulsbo/Cedarview-led; `PVR_QUIRK_OMAP4` is only stored and printed
    in `pvr-drv.c`; the OMAP4 compatible entry depends on the `ti_omap4_sgx540_120` build macro; and the
    "mux reset default" wording was softened, since the bootloader could have set it.

### Could not reproduce or still unverified
- lore.kernel.org and the Mesa GitLab MR search were still not queried directly, so the absence of
  2025-2026 upstream SGX work stays "likely".
- git.ti.com refused the raw `ti-bsp.inc` (HTTP 403). It was read from the GitHub mirror
  `YoeDistro/meta-ti` (pushed 2026-10-10), which is assumed to track meta-ti master.
- The renamed `mesa-pvr-24.inc` (where the 24.0.1 `sgx` gallium driver presumably lives) was not opened.
- All device-side open points remain unverified, because no device was touched: GFX genpd state, the
  `56000000.gpu` device, the OCP REVISION and CORE_REVISION reads, the VDD_CORE readback and the pinned
  CMA usage.
