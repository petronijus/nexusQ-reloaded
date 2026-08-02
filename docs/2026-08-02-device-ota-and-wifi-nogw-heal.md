# 2026-08-02 — Device (daemon) OTA proven end-to-end + the WiFi `nogw` heal

Base: v1.11.0 (tagged 2026-07-31); post-v1.11.0 dev line. Commits:
`46ad5ef` (`feat(nexusqd): progress bar + mute-LED blink primitives (r11)`),
`f8477e9` (`feat(control): device OTA with LED narration + install lock (r20)`),
`6cb6dc5` (`fix(wifi): watchdog heals the associated-but-dead 'nogw' wedge (r61)`).
Packages: `nexusqd` **r11**, `nexusq-control` **r20**, `device-google-steelhead`
**r61**. Companion app **1.9.1 → 1.9.5** (own track; manifest `version 1.9.5` /
`versionCode 24`).

## The milestone: the Q updated its own daemons over the air, live

The device-daemon OTA path (scaffolded earlier — `nexusq-control` r17, the signed
GitHub-Pages apk repo) was **proven end-to-end on hardware this session**: the
reference Q was taken **`nexusqd` r10 / `nexusq-control` r16 → r11 / r19** entirely
via the app's *Nexus Q* update button — no reflash, no adb, no ssh. The apk repo on
`gh-pages` (`https://petronijus.github.io/nexusQ-reloaded/nexusq`) currently serves
**nexusqd r11 + nexusq-control r19**; **r20 is pending a republish**
(`scripts/publish-ota-repo.sh`). Images **v1.11.5** and **v1.11.6** were built
(v1.11.6 = control r19 + the watchdog fix baked); **v1.11.7** (control r20 + nexusqd
r11) is building.

### Trust model (unchanged, load-bearing)
Only the four small daemons are OTA'd — `nexusq-control`, `nexusqd`,
`nexusq-btagent`, `nexusq-setupd` (`OTA_PACKAGES`). The device already trusts the
`pmos@local` build key (baked in `/etc/apk/keys` at image build), so `apk` installs
our **signed** packages straight from the repo — no new key, no reflash.
`device-google-steelhead` is ~191 MB (it bundles the unpacked glibc-rt Roon base),
over GitHub's 100 MB file limit, so config OTA still waits on a glibc-rt split; the
**kernel** stays a fastboot flash (fastboot-over-ssh, the "System" track).

## nexusqd r11 — two LED primitives for the narration (commit `46ad5ef`)

- **`progress <pct> [R G B]`** — a **determinate** ring bar: lights `pct`% of the
  32-LED ring in the colour (default `#0099CC` = `0 153 204`), the rest a dim (`/12`)
  track. A manual mode, cleared by `set` / `off` / `breathe` / `spin` / `auto`.
  Range-checked (0–100). `CTL_PROGRESS`.
- **`mblink R G B | mblink stop`** — an **autonomous** blink of the dedicated **MUTE
  LED** ("software update available"). The daemon owns the 0.5 s cadence, so the
  blink survives the ring being busy (a theme/colour change or the music visualiser
  never touch the mute LED). It is a **persistent** indicator: suppressed only while
  the mute LED is doing its real job (an actual mute, or a volume overlay) and it
  **resumes** the moment that ends; only `mblink stop` (or an explicit `mute R G B`
  override) clears it. `CTL_MBLINK`. Parser + range tests added (`test_control.c`).

## nexusq-control r20 — device OTA with LED narration + install lock (commit `f8477e9`)

The LEDs narrate the whole flow, and — deliberately — **an update that merely waits
is signalled ONLY on the mute LED**; the ring stays on the user's theme until an
install actually runs.

- **`checkNexusUpdate`** — `_ensure_ota_repo()` (idempotently appends the OTA repo to
  `/etc/apk/repositories`), `apk update`, `apk list --upgradable` / `--installed`;
  returns `{packages:[{name,installed,available,upgradable}], updateAvailable, repo}`.
  The bridge then blinks the mute LED **amber** (`mblink 255 140 0`) when
  `updateAvailable`, else `mblink stop`.
- **`installNexusUpdate`** — guarded by `_nexus_install_lock` (a `threading.Lock`):
  a concurrent install is **rejected `Err("busy")`** instead of racing a second
  `apk upgrade`. (A flaky link had the app resend the call; with per-request threads
  that launched a second `apk upgrade` over the first, which got killed = `Terminated`
  when control then restarted itself.) On the winning call: `mblink stop` (clear the
  "available" blink) → start `_OtaProgress` (a background thread easing the
  determinate `progress` ring bar asymptotically toward a soft cap of 92 %, since apk
  emits no machine-readable percentage; `finish()` snaps it to 100 %) → `apk upgrade`
  the daemons. The install returns which packages actually changed (`upgraded`), and
  the **tail runs off-thread** (`_finish_nexus_update`) so the ack ships first:
  restart any changed non-control daemon, flash the ring **green** (`set 0 255 0`, a
  good-pairing success), restore the theme (`THEME_CMDS`), then
  `systemctl --no-block restart nexusq-control` — which drops the app link; the app
  reconnects to the new build.

This is **PROTOCOL §12** ("system OTA"), now written up with the method table, the
LED narration, and the signed-repo trust model; the nexusqd LED vocabulary
(`progress`, `mblink`) is added to the §4 LED-ring command list.

## Companion app 1.9.1 → 1.9.5 (own track; commits `919a333`..`e4c468d`)

The device OTA and app OTA both landed usable UI this session. Fixes, in order:

- **App-OTA download progress bar** fixed in stages: handle a **missing
  `Content-Length`** on GitHub's redirected asset (indeterminate + MB shown);
  **throttle** progress to ~100 updates (was ~10 000 `setState`/download, which pegged
  the UI thread so the bar only painted full at the end); and — the actual visible fix
  — **explicit colours** (dim track vs bright accent), because the Material-3 default
  track blended with the blue fill so a partial bar read as one static blue strip
  while only the % text moved.
- **Update check bypasses GitHub's CDN cache** (`no-cache` header + `?t=`
  cache-buster) — a freshly-pushed manifest read as stale for up to Fastly's 5 min
  `max-age`.
- **A failed update check now shows an error** instead of silently reading as "up to
  date".
- **Settings auto-checks the DEVICE (Nexus Q) update track on open** (was only the app
  track), so the section no longer blanks after navigating away.
- **Device OTA no longer shows a false "failed"** — installing restarts the daemons
  (incl. the control bridge), which drops the app link, so the install call's
  disconnect is **expected**; success is confirmed by **reconnecting and re-checking
  the version** (no pending update == success). The install now shows in-app feedback
  (Installing… title, the upgrading package list, an activity bar, a reconnect note)
  instead of a blank section.

Manifest `companion/app-release.json` now `version 1.9.5` / `versionCode 24`;
releases `app-v1.9.1`..`app-v1.9.5`.

---

## WiFi watchdog r61 — heal the associated-but-dead `nogw` wedge (commit `6cb6dc5`)

**Live-caught this session and healed.** A new wedge shape: `wlan0` **associated**
(strong signal) but NetworkManager stuck in *"getting IP configuration"* — DHCP got
no lease, so the interface has an IP but **no default route** and the LAN is
unreachable (the app just says "reconnecting").

`nexusq-wifi-watchdog` detects wedges by **pinging the default gateway** — but with
no route there **is** no gateway, so it hit the `nogw` branch, which held **`fails=0`**
and therefore **never healed this exact case — the one the watchdog was built for.**

Fix: while associated, a `nogw` now **counts like a bad check** (`fails=$((fails+1))`,
and the heal condition fires on `st = bad` **or** `st = nogw`), triggering the same
`nmcli disconnect/connect wlan0` heal that re-runs DHCP and restores the route. The
health line now carries `"fails"` for the `nogw` state too
(`/var/log/nq-health/wifi-watchdog.jsonl`). This complements the v1.11.0
`brcmfmac roamoff=1` fix (the escan/roam-scan wedge) — a different failure mode that
the watchdog now also covers.

## State summary

- OTA repo (gh-pages): **nexusqd r11 + nexusq-control r19** live; **r20 pending
  republish**.
- Baked images this session: **v1.11.5**, **v1.11.6** (control r19 + watchdog fix);
  **v1.11.7** (control r20 + nexusqd r11) building.
- App track: **1.9.5** (versionCode 24).
- Last public tag: **v1.11.0** (2026-07-31) — the v1.11.x dev line is untagged.
