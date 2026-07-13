# 2026-07-13 — Onboarding step 1 IMPLEMENTED (13/13 coding tasks) + the CRLF post-mortem

**Status:** all 13 coding tasks of the onboarding step-1 plan
(`docs/superpowers/plans/2026-07-13-onboarding-step1.md`) are executed,
reviewed and pushed — commits **`ae8f499..cb03cf7`** (25 commits on `main`).
**Task 14 (build → flash → HW acceptance → tag) is IN PROGRESS** and continues
on the **Linux machine** (this was the last Windows session before a machine
switch; see HANDOFF.md "WHERE TO CONTINUE"). Nothing here is flashed yet —
the device still runs v1.8.2.

Execution was **subagent-driven**: each task implemented by a worker, reviewed
per-task (with fix rounds), then a final whole-branch review (its catches and
its accepted-risk/backlog triage are recorded below).

## What was built (per component)

### nexusqd r9 — `spin R G B` (setup LED animation)
- New socket command `spin R G B` → rotating-dot setup animation on the manual
  override layer (priority 8), cleared by `auto`/`set`/`breathe`/`off`.
- `userspace/nexusqd/src/spinner.c` — pure deterministic renderer
  (head dot + 8-LED exponential tail, 0.75 rev/s), **host-tested**
  (`tests/test_spinner.c`); 30 ms frame cadence while active.
- Commit `ae8f499`; `pmos/nexusqd` pkgrel 8→**9**.

### nexusq-control r9 — identity + `startSetupMode`
- Device identity file **`/etc/nexusq/device.json`**
  (`{"name": …, "room": …}`): `load_identity()` with resilient fallbacks;
  the name feeds `getDeviceInfo`/mDNS, the room ships as an mDNS TXT
  `room=` record.
- New method **`startSetupMode`**: arms `/run/nexusq-setup.force` + starts
  `nexusq-setupd` (re-provisioning while already on WiFi); **all** failure
  shapes map to error code `unavailable`.
- `librespot-nexusq` wrapper reads the Spotify device name from
  `device.json` (rename during setup → Spotify shows the new name).
- Commits `61fa926`, `c5ced68`, `1d05eeb`; `pmos/nexusq-control` pkgrel 8→**9**.

### NEW package: nexusq-setupd 0.1.0-r0 — BT RFCOMM WiFi provisioning
- `userspace/nexusq-setupd/` + new aport `pmos/nexusq-setupd` +
  `docker-build.sh` staging (Phase 7c3 builds it) + `nexusq.preset`
  `enable nexusq-setupd.service`.
- **SetupCore** (transport-less state machine): `getDeviceInfo`,
  `confirmColor`, `scanNetworks`, `setWifi`, `getNetworkState`, `setName`,
  `setTheme`, `finishSetup`; setup error codes `wrong_password` /
  `not_found` / `timeout`; **the psk is never logged** (sanitized
  SubprocessError handling on the nmcli path); validate-before-side-effects.
- **BlueZ transport**: D-Bus `Profile1` RFCOMM server, service UUID
  **`8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a`**, fixed channel 3, Just-Works
  `Agent1` (accepted risk — documented in PROTOCOL.md §8), 600 s idle
  timeout, crash-restart re-arms via the force flag.
- Lifecycle: `ExecCondition=/usr/bin/nexusq-setup-needed` (runs only when no
  WiFi profile exists OR `/run/nexusq-setup.force` is armed); one-shot per
  trigger (exits after `finishSetup`); `Restart=on-failure`.
- Extra deps (setupd only): `py3-dbus` + `py3-gobject3` (bridge/NFC stay
  stdlib-only).
- **23 host tests** (`python -m unittest`, `tests/test_setupd.py`).
- Commits `6ddf61d`, `62ab560`, `02bc460`, `dc62c45`, `5b70651`.

### nexusq-nfc-send — tap payload = live connection info (backlog item CLOSED)
- The NFC tap payload is no longer a static greeting: **rebuilt per tap** as
  `{"v":1,"bt":<BD_ADDR>,"host":<hostname>,"ip":<current IP>,"prov":<bool>}` —
  this closes the standing "NFC payload = connection info" backlog item
  (open since v1.7.0). Commit `0307430`; `device-google-steelhead`
  pkgrel 43→**44**.
- ⚠️ **Final-review catch (critical):** the unit's `Environment=NQ_NFC_MESSAGE=…`
  line had survived — it overrides `build_payload()` entirely and would have
  dead-ended tap-to-onboard with the old static string. **REMOVED** in
  `af2dec4`; `NQ_NFC_MESSAGE` is now documented in the unit as a manual-test
  override only, kept unset.

### Companion app (Flutter/Android) — the 8-screen setup wizard
- **DeviceTap** NFC payload parsing (`tryParse` never throws on wrong-typed
  fields) + tap routing in `main.dart`: provisioned tap → auto-connect over
  LAN; unprovisioned tap → jump into the wizard with the MAC prefilled.
- Kotlin **BT RFCOMM platform channel** (`nexusq/btsetup`): scan/connect/
  newline-JSON lines; volatile socket, permission re-entrancy, lifecycle
  dispose.
- Dart **BtSetupClient** + **pairingColor parity** with the device — shared
  test vectors `companion/pairing-color-vectors.json` keep the Dart and
  Python implementations bit-identical.
- **Stock-asset pipeline**: `scripts/extract-stock-assets.sh` pulls the
  original Google setup imagery from the stock APKs into
  `companion/app/assets/stock/` (**gitignored** — Google copyright); tracked
  `.keep` placeholders + icon fallbacks keep fresh clones building.
- **Setup wizard**: welcome / cables / find / confirm-color / wifi (with the
  wrong-password path) / name-room / theme / outro (`q_outro.mp4`); entry
  points = NFC tap routing + "Set up new device" in ConnectGate.
- **14 Flutter tests**, `flutter analyze` clean. Debug build **installed on
  the user's Pixel 9 Pro Fold** (wizard reachable; end-to-end run awaits the
  v1.9.0-rc1 device image).
- Commits `2f08e5e`…`8ca26c8` + `af2dec4` fixes.

### Docs / agents landed in-session
- **PROTOCOL.md §8 "Setup transport"** (commit `379e59c`): UUID, Just-Works
  accepted-risk note, envelope reuse, the 8 methods + error codes, lifecycle,
  pairing-color contract; §7 updated for the dynamic payload; setupd README.
- **nexusq-build agent brief** (`afa3101`): the build agent MUST report
  progress to main — phase transitions, 10-min heartbeats, immediate
  error/retry notices.

## The CRLF incident (post-mortem — read this on the Linux machine)

- **What happened:** the Windows worktree was CRLF (`core.autocrlf=true` at
  the system level) and the dockerized build reads the **worktree** via the
  mount → `failed to source APKBUILD`, nexusqd build failure.
- **What did NOT happen:** committed blobs were **never CRLF-poisoned** —
  verified **byte-exact from a Linux container** against the repo objects.
  Earlier in-session claims of "poisoned blobs" were **measurement
  artifacts of msys pipe translation** (Git-Bash text-mode pipes rewrote
  LF→CRLF while *measuring*, indicting innocent blobs). Durable lesson:
  **never judge byte content of git objects through an msys pipe** — check
  from a Linux container or with binary-safe tooling.
- **Durable fix (`cb03cf7`):** repo-wide `.gitattributes` forcing LF on text
  + full worktree renormalization — the policy now lives in the REPO, not in
  machine config.
- **On Linux:** after `git pull` files may re-checkout; the worktree will be
  LF; nothing else to do.

## Windows-machine environment note (NOT a repo issue)

Repeated **null-byte file corruption** was found on the Windows machine
during the session (Python stdlib files, the pub cache, Android SDK files) —
pattern consistent with disk/filesystem trouble. Recommendation to the user:
`chkdsk` + SMART check. Unrelated to this repository (all repo content is
verified from git objects).

## Remaining work (plan Task 14 — the Linux machine)

1. `git pull` (main at `cb03cf7`+).
2. **Build v1.9.0-rc1** via the standard dockerized pipeline. Pre-build:
   populate the `firmware/` overlay + `private/access` (the v1.8.1 lesson).
   Verification additions on the mounted rootfs: `/usr/bin/nexusq-setupd` +
   `/usr/bin/nexusq-setup-needed` + `nexusq-setupd.service` + its preset
   `enable` line; `py3-dbus` + `py3-gobject3` installed; `nexusq-nfc.service`
   **without** `NQ_NFC_MESSAGE`; `/var/lib/systemd/linger/root` present.
3. **Flash** (the device was left in fastboot 2026-07-13; may need
   re-entering).
4. **HW acceptance = plan Task 14 Step 3** (6 numbered checks): baked-profile
   boot must NOT enter setup mode + diag sweep; delete wifi + reboot → setup
   mode (LED spin + discoverable); full wizard from the Pixel incl. a
   deliberately wrong password; NFC tap in both provisioned states;
   `startSetupMode` re-provisioning; final diag sweep. Final-review
   recommendation: exercise the fresh-boot path with the baked
   `wifi.nmconnection` REMOVED.
5. Propose tag **v1.9.0** (user approves).

## Backlog from the final-review triage (post-v1.9.0)

- `bad_params` (PROTOCOL §3 doc) vs `bad_request` (impl) naming unification.
- "Add second device" entry point in the connected app UI.
- Kotlin `bad_args` message polish; Dart `dispose()` in-flight completers;
  `fakeAsync` timeout tests; `ACTION_DISCOVERY_FINISHED` progress bar.
- nmcli psk-in-argv → keyfile hardening; `sendLine` write-lock.
