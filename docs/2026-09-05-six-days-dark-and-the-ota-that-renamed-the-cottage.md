# 2026-09-05 — six days dark on a healthy box, and the OTA that renamed the cottage

The cottage Q (`nexus-q-sumperak`, serial `AW1S12251417`) had been unreachable
since 2026-08-30 23:30. Petr power-cycled it at 17:43 CEST today and the session
that followed found two defects, shipped two fixes (device **r93**,
`nexusq-kernel-ota` **r5**, OTA-only — no new image) and brought the unit onto the
fleet key and the current release. A third finding, on the MacBook, stopped the
publish from regressing every other package in the fleet.

Nothing here crashed. Every fault was a piece of software doing exactly what it
was written to do.

---

## 1. Six days dark — the watchdog stranded the device it was healing

### What the box said about itself

The journal's boot `-1` runs **2026-08-29 14:15 → 2026-09-05 17:43** with no
oops, no reboot, no gap. `nexusq-mqtt` logged `connection lost: Network
unreachable` **once a minute** for the whole outage; the health sampler kept
sampling. The box was fine. It had no link.

### The heal that killed the link

`nexusq-wifi-watchdog`'s `heal()` was:

```sh
nmcli device disconnect wlan0; sleep 2; nmcli device connect wlan0
```

NetworkManager's audit log for the last heal:

```
23:30:09  device-disconnect ... result="success"
23:30:12  connection-add-activate ... result="fail"
          reason="A 'wireless' setting is required if no AP path was given."
```

and the kernel, six seconds later:

```
[...] brcmf_escan_timeout: timer expired
```

`nmcli device connect wlan0` with no profile named activates "the best available
network" — which needs the SSID in NM's scan cache. The cache was empty (the
`escan` had just timed out), so `connect` failed. That alone would be a blip. What
made it permanent is a property of `nmcli device disconnect` that the watchdog did
not account for: **it blocks NM's autoconnect on that device until the next
explicit connect or a reboot.** NM would never re-associate on its own, and the
watchdog's `down` branch — by design, "NM owns re-association" — did nothing.

The watchdog's own JSONL log: **16 536 `st:down` lines** after the last heal, zero
heal or reconnect events. The script on the device was byte-identical to the
repo's — this was not drift, it was the design.

### The heal storm before it

The last heal was not unusual; it was the 122nd. Between **2026-08-29 23:08** and
**2026-08-30 23:30** the log shows **122 heals**, one every ~5–12 min, each with the
same shape:

```
st:bad  loss:100  sig:-42..-45      (associated, strong, TX dead)
heal_result  loss_after:0           (bounce fixes it, every time)
```

The first heal is timestamped **14 s before** the 2026-08-29 23:08:45 profile fix
that changed the WiFi MAC on the live interface from the cloned `f8:8f:ca:20:48:e1`
to the permanent `f8:8f:ca:05:1f:11`
(`docs/2026-08-29-mqtt-at-the-cottage-and-a-cloned-mac.md`, applied as
`cloned-mac-address=permanent` + reconnect). In the 9 hours **before** 23:08 that
day: no heals. After today's reboots, with the MAC set from boot: **0 bad checks**.

**Open question, not answered today:** whether changing the BCM4330's MAC on a live
interface leaves the chip/firmware in a state that produces the recurring TX wedge
(100 % loss at −42 dBm, cleared by a bounce). The correlation is exact; the
mechanism is not established. If a per-unit MAC ever has to be changed at runtime
again, watch `wifi-watchdog.jsonl` for the pattern, and prefer a reboot.

Also on the record from the same window: the unit was switched from static
`<old-static-ip>` to **DHCP** on 2026-08-30 09:09/09:46 (profile backup
`.bak-dhcp`), for the librespot zeroconf fix (commit `314fdd5`). It now takes
`<dhcp-lease>` and resolves as **`nexus-q-sumperak.local`**. Cottage LAN is
`<cottage-lan>/22`, gateway `<cottage-gateway>`, DietPi broker `<cottage-pi>`.

### Fix — device r93: a `reconnect` path

`pmos/device-google-steelhead/nexusq-wifi-watchdog`:

- New pure function **`down_action <nm-state> <consecutive-downs> [threshold]`**
  (`TESTABLE` marker) decides what a non-associated wlan0 gets:
  - NM state **30** (disconnected) or **120** (failed, which NM turns into 30) for
    **`NQ_WIFI_DOWNS`** consecutive checks (default **4** ≈ 2 min at 30 s) →
    `reconnect`; fewer → `wait`;
  - **10/20** (unmanaged/unavailable — radio off, driver gone), **40–110**
    (NM mid-activation) or **blank** (NM not answering) → `leave`, and the down
    count resets. Reconnecting into those would fight NM.
- **`reconnect()`**: `nmcli device wifi rescan ifname wlan0` → `nmcli device
  connect wlan0` (which is also what clears the autoconnect block) → check
  `assoc`; one retry. Shares **`HEAL_COOLDOWN`** with `heal()`, so neither can
  storm.
- **`heal()`** now uses the same `connect_wlan` — rescan before connect, retry
  once — so an empty scan cache no longer turns a heal into an outage.
- JSONL: new events **`reconnect`** (`nm`, `downs`, `sig`) and
  **`reconnect_result`** (`assoc`, `loss_after`, `gw`); **`heal_result`** gains
  **`assoc`** (`yes`/`no`); every **`down`** line carries **`nm`** (NM state) and
  **`downs`** (consecutive count); the `start` line records `downs_to_reconnect`.
  A heal followed by silence can no longer be mistaken for a heal that worked.

Test: `pmos/device-google-steelhead/tests/test_wifi_watchdog_down_action.sh` —
**16 pass** (every NM state × below/at/above threshold, the blank state, a custom
threshold).

---

## 2. The kernel OTA renamed the unit

### Bringing the cottage Q onto the fleet key and the current release

It trusted only `pmos@local-6a913e9e` (the v1.13.0 image's key,
`docs/2026-08-29-ota-key-drift.md` step 3). Steps, all today:

1. `pmos/ota-signing-key.rsa.pub` → `/etc/apk/keys/pmos@local-6a42e957.rsa.pub`.
2. `apk upgrade --available --ignore linux-google-steelhead` — **121 packages**;
   device **r87 → r92**, `nexusq-control` r33 → r35, `nexusq-kernel-ota` r3 → r4.
   The access-file migration stashed and restored `authorized_keys`; its sha256 and
   the WiFi profile's sha256 were identical before and after. `mkinitfs` ran;
   slot A untouched (md5 unchanged).
3. `nq-kernel-ota stage-latest` → `6.18.48-r0`, **6 711 296 B** staged with the
   **958 080 B** initramfs carried over. `NQ_KOTA_YES=1 nq-kernel-ota try` →
   trial boot → autopromote **"healthy after 10s"** → apk reconciled → `dmesg`
   0 errors, 2 CPUs.

Then:

```
wlan0             f8:8f:ca:20:48:e1
bluetoothctl list F8:8F:CA:20:49:E5
```

Prague's identity, on both radios. The MQTT `node_id` would have collided again
exactly as on 2026-08-29.

### Why

Per-unit identity exists **only as a flash-time byte patch of the DTB** appended to
the boot image (`docs/2026-08-28-per-unit-bt-wifi-identity.md`). The kernel apk's
DTB carries the DTS's first-unit values. `nq-kernel-ota` carried the booting
slot's **ramdisk** onto the new kernel — "reality against reality" — but not its
**identity**, and nothing else could: the apk is the same for every unit.

### Repair on the day (hand-carried DTB)

The 6.12 `slot-a-backup.img` (written by `stage` before it overwrote anything)
was the source of truth. A python byte patch of slot A's image: both properties
found **exactly once** in the DTB, `local-mac-address` → `f8 8f ca 05 1f 11`,
`local-bd-address` → `9c ac 73 ca 8f f8` (reversed, as the DT stores it), the
Android header's SHA1 id recomputed, **exactly 26 differing bytes** against the
unpatched image (3 + 3 payload + 20 id) — the same invariant as the 2026-08-28
recipe. `NQ_KOTA_RELEASE=6.18.48-r0 nq-kernel-ota stage <img>` → `try` →
autopromote →

```
wifi=f8:8f:ca:05:1f:11 bt=f8:8f:ca:73:ac:9c
slot A md5 4ee9c080…  == slot B md5 4ee9c080…
```

### Fix — nexusq-kernel-ota r5: the identity is carried like the ramdisk

`userspace/nexusq-kernel-ota/nq-kernel-ota`:

- **`fdt_tool`** — a python FDT walker (no `dtc` on the device). `load()` accepts an
  Android boot image, a raw boot partition or a bare `.dtb`; in an image it scans
  the kernel for `d00dfeed` and takes the hit whose `totalsize` **ends exactly at
  the end of the kernel** — the first hit is a decoy inside the zImage. `props()`
  walks the structure block and returns every property by name with its absolute
  offset.
- **`identity_of <what>`** → `wifi=… bt=…`. **`carry_identity <src> <dst.dtb>`**
  byte-patches the 6 + 6 bytes; it **refuses** unless each side holds exactly one
  6-byte `local-mac-address` and one `local-bd-address` — a guess would rename a
  unit as surely as doing nothing. The blob's length and layout are unchanged.
- **`stage-apk`** calls `carry_identity "$BOOT_SLOT" "$_dtb"` before packing and
  **dies** if it cannot (`NQ_KOTA_NO_IDENTITY=1` overrides, for a DTB that
  deliberately has no such properties).
- **`status`** prints the identity of both slots. New subcommands
  **`identity [image|partition|dtb]`** (default: the boot slot) and
  **`carry-identity <src> <dst.dtb>`** (the manual form of what fixed the box).
  Usage text now also lists `stage-apk`/`stage-latest`, which it never had.

Test: `pmos/nexusq-kernel-ota/tests/test_identity_carry.sh` — **17 pass**. It
builds synthetic FDTs and boot images with a decoy `d00dfeed` planted in the
zImage, and proves: the decoy is skipped, exactly the identity bytes move
(**6 differing bytes** in the DTB, since both units share the `f8:8f:ca` OUI),
the ethernet node's `mac-address` decoy is untouched, the destination length is
unchanged, a second run is a no-op, a boot-image destination is refused,
duplicate or missing properties (on either side) abort with nothing written, and
`identity` prints `?` for what it cannot find rather than a guess.
(`NQ_KOTA_NO_IDENTITY=1` is a `stage-apk` branch and is not covered by this test.)

---

## 3. Publishing from the MacBook without regressing the fleet

The fixes had to ship from the MacBook (the desktop was not in reach). Its
`nexusq-workdir` volume held **every OTA package signed by the retired
`pmos@local-6a93112c`** and **no kernel newer than `6.12.12-r52`**.
`scripts/publish-ota-repo.sh` publishes "the newest apk of each package in the
volume", so an `OTA_PACKAGES_ONLY` build of two packages would have published a
fleet-signed index over ten apks every device rejects as `UNTRUSTED` — and
`apk upgrade --available` (what the app's *System* button runs) **re-installs any
package whose repo copy differs**, so the whole transaction would have failed on
every box, not just skipped one. Plus a kernel payload rolled back a release.

Two changes:

- **`scripts/seed-ota-volume.sh`** (new): reads the published `APKINDEX.tar.gz`,
  downloads each listed apk, verifies its `.SIGN.RSA.<fleet key>` member, and
  places it in the volume's `packages/edge/armv7` chowned to the repo dir's owner
  (pmbootstrap's uid 12345). A same-name file signed by another key — or any
  **newer** foreign-signed build that would win `sort -V` — is moved into
  `.retired-<key>/`; nothing is deleted. Idempotent. Run today on the MacBook:
  **`seeded=11 retired=7`**.
- **`publish-ota-repo.sh`** gains a **per-apk signature gate** before `apk index`:
  every apk about to be published must carry `.SIGN.RSA.<fleet key>.rsa.pub`, or
  the publish stops and names the file. The index signature alone never protected
  against this; devices verify each apk.

The build was then started on the MacBook (arm64 host, Docker 29.7.2):

```sh
docker run --privileged -e OTA_PACKAGES_ONLY=1 \
  -e OTA_PACKAGES="device-google-steelhead nexusq-kernel-ota" \
  -v "$PWD":/src:ro -v nexusq-output:/tmp/output \
  -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap nexusq-builder /src/docker-build.sh
```

followed by `scripts/publish-ota-repo.sh`. This note describes the procedure; the
publish result is not claimed here (the build was still running when this was
written — check the published index for `device-google-steelhead-1.0-r93` and
`nexusq-kernel-ota-0.1.0-r5`).

**Procedure for any machine that publishes OTA from now on:**
`install-fleet-signing-key.sh` (once) → `seed-ota-volume.sh` (once, and after any
gap) → `OTA_PACKAGES_ONLY=1` build → `publish-ota-repo.sh` (now fails closed on a
foreign signature).

---

## State of the cottage Q at the end of the session

| | |
|---|---|
| hostname / address | `nexus-q-sumperak.local`, DHCP (`<dhcp-lease>`; static `<old-static-ip>` gone since 2026-08-30) |
| trusts | `pmos@local-6a42e957` (fleet) — can OTA |
| userspace | device **r92** (r93 pending publish), control r35, kernel-ota r4 (r5 pending) |
| kernel | **6.18.48-r0** in both slots, md5 `4ee9c080…` |
| identity | `wifi=f8:8f:ca:05:1f:11 bt=f8:8f:ca:73:ac:9c` — its own |
| watchdog | 0 bad checks since the reboots; still the r92 script until r93 lands |

## What is still open

- The **live-MAC-change → TX wedge** correlation (§1). Unexplained.
- The watchdog cannot help a unit that is *already* stranded on r92 — it needs a
  reboot or a hand `nmcli device connect wlan0` once, then r93 keeps it from
  happening again.
- `checkSystemUpdate` still filters the kernel out (by design); a kernel reaches
  a device only via `nq-kernel-ota` over ssh, and that is the path that now
  carries identity.
