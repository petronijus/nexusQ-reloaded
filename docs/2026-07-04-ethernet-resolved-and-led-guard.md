# 2026-07-04 — Ethernet NM layer RESOLVED (task #17 narrowed) + led_frozen static-by-design guard

> **Title correction 2026-07-05:** this doc originally said "task #17 CLOSED" —
> that over-claimed. The **NM retry-loop half of #17 IS fixed** (everything in
> §1 stands and shipped in v1.6.7), but the **LAN9500A enumeration
> intermittency came back** on the v1.6.7 acceptance boots — see the
> **Addendum 2026-07-05** at the bottom. #17 continues for the enumeration
> race only.

Follow-up session to the v1.6.6 acceptance: both open items from
`docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md` are closed. All
findings below are verified on the live device (the `#29`/r20 image). Ships as
`device-google-steelhead` **r21** (in tree, uncommitted at time of writing) +
`scripts/diag/nq-health-report`; everything device-side was ALSO hot-deployed
to the running unit per the bake-successes rule. **No kernel change.**

---

## 1. Ethernet — the "#29 flap" was NetworkManager, not the link. NM LAYER RESOLVED.

### 1a. The hardware/driver layer is FULLY healthy (batch 2b revived it)

With NM detached from `eth0`, the link is rock solid:

- carrier held **90+ s with zero transitions**, `100Mbps/Full`, **0 rx/tx
  errors** — under the `ondemand` governor, which **rules out the cpufreq
  boot-timing theory** for the current image;
- USB autosuspend is already pinned by patch 0006 (root-hub autosuspend off);
- boot enumeration is textbook (`usb 1-1 … 0424:9e00` → `smsc95xx … eth0`).

So the v1.4.0-era "eth dead" regression is genuinely gone since batch 2b; what
remained was purely a configuration-layer artifact.

### 1b. The flap mechanism — a self-arming NM DHCP retry loop

The RJ45 is on the **direct PC↔Nexus cable** (no DHCP server on the wire). NM
auto-generated **"Wired connection 1"** and looped:

1. activate → DHCP → **45 s timeout** → deactivate;
2. deactivation **resets the cloned "stable" MAC** — the MAC write **bounces
   the LAN9500A carrier**;
3. the carrier event **RESETS NM's autoconnect-retries counter** → reactivate;
4. goto 1. Self-arming, **~47 s period, 14 811 journal lines in 29 h**.

This is also what failed `NetworkManager-wait-online.service` — the ONE failed
unit in the `#29` acceptance. (Even with `autoconnect-retries=1` the loop
re-armed at a ~34 s period until the MAC churn was removed — the retry counter
never survived a carrier bounce.)

TX/RX were proven healthy the whole time: the device's DHCP **DISCOVERs were
captured on the host NIC**, and with static IPs ping ran at **0 % loss in both
directions**.

### 1c. The fix — baked eth0 NM profiles (device pkg r21, hot-deployed)

Three files in `pmos/device-google-steelhead/`, installed by the APKBUILD and
already live on the device:

| File | Where | What |
|------|-------|------|
| `eth-no-auto-default.conf` | `/etc/NetworkManager/conf.d/` | `no-auto-default=eth0` — NM never generates "Wired connection 1" again |
| `eth-lan.nmconnection` | `/etc/NetworkManager/system-connections/` | DHCP, `dhcp-timeout=30`, `autoconnect-retries=1`, **`ethernet.cloned-mac-address=permanent`** — the permanent clone is the key: no MAC churn → no carrier bounce → the retry counter finally sticks; on a serverless wire the port goes quiet instead of looping (re-plug triggers a fresh attempt) |
| `eth-direct.nmconnection` | `/etc/NetworkManager/system-connections/` | static **10.42.0.2/24 + 10.0.0.2/24**, `never-default`, `autoconnect=no` — manual activation for the direct-cable workflow (must not fight eth-lan's DHCP on a real LAN) |

**Host side:** persistent NM profile **`eth-direct-host`** created on
petronijus-PC `enp7s0` (10.42.0.1/24 + 10.0.0.1/24, never-default,
autoconnect) — no more ad-hoc `ip addr add` / unmanaged juggling; the
direct-cable workflow needs zero host-side setup.

### 1d. Verified live (2026-07-04)

- eth0 settles at **"disconnected" quietly** — 0 re-activations, carrier
  stable;
- **`nm-online -s` rc=0** — `NetworkManager-wait-online` passes again;
- `nmcli c up eth-direct` → ping **3/3, 0.77 ms avg** → **`ssh root@10.42.0.2`
  works** over the cable.

### 1e. Caveat worth keeping — eth0's hw MAC is RANDOM per boot

The LAN9500A has **no MAC EEPROM**, so the kernel assigns a random MAC every
boot. With `cloned-mac-address=permanent` that random address is what goes on
the wire → **on a real LAN the DHCP lease/IP changes per boot**. If a stable
LAN identity is ever wanted, pin a fixed `cloned-mac-address=XX:…` in
`eth-lan.nmconnection`. (Irrelevant for the direct-cable workflow — eth-direct
is static.)

---

## 2. led_frozen static-by-design guard — SHIPPED

The other open item from the `#29` acceptance (the screensaver locks a static
frame after ~300 s idle and the v1.6.5 keepalive re-commits identical bytes, so
the — now real — frame fingerprint legitimately stops changing on a healthy
idle device → permanent false CRIT).

- **`nq-healthd` (device pkg r21, hot-deployed + service restarted):** emits
  crit `led_frozen` **only when the frozen frame co-fires with distress**
  (`nq_resp=0` or `nq_progress=0` in the same sample); a static frame with a
  healthy daemon emits **info `led_static`** instead. A later responsiveness
  drop is still covered by `nexusqd_hang`.
- **`scripts/diag/nq-health-report`** mirrors the logic: crit only for
  distressed stalled rows, info `led_static` otherwise; the summary splits into
  `led_frozen_events` / `led_static_events`.
- **Regression-tested** on the `nq-captures/20260703-144228/` acceptance
  capture: verdict **CRIT → OK**, with
  `led_static … 25 occasion(s)` as the info finding.

---

## Deployment state _(as of 2026-07-04 — superseded by the Addendum 2026-07-05 below: r21 released as v1.6.7 and flashed)_

- Tree: `device-google-steelhead` **r21** (eth NM files + healthd guard) +
  `scripts/diag/nq-health-report` — uncommitted at time of writing.
- Device: still runs the **r20 image** with these files **hot-deployed** (and
  verified). They are already in the APKBUILD, so the next rebuild+reflash
  bakes them — no regression window.
- Open after this session: the standing B4/B10/B16/B21, U5 (watch), U6, U7,
  PA HDMI-audio UCM profile, deep cpuidle C2+, NFC tag-read test.

---

## NFC live RF test (same day, evening) — FUNCTIONAL

First functional NFC test since the pinmux fix, driven by a minimal
NFC generic-netlink poller (no neard in Alpine repos; constants verified
against `include/uapi/linux/nfc.h`, script kept in the session record):

- **Detection works, repeatedly**: `DEV_UP` + `START_POLL` accepted
  (`pn544_hci_start_poll protocols 0x5e`), and a contactless card on the
  dome produced `NFC_EVENT_TARGETS_FOUND` on every tap across multiple
  sessions (10+ detections). The chip advertises
  Jewel+MIFARE+FeliCa+ISO14443-A/B+NFC-DEP (0x7e).
- **Data exchange works**: raw SHDLC/HCI frames from the card visible in
  dmesg during detection (`... 85 80 08 bf f0 7d ...`) — the 4-byte
  sequence `08 bf f0 7d` is consistent with the card's MIFARE UID.
- **Known-issue found — pn544_hci session-kill fragility**: killing the
  netlink session (test-harness kills, `timeout`) while the device is
  polling or has an active target wedges the chip's HCI state:
  `pn544_hci_i2c: cannot read len byte` → `nfc_dev_up: SE discovery
  failed` → later `START_POLL` returns EREMOTEIO then ENODEV. Driver
  re-bind does NOT recover it (`Unable to register IRQ handler` -22 —
  a separate rebind wart: stale gpio-IRQ config; polarity detect itself
  passes instantly, confirming the pinmux fix). Only a reboot (VEN power
  cycle from clean state) recovers. Normal long-lived userspace (a neard
  port or a small resident NFC service) never does this — the follow-up
  item is that userspace, not a driver fix; the clean NFCID readout demo
  waits for it.

---

## Addendum 2026-07-05 — v1.6.7 RELEASED + FLASHED; enumeration intermittency REOPENS #17 (narrowed)

### v1.6.7 release record

Everything above (device pkg **r21**: baked eth NM profiles + the `led_static`
healthd guard) shipped as **v1.6.7**
(<https://github.com/petronijus/nexusQ-reloaded/releases/tag/v1.6.7>). Kernel
**unchanged**: `6.12.12-r28`, uname `#29-postmarketOS` —
`nexusq-boot-v1.6.7.img` is byte-identical to v1.6.6's boot (md5
`12fba8987364226b2c60aaaf94650557`). Assets: `nexusq-boot-v1.6.7.img` +
`nexusq-rootfs-v1.6.7-sparse.img.zst` + `nexusq-v1.6.7.sha256`
(post-verified). Clean `PUBLIC_RELEASE` build; the no-secrets preflight ran
**rc=0** — the 958bc0a guard held, no `Staged` lines.

### Flashed + ACCEPTED 2026-07-05 (the device now runs the r21 image)

- **3 clean boots, zero failed units every time** — including
  `NetworkManager-wait-online` **green** on all 3 (see the degradation note
  below).
- **`led_static` guard verified live**: 33× info `led_static`, **zero false
  CRIT in 91 samples**.
- NFC clean probe, WiFi factory MAC / `192.168.20.195`, CPU/power nominal
  (1200 MHz @ 1380 mV exact, cpuidle C1).
- The 2026-07-04 hot-deploy is superseded — r21 is **baked and flashed**, no
  regression window.

### The reopen — LAN9500A enumeration intermittency is BACK (task #17 continues, narrowed)

- **0/3 acceptance boots enumerated the chip**: USB `CCS=0`; the patch-0006
  `LAN9500A power-on-reset sequenced` init runs, but the port never shows
  connect — vs **3/3 enumerated boots on 2026-07-03/04 with the
  byte-identical kernel**.
- **NOT cpufreq**: `ondemand` ran on the good boots too. **NOT r21**: r21
  changed only NM config (userspace, post-enumeration). It is a **kernel/ehci
  bring-up race** — the patches 0006/0008/0012 area — and that is the ONLY
  remaining half of task #17. The NM half above stands fixed.
- The `eth-direct` workflow (§1c/§1d) is unaffected **on boots where the chip
  enumerates** — it was verified end-to-end 2026-07-04 on an enumerated boot.
- **Graceful-degradation win**: with the chip absent, the baked profiles keep
  the boot clean — no auto-generated profile, no retry loop, **no failed
  units, wait-online green** — verified across all 3 acceptance boots.

### Housekeeping

- One residual `vdd_mismatch` sampling race: **1/91 samples slipped past the
  r20 freq-hold guard** in the acceptance capture — minor, warn-only; noted in
  `scripts/diag/README.md` known-issues.
