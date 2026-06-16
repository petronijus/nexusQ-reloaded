# BCM4330 Firmware for Nexus Q

The Broadcom BCM4330 WiFi/Bluetooth chip needs proprietary firmware to operate.

## What ships where

- **WiFi base firmware** (`fw_bcmdhd.bin`, `fw_bcmdhd_apsta.bin`, NVRAM) comes
  from the **`firmware-aosp-broadcom-wlan`** postmarketOS package — it is *not*
  in this repo and is pulled in automatically by the build.
- **WiFi calibration** (`bcmdhd.cal`) and the **Bluetooth patchram**
  (`bcm4330.hcd`) are device-specific blobs recovered from the Nexus Q's
  Android vendor partition. They are **proprietary and not redistributable**, so
  they are **not committed to this public repo**. You provide them yourself.

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

`pmos/firmware-google-steelhead/APKBUILD` installs the calibration into the
rootfs. Its `source=`/`package()` blocks are commented until you've staged the
blob (the package must not carry the proprietary file in a public tree).
