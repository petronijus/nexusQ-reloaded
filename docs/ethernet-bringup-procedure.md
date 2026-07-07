# Nexus Q ethernet (LAN9500A) — exact bring-up procedure & regression checklist

Reference for keeping the on-board SMSC **LAN9500A** USB-ethernet working while
other kernel work (e.g. SMP second-core) is in flight. First made to work in
**v1.1.0 / kernel #8** (2026-06-22). If `eth0` disappears after an unrelated
change, work the **Regression triage** at the bottom — it tells you *which layer*
broke.

> **Status 2026-07-06 — ✅ RESOLVED, task #17 FULLY CLOSED (enumerate + link +
> NM), gold-validated from a true cold boot; ships as v1.6.8.**
> The enumeration intermittency was **not a race** — it was a **pinmux miss**:
> `gpio_1` NENABLE (the LAN9500A power-enable) is pad **`kpd_col2` @ CORE
> padconf `0x186`**, but `ethernet_gpios` muxed only `gpio_62` NRESET (`0x08c`);
> `0x186` was omitted (a prior comment wrongly placed `gpio_1` in the wkup
> padconf). gpiolib drove the DATAOUT **latch** (debugfs "asserted") but the pad
> stayed in **safe_mode**, so NENABLE never reached the chip → never powered →
> never drove D+ → PORTSC CCS=0 on cold boot. The healthy USB3320 PHY (its pads
> ARE muxed) masked it; the "intermittency" was **stock priming** — warm reboots
> from a stock RAM boot never cut LAN9500A power, so a stock-initialized chip
> stayed attached and looked like a pass. **Same pinmux-miss class as the NFC
> bug.** Fix: DTS `ethernet_gpios` += `OMAP4_IOPAD(0x186, PIN_OUTPUT |
> MUX_MODE3)` (patch 0003; kernel pkgrel **32**, uname **`#33`**, commit
> **e33a1b4**). The 2500ms "attach-ready settle" (`#31`, commit 6c869e8) was a
> false positive and was **reverted** to stock `udelay(100)`/`udelay(2)`; the
> non-stock `gpio_159` (`0x164`) mux + `steelhead-eth-phy-reset-gpios` property
> were dropped (stock leaves that pad safe_mode; not wired to the LAN9500A).
> **GOLD-VALIDATED:** clean fastboot flash of `#33` + a true cold power-cycle →
> `eth0` enumerates **100Mbps/Full, 0 failed units** (warm boot #1 too); also
> proven live by an mmio write of `0x4A100184` (`0x0e03010f`) + `ehci-omap`
> rebind from the cold-failed state, and bidirectionally (pad set→attach,
> cleared→detach). **Lesson: debugfs/gpiolib "asserted" = the DATAOUT latch is
> driven, NOT that the pad is routed — always diff the IOPAD mux against a live
> stock `omap_mux` dump (`reverse-eng/stock-omap-mux-full.txt`, `kpd_col2` line
> 520 = `0x0e03`).** Full record:
> `docs/2026-07-06-eth-coldinit-resolved.md`.
>
> _(Superseded status 2026-07-05 — "NM layer RESOLVED; enumeration
> intermittency ACTIVE again" — kept below; its NM-layer half stands, the
> "kernel/ehci bring-up race" framing was wrong: it was the unmuxed pad.)_
> On the v1.6.7 acceptance (flashed 2026-07-05) the LAN9500A **did not
> enumerate on any of the 3 boots** (USB CCS=0; the patch-0006
> `LAN9500A power-on-reset sequenced` init runs but the port never shows
> connect) — while the 2026-07-03/04 boots enumerated **3/3 with the
> byte-identical kernel** (`6.12.12-r28`/`#29`). So enumeration is
> **intermittent**, not deterministically dead. It is NOT cpufreq (`ondemand`
> ran on the good boots too) and NOT the r21 device pkg (it changed only NM
> config, which is post-enumeration userspace) — the suspect is the
> **kernel/ehci bring-up race** in the patches 0006/0008/0012 area. Everything
> in the 2026-07-04 note below (the NM retry-loop fix, the zero-touch §4
> workflow) **stands and is baked+flashed since v1.6.7** — but it only applies
> on boots where the chip enumerates. Graceful degradation is verified: with
> the chip absent, the baked profiles keep the boot clean (no auto-generated
> profile, no retry loop, zero failed units, wait-online green — all 3
> acceptance boots). See the 2026-07-05 addendum in
> `docs/2026-07-04-ethernet-resolved-and-led-guard.md`.
>
> _(Superseded status 2026-07-04 — "RESOLVED, task #17 CLOSED" — kept below;
> its NM-layer half remains true, the closure over-claimed.)_
> The v1.4.0 regression (no enumeration, PORTSC CCS=0) ended with batch 2b
> (`#29`, 2026-07-03) — likely one of the batch-2 clock changes revived
> enumeration — and the remaining "carrier flap" was root-caused 2026-07-04 as
> **NOT a link-layer fault at all**: the LAN9500A/driver is **fully healthy**
> (NM detached: carrier held 90+ s with zero transitions, 100Mbps/Full, 0 rx/tx
> errors, under `ondemand` — which also rules out the cpufreq-timing theory on
> the current image; autosuspend already pinned by patch 0006; boot
> enumeration textbook). The flap was **NetworkManager's auto-generated "Wired
> connection 1" DHCP retry loop** on the serverless direct cable: 45 s DHCP
> timeout → deactivate resets the cloned "stable" MAC → the MAC write bounces
> the LAN9500A carrier → the carrier event resets NM's autoconnect-retries
> counter → reactivate (self-arming, ~47 s period, 14 811 journal lines in
> 29 h; also the `NetworkManager-wait-online` failure). Fixed by the baked
> eth0 NM profiles in `device-google-steelhead` r21 — see §4 (the new
> zero-touch workflow) and
> `docs/2026-07-04-ethernet-resolved-and-led-guard.md`. Verified live:
> eth0 settles at "disconnected" quietly, `nm-online -s` rc=0,
> `ssh root@10.42.0.2` over the cable works.
> _(Superseded status 2026-07-03 "partial comeback, link flaps" — the dmesg
> Up/Down lines were real but NM-induced, not a driver/HW wobble. Evidence:
> `nq-captures/20260703-144228/` +
> `docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md`.)_

The chip is a USB-ethernet adapter soldered behind the OMAP4 EHCI port 1:
`OMAP4 EHCI port1 → SMSC USB3320 ULPI PHY (38.4 MHz) → LAN9500A (0424:9e00) → RJ45`.

---

## 1. The software recipe — necessary AND sufficient (all four layers)

If any one of these is missing/reverted, `eth0` will not come up.

### 1a. defconfig (`kernel/configs/steelhead_defconfig`) — all `=y`
```
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_EHCI_HCD_OMAP=y          # OMAP EHCI host (where patch 0006 acts)
CONFIG_MFD_OMAP_USB_HOST=y          # UHH/USBHS core (where patch 0008 acts)
CONFIG_NOP_USB_XCEIV=y
CONFIG_OMAP_USB2=y
CONFIG_USB_USBNET=y
CONFIG_USB_NET_SMSC95XX=y           # the LAN9500A driver -> creates eth0
```

### 1b. Device tree (`kernel/dts/omap4-steelhead.dts`, shipped via patch 0003)
The `&usbhsehci` node MUST carry the steelhead bring-up resources:
```
&usbhsehci {
	phys = <&hsusb1_phy>;
	clocks = <&auxclk3_ck>;                  /* 38.4 MHz PHY refclk */
	clock-names = "steelhead-ethernet-phy";
	steelhead-ethernet-enable-gpios = <&gpio1 1  GPIO_ACTIVE_LOW>;  /* gpio_1  NENABLE */
	steelhead-ethernet-reset-gpios  = <&gpio2 30 GPIO_ACTIVE_LOW>;  /* gpio_62 NRESET  */
	...
};
```
plus the `hsusb1_phy: hsusb1-phy { compatible nop-phy; #phy-cells = <0>; }` node and
`port1-mode = "ehci-phy"`. (These survived the SMP `cpu@1` DTS regen — verify they
still do after any `scripts/regen-dts-patch.sh` run.)

> **CRITICAL (the 2026-07-06 cold-init fix) — the `ethernet_gpios` pinctrl node
> MUST mux BOTH gpio pads**, or the gpio is driven only at the DATAOUT latch and
> never reaches the pin:
> ```
> ethernet_gpios: pinmux_ethernet_gpios {
>     pinctrl-single,pins = <
>         OMAP4_IOPAD(0x186, PIN_OUTPUT | MUX_MODE3)  /* kpd_col2 -> gpio_1  NENABLE */
>         OMAP4_IOPAD(0x08c, PIN_OUTPUT | MUX_MODE3)  /* gpio_62 NRESET */
>     >;
> };
> ```
> `0x186` (`kpd_col2`) was omitted for a long time (a comment wrongly placed
> gpio_1 in the wkup padconf), so NENABLE stayed in safe_mode and the LAN9500A
> was never powered on a cold boot — the single root cause of the whole
> "SOLVED→REGRESSED→intermittent" saga. Do NOT re-add a `gpio_159`/`0x164` mux or
> a `steelhead-eth-phy-reset-gpios` property — stock leaves that pad safe_mode;
> it is not wired to the LAN9500A.

### 1c. Kernel patch `0006-usb-ehci-omap-steelhead-keep-ethernet-port-alive-ulp`
In `ehci_hcd_omap_probe`, **before `usb_add_hcd()`** (order is the whole point):
1. **PHY power-on-reset sequence:** enable auxclk3 → NENABLE(gpio_1) low → `udelay(100)`
   → NRESET(gpio_62) high → `udelay(2)`.
2. **`INSNREG01` burst thresholds = 0x80** (OUT<<16 | IN), steelhead-only.
3. **ULPI Function-Control soft reset** of the USB3320 (via the EHCI INSNREG05 ULPI
   viewport) — without it the PHY answers reads but never enumerates the device.
4. After `usb_add_hcd()`: **`usb_disable_autosuspend(root_hub)`** so the idle port is
   not clock-gated away.

### 1d. Kernel patch `0008-mfd-omap-usb-host-steelhead-UHH-HOSTCONFIG-connect`
In `omap_usbhs_init` (`drivers/mfd/omap-usb-host.c`): program `UHH_HOSTCONFIG` to the
vendor value **0x11c** — set `OMAP_UHH_HOSTCONFIG_P1_CONNECT_STATUS` (bit 8) so EHCI
latches the port-1 connect, and **leave `OMAP4_UHH_HOSTCONFIG_APP_START_CLK` (bit 31)
clear** (mainline default measured = 0x1c; mainline otherwise *sets* APP_START_CLK,
which auto clock-gates the UHH).

> Both patches must **apply with GNU `patch`** (abuild uses `patch -p1`, not `git
> apply`). After hand-editing a `.patch`, dry-run it; a wrong `@@` count or a
> non-` `-prefixed blank context line makes it silently fail to apply → the fix is
> missing from the build even though the build "succeeds".

---

## 2. Build the boot image

**Fast path (kernel-only, reuses the warm `nexusq-workdir` volume — minutes):**
```bash
docker run --rm --privileged -v "${PWD}:/src:ro" \
    -v nexusq-output:/tmp/output \
    -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap \
    nexusq-builder /src/scripts/build-kernel-boot.sh boot-eth.img
# pull it out of the output volume:
docker run --rm -v nexusq-output:/d -v "$PWD/output:/o" alpine:3.21 sh -c 'cp /d/boot-eth.img /o/'
```
Full path (`./docker-build.sh`) also works but rebuilds the rootfs (Phase 9 currently
fails on a post-install step — harmless for the kernel apk; the boot image is fine).

**Always confirm the patches applied** in the build output:
```
>>> linux-google-steelhead: 0006-...patch   ->  patching file drivers/usb/host/ehci-omap.c
>>> linux-google-steelhead: 0008-...patch   ->  patching file drivers/mfd/omap-usb-host.c
```
No `Hunk #N FAILED` / `.rej` lines. Sanity-check the DTB before flashing:
```bash
dtc -I dtb -O dts output/<dtb> | grep -E 'steelhead-ethernet|auxclk3|cpu@'
```

Boot image must be **< ~6.5 MB** (U-Boot ceiling) and DTB appended to the zImage.

---

## 3. Flash to the boot partition (p9) — from the running device, no fastboot

Device is reachable over **ethernet (`10.42.0.2`, the DEFAULT deploy path since
2026-07-07 — ~80 Mbit/s, 0.62 ms, fixed IP; see §4)** or, as a fallback, over the
USB gadget (`172.16.42.1` — solid but its `enx*` iface renames every reboot, so
re-add the host IP first with `sudo ip addr add 172.16.42.2/24 dev enx<...>`).
WiFi works too but caps at ~34 Mbit/s (BCM4330 HW ceiling — see
`docs/2026-07-07-wifi-characterization-and-ethernet-default.md`), so prefer the
cable for a boot-image push. Substitute the reachable host below (`10.42.0.2` or
`172.16.42.1`) — `nqctl` picks it for you (ethernet first):
```bash
DEV=root@10.42.0.2        # or root@172.16.42.1 (gadget fallback)
# 1. back up the currently-working p9 FIRST
ssh $DEV 'dd if=/dev/mmcblk0p9 bs=1M' > output/p9-backup.img
# 2. push + verify + flash + read-back verify
LSHA=$(sha256sum output/boot-eth.img | awk '{print $1}'); SZ=$(stat -c%s output/boot-eth.img)
ssh $DEV "cat > /tmp/b.img" < output/boot-eth.img
ssh $DEV "sha256sum /tmp/b.img"          # must equal $LSHA
ssh $DEV "dd if=/tmp/b.img of=/dev/mmcblk0p9 bs=1M conv=fsync; sync;
          head -c $SZ /dev/mmcblk0p9 | sha256sum"   # must equal $LSHA
# 3. reboot (clean systemd reboot boots from p9; ~90-130 s back up)
ssh $DEV 'systemctl reboot'
```

---

## 4. Reach the device over ethernet (direct PC↔Nexus cable) — the DEFAULT path, fully automatic since r29 (2026-07-07)

This is now the **default deploy/control transport** — measured 2026-07-07 at
**~80 Mbit/s, 0.62 ms, 0 % loss**, beating WiFi (~34) and the USB gadget (~64
crypto), and it has a fixed name/IP (the gadget renames per boot). The Nexus RJ45
is cabled directly to `petronijus-PC` NIC **`enp7s0`** (Intel I225-V, 100 Mbps). A
direct cable has **no DHCP server** — this is exactly the topology that armed the
old NM retry loop (see the Status note). Since `device-google-steelhead` **r21**
(baked since v1.6.7) eth0 is owned by shipped config files, and the host has a
persistent profile too — no ad-hoc setup on either end. ⚠️ All of this presupposes
the chip **enumerated this boot** (`ls /sys/class/net` shows `eth0`) — on `#33`+
(v1.6.8) it enumerates from a true cold boot; if `eth0` is missing on an older
image it's the unmuxed-pad root cause (Status note), not a profile problem;
reboot or use the gadget/WiFi instead:

- **Device (baked):** `eth-no-auto-default.conf` (`no-auto-default=eth0` — NM never
  generates "Wired connection 1"), `eth-lan.nmconnection` (DHCP,
  **`autoconnect-priority=10`**, `dhcp-timeout=10`, `autoconnect-retries=1`,
  **`cloned-mac-address=permanent`** — no MAC churn → no carrier bounce → the retry
  counter sticks; on a serverless wire the port goes quiet instead of looping),
  `eth-direct.nmconnection` (static **10.42.0.2/24 + 10.0.0.2/24**, never-default;
  **since r29 `autoconnect=true` at `autoconnect-priority=5`**).
- **Host (persistent NM profile `eth-direct-host` on `enp7s0`):** 10.42.0.1/24 +
  10.0.0.1/24, never-default, autoconnect — replaces the old
  `managed no` + manual `ip addr add` dance.

**Fall-through logic (r29, 2026-07-07):** on any eth0 carrier NM tries `eth-lan`
DHCP FIRST (priority 10). On a real LAN it completes and wins. On the serverless
direct cable it fails its single attempt after `dhcp-timeout=10 s`, and NM then
falls through to the lower-priority static `eth-direct` → **10.42.0.2 comes up
automatically, no manual `nmcli c up`**.

**Workflow:** just ssh over the cable once the device is booted:
```bash
ssh root@10.42.0.2          # comes up on its own ~10 s after carrier
# if the fall-through hasn't fired yet (or a pre-r29 image with autoconnect=no):
ssh root@172.16.42.1 'nmcli c up eth-direct'   # force it over the gadget/WiFi
```
Verified 2026-07-07: ping 0 % loss (~0.62 ms), ssh works, `nm-online -s` rc=0.
_(Pre-r29, 2026-07-04: `eth-direct` was `autoconnect=no` and required a manual
`nmcli c up eth-direct` each boot — now automatic.)_

⚠️ **eth0's hw MAC is RANDOM per boot** (the LAN9500A has no MAC EEPROM), and
`cloned-mac-address=permanent` puts that random address on the wire — so **on a
real LAN the DHCP lease/IP changes every boot**. If a stable LAN identity is ever
wanted, pin a fixed `cloned-mac-address=XX:…` in `eth-lan.nmconnection`.

<details><summary>Pre-r21 manual procedure (reference — needed only on older images)</summary>

**Device side (persistent, survives reboot):**
```bash
nmcli con add type ethernet ifname eth0 con-name eth-direct \
  ipv4.method manual ipv4.addresses 10.42.0.2/24 ipv4.never-default yes \
  ipv6.method link-local connection.autoconnect yes
nmcli con up eth-direct
```
**PC side (keep NM from flushing the manual IP):**
```bash
sudo nmcli dev set enp7s0 managed no
sudo ip addr add 10.42.0.1/24 dev enp7s0 ; sudo ip link set enp7s0 up
```
Then: `ssh root@10.42.0.2`. Without a static profile, NM sits in "connecting
(getting IP)", times out ~every 45 s and **bounces the carrier** (the historical
"flap" — never a hardware fault).
</details>

**Verify:**
```bash
ping -c3 10.42.0.2                                   # 0% loss expected
ssh root@10.42.0.2 'ls /sys/class/net/'              # eth0 present
ssh root@10.42.0.2 'dmesg | grep -iE "smsc95|0424:9e00"'
```
Healthy: `usb 1-1: New USB device ... idVendor=0424 idProduct=9e00` then
`smsc95xx ... eth0: register 'smsc95xx' ... Link is Up - 100Mbps/Full`.
Throughput ~80 Mbit/s (crypto/CPU-bound, measured 2026-07-07 — the fastest of the
three transports), not a fault.

---

## 5. Regression triage — "eth0 worked, now it doesn't" (e.g. after SMP work)

Work top-down; each step says which layer is at fault.

1. **Does `eth0` exist?** `ssh root@<dev> 'ls /sys/class/net; dmesg | grep -iE "smsc95|0424:9e00|usb 1-1"'`
   - **`eth0` present, link up, but no connectivity** → it's the *runtime* layer, not the
     kernel. On r29+ the static `eth-direct` auto-comes-up ~10 s after carrier (§4); if it
     hasn't yet, force it with `nmcli c up eth-direct`. Most common false alarm.
   - **`eth0` present but "flapping"** → an NM activation loop bouncing the carrier via MAC
     rewrites, NOT a link fault (root-caused 2026-07-04, see the Status note). On r21+ the
     baked `eth-no-auto-default.conf` + `eth-lan` profile prevent it; on older images use
     the §4 manual static profile. Confirm by detaching NM
     (`nmcli dev set eth0 managed no`) — a healthy link holds carrier indefinitely.
   - **No `eth0` / no `usb 1-1` device** → kernel/HW layer. **First check the
     `gpio_1` NENABLE pad mux** (the 2026-07-06 root cause): the flashed DTB's
     `ethernet_gpios` MUST mux `kpd_col2` @ `0x186` (`dtc -I dtb -O dts <dtb> |
     grep -A4 ethernet_gpios` should show BOTH `0x186` and `0x08c`). Confirm live
     from the cold-failed state: `mmio r 0x4A100184` should read `0x0e03….` — if
     the upper 16 bits are `0x010f` (safe_mode) the pad is unmuxed and the fix is
     missing from this build. On `#33`+ this is fixed; a true cold boot after a
     clean flash enumerates. (Historical: the "intermittency" 2026-07-05 was
     **stock priming** — warm reboots from a stock RAM boot kept the chip powered
     and masked the miss, not an ehci race.)

2. **Did the build actually contain the fix?** Re-check the build log for
   `patching file drivers/usb/host/ehci-omap.c` and `.../mfd/omap-usb-host.c` with **no
   `Hunk FAILED`**. A silently-unapplied `0006`/`0008` (GNU-patch format breakage) is the
   #1 cause: the kernel boots fine but the steelhead host-init / `UHH_HOSTCONFIG` change
   is gone. Confirm on-device:
   `ssh root@<dev> 'dmesg | grep -iE "steelhead|UHH_HOSTCONFIG"'` — the 0006 host-init
   and (if present) the 0008 diagnostic should show.

3. **Does the flashed DTB still carry the ethernet nodes?** A `regen-dts-patch.sh` run for
   `cpu@1`/SMP can drop the `&usbhsehci` steelhead props. Check the *built* DTB (not just
   the source): `dtc -I dtb -O dts <built.dtb> | grep -E 'steelhead-ethernet|auxclk3'`.

4. **SMP suspicion (`CONFIG_SMP=y`).** SMP=y with `maxcpus=1` should be inert for USB, but:
   - Confirm the device still booted single-core: `nproc` = 1, `cat /proc/cmdline` has
     `maxcpus=1`. If the 2nd core actually came up, USB IRQ timing/affinity changes — test
     ethernet with SMP forced off (`maxcpus=0`/`nosmp` or a `CONFIG_SMP=n` build) to
     bisect: if eth0 returns, the regression is SMP-side, not ethernet-side.
   - The `0009-...-smp-bringup` instrumentation patch must not touch the EHCI/USBHS probe
     path or its timing.

5. **Still stuck?** Roll back to the known-good image to confirm the HW is fine, then
   bisect your change against it: `dd if=output/p9-backup.img of=/dev/mmcblk0p9 ...`
   (or the v1.1.0 release asset `nexusq-boot-v1.1.0.img`).

**Ground truth:** the LAN9500A is healthy hardware — the stock Android 3.0 kernel
enumerates it on this unit, and v1.1.0 does too. If `eth0` is gone, a *software* layer
above regressed; it is never "dead hardware".
