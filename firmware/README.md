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
> (`14:7d:c5:3a:35:b5` on the reference unit, Murata OUI) always wins, and the
> `macaddr=` in `bcmdhd.cal` (`00:90:4c:c5:12:38`) is a Broadcom placeholder
> anyway (stock injected the factory `f8:8f:ca:20:48:e1` outside the firmware
> path). Do NOT try to set the MAC here.
>
> ⚠️ **OPEN (found 2026-07-15): the factory MAC `f8:8f:ca:20:48:e1` is injected
> NOWHERE.** wlan0 runs the **OTP MAC** on air, and its DHCP lease carries an
> **empty hostname**. (Was documented here as "the WiFi identity is pinned at the
> **NetworkManager layer**" via `cloned-mac-address` in the baked profile /
> `scripts/gen-wifi-profile.sh` — that pinning is **not in effect** on the live
> device as of 2026-07-15, so the claim is retired pending a fix.) **Look DHCP leases
> up by the OTP MAC `14:7d:c5:3a:35:b5`** — `f8:8f:ca:20:48:e1` is stale, and the
> empty hostname means you cannot find it by name either. The **BT** MAC is
> fine (DTS `local-bd-address`). Tracked in `CHANGELOG.md` known issues (v1.9.0 +
> v1.10.0).
>
> **Root cause (2026-07-15) — still NOT fixed as of v1.10.0.**
> `scripts/gen-wifi-profile.sh` pins `cloned-mac-address` into the **BAKED dev
> profile ONLY**. The profile `nexusq-setupd` creates during onboarding via
> `nmcli connection add` does **not** carry it, so NM falls back to `permanent` =
> the OTP MAC. The pinning was never wrong *in the baked path* — it simply has **no
> reach** over an onboarded profile. **The device has no source for the factory MAC
> at all**: nvram's `macaddr=` is a generic Broadcom default (above), and nothing
> else on the box knows `f8:8f:ca:20:48:e1`. **The proper fix mirrors BT**: a
> `local-mac-address` in the **DTS wifi node** — after a stock audit
> (`stock-parity-auditor`), since stock injected it from outside the firmware path
> and we do not yet know from where.

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

> ⚠️ **Machine-setup gotcha (bit the first v1.8.1 flash, 2026-07-12):** the empty
> fallback is SILENT for the maintainer too — on a build machine where the
> gitignored `./firmware/` overlay was never populated, the image builds and
> flashes fine but boots with **no `wlan0` and no BT** (`/lib/firmware/brcm/`
> empty). On any new build machine stage the blobs FIRST
> (`cp private/firmware/bcm4330.hcd private/firmware/bcmdhd.cal firmware/`, or
> `./scripts/setup-firmware.sh`), and verify the build log says
> **`Staged BCM4330 firmware`** — not the empty fallback. The image verification
> gate now also checks the rootfs `/lib/firmware/brcm/` contents (the final
> v1.8.1 rebuild verified `brcmfmac4330-sdio.bin`/`.txt` + `BCM4330B1.hcd` + the
> `google,steelhead` aliases present).
