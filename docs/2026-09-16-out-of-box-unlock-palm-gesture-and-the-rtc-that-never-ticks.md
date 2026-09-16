# The out-of-box report: two real doc bugs, one misdiagnosis, and the RTC behind it

2026-09-16 — triage of [issue #4](https://github.com/petronijus/nexusQ-reloaded/issues/4),
filed by `mattv-nmg`, who flashed a **stock, never-unlocked** Nexus Q. Three
claims came in. Two were right and are fixed here; the third was wrong, and
chasing why it was wrong turned up a real defect nobody had looked for.

The unit's fastboot identity, as reported:

```
version-bootloader: steelheadB4H0J
product: steelhead        device_type: HS
secure: yes               unlocked: no
```

---

## 1. A factory unit is locked, and the guide never said so — REAL, fixed

`INSTALL.md` §2 went straight to `fastboot flash boot`. On a unit that has never
been unlocked that fails:

```
Writing 'boot'   (bootloader) fbt_handle_flash: failed, device is locked
FAILED (remote: 'device is locked')
```

Nothing in the repo mentioned `oem unlock` — not INSTALL.md, not README.md, not
a single doc. The reference unit was unlocked long before any of this was
written, so the step never existed for anyone here to forget.

Verified against the stock bootloader rather than taken on trust
(`reverse-eng/factory/tungsten-ian67k/bootloader-phantasm-steelheadb4h0j.img`,
U-Boot 2011.09-rc1, a legacy uImage: header 0x40, load 0x80100000):

| Evidence | Where |
|---|---|
| `oem unlock` / `oem unlock_accept` command names | strings @ `0x80125…` |
| `…accept in %d seconds via 'fastboot oem unlock_accept'.` | fmt string |
| **the `%d` is literally 5** — `mov r1, #5` right before the printf | `0x801065dc` |
| `unlock pending expired`, `FAILoem unlock not requested` | the miss path |
| `oem unlock` answers **`OKAY`** when newly requested, `FAILalready unlocked` otherwise | `0x80106e48` / `0x80106eac` |

That last row is why the README can safely write `fastboot oem unlock &&
fastboot oem unlock_accept` on one line: the `&&` fires on a real OKAY, and
short-circuits harmlessly on an already-unlocked box. Chaining them is also the
most reliable way to land inside a 5-second window.

**Fixed:** new `INSTALL.md` **§1d** (check `getvar all` for `unlocked:`, then the
two commands, with the window, the userdata erase and the "it stays in fastboot
afterwards" all spelled out), a pointer to it at the top of §2, and step 2 of the
README quick start.

## 2. §1b had the palm gesture backwards — REAL, fixed

The guide said: cover the sensor, *then* apply power, and keep it covered. The
reporter never once got a red ring that way. What works:

1. power on with the dome **untouched**;
2. palm the centre the moment the **mute LED lights** (~1 s window);
3. hold to solid red;
4. **lift off promptly**.

The stock bootloader explains both halves.

**Why palm-first cannot work.** `board_fbt_key_pressed()` (`0x8011fc68`) probes
the ring AVR, waits up to 2 s and re-probes if it is not answering yet
(`avr not detected` / `delaying %d milliseconds until we try again`, with 2000
hard-coded at `0x8011fca0`), then polls `avr_get_key()` for a **queued key
event**. A palm already on the dome at power-up is calibrated *into* the
capacitive baseline by the AVR's own start-up, so the AVR never queues a key
down, U-Boot reads "nothing queued" and boots on. The touch has to arrive after
the AVR is alive — and the centre LED lighting is precisely that signal.

**Why you must let go.** `board_fbt_key_command()` (`0x8011fb44`) keeps polling
the mute key every 100 ms *while in fastboot*:

```
8011fb60:  cmp  r0, #100          @ poll no faster than 100 ms
8011fb88:  cmp  r5, #128          @ 0x80 = key down -> record press time
8011fbec:  ldr  r3, =0x2710       @ 10000 ms
8011fbf0:  cmp  r4, r3
8011fbf8:  ldr  r0, ="%s: mute key down more than %u seconds, starting recovery\n"
8011fc08:  mov  r0, #5            @ -> jump-table entry that enters RECOVERY
```

So a hold of **more than 10 seconds** leaves fastboot for recovery. That is the
"holding past red moves it to a different mode" the reporter noticed and could
not find documented — because it was not documented anywhere, here or upstream.

**Fixed:** `INSTALL.md` §1b rewritten with the correct ordering, the mechanism,
and the 10-second warning; README quick start step 1 likewise.

---

## 3. "The image ships a machine-id and someone else's journal" — NOT TRUE

The follow-up comment reported, on a freshly flashed v1.15.1:

```
$ cat /etc/machine-id
bd86e58b2143456b93a5b10af130e7ae
$ journalctl -u nexusq-mqtt
Aug 22 20:03:33 steelhead systemd[1]: ... ConditionPathExists=/etc/nexusq/mqtt.json
-- Boot 19839847eb7b428ea086d962dbbb8513 --
Aug 22 20:08:11 steelhead systemd[1]: ...
-- Boot 02bdd29d4cea4ad7b209ff67dbc2da97 --
Sep 03 18:49:16 steelhead systemd[1]: ...
```

...concluding that the id and the journal came from the image, because "the Aug
22 boots predate my ownership".

### The artifact says otherwise

`nexusq-rootfs-v1.15.1-sparse.img.zst` was downloaded from the release, expanded
(`simg2img`) and mounted read-only:

| Path | State in the published v1.15.1 rootfs |
|---|---|
| `/etc/machine-id` | **does not exist** |
| `/var/lib/dbus/machine-id` | does not exist |
| `/var/lib/systemd/random-seed` | does not exist |
| `/var/log/journal/` | exists and is **empty** |
| `/etc/ssh/ssh_host_*` | none |

The current v1.16.0 build is identical in every row. And the reference unit's
own id is `6ab3076fcc7448a795e8b129a2358462` — **different** from the reporter's.
Two units, two ids: nothing is baked, and systemd's first-boot generation is
working exactly as intended.

The inference that misled the report is a reasonable-looking one: *the journal
directory is named after the current machine-id, therefore the id predates the
journal's contents.* It does not follow — journald **creates** that directory
from whatever machine-id exists at the time of the first boot, so the two always
agree, on every Linux box, no matter where either came from.

### So where does "Aug 22" come from?

From systemd, and it is the same date on **every** unit:

```
$ awk '/^P:systemd$/,/^$/' /lib/apk/db/installed   # in the v1.15.1 image
V:261.2-r1
t:1787443412        ->   Sun 2026-08-23 00:03:32 UTC
```

`1787443412` is systemd 261.2-r1's build timestamp, which is what lands in
systemd's compiled-in `TIME_EPOCH`. With no RTC value and no network time yet,
PID 1 jumps the clock forward to that epoch, and journald stamps the boot there.
In UTC−4 (US Eastern, matching the reporter) that instant is **Aug 22 20:03:32**
— their first log line is `Aug 22 20:03:33`, one second later.

So both "Aug 22" boots are the reporter's **own** first two power-ups, misdated
by exactly the systemd build epoch; `Sep 03 18:49` is the boot that finally got
NTP. Nothing personal was ever in the image, and the release gate's silence was
correct even though nobody had asked it this question.

---

## 4. The defect underneath: the TWL6030 RTC never runs

That the clock has to fall back to a build epoch at all is the actual bug. The
Q has an RTC; it is not ticking. On the reference unit, **7 h 47 min** into a
normal boot:

```
$ timedatectl
     Universal time: Wed 2026-09-16 21:06:20 UTC
           RTC time: Sat 2000-01-01 00:00:00      <- never moved
System clock synchronized: yes      NTP service: active

$ cat /sys/class/rtc/rtc0/since_epoch   # twice, 3 s apart
946684800
946684800                               <- frozen

$ hwclock -r
hwclock: select() to /dev/rtc to wait for clock tick timed out
$ hwclock -w    # silent; since_epoch still 946684800
```

`dmesg`:

```
twl_rtc 48070000.i2c:twl@48:rtc: Power up reset detected.
twl_rtc 48070000.i2c:twl@48:rtc: registered as rtc0
twl_rtc 48070000.i2c:twl@48:rtc: setting system clock to 2000-01-01T00:00:00 UTC
```

Read straight off the PMIC (TWL6030 slave `0x48` on i2c-0 = `48070000.i2c`,
`TWL_MODULE_RTC` base `0x00`), twice, 3 s apart:

| Reg | Name | Value | Meaning |
|---|---|---|---|
| `0x00` | `SECONDS_REG` | `0x00` → `0x00` | does not advance |
| `0x03`/`0x04` | days / months | `0x01` / `0x01` | Jan 1 |
| `0x10` | `RTC_CTRL_REG` | **`0x00`** | `STOP_RTC` clear — **the counter is stopped** |
| `0x11` | `RTC_STATUS_REG` | `0x80` | `POWER_UP` set, never cleared |

This is not the ordinary "mains appliance with no coin cell, so the RTC resets
on unplug" story. The counter does not run **within a single boot either**, and
`CONFIG_RTC_SYSTOHC=y` therefore has nothing it can write back to.

`rtc-twl.c` only starts the RTC when it reads `RTC_CTRL_REG` and finds
`STOP_RTC` clear. The register **is** clear and the driver did **not** print
`Enabling TWL-RTC`, so either its read came back with the bit set (a bogus read)
or its write did not land. Register `0x11` staying at `0x80` — the driver is
supposed to clear the status bits by writing 1s — points at **writes to the RTC
block being silently dropped while reads work**, which would explain both.

Not fixed here: it needs a kernel/DTS change, a rebuild and a flash, and under
[keep-stock-matching-fixes] the first step is to establish what the stock kernel
did with this block before building anything. Symptoms to carry forward:

- every boot starts at systemd's `TIME_EPOCH`, so **all logs before NTP lands are
  misdated by weeks** — which is exactly what sent issue #4 down the wrong path;
- anything time-dependent that runs before `systemd-timesyncd` syncs sees a
  clock weeks in the past;
- the Q is on WiFi/ethernet the whole time, so NTP does eventually fix the wall
  clock — this is a correctness and forensics problem, not an outage.

A cheap, honest interim once the RTC question is settled either way: ship
`/usr/lib/clock-epoch` stamped with the **image build** date, so the pre-NTP
fallback is at least the release's own date rather than whenever pmOS last built
systemd. The image ships no such file today.

---

## 5. What else a first-timer hits (found by reading the guide as a stranger)

The report was two bullets; the OOB path had more wrong with it. Found by
reading `INSTALL.md` top to bottom as someone who owns nothing yet:

| Symptom | Reality |
|---|---|
| Title block: "**This guide describes release `v1.15.2`**" — device r93, kernel `6.18.48-r0` | line 1 is `<!-- RELEASE: v1.16.0 -->`; v1.16.0 is device **r101**, `nexusqd` r20, kernel **`6.18.48-r1`** |
| "Verify against `sha256sums-v1.16.0.txt`" | that file **is not in the v1.16.0 release**; the release carries a bare `sha256sums.txt` |
| Flash block: "The v1.11.0 kernel is r45 (~5.3 MiB; 44 patches through 0044)" | four kernel revisions stale; v1.16.0's boot.img is 6 719 488 B on 6.18.48-r1, 44 patches through 0046 |
| "~630 MiB compressed, ~2.6 GiB raw" … and "(~2.08 GiB raw)" 220 lines later | the same file, two different sizes, both wrong: **675 MiB → 2.65 GiB** |

The version marker gate (added v1.14.2, after the guide went four releases
stale) passed through all of this, because it reads **only the marker**. A
one-line HTML comment is easy to bump and the body is not, which is precisely
backwards from what the gate was trying to protect.

The checksum name is a script bug, not a doc bug: `package-release.sh` has always
written `sha256sums.txt`, and the versioned name on every release up to v1.15.2
was typed by hand at upload time. v1.16.0 was uploaded from the script's own
printed command, so the hand-correction did not happen. Fixed at the source —
the script now writes `sha256sums-$VER.txt`.

**The published v1.16.0 release was corrected too**, because a guide that names
a file the release does not have is still a broken first install no matter how
right the repo is. `sha256sums-v1.16.0.txt` was uploaded to the v1.16.0 release,
then downloaded back and diffed against the local copy to prove the published
bytes are the right ones. The unversioned `sha256sums.txt` was **left in place**:
its content is identical, some link somewhere may already point at it, and
deleting an asset off a published release is not something to do in passing.
The release therefore carries both, and the guide names the versioned one.

`package-release.sh` now gates on the guide's **body**: the "This guide describes
release `$VER`" sentence plus all three artifact filenames. Watched failing
against the exact v1.16.0 shape — marker and filenames bumped to the new version,
prose left a release behind — before being trusted.

## What changed in this session

- `INSTALL.md` — §1b rewritten (correct ordering + mechanism + the 10 s recovery
  warning); new **§1d** bootloader unlock; §2 opens with a pointer to §1d; §1c
  now says first-time installers should skip it.
- `README.md` — quick start: corrected gesture, and the unlock as its own step.
- `scripts/package-release.sh` — writes `sha256sums-$VER.txt` instead of a bare
  `sha256sums.txt`, and gates on the install guide's body (the "describes
  release" sentence + all three artifact filenames), not just its marker.
- `scripts/release-preflight-no-secrets.sh` — five new first-boot-identity
  checks, so the next time someone asks "is my id baked into your image?" the
  release path has already answered:
  `/etc/machine-id` (absent **or zero-length**), `/var/lib/dbus/machine-id`,
  `/var/lib/systemd/random-seed`, an empty `/var/log/journal/`, and **no ssh
  host keys** — that last one had never been gated at all, and a leaked host
  private key would let anyone impersonate every Q flashed from the release.

Each new check was watched failing against a deliberately contaminated ext4
image before being trusted ([test-must-be-seen-failing]). One of them was wrong
when first written and the dirty image caught it: `Size: 0$` matched debugfs's
`Fragment: Address: 0 Number: 0 Size: 0` line, which every inode has, so a
32-byte machine-id was waved through as "zero-length". It now reads only the
`User: … Size: N` line.
