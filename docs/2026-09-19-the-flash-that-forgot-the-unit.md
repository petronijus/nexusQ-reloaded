# The flash that forgot the unit — a per-unit persist store on the `cache` partition (2026-09-19)

**Verdict: "USB Audio" was off on the Prague Q for three days because the
2026-09-16 v1.16.0 flash reset every per-unit setting to the image defaults and
nothing said so. The same flash resets the unit's name, its WiFi profile, its
ssh host keys, its Bluetooth bonds — and since device r102 there is nowhere a
site's own NTP server can live at all. Device r103 ends it: the `cache`
partition (p12, 512 MB, which a flash never writes) carries a per-unit store
that is bind-mounted over the rootfs paths at boot. One copy, nothing to
synchronise, nothing to redo after a flash.**

Follow-on to `docs/2026-08-28-per-unit-bt-wifi-identity.md` (the first unit's
MAC in the shared DTS) and to device r102 (Prague's gateway in the fleet NTP
list): the third instance of one defect, a per-unit value living where the
fleet image lives.

## 1. What was asked, what the journal said

Petr arrived in Prague on the 19th and found USB Audio switched off. The
persistent journal on the Prague Q covers every boot since the 09-16 flash:

| evidence | reading |
|---|---|
| `/home/user/.config/systemd/` mtime | **2026-09-19 21:18:16** — the directory did not exist before |
| `/home/user/.config/{labwc,lxqt}` mtime | 2026-09-16 13:47, the image build; `pulse` 15:20, the first boot |
| `journalctl` for `nexusq-uac2-in` across all 3 boots | first start **21:18:20 on the 19th**, none earlier |
| `nexusq-control` clients | `192.168.20.169` (the phone) connected 21:17; two user-manager reloads 21:18:11 / 21:18:16 = the app's unmask + `enable --now` |

So nothing switched it off. The source toggles are uid-10000 user units whose
enablement lives in `~/.config/systemd/user/default.target.wants/`; `usbaudio`
and `roon` ship default-OFF (`nexusq-control`'s own comment: "a reflash resets
to image defaults"). The flash gave Prague a fresh rootfs, and the toggle was
never put back — the 09-16 session even wrote "that would need the toggle ON".
The `runuser` burst at 21:17:27–32 in the same window is `nexusqd`'s
`nqvol_apply`, one `nq-vol` per touch-ring step: Petr turning the volume, not a
fault.

## 2. What a flash actually touches

```
fastboot flash boot     -> p9   boot
fastboot flash userdata -> p13  rootfs slot A
fastboot oem unlock     -> erases userdata only
```

Everything else on the eMMC survives: p14 `userdata_b` (rootfs slot B), p7
`misc` (the A/B slot marker), p10 `efs` (8 MB), p5 `device_info`, and **p12
`cache`** — 512 MB, stock Android's OTA scratch space, still carrying the
factory's empty ext4 (same UUID as `efs`, a fixed-UUID mkfs), read by nothing
in this OS. That is the store.

## 3. The design

`nq-persist` (device package, `/usr/bin`) plus seven systemd units, all wanted
by `local-fs.target` so everything ordered after `sysinit.target` — the user
manager, NetworkManager, sshd, bluetoothd, timesyncd — sees the unit's own
state without knowing the store exists:

```
nexusq-persist-prepare.service   format p12 as ext4 `nq-persist` ONLY if its label is not
                                 ours; refuse if it is mounted; park writes made under the
                                 unmounted mountpoint in /run/nexusq/persist-shadow
var-lib-nexusq-persist.mount     /dev/disk/by-partlabel/cache -> /var/lib/nexusq/persist
                                 (after systemd-fsck@…cache, which a drop-in orders after prepare)
nexusq-persist-apply.service     seed the store from the rootfs where it is empty (the upgrade
                                 path: the unit's current state becomes the store); merge parked
                                 writes, never over an existing file; render what cannot be
                                 bind-mounted; ConditionPathIsMountPoint=/var/lib/nexusq/persist
home-user-.config-systemd.mount              bind  <- persist/user-systemd    (the source toggles)
etc-NetworkManager-system\x2dconnections.mount bind <- persist/nm-connections  (this unit's WiFi)
var-lib-bluetooth.mount                      bind  <- persist/bluetooth       (adapter state, bonds)
nexusq-persist-hostname.path     PathChanged=/etc/hostname -> nq-persist save-hostname
```

What could not be a bind mount, and why:

- **`/etc/nexusq/device.json`** (name + room) is read by six programs and
  written by two. `/etc/nexusq` also holds package files (`shairport-sync.conf`)
  and a fleet file (`mqtt.json`), so bind-mounting the directory would let a
  stale store copy shadow a newer package file after the next flash. Instead
  the package ships `device.json` as a **symlink** into
  `persist/identity/`, and both writers (`nexusq-control` r46, `nexusq-setupd`
  r5) gained `write_identity()`, which resolves the link and renames the temp
  file over the **target** — the old `os.replace(tmp, link)` would have swapped
  the link for a regular file, "working" until the next flash. Pinned by tests
  on both sides, seen failing against the old writers.
- **`/etc/hostname`** is systemd-hostnamed's file, rewritten atomically, so
  neither a symlink nor a file bind mount survives a rename. Applied from the
  store at boot; every change recorded by the `.path` unit.
- **ssh host keys.** `/etc/ssh` is package territory. The store keeps the keys
  under `persist/ssh/`, and `apply` renders `/run/nexusq/sshd-hostkeys.conf`
  with a `HostKey` line for exactly the keys that exist; the package's
  `sshd_config.d/10-nexusq-persist.conf` says `Include` of that file. Measured
  on the unit's OpenSSH 10.5: `HostKey` lines from an include **replace** the
  defaults, and an include matching nothing is silently nothing — so a unit
  whose store did not mount falls back to `/etc/ssh` rather than to no sshd. On
  a virgin flash `apply` runs before `sshdgenkeys`, so it generates the keys
  itself (`ssh-keygen -A` into a prefix, then moved): the first fingerprint a
  unit ever shows is the one it keeps. **`ssh-keygen -R` after a reflash is
  over.**
- **Site NTP.** `persist/site/ntp-servers` holds the site's IP literal(s);
  `apply` renders `/run/systemd/timesyncd.conf.d/20-nexusq-site-ntp.conf` on
  every boot from that plus the current fleet list. Measured on the unit:
  timesyncd **merges** `NTP=` across drop-ins (a plain `NTP=192.168.20.1` in a
  later file landed *last*), and an empty assignment resets — so the rendered
  file is `NTP=` then `NTP=<site> <fleet minus duplicates>`. Site first, fleet
  after, and a changed fleet list is picked up without touching the store.
  `nq-persist ntp set 192.168.20.1` on Prague gives it its gateway back, which
  is what r102 could not do without a per-site mechanism.
- **NetworkManager's package profiles** `eth-lan` / `eth-direct` moved from
  `/etc/NetworkManager/system-connections` to NM's read-only vendor directory
  `/usr/lib/NetworkManager/system-connections` (keyfile plugin, verified on NM
  1.58 with a probe profile), so the `/etc` directory holds nothing but this
  unit's own networks and is safe to bind-mount. `nmcli c up eth-direct` is
  unchanged.

Deliberately **not** in the store: `machine-id` (PID 1 reads it before any
mount), PulseAudio's saved volumes (a flash resetting the amp to the safe
default is a feature), `authorized_keys` and `mqtt.json` (fleet values, baked
by `docker-build.sh`, the same on every unit).

## 4. Failure modes, in order of preference

Every path is loud and non-fatal for the boot. No partition, or a store that
will not mount → `apply` and the three bind mounts skip on
`ConditionPathIsMountPoint`, the unit boots on its rootfs state exactly as
before r103, `nq-persist status` says `NOT MOUNTED`, sshd is on its `/etc/ssh`
keys. `prepare` never formats a device that is mounted, and never one whose
label is already `nq-persist` (the UUID is the proof in the test). Rootfs A/B:
`nq-rootfs-ab populate` copies with `--one-file-system`, so the store and its
bind mounts are skipped and both slots share one store. `nq-kernel-ota` is
untouched.

The r102 → r103 upgrade on a unit in the field: `.pre-upgrade` moves a plain
`device.json` to the link's target path (under the still-unmounted mountpoint,
so the new symlink serves the old name until the reboot); at the next boot
`prepare` parks it in `/run`, `apply` seeds the store from the rootfs
directories (toggles, WiFi, bonds, keys, hostname) and merges the parked
identity. Tested end to end in
`pmos/device-google-steelhead/tests/test_persist.sh` (48 checks, one
`--privileged` Alpine container, a loop image as the partition), including the
control — the same "flash" without the store loses the toggle — so the
assertion is known to detect the loss.

## 5. What is still open

- **Phase 2:** the A/B initramfs could take the unit's WiFi/BT MAC from the
  store and patch the DTB at boot. Then one generic `boot.img` serves every
  unit and the hand DTB patch at flash time
  (`docs/2026-08-28-per-unit-bt-wifi-identity.md`) goes away.
- The 09-16 open item — does PulseAudio ever open the UAC2 gadget card while
  `alsaloop` holds it — is measurable on Prague now that the toggle is on.
