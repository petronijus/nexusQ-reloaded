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
