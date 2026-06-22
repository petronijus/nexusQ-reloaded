# Ethernet (LAN9500A) — continuation plan

Pick up here. The on-board SMSC LAN9500A USB-ethernet still enumerates only
**intermittently**. This doc is the exact next diagnostic so the next session
starts measuring, not guessing.

## State at hand-off (2026-06-23)

- Chain: `OMAP4 EHCI port1 (0x4A064C00) → SMSC USB3320 ULPI PHY (38.4 MHz) →
  LAN9500A (0424:9e00) → RJ45`.
- Failure signature on a bad (cold) boot: `PORTSC = 0x00501000` →
  **PP=1 (port powered), CCS=0, line status 00** (neither D+ nor D- pulled) →
  the chip is **not presenting as a USB device at all**. `ULPI DBG=0x0` in the
  patch-0006 diag sampler. Zero `new high/full-speed USB device` messages.
- What is already in the kernel and **confirmed stock-parity** (auditor, evidence
  in `reverse-eng/vmlinux.bin`): board reset sequence + timing, INSNREG01
  `0x00800080`, ULPI Function-Control soft-reset before `usb_add_hcd`, OHCI held
  suspended, the new **1 ms ULPI pre-reset settle** (commit `3b06c41`).
- The settle is **necessary parity but not sufficient** — cold boot after it still
  failed. So the remaining cause is elsewhere.

## Hypotheses, ranked

1. **UHH_HOSTCONFIG not actually holding `0x11c` at runtime (PRIME suspect).**
   Patch 0008 programs `UHH_HOSTCONFIG` (UHH base `0x4A064000`, offset `0x10` →
   `0x4A064010`) to vendor `0x11c` (P1_CONNECT_STATUS set, APP_START_CLK clear).
   The auditor could **not** statically prove the value sticks — the vendor write
   lives in `usbhs_runtime_resume` (mach-omap2/usb-host.c), which **re-runs on
   every runtime-resume** and may overwrite our value back to the mainline `0x1c`.
   If so, CCS can never latch. **This is the first thing to measure.**
2. **USB3320 ULPI PHY is not alive / not clocked** at the moment of the soft
   reset. `ULPI DBG=0x0` is suspicious. If the PHY's vendor-id registers read
   `0x00`/`0xff`, the data path is dead regardless of the LAN9500A.
3. The LAN9500A itself is held in reset / unpowered on the bad boots (NENABLE /
   NRESET gpio state wrong at the critical moment) — less likely, gpios are
   driver-owned and the board reset matches stock, but verify the live gpio
   values.

## The diagnostic to build (kernel-side, because /dev/mem faults)

`/dev/mem` reads of the USBHS region **bus-error** from userspace (the module is
clock-gated for user access). So instrument the kernel — extend the **existing
patch-0006 diag sampler** (it already prints `PORTSC` from kernel context, where
the USBHS clocks are on) to also dump, right after `usb_add_hcd()` and again in
the timed sampler:

- **`UHH_HOSTCONFIG`** (read back the UHH register) — does it read `0x11c` or has
  it reverted to `0x1c`? Print it next to PORTSC.
- **USB3320 ULPI identity + function control** via the INSNREG05 ULPI viewport
  (read path, OPSEL=3): VENDOR_ID_LOW (`0x00`, expect `0x24`), VENDOR_ID_HIGH
  (`0x01`, expect `0x04` → SMSC `0x0424`), PRODUCT_ID, FUNC_CTRL (`0x04`),
  OTG_CTRL, INTERFACE_CTRL. **If vendor id ≠ 0x0424 → the PHY is dead/unclocked**
  (cause #2). If it reads correctly → the PHY is fine, look at UHH/LAN9500A.
- The live **NENABLE (gpio_1) / NRESET (gpio_62)** values via `gpiod_get_value`
  in the sampler (sanity on cause #3).

Add a small ULPI **read** helper mirroring `omap_ehci_soft_phy_reset`'s write
(set OPSEL=read=3, the FUNC_CTRL/etc reg address, CONTROL=1, poll, then read back
the data byte from INSNREG05 low bits). All of this is read-only instrumentation
in patch 0006; build a `boot-eth-diag.img`, **cold-boot 3–5×**, and read dmesg.

## Fix paths by outcome

- **If UHH reverts to `0x1c`** (cause #1, most likely): make patch 0008 also hook
  `usbhs_runtime_resume` (or set the bit in a place that survives runtime-resume),
  so `UHH_HOSTCONFIG` keeps `P1_CONNECT_STATUS` set after every resume. This is the
  vendor-faithful behaviour (stock sets it in exactly that resume path).
- **If the ULPI PHY vendor id is wrong/zero** (cause #2): the USB3320 isn't being
  brought up — investigate its refclk / reset ordering relative to the EHCI port
  power; possibly the PHY needs its own reset/settle before the LAN9500A reset.
- **If gpios are wrong** (cause #3): fix the board reset gpio sequencing.

## Hard rules (do not regress)
- **Do NOT** add a NENABLE power-cycle, a post-NRESET board delay, or a connect
  retry loop — the auditor proved stock does **none** of these. Stay
  vendor-faithful; the answer is a register/PHY state issue, not brute force.
- Test only by **cold power-cycle** (warm `fastboot reboot` leaves the LAN9500A
  rail up and is not representative). Statistically validate over **multiple cold
  boots** — a single good boot is luck, not a fix.
- Keep the 1 ms settle (`3b06c41`) — it is correct stock parity.

## Key references
- `reverse-eng/vmlinux.bin` — stock kernel. Functions: `steelhead_usbhost_init`
  VA `0xC00178C4`, `ehci_hcd_omap_probe` `0xC03333F0`, `omap_ehci_soft_phy_reset`
  `0xC0329B88` (the `udelay(1000)` at `0xC0329BA4`).
- `kernel/patches/0006-…-keep-ethernet-port-alive-ulp.patch` — soft_phy_reset +
  diag sampler (where to add the register dump).
- `kernel/patches/0008-…-UHH-HOSTCONFIG-connect.patch` — the UHH write to harden.
- `docs/ethernet-bringup-procedure.md` — the 4-layer recipe + regression triage.
- `docs/2026-06-23-session-findings.md` — full session context.
