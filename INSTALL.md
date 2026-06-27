# Nexus Q Reloaded -- Install Guide (v1.5.0)

Flashing postmarketOS onto a Google Nexus Q ("steelhead") using the release
images. Takes ~10 minutes. The device is **unbrickable** as long as you never
touch the `bootloader` partition -- everything else can always be reflashed.

## What you need

- Google Nexus Q
- micro-USB cable (data-capable)
- power cable for the Q
- `fastboot` on your PC (`apt install android-sdk-platform-tools` or
  `android-tools`)
- optional: micro-HDMI cable + display (to watch it boot)
- release artifacts: `nexusq-boot-v1.5.0.img`, `nexusq-rootfs-v1.5.0-sparse.img`

## 1. Enter fastboot mode

1. Unplug power.
2. Put your palm over the top dome so you **cover the mute LED sensor**.
3. Plug power in while keeping the sensor covered.
4. The LED ring turns **solid red** -> you are in fastboot.
5. Connect micro-USB to your PC and check: `fastboot devices`

## 2. Flash

```bash
# Boot image (kernel + appended DTB, ramdisk-less) -> 8 MB boot partition.
# It MUST stay under 8 MB or U-Boot rejects the write (error=-27).
fastboot flash boot nexusq-boot-v1.5.0.img

# Root filesystem -> userdata partition. The -S 100M chunking is REQUIRED:
# the 2012 U-Boot has a ~150 MB download buffer and fails silently without it.
fastboot -S 100M flash userdata nexusq-rootfs-v1.5.0-sparse.img
```

**Never run** `fastboot flash bootloader` or touch `xloader` -- that is the
only way to brick the device.

## 3. First boot

1. Unplug power, wait 5 s, plug back in **without** covering the sensor.
2. Watch HDMI: Tux logo -> kernel log -> LightDM login screen (XFCE4).

**Known quirk:** roughly 1 in 3 boots hangs with a black screen (old U-Boot
flakiness, cause not yet found). Just power-cycle again.

Login: user `user`, password `147147` (root has the same password --
**change both** after first login: `passwd`). SSH host keys are generated
on first boot.

## 4. Getting a shell (no keyboard needed)

The Q runs an RNDIS network gadget on its micro-USB port:

1. Connect micro-USB to your PC. A new network interface appears.
2. Give your PC side a static IP:
   `nmcli con add type ethernet ifname <iface> con-name nexusq ipv4.method manual ipv4.addresses 172.16.42.2/24`
3. `ssh user@172.16.42.1`

## 5. WiFi

```bash
ssh root@172.16.42.1
nmcli dev wifi connect "YOUR_SSID" password "YOUR_PASSWORD"
```

The connection persists across reboots. From then on the USB cable is
optional -- find the device on your LAN as hostname `steelhead`.

## What works in v0.1.0

| Subsystem | Status |
|-----------|--------|
| HDMI video + XFCE4 desktop | ✅ |
| WiFi (BCM4330, original calibration) | ✅ |
| Bluetooth | ✅ |
| SSH (USB gadget + WiFi) | ✅ |
| TMP101 temperature sensor | ✅ |
| TAS5713 25 W speaker amp | 🟠 software-verified, listening test pending |
| HDMI audio | 🟠 needs a sink with audio EDID (TV/AVR) |
| NFC (PN544) | 🟠 driver binds, chip untested |
| TOSLINK / SPDIF | ⬜ not wired up yet |
| Ethernet | 🔴 dead hardware on the reference unit |
| TWL6040 codec (headset) | 🔴 dead hardware on the reference unit |
| SMP (2nd CPU core) | 🔴 disabled (U-Boot leaves CPU1 undefined) |

(The two 🔴 hardware items are specific to the project's reference device --
your unit may be healthier. See `PLAN.md` and `HANDOFF.md`.)

## Building from source

Hard requirements discovered the painful way (details in `HANDOFF.md`):

- **Toolchain:** Arm GNU Toolchain **13.3.Rel1** (`arm-none-linux-gnueabihf-`).
  Kernels built with newer GCC (15.x tested) do not boot -- silently.
- **Size ceiling:** zImage + DTB must stay **<= 6.5 MB** or U-Boot will not
  load it from the boot partition.
- Kernel: mainline 6.12.12 + the four patches in `kernel/patches/`,
  config `kernel/configs/steelhead_defconfig`.

```bash
# kernel + dtb
export ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf-
cp kernel/configs/steelhead_defconfig .config && make olddefconfig
make -j$(nproc) zImage dtbs

# boot image
cat arch/arm/boot/zImage arch/arm/boot/dts/ti/omap/omap4-steelhead.dtb > zImage-dtb
python3 make-bootimg.py zImage-dtb boot.img

# on a running device you can skip fastboot entirely:
ssh root@<ip> 'cat > /tmp/boot.img && dd if=/tmp/boot.img of=/dev/mmcblk0p9 bs=1M conv=fsync && systemctl reboot' < boot.img
```

For the full rootfs build, see `docker-build.sh` (pmbootstrap pipeline).
