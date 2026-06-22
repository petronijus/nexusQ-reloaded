# Nexus Q ethernet (LAN9500A) — exact bring-up procedure & regression checklist

Reference for keeping the on-board SMSC **LAN9500A** USB-ethernet working while
other kernel work (e.g. SMP second-core) is in flight. First made to work in
**v1.1.0 / kernel #8** (2026-06-22). If `eth0` disappears after an unrelated
change, work the **Regression triage** at the bottom — it tells you *which layer*
broke.

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

Device is reachable over the USB gadget (`172.16.42.1`) or, once up, over ethernet
(`10.42.0.2`, see §4). The gadget iface on the host renames every reboot — re-add the
host IP first (`sudo ip addr add 172.16.42.2/24 dev enx<...>`).
```bash
# 1. back up the currently-working p9 FIRST
ssh root@172.16.42.1 'dd if=/dev/mmcblk0p9 bs=1M' > output/p9-backup.img
# 2. push + verify + flash + read-back verify
LSHA=$(sha256sum output/boot-eth.img | awk '{print $1}'); SZ=$(stat -c%s output/boot-eth.img)
ssh root@172.16.42.1 "cat > /tmp/b.img" < output/boot-eth.img
ssh root@172.16.42.1 "sha256sum /tmp/b.img"          # must equal $LSHA
ssh root@172.16.42.1 "dd if=/tmp/b.img of=/dev/mmcblk0p9 bs=1M conv=fsync; sync;
                      head -c $SZ /dev/mmcblk0p9 | sha256sum"   # must equal $LSHA
# 3. reboot (clean systemd reboot boots from p9; ~90-130 s back up)
ssh root@172.16.42.1 'systemctl reboot'
```

---

## 4. Bring up + reach the device over ethernet (direct PC↔Nexus cable)

The Nexus RJ45 is cabled directly to `petronijus-PC` NIC **`enp7s0`** (Intel I225-V,
100 Mbps). A direct cable has **no DHCP server**, so use static IPs both ends. Without
this, NetworkManager sits in "connecting (getting IP)", times out ~every 45 s and
**bounces the carrier** (the "flap" — it is NOT a hardware fault).

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
Then: `ssh root@10.42.0.2`.

**Verify:**
```bash
ping -c3 10.42.0.2                                   # 0% loss expected
ssh root@10.42.0.2 'ls /sys/class/net/'              # eth0 present
ssh root@10.42.0.2 'dmesg | grep -iE "smsc95|0424:9e00"'
```
Healthy: `usb 1-1: New USB device ... idVendor=0424 idProduct=9e00` then
`smsc95xx ... eth0: register 'smsc95xx' ... Link is Up - 100Mbps/Full`.
Throughput on this HW is ~30–60 Mbps (USB2 / single-core bound), not a fault.

---

## 5. Regression triage — "eth0 worked, now it doesn't" (e.g. after SMP work)

Work top-down; each step says which layer is at fault.

1. **Does `eth0` exist?** `ssh root@<dev> 'ls /sys/class/net; dmesg | grep -iE "smsc95|0424:9e00|usb 1-1"'`
   - **`eth0` present, link up, but no connectivity** → it's the *runtime* layer, not the
     kernel. Redo §4 (static IPs / `eth-direct` profile). Most common false alarm.
   - **`eth0` present but flapping** → NetworkManager DHCP bounce. §4 static profile.
   - **No `eth0` / no `usb 1-1` device** → kernel/HW layer, go on.

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
