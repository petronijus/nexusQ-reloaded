# Boot Warnings — Follow-up Bugfix Candidates

**Captured:** 2026-06-19, fresh boot of `6.12.12 #3` on the device (after the
LED-ring driver work). These dmesg warnings/errors are **unrelated to the
`leds-steelhead-avr` driver** (which probes cleanly: `fw=0x00 hw=0x01 leds=32,
HOST mode`, no errors). Listed worst-first. Nothing here blocks the system —
boot is clean, no failed services, no pstore crash, no kernel oops.

---

## HIGH — ABE / `dpll_per_m3x2` audio clock fails to set (affects TAS5713)

```
[63.685577] clk: couldn't set dpll_per_m3x2_ck clk rate to 61440000 (-22), current rate: 256000000
[64.083404] clk: failed to reparent abe-clkctrl:0030:24 to abe_24m_fclk: -22
```

**Why it matters:** This is the **audio MCLK path for the TAS5713 amplifier**
— the project's top-priority feature. `PLAN.md` §1 specifies the amp MCLK as
12.288 MHz derived from `dpll_per_m3x2x2 = 61.44 MHz → auxclk1 /5 →
fref_clk1_out`. The clock framework is refusing to set `dpll_per_m3x2_ck` to
**61.44 MHz** (stuck at 256 MHz) and the ABE clkctrl reparent to
`abe_24m_fclk` fails with `-EINVAL (-22)`. The `speaker-test` "ran clean (rc=0)"
result in PLAN §1 may therefore have produced **no correct MCLK** — worth
re-checking before the physical listening test.

**Investigate / fix:**
- Verify the DTS `assigned-clocks`/`assigned-clock-rates`/`assigned-clock-parents`
  for `dpll_per_m3x2_ck`, `auxclk1`, and the McBSP2/`fref_clk1_out` path against
  the OMAP4 clock tree — the requested 61.44 MHz may be unreachable from the
  current DPLL_PER M-divider settings, or a parent (`dpll_per`) is at the wrong
  rate so the `/x2` can't reach 61.44 MHz.
- Check whether `abe-clkctrl:0030:24` (an ABE leaf) is being asked to reparent
  to `abe_24m_fclk` by a node that shouldn't (leftover from the disabled
  TWL6040/`omap-abe-twl6040` card?). Since that card is disabled (dead codec
  — _2026-07-03 correction: the TWL6040 is in fact unused/unpopulated on
  steelhead, not dead; nodes removed entirely in batch 2_),
  a stale ABE clock consumer may be the source of the `-22`.
- Confirm with `cat /sys/kernel/debug/clk/clk_summary | grep -E 'dpll_per|abe|auxclk1|fref_clk1'` what the actual tree/rates are at runtime.

---

## MEDIUM — three `ti-sysc` target-modules fail to probe

```
[1.088500] ti-sysc 4a318000.target-module: probe with driver ti-sysc failed with error -16   (-EBUSY)
[5.203460] ti-sysc 48091fe0.target-module: clock get error for fck: -2                          (-ENOENT)
[5.210662] ti-sysc 48091fe0.target-module: probe with driver ti-sysc failed with error -2
[5.244934] ti-sysc 480b2000.target-module: OCP softreset timed out                              (x2)
```

**Why it matters:** Three OMAP interconnect target-modules don't come up. Likely
unused/!powered IP blocks, but each failed probe can wedge a power domain or
hide a DTS clock mistake. `-EBUSY` (4a318000) often means a resource/region is
already claimed; `fck: -ENOENT` (48091fe0) means a referenced functional clock
is missing from the DTS; the `480b2000` softreset timeout means that module
isn't clocked/powered when reset is attempted.

**Investigate / fix:**
- Identify each: `cat /sys/bus/platform/devices/<addr>.target-module/of_node/...`
  or cross-reference `arch/arm/boot/dts/ti/omap/omap4*.dtsi` for the
  `target-module@...` at `0x4a318000`, `0x48091fe0`, `0x480b2000`.
  (Candidates by typical OMAP4 map: `0x4a31xxxx` = a control/efuse or GPIO in
  the wkup/core domain; `0x48091xxx` = an McBSP/McASP/abe peripheral;
  `0x480b2xxx` = HDQ/1-wire or a McSPI — confirm before acting.)
- If genuinely unused on the Nexus Q, set those nodes `status = "disabled"` in
  `kernel/dts/omap4-steelhead.dts` to silence the probe churn and avoid leaving
  a power domain half-initialized.
- If `0x48091fe0` is audio-related (McBSP/ABE), its missing `fck` may be the
  *same* root cause as the HIGH item above — fix together.

---

## MEDIUM — WiFi: missing CLM/TXCAP regulatory blobs

```
[76.913391] brcmfmac mmc4:0001:1: Direct firmware load for brcm/brcmfmac4330-sdio.clm_blob failed with error -2
[77.221435] brcmfmac: no clm_blob available (err=-2), device may have limited channels available
[77.245727] brcmfmac: no txcap_blob available (err=-2)
```
(Also seen during the session: repeated `brcmf_fweh_event_worker: event handler failed (72)`.)

**Why it matters:** WiFi works, but without the CLM (regulatory/channel) blob
the radio "may have limited channels available" and TX power caps are not
applied. For a device that is primarily WiFi-connected, correct regulatory data
is worth having.

**Investigate / fix:**
- The BCM4330 CLM blob is often baked into the firmware for this chip (the
  recovered `brcmfmac4330-sdio.bin` may already contain it — hence WiFi works);
  if a separate `brcmfmac4330-sdio.clm_blob` is not available for this exact
  FWID (`01-cafa6b3e`, ver 5.90.195.114), the `-2` is benign and can be left.
  Document it as expected rather than chasing a non-existent blob.
- The recurring `fweh event handler failed (72)` is a known brcmfmac event-queue
  noise on older chips; usually harmless. Worth confirming it doesn't correlate
  with disconnects.

---

## LOW — cosmetic / environmental (likely leave as-is)

| Warning | Note |
|---|---|
| `[0.000000] WARNING ... arm_dt_init_cpu_maps+0xcc` (devtree.c:129) | DT lists 2 CPUs but `CONFIG_SMP=n`/CPU1 parked → cpu-map warning. Benign on single-core; silence by trimming the second `cpu@1` node from the DTS if desired. |
| `[0.271423] hw-breakpoint: Failed to enable monitor mode on CPU 0` | HW debug/watchpoints unavailable; benign. |
| `brcmf_p2p_create_p2pdev: timeout` / `add iface p2p-dev-wlan0 ... err=-5` | Wi-Fi P2P device creation fails (BCM4330 quirk). P2P unused; can disable via a `modprobe.d` option or NM config to remove the noise. |
| `HDMICORE: timeout reading edid` (repeats every ~6 s) | The attached panel provides no EDID; environmental. Repeats are a poll loop — harmless but noisy; goes away with a real EDID-providing TV. |
| `display-connector connector0: No GPIO consumer ddc-en found` | DTS `connector0` has no `ddc-en-gpios`; benign (no DDC enable line on this board). |
| `ti-sysc ... OCP softreset timed out` (480b2000) | See MEDIUM ti-sysc item. |

---

---

## INVESTIGATION RESULTS (2026-06-19, branch `fix/boot-warnings`)

### HIGH — ABE / `dpll_per_m3x2` audio clock — TWO independent faults

**Fault A — the `-22` reparent (FIXED in DTS):**
The `&mcbsp2` node had:
```
assigned-clocks        = <&abe_clkctrl OMAP4_MCBSP2_CLKCTRL 24>;
assigned-clock-parents = <&abe_24m_fclk>;
```
`abe-clkctrl:0030:24` is the McBSP2 *functional* gfclk. Per
`drivers/clk/ti/clk-44xx.c` (`omap4_func_mcbsp2_gfclk_parents[]`) its **only**
legal parents are `abe-clkctrl:0030:26` (its sync mux), `pad_clks_ck`, and
`slimbus_clk`. `abe_24m_fclk` is **not** in that list → `clk_set_parent`
returns `-EINVAL` → the boot error `failed to reparent abe-clkctrl:0030:24 to
abe_24m_fclk: -22`. `abe_24m_fclk` *is* a legal parent of **bit 26** (the sync
mux), not bit 24. At runtime the gfclk already resolves to 24.576 MHz via the
bit-26 default, so the McBSP2 SRG was actually fine — the warning was pure
noise from an impossible reparent.
**Fix:** reparent **bit 26 → `abe_24m_fclk`** and **bit 24 → bit 26** explicitly:
```
assigned-clocks        = <&abe_clkctrl OMAP4_MCBSP2_CLKCTRL 26>,
                         <&abe_clkctrl OMAP4_MCBSP2_CLKCTRL 24>;
assigned-clock-parents = <&abe_24m_fclk>,
                         <&abe_clkctrl OMAP4_MCBSP2_CLKCTRL 26>;
```
Confirmed in the decompiled DTB (`<… 0x30 0x1a>` = bit 26, `<… 0x30 0x18>` =
bit 24; parents `abe_24m_fclk`, then bit 26). **Needs flash-test** only to
confirm the warning is gone; the clock tree is unchanged from the working
default, so this is low-risk.

**Fault B — `dpll_per_m3x2_ck` cannot be set to 61.44 MHz (UNRESOLVED, needs flash-test):**
Live `clk_summary` (read 2026-06-19, no reboot):
```
dpll_per_ck        768 MHz
 dpll_per_x2_ck   1536 MHz
  dpll_per_m3x2_ck 256 MHz  (N)   <- stuck, consumed ONLY by auxclk1_src_ck
   auxclk1_src_ck  256 MHz  (N)
    auxclk1_ck      16 MHz  (Y)   <- tas5713@1b mclk; WANT 12.288 MHz
```
The math is reachable: `1536 / 25 = 61.44 MHz` (divider max-div 31, so div 25
is valid) and `61.44 / 5 = 12.288 MHz`. `dpll_per_m3x2_ck` is consumed by
nothing except this audio path, so changing it is safe (no shared-consumer
conflict). The error fires at ~63 s, i.e. when `tas5713`'s `assigned-clocks`
are applied (`drivers/clk/clk-conf.c`), not at provider init.

Deep code trace of *why* `clk_set_rate(dpll_per_m3x2_ck, 61440000)` returns
`-EINVAL`: `dpll_per_m3x2_ck` is a `ti,composite-clock` (gate + divider, **no
mux**). `clk_register_composite()` therefore wires `clk_composite_round_rate`
(NOT `clk_composite_determine_rate`) as its rate op, and the underlying
`ti_clk_divider` provides a working `round_rate`/`set_rate` for div=25. By
static analysis the set *should* succeed (parent 1536 MHz, no
`CLK_SET_RATE_PARENT`, no min/max constraint: live `clk_min_rate=0`,
`clk_max_rate=4294967295`). The device nevertheless reports `-22`. The
contradiction could not be resolved read-only (no reboot allowed; the device
is shared with the LED workstream). **Left the correct 61.44/12.288 assignment
in place** (changing the *value* would be wrong — those rates are exact and
derive cleanly). After the reparent fix + the RNG/HDQ disables (which change
probe ordering and remove a competing clkctrl consumer), a **flash-test** must
re-check whether `dpll_per_m3x2_ck` reaches 61.44 MHz and `auxclk1_ck` reaches
12.288 MHz. **Fallback if `-22` persists:** small kernel patch to
`drivers/clk/clk-composite.c` `clk_composite_determine_rate()` to add a
`round_rate` fallback in the no-mux branch (currently only handles
`determine_rate` there), since OMAP4 composite `dpll_per_m*x2` clocks expose
only `round_rate`. No mainline OMAP4 board sets a `dpll_per_m3x2` rate via
`assigned-clocks`, so this path is genuinely under-exercised upstream.

### MEDIUM — three `ti-sysc` target-modules — IDENTIFIED

| Addr | What it is | Cause | Action |
|---|---|---|---|
| `0x4a318000` | **GPTIMER1** (`timer1_target`, `ti,timer-alwon`) — the always-on system clockevent ("TI gptimer clockevent: always-on 32768 Hz"). | The OMAP timer core claims the timer region directly, so `ti-sysc` sees it busy → `-EBUSY (-16)`. **Expected on every OMAP4 board.** | **Left as-is.** Disabling it would break timekeeping. Documented in DTS. |
| `0x48091fe0` | **Hardware RNG** (`rng_target`, `ti,omap4-rng`), in the `l4_secure` clock domain. | `OMAP4_RNG_CLKCTRL` fck lives behind the secure-side clkctrl, not exposed on this U-Boot/GP flow → `clock get error for fck: -2` (`-ENOENT`). Nexus Q does not use the on-chip hwrng. | **`status = "disabled"`** in DTS. |
| `0x480b2000` | **HDQ / 1-wire** master (`ti,omap3-1w`). | No HDQ/1-wire device wired on the Nexus Q; module left unclocked → `OCP softreset timed out`. | **`status = "disabled"`** in DTS (referenced by full path — node has no upstream label). |

All three verified against `arch/arm/boot/dts/ti/omap/omap4-l4.dtsi`. RNG/HDQ
disables confirmed in the decompiled DTB; timer1 confirmed untouched. **Needs
flash-test** to confirm the two `ti-sysc` failures are gone (DTB-only change,
low-risk).

### MEDIUM — WiFi CLM/TXCAP blob — CONFIRMED BENIGN
The BCM4330 (`brcmfmac4330-sdio`, FWID `01-cafa6b3e`, ver 5.90.195.114) has its
regulatory data baked into the firmware blob — WiFi associates and passes
traffic without a separate `.clm_blob`. No upstream `brcmfmac4330-sdio.clm_blob`
exists for this FWID, so the `-2` is expected, not a fault. Leave as-is; the
recurring `fweh event handler failed (72)` is known BCM4330 event-queue noise
and did not correlate with disconnects in the captured session.

### Build verification (no device reboot)
- DTB compiles clean (no dtc warnings) from the edited DTS.
- Regenerated `kernel/patches/0003-ARM-dts-omap4-add-steelhead.patch` (now 682
  DTS lines); all five patches `0001`–`0005` apply cleanly to a fresh
  `linux-6.12.12` tree and the patched tree compiles `omap4-steelhead.dtb`.
- `build-clean-modules.sh` therefore stays consistent.

### What still needs a flash + boot test (controller to coordinate)
1. Confirm `failed to reparent abe-clkctrl:0030:24` is gone.
2. Confirm `dpll_per_m3x2_ck` reaches 61.44 MHz and `auxclk1_ck` 12.288 MHz
   (re-read `clk_summary`); if `-22` persists, apply the documented
   `clk-composite.c` fallback patch.
3. Confirm the `48091fe0` (RNG) and `480b2000` (HDQ) `ti-sysc` errors are gone
   and nothing else regressed (timer1 `-EBUSY` is expected to remain).

---

## Suggested order of work

1. **ABE/`dpll_per_m3x2` 61.44 MHz** — gate it before the TAS5713 listening test
   (PLAN §1); it may be the difference between a clean MCLK and none.
2. **Identify the three `ti-sysc` modules** — disable unused ones in the DTS;
   one may be the same audio-clock root cause.
3. **CLM blob** — confirm whether one exists for this FWID; if not, document as
   expected.
4. The LOW items only if chasing a pristine dmesg.

---

---

## FLASH-TEST RESULTS — kernel `6.12.12 #2-postmarketOS` (2026-06-20)

Built clean from `main` (commit `1c0a9d2`, with the fix) via `docker-build.sh`;
`pkgrel` bumped `0→1` as an on-device verification marker (`uname` now shows
`#2`). Kernel-only boot.img (6.34 MB: vmlinuz+appended DTB, no external ramdisk,
matching the working p9 format) `dd`-flashed to `/dev/mmcblk0p9`. Booted OK,
modules load clean (taint=512 = the cpu-map WARN only, no module taint).

| Boot-warnings item | Before (#1) | After (#2) | Status |
|---|---|---|---|
| McBSP2 `reparent abe-clkctrl:0030:24 … -22` | present | **gone** | ✅ FIXED |
| `ti-sysc 48091fe0` (RNG) `-2` | present | **gone** | ✅ FIXED |
| `ti-sysc 480b2000` (HDQ) softreset | present | **gone** | ✅ FIXED |
| `ti-sysc 4a318000` (GPTIMER1) `-16` | present | present | ⏳ see B1 below |
| `dpll_per_m3x2_ck … 61440000 (-22)` (Fault B) | present | present | ❌ OPEN (B7) |

`leds-steelhead-avr` still probes clean (`fw=0x00 hw=0x01 leds=32, HOST mode`).

---

## FULL BOOT-ERROR INVENTORY (2026-06-20) — *every* dmesg item is ours to fix

Policy: nothing is "benign/environmental/expected". Each line below is a defect
with a root cause and a planned fix. `#2` boot, captured over the USB gadget net.

| ID | dmesg / unit | Root cause | Planned fix | Where |
|----|--------------|-----------|-------------|-------|
| **B1** | `ti-sysc 4a318000.target-module: probe … -16` | GPTIMER1 always-on clockevent; the OMAP timer core claims the region, so ti-sysc sees `-EBUSY`. | Stop ti-sysc from binding the timer region (mark the target-module so it isn't double-probed, mirroring how mainline omap4 keeps the clockevent out of ti-sysc), without disabling the timer. | DTS |
| **B2** | `WARNING … arm_dt_init_cpu_maps devtree.c:129: DT /cpu 2 nodes greater than max cores 1, capping them` | DTS declares `cpu@0`+`cpu@1` but the kernel is single-core (`SMP=n`/`NR_CPUS=1`). | Single-core reality: remove `cpu@1` from the DTS (re-add it together with the SMP bring-up — see the 2nd-core research doc). Silences the WARN and clears taint=512. | DTS |
| **B3** | `omap4_sram_init: Unable to get sram pool needed to handle errata I688` | `sram@40304000` exists but exposes no `pool`/`barrier` child region, so the I688 barrier workaround can't allocate SRAM. | Add the mmio-sram `barrier` reserved region (per mainline `omap4.dtsi` `ocmcram`/`sram` + `omap4-cpu-thermal`/errata setup) so `omap4_sram_init` gets its pool. | DTS |
| **B4** | `brcmfmac … brcmfmac4330-sdio.clm_blob failed -2` / `no clm_blob`, `no txcap_blob` | No regulatory CLM/TXCAP blob file for FWID `01-cafa6b3e`. | Source/provide `brcmfmac4330-sdio.clm_blob` for this FWID if it exists; otherwise ship a documented stub + confirm channels/TX caps are correct from the in-firmware defaults. | firmware pkg |
| **B5** | `brcmf_p2p_create_p2pdev: timeout` / `add iface p2p-dev-wlan0 … err=-5` | brcmfmac tries to create a P2P device the BCM4330 firmware doesn't support here. | Disable P2P (`brcmfmac.p2pon=0` is default; set module/feature-disable or NM `p2p-dev` off) so the iface is never created. | module cfg |
| **B6** | `display-connector connector0: No GPIO consumer hpd found` / `ddc-en found`; `HDMICORE: timeout reading edid` (every ~6 s) | DTS `connector0` has no `hpd-gpios`/`ddc-en-gpios` and there is no DDC/EDID path, so omapdss polls EDID forever. | Give the connector a fixed mode / `ddc-i2c-bus` or an embedded EDID so it stops polling (and wire `hpd`/`ddc-en` if the board has them). | DTS |
| **B7** | `clk: couldn't set dpll_per_m3x2_ck … 61440000 (-22)`; `auxclk1_ck`=16 MHz (want 12.288), `dpll_per_m3x2_ck`=256 MHz (want 61.44) | OMAP4 composite `dpll_per_m3x2` exposes only `round_rate`; `clk_composite_determine_rate()` no-mux branch lacks a `round_rate` fallback → `assigned-clock-rates` returns `-EINVAL`. **TAS5713 MCLK is wrong.** | Kernel patch `drivers/clk/clk-composite.c`: add `round_rate` fallback in the no-mux branch. New patch `0006-*`. | kernel patch |
| **B8** | `Alternate GPT is invalid, using primary GPT` | Backup GPT at end of `mmcblk0` is stale/misplaced (rootfs `dd`'d without fixing the secondary header for the 14.7 GB eMMC). | `sgdisk -e` (move backup GPT to true end) + verify. | device-side |
| **B9** | `systemd-vconsole-setup.service` failed: `loadkeys` / `KD_FONT_OP_GET … I/O error` | The omapdrm fbcon VT doesn't implement font/keymap ioctls; there is no real text VT (UI is weston/labwc). | Mask `systemd-vconsole-setup.service` (and `getty` on tty if unused) in the device package. | device pkg |
| **B10** | `hw-breakpoint: Failed to enable monitor mode on CPU 0` | HW debug/watchpoint monitor mode is gated by the secure side on this GP-fused OMAP4460. | Likely a genuine HW/secure limit — confirm it's secure-blocked, then document precisely; suppress only if confirmed unreachable. | (investigate) |

### Userspace (not dmesg, but ours)
- **U1 — nexusqd CPU 44%→3%:** TWO compounding bugs. (a) the main loop free-ran
  because `poll()` woke on the audio pipe; (b) the real driver — `arecord` exits
  immediately (snd-aloop absent, see B11), leaving the pipe at EOF so `poll()`
  returned `POLLHUP` instantly and the loop spun (the 44% old binary was
  render-bound at this spin; a frame-clock-only fix made it *worse*, 91%, by
  spinning faster). **FIXED** in `src/nexusqd.c`: (1) monotonic `next_frame`
  deadline so the heavy render runs at fps, not per wake; (2) on EOF/`POLLHUP`/
  `POLLERR` close `afd`, stop polling the dead pipe, and re-spawn `arecord` every
  `AUDIO_RESPAWN_S`=3 s (audio.h). **Measured on-device: 3% CPU, nonvoluntary
  ctxt/s=0, 75% idle** (was 0% idle / 83% sys). Deployed (binary swap to
  `/usr/bin/nexusqd`).
- **U2 — nexusqd APKBUILD:** invalid `# Maintainer:` (not RFC822) aborted the
  aport build. **FIXED** (line removed, matches the other aports).
- **U3 — apk signing fails in `build-nexusqd-only.sh`:** `abuild` can't read
  `~/.abuild/*.rsa` (`Permission denied`) on a reused work volume, so the **apk**
  can't be produced (we extract the compiled binary from the chroot pkgdir to
  deploy — fine for updating a running device, but a clean apk needs the key perms
  fixed/regenerated). OPEN (build hygiene).

### B11 — snd-aloop missing (audio tap / Spotify loopback never worked)
`CONFIG_SND_ALOOP is not set` in the defconfig → no `snd-aloop.ko`, so
`hw:Loopback,{0,1}` don't exist: librespot can't play to `plughw:Loopback,0` and
nexusqd's `arecord` on `hw:Loopback,1` dies instantly (root cause of U1's spin).
`modules-load.d/snd-aloop.conf` already wants it. **FIX (defconfig, done; needs
kernel batch):** `CONFIG_SND_ALOOP=y` (built-in → exists without a `.ko`, so only
boot.img needs reflashing, not the rootfs).

### Build-process fixes captured (so #N+1 is reproducible)
- Build from `main` *after* the fix is merged (build #1 shipped the pre-fix DTB).
- `pkgrel` bump → `uname` marker to prove the new kernel actually flashed.
- `pmbootstrap build --force` in `docker-build.sh` (defeat stale work-volume cache).
- `distfiles` permission error → use a clean work volume (`docker volume rm`).
- `build-nexusqd-only.sh` for fast userspace iteration: must NOT `chown -R` a
  reused work volume (breaks chroot root-owned files → `/bin/sh: Permission
  denied`); it `zap`s chroots to recreate them clean.

### Fix batching
- **Kernel/DTS batch (one rebuild+flash):** B1, B2, B3, B6, B7 (+ B4/B5 firmware/module).
- **Device-side (over SSH):** B8 (sgdisk), B9 (mask unit), B5 (NM/module cfg).
- **Userspace:** U1 deploy.
- **Investigate:** B10.

---

## STATUS UPDATE 2026-07-02 — re-swept on kernel `6.12.12 #26` (v1.6.5 era)

Full re-inventory (verbatim log lines, new IDs **B12–B21**, **U4–U7**, device-state
observations): **`docs/2026-07-02-boot-error-inventory.md`**. Summary against the
table above:

| ID | Status 2026-07-02 |
|----|-------------------|
| B1 (GPTIMER1 `-EBUSY`) | ✅ RESOLVED (v1.5.0 ti-sysc active-timer silencing) |
| B2 (cpu-map WARN) | ✅ RESOLVED (`cpu@1` restored with SMP, v1.2.0) |
| B3 (SRAM I688 pool) | ✅ RESOLVED (dram barrier maps at boot) |
| B4 (clm/txcap blob) | ❌ OPEN — plus a new miss of the device-specific `brcmfmac4330-sdio.google,steelhead.bin` probe |
| B5 (brcmfmac P2P) | ✅ RESOLVED (P2P disabled, v1.5.0) |
| B6 (EDID timeout) | ✅ RESOLVED (absent this boot; v1.2.0 DDC/mode_valid) |
| B7 (`dpll_per_m3x2` / TAS5713 clocks) | ✅ RESOLVED (patch 0007 + patch 0022, v1.6.1 — audio at 1.000×) |
| B8 (Alternate GPT invalid) | ⛔ BLOCKED — `sgdisk -e` refused: p13 ends at the literal last sector (30777343), the 33-sector backup GPT can't fit; needs a p13 shrink (explicit approval) |
| B9 (vconsole-setup fail) | ✅ RESOLVED (0 failed units this boot) |
| B10 (hw-breakpoint monitor mode) | ❌ OPEN (investigate secure-side gating) |
| B11 (snd-aloop) | ✅ RESOLVED (`CONFIG_SND_ALOOP=m` + modules-load, v1.6.2) |

New in the 2026-07-02 sweep: **B12** twl6030 vsel OUT-OF-RANGE ×4, **B13**
cpuidle driver fails to register, **B14** clkctrl "device ID is greater than 24"
(mpu/pmu/iva fck), **B15** pn544 nfc_en polarity fallback, **B16** ramoops
invalid-buffer error, **B17** bcm4330-pwrseq deferred (external clock), **B18**
`40132000.target-module` deferred, **B19** tas571x PVDD dummy regulators, **B20**
hsusb1-phy exclusive-vbus dummy refusal, **B21** minor batch; userspace **U4**
PulseAudio/PipeWire conflict, **U5** bluetoothd hci0 default config, **U6**
gkr-pam session noise, **U7** nsresourced bpf-lsm.

**Same-day outcome:** B12/B13/B14/B17/B18/B19/B20/U4 were root-caused and
**fixed in tree** (kernel patches 0023–0028 + defconfig + DTS, pkgrel 26/18 —
built, not flashed); B15's chip was proven **dead hardware** (node disabled);
and the sweep's "WiFi currently DEAD" claim under B17 was **wrong** — the DHCP
IP had moved (NM randomized MAC), the link was up the whole time. Full fix map +
corrections: `docs/2026-07-02-boot-error-inventory.md`; stock-parity evidence:
`docs/2026-07-02-stock-parity-voltage-wifi-idle.md`.

## STATUS UPDATE 2026-07-03 — the fix batch is FLASHED and VERIFIED (`#27`)

The 2026-07-02 batch was flashed 2026-07-03 and the acceptance run passed:
**B12/B13/B14/B15/B17/B18/B19/B20 + U4 confirmed GONE** on
`6.12.12 #27-postmarketOS`, and **B8 is FIXED on-device** (p13 shrunk 33
sectors + backup GPT relocated 2026-07-03; the fix survived the reboot — no
"Alternate GPT" line). Still open: B4, B10, B16, B21, U5 (did not reproduce on
`#27` — watching), U6, U7, plus two NEW items **B22** (`twl: not initialized`
×22 burst @0.78 s from the 0013/0014 vdd_mpu init path) and **B23**
(`Skipping twl internal clock init … (unknown osc rate)`, surfaced by
`CLK_TWL=y`). Authoritative per-item table:
`docs/2026-07-02-boot-error-inventory.md` §"FLASH-VERIFIED 2026-07-03".

## STATUS UPDATE 2026-07-03 (later) — batch 2 BUILT (`#28`), awaiting flash

**B22 and B23 are fixed in tree** (kernel patches **0030** — `twl_is_ready()`
gating of the pre-probe vdd_mpu/VC accesses — and **0031** — `clocks_init()`
gated to twl4030 class; the planned twl-fck DTS wiring was investigated and
REJECTED as harmful), plus patch **0029** (readable `frame` bin_attr for the
LED-ring health fingerprint). Kernel pkgrel 27 (next boot = `#28`), device
r20 — **built, not flashed**. Two verdict corrections landed with it: B15's
chip is **NOT concluded dead** anymore (retracted — under investigation) and
the TWL6040 was **never a dead codec** (unused/unpopulated on steelhead).
Authoritative: `docs/2026-07-02-boot-error-inventory.md` §"BATCH 2".
