# SGX540 performance, sleep and clock on the flashed image, 2026-10-13

Prague unit, freshly flashed (2026-10-12 23:10): kernel 6.18.48-r27, device
r128, nexusq-sgx r0, nexusq-sgx-mesa r0 (Maemo mesa-sgx 24.0.9 + our B1/B2),
DDK 1.17.4948957, rootfs slot A. HDMI 1280x720@60, the desktop (LXQt on labwc)
on the GPU. Measured over WiFi with nothing playing. This is the baseline
`scripts/diag/nq-gpu-bench` compares against.

## Throughput: glmark2-es2-wayland, fullscreen 1280x720

The client was given mesa-sgx through `sgx-env`, as labwc gets it. EGL config
RGBA8888, depth 24, stencil 8: glmark2's default asks for depth 32, and the
SGX540 offers neither that nor 8888 without depth/stencil nor 565.

| | SGX540 (mesa-sgx) | llvmpipe (system Mesa) |
|---|---|---|
| **glmark2 Score** | **81** | 5 |
| build use-vbo=true | 140 FPS | 12 |
| texture linear / mipmap | 153 / 141 | 9 / 6 |
| shading phong | 89 | 6 |
| bump high-poly | 63 | 4 |
| desktop shadow, 4 windows | 52 | 2 |
| desktop blur r=5 | 14 | 1 |
| effect2d 5x5 kernel | 13 | 3 |
| jellyfish | 34 | 2 |
| refract | 6 | 1 |
| terrain | did not finish (below) | 0.05 |

- **terrain** aborted with `PVR:(Error): SGXKickTA: TA went out of Mem and SPM
  occurred during last TA kick`: the scene overflowed the parameter buffer.
  The driver recovered and the next scenes ran normally; no kernel error.
  **Fixed the next evening (nexusq-sgx r1):** the DDK reads application hints
  from `/etc/powervr.ini` (`libsrv_um`'s `PVRSRVGetAppHint`; `libpvr_dri_support`
  knows `ParamBufferSize`/`MaxParamBufferSize`). With `[default]
  ParamBufferSize=8388608` terrain renders without an overflow (2 FPS: it is
  a heavy scene, 0.05 FPS on llvmpipe), 16 MiB behaves the same, and the full
  run scores **83** (die peak 81 °C). That is the baseline from then on.
- Two benchmark runs the same evening scored 5 because the client never got
  mesa-sgx: `sgx-env` scopes the GPU environment to the process it execs and
  `timeout` stood in between. `nq-gpu-bench` therefore fails any run whose
  `GL_RENDERER` is not the SGX540.

**The GPU is the bottleneck, not the CPU.** Five scenes with the CPU governor
`conservative` and with `performance` scored 72 and 72 (build 86/85, buffer
48/48, shadow 52/52, jellyfish 34/35). During the full run the CPU sat at
350 MHz 74 % of the time.

Real clients: mpv `--vo=gpu` played 720p30 with 0 dropped frames out of 900 at
350 MHz (2026-10-12); the desktop composites with damage tracking and the GPU
is awake only while something changes.

## Clock

`clk_summary`: `l3-gfx-clkctrl:0000:24` under `dpll_per_m7x2_ck` at
**307 200 000 Hz**: stock's OPP100 GPU clock (patch 0062), fixed. There is no
GPU DVFS: stock switched 153.6 / 307.2 / 384 MHz and scaled VDD_CORE with it
(`power-clocks-pm.md` TL;DR 3-4); our kernel has no VDD_CORE regulator, no GPU
OPP table and no devfreq.

## Sleep

After the benchmark, 30 s with the desktop shown and nothing changing:

- GPU target module `runtime_status=suspended`, `runtime_active_time` +0 ms;
- genpd `prm_gfx` = `off-0`; `gfx_pwrdm` OFF:11 / ON:10 (it powers up and
  down per use);
- cpu0 spent 15.5 s of the 30 s in C3 with the desktop up;
- the SGX interrupt (WUGEN 21, "SGX ISR") counts only while rendering.

So the GFX domain is off whenever nothing renders, as stock's APM did. The
openpvrsgx probe reference feared in `power-clocks-pm.md` TL;DR 8.4 does not
keep the domain on.

## Thermal

One on-die sensor (`thermal_zone0`) for CPU and GPU together. Full glmark2
run: die peak **88.3 °C** (CPU mostly at 350 MHz); idle afterwards 63 °C. The
100 °C passive trip cools only the CPU, never the GPU. A sustained renderer (a
visualizer) needs a frame cap if the die passes ~85 °C (`power-clocks-pm.md`
section 7).

## How to make it faster (tasks for 2026-10-13)

1. **384 MHz like stock (up to +25 %).** It needs VDD_CORE at 1.25 V. First
   measure VDD_CORE at runtime (the 2026-10-11 `--pmic` reading was invalid:
   VCORE1's set-point is not readable from Linux), then give Linux a VDD_CORE
   regulator (TWL6030 VCORE1 through the VC/VP, as stock's
   `omap_device_scale`) and only then raise the clock. Never 384 MHz on the
   1.2 V VC ON value of patch 0027.
2. **GPU frequency scaling (stock's DVFS).** With VDD_CORE controllable: an OPP
   table 153.6 / 307.2 / 384 MHz and devfreq (or the DDK's
   `RequestSGXFreq`-style hook) so the GPU drops to 153.6 MHz at 962 mV when
   idle-ish and rises under load; `devfreq_cooling` on `thermal_zone0` would
   also give the thermal trip a GPU knob. Measure each step with
   `nq-opp-study2.sh GPU=1` and `nq-gpu-bench`.
3. ~~**Parameter buffer.**~~ Done 2026-10-13: `/etc/powervr.ini` from
   nexusq-sgx r1 (8 MiB), score 83, terrain without an overflow.
4. **Clients:** cap animations at 30 fps and keep them at 720p.

## Coverage added the same night (device r129, host tools)

- `nq-diag-snapshot` section `GPU_SGX540`: driver, DRM devices, the target
  module's runtime PM, genpd `prm_gfx`, `gfx_pwrdm` counters, the clock, the
  interrupt, the fetched userspace, the session's renderer, the GPU kernel log.
- `nq-healthd`: `gpu_drv`, `gpu_rpm`, `gpu_active_ms`, `hdmi_on` per sample.
- `nq-health-report`: `gpu` (info), `gpu_never_sleeps`, `gpu_awake_headless`,
  `gpu_clock` (warn).
- `scripts/diag/nq-gpu-bench`: this benchmark against this baseline.
- The nexusq-diag agent and skill check the GPU in every sweep.
