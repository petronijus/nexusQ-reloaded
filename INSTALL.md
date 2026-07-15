# Nexus Q Reloaded -- Install Guide (v1.10.0)

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
- release artifacts: `nexusq-boot-v1.10.0.img` (~5.3 MiB), `nexusq-rootfs-v1.10.0-sparse.img.zst`
  (~2.1 GiB raw; the rootfs is zstd-compressed for distribution -- install `zstd` to
  decompress it, see step 2), `nexusq-v1.10.0.sha256`
  - **The v1.10.0 kernel is UNCHANGED from v1.8.2/v1.9.0** (`6.12.12-r43`, `#44`; 42
    patches through 0042 -- incl. the crackle fixes 0041/0042 and the 0040 BT UART
    `max-speed` fix -- plus the `conservative` default-governor defconfig). v1.10.0 is
    a **userspace** release: BT pairing from the app in **both** directions + the
    HDMI desktop on demand (device **r48**, **btagent r3**, **nexusq-control r10**,
    setupd r4, nexusqd r10, firmware r2). At ~5.3 MiB the boot image is still **well
    under the 8 MB boot partition**. Coming from **v1.8.2 or v1.9.0** you strictly
    only need `userdata`; coming from **any earlier release** flash **both**. Flashing
    both is always safe. Verify against `nexusq-v1.10.0.sha256`.

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
# The v1.10.0 kernel is UNCHANGED from v1.8.2/v1.9.0 (~5.3 MiB; 42 patches through
# 0042 + the conservative-governor defconfig). Flashing it is a no-op from v1.8.2 or
# v1.9.0, required from anything older, and always safe.
fastboot flash boot nexusq-boot-v1.10.0.img

# Root filesystem -> userdata partition. The -S 100M chunking is REQUIRED:
# the 2012 U-Boot has a ~150 MB download buffer and fails silently without it.
# As of v1.6.0 the sparse rootfs is all-RAW (byte-exact): EVERY block is written,
# zeros included, so the flash is correct even though U-Boot never erases userdata.
# (A previous DONT_CARE-chunked sparse skipped zero blocks and left STALE eMMC data
#  behind, which re-corrupted libpython and crashed python3 -- see CHANGELOG 1.6.0.)
# The rootfs ships zstd-compressed (~2.08 GiB raw) -- decompress it first:
zstd -d nexusq-rootfs-v1.10.0-sparse.img.zst   # -> nexusq-rootfs-v1.10.0-sparse.img
fastboot -S 100M flash userdata nexusq-rootfs-v1.10.0-sparse.img
```

Expect boot + userdata to take **~3 minutes** total (the chunked userdata flash
is ~23 chunks, each reporting OKAY — measured 2026-07-03).

**After any reflash:** the device regenerates its SSH host key on first boot,
so your next `ssh` will warn about a changed key. Clear the stale entries
first: `ssh-keygen -R 172.16.42.1` (and `10.42.0.2` / the device's WiFi IP).

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

### 5a. The normal path -- app-driven onboarding (since v1.9.0)

An **unprovisioned** device arms setup mode on its own at boot: the ring spins
blue, and the adapter goes discoverable + pairable. Then, from the companion app:

1. **Tap the phone on the dome** (NFC). The app jumps straight into the setup
   wizard. (No NFC? Use "Set up new device" and pick the Q from the BT list --
   that list is only the fallback.)
2. Confirm the pairing colour -> the phone bonds (Just-Works, no PIN -- **nothing
   attached to the Q can answer a prompt**, so any PIN/confirm dialog means
   something is wrong; see the blueman note below).
3. Pick your SSID, enter the password -> the Q joins. **Wrong password -> the ring
   turns red.**
4. Name / room / theme -> outro. The Q closes its pairing window automatically.

The BT setup link is **bonded and encrypted** (`RequireAuthentication=True`), so
the WiFi PSK never crosses the air in cleartext, and it is never logged.

> ⚠️ **A fresh flash of a DEV image does NOT arm setup mode.** `docker-build.sh`
> bakes `private/access/wifi.nmconnection` into dev images, so the device
> **self-provisions** and `nexusq-setup-needed` correctly reports "not needed".
> **`PUBLIC_RELEASE=1` images do not bake it and DO run onboarding.** To exercise
> onboarding on a dev image you must currently delete the baked profile by hand --
> a `NEXUSQ_NO_WIFI=1` build flag (skip only the wifi bake, keep the ssh keys) is
> an **open task, not yet written**.

> The pairing window **fails CLOSED** (setupd r4 / btagent r1): only a
> *successful* nmcli listing no WiFi profile counts as unprovisioned, so a
> transient NetworkManager wobble can no longer drop a **provisioned** device into
> a discoverable + pairable setup mode.

> ⚠️ **Do not start `blueman-applet` by hand** -- its **DisplayYesNo** agent forces
> SSP into Numeric Comparison, raising a confirm dialog on the HDMI desktop that
> nothing attached to the Q can click, and **every bond then times out**. It is
> suppressed by default since device r47 (the *package* stays for
> `blueman-manager` on demand).

To **re-provision** an already-configured Q (new SSID, moved house), call
`startSetupMode` over the LAN bridge from the app -- it re-arms setup mode
without a reflash. Tested + passing 2026-07-15.

### 5b. Fallback / recovery -- join by hand

Still fully supported, and the only route if you have no phone, no NFC, or a
dev image that self-provisioned:

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
> ignores the nvram `macaddr=` too).
>
> ⚠️ **Correction (2026-07-15): the factory MAC is NOT pinned.** This note used to
> claim the v1.6.6 image pins the **factory MAC** at the NM layer instead
> (`cloned-mac-address=F8:8F:CA:20:48:E1` in the baked profile /
> `scripts/gen-wifi-profile.sh`), "verified on air 2026-07-03". A v1.9.0 diag sweep
> found that MAC is **injected nowhere**: wlan0 runs the **OTP MAC**
> `14:7d:c5:3a:35:b5` (Murata OUI), and the DHCP lease carries an **empty
> hostname**. **Look your lease up by the OTP MAC** — `f8:8f:ca:20:48:e1` is stale.
> (The **BT** MAC is fine — pinned in the DTS via `local-bd-address`.) **Open bug**,
> tracked under CHANGELOG v1.9.0 + v1.10.0 known issues.
>
> **Root cause (2026-07-15, still NOT fixed as of v1.10.0):**
> `scripts/gen-wifi-profile.sh` pins `cloned-mac-address` into the **BAKED dev
> profile only**. The profile `nexusq-setupd` creates during onboarding via
> `nmcli connection add` does **not**, so NM falls back to `permanent` = the OTP MAC.
> **The device has no source for the factory MAC at all** (nvram carries a generic
> Broadcom default). The proper fix mirrors BT: a `local-mac-address` in the DTS wifi
> node, after a stock audit.

## What works

| Subsystem | Status |
|-----------|--------|
| HDMI video + **LXQt / Wayland** desktop (labwc + Pixman) | ✅ **on demand since v1.10.0** — toggle it from the app's Devices screen (`setDesktop`); it idles the GPU/display path and heats the sphere, so it is on-request. Audio survives a desktop stop (device **r48** bakes the `user` linger — without it, stopping the desktop would kill PA + librespot). _(This row said "XFCE4" until 2026-07-15; the desktop has been LXQt/Wayland since v1.6.12.)_ |
| **BT pairing from the app — both directions** | ✅ **v1.10.0** — the Q has no screen or input device, so **the app is its Bluetooth settings panel**. **Inbound**: pair a phone for music. **Outbound**: the Q scans for and pairs a **mouse / keyboard** (verified on a Logitech MX Master 4 + MX Keys — Just Works, no passkey; HID reaches `/dev/input` via uhid). Pair a keyboard + mouse and switch the desktop on → the appliance is a computer |
| WiFi (BCM4330, original calibration) | ✅ working, stable IP since v1.6.6 (stable on-air MAC = the chip's **OTP MAC** `14:7d:c5:3a:35:b5`; the "factory MAC pinned at the NM layer" claim is **retired-pending-fix** — that MAC is injected nowhere, and the lease has an empty hostname, so look it up by the OTP MAC · 2026-07-15). **Characterized 2026-07-07: 5 GHz is healthy, not flaky** (0 % loss, 2.6 ms jitter); bulk **~34 Mbit/s is a HW ceiling** of the 1×1 802.11n chip, not a bug — use ethernet (`10.42.0.2`) for bulk transfers |
| App-driven onboarding (NFC → BT → WiFi) | ✅ **v1.9.0** — an unprovisioned device arms setup mode itself; tap the phone on the dome → bonded/encrypted BT RFCOMM → WiFi join → name/room/theme. See §5a. ⚠️ a **dev** image self-provisions (baked WiFi) and will NOT onboard; `PUBLIC_RELEASE=1` images do |
| Bluetooth (BCM4330, A2DP sink) | ✅ **reliable A2DP since v1.8.0** — root-caused 2026-07-09: the DTS had no BT UART `max-speed`, so hci_bcm never synced the host UART to the BCM4330 firmware baud → HCI frame corruption (`Frame reassembly failed (-84)`), phantom "Connected", dropped links, garbled audio. Fixed by pinning `max-speed = 3000000` (stock value; kernel patch 0040). Pair the phone → the Q is an A2DP sink (phone → BT → PulseAudio → TAS5713) |
| SSH (USB gadget + WiFi) | ✅ |
| TMP101 temperature sensor | ✅ |
| TAS5713 25 W speaker amp | ✅ working (48 kHz; PulseAudio resamples) — the v1.6.0 2× speed bug was fixed in v1.6.1 (kernel patch 0022); the residual playback crackle was CLOSED in v1.8.1 (kernel patches 0041 sDMA read-priority + 0042 DPLL_ABE sys_clkin relock, hardware-verified 2026-07-12) |
| Spotify Connect (librespot) | ✅ working, **baked into the build** (v1.6.1) — advertises "Nexus Q", discovery + auth + streaming over WiFi |
| LED music visualizer | ✅ working (v1.6.2) — reacts to Spotify playback via the `nexusq` audio tee → snd-aloop loopback → nexusqd FFT/beat; v1.6.5 adds a 1 Hz idle AVR keepalive (the ring no longer goes dark after long idle) |
| Companion app / remote control | ✅ working (v1.6.3) — volume, LED theme + brightness, now-playing; via the on-device `nexusq-control` LAN bridge (TCP 45015, mDNS `_nexusq._tcp`, reachable over WiFi since v1.6.5) + a Flutter phone/desktop app (built separately, **not** in the image) |
| HDMI audio | 🟠 needs a sink with audio EDID (TV/AVR) — the omap-hdmi-audio card is a dummy-DAI, so as of v1.6.9 PulseAudio ignores it (`PULSE_IGNORE` udev rule); no more boot-log noise |
| NFC (PN544) | ✅ **fixed 2026-07-03, ships in v1.6.6** — the chip was never dead: the DTS muxed the wrong pads (dpm_emu debug pads instead of `usbb2_ulpitll_dat1/2/3`), found via a stock RAM-boot probe; clean `nfc_en` polarity detect + `nfc0` registers on the v1.6.6-candidate kernel. On v1.6.5 the node is still disabled |
| TOSLINK / SPDIF | ✅ brought up in v1.6.13 (mainline `davinci-mcasp` DIT/IEC958); a selectable PulseAudio output since v1.6.15, pinned to 48 kHz |
| Ethernet (LAN9500A) | ✅ **works from a cold boot since v1.6.8 (task #17 fully closed)** — the "enumeration intermittency" was a pinmux miss (`gpio_1` NENABLE on an unmuxed pad `0x186`, so the chip was never powered); fixed by a DTS pad mux in kernel `#33`, gold-validated from a true cold power-cycle (`eth0` 100Mbps/Full, 0 failed units). NM layer also resolved (baked `eth-lan` DHCP + `eth-direct` static `10.42.0.2` for a direct PC↔Q cable). Note: the chip has no MAC EEPROM, so the hw MAC (and a LAN DHCP lease) is random per boot. On a **pre-v1.6.8 image** `eth0` may be absent on cold boots — power-cycle or use the USB gadget/WiFi |
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
- Kernel: mainline 6.12.12 + the patches in `kernel/patches/` (42 as of kernel
  r43, 2026-07-13), config `kernel/configs/steelhead_defconfig`.
  ⚠️ The steelhead DTS enters the kernel tree **via those patches** (0003 +
  follow-ups) — `kernel/dts/omap4-steelhead.dts` is the reference copy; editing it
  alone does NOT change the built DTB.

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
