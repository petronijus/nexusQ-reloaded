# 2026-09-06 — the picker shows the spheres, and the theme that forgot itself

Companion app 1.18.1+52 (picker with spheres), nexusq-control r37 (persistent
colour theme). Desktop session, picking up the MacBook's handover of the
unreleased 1.18.1.

## 1. What Petr asked for

The MacBook session had built the multi-device picker (the first screen lists
every `_nexusq._tcp` bridge; several wait for a tap) as a plain list: a speaker
icon, the name, `host:port`. Petr wanted to see it on his phone before it went
out. He saw it and said:

> místo ikonky obrázky těch koulí, jako je na homescreen, navíc pokud má nějaká
> z nich nastavenou jinou ambientní barvu, tak aby byla vidět (btw nevím jestli
> je ta ambientní barva persistentní, to by měla, tak to kdyžtak ověř)

Two things, then: draw each box the way the home screen does, in its own colour;
and check whether the colour survives a reboot.

## 2. The theme was not persistent — on either side

`nexusq-control` kept the theme only in its state dict: `"theme": "blue"` at
start, `setTheme` sent the `breathe R G B` to nexusqd and remembered the name in
memory. nexusqd's breathing override is in-memory too (`control.c`, `CTL_BREATHE`).
Consequences, both verified by reading the code and the device:

- every reboot came back breathing the stock blue;
- every restart of the bridge — which is every OTA of it — reset the *reported*
  theme to `blue` while the ring kept the old hue. The app showed "Blue" on a
  ring breathing warm until the next tap re-synced them.

Fix (r37, `userspace/nexusq-control/nexusq-control`):

- `THEME_CONF_PATH = /etc/nexusq/theme.json`, `_theme_load()` (returns `None`
  for no file, a torn file, or a theme this build does not know) and
  `_theme_save()` (tempfile + `os.replace`, the EQ file's discipline).
- `setTheme` persists **after** nexusqd accepted the command and raises
  `unavailable` if the write fails — the ring changed, but the app is told the
  choice would not survive a reboot. The bridge's initial state reads the file,
  so the first `getState` after a bridge restart is already right.
- `theme_restore_thread` at start: if a file exists, send the theme's commands
  to nexusqd, retrying every 5 s for a minute while the socket comes up. No
  file → nothing sent: a box that was never themed keeps nexusqd's stock idle
  screensaver, which is a different animation from a forced `breathe` in blue.
- `tests/test_theme.py`, 8 tests: round trip, no temp file left behind, torn /
  unknown / non-dict files read as "never themed", every shipped theme loads,
  a failed write is `unavailable`, the restore sends exactly the stored
  theme's commands, sends nothing without a file, retries until nexusqd
  answers. 95/95 in the control suite.

PROTOCOL.md (`setTheme` row + the LED-ring paragraph) and the bridge README
record it.

## 3. The picker draws the spheres

`DeviceSphere` is the home screen's widget (the sphere PNG with the lit slot
clipped into its transparent band). The picker now renders each found device as
a column: sphere (132 px) lit in the box's theme, the name in `nameColorFor`
(the Off theme's black falls back to white, exactly as on the home screen),
`host:port` dim underneath. The generic icon above the list is gone once there
is a list; the search ring stays while searching.

Where the theme comes from: mDNS carries `name=`, `room=`, `model=` and no
theme, and a TXT record would only be as fresh as the last re-announce. So the
gate asks each box itself the moment it resolves: `lib/protocol/glance.dart`,
`glanceAt(Discovered)` — connect, `getState`, close, 3 s, never throws.
`DeviceGlance` takes only `theme` and `muted` (`on` = the home screen's rule,
`!muted && theme != 'off'`); deliberately **not** `getState.name`, which is the
bridge's start-up snapshot and goes stale after a rename — the mDNS record the
picker already holds is the fresh one.

Behaviour: a row appears dark at once and colours in when the box answers. A
box that never answers stays dark and reads `host:port · not answering`, and
is still tappable: the glance is a picture, not a gate. A `_round` counter
drops answers from a previous "Search again" so a slow box from round one
cannot light round two's row — the test for that was run with the guard removed
and watched fail before it was trusted.

Tests: `ConnectGate` gained a `glance` seam next to `discoverAll` and
`clientFactory`; the widget-test helper injects canned answers by device key.
Without the seam the default glance would dial a socket and leave its timeout
pending under the test clock. Four new tests (theme colours + no icon,
off/muted dark + readable name, not answering + still pickable, the stale
round); 126/126 in the app suite.

## 4. Seen on the phone

Pixel 9 Pro Fold, over Wi-Fi adb (the USB link died on every streamed
install — "write terminated: Protocol error" — so the phone was switched to
`adb tcpip` after a sysfs de-/re-authorise of the port). The demo needed two
boxes on one LAN, which Petr does not have: the desktop advertised a fake
`Nexus Q Sumperak` over Avahi (D-Bus entry group; the Android browse does not
probe endpoints) and ran a stand-in bridge on :45015 answering `getState` with
`theme: warm`. The picker showed the Prague Q blue and the fake one warm, names
in matching colours. Petr: "jo, to se mi moc líbí! to máme hotovo."

## 5. The trap: a built-but-unapproved apk is not held by anything

At ~18:40 the r37 apk — built, waiting for Petr's go-ahead, never approved —
**was published to gh-pages by another session** (`d79ca03`) that was shipping
an unrelated package (`nexusq-mqtt` r5). Not that session's mistake in any
meaningful sense: `publish-ota-repo.sh` takes **the newest build of every
package in `pmos/ota-packages.list`** out of the shared `nexusq-workdir`
volume. It has no idea which of those builds anyone intended to ship. Any
publish, from any session, ships whatever is newest in the volume.

It was rolled back within minutes (`43173cd` serves r36 again) and the apk was
moved to `packages/edge/armv7/.held-unapproved/` rather than deleted. Verified
independently here, not taken on trust:

| check | result |
|---|---|
| what Pages serves | gh-pages HEAD `43173cd`, index lists `nexusq-control 0.1.0-r36` |
| what the device sees | Prague Q after `apk update`: `Installed r36 = Available r36` |
| did any box install it | Prague Q has no `/etc/nexusq/theme.json`, which r37's `setTheme` would create |
| the apk | in `.held-unapproved/`, 38040 bytes, not deleted |
| my source | 4 diff hunks, all the theme change; line 578 (`--machine=user@.host`) untouched |

The cottage Q could not be checked (unreachable from Prague), but nothing
upgrades a device on its own — an OTA is always something a person or the app
starts, and nobody started one in that window.

**The real lesson is not "be careful".** Two sessions sharing one build volume
and one publish script means the volume's contents ARE the release decision,
and nothing in the tooling can currently express "built, not approved". Worth
fixing at the tool level: either `publish-ota-repo.sh` skips anything under a
`.held-*` prefix by name (so a hold is a first-class state, not a convention),
or it takes an explicit package list and refuses to ship a version the caller
did not name. A convention that lives only in a chat message between two
sessions is exactly the kind of guard that fails silently the next time.

## 6. Shipped

Both halves went out the same evening, in the order that keeps a phone from
ever seeing an update it cannot download:

1. `main` pushed (the picker, r37, and the other session's four commits).
2. GitHub release **`app-v1.18.1`** with `nexusq-companion-1.18.1.apk`; the
   asset URL checked for HTTP 200 **before** anything pointed at it.
3. `companion/app-release.json` → **1.18.1 / 52**, pushed and confirmed live on
   raw.githubusercontent — that bump is what makes installed apps offer the
   update, which is why it is a separate step after the release exists.
4. `nexusq-control` **r37** released from `.held-unapproved/`, published to
   gh-pages `0873a78` (secrets gate 11/11 clean), and installed on the Prague Q
   with `apk upgrade --available --ignore linux-google-steelhead` — the app's
   own path.

Persistence verified on the box, not asserted: `setTheme warm` →
`/etc/nexusq/theme.json` reads `{"theme": "warm"}` with no temp file left
behind; `systemctl restart nexusq-control` → `getState` still answers `warm`,
which is exactly the case that used to answer `blue`; and the journal shows
`theme restored from /etc/nexusq/theme.json -> warm`, i.e. the boot path
re-sending it to nexusqd. The Q was then put back on blue, the theme it was
found on. A full reboot was deliberately **not** run: two sink-inputs were
active, so somebody was listening, and the restart exercises the same
`theme_restore_thread` the boot does.

**Open after this session:**

- **iOS build 52.** `release-ios.sh` needs the distribution identity in the
  MacBook's keychain. Until it lands, 1.18.1 is half-released by the both-tracks
  rule (HANDOVER has the steps; do not re-bump the version).
- **The cottage Q is still on control r37's predecessor** (r36). It is on
  another network and was unreachable all evening; it will pick r37 up from the
  app or `apk upgrade` next time it is reachable. Nothing about r37 is urgent
  for it — without a theme file it behaves exactly as before.
- Spotify control end to end and the first real-iPhone run are still unverified
  by a human, unchanged from the MacBook's handover.
