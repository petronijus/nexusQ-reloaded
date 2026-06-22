# Ethernet (LAN9500A) — stock Android bring-up, reverse-engineered

Date: 2026-06-22. Source: `reverse-eng/vmlinux.bin` (stock Android OMAP4 kernel,
decompressed Image, raw ARM, load base `0xC0008000`, ARM not Thumb, HZ=128).
Goal: recover the exact power/clock/reset sequence the stock kernel used to make
the SMSC LAN9500A USB-Ethernet enumerate, because the mainline port gets
`CCS=0` (no `eth0`) despite a powered port and a responding ULPI PHY.

## The two ethernet GPIOs (decisive)

Stock `board-steelhead-usbhost.c` passes a `struct gpio[]` to
`gpio_request_array()` (found at vmlinux file off `0x3c35c`, VA `0xC004435C`):

| label              | gpio    | initial flag     |
|--------------------|---------|------------------|
| `ethernet_nenable` | gpio_1  | `OUT_INIT_HIGH`  |
| `ethernet_nreset`  | gpio_62 | `OUT_INIT_LOW`   |

So at request time: **nenable=HIGH (disabled), nreset=LOW (reset asserted)**.

## Full sequence (disassembled `steelhead_usbhost_init`, VA 0xC00178C4)

1. `omap_mux_init_gpio(1, OUT)` ; `omap_mux_init_gpio(62, OUT)`
2. `omap_mux_init_signal(usbb1_ulpiphy_clk/stp/dir/nxt/dat0..7)` — ULPI PHY pads
3. `gpio_request_array(eth_gpios, 2)` → nenable(gpio_1)=**HIGH**, nreset(gpio_62)=**LOW**
4. `omap_mux_init_signal("fref_clk3_out")` — route the PHY refclk pin
5. `clk_get("auxclk3_ck")` → `clk_set_rate(auxclk3, 38_400_000)` → `clk_enable(auxclk3)`
   — **PHY 38.4 MHz reference clock running** (value `0x0249F000` confirmed in code)
6. `udelay(100)`
7. `gpio_set_value(gpio_1, 0)` → **ethernet_nenable LOW = power/enable ON**
8. `udelay(2)`
9. `gpio_set_value(gpio_62, 1)` → **ethernet_nreset HIGH = release reset**
10. store auxclk3 into pdata; register EHCI; `printk("usb:ehci initialized")`

### Invariant the stock order guarantees
**clock running → enable asserted → (settle) → reset released → EHCI started.**
The LAN9500A only leaves reset *after* VBUS/enable is on AND the 38.4 MHz PHY
clock is stable. Final pin levels: gpio_1=LOW (enabled), gpio_62=HIGH (out of
reset).

## Where mainline differs (root-cause hypothesis)

Final levels match mainline, but the **sequence/ordering does not**:

- `hsusb1_power` is `regulator-always-on` + `regulator-boot-on`, so gpio_1 is
  held LOW from the very start — power is applied **before** auxclk3 is enabled,
  and there is no clean HIGH→LOW enable edge.
- gpio_62 is modelled as the **usb-nop-xceiv PHY reset**, deasserted at PHY
  `init` time. Its release ordering relative to (a) the auxclk3 enable and
  (b) the gpio_1 enable edge is governed by driver probe order, **not** the
  strict stock order. The LAN9500A nRESET can be released before the PHY clock
  is stable, so the chip never initialises and never asserts connect → `CCS=0`.

### Proposed fix direction
Enforce the stock order for the LAN9500A, not relying on regulator/phy probe
ordering: in the steelhead ehci-omap bring-up (the patch-0006 path), with
auxclk3 enabled, drive nenable LOW, `udelay(100)`, then nreset HIGH with
`udelay(2)` **before** the port is brought up — i.e. give the LAN9500A a clean
power-on-reset with the clock already running. Equivalent DT modelling: a
`reset-gpios` on the ethernet device with proper assert/deassert + a power
sequence, instead of always-on regulator + PHY-reset.

### Live test to confirm before coding
On the running mainline kernel (clock already 38.4 MHz, VBUS on), re-pulse the
sequence on gpio_1/gpio_62 (via the driver or devmem on GPIO1 bit1 / GPIO2
bit30) and watch `PORTSC` CCS / `eth0`. If a correctly-ordered re-pulse brings
the LAN9500A up, the ordering hypothesis is confirmed.

## Other confirmed facts
- PHY refclk path is independent of the audio `dpll_per_m3x2` clock — auxclk3 is
  38.4 MHz on the running kernel, unaffected by the TAS5713 clock fix.
- Stock `init.steelhead.rc` runs `dhcpcd_eth0` → ethernet worked on stock.
- ULPI PHY identity on mainline matches a healthy USB3320: VID 0x0424/PID 0x0007.
