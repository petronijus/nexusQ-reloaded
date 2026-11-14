# 2026-11-14 — Spotify drops the connection: three minutes of silence, then 0 % volume

The cottage Q (`nexus-q-sumperak`, v2.1.2, librespot 0.8.0-r0 from Alpine
testing) lost Spotify while Petr was listening, did not come back by itself,
and when he started it again by hand the volume was 0.

## What the journal shows

```
17:05:52 librespot_core::session  ERROR Connection to server closed.
17:07:49 NetworkManager           dhcp4 (wlan0): new lease, address=<unchanged>   (hourly renewal, same address)
17:08:45 librespot_connect::spirc WARN  unexpected shutdown
17:08:46 librespot                WARN  Spirc shut down unexpectedly
17:08:47 librespot_core::session  INFO  Connecting to AP "ap-gew4.spotify.com:443"
17:08:48 librespot_core::session  INFO  Authenticated as '…' !
17:08:49 nexusqd                  audio silent
17:09:36 librespot_connect::spirc INFO  delayed volume update … volume is now 5899   (Petr turning it up)
```

- The network was fine: no WiFi or NetworkManager event around 17:05; the
  DHCP line is the hourly renewal of the same address.
- The track that was playing carried on until 17:08:49: its audio comes from
  the CDN over its own HTTPS connection and was already buffered.
- librespot started at boot (16:08, after the v2.1.2 upgrade) with
  `starting at the sink's 0%`, so its `--initial-volume` was 0.

## Why

librespot holds two connections to Spotify: the access point (AP), which
carries the login, the keep-alive and the decryption key of every track, and
the dealer websocket, over which Spotify Connect hears its commands.

1. Spotify's AP closed the connection. It does that routinely: upstream
   reports resets 0–140 ms after an on-time keep-alive Pong, minutes to an
   hour apart, about 190 a day on one device (librespot PR #1871). Here the
   session had lasted an hour (16:08 → 17:05).
2. librespot 0.8.0 answers by invalidating the whole session
   (`Session::shutdown()`, `core/src/session.rs`). That only sets a flag.
3. The Spirc (the Connect loop, `connect/src/spirc.rs`) tests the flag only
   at the top of `while !self.session.is_invalid()`, i.e. after something
   wakes its `select!`. The dealer is a separate connection and stayed up, so
   nothing did: the Q stayed visible in Connect, and the next track could not
   get its key. Upstream issues #1492 and #1682 show the same log.
4. Petr's touch in the app woke it. librespot's main loop then built a new
   Spirc from scratch, with `setup.connect_config`, whose `initial_volume` is
   the `--initial-volume` of the program's start, and `Spirc::new` sets the
   mixer to it. Playback stopped and the volume went to 0. (Any session loss
   does this: a Q booted at 27 % and turned up to 60 % drops back to 27 %.)

Why the sink was at 0 % at that boot is not known: every earlier boot started
at 27 %, `volume.json` is new in device r120 and did not exist on this unit
before the upgrade, and no component logs a change of the sink volume.

## The fix: librespot as an override (librespot 0.8.0-r100)

`pmos/librespot/`, Alpine's APKBUILD (kept as `upstream/APKBUILD.alpine`) with
seven patches on 0.8.0:

| Patches | From | What it does |
|---|---|---|
| 0001–0003 | PR #1871 (open, head `14c8637`) | When the AP connection closes, a write fails or the keep-alive times out, the session logs in again on the next AP with the last login's credentials and stays valid. Dealer, Connect registration, Spirc and player carry on; a key request made during the reset waits and is sent again on the new connection. |
| 0004–0006 | PR #1787 (open, head `a1b5e44`) | When the session does end (the reconnect failed or took over 30 s, or the connection closed within 30 s of connecting), `Session::shutdown()` also ends the dealer's subscriptions, so the Spirc's streams end and it shuts down at once. |
| 0007 | ours | A Spirc built after the first one takes `mixer.volume()` as its initial volume instead of the program's `--initial-volume`. |

On v0.8.0 the PRs conflicted only in `CHANGELOG.md` (dropped), in core's
dev-dependencies (tokio `test-util`, which #1871's tests need) and in one line
of `Session::shutdown()`, where both add a call; both are kept, as #1871's
description asks.

Verified on a host (aarch64, Rust 1.91): `cargo test --workspace --features
alsa-backend` passes; `librespot-core` runs 23 tests, six of them #1871's
(`a_request_waits_while_the_session_reconnects`,
`a_request_given_up_on_is_not_sent_again`,
`a_shutdown_ends_a_request_waiting_for_a_reconnect`,
`a_request_after_a_shutdown_ends_at_once`,
`a_subscription_answered_on_a_closed_connection_ends`,
`a_login_without_an_answer_times_out`). 0007 has no automated test; it is
checked on the device.

The build (`docker-build.sh` Phase 7c9) stops if the override does not build,
and the APKBUILD's `build()` stops if a re-base applied the patches but lost
one of the three behaviours. The rootfs SHIP CHECK reports which librespot an
image carries.

## Keeping it current

A copy of a distro package freezes unless something updates it.
`scripts/check-overrides.py` does, for every `pmos/*/upstream/upstream.json`
(librespot so far):

- Alpine's APKBUILD against `upstream/APKBUILD.alpine`: a change at the same
  pkgver is merged into ours three-way by `just overrides` (`--merge`), which
  bumps our pkgrel and takes the new base; a conflict, or a new pkgver (their
  package would outrank ours, and the patches need a re-base), is an error.
- librespot's latest release against the one the patches were taken for: a
  new one is an error (re-base, and drop what the release carries).
- Each carried PR: merged upstream, closed, or its head moved since it was
  taken, is a warning in a banner.

`docker-build.sh` (at its start) runs it and stops only on what makes the
override wrong or outranked: a new pkgver at Alpine, a conflicting Alpine
change, versions in the override that disagree. The rest is a warning there,
so a hotfix build is not held up. `scripts/publish-ota-repo.sh` runs it with
`--strict`, which also stops on an unmerged Alpine change and a newer upstream
release. Both stop when upstream cannot be asked (exit 2; an HTTP 404 or a
GitHub rate limit is reported as such; `GITHUB_TOKEN` is used when set).
`NEXUSQ_SKIP_OVERRIDE_CHECK=librespot` skips one override, `=1` all of them,
loudly. The container mounts the repo read-only, so the merge runs on the host.

What it does not cover: a unit upgrades against Alpine edge/testing between
our releases, so a newer Alpine librespot would outrank this build there
(open in PLAN: pinning the overrides on the units).

## Getting the new binary running

A system update restarts our system daemons, not the appliance user's units,
so librespot would have taken the new binary and run the old one until a
reboot. nexusq-control r69 restarts a user service whose binary was replaced
(`/proc/<pid>/exe` reads "… (deleted)") when its source is idle; see the
CHANGELOG.

## Still to do

In PLAN ("the 2026-11-14 cottage Q findings"): the build and the device test,
pinning the overrides on the units, offering 0007 upstream. When a librespot
release carries the fixes, drop the override.
