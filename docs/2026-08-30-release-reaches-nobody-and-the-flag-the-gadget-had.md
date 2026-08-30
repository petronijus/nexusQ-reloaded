# A release that reached nobody, and the flag the gadget had all along (2026-08-30)

Two findings from one session, unrelated in mechanism and joined at the hip in
practice: the second is a fix that nothing could have delivered, because the
first meant no fix had reached a device in two days.

Started from "download the news, then look at performance". The news was
v1.14.0 → v1.14.2 and app 1.17.0 → 1.17.3. The performance look began, as it
always should, with the passive Home Assistant history rather than an ssh
session — and the first thing it showed was a 29-hour hole.

---

## 1. The 29-hour hole (already known, and it reproduced from the outside)

`scripts/diag/ha-opp-window.py --days 3` over 2026-08-27 17:06 → 08-30 17:06:

| window | 350 MHz | die |
|---|---|---|
| 08-28, 10h–18h | 96,6–96,8 % | 55 °C |
| **08-28 19:30 → 08-30 00:44** | **0,0–0,1 %** | **77–85 °C, peak 90,6 °C** |
| 08-30 01h onward | 88,4 % | 56–59 °C |

`uptime: 1.22 d -> 4.22 d (NO reboot)` — one continuous boot, so this was not a
crash, and 1200 MHz residency peaked at 66,1 %.

The device journal dates the start to the second:

```
2026-08-28T19:13:45 NetworkManager[384]: device (usb0): carrier: link connected
```

The USB host — the Xiaomi TV box — attached. This is the failure already
root-caused in `fae2e3e` (device r88): a UAC2 host that stops sending without
closing the stream leaves the gadget capture substream in `state: RUNNING` with
`hw_ptr` frozen, and `alsaloop --sync=simple` spins on it forever.

**Worth recording as method, not as news:** the whole episode was visible, dated
and quantified from Home Assistant alone, without touching the box. An ssh
session pushes the die to 74–79 °C within seconds and drags the OPP up with it,
so the tool that cannot see the device is the only one that can see it honestly.

---

## 2. The fix was live, the package knew nothing about it, and the repo had neither

The Prague Q at `192.168.20.246`:

```
apk info -v   →  device-google-steelhead-1.0-r87
apk audit     →  U usr/bin/nexusq-uac2-in        (file differs from the package)
```

So the r88 script was hand-copied onto an r87 package. Any `apk fix`, any
reinstall, any reflash would silently restore the spinning version.

And the repo it would reinstall from had never heard of r88 either:

```
gh-pages, last commit 2026-08-28 06:23 UTC:
  "OTA apk repo — device-google-steelhead 1.0-r87 …"
```

while GitHub Releases carried **v1.14.2, published 2026-08-30 08:11 UTC, device
r89**.

### The actual defect: a release is two publishes and only one of them ran

```
scripts/package-release.sh   -> boot.img + rootfs  -> GitHub Releases   ✅ ran
scripts/publish-ota-repo.sh  -> signed apks        -> gh-pages          ❌ did not
```

Both read the same build volume. Nothing tied them together, and
`package-release.sh` did not contain the string "OTA". So v1.14.2 shipped as an
image while every box in the field stayed on r87 — and every UI said *up to
date*, because **a device cannot be offered a version its repo does not carry.**
The image track was perfect. The fleet simply never heard about it.

### Why "just run both" was not available either

Publishing from the MacBook would have made it worse. The signing keys:

| | key |
|---|---|
| desktop `nexusq-workdir/config_abuild` | `pmos@local-6a42e957` |
| published `APKINDEX.tar.gz` | `pmos@local-6a42e957` |
| **Prague Q `/etc/apk/keys/`** (verified live, and byte-identical to the desktop's) | **`pmos@local-6a42e957`** |
| image built on the MacBook (v1.14.0/1/2) | `pmos@local-6a93112c` |
| image v1.13.0 (Šumperák) | `pmos@local-6a913e9e` |

A publish from the Mac would re-sign the index with `6a93112c` and take OTA away
from the one box where it still worked. The guard added in `1380e2f` fails
closed on exactly that — correctly.

That answers the open question from the MacBook's handover task, which could not
reach either box: **the Prague Q trusts `6a42e957`, the same key this desktop
signs with.** So option A — build releases here — costs nothing in the field.

### What changed

- **`pmos/ota-signing-key.rsa.pub`** — the fleet's public key, recorded. It was
  the missing half of a guard that had been wrapped in `if [ -f … ]` with no
  `else`: the one check written to stop key drift did nothing, always, because
  its reference file was never committed. Verified byte-identical against the
  live device before committing, not against what we believed. The private half
  is now backed up in 1Password ("nexusQ OTA signing key (fleet)"); before today
  its only copy was inside a docker volume.
- **`pmos/ota-packages.list`** — the OTA package set, in one place. It used to
  live only inside `publish-ota-repo.sh`, where a package missing from it fails
  *silently* (that is how device r80 shipped against a missing
  `nexusq-rootfs-ab`). A second copy inside the new gate would have reproduced
  the trap one level up: a gate that checks the subset it happens to know about
  is a gate that agrees with the bug.
- **`scripts/verify-ota-parity.sh`** — the gate. For every listed package the
  version in the *released rootfs* must equal the version in the *published
  index*, and the key baked into the image must be the key the index is signed
  with. Judged against the rootfs, never against the build volume the apks came
  from — that comparison is circular and would agree with itself no matter how
  far behind the repo had fallen.
- **`scripts/package-release.sh`** now publishes the OTA repo and then runs that
  gate. `--no-ota` skips the publish; **nothing skips the gate.**

### The gate was watched failing before it was trusted

`scripts/tests/test-verify-ota-parity.sh` builds synthetic rootfs images with
`mkfs.ext4 -d` (populate-from-directory, so only the gate itself needs sudo) and
covers seven cases, including version drift, key drift, a package the repo does
not carry, and — the one that matters most today — an unfetchable index, which
must **fail** rather than assume.

Then the gate itself was mutated to prove the tests are not decorative:

| mutation | result |
|---|---|
| version comparison replaced with `elif false` | test 2 goes red |
| unfetchable index downgraded to a notice | test 6 goes red |

Both restored, 7/7 green after. This matters because the two release gates fixed
earlier the same day (`9d16ba1`) had reported success for their whole lives while
unable to read what they judge — and no test would have caught it, because there
was none.

---

## 3. The performance finding: the park probe cost more than anyone priced

With r88 live and the box genuinely idle, the standing-goal number was **88,4 %
@ 350 MHz** — below the 96,7 % the same box had shown two days earlier, and
below the 90,8 % baseline. Something was running.

### What the probe actually costs

r88 parks `alsaloop` when the host stops sending and, being unable to watch
`hw_ptr` while parked, duty-cycles a probe: start `alsaloop` for ~3 s every 30 s
and keep it only if input moves. Its own comment estimates *"roughly 2 s of work
every 30 s"*.

Measured on the device, 1 Hz for 300 s, detached via `systemd-run` (an earlier
attempt died with its ssh session — `systemd-logind` reaps the session scope),
one sample = zero forks so the sampler cannot bias what it measures:

| | share of wall | 350 MHz | 1200 MHz | CPU busy | die |
|---|---|---|---|---|---|
| parked | 91,0 % | 93,68 % | 0,11 % | 8,16 % | 59,0 °C |
| **probe running** | **9,0 %** | **1,62 %** | **77,29 %** | **30,23 %** | **64,6 °C** |

**99 % of all time above 350 MHz was the probe** looking for a host that was not
there. Priced by the OPP mix (V²f; 1200 MHz costs 6,2× 350 MHz), relative
dynamic power **1,13× → 1,54×**: a permanent +36 % on idle MPU power, paid
around the clock for as long as the TV box is powered on and not playing.

The service's own accounting agrees, over a much longer window:

```
nexusq-uac2-in.service: Consumed 1h 13min 26s CPU over 17h 45min wall  = 6.9 % of a core
```

### The flag the comment said did not exist

> *"the gadget exposes no 'host is streaming' flag — its configfs attributes are
> all static"*

The configfs attributes are indeed static. But `u_audio` registers an ALSA
control on the gadget card:

```
numid=4,iface=PCM,name='Capture Rate'
```

Sampled at 1 Hz across two full probe cycles, it read **0 the entire time —
including while the probe held the PCM open**. That is the decisive observation:
it tracks the *host's* alt-setting, not our own open, so it cannot be fooled by
our own activity. (`amixer cget name='Capture Rate'` returns nothing, which is
why it was missed: the control is `iface=PCM`, not `MIXER`, and must be
addressed by numid — resolved by name at startup, since numid is an allocation
order and not an API.)

`/proc/interrupts` says the same thing for free: the `musb-hdrc` counters were
frozen at 199723646 across 5 s, so a host that is not streaming generates no
gadget interrupts at all.

### Why "non-zero means wake up" is wrong

The flag answers *is the host's stream open*, not *is audio arriving*, and those
come apart in precisely the failure that started all this. Parked from a wedge —
host holding the stream at 48000 Hz and sending nothing — a bare "non-zero →
unpark" unparks, finds input still frozen, re-parks 12 s later, and repeats
forever. A flap that costs more than the probe it replaced.

So the decision depends on **why** we parked, recorded at park time:

| parked at | flag now | action |
|---|---|---|
| 0 (host closed the stream) | 0 | stay — the cheap steady state |
| 0 | non-zero | unpark, host is back |
| non-zero (the wedge) | non-zero | **probe** — asking cannot answer, measure |
| non-zero | 0 | host let go; the flag is trustworthy again |

That table is `park_action()`, deliberately pure and marked `TESTABLE:` so
`pmos/device-google-steelhead/tests/test_uac2_park_action.sh` extracts the real
function rather than reimplementing it. Replacing it with the naive version
turns 4 of its 8 cases red — checked, not assumed. (r88's message said both
paths were "unit-tested off-device"; no such test was ever committed.)

### The fork is not free either — measured, not assumed

`nexusq-uac2-in` already carries a warning that forking `pactl` every 3 s cost
**+4,6 % of a core**. So the replacement was measured before it was shipped:

| call | CPU @1200 MHz | ≈ @350 MHz |
|---|---|---|
| `amixer cget` | 19,5 ms | ~67 ms |
| `pactl list short modules` | 15 ms | ~51 ms |

`amixer` is **more expensive than the `pactl` call the file warns about**. At one
call per 3 s tick it would have burned ~2,2 % of a core forever, and each ~67 ms
burst is itself well past the 16 ms run length that makes `conservative` ramp —
trading a 1200 MHz probe for a permanent 700 MHz nudge is not a win. So the poll
is thinned to every 4th tick (12 s).

### Result

300 s, same sampler, box idle, USB host attached and not playing:

| | r88 (probe every 30 s) | r90 (flag polled every 12 s) |
|---|---|---|
| 350 MHz | 85,40 % | **90,40 %** |
| 700 MHz | 5,20 % | 7,45 % |
| 1200 MHz | 7,05 % | **0,17 %** |
| gadget substream open | 9,0 % of wall | **0,0 %** |
| relative dynamic power | 1,54× | **1,21×** |

`alsaloop` now never starts while the host is idle, and waking is *faster* than
before: at most 12 s against the old 30 s retry.

**The poll interval was A/B'd rather than guessed.** At 30 s the same window
gives **91,37 % @ 350 MHz** — so the fork costs about **1 pp of residency**, and
12 s buys back up to 18 s of music you would otherwise miss after pressing play.
Kept at 12 s deliberately; `NQ_UAC2_PARK_POLL_TICKS` moves it.

### Left on the table

The zero-fork version is `alsactl monitor`: one long-lived process woken by the
control-change notification instead of asking. Not taken, because whether
`u_audio` actually emits a notification for this control was **not verified on
the device**, and a monitor that never fires does not degrade gracefully — USB
audio would simply never come back. Worth doing as the primary with this poll
kept as the backstop.

~~Also unverified, and it needs Petr: that `Capture Rate` reads **non-zero during
real playback**.~~ **Resolved the same evening — see §5.**

---

## Fleet state after this session

| | Prague Q | Šumperák Q |
|---|---|---|
| package installed | r87 | v1.13.0-era |
| script actually running | **r90** (hand-copied, measured above) | r87 behaviour |
| trusts key | `6a42e957` ✅ matches the repo | `6a913e9e` ❌ cannot OTA at all |

The Šumperák box is still exposed to the 28-hour spin, and cannot receive the fix
over the air until its key is reconciled — a manual copy into `/etc/apk/keys`,
or a reflash from an image built on this desktop.

---

## 4. Postscript: publishing that repo turned out to be handing out the WiFi PSK

Running `publish-ota-repo.sh` for the first time from the desktop is what
uncovered this, and only by accident: the release's *image* gate
(`release-preflight-no-secrets.sh`) was run afterwards, reported **"PERSONAL
build"**, and prompted the obvious next question — what is inside the package I
just published?

```
device-google-steelhead-1.0-r90.apk
  etc/NetworkManager/system-connections/wifi.nmconnection   psk=<the real one>
  root/.ssh/authorized_keys                                 2 ssh keys
  etc/skel/.ssh/authorized_keys                             2 ssh keys
```

Walking `gh-pages` backwards, **every published revision from r62 (2026-08-02)
onward carried it**: r62, r84, r85, r86, r87, r90 — four weeks on a public repo.
Today's publish refreshed it rather than started it.

**The gate existed and was pointed at the wrong artifact.** `release-preflight-
no-secrets.sh` has guarded the rootfs image since 2026-07-02, correctly, because
a release uploads that image to public GitHub. The same bytes ride one directory
away inside the *package* — which is published to a public GitHub Pages branch on
every OTA push — and nothing looked there. Not a missing idea; a missing pointer.

### What was done

- **`scripts/verify-apk-no-secrets.sh`**, wired into `publish-ota-repo.sh` before
  the push. It opens every apk and fails on a `*.nmconnection` carrying `psk=`, a
  non-empty `authorized_keys`, a private key or a shadow file — by CONTENT, since
  `PUBLIC_RELEASE=1` legitimately ships empty placeholders. Run against the live
  repo it flagged r90 and passed the other ten, and it found a third file the
  manual look had missed (`root/.ssh/authorized_keys`).
- **`device-google-steelhead` held back from OTA**, not "rebuilt clean". A clean
  build of the same package cannot simply replace a personal one in the field:
  apk removes files that leave a package's file list, so a device upgrading from
  personal to clean loses its WiFi profile *and* its root `authorized_keys` —
  offline and locked out, which for the cottage unit means a car journey. The
  access files have to stop being package content first.
- **`gh-pages` rewritten** to one parentless commit. Verified: a fresh clone
  carries 1 commit and zero affected objects, and the URL 404s.

### The part a rewrite cannot fix

The old commits remain fetchable from the GitHub API **by SHA** — checked, three
of them still answer HTTP 200 after the force-push. GitHub does not garbage-
collect on demand. So the rewrite reduces exposure; it does not end it.

**The PSK was public for four weeks and must be treated as compromised.**
Rotating it is the remediation; everything above is containment.

### Why it is the same bug as the rest of this session

Three times in one day: a guard wrapped in `if [ -f ]` with no `else`, a gate
that passed because it could not read root-owned files, and now a gate aimed at
the image while the identical secret shipped in the package. None of them were
missing ideas. Each was a check that could not see the thing it was written to
protect, and reported success. That is the failure mode to design against here —
not the absence of a gate, but a gate looking slightly to one side of the danger.


---

## 5. The half that was still a guess, settled at 21:59

Everything above observes `Capture Rate` in the **0** state. That proves the
cheap half — the bridge parks when the host goes quiet — and leaves the other
half inferred from how `u_audio` is written rather than seen. A flag that never
comes back would not degrade loudly; USB audio would simply stop working, which
is the worst way for an assumption to be wrong.

Petr pressed play. The whole cycle, on the wire:

```
Capture Rate = 48000                                (0 all day until now)
hw_ptr 8580720 -> 8677296 over 2 s                  audio genuinely flowing
alsaloop running (pid 6727)                         the bridge came back on its own
21:59:04 nexusq-uac2-in: host started streaming at 48000 Hz — USB audio live again
```

So r91 rests on nothing unproven.

### And the number that actually matters

240 s, detached sampler, box genuinely playing:

| | idle (parked) | **playing** | this morning: idle with the probe |
|---|---|---|---|
| 350 MHz | 90,40 % | **90,11 %** | 85,40 % |
| 700 MHz | 7,45 % | 9,07 % | 5,20 % |
| 1200 MHz | 0,17 % | **0,29 %** | 7,05 % |
| CPU busy (of 2 cores) | 9,6 % | **33,7 %** | 8,2 % |
| die | 58,7 °C | **60,2 °C** | 59,0 °C |
| relative dynamic power | 1,21× | **1,19×** | 1,54× |

**Playing music is energetically free.** The CPU does 3.5× the work — 33,7 %
against 9,6 % — and the power does not move, because every bit of that work
happens at 350 MHz, where a second costs 1,0 instead of 6,2. The device ends the
day in a state where **a Q playing music draws less than a silent one did that
morning**: 1,19× against 1,54×.

This is the same lesson the project keeps re-learning and it is worth stating
once more plainly: **CPU per cent is not power on this SoC.** The probe looked
cheap by CPU time (30 % of two cores for 9 % of the time) and was expensive
because of *where* on the frequency curve it ran; playback looks expensive by CPU
time and is nearly free for the same reason inverted.

### One more observer-bias trap, caught in the act

A spot read taken from inside an ssh session reported **1200 MHz / 65,4 °C** and
looked like playback had regressed. It had not — that was the ssh session, which
drags the OPP up within seconds (the reason `ha-opp-window.py` exists at all).
The detached sampler said 90,11 % @ 350 MHz for the same music.

Sixth time in one day that a reading meant something other than what it appeared
to: this one at least was recognised before it was written down as a finding.
