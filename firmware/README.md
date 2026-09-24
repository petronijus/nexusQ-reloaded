# BCM4330 Firmware for Nexus Q

The Broadcom BCM4330 WiFi/Bluetooth chip needs proprietary firmware to operate.

## What ships where

The mainline kernel drives the BCM4330 with **`brcmfmac`** (WiFi) and
**`hci_uart_bcm`** (Bluetooth) — NOT the Android `bcmdhd` driver. Those two want
firmware under `/lib/firmware/brcm/` with very specific names (verified live from
`dmesg` on the device):

| File (in `/lib/firmware/brcm/`) | What | Source (`./firmware/`) | md5 |
|---|---|---|---|
| `brcmfmac4330-sdio.bin` | WiFi firmware, **stock** 5.90.125.0 | `fw_bcmdhd.bin` = stock `system.img:/vendor/firmware/fw_bcmdhd.bin` | `658765a665299744947e99e1f1986d19` |
| `brcmfmac4330-sdio.txt` | WiFi NVRAM / calibration | `bcmdhd.cal` = stock `/etc/wifi/bcmdhd.cal` (already key=value NVRAM) | `f222187eb4c97e47b0f173a270001563` |
| `BCM4330B1.hcd` | Bluetooth patchram for the BCM4330B1 | `bcm4330.hcd` = stock `/vendor/firmware/bcm4330.hcd` | `7e5bb859e33142e94052c76fba23b9e6` |

All three are proprietary: they are not in git and are staged from the private
overlay. `docker-build.sh` and `scripts/setup-firmware.sh` refuse any copy whose
md5 differs.

> ✅ **The WiFi firmware is stock's own since firmware r3 (2026-09-23).** Until then
> we shipped linux-firmware's `brcmfmac4330-sdio.bin` (5.90.195.114, 2013). It
> stopped delivering unicast frames every few minutes (73 % gateway ping loss),
> and that was the recurring "WiFi drops" problem. Stock's 5.90.125.0 runs under
> brcmfmac unchanged, with zero drops in 5.8 h. It costs bulk throughput
> (~13–16 Mbit/s instead of 18–30), which is irrelevant for audio streaming. See
> `../docs/2026-09-23-wifi-unicast-wedge-firmware.md`. Do not "upgrade" back to
> linux-firmware.

Without `brcmfmac4330-sdio.bin` the kernel logs `brcmfmac ... Direct firmware load
... failed ... -2` and there is **no WiFi**; without `BCM4330B1.hcd` it logs
`BCM: firmware Patch file not found` and there is **no Bluetooth**.

> ⚠️ **Use the STEELHEAD `.hcd`, not just any BCM4330B1 blob (corrected 2026-07-14).**
> A wrong board blob was staged through v1.8.2 — *"Proxima BCM4330B1 NoExtLNA"*, build
> 0482, md5 `16db686…` (a different BCM4330B1 board's patchram). The correct Nexus Q
> blob is the **stock steelhead** *"Google Phantasm BCM4330B1"*: **build 0749**, md5
> **`7e5bb859e33142e94052c76fba23b9e6`**, **51813 B**. `bcm4330.hcd` in this overlay
> (and `private/firmware/`) is now the Phantasm blob;
> `firmware-google-steelhead` is **r2**. (The correct blob did not by itself fix the
> BT setup-pairing bug — that was **two userspace bugs**, root-caused 2026-07-15:
> `blueman-applet`'s DisplayYesNo agent hijacking SSP + the app bonding on demand;
> see `../docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`
> — but it IS the right patchram for this device.)

> ℹ️ **The BCM4330 is not the pairing suspect.** SSP bonding + A2DP are verified
> working on this controller (2026-07-09, re-verified 2026-07-15). Any future
> "pairing is broken" symptom is **userspace until proven otherwise** — check for a
> second BlueZ agent (`blueman-applet`) before touching firmware. *Never re-derive a
> hardware limit from a userspace symptom.*

> ℹ️ `firmware-aosp-broadcom-wlan` (a build dependency) ships AOSP's bcmdhd-style
> `fw_bcm4330_*.bin` images under other names; nothing loads them, and the
> dependency is kept only for parity with firmware-samsung-maguro. (The old claim
> that brcmfmac *cannot* use a bcmdhd image was never tested and is wrong. On the
> 4330 both drivers speak BCDC over SDIO, and we now run stock's bcmdhd image.)

brcmfmac also probes board-specific and optional firmware names. These logged
`Direct firmware load ... failed with error -2` at boot (inventory item B4) —
**both silenced in v1.6.10** (the boot log is now clean):

- `brcmfmac4330-sdio.google,steelhead.bin` / `.txt` — a board-specific override
  the driver builds from the DT compatible (`google,steelhead`) and probes
  **before** the generic `.bin`. The `firmware-google-steelhead` aport (r1) now
  **ships board-named symlinks** to the identical generic files (comma is a legal
  filename char), so the board-specific probe succeeds and the `-2` never
  happens.
- `brcmfmac4330-sdio.clm_blob` (regulatory/channel data) and the txcap blob — no
  upstream blob exists for this FWID `01-cafa6b3e` (the regulatory data is baked
  into the firmware), so there is nothing to ship. **Kernel patch 0033** requests
  these OPTIONAL items with `firmware_request_nowarn`, so their absence is silent
  instead of an error. See `../docs/2026-07-02-boot-error-inventory.md` (B4).

> ℹ️ **The nvram `macaddr=` is IGNORED by brcmfmac/the firmware** (proven by a
> live driver-reload test 2026-07-03, re-confirmed 2026-07-16): the chip's OTP MAC
> (`14:7d:c5:3a:35:b5` on the reference unit, Murata OUI) always wins over nvram, and
> the `macaddr=` in `bcmdhd.cal` (`00:90:4c:c5:12:38`) is a Broadcom placeholder
> anyway. Do NOT try to set the MAC via nvram — **it is set in the DTS instead** (see
> below).
>
> ✅ **FIXED in v1.10.1 (2026-07-16) — the factory WiFi MAC is now pinned in the DTS.**
> Kernel patch `0043-ARM-dts-omap4-steelhead-wifi-local-mac-address.patch` (r43 → r44)
> adds `local-mac-address = [f8 8f ca 20 48 e1]` to the `wifi@1` node, **exactly as the
> BT node pins `local-bd-address`**. brcmfmac's `brcmf_of_probe()` reads it via
> `of_get_mac_address()` into `settings->mac` and **programs it over the OTP MAC**, so
> the factory MAC becomes wlan0's **permanent** address at the driver level.
> **Hardware-verified:** `ethtool -P wlan0` reports `f8:8f:ca:20:48:e1` as PERMANENT
> (was the OTP `14:7d:c5:3a:35:b5`). **Lease lookups:** after a **v1.10.1+** flash look
> wlan0 up by the factory `f8:8f:ca:20:48:e1` (router hostname is populated again); on
> **≤ v1.10.0** images the on-air MAC was the OTP `14:7d:c5:3a:35:b5` with an empty
> hostname. Tracked in `CHANGELOG.md` [1.10.1].
>
> **Why DT is the only route (stock-parity chain, 2026-07-15 → fixed 07-16).** Stock got
> the WiFi MAC from the **bootloader cmdline** (`androidboot.wifi_macaddr=`, from the
> per-device efs/factory partition) — a path we cannot reproduce (our U-Boot doesn't
> pass it, `CONFIG_CMDLINE_FORCE=y` discards it). nvram's `macaddr=` is a generic
> Broadcom default (above) and brcmfmac ignores it because the chip has a MAC in OTP.
> So the device has no *runtime* source for the factory MAC — the DTS is it.
> This also **closes the onboarding-profile gap**: the NetworkManager
> `cloned-mac-address` pin (`scripts/gen-wifi-profile.sh`) only reached the **baked dev
> profile**; the profile `nexusq-setupd` creates during onboarding fell back to
> `permanent` = the OTP MAC. With the MAC pinned at the driver, NM `permanent` == the
> factory MAC on **every** profile, so no per-profile clone is needed. The factory MACs
> are consecutive: BT `…49:e5`, WiFi `…48:e1`.

All three blobs are **proprietary and not redistributable**, so they are **not
committed** (gitignored). You provide them yourself (see below).

> ℹ️ **The linux-firmware download is gone (2026-09-23).** From v1.14.1 on,
> `docker-build.sh` fetched `brcmfmac4330-sdio.bin` from a mirror list. That
> blob is the firmware that wedged unicast RX, so a fetch would quietly bring
> the bug back. With the overlay present, a missing or wrong blob is now
> `exit 1`. A public clone without the overlay still gets the empty package
> and a green build.

## Getting the blobs

**Maintainer (private overlay):** the blobs live in the `nexusQ-reloaded-private`
overlay. Clone it into `./private` and stage them into the build tree:

```bash
git clone <nexusQ-reloaded-private> private
./scripts/setup-firmware.sh        # copies private/firmware/* -> firmware/ (gitignored)
```

**Anyone else (extract from the stock factory image):** Google's
`tungsten-ian67k` factory image contains all three in `system.img`. Unsparse it
with `simg2img system.img system.raw.img`, then:

```bash
debugfs -R "dump /vendor/firmware/fw_bcmdhd.bin firmware/fw_bcmdhd.bin" system.raw.img
debugfs -R "dump /vendor/firmware/bcm4330.hcd   firmware/bcm4330.hcd"   system.raw.img
debugfs -R "dump /etc/wifi/bcmdhd.cal           firmware/bcmdhd.cal"    system.raw.img
md5sum firmware/fw_bcmdhd.bin firmware/bcm4330.hcd firmware/bcmdhd.cal   # compare with the table above
```

(On a Q still running Android, `adb pull` of the same paths works too.)

## Packaging

`docker-build.sh` (Phase 6) stages the three blobs into the
`firmware-google-steelhead` aport under the exact driver-requested names
(`BCM4330B1.hcd` from `bcm4330.hcd`, `brcmfmac4330-sdio.txt` from `bcmdhd.cal`,
and `brcmfmac4330-sdio.bin` from `fw_bcmdhd.bin`), each md5-verified, and the
APKBUILD installs them to `/lib/firmware/brcm/`. So you only need to place the
three files in `firmware/`, and the build does the rest.

If the proprietary blobs are **absent** (a public clone without the overlay),
`docker-build.sh` automatically swaps in an **empty** `firmware-google-steelhead`
package so the build still succeeds; WiFi/BT simply come up with no firmware.

> ⚠️ **Machine-setup gotcha (bit the first v1.8.1 flash, 2026-07-12):** the empty
> fallback is SILENT for the maintainer too — on a build machine where the
> gitignored `./firmware/` overlay was never populated, the image builds and
> flashes fine but boots with **no `wlan0` and no BT** (`/lib/firmware/brcm/`
> empty). On any new build machine stage the blobs FIRST
> (`./scripts/setup-firmware.sh`), and verify the build log says
> **`Staged BCM4330 firmware`** — not the empty fallback. The image verification
> gate now also checks the rootfs `/lib/firmware/brcm/` contents (the final
> v1.8.1 rebuild verified `brcmfmac4330-sdio.bin`/`.txt` + `BCM4330B1.hcd` + the
> `google,steelhead` aliases present).
