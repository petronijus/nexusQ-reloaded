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

## Suggested order of work

1. **ABE/`dpll_per_m3x2` 61.44 MHz** — gate it before the TAS5713 listening test
   (PLAN §1); it may be the difference between a clean MCLK and none.
2. **Identify the three `ti-sysc` modules** — disable unused ones in the DTS;
   one may be the same audio-clock root cause.
3. **CLM blob** — confirm whether one exists for this FWID; if not, document as
   expected.
4. The LOW items only if chasing a pristine dmesg.
