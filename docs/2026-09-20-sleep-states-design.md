# 2026-09-20 — Sleep states: what is actually wrong, and a design

A user asked for a sleep mode ([Discussion #3](https://github.com/petronijus/nexusQ-reloaded/discussions/3),
@GlitchedCod):

> **Sleep mode**: If the device isn't in use it goes into a sleep mode, got the
> CPU to the smallest power consumption usage possible and maybe even a settings
> to disable the LEDs completely and it can start again with a press on the mute
> button (max sleep mode) or if a device connect to it again (sleep mode with
> network and Bluetooth support). The orb start being very hot even if it's not
> in use and consume a lot of energy for nothing.

He is right, and the measurements below say the reason is worse — and more
fixable — than "we never got round to the deep C-states".

## 1. The headline: MPU and CORE retention is never *asked for*

⚠️ **This section was wrong in its first version and is corrected here.** The
first reading of the evidence claimed the power domains "never transition" and
that the one transition we attempt "fails silently". Both were misreadings. What
follows is what the measurements actually support.

`/sys/kernel/debug/pm_debug/count` after 2.4 h of uptime shows zeros:

```
mpu_pwrdm   (ON), OFF:0, RET:0, INA:0, ON:1
cpu0_pwrdm  (ON), OFF:0, RET:0, INA:0, ON:1
cpu1_pwrdm  (ON), OFF:0, RET:0, INA:0, ON:1
core_pwrdm  (ON), OFF:0, RET:0, INA:0, ON:1
```

**Those counters are not evidence of anything.** `state_counter[]` and
`state_timer[]` are only updated by `_pwrdm_state_switch()`, which on OMAP4 is
driven from the idle path — the one patch 0024 disabled. They read zero because
the accounting never runs, not because the hardware never moves. Reading them as
"nothing ever transitions" was the first mistake.

What *is* true, and rests on the code rather than the counters: with only C1
registered, nothing ever programs `mpu_pwrdm` or `core_pwrdm` to RET or OFF.
`omap4_enter_lowpower()` is the only caller that would, and it is reached only
from the deep C-states and from suspend, neither of which ever runs here. So MPU
and CORE retention genuinely never happens — because it is never requested, not
because it is refused.

That is still the answer to "the orb gets hot for nothing", and it still means
every idle-power fix this port has shipped — the conservative governor, the
350 MHz OPP work, the `Nice=19` sweep, the pid-1 churn — has been shaving *load*
on a chip whose big power domains are pinned ON. But the fix is "ask for it",
not "find out why the hardware refuses".

## 2. The hard part already works: CPU1 really does power off

CPU hotplug goes through the same `omap4_enter_lowpower()` machinery as the deep
idle states, so it is a free test of that path — including the HS secure calls.

The test that settles it. `pwrdm_dbg_show_counter()` compares the *software's*
cached state against a live hardware read every time `pm_debug/count` is read:

```c
if (pwrdm->state != pwrdm_read_pwrst(pwrdm))
        printk(KERN_ERR "pwrdm state mismatch(%s) %d != %d\n",
               pwrdm->name, pwrdm->state, pwrdm_read_pwrst(pwrdm));
```

With `OFF=0, RET=1, INACTIVE=2, ON=3`, reading that file at three moments:

```
CPU1 online   -> no cpu1 line                          (hardware reads ON)
CPU1 offline  -> pwrdm state mismatch(cpu1_pwrdm) 3 != 0   (hardware reads OFF)
CPU1 online   -> no cpu1 line
```

**`cpu1_pwrdm` genuinely reaches OFF.** The second mistake was reading `3 != 0`
as "programmed OFF, read back ON" — the argument order is (cached, live), so it
says the opposite. The same lines for `cam`, `ivahd`, `tesla`, `abe` and `gfx`
mean those domains were powered off by runtime PM at that instant, which is also
good news rather than bad.

So the MPUSS low-power path works on this HS OMAP4460: the CPU powers off, the
secure resume path runs, and the CPU comes back. Supporting evidence for the
secure side: the PPA shipped in `xloader-phantasm-ian67k.img` reports
`-- PROD PPA RC5.0 --` and version **1.7.5**, comfortably over the **1.4.0+**
that `sleep44xx.S` requires for the CPU1 `NS_SMP` API. (Worth knowing anyway:
that path, `ppa_actrl_retry`, is an *infinite* retry loop on a failed secure
call, so a PPA that did not answer would hang CPU1 on resume rather than return
an error — a plausible shape for the historical CPU1 cpuidle panic, though that
is now a hypothesis about the past, not a present fault.)

## 3. Idle profile, measured with nobody logged in

180 s sample, no ssh session attached (an open session heats the die and
skews it):

| | |
|---|---|
| temperature | 53.1 °C average, 57.4 °C max |
| CPU busy | ~13 % of one core, doing nothing |
| 350 MHz residency | **91.8 %** (700/920/1200 MHz share 8 %) |
| wakeups | **368/s** — one every 2.7 ms |

The governor is doing its job; the wakeup rate is not. On a tickless kernel
(`CONFIG_NO_HZ_IDLE=y`, `HZ=100`) an idle two-core system should be well under
20 wakeups/s. We are 17× over.

### Where the wakeups come from

30 s ftrace, again with nobody logged in:

```
hrtimer callbacks/s          tasks woken/s
164.5  tick_nohz_handler      84.0  alsa_buf_mon
 93.4  hrtimer_wakeup         51.1  kworker/u9:3
  9.8  ehci_hrtimer_func      41.7  kworker/1:0
  2.8  timerfd_tmrproc        26.3  python3
                              23.4  arecord
timer callbacks/s             18.6  kworker/0:2
 23.4  loopback_jiffies_timer  16.8  rcu_sched
 19.3  delayed_work_timer_fn   10.1  irq/116-4807200
  9.0  tcp_orphan_update        9.9  dbus-broker
  8.9  process_timeout          8.4  brcmf_wdog/mmc4
  5.7  brcmf_sdio_watchdog      7.1  avahi-daemon
```

`tick_nohz_handler` is a symptom (it fires when a CPU is *not* idle), so read the
task column. **The audio path is the largest single idle consumer** —
`alsa_buf_mon` (a PulseAudio thread) at 84/s, `arecord` at 23.4/s and
`loopback_jiffies_timer_function` at 23.4/s are one phenomenon: the LED ring's
audio visualiser runs `arecord` against the PulseAudio monitor source, which
keeps PA, the snd-aloop card and its jiffies timer awake permanently — including
when the device is silent and there is nothing to visualise.

**Note this is not the LED ring itself.** Petr is handling the ring separately;
what is described here is the *capture tap that feeds it*, which can stop while
the ring keeps doing whatever it does, because capturing silence produces
nothing to show.

Second: WiFi, at `brcmf_sdio_watchdog` 5.7/s + `brcmf_wdog/mmc4` 8.4/s + 52/s of
`mmc4` interrupts. Third: the three Python daemons at a combined 26.3/s, which
is modest and not where to start.

## 4. What stock did — and why our own reason for C1-only does not hold

Our `kernel/patches/0024-ARM-OMAP4-cpuidle-steelhead-C1-only.patch` trims cpuidle
to C1 and justifies it like this:

> the C2/C3 MPUSS power transitions trap into the secure monitor, which the HS
> secure side rejects with SMP online (stock 3.0.8 guards the same paths with
> `cpuidle44xx.disallow_smp_idle`)

Both halves of that are now in doubt.

**The stock cmdline does not contain that parameter.** From
`reverse-eng/stock-eth-working-state-2026-06-24.txt`:

```
console=ttyFIQ0 androidboot.console=ttyFIQ0 mem=1G vmalloc=768M
omap_wdt.timer_margin=30 no_console_suspend androidboot.bootloader=steelheadB4H0J …
```

The knob exists in the stock binary — `disallow_smp_idle`, `only_state`,
`max_state`, `keep_mpu_on`, `keep_core_on`, `skip_off` — but all six live in
**`.bss`** (kallsyms type `b`), which is zero-initialised, and none is set on the
command line. Stock therefore ran with all of them at their defaults.
(`no_console_suspend` being present is itself a hint that stock suspended.)

**And stock offered four idle states, three of which switch both CPUs off.**
Decoded from `omap4_init_power_states` (`0xc0068768`) filling
`omap4_power_states` (`0xc0740e58`), four entries at stride 0x20 with their
description strings:

| # | description | exit latency / target residency |
|---|---|---|
| 0 | `CPU WFI` | 4 µs / 5 µs — this is our C1 |
| 1 | `CPUs OFF, MPU + CORE INA` | 1100 µs |
| 2 | `CPUs OFF, MPU + CORE CSWR` | 1200 µs |
| 3 | `CPUs OFF, MPU CSWR + CORE OSWR` | 1500 µs |

So the same HS OMAP4460, on the same board, ran CPUs-OFF states with SMP online.
Stock's coupling is hand-rolled — a spinlock, a per-CPU requested state,
`_find_next_bit_le`, and explicit GIC distributor/CPU-interface save and
restore — rather than the kernel's coupled-cpuidle framework.

**Mainline is not missing HS support.** `omap-mpuss-lowpower.c` writes the device
type into the SAR scratchpad for the low-level code
(`writel_relaxed((omap_type() != OMAP2_DEVICE_TYPE_GP) ? 1 : 0, sar_base + OMAP_TYPE_OFFSET)`)
and `arch/arm/mach-omap2/Kconfig` has `select ARCH_NEEDS_CPU_IDLE_COUPLED if SMP`.
The machinery is there; this port has simply never exercised it beyond hotplug —
and §2 shows that hotplug's own power-down is not working either.

Those residency numbers matter for the plan: the deep states need **1.1–1.5 ms**
of predicted idle, and we currently wake every **2.7 ms**. Even with the states
registered and working, the menu governor would pick them only sometimes. The
wakeup rate has to come down first or the C-states buy far less than they look.

## 4b. MEASURED: `freeze` hangs the device. R3 is blocked.

Tried on 2026-09-20 with Petr's explicit go-ahead, and it cost a reboot. Writing
this down in full because the negative result is worth more than the attempt.

The probe armed an RTC alarm first and logged to a file (`/tmp` survives a reboot
on this rootfs, which is the only reason any of this is known):

```
-- power domains BEFORE --   mpu/core/cpu0/cpu1/l4per all (ON), all counters 0
   uptime=11072.16s  temp=52437
   wakeup sources armed: twl@48:rtc, 4809c000.mmc, 480d5000.mmc,
                         alarmtimer.2.auto, musb-hdrc.0.auto
   rtc since_epoch=1789913934  alarm=1789913964  (+30s)
-- writing 'freeze' to /sys/power/state --
```

…and nothing after it. **The write never returned.** The box went off USB
(no enumeration, no `/dev/ttyACM*`), off WiFi (no ARP anywhere on the /24), sat
dead for about 14 minutes and then reset itself. `pstore` is empty afterwards, so
there was no kernel panic to capture, and mainline prints no reset reason, so the
~14 minutes remain unattributed.

Note this was **`freeze`, the gentler of the two** — suspend-to-idle touches
neither the power domains nor the secure monitor. `mem` is strictly more
dangerous and must not be tried next.

### What it was *not*

Two hypotheses formed and killed, both safely, while the box was awake:

* *"The TWL6030 interrupt path is dead"* — `/proc/interrupts` showed
  `TWL6030-PIH 0` and `rtc0 0` since boot, which looked damning. But arming an
  alarm for +15 s with the system awake moved both to 1 and cleared the
  `wakealarm` file. **The RTC alarm and its interrupt work.**
* *"The RTC is not registered as a wakeup source"* — it is:
  `/sys/kernel/debug/wakeup_sources` lists `48070000.i2c:twl@48:rtc` with events
  recorded, and its `device/power/wakeup` reads `enabled`.

So the alarm fires, the interrupt arrives, and the source is registered — and the
system still did not come back. The remaining suspects are a device
suspend/resume callback that deadlocks, or the s2idle loop being unexitable
because the TWL's *threaded* handler cannot do its i2c reads once the i2c adapter
is suspended (a classic for PMIC-behind-i2c wake sources). Distinguishing them
needs to see the kernel talking while it happens.

### The process failure, which is the real lesson

The safety net was "two network paths" — the USB gadget and WiFi. That is not
redundancy: **both depend on drivers resuming**, so both fail together, which is
exactly what happened.

There is **no serial console on this board and there will not be one**, so the
answer is not "attach a UART" — it is to stop flying blind by other means:

* **`/sys/power/pm_test`** (CONFIG_PM_DEBUG is on) runs the suspend machinery up
  to a chosen phase — `freezer`, `devices`, `platform`, `processors`, `core` —
  and returns by itself after ~5 s. A level that comes back is a level that
  works; the level that does not come back is the answer. This is how a suspend
  hang should be bisected, and it should have been the first move rather than a
  full `freeze`.
* **Write progress to a file with a `sync` behind every line.** `/tmp` is on the
  ext4 root here, not tmpfs, so a probe's own log survives the reboot it causes —
  which is the only reason anything is known about the attempt above.
* **The journal is persistent**: `journalctl -b -1` reaches the boot that died.
* **Reboots are an acceptable price.** They are not something to avoid at the
  cost of learning nothing; they are the cost of each experiment, so make each
  experiment worth one.

## 4c. ROOT CAUSE: the TWL6030 cannot wake s2idle, by construction

`pm_test` walked the whole suspend machinery and **every applicable phase
passed** — so nothing in the port is broken:

```
freezer     rc=0   froze and thawed userspace
devices     rc=0   suspended and resumed everything, incl. smsc95xx eth0 and
                   brcmfmac (which reloads its firmware on resume)
platform    rc=0   incl. the late/noirq phases
processors  rejected: "Unsupported test mode for suspend to idle"
core        rejected: likewise
```

(The last two only apply to suspend-to-RAM, not s2idle.) The hang therefore lies
in the one part `pm_test` skips: the s2idle loop itself. The system suspends
correctly and then **never receives a wakeup**.

`drivers/mfd/twl6030-irq.c` says why:

```c
case PM_SUSPEND_PREPARE:
        chained_wakeups = atomic_read(&pdata->wakeirqs);
        if (chained_wakeups && !pdata->irq_wake_enabled) {
                enable_irq_wake(pdata->twl_irq);      /* wake IS propagated */
                ...
        }
        disable_irq(pdata->twl_irq);                  /* ...and then disabled */
        break;
case PM_POST_SUSPEND:
        enable_irq(pdata->twl_irq);
```

The parent PIH interrupt is **disabled for the duration of the suspend**. For
suspend-to-RAM that is harmless: the wake happens in hardware at the PRCM/WUGEN
level, below the disabled Linux IRQ, and `PM_POST_SUSPEND` re-enables it on the
way out. **s2idle has no such hardware path** — it relies on the interrupt
actually firing and breaking the loop. With the PIH disabled, the RTC alarm can
never do that, no matter that the alarm fires and the wake flag is set.

So nothing here is our bug, and nothing needs fixing to move on. It also flips
the earlier advice in §4b: `mem` is not "more dangerous because `freeze` failed"
— `mem` is the mode whose wake path is actually wired, and it is the one to try.

Two smaller things the bisect turned up, neither fatal:

* `l4-per-clkctrl:0060:0 / :0048:0 / :0040:0: failed to disable` during the noirq
  phase — three L4-PER clocks refusing to gate. Worth chasing once suspend works,
  because a clock that will not gate is a domain that will not retain.
* Resume costs ~1.4 s, most of it `brcmfmac` reloading BCM4330 firmware.

### The safety net that actually works

`drivers/watchdog/omap_wdt.c` has **no system suspend/resume handlers**, so the
watchdog keeps its hardware state across a suspend, and its WDT sits in the
always-powered WKUP domain. Arming it and then letting userspace freeze (so
nothing can ping it) gives a hard reset in N seconds — a net that does **not**
depend on any driver resuming, which is exactly what the previous attempt lacked.

## 4d. Suspend-to-RAM did not come back — and the conclusion I drew was too big

`mem` was tried with a watchdog as the net. The probe's own log, recovered from
ext4 afterwards:

```
   watchdog armed, timeout=60s (asked 60)
   rtc since_epoch=1789916276  alarm=1789916306
>>> writing 'mem' to /sys/power/state
```

Nothing after it. The box hung, and **the watchdog did not reset it** despite
arming correctly and reporting the timeout back. Nor did anything else:

| way back | result |
|---|---|
| RTC alarm at +30 s | did not wake it |
| OMAP watchdog at +60 s | did not reset it |
| touching the dome / mute key (AVR on gpio_49) | did not wake it |
| unplugging and replugging USB (`musb-hdrc` **is** an armed wake source) | did not wake it |
| pulling the mains | the only thing that worked |

⚠️ **I first wrote this up as "suspend-to-RAM has no working way back at all".
That was an overreach and Petr called it:** what was measured is that *this
attempt* did not come back, which is a weaker claim. Worse, it silently merged
two completely different failures — *suspended and could not be woken* versus
*hung while suspending* — and nothing above distinguishes them. §4e does.

Two corrections to reasoning that looked sound and was not:

* *"`omap_wdt` has no suspend/resume handlers and sits in the always-powered WKUP
  domain, so it keeps counting."* It does not. The driver indeed has no PM ops,
  but the **hardware** stops, because the PRCM gates its functional clock during
  the suspend. A watchdog is not a net for a suspend on this SoC.
* *"`mem` is the mode whose wake path is actually wired."* Also wrong — see the
  table. §4c's reasoning about `disable_irq()` on the PIH was correct as far as
  it went, but fixing s2idle's wake would not have helped, because `mem` cannot
  wake either.

**The method lesson, twice over:** both attempts were protected by a safety net
that had been *derived* rather than *measured* — first "two network paths"
(which both need drivers to resume), then the watchdog (which stops with its
clock). The repo already has the rule for this in another form —
a test must be seen failing — and it applies to the net as much as to the test.
**Arm a net and watch it fire, in isolation, before trusting it.**

One thing in the BEFORE counters is worth keeping, because it is the first
positive evidence of any kind:

```
l4per_pwrdm (ON), OFF:0, RET:1, INA:0, ON:2
```

`l4per_pwrdm` reached **retention once** — during the `pm_test platform` run.
So the accounting does work, and retention on this board is not impossible in
principle. MPU and CORE stay at zero only because `pm_test platform` stops before
reaching them.

### What this does to the ladder

R3 and R4 cannot be finished until §4e's remaining unknown is resolved.

That leaves **R2 (register C2/C3)** as the only remaining route to MPU/CORE
retention, and it is also the one that needs no wake source at all: a C-state is
left by any ordinary interrupt, with no suspend, no frozen userspace and no
wakeup plumbing. It needs a kernel rebuild and a flash, not an experiment on a
running box. **R0 stays worth doing in parallel**, because the deep states need
1.1-1.5 ms of predicted idle and the box currently wakes every 2.7 ms.

## 4e. Localised: everything up to `syscore_suspend()` works

The bisect in §4c was run by writing **`freeze`**, which takes the `s2idle_loop()`
branch in `suspend_enter()` *before* the deeper levels are reached — so the kernel
rejected `processors` and `core` as "unsupported for suspend to idle". I read that
as a fact about the hardware. It was a fact about my choice of mode. Re-run with
**`mem`**, both levels are valid:

```
freezer     rc=0
devices     rc=0
platform    rc=0
processors  rc=0     suspend_disable_secondary_cpus() and back
core        rc=0     + arch_suspend_disable_irqs() + syscore_suspend()
```

**All five returned.** `core` runs everything and then skips exactly one call:

```c
        error = syscore_suspend();
        if (!error) {
                if (!(suspend_test(TEST_CORE) || *wakeup)) {
                        error = suspend_ops->enter(state);   /* <- only this is untested */
                }
                syscore_resume();
        }
```

So the whole preparation — freezing, device suspend, the platform and noirq
phases, disabling the secondary CPU, disabling IRQs, `syscore_suspend()` — is
sound. The failure is confined to `suspend_ops->enter()`, i.e. OMAP4's
`omap4_pm_suspend()` → `cpu_suspend(0, omap4_finish_suspend)`: the MPUSS
power-down itself, or the return from it. **Which of those two it is remains
unknown**, and that is the honest state of it.

One suspect worth naming, from §4c's reading of `sleep44xx.S`: `omap4_cpu_resume`
enters `ppa_actrl_retry`, an **infinite** retry loop around a secure PPA call, on
HS devices. A CPU that comes out of MPUSS OFF and cannot get that call answered
spins there forever — which looks exactly like "suspended, never returned", with
no watchdog (its clock is gated) and no way out but the mains. That is a
hypothesis, not a finding: the loop is guarded by an MPIDR test that skips CPU0,
and CPU0 is the one that resumes first.

### Consequence for R2, which is not obvious

R2 registers C2/C3, and those go through **the same `omap4_enter_lowpower()`**
that the untested `suspend_ops->enter()` reaches. So R2 may well meet the same
wall — on every idle, not once per experiment. Two things differ and may matter:
a C-state is left by an ordinary interrupt with no `syscore_suspend()` behind it,
and C2/C3 target MPU CSWR/OSWR rather than device OFF. Worth going in with eyes
open rather than assuming R2 is the safe one.

## 4f. Resolved: it sleeps and does not wake — and ramoops has never worked

> **The ramoops half of this heading is WRONG — see §4i.** ramoops captures
> crashes correctly; the records are archived to `/var/lib/systemd/pstore/`
> and unlinked from `/sys/fs/pstore` by `systemd-pstore.service` at boot. The
> sleep findings in this section are unaffected.

Two things measured in isolation, which is what should have happened before any
suspend was attempted.

### The watchdog works, and it answers §4e

Armed for 30 s at uptime 314.6 s and deliberately not petted, with no suspend
involved:

```
   armed, timeout=30s — NOT petting it, NOT suspending
   a working watchdog resets this board at about uptime=345s
   +25s still alive (uptime=339.8s)        <- last line written
```

…and the board came back at uptime 33 s. **It fired on schedule.** So
`omap_wdt` does reset this board when the SoC is awake.

That settles the question §4e left open. The watchdog did **not** fire during
the suspend attempt, and gating its clock is part of the low-power transition
itself — so had the CPU wedged *before* that transition, the watchdog would still
have been clocked and would have fired. It did not. **The board genuinely goes to
sleep and does not come back: the failure is on resume, not on the way down.**

That puts `omap4_cpu_resume` in `sleep44xx.S` squarely in the frame, including
its infinite `ppa_actrl_retry` loop around a secure PPA call.

### ramoops captures nothing, and never has

`pstore` is empty after a watchdog reset **and** after a deliberate
`echo c > /proc/sysrq-trigger` panic. Not "lost because the mains was pulled" —
it captures nothing at all, from anything.

It is configured and the kernel accepts it:

```
ramoops.mem_address=0xbf000000 ramoops.mem_size=0x100000
ramoops.console_size=0x80000 ramoops.record_size=0x20000 ramoops.dump_oops=1
[    0.175903] pstore: Registered ramoops as persistent store backend
[    0.175903] ramoops: using 0x100000@0xbf000000, ecc: 0
```

**Likely cause:** `mem=1008M` ends the kernel's map at exactly `0xBF000000`, and
ramoops is placed in the first megabyte above it — which is the **top of DRAM**,
where U-Boot 2011.09 relocates itself, its stack and its heap on every boot. The
region is outside the kernel, as it must be, but it is not private: the
bootloader owns it by the time Linux looks.

**Likely fix:** reserve the region properly through the device tree
(`reserved-memory` with `compatible = "ramoops"`) so it sits inside
kernel-managed DRAM and well away from the top, rather than being carved out by
`mem=` and hoped over. That is a DTS + defconfig change, so it rides a kernel
rebuild.

This matters beyond this investigation: the cmdline carries these parameters, the
repo's docs refer to ramoops as the post-mortem channel, and it has been giving a
false sense of security. The forensics that *do* work here are the persistent
journal (`journalctl -b -1`) and a probe writing to `/tmp` on the ext4 root with
`fsync` behind each line.

## 4g. ramoops: the data survives, the header does not

> **Superseded by §4i — this section describes a bug that does not exist.**
> Every "pstore is EMPTY" reading below came from `/sys/fs/pstore`, which
> `systemd-pstore.service` drains and unlinks at boot. ramoops recovers the
> buffer correctly; the zeroed counters are it zapping a zone it had already
> read out, not a failure. The archive is `/var/lib/systemd/pstore/`.

§4f said ramoops "captures nothing" and blamed the region's placement. Both the
long-standing repo explanation and mine were wrong, and the measurements say
something more useful.

**DRAM is not scrubbed.** Distinct markers written through `/dev/mem` every 2 MB
across `0xBF000000`-`0xBFE00000`, then a watchdog reset (confirmed by a `boot_id`
change, not by guessing from uptime):

```
0xbf000000  gone (DBGC…)      0xbf800000  SURVIVED
0xbf200000  SURVIVED          0xbfa00000  SURVIVED
0xbf400000  SURVIVED          0xbfc00000  SURVIVED
0xbf600000  SURVIVED          0xbfe00000  SURVIVED
```

Seven of eight came back with the right timestamp. The eighth is not clobbered by
anything foreign: `DBGC` is `PERSISTENT_RAM_SIG` (`0x43474244`) — ramoops' own
signature, written by the kernel.

**And the console text survives too.** Writing a unique marker to `/dev/kmsg` and
resetting:

```
marker visible in the region BEFORE the reset: True
marker present in raw DRAM AFTER the reset:    True   at phys 0xbf07e01b
/sys/fs/pstore:                                EMPTY
context: …DBGC \x00×8 [   84.946685] NQ-RAMOOPS-MARKER-… seq=0
```

So the text persists and pstore refuses to expose it. The context says why:
behind the `DBGC` signature sit **eight zero bytes** — `start = 0`, `size = 0` —
followed by perfectly intact log text. The buffer's *header* did not survive, so
the zone looks empty and its contents are discarded.

**Suspected cause:** the region is mapped **write-combine** (`mem_type = 0`, the
default; `MEM_TYPE_WCOMBINE` in `fs/pstore/ram_core.c`). The data is written
sequentially and drains; the header is the one location rewritten on *every*
message, and is still in the write buffer when the reset lands.

**Candidate fix:** `ramoops.mem_type=1` (`MEM_TYPE_NONCACHED`) on the cmdline —
no kernel code change, just `scripts/extract-and-repack.sh`'s `CMDLINE` and a
boot.img flash. Testable with the same probe: if pstore comes back non-empty
afterwards, it is fixed.

### Five tooling errors, all of which looked like data

Worth recording because the pattern cost more than the experiments did. Each of
these produced a confident wrong answer:

1. `pm_test` driven by writing **`freeze`** — takes the s2idle branch first, so
   `processors`/`core` are rejected; I read that as a hardware fact.
2. `m.flush()` on a `/dev/mem` mapping — `msync` is unsupported there, the
   exception swallowed a **successful** write and logged "WRITE FAILED".
3. Reboot detected as **`uptime < 150`** — true without any reset, so a write and
   its read ran on the same boot and the "verdict" was fiction. Now: compare
   `/proc/sys/kernel/random/boot_id`.
4. `open("/dev/kmsg", "w")` — Python's `"w"` is `O_TRUNC`, which is `EINVAL` on
   that device; the probe died one line in.
5. Default kmsg priority against **`loglevel=4`** — `KERN_INFO` never reaches the
   console, so it never reaches ramoops; `dmesg` showed it and made it look fine.
   Needs `<1>`.

The countermeasure that actually worked: **make every probe verify itself** — log
`boot_id` on both sides, assert the marker is visible *before* the event, and
`fsync` each line to the ext4 root so the record outlives the board.

## 4h. R0 measured properly: what actually pulls the CPU out of idle

Two earlier attempts at this were wrong and are worth recording as much as the
answer.

**Wrong #1 — ftrace `sched_wakeup` counts.** They count wakeups of a *task*,
which is not the same as the CPU leaving idle: a wakeup on an already-busy CPU
costs nothing. shairport's 87 thread-wakeups/s turned out to be ~29 idle exits.

**Wrong #2 — an A/B sweep that stopped each service in turn.** Invalid by
construction: stopping and restarting a service makes churn that spills into the
next 25 s window, so every window read higher than the one before and the
"restored" baseline came back **68 % above** the original (226 → 380 wakeups/s),
producing nonsense like "nq-healthd costs -530 wakeups/s". Back-to-back
stop/measure/start cycles never settle. Deleted, not kept.

**Right — trace the thing itself, passively.** `power:cpu_idle` fires on entry
and exit (`state=4294967295`); for each exit, the next `sched_switch` on that CPU
names what got the processor. Nothing is stopped, so there is no churn and no
drift. 60 s, everything enabled:

```
466 idle exits/s

what ran right after the exit        interrupts taken coming out of idle
   34.5/s  alsa_buf_mon                 125.2/s  twd  (the local timer)
   11.2/s  python3                       65.8/s  IPI
   10.7/s  kworker/u9:0                   7.8/s  mmc4
    8.6/s  arecord                        6.0/s  omap-dma-engine
    6.7/s  rcu_sched                      4.3/s  48072000.i2c
    4.3/s  irq/116-4807200                2.1/s  48055000.gpio
    2.8/s  dbus-broker                    2.1/s  brcmf_oob_intr
    2.3/s  brcmf_wdog/mmc4
```

The tasks sum to ~95/s against 466 exits, so **most idle exits are an interrupt
serviced with no task switch at all** — the CPU wakes, handles it, and goes
straight back. The dominant single source is the local timer at 125/s, and the
timers being armed are overwhelmingly userspace ones.

`alsa_buf_mon` — shairport-sync's ALSA buffer monitor — is the largest single
task cause and the largest single timer armer, at 86 nanosleeps/s whether or not
anything is playing.

### The shairport knob does not work

`disable_standby_mode_silence_scan_interval = 0.5` changes nothing: still 86/s.
It only applies when `disable_standby_mode` is not `"never"`, and `"never"` is
the default (the binary says so: *"It should be `always`, `auto` or `never`. It
remains set to `never`"*). The monitor thread runs **unconditionally** on a fixed
~11.6 ms interval. There is no configuration that stops it, so the device config
was reverted rather than left carrying a setting that looks effective and is not.

Fixing it therefore means patching or bumping `shairport-sync` itself — a package
change, not a config one. Worth doing on correctness grounds (a daemon has no
business waking a box 86 times a second through silence) rather than for the
degrees it saves, which are within noise.

## 4i. RESOLVED: ramoops works. `/sys/fs/pstore` was the wrong place to look

§4f said "ramoops has never captured anything" and §4g built a cause on top of it.
Both were measuring the wrong thing. **ramoops captures crashes correctly**, and on
this device it very likely always did.

`systemd-pstore.service` runs at boot, copies every pstore record into
`/var/lib/systemd/pstore/` and then **unlinks it from pstorefs** (`Unlink=yes`, the
default). So `/sys/fs/pstore` is empty a second after boot *by design*. Every
"pstore is EMPTY" reading in this document — and every conclusion drawn from one —
was taken from a directory systemd had already drained.

The records were there the whole time:

```
/var/lib/systemd/pstore/console-ramoops-0   19357 B
/var/lib/systemd/pstore/dmesg-ramoops-0     76075 B
```

and they contain exactly what they should. The console record holds all 300
deliberately-injected probe lines and the shutdown that followed:

```
[  135.057922] NQ_PANIC_COUNTER_PROBE line 0 padding-padding
...
[  138.855529] Rebooting in 120 seconds..
```

and the dump record holds the crash itself:

```
<6>[  138.807647] sysrq: Trigger a crash
<0>[  138.811279] Kernel panic - not syncing: sysrq triggered crash
<4>[  138.831604]  unwind_backtrace from show_stack+0x10/0x14
```

**So the whole chain reads differently.** The zone counters coming back as 0 after a
reset is not a failure — it is ramoops having *successfully* recovered the old
buffer, handed it to pstore and zapped the zone for reuse, which is what
`persistent_ram_zap()` is for. The payload left visible in raw DRAM is the orphaned
remains of a buffer that had already been read out. Nothing was ever broken.

**What this means for `ramoops.mem_type=1`.** It is flashed (kernel `6.18.48-r3`) and
the device captures crashes with it. Whether `mem_type=0` would capture them just as
well was never actually tested, because the test used to be "is `/sys/fs/pstore`
non-empty". Treat the parameter as unproven rather than as a fix: it is harmless and
in place, and there is no longer a symptom motivating a change either way.

**How to read a crash on this device, correctly:**

```sh
ls -la /var/lib/systemd/pstore/          # records archived at boot
grep -i "Kernel panic" /var/lib/systemd/pstore/dmesg-ramoops-*
```

Do **not** use `/sys/fs/pstore` as evidence of anything after boot, and do not read
an empty one as "the reset was clean".

**Worth doing (not done):** `/var/lib/systemd/pstore/` lives on the rootfs, so a
flash wipes the entire crash history. It belongs in the persist store next to the
ssh host keys and Bluetooth bonds, so a unit's crash record survives a reflash.

### Three traps, all of which produced confident wrong answers

1. **`/sys/fs/pstore` is drained by `systemd-pstore.service` at boot.** The archive
   is `/var/lib/systemd/pstore/`. This one invalidated two sessions' conclusions.
2. **`loglevel=4` filters the probe away.** A `<4>` message never reaches any
   console, ramoops included, so injected probe lines produced zero hits in the
   region and looked exactly like "the console backend writes nothing". Only `<1>`
   and friends pass.
3. **"It answered `ssh`, so it rebooted" is false.** With `(sleep 1; systemctl
   reboot) &`, an `until ssh true` loop connects to the still-running system before
   the reboot lands. Confirm a reset by `boot_id` or uptime, never reachability.

## 5. The design: a ladder, not a switch

Each rung is independently useful, independently testable, and does not depend on
the ones above it.

### R0 — cut the wakeup rate (no new sleep state at all)

Attack, in measured order: the idle `arecord` tap on the PA monitor (84 + 23 + 23
per second between PulseAudio, arecord and snd-aloop), then the brcmfmac SDIO
watchdog, then the Python daemons' poll loops. Zero risk, immediately lowers
temperature, and it is the **precondition** for anything below it paying off.

### R1 — the LED ring — *excluded from this design.* Petr is doing it differently.

### R2 — register C2/C3, because the path underneath them already works

§2 removes the blocker this rung was assumed to have: CPU OFF through the HS
secure path is demonstrably working, and the PPA is new enough. So this is now
"revert or narrow patch 0024 and see what MPU/CORE do", not "find out why the
hardware refuses". Still test on serial with ramoops armed — the historical
failure was a CPU1 cpuidle panic and `ppa_actrl_retry` can hang rather than
fail — but the prior is much better than it looked.

This is the user's *"sleep mode with network and Bluetooth support"*: the network
stack stays fully up and only the silicon idles deeper.

### R3 — suspend-to-idle (`freeze`) — **BLOCKED, measured**

It hangs the device (§4b). Not "might": tried, hung, cost a reboot. It stays on
the ladder because the idea is still right — freezing userspace stops every one
of those wakeups at once — but it cannot be retried until `ttyS2` is attached and
the hang can be watched rather than inferred.

### R4 — suspend-to-RAM (`deep`)

The user's *"max sleep mode"*. `mem_sleep` already reads `s2idle [deep]`. Wake by
the mute press: the AVR's interrupt is `48055000.gpio` offset 17 = **gpio_49**,
and an OMAP4 GPIO pad can be a wake source, so `enable_irq_wake()` on it is the
mechanism. The real work is not the suspend but the **resume**: every driver has
to come back — BCM4330 firmware, the BT patchram, the AVR, the TAS5713.

## 6. What the user must be told

**The two modes he asked for are mutually exclusive.** "Wake when a device
connects" needs a live network stack for zeroconf (Spotify Connect, AirPlay), and
"max sleep, wake on the mute button" does not have one. R0+R2 (+R3) give the
first; R4 gives the second. A unit can offer both as a setting, but not both at
once.

Also worth saying: this board **cannot wake an HDMI receiver** that has gone to
standby, measured separately today — see
`2026-09-20-hdmi-audio-the-output-that-was-never-offered.md`.

## 7. Order of work, and why

1. **R0**, because it is free, measurable, and is what makes R2 worth having at
   all: the deep states need 1.1-1.5 ms of predicted idle and we wake every
   2.7 ms.
2. **R2**, which is now the cheap one — the machinery under it is proven, so this
   is largely "stop refusing to register the states and measure what happens".
3. **R3**, independent of both, and possibly most of what the user actually wants.
4. **R4**, last, because its cost is the resume path of every driver.

## 4j. R2 ATTEMPTED: the deep states do not fault — they are simply never reached

Kernel `6.18.48-r4` registers C2/C3 with `CPUIDLE_FLAG_OFF`, so they exist with
counters and the governor cannot pick them until one is armed by hand. That made
the experiment finally cheap to run, and it answers a question this project has
carried unexamined since the SMP bring-up.

**C2 was armed on BOTH cpus for 90 s. Nothing faulted.**

```
[BEFORE] mpu_pwrdm (ON),OFF:0,RET:0    cpu0 C2 usage=0   cpu1 C2 usage=0
         disable flags -> cpu0=0 cpu1=0        (armed, both cores, 90 s)
[AFTER]  mpu_pwrdm (ON),OFF:0,RET:0    cpu0 C2 usage=0   cpu1 C2 usage=0
         system: running, 0 failed units, no new kernel err/warn
```

**⚠️ The long-standing premise is not confirmed.** Patch 0024 said "deep C-states
fault — the MPUSS power transitions of C2/C3 trap into the secure monitor, which
the HS secure side rejects with SMP online". With both cores online and C2 armed,
nothing trapped, nothing panicked, the box stayed up. That does **not** prove the
secure path is fine — **C2 was never entered**, so the faulting code never ran.
What it does retire is the idea that merely *offering* the state is dangerous.

**Why it was never entered, measured:**

```
cpu0   176636 idle periods / 137591186 us  ->  mean  778 us
cpu1   137268 idle periods / 112939086 us  ->  mean  822 us

C2     target_residency  960 us    exit_latency  768 us
C3     target_residency 1100 us    exit_latency  978 us
```

The box's mean idle period is **~800 us**. C2 needs 960 us of *predicted* idle and
C3 needs 1100 us, and the `menu` governor predicts conservatively from the recent
distribution, so it is not close — and correctly never selects either. Both cores
are online and both idle heavily (C1 usage 176 k / 137 k), so this is not a CPU1
or coupled-entry problem: it is purely that nothing here is ever quiet for a
millisecond.

**This is what makes R0 a prerequisite rather than a preference, and it puts a
number on it.** Mean idle has to rise above 960 us — call it a third more idle
time per wakeup — before C2 becomes *selectable at all*, never mind profitable.
At 368 idle exits/s that is roughly the wakeup rate the two deliberate pollers
account for. So the ladder's order was right, and R2 cannot be evaluated until
R0 is decided.

**Still unknown, and only reachable after R0:** whether an actually-entered C2
completes or trips the secure monitor. The experiment to run then is the same
one, with the arm held long enough for the governor to pick the state once idle
has grown — `usage` moving off 0 is the signal, and `mpu_pwrdm` RET leaving 0 is
the payoff.

## Where this stands (end of 2026-09-20)

**R0 — in progress, and it is not the bug hunt it looked like.** The two largest
idle wakeup sources are both *deliberate*, not defects:

| source | rate | why it is there |
|---|---|---|
| `alsa_buf_mon` (shairport-sync) | ~29-35/s | unconditional ~11.6 ms poll; no config knob, 5.1-r0 is the newest Alpine has, so it needs a package patch |
| `arecord -D hw:Loopback,1,0` (`nq-uac2-silence`) | ~6-9/s | owns the aloop while ASLEEP **by design** so it can wake on the first non-zero frame — wakeups traded for wake latency |

So R0 is now a **design decision** — how much wake latency are we willing to give
up for depth — rather than a list of things to fix. That call is Petr's and is not
made yet.

Shipped on this rung: `nexusqd` r21 makes the sink-input gate's timed safety net
unconditional (it was unreachable). Installed and verified on the device — idle:
no tap; a stream: tap on; stream ends: tap off within 3 s, sinks back to
`SUSPENDED`.

**R2 — unblocked, and it is the next rung.** It was gated on having a post-mortem
for a hang. §4i settles that: ramoops works and always did, so a hang after
registering C2/C3 is readable from `/var/lib/systemd/pstore/` on the next boot.
Serial is still unavailable and always will be, so R2 must be attempted on the
strength of ramoops alone.

**Measured properly, 2026-09-21 19:36** — box up 20.5 h, `nexusqd` settled 19 h,
tap correctly off, nothing playing:

```
idle exits            368/s      (cpu0 C1 entries 459/s)
 tasks after an exit   alsa_buf_mon 24.6  python3 8.5  arecord 7.5  kworker/u9 7.5
 interrupts            twd 93.5   IPI 51.2   mmc4 6.0   omap-dma 5.1   i2c 3.7
```

Two things to read from it. **Tasks account for only ~70/s of 368**, so most exits
are interrupts serviced without any task switch — attributing wakeups by task
alone will always under-explain this box. And **`twd` at 93.5/s is downstream, not
a cause**: `CONFIG_NO_HZ_IDLE=y` with `CONFIG_HZ=100`, so a fully periodic tick on
two cores would be 200/s; 93.5 means the tick does stop and is being re-armed by
the timers the polling daemons set. Cutting the pollers takes `twd` with them —
**do not chase the timer separately.**

The earlier reading of **308 exits/s was contaminated** (`nexusqd` restarted ~2 min
before, screensaver still animating into the AVR: `48072000.i2c` at 55/s versus
3.7/s here, `nexusqd` at 10.5/s versus absent). That is the measurement discipline
this needs — settle **>300 s** after any daemon restart
([[nexusqd-needs-300s-before-measuring]]).

## Open questions

- With C2/C3 registered, do `mpu_pwrdm` and `core_pwrdm` actually reach CSWR/OSWR,
  or does something else hold them? Unknown until asked — and the counters will
  only start meaning anything once the idle path runs, since that is what updates
  them.
- Does `cpuidle44xx`'s coupled path work on this board once domains transition —
  and is `ARCH_NEEDS_CPU_IDLE_COUPLED` actually enabled in our build? The
  defconfig does not list it (it would be selected, and `savedefconfig` omits
  selected symbols), so confirm against the built `.config`, not the defconfig.
- What did stock's six tuning knobs actually gate? The literal-pool scan found
  only the `__param_*` structures; this kernel builds addresses with
  `movw`/`movt`, so a proper scan needs pair reconstruction over the whole
  `cpuidle44xx` text range.
- Can `smsc95xx` (ethernet) or `brcmfmac` (WiFi) wake the system? That decides
  whether R3 can keep the "a device connects to it" promise.
