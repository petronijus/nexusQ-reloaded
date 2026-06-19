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
  TWL6040/`omap-abe-twl6040` card?). Since that card is disabled (dead codec),
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
