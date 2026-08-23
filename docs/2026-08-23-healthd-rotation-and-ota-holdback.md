# The telemetry outage: one field fix and two of our bugs (device r80)

2026-08-23. Home Assistant had lost the Q. Working the outage backwards turned
up three independent causes stacked on top of each other: the known DFS-channel
WiFi issue (fixed at the router), a log-rotation leak in the new C `nq-healthd`
(fixed, device **r80**), and an OTA repo that had been silently refusing to
upgrade the device past **r77** (fixed in `scripts/publish-ota-repo.sh`).

## 1. The Q was off the network — DFS ch100, resolved at the router

The 2026-08-20 finding (`docs/2026-08-20-rescue-initramfs-and-ramdisk-address.md`,
"The Q cannot see its 5 GHz AP") stood exactly as recorded: the AP had
auto-selected **channel 100 / 5500 MHz**, and the BCM4330 (nvram `ccode=US`,
world regdomain on `phy#0`) does not report UNII-2C/DFS at all — the Q scans
5 GHz only up to 5320 MHz.

Petr pinned the router's 5 GHz radio to **channel 36**, as recommended. The Q
re-associated on its own: **−52 dBm, ch36 / 5180 MHz**. With a route again,
timesyncd fixed the clock — it had been sitting in **year 2000** the whole
offline stretch (no RTC, no NTP off the USB link) — and MQTT reconnected.

## 2. But telemetry stayed degraded: `healthd_fresh:false` with healthd running

Back online, the broker showed `nexusq/health/state` publishing — with
**`healthd_fresh:false`**, no temp/freq/governor, and HA's "Health sampler"
problem sensor raised. `nq-healthd.service` was active and sampling.

The evidence on disk told the story:

    /var/log/nq-health/health.jsonl     — absent
    /var/log/nq-health/health.jsonl.1   — 25 MB and growing

### Root cause: `rotate_if_big()` renamed the file but kept the open stream

The C rewrite (device **r77**, 2026-08-20) carried over the shell daemon's
rotation *policy* (rename to `.1` past `maxbytes` = 4 MiB, checked every 12
ticks) but not its *mechanics*. The shell appended via a fresh `>>` redirect
every sample, so a rename was always followed by a clean recreate. The C daemon
holds one `FILE *out` open across samples — `rename()` moves the **inode**, the
stream follows it, and the `if (!out) out = fopen(logpath, "ae")` reopen never
fires because `out` is still valid. Net effect, forever after the first
rotation:

- every sample appends to `health.jsonl.1`, now **unbounded** (rotation stats
  `logpath`, which no longer exists, so it never triggers again);
- `health.jsonl` is never recreated, so `nexusq-mqtt` (which reads and
  `stat()`s `HEALTH_PATH` = `/var/log/nq-health/health.jsonl`) reports
  `healthd_fresh:false` and drops every healthd-sourced field.

A bug window of r77–r79; harmless before r77.

### Fix (r80)

`rotate_if_big(FILE **outp)` now `fclose()`s and NULLs the stream after a
successful rename, so the next sample's reopen creates a fresh `logpath` —
readers stat the path, so the path must be what the daemon writes. Fixed in
`userspace/nq-healthd/nq-healthd.c` **and** `pmos/device-google-steelhead/nq-healthd.c`
(the two copies are kept in sync), `device-google-steelhead` pkgrel 79→**80**,
package-only rebuild, OTA-published. **Verified live: `healthd_fresh:true` on
the broker**, temp/freq/governor back in HA.

## 3. And the upgrade path itself was broken: the r77 hold-back

Shipping r80 exposed the third bug: on the device, `apk add --upgrade
device-google-steelhead` completed **without error — and kept r77**.

`apk policy device-google-steelhead` showed r80 available in the repo; forcing
the version made apk say why:

    apk add device-google-steelhead=1.0-r80
    → unsatisfiable: requires nexusq-rootfs-ab

`device-google-steelhead` has depended on **`nexusq-rootfs-ab`** since the A/B
rootfs work (r77/r78, 2026-08-20) — and `scripts/publish-ota-repo.sh` had never
been taught about the new aport: its `OTA_PACKAGES` list didn't include it, so
the repo offered r78+ with a dependency it could not satisfy. apk's `--upgrade`
treats that as "nothing to do", not as an error: **every device in the field was
silently frozen at r77**, which is precisely the release range carrying the
rotation bug above.

Fix: `nexusq-rootfs-ab` added to `OTA_PACKAGES`, repo republished, device
upgraded r77→**r80** and verified.

### The lesson, stated as a rule

**Any new runtime `depends=` of an OTA-shipped package must be added to
`publish-ota-repo.sh` `OTA_PACKAGES` in the same change.** The failure mode is
the worst kind — no error anywhere: the build succeeds, the publish succeeds,
`apk add --upgrade` on the device exits 0, and the fleet just stops updating.
The diagnostic pair that surfaces it: `apk policy <pkg>` (is the new rel even
offered?) then `apk add <pkg>=<ver>` (force the version → apk finally prints
the unsatisfiable dependency).

## Also published

`nexusq-kernel-ota` **0.1.0-r3** (the 2026-08-20 packer-takes-a-ramdisk +
promote-unit ordering fixes) had been sitting built in the workdir since the
r79 build; it went to the OTA repo in the same republish.

## State after

Device **r80** live (`healthd_fresh:true`), kernel-ota **r3** and rootfs-ab
**r1** published, WiFi on ch36 at −52 dBm, clock synced, HA telemetry whole
again. No image/flash change — everything above shipped over the air, which is
rather the point of having fixed the OTA repo.
