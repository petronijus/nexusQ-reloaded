# 2026-07-06 — v1.6.9 boot-log cleanup: gkr-pam + HDMI-audio noise silenced

Cosmetic-only follow-up to the (already clean) v1.6.8 boot. **No functional
change.** Device pkg **r23**, kernel **unchanged** `6.12.12-r32` (uname `#33`).
A v1.6.9 PUBLIC build + release is in progress separately. Commits: `e155ec9`
(r22, gkr + first HDMI attempt), `f4462a1` (r23, HDMI udev rule corrected).

## What was left on the v1.6.8 boot

After the ethernet cold-init fix (v1.6.8, task #17), the boot was clean (0 failed
units) except three residual log-noise lines, none functional:

- **U6** `gkr-pam: couldn't unlock the login keyring` — every key-based ssh login.
- **U4 (HDMI half)** PulseAudio `module-alsa-card: Failed to find a working
  profile` on the `omap-hdmi-audio` card — every boot.
- **U5** `bluetoothd: Failed to set default system config for hci0` — every boot.

## Fixes

### U6 gkr-pam — FIXED (root cause, not masked)

`/etc/pam.d/base-auth` + `base-session` now shadow the Alpine base files to drop
the desktop-keyring PAM lines (the session-phase `auto_start` was the noisy one).

- gnome-keyring stays **installed** — it is a hard dependency of
  nm-applet/gvfs/webkit — but nothing on this appliance uses the user keyring.
- `pam_systemd` / `pam_rundir` (→ `XDG_RUNTIME_DIR`) are preserved; every
  base-session line is `-session optional`, so a stale copy can never block login.
- **Verified:** 0 gkr lines across 4 fresh logins, `loginctl` sessions intact.

### U4 HDMI-audio — FIXED, r22 → r23 correction

The `omap-hdmi-audio` ALSA card is a `snd-soc-dummy-dai` with no real IEC958
routing — not a usable sink (device audio is TAS5713 + snd-aloop; HDMI is desktop
video only). A `PULSE_IGNORE` udev rule tells PulseAudio to skip it.

- **r22 (rejected in acceptance):** pinned `KERNEL=="card1"`. The ALSA card index
  is **probe-order dependent** — HDMI enumerated as `card2` that boot, so the rule
  tagged the tas5713 card (id mismatch → no-op) and the real HDMI card was never
  tagged; PA still failed `module-alsa-card` on it.
- **r23 (accepted):** match the backing **platform device** instead —
  `SUBSYSTEM=="sound", KERNEL=="card*", KERNELS=="omap-hdmi-audio.1.auto"`.
  `KERNELS=` walks the parent chain to the stable platform name, independent of
  the card number.
- **Verified on r23** via `udevadm test`: `PULSE_IGNORE=1` lands only on the HDMI
  card (not Loopback or tas5713); after a PA restart the HDMI card no longer
  appears in `pactl list cards`. **0 module-alsa-card errors.**

### U5 bluetoothd — left DOCUMENTED-BENIGN

bluez sends `MGMT_OP_SET_DEF_SYSTEM_CONFIG` regardless of `main.conf` and the
BCM4330B1 rejects the batch, but the controller initialises and works
(`Powered: yes`). No clean suppression exists — kept as a known-benign one-liner.

## Lesson

**ALSA card indices are probe-order dependent.** A per-card udev rule
(`PULSE_IGNORE` and any similar per-card tagging) MUST match by backing device
(`KERNELS=`) or card id — **never** by a `cardN` index. The r22 rejection was
exactly this trap.

## Acceptance on r23 (clean fastboot flash) — ACCEPT

- **0 failed systemd units**, gkr=0, HDMI-audio noise=0.
- Ethernet cold-init works (100Mbps/Full), WiFi / NFC / CPU healthy.
- No new regression; residual err/warn = the known-benign set only (B4, B10,
  B16, B21, B22/B23, U5, U7 — see `docs/2026-07-02-boot-error-inventory.md`).
- **Thermal watch-item:** under sustained dual-core load the SoC peaked
  **~98–99 °C** (was 91.8 °C on 2026-07-03) — below the 100 °C passive trip, no
  throttle, but the known thin thermal headroom on this fanless sphere.

## Backlog after v1.6.9 (PROJECTS only — no boot-log items left)

- NFC long-lived userspace (tap-to-pair).
- Deep cpuidle C2+ (the HS secure dispatcher project, services 0x1c/0x1d/0x21).
- The thermal-headroom watch.

---

## Follow-up (2026-07-06): bluetoothd line re-examined + BD_ADDR real issue found

Petr pushed back on "benign" — rightly. Deep investigation (bluetoothd -nd trace):

- **`Failed to set default system config for hci0` is genuinely cosmetic, and
  the earlier description was WRONG**: bluez does NOT send MGMT_OP_SET_DEF_SYSTEM_CONFIG
  and the controller does NOT reject it. `/etc/bluetooth/main.conf` is empty (all
  section headers, zero keys), so `set_def_system_config()` builds an empty TLV,
  `mgmt_send_tlv()` returns 0, and bluez logs "Failed" though nothing was sent.
  All params use sane firmware defaults. BT fully works: scan found 33 devices,
  discoverable toggles, A2DP/AVRCP/HFP/PBAP/MAP/GATT profiles registered, LE
  central+peripheral (5 adv instances). To make the LINE disappear via a real
  (non-masking) change: ship a main.conf with a couple of sane default keys so
  the TLV is non-empty and the call succeeds.

- **REAL ISSUE found: BD_ADDR `43:30:A0:00:00:00`** — a Broadcom BCM4330 placeholder
  baked in BCM4330B1.hcd: (a) NON-UNIQUE — every flashed Nexus Q reports it
  (pairing-record collisions with multiple units), (b) MALFORMED — MSB 0x43 has
  the group/multicast bit set, so it's an invalid unicast public address (stacks
  may refuse/mishandle bonding). Our DT bluetooth node has no `local-bd-address`;
  stock injected the real per-device BT MAC `f8:8f:ca:20:49:e5` via the
  `board_steelhead_bluetooth.btaddr=` cmdline.
  FIX (stock-parity, DTS): add to the `bluetooth { }` node —
    `local-bd-address = [e5 49 20 ca 8f f8];`  (stock f8:8f:ca:20:49:e5, DT LE order)
  The brcm,bcm4330-bt serdev driver / btbcm issues the vendor Write_BD_ADDR
  (0xFC01) at setup. Verify after flash: `bluetoothctl show` → f8:8f:ca:20:49:e5.
  Fallback if the serdev path doesn't program it: a Before=bluetooth.service
  oneshot sending vendor 0xFC01. → fold into the clean-boot batch.

---

## v1.6.10 — the COMPLETE boot-log cleanup (rc1 → rc5): dmesg err/warn EMPTY

Everything above was v1.6.9 (gkr-pam + HDMI-audio). v1.6.9 still booted with
**~15 err/warn lines**. v1.6.10 closes ALL of them with real fixes, two
authorized downgrades, and two honestly-documented external lines. **Final state,
clean-flash acceptance on device pkg `r28` / kernel pkgrel `35` (uname `#36`):
`dmesg -l err,warn` is EMPTY; `journalctl -b -p warning` = ONLY the 3 external
residuals.** Kernel patches 0033–0036; defconfig BPF/ACL/SYN; DTS pmu/gpmc/BD_ADDR;
device pkg r22→r28; new `firmware-google-steelhead` (r1). boot.img grew ~0.3 MB
(the BPF core) — still well under the 8 MB boot partition.

### The rc arc

- **rc1** (`dd391d5`) — the batch of "real fix" lines: DTS `&pmu interrupt-affinity`
  and `&gpmc status=disabled`; defconfig `CONFIG_EXT4_FS_POSIX_ACL=y`; kernel
  patch **0033** (brcmfmac `firmware_request_nowarn` for the OPTIONAL clm/txcap
  blobs — BCM4330 CLM is in-firmware) and patch **0034** (drop the
  `HAVE_HW_BREAKPOINT` arch select — OMAP4460 HS has secure debug locked,
  `enable_monitor_mode()` can never set `DSCR.MDBGEN`, stock 3.0.8 didn't build
  it; zero functional loss); patch **0035** (AUTHORIZED downgrade of the L2C
  aux-modify notice to `pr_debug` — see below); `firmware-google-steelhead` (r1)
  board-named brcmfmac symlinks. Also caught: the `20-nexusq-nsresourced-off.preset`
  as a `/dev/null` mask made `preset-all` log "Unit is masked" — rejected, changed
  to a `disable` preset.
- **rc2** (`fe6045b`) — **BD_ADDR** (DTS `local-bd-address=[e5 49 20 ca 8f f8]`
  + kernel patch **0036**: btbcm now recognizes the `43:30:A0` BCM4330 placeholder
  so the DT address is actually programmed — the DT alone didn't take because
  btbcm only knew the `43:30:B1` signature; without this the controller kept the
  non-unique, group-bit-set placeholder `43:30:A0:00:00:00`) + the residual
  userspace warns (PA autospawn, `50-dns-filter.sh` on `lo`, bluetooth
  `ConfigurationDirectoryMode=0755`).
- **rc3** (`797bdaa`) — `systemd-nsresourced` disabled (preset `disable` +
  post-install removes the enable symlinks — systemd's `configure` had enabled the
  socket before our preset existed and the build's preset pass didn't re-evaluate
  it) + librespot no left-over process (the `ExecStartPre` readiness gate; busybox
  `timeout` leaked an orphaned process).
- **rc4** (`0099e2d`) — **BPF ENABLED** (`CONFIG_BPF_SYSCALL=y` + `BPF_JIT=y` +
  `CGROUP_BPF=y`, plus `CONFIG_SYN_COOKIES=y`) — kills the IP-firewall notice
  class for ALL units (the whack-a-mole insight, below), makes systemd
  IP-address hardening functional, exposes the `unprivileged_bpf_disabled` knob,
  and kills the `tcp_syncookies` warn. The interim per-unit journald/udevd
  no-ipfirewall drop-ins were **removed** — with BPF present the default
  `IPAddressDeny=any` is real hardening. librespot leak finalized.
- **rc5** (`e6e3f56`, r28) — the last fixable line: **bluetoothd `Failed to set
  default system config for hci0`**. Root cause (correcting the v1.6.9
  "documented-benign"): bluez ships `/etc/bluetooth/main.conf` with only section
  headers, so `set_def_system_config()` builds an empty MGMT TLV,
  `mgmt_send_tlv()` returns 0, and bluetoothd logs "Failed" though nothing was
  sent. Fix: an idempotent post-install `sed` populates `[LE]` with sane
  connection-parameter defaults (MinConnectionInterval=7, MaxConnectionInterval=42,
  ConnectionLatency=0, ConnectionSupervisionTimeout=42) so the TLV is non-empty and
  the call succeeds. Verified live on r27: the line disappears, controller stays
  `F8:8F:CA:20:49:E5` / Powered / Pairable.

### L2C aux-modify — the AUTHORIZED exceptional downgrade (not a lazy mask)

Petr approved masking genuinely-unfixable lines only after exhaustive proof. The
L2C `platform/DT modifies aux control register` notice (×2) is emitted because
Linux legitimately enables L2 prefetch via the secure SMC over a ROM value that
leaves prefetch off — **the readback delta IS the prefetch bits**. The immutable
stock bootloader plus the absence of any DT/upstream reconciliation path make it
otherwise unremovable **without a perf regression**. Exhaustively verified
2026-07-06 that the register end-state is identical to stock; patch 0035
downgrades the notice to `pr_debug`.

### Lesson 1 — the whack-a-mole (a "first unit using IP firewalling" notice can't be killed per-unit)

systemd emits `unit configures an IP firewall, but the local system does not
support BPF/cgroup firewalling` **once, for the FIRST unit** that carries
`IPAddressDeny`. Adding a no-ipfirewall drop-in to that unit just moves the line
to the **next** unit with `IPAddressDeny` — endless whack-a-mole. The only two
real outcomes are **BPF present** (the notice never fires, and `IPAddressDeny=any`
becomes functional hardening) or **nothing**. We chose BPF.

### Lesson 2 — NO serial-console access exists on this device

The only paths to the Q are **fastboot + ssh + a stock/our build boot** — there
is **no serial console** (would require opening the sphere / soldering). This
directly blocks **deep cpuidle C2/C3**: the code path is feasible (mainline has
the OMAP4460 HS secure idle dispatcher, services 0x1c/0x1d/0x21), but the
suspend-to-RAM de-risk step **HUNG on resume**, and debugging a resume hang blind
(no console, pstore doesn't survive the DRAM re-init) is impractical. **Deferred
until serial exists** — do not re-attempt C2+ blind.

### The 3 genuinely-external residuals (honest)

1. **eth-lan DHCP fail on a DHCP-less direct PC cable** — environmental;
   `autoconnect=false` would break real-LAN plug-and-play.
2. **kscreen `.service` D-Bus naming** — upstream libkscreen packaging lint (hard
   dep via lxqt-config).
3. **avahi `No NSS support for mDNS`** — `nss-mdns` is not packaged in the
   pmOS/Alpine repos (`apk: no such package`); avahi's publish path (librespot
   Spotify-Connect zeroconf) works fine.

Anything else on a future boot is a **regression**. Standing watch-item: the
**~94–99 °C** sustained-load thermal headroom (not a fault).
