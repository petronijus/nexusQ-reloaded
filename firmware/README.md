# BCM4330 Firmware for Nexus Q

The Broadcom BCM4330 WiFi/Bluetooth chip requires proprietary firmware
blobs to operate. The main firmware is provided by the
`firmware-aosp-broadcom-wlan` package in postmarketOS.

## Device-Specific Calibration

The Nexus Q may have a device-specific calibration file (`bcmdhd.cal`)
that tunes the radio for the device's antenna layout. To extract it:

1. Boot the Nexus Q into its original Android system
2. Connect via ADB:
   ```
   adb pull /system/vendor/firmware/bcmdhd.cal
   ```
3. Place the file in this directory and update the firmware APKBUILD

If the calibration file is unavailable, WiFi will still function using
the generic calibration from `firmware-aosp-broadcom-wlan`, though RF
performance may not be optimal.

## Firmware Files

The `firmware-aosp-broadcom-wlan` package provides:

- `/lib/firmware/postmarketos/bcmdhd/bcm4330/fw_bcmdhd.bin` -- WiFi firmware
- `/lib/firmware/postmarketos/bcmdhd/bcm4330/fw_bcmdhd_apsta.bin` -- AP mode
- NVRAM configuration

The Bluetooth firmware is loaded by the `hci_bcm` driver via the standard
`brcm/BCM4330B1.hcd` file from the `linux-firmware` package.
