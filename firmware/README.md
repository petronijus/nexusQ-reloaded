# BCM4330 Firmware for Nexus Q

The Broadcom BCM4330 WiFi/Bluetooth chip needs proprietary firmware to operate.

## What ships where

The mainline kernel drives the BCM4330 with **`brcmfmac`** (WiFi) and
**`hci_uart_bcm`** (Bluetooth) — NOT the Android `bcmdhd` driver. Those two want
firmware under `/lib/firmware/brcm/` with very specific names (verified live from
`dmesg` on the device):

| File (in `/lib/firmware/brcm/`) | What | Source | In git? |
|---|---|---|---|
| `brcmfmac4330-sdio.bin` | brcmfmac WiFi base firmware | upstream **linux-firmware** (redistributable) | no — cached in `./firmware`, else fetched at build time |
| `brcmfmac4330-sdio.txt` | brcmfmac WiFi NVRAM / calibration | the device's `bcmdhd.cal` (already key=value NVRAM) | no — proprietary |
| `BCM4330B1.hcd` | Bluetooth patchram for the BCM4330B1 | the device's vendor BT firmware | no — proprietary |

Without `brcmfmac4330-sdio.bin` the kernel logs `brcmfmac ... Direct firmware load
... failed ... -2` and there is **no WiFi**; without `BCM4330B1.hcd` it logs
`BCM: firmware Patch file not found` and there is **no Bluetooth**.

> ⚠️ `firmware-aosp-broadcom-wlan` (a build dependency) ships the *bcmdhd*-style
> `fw_bcm4330_*.bin` images. **brcmfmac cannot use those** — they are kept only for
> parity. The WiFi firmware that actually loads is `brcmfmac4330-sdio.bin` above.

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
> live driver-reload test 2026-07-03): the chip's OTP MAC
> (`14:7d:c5:3a:35:b5` on the reference unit) always wins, and the `macaddr=`
> in `bcmdhd.cal` is a Broadcom placeholder anyway (stock injected the factory
> `f8:8f:ca:20:48:e1` outside the firmware path). Do NOT try to set the MAC
> here — the WiFi identity is pinned at the **NetworkManager layer**
> (`cloned-mac-address` in the baked profile, `scripts/gen-wifi-profile.sh`).

`bcmdhd.cal` and `bcm4330.hcd` are device-specific, **proprietary and not
redistributable**, so they are **not committed** (gitignored). You provide them
yourself (see below). `brcmfmac4330-sdio.bin` is redistributable; it is gitignored
too but `docker-build.sh` will fetch it from upstream linux-firmware if it is not
already cached in `./firmware`.

## Getting the blobs

**Maintainer (private overlay):** the blobs live in the `nexusQ-reloaded-private`
overlay. Clone it into `./private` and stage them into the build tree:

```bash
git clone <nexusQ-reloaded-private> private
./scripts/setup-firmware.sh        # copies private/firmware/* -> firmware/ (gitignored)
```

**Anyone else (extract from your own device):** boot the Nexus Q into its
original Android system and pull the files over ADB:

```bash
adb pull /system/vendor/firmware/bcmdhd.cal firmware/bcmdhd.cal
# the BCM4330 BT .hcd patchram lives alongside the vendor BT firmware
```

Place them at `firmware/bcmdhd.cal` and `firmware/bcm4330.hcd` (both gitignored).
Without the calibration, WiFi still works on generic defaults (RF performance
may be sub-optimal); without the `.hcd`, Bluetooth won't come up.

## Packaging

`docker-build.sh` (Phase 6) stages the three blobs into the
`firmware-google-steelhead` aport under the exact driver-requested names
(`BCM4330B1.hcd`, `brcmfmac4330-sdio.txt` from `bcmdhd.cal`, and
`brcmfmac4330-sdio.bin` from the local cache or upstream linux-firmware), and the
APKBUILD installs them to `/lib/firmware/brcm/`. So you only need to place
`firmware/bcmdhd.cal` and `firmware/bcm4330.hcd` — the build does the rest.

If the proprietary blobs are **absent** (a public clone without the overlay),
`docker-build.sh` automatically swaps in an **empty** `firmware-google-steelhead`
package so the build still succeeds; WiFi/BT simply come up with no firmware.
