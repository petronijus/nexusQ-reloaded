# Ethernet cold-init — RESOLVED + gold-validated (2026-07-06)

> **STATUS: RESOLVED & GOLD-VALIDATED — task #17 FULLY CLOSED.** Root cause was
> `gpio_1` NENABLE (the LAN9500A power-enable) sitting on an **unmuxed pad**
> (`kpd_col2` @ CORE padconf `0x186`). Fix = mux that pad in the DTS
> `ethernet_gpios` node (`OMAP4_IOPAD(0x186, PIN_OUTPUT | MUX_MODE3)`), kernel
> **pkgrel 32 / uname `#33`** (commit **e33a1b4**). **GOLD STANDARD PROOF:** a
> clean fastboot flash of `#33` + a **true cold power-cycle** (no stock prime) →
> `eth0` enumerates **100Mbps/Full, 0 failed units**; a clean-flash warm boot #1
> also enumerated. Ships as **v1.6.8**.
>
> **The 2500ms "attach-ready settle" (kernel `#31`, commit 6c869e8, "closes #17")
> was a FALSE POSITIVE, not a fix** — those "5/5" boots all descended from a
> stock RAM boot via warm reboots that never cut LAN9500A power, so the
> stock-initialized chip just stayed attached. A clean flash / true cold boot
> without stock still failed. e33a1b4 corrects that claim: the 2500ms/200ms/50ms
> delays are reverted to stock `udelay(100)`/`udelay(2)` (patch 0006 power
> block), and the non-stock `gpio_159` (0x164) pad mux +
> `steelhead-eth-phy-reset-gpios` property are removed (stock leaves that pad in
> safe_mode; it is not wired to the LAN9500A).
>
> The sections below are the investigation trail that led there, preserved as a
> record. See the finalized "RESOLVED" section at the bottom for the closing
> proof.

## Original header (superseded — kept for the record)
**ROOT CAUSE FOUND & PROVEN LIVE — gpio_1 NENABLE pad was unmuxed.** Fix applied
to DTS (kernel #32, building). Cold-boot validation was pending a power-cycle
when this was written; it has since PASSED (see the banner above and the bottom
section). Commit 6c869e8 "closes #17" (2500ms settle) was premature — the settle
is a red herring, real fix is the pad.

## The corrected picture (Petr's catch, 2026-07-06)
The "5/5 attach-ready-settle fix works" from 2026-07-05 was a **false positive
from stock-priming**: that whole chain descended from a stock RAM boot →
`adb reboot` → dd #31 → warm reboots. Power to the LAN9500A was never cut, so
the stock-initialized chip simply stayed attached across warm reboots. The
2500 ms settle (patch 0006 v3) had nothing to do with it.

**Confirmed by clean tests:** a clean fastboot flash of #31 (no stock first) →
eth0 ABSENT; a true cold boot (power pulled, no stock) → eth0 ABSENT.

**Confirmed hypothesis:** our mainline CANNOT cold-init the LAN9500A. Stock
cold-inits it reliably (stock RAM boot enumerates eth0 from any state). Once
stock brings it up, it survives warm reboots. This is our bug, chip is 100%
alive.

## Live register characterization of the cold-FAILED state (kernel #31)
Device reachable (WiFi .195 / gadget) even with eth down. Tools left on device:
`/root/mmio` (aligned MMIO r/w — NEVER use python mmap, it wedges INSNREG05),
`/root/ulpi_read.sh` (ULPI viewport reads). EHCI base 0x4A064C00.

- PORTSC1 (0x4A064C54) = 0x00001000 → PP=1 (port powered), CCS=0 (no connect)
- CM_L3INIT_USB_HOST_HS_CLKCTRL (0x4A009358) = 0x01000102 → UTMI p1 clock ON,
  sourced from external xclk60mhsp1 (USB3320). Good.
- UHH_HOSTCONFIG (0x4A064040) = 0x1c → **P1_CONNECT_STATUS bit8 (0x100) is
  CLEARED at runtime** (patch 0008 sets 0x11C in the parent probe; something
  clears bit8 later). Semantics unconfirmed — flagged to RE.
- ULPI PHY (USB3320) fully healthy & correct host state: VID=0x0424,
  FUNC_CTRL=0x45, IFC_CTRL=0x18, OTG_CTRL=0x66 (DrvVbus + Dp/Dm pulldowns),
  **DEBUG linestate=0x00 (SE0 — nothing on the bus)**.
- gpios: gpio_1/NENABLE (Linux 513) = power ON; gpio_62/NRESET (574) = released;
  gpio_159/"steelhead-eth-phy-reset" (671) = released (driver captures it but
  NEVER pulses it in bring-up).

**Interpretation:** OMAP EHCI + USB3320 ULPI PHY are healthy and driving VBUS
with host pulldowns. The LAN9500A downstream simply never drives D+ (SE0). The
blocker is the LAN9500A CHIP's own bring-up, not the OMAP/PHY/EHCI side, and not
timing.

## Runtime experiments RULED OUT (all still SE0 / eth0 absent)
via `echo 4a064c00.ehci > /sys/bus/platform/drivers/ehci-omap/unbind` (patch
0032 lets it rebind cleanly) → gpio manipulation → rebind:
1. **30 s clean power-off** (NENABLE off + NRESET asserted) then on → NO attach.
   Rules out rail-discharge / power-cycle-duration. NENABLE may not truly cut
   the LAN9500A rail (likely always-on 3V3 regulator).
2. **Pulsing gpio_159** (assert+release, active-low) in the sequence → NO attach.
   That line at this polarity/timing is not the missing step.
3. No 25MHz clock node for the LAN9500A in the mainline clk tree (auxclk3=
   38.4MHz is the USB3320 refclk, running) → LAN9500A likely has its own crystal.

**Key insight:** runtime power-cycle+rebind just re-runs OUR failing bring-up
with variations. Guessing without stock's blueprint violates verify-against-stock.

## What's running / next
- stock-parity-auditor (agent a4b0cf81aec2fb4e2) disassembling stock's EXACT
  LAN9500A cold-init from reverse-eng/vmlinux.bin. Awaiting: the precise ordered
  gpio/clock/VBUS/register sequence stock does between power/reset and the chip
  driving D+; whether a separate LAN9500A power-enable / VBUS switch exists;
  gpio_159's real role; UHH_HOSTCONFIG P1_CONNECT_STATUS semantics.
- Plan: replicate stock's exact sequence LIVE on the cold device (mmio + gpio +
  rebind); when it attaches, bake into patch 0006; build; cold-boot validate
  (needs Petr's power-cycle in the morning).

## Device state left for the morning
Running kernel #31 (dd-deployed) + v1.6.8-personal r30 rootfs (fastboot-flashed).
eth0 absent (cold-failed, expected). Reachable: ssh root@192.168.20.195 (WiFi,
factory MAC) or root@172.16.42.1 (gadget). `/root/mmio` + `/root/ulpi_read.sh`
present (tmpfs — regenerate from scratchpad if rebooted).

## Record correction — DONE
Commit 6c869e8 "closes #17" (2500ms settle) was PREMATURE — the settle did not
fix cold-init. Corrected by **e33a1b4**, which applied the real pad-mux fix and
**reverted the 2500ms settle** back to stock timing. Record reconciled across
CHANGELOG / HANDOFF / README / PLAN / `ethernet-bringup-procedure.md` /
`2026-07-02-boot-error-inventory.md` on 2026-07-06.

---

## RESOLVED (2026-07-06 late) — ROOT CAUSE: gpio_1 NENABLE pad UNMUXED

Stock-parity RE + live proof nailed it. gpio_1 (NENABLE, LAN9500A power-enable)
= pad **kpd_col2 @ core padconf 0x186** (word 0x4A100184 upper 16b). Our DTS
`ethernet_gpios` muxed only gpio_62 NRESET (0x08c); **0x186 was absent** (a prior
comment wrongly placed gpio_1 in the wkup padconf). Result: gpiolib drove the
DATAOUT latch (debugfs "asserted") but the pad stayed in safe_mode (0x010f), so
NENABLE never reached the chip → LAN9500A never powered → never drove D+ →
PORTSC CCS=0 on cold boot. The healthy PHY (its pads ARE muxed) masked it,
sending every other theory (timing/clock/VBUS/power-cycle/gpio_159) down dead
ends. **Same pinmux-miss class as the NFC bug.**

Stock muxes BOTH (omap_mux_init_gpio 1 & 62 @ 0xc00178d0/dc = 0x0e03).

**PROVEN LIVE (no reboot, from the cold-failed baseline):**
`mmio w 0x4A100184 0x0e03010f` (kpd_col2→gpio_1 mode3 out) + `ehci-omap` rebind
→ eth0 attached, PORTSC1=0x00001005 (CCS=1), smsc95xx eth0, **Link Up
100Mbps/Full**.

**FIX applied:** DTS `ethernet_gpios` += `OMAP4_IOPAD(0x186, PIN_OUTPUT |
MUX_MODE3)`; patch 0003 regenerated; kernel pkgrel **32** (uname **`#33`**).
Commit **e33a1b4** (supersedes the premature 6c869e8).

**Cleanups landed in e33a1b4 (stock parity):** patch 0006 power block reverted
to stock `udelay(100)`/`udelay(2)` — the disproven 200ms/50ms/2500ms delays
dropped; DTS drops the non-stock `gpio_159` (0x164) pad mux + the
`steelhead-eth-phy-reset-gpios` property (stock leaves that pad in safe_mode; it
is not wired to the LAN9500A).

**GOLD-VALIDATED 2026-07-06 — cold-boot PASSED (task #17 FULLY CLOSED).** Three
independent proofs:
1. **Live mmio** — from the cold-FAILED baseline (no reboot), `mmio w
   0x4A100184 0x0e03010f` (kpd_col2 → gpio_1 mode3 out) + `ehci-omap` rebind →
   `eth0` attached, PORTSC1=`0x00001005` (CCS=1), smsc95xx `eth0`, Link Up
   100Mbps/Full.
2. **Bidirectional causality** — setting the pad → attach; clearing the pad →
   detach.
3. **GOLD STANDARD** — a **clean fastboot flash of `#33`** + a **true cold
   power-cycle** (power pulled, no stock prime) → `eth0` enumerates
   **100Mbps/Full, 0 failed units**. The clean-flash **warm boot #1** enumerated
   too.

**Method worth keeping:** the device was left in the cold-FAILED state and
probed live with an aligned MMIO helper (`/root/mmio`) + ULPI viewport reads —
**never python mmap** (it wedges INSNREG05). The stock-parity-auditor found the
pad miss by diffing `reverse-eng/stock-omap-mux-full.txt` (`kpd_col2` @ mux-dump
line 520 = `0x0e03`) against the DTS.

**Note for LAN DHCP:** `eth0`'s hw MAC is **random per boot** (the LAN9500A has
no MAC EEPROM) — lease/IP matching by eth MAC is impossible on a real LAN.
