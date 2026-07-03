# Nexus Q Reloaded -- Install Guide (v1.6.5)

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
- release artifacts: `nexusq-boot-v1.6.5.img` (5.0 MiB), `nexusq-rootfs-v1.6.5-sparse.img.zst`
  (~2.08 GiB raw; the rootfs is zstd-compressed for distribution -- install `zstd` to
  decompress it, see step 2), `nexusq-v1.6.5.sha256`
  - **`nexusq-boot-v1.6.5.img` is byte-identical to v1.6.2/v1.6.3's boot** (the kernel is
    unchanged; md5 `36a3dec2c4a493710dffa18c4d796236`). If one of those boots is already on
    the device you can **flash only userdata** and skip the boot step below.

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
# (Identical to v1.6.2/v1.6.3's boot -- skip this line if one is already flashed.)
fastboot flash boot nexusq-boot-v1.6.5.img

# Root filesystem -> userdata partition. The -S 100M chunking is REQUIRED:
# the 2012 U-Boot has a ~150 MB download buffer and fails silently without it.
# As of v1.6.0 the sparse rootfs is all-RAW (byte-exact): EVERY block is written,
# zeros included, so the flash is correct even though U-Boot never erases userdata.
# (A previous DONT_CARE-chunked sparse skipped zero blocks and left STALE eMMC data
#  behind, which re-corrupted libpython and crashed python3 -- see CHANGELOG 1.6.0.)
# The rootfs ships zstd-compressed (~2.08 GiB raw) -- decompress it first:
zstd -d nexusq-rootfs-v1.6.5-sparse.img.zst   # -> nexusq-rootfs-v1.6.5-sparse.img
fastboot -S 100M flash userdata nexusq-rootfs-v1.6.5-sparse.img
```

Expect boot + userdata to take **~3 minutes** total (the chunked userdata flash
is ~23 chunks, each reporting OKAY — measured 2026-07-03).

**After any reflash:** the device regenerates its SSH host key on first boot,
so your next `ssh` will warn about a changed key. Clear the stale entries
first: `ssh-keygen -R 172.16.42.1` (and the device's WiFi IP).

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
ssh user@172.16.42.1
sudo nmcli dev wifi connect "YOUR_SSID" password "YOUR_PASSWORD"
```

> Note (2026-07-02, updated 2026-07-03): on the **v1.6.5 release image** connect
> as `user@`, not `root@` — `ssh root@172.16.42.1` fails (root's authorized key
> is not baked in; escalate with `sudo`). The fix — the build bakes
> `private/access/authorized_keys` into `/root/.ssh` + `/etc/skel/.ssh` — is
> **verified on device 2026-07-03** (key-based `root@` works over gadget AND
> WiFi) and ships in v1.6.6. Public builds without the private overlay still
> have no baked key.

The connection persists across reboots. From then on the USB cable is
optional -- find the device on your LAN as hostname `steelhead`.

> Note (2026-07-02, updated 2026-07-03): on the v1.6.5 image the WiFi **IP
> changes every boot** — NetworkManager uses a randomized locally-administered
> MAC, so each boot pulls a fresh DHCP lease. Find the current IP in your
> router's leases by hostname `steelhead`. **Fixed + verified on device
> 2026-07-03** (`wifi-stable-mac.conf`, `cloned-mac-address=permanent`) — ships
> in v1.6.6; the stable on-air MAC is the WiFi chip's **OTP MAC** (on the
> reference unit `14:7d:c5:3a:35:b5`), not the factory-label MAC — brcmfmac
> never reads the factory calibration MAC (a live driver-reload test proved it
> ignores the nvram `macaddr=` too). The v1.6.6 image therefore pins the
> **factory MAC** at the NM layer instead
> (`cloned-mac-address=F8:8F:CA:20:48:E1` in the baked profile /
> `scripts/gen-wifi-profile.sh`).

## What works in v0.1.0

| Subsystem | Status |
|-----------|--------|
| HDMI video + XFCE4 desktop | ✅ |
| WiFi (BCM4330, original calibration) | ✅ working — the 2026-07-02 "dead" verdict was wrong: the DHCP **IP had moved** (NM randomized MAC → fresh lease per boot; see the note in §5). Stable-MAC fix **verified on device 2026-07-03** (ships in v1.6.6) |
| Bluetooth | ✅ |
| SSH (USB gadget + WiFi) | ✅ |
| TMP101 temperature sensor | ✅ |
| TAS5713 25 W speaker amp | ✅ working (24/48 kHz; 44.1 k is resampled to 48 k via the `nexusq` ALSA PCM) — the v1.6.0 2× speed bug was fixed in v1.6.1 (kernel patch 0022) |
| Spotify Connect (librespot) | ✅ working, **baked into the build** (v1.6.1) — advertises "Nexus Q", discovery + auth + streaming over WiFi |
| LED music visualizer | ✅ working (v1.6.2) — reacts to Spotify playback via the `nexusq` audio tee → snd-aloop loopback → nexusqd FFT/beat; v1.6.5 adds a 1 Hz idle AVR keepalive (the ring no longer goes dark after long idle) |
| Companion app / remote control | ✅ working (v1.6.3) — volume, LED theme + brightness, now-playing; via the on-device `nexusq-control` LAN bridge (TCP 45015, mDNS `_nexusq._tcp`, reachable over WiFi since v1.6.5) + a Flutter phone/desktop app (built separately, **not** in the image) |
| HDMI audio | 🟠 needs a sink with audio EDID (TV/AVR) |
| NFC (PN544) | 🟠 under investigation — no i2c ACK on the reference unit (2026-07-02), but the "dead hardware" verdict was **retracted 2026-07-03** (software parity with stock is complete, cause unexplained); DTS node disabled meanwhile |
| TOSLINK / SPDIF | ⬜ not wired up yet |
| Ethernet (LAN9500A) | 🟠 **not** dead HW — fixed v1.1.0/v1.3.0, currently down on cpufreq builds (v1.4.0 boot-timing regression, fix tracked 1.4.1; re-confirmed still down 2026-07-03) |
| TWL6040 codec (headset) | ⚪ not populated/unused on steelhead (corrected 2026-07-03 — the stock kernel never drove it; no headset path by design, was wrongly "dead hardware") |
| SMP (2nd CPU core) | ✅ dual-core works (v1.2.0; `nproc=2`) |

(The 🔴 items are specific to the project's reference device -- your unit
may be healthier. The table above predates the current release; see `CHANGELOG.md`,
`PLAN.md` and `HANDOFF.md` for the up-to-date status.)

## Building from source

Hard requirements discovered the painful way (details in `HANDOFF.md`):

- **Toolchain:** the shipping kernel is now built with **Alpine GCC 15.2** via the
  pmbootstrap pipeline (`docker-build.sh`) and **boots fine** (verified on device
  2026-06-28: `/proc/version` = `cc (Alpine 15.2.0) 15.2.0`). The earlier
  "Arm GNU Toolchain 13.3.Rel1 only; GCC 15.x silently does not boot" rule applied
  to a hand-cross-compiled out-of-tree build and is **superseded** for this path.
  If you hand-build out of tree and hit a black screen, the 13.3 toolchain
  (`arm-none-linux-gnueabihf-`) is still a known-good fallback.
- **Size ceiling:** zImage + DTB must stay **<= 8 MB** (the boot partition; U-Boot
  rejects a larger write with `error=-27`). LZMA compression keeps the dual-core
  SMP image comfortably under it.
- Kernel: mainline 6.12.12 + the 31 patches in `kernel/patches/`,
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
