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

Register `0x11` staying at `0x80` — the driver clears the status bits by writing
1s back, at probe — and `0x10` staying at `0x00` — the 6.18 `twl_rtc_probe`
writes `CTRL = STOP_RTC` **unconditionally** — together point at **writes to the
RTC block being silently dropped while reads work**.

_(This paragraph said until 2026-09-17 that the driver "did not print `Enabling
TWL-RTC`, so its read or write went wrong". That inference was invalid: the
6.18 driver no longer has that branch at all — `strings rtc-twl.ko` on the
device shows `Power up reset detected.` and nothing about enabling — so the
absence of the line proves nothing. The stock-parity audit of 2026-09-17 found
the real mechanism; see the addendum below.)_

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

### Addendum 2026-09-17 — root cause: MSECURE is never driven high

The stock-parity audit (`stock-parity-auditor`, against `reverse-eng/vmlinux.bin`,
the stock mux dump, upstream 6.18 `rtc-twl.c`/`twl-core.c` and live read-only
register reads) settled it. Nine items MATCH — same i2c slave `0x48`, same
module base, same register map, same probe sequence, same PIH unmask (live: the
unmask write **landed**, `0x49:0xD3 = 0xE7`), VUSB and CLK32KG writes to the same
PMIC land too. Exactly one MISMATCH, and it is board-level, not driver-level:

**The TWL6030 write-protects its RTC block (and the secured/backup registers)
while its MSECURE input is low.** Reads pass, writes are ACKed and discarded.
Stock `steelhead_init` (`board-steelhead.c:999-1004`, `0xc0016aec–0xc0016b04`
in `vmlinux.bin`) does `omap_mux_init_signal("fref_clk0_out.gpio_wk6",
OMAP_PIN_OUTPUT)`, `gpio_request(6, "msecure")`, `gpio_direction_output(6, 1)`
— the comment reads *"Drive MSECURE high for TWL6030 write access"*. Stock mux
dump: pad `0x054 = 0x0003` (gpio_wk6, output).

On our side, three things conspired:

| | |
|---|---|
| `omap4-steelhead.dts` had an `msecure_pins` group | pointing at pad **`0x050`** (`fref_slicer_in`), not `0x054` (`fref_clk0_out`) |
| nothing referenced the group | not in any `pinctrl-0` |
| no gpio hog on gpio_wk6 | so even a correct mux would have driven nothing |
| the included `twl6030_omap4.dtsi` claims pad `0x054` as **`MUX_MODE2 = sys_drm_msecure`** | the secure-ROM-owned signal, which this HS OMAP4460 leaves low — which is why Google bypassed it with a GPIO in the first place |

Live: `0x4a31e054 = 0x0002` (mode 2), `gpiochip0` (`4a310000`) has no line 6
requested, and the RTC block reads exactly its reset defaults. Same defect class
as the NFC pinmux (2026-07-03) and the ethernet NENABLE pad (2026-07-06): the
right signal named, the wrong pad muxed.

**Fix (kernel 6.18.48-r2, DTS):** `msecure_pins` → `OMAP4_IOPAD(0x054,
PIN_OUTPUT | MUX_MODE3)`; a `msecure_hog` in `&gpio1` (line 6, output-high,
line-name `msecure`, beside the tps62361 one); and `&twl { pinctrl-0 =
<&twl6030_pins &msecure_pins>; }` after the dtsi includes, so the PMIC's own
pinctrl carries the gpio route instead of upstream's mode-2 group — overriding
the consumer is what avoids two groups claiming one pad (pinctrl-single
`-EBUSY`). Expected after boot: `0x48:0x10 = 0x01`, `0x11` bit 7 clear,
`since_epoch` advancing, `hwclock -r` returning, `RTC_SYSTOHC` finally having
something to write to. `Power up reset detected.` will still appear after a
mains unplug — there is no backup cell; stock had that too and Android re-set
the RTC on every time sync.

Found along the way: `kernel/patches/0003` is the *base* DTS and 0040/0042/0043
layer on top, but `scripts/regen-dts-patch.sh` dumped the whole source into
0003 — it had not been run since 0043 was added (2026-07-16), and the source
copy of the 0040/0043 hunks had drifted from the patches in comment wording.
The script now reverse-applies the later patches to produce 0003 and refuses to
write it unless 0003 + the series reproduces the source byte for byte; the
source was realigned to the series first.

#### Verified on the device 2026-09-17

Delivered with no cable: kernel-only build (`scripts/build-kernel-boot.sh` →
`linux-google-steelhead-6.18.48-r2.apk`, kernel+dtb 5 758 924 B; the on-device
boot.img with the carried ramdisk 6 719 488 B), scp'd to the Prague Q,
`nq-kernel-ota stage-apk` (identity carry: **0 properties patched** — this unit's
DTB already holds its own MAC/BD_ADDR), `nq-kernel-ota try` attended at
21:21:55Z, booted from the trial slot; the **health-gated autopromote copied
slot B → A at 23:23:41 CEST**, slot-A backup kept at
`/var/lib/nexusq-kernel-ota/slot-a-backup.img`. The Prague Q runs `6.18.48-r2`
from slot A.

Read-only, about a minute into that boot:

| Check | Result |
|---|---|
| `uname -r` | `6.18.48-r2` |
| `/sys/kernel/debug/gpio` | `gpio-6 (msecure) out hi` |
| pad `0x4a31e054` | **`0x0003`** (was `0x0002`) |
| pinctrl | `pin 10 (4a31e054): 0-0048 … function msecure-pins group msecure-pins` |
| `i2cget 0x48 0x10` / `0x11` | `0x01` (`STOP_RTC` set = running) / `0x02` (`POWER_UP` cleared) |
| `since_epoch`, 3 s apart | `1789680197` → `1789680200` |
| `hwclock -r` | `2026-09-17 23:23:20.089871+02:00` |
| `timedatectl` | RTC time == Universal time, `System clock synchronized: yes` |
| `dmesg -l err,warn` | **one** line: `twl_rtc … Power up reset detected.` |

That one line is expected after a mains power-cycle and will keep appearing:
there is no backup cell, so the RTC survives **warm reboots** only — a mains
unplug resets it to 2000-01-01, PID 1 then jumps to systemd's build epoch as
before, and the RTC reads real time again once NTP lands and `RTC_SYSTOHC`
writes it back. What is gone is the freeze *within* a boot and, with it, the
build-epoch clock on every warm reboot of a unit that has synced once.
Not shipped: `/usr/lib/clock-epoch` (still an optional follow-up). Not yet done:
the r2 apk is **not published** to the OTA repo and no release is cut; the
cottage Q is still on v1.15.2 (last recorded 2026-09-05). The full `nexusq-diag`
sweep on r2 ran separately and is not reported here.

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

#### And across a reboot — 2026-09-17 23:43 CEST

The verification above left one thing unproven: the first r2 boot inherited r1's
frozen counter, so it still printed `Power up reset detected` and set the clock
to 2000-01-01 before timesyncd corrected it. Only a boot that *reads* the RTC
back settles it. Warm reboot at 21:43:21Z, ssh back in 92 s:

```
[   14.949584] twl_rtc 48070000.i2c:twl@48:rtc: setting system clock to 2026-09-17T21:44:09 UTC (1789681449)
```

`Power up reset detected` count **0**; the journal's first kernel line stamped
`2026-09-17T23:43:45+02:00`; **`dmesg -l err,warn` empty**. The RTC had been the
only err/warn line left on a boot log that has otherwise been clean since
v1.6.10.

What is still true: there is no backup cell, so a **mains unplug** resets the RTC
to 2000-01-01 and the pre-NTP window comes back for that one boot. Stock behaved
the same way (Android re-set the RTC on every time sync). `/usr/lib/clock-epoch`
would make that window land on the image's build date rather than systemd's —
still not shipped, still optional.
