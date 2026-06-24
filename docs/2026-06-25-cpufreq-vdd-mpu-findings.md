# CPU frequency scaling (cpufreq / DVFS) on the Nexus Q — findings

**2026-06-25.** The OMAP4460 MPU is stuck at **350 MHz (OPP50)** with no cpufreq —
the system feels slow and ssh / USB-ethernet throughput is CPU-bound (not a link
problem: at 350 MHz ssh RX ≈ 8.4 MB/s; the 100 Mbps link itself is healthy). This
documents everything found while scoping how to scale up safely. Voltage scaling
of VDD_MPU is the one place a wrong value can crash or stress the hardware, so the
emphasis is on ground truth.

## Confirmed ground truth (measured live on stock + decoded from vmlinux)

- **This exact unit IS 1.2 GHz-capable.** Booted the stock kernel (RAM, via
  `output/stock-adb-boot.img`) and read its cpufreq:
  `scaling_available_frequencies = 350000 700000 920000 1200000`,
  `cpuinfo_max_freq = 1200000`. Forcing the `performance` governor put
  `scaling_cur_freq = 1200000` — stock ran the CPU at **1.2 GHz** right then. So
  the OPP-Nitro eFuse bit is set on this silicon.
- **VDD_MPU voltage table — measured live** via `/sys/kernel/debug/voltage/vdd_mpu`
  (`curr_nominal_volt`) stepping each OPP with the userspace governor:

  | MPU freq | VDD_MPU nominal | note |
  |---|---|---|
  | 350 MHz (OPP50) | **1025000 µV** | boot OPP |
  | 700 MHz (OPP100) | **1203000 µV** | |
  | 920 MHz (OPP-Turbo) | **1317000 µV** | |
  | 1200 MHz (OPP-Nitro) | **1380000 µV** | runtime-enabled on capable silicon |

  These match the stock OPP table the auditor decoded from `vmlinux.bin`
  (`virt_dpll_mpu_ck` table @ `0xc0043d5c`, selected by `omap_init_opp_table`
  @ `0xc0012a9c` for `id>>20 == 0x446` = OMAP4460). mainline `omap4460.dtsi`
  `operating-points` are 3–4 mV LOW at the top (1200000/1313000 vs stock
  1203000/1317000) — **use the stock values** since SmartReflex is off (see below).
- At 1.2 GHz stock's SmartReflex (AVS, class-1.5) trimmed VDD_MPU DOWN from the
  1380000 nominal to `curr_vp_volt = curr_calibrated_volt = 1230000`. So SR saves
  power but the **nominal voltages above are the safe open-loop set-points** — they
  are what to use when SR is off.

## VDD_MPU regulator architecture (the crux)

- **VDD_MPU is supplied by an external TI TPS62361** (not the TWL6030). Stock decode
  (`omap4_twl_tps62361_enable` @ `0xc0011f80`, `tps6236x_*` symbols): the TPS62361
  is on the **SmartReflex / VC-VP I²C path** (a dedicated hardware voltage-control
  bus driven by the OMAP4 Voltage Controller), **not** a normal `/dev/i2c-N` bus.
  That is why a live `i2cget` of 0x60 on every normal bus returns "Read failed" on
  our mainline kernel (the TWL6030 ACKs fine on i2c-0, so i2c itself works).
- Stock's bring-up does a **retasking** (`omap4_twl_tps62361_enable`): at boot the
  TWL6030 **VCORE1 SMPS feeds VDD_MPU**; stock then pulls VCORE1 down (it goes to
  VDD_CORE/MM) and hands VDD_MPU to the TPS62361 for DVFS. **On our mainline kernel
  none of that happens** → the TPS62361 stays **dormant** and **VCORE1 (TWL6030) is
  what feeds VDD_MPU** (at the 350 MHz boot OPP, ~1025 mV).
- PandaBoard-ES (same OMAP4460) drives the TPS62361 `VSEL0` via an OMAP GPIO
  (`GPIO_WK7`); **our Nexus Q straps VSEL0/VSEL1** instead (the stock init passes
  both VSEL gpios as `-1` → strapped, voltage set purely over the SR i2c). The
  exact strap state is still **UNKNOWN** — not decodable from `vmlinux` alone, and
  not readable live (the TPS is dormant on mainline and on the SR bus on stock).

## mainline 6.12 support state

- **No mainline OMAP4 DT uses `tps62361`** (grep of `arch/arm/boot/dts/ti/` = none;
  no `cpu-supply` on any omap4 board). So there is **no ready-made TPS62361 omap4
  cpufreq** to copy — it would be custom work.
- mainline *does* have the OMAP4 VC/VP voltage plumbing (`mach-omap2/vc.c`,
  `vc44xx_data.c`, `voltage.c`, `smartreflex-class3.c`, `sr_device.c`) — but the
  PMIC descriptions that bound the TWL6030+TPS62361 to it were removed when omap4
  went DT-only; only `pmic-cpcap.c` (Motorola) carries an `i2c_slave_addr = 0x60`.
- Our config: `CONFIG_POWER_AVS_OMAP` not set, `CONFIG_ARM_OMAP2PLUS_CPUFREQ` not
  set (legacy omap cpufreq/AVS not built). `CONFIG_CPUFREQ_DT=m`,
  `CONFIG_CPUFREQ_DT_PLATDEV=m`, `CONFIG_REGULATOR_TPS62360=m` (all **modules, not
  loaded** → no cpufreq device is created → stuck at the boot OPP). `ARM_TI_CPUFREQ=y`
  but its match table has no omap4 entry → a no-op here (plain cpufreq-dt drives
  omap4; `cpufreq-dt-platdev.c:92` allowlists `ti,omap4`).
- The mainline `tps62360` regulator driver supports `ti,tps62361` (base 500000 µV,
  128 × 10 mV → **range 500000–1770000 µV**; the "two ranges" the auditor saw are
  the TPS62360 vs TPS62361 chip variants, not straps). It reads
  `ti,vsel0-state-high` / `ti,vsel1-state-high` to pick which of the 4 SET registers
  is active — but it expects the TPS on a **normal i2c bus**, which on OMAP4460 it
  is not.

## The two realistic paths

**A. VCORE1 (TWL6030) → ~700 MHz (maybe 920 MHz). Pragmatic, lower risk.**
- VCORE1 already feeds VDD_MPU on mainline. Wire the **TWL6030 VCORE1 SMPS as a
  real regulator** (it is currently a dummy — only `abb_mpu` is registered; see
  the dummy-regulator task) and set `&cpu0 { cpu-supply = <&vcore1>; }`.
- `CONFIGFREQ_DT` + `CPUFREQ_DT_PLATDEV` = `y`; OPP table capped at OPP100 (700 MHz
  @ 1203000) using the measured stock voltages; optionally try OPP-Turbo (920 MHz).
- cpufreq-dt sets the voltage over the **normal TWL6030 control i2c** (no VC/VP/SR
  complexity). VCORE1 can supply ~OPP-Turbo current (the OMAP4430 reached ~1 GHz on
  it); 700 MHz is safely within range, 920 MHz probably but less certain.
- Achievable, ~2–2.6× speed-up. Entangled with fixing the dummy regulators.

**B. TPS62361 → 1.2 GHz. Stock-faithful, big effort, higher risk.**
- The silicon is proven 1.2 GHz-capable and the voltage table is known, BUT mainline
  has **nothing** for the OMAP4460 TPS62361 path: it needs the VC/VP + SR-I2C +
  the `omap4_twl_tps62361_enable` retasking re-implemented, plus the unknown VSEL
  strap resolved (board schematic or a live SR-i2c read). Multi-session custom
  kernel work with real HW risk if the voltage/strap is wrong.

## TODO before either build

- Decide scope (A vs B) — A recommended for v1.4; B is a de-risked future stretch.
- For A: enable the TWL6030 VCORE1 regulator in the DT, add `cpu-supply`, flip the
  three configs to `=y`, add the capped OPP table with the **measured stock
  voltages**, build, fastboot, verify `scaling_cur_freq` climbs + the system stays
  stable + thermals OK (`CPU_THERMAL`/`TI_THERMAL` are already `=y`).
- For B: resolve the VSEL strap first (schematic or an SR-i2c read on stock), then
  re-implement the TPS62361 + VC path; do not guess the voltage.

## Evidence / files
- Live stock: `/sys/devices/system/cpu/cpu0/cpufreq/*`, `/sys/kernel/debug/voltage/vdd_mpu/*`.
- `reverse-eng/vmlinux.bin`: OPP table `0xc0043d5c`, `omap_init_opp_table`
  `0xc0012a9c`, `omap4_twl_tps62361_enable` `0xc0011f80`, `tps6236x_*` syms.
- `build/linux-6.12.12/drivers/regulator/tps62360-regulator.c` (`ti,tps62361`,
  base 500000, vsel-state straps), `drivers/cpufreq/cpufreq-dt-platdev.c:92`
  (`ti,omap4`), `arch/arm/mach-omap2/vc*.c` + `voltage.c` (VC/VP plumbing),
  `arch/arm/boot/dts/ti/omap/omap4460.dtsi` (operating-points, 3–4 mV low).
- `kernel/configs/steelhead_defconfig` (CPUFREQ_DT=m etc.).
- Web: PandaBoard-ES ref manual (TPS62361 @ U25, VSEL0 via GPIO_WK7);
  LKML 2013 OMAP4460/TPS/PandaBoardES VP-regulator-for-cpufreq + VC/VP-in-dts RFCs.
