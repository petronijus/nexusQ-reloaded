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

> ⚠️ **Corrected 2026-09-22 (§4n):** the next paragraph is wrong. Mainline
> `pwrdms_setup()` (`pm44xx.c`) programs `mpu_pwrdm` and `core_pwrdm` to next=RET
> with logic OFF **at boot**. Live on r7: `PM_MPU_PWRSTCTRL=0x003c0601`,
> `PM_CORE_PWRSTCTRL=0x03ff0f01`. They are armed; they never transition only
> because a CPU never powers off.

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

> ⚠️ **Corrected 2026-09-22 (§4n):** hotplug does **not** go through
> `omap4_enter_lowpower()`. `omap4_hotplug_cpu()` (`omap-hotplug.c`) calls
> `finish_suspend(1)` directly and wakes through `omap4460_secondary_startup`
> + PPA 0x25. It proves the *entry* half (L1 flush, SMC 0x108, SCU OFF), never
> `cpu_suspend`/`omap4_cpu_resume` or an interrupt wake through the ROM and
> SAR+0xa04.

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

## 4j. R2 ATTEMPTED: the states are registered, and CANNOT be armed

> **Read §4k before trusting anything below.** The measurements in this section
> are real but the conclusion drawn from them is wrong: the box *does* idle long
> enough, and the reason C2 was never entered is that `CPUIDLE_FLAG_OFF` cannot
> be undone from sysfs. Both C2 experiments proved nothing about the hardware.

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

## 4k. Why C2 was never entered: `CPUIDLE_FLAG_OFF` is not a runtime switch

§4j blamed the wakeup rate. That was wrong twice over, and both errors are worth
keeping because each looked like a result.

**Error 1 — the idle figure was taken from an unsettled box.** §4j quoted mean idle
of 778 us (cpu0) / 822 us (cpu1) against C2's 960 us threshold and concluded the box
never idles long enough. Those are **cumulative-since-boot** counters read ~2-4 min
after boot, so the boot storm dominates them. Measured as a **delta over a 120 s
window** on a settled box instead:

```
cpu0   33996 idle periods / 83419281 us  ->  mean 2453 us   (283 exits/s)
cpu1   32335 idle periods / 60625640 us  ->  mean 1874 us   (269 exits/s)
C2 needs 960 us      C3 needs 1100 us
```

The box idles **2.5x longer than C2 requires**. Idle depth was never the blocker.
(Same trap as the contaminated 308 exits/s reading — a cumulative counter is not a
steady-state measurement.)

**Error 2 — the state was never actually armed.** Re-run on the settled box, C2
"armed" on both cpus for 120 s: `usage=0`, and crucially **`above=0 below=0`** —
those increment when a state is *chosen* and the idle turned out shorter/longer, so
all-zero means it was never even considered. Switching the governor to `teo` changed
nothing. No `/dev/cpu_dma_latency` holder existed. The cause is in the kernel, from
6.18.48's own source:

```c
/* drivers/cpuidle/sysfs.c */
show_state_disable   ->  state_usage->disable & CPUIDLE_STATE_DISABLED_BY_USER
store_state_disable  ->  sets/clears ONLY  CPUIDLE_STATE_DISABLED_BY_USER
/* drivers/cpuidle/cpuidle.c:653 */
if (drv->states[i].flags & CPUIDLE_FLAG_OFF)
        dev->states_usage[i].disable |= CPUIDLE_STATE_DISABLED_BY_DRIVER;
```

`CPUIDLE_FLAG_OFF` sets the **DRIVER** bit. The sysfs `disable` file reads and
writes only the **USER** bit. So `echo 0 > .../state1/disable` clears a bit that was
never set, the DRIVER bit stays, the state remains disabled — **and `disable` reads
back `0`**, which is why it looked armed. Patch 0024's premise, that the state could
be armed by hand for a measured run, is simply false.

**So the original question is still open.** Nothing has entered C2 on this board, so
"do the MPUSS transitions trap into the HS secure monitor with SMP online" remains
exactly as unanswered as before. What *is* now established: registering the states
is harmless (the box runs normally with them present), and idle depth is not the
obstacle.

**To actually answer it**, the driver must not mark them `CPUIDLE_FLAG_OFF` —
register C2/C3 enabled and let the governor pick them. That carries a real risk of a
kernel that hangs on the first deep idle, which is why it needs a deliberate
decision rather than a quiet default. Recovery is a `fastboot flash boot` of the
previous image, which has been exercised repeatedly, and ramoops now archives the
console to `/var/lib/systemd/pstore` so a hang leaves evidence (§4i).

⚠️ **Do not read `disable` as proof a state is armed.** On this kernel it can only
ever tell you what *userspace* asked for. The honest check that a state is live is
`usage` moving, or `above`/`below` becoming non-zero.

## 4l. ANSWERED: the deep C-states hang the board. Patch 0024's premise was right

The experiment §4k called for was built, flashed and run. Kernel **6.18.48-r5** =
the tree with patch 0024 **removed entirely**, so `cpuidle44xx.c` is pristine
upstream and C2/C3 register enabled and governor-selectable from the first idle.
Verified from the built image before flashing (disassembled `omap4_idle_init`: no
`of_machine_*` guard, tail-call to `cpuidle_register`; state table read out of the
binary showing `flags=0x42` = `COUPLED|TIMER_STOP` and `CPUIDLE_FLAG_OFF` set on
nothing).

**The board does not boot.** Both partitions flashed, five minutes of watching:

```
no ssh, no fastboot, no USB enumeration at all  (lsusb: nothing; /dev/ttyACM*: none)
```

Not a slow boot and not a WiFi problem — the USB gadget never appeared, so it hung
before userspace. Recovery needed the manual palm-on-dome gesture from INSTALL.md §1
(mains off, mains on, palm the moment the centre LED lights) and a reflash of the
r4 acceptance pair, after which the unit came back clean: `running`, 0 failed units,
modules matching, WiFi up, persist store intact.

**So the long-standing claim is CONFIRMED, not retired.** Patch 0024 said the C2/C3
MPUSS transitions fault on this HS part with SMP online. §4j had softened that to
"not confirmed"; it is now confirmed by experiment. The patch stays, and the
`CPUIDLE_FLAG_OFF` form is the right one to keep: identical safety to the old
C1-only truncation, but the states exist with residency counters, which is what made
this measurable at all.

**The suspect, from the built binary:** both deep states carry
`CPUIDLE_FLAG_COUPLED` and enter through `omap_enter_idle_coupled()` — the two cores
must rendezvous. That is exactly the path stock 3.0.8 fenced off with
`cpuidle44xx.disallow_smp_idle`, and exactly what patch 0009 (SEV in
`prepare_wake_cpu1`) was written against. A single-core entry path was never the
thing being tested.

⚠️ **ramoops cannot help with this class of failure.** The archive was **empty**
after recovery. Not a regression in §4i's fix: escaping the hang required pulling
mains, and a cold start scrubs DRAM, so the ramoops region went with it. **Any hang
that can only be escaped by a mains cycle is structurally un-post-mortem-able here.**
A hang that a *warm* reset can escape still leaves a record; this one could not.

**What would move it forward**, none of it cheap: make the deep states single-core
(drop `CPUIDLE_FLAG_COUPLED`, offline CPU1 or gate entry on `cpu1` being down), or
reproduce stock's `disallow_smp_idle` fence and find what it actually gated, or get
a serial console so the hang can be watched instead of inferred. The first is the
only one available without hardware Petr does not have.

**R2 is therefore closed as attempted-and-blocked, and it no longer depends on R0.**
The wakeup rate was never what stood in the way.

## 4m. FOUND: a 170 µs CPU-latency QoS from the Bluetooth UART vetoes C2/C3 (2026-09-22)

Earlier runs armed C2 at runtime (with the 0048 knob and with sysfs `disable=0`),
and the governor still never picked it: `usage`, `above` and `below` all stayed 0
on both CPUs, with teo the same as menu. (There turned out to be a second,
independent gate as well. See §4n.)
The handover's prime suspect was the coupled plumbing (an empty
`dev->coupled_cpus` makes `cpuidle_coupled_register_device()` succeed without
building anything). **That suspect is cleared, from source and from the running
config:**

- `cpuidle_register()` lives in `drivers/cpuidle/cpuidle.c`, not `driver.c`, and it
  copies its second argument into `device->coupled_cpus` under
  `CONFIG_ARCH_NEEDS_CPU_IDLE_COUPLED`.
- `/proc/config.gz` on r7: `CONFIG_ARCH_NEEDS_CPU_IDLE_COUPLED=y` (selected by
  `ARCH_OMAP4` when `SMP`).
- `omap4_idle_init()` runs from `omap_late_initcall`, after `smp_init()`, so
  `cpu_online_mask` already holds both cores.

**The real veto is the CPU-latency QoS**, read on the unit after 19.7 h up:

```
/dev/cpu_dma_latency   170 us
C2 exit_latency        768 us   (328 + 440)
C3 exit_latency        978 us   (460 + 518)
```

menu and teo both drop every state whose exit latency is above
`cpuidle_governor_latency_req()` before they even look at predicted idle. So
neither governor can ever select C2 or C3. That is why the two agree, and why
`above`/`below` never moved.

**Where 170 comes from.** `8250_omap` sets
`calc_latency = USEC_PER_SEC * 64 * 8 / baud` (a 64-byte FIFO filling at line
rate) in `set_termios`, and applies it whenever the port is runtime-active
(`omap8250_runtime_resume` / the IRQ handler). At 3 Mbaud that is
512000000 / 3000000 = **170**. No other baud on this board produces it (115200 gives
4444, 921600 gives 555). 3 Mbaud is the BCM4330 link (patch 0040).

**Why the port never idles.** The chain that holds it:

```
serial0-0   (hci_uart_bcm)   runtime-SUSPENDED  - hci_bcm's own PM works
serial0     (serdev ctrl)    no callbacks, held by serdev_device_open()
4806c000.serial:0.0 (port)   active, 18.7 s suspended in 19.7 h
4806c000.serial     (UART2)  active  ->  QoS = calc_latency = 170 us
```

`serdev_device_open()` takes `pm_runtime_get_sync(&ctrl->dev)` and only
`serdev_device_close()` drops it. `hci_uart` opens the serdev at probe and keeps it
open for the life of the driver. So while Bluetooth is bound, the UART is
permanently active and the 170 µs QoS request is permanently in force.
`hci_bcm`'s runtime suspend only deasserts the chip's device-wake. It never lets
go of the UART.

**Causality, measured.** Unbind `hci_uart_bcm` from `serial0-0`, read, rebind:

```
before:  qos=170   uart=active
unbound: qos=4444  uart=suspended port=suspended
rebound: qos=170   uart=active      (BCM4330B1 re-patched, hci0 powered)
```

4444 is the 115200 console UART, and it is above C3's 978 µs, so it does not block
anything.

### What this does to §4l and to the knob experiments

- **The "four configurations survive on a running box" result measured nothing.**
  None of them ever entered C2, because the QoS vetoed it before the governor got
  that far. `omap_enter_idle_coupled()` never ran with `index >= 1`. The entry path
  is **not** cleared.
- **The r5/r6 boot hangs are consistent with this, and now read differently.** At
  boot, before `hci_uart` probes and opens the UART, there is no 170 µs request.
  C2/C3 were genuinely selectable and genuinely entered, and the board hung. The
  boot hang is still the only time C2 has ever actually run on this box.

### Stock parity (NOT yet verified against `reverse-eng/vmlinux.bin`)

The expectation, from the Android OMAP 3.0 tree and not yet from our stock binary:
stock 3.0.8 `omap-serial` carried the same formula (`fifosize * 8 * 10^6 / baud`)
and the same "only while active" rule. What stock had and we do not is **bluesleep**:
when the BCM4330 was idle (BT_WAKE / HOST_WAKE both deasserted) the UART was
released and clock-gated, the QoS request went back to default, and deep idle was
reachable with Bluetooth up. The parity fix is to make the BT UART idle when the
chip idles: have `hci_bcm`'s runtime suspend/resume drop and retake the serdev
controller's runtime-PM reference, and rely on HOST_WAKE (already wired, because
`serial0-0` does runtime-suspend) to bring it back before data arrives.

## 4n. R2 run for real: CPU0 entering OFF from idle hangs the board, alone (2026-09-22)

### The second gate: patch 0048's premise is backwards

With BT unbound (QoS 4444 µs) and `deep_idle=1`, C2 **still** got 0 entries, even
with CPU1 offline. The per-state `disable` file read **1** while armed. That was the
tell:

```c
/* drivers/cpuidle/cpuidle.c:653, v6.18.48 */
if (drv->states[i].flags & CPUIDLE_FLAG_OFF)
        dev->states_usage[i].disable |= CPUIDLE_STATE_DISABLED_BY_USER;
```

`CPUIDLE_FLAG_OFF` sets the **USER** bit, not the DRIVER bit. The sysfs `disable`
file is exactly the right switch. `deep_idle` (which calls
`cpuidle_driver_state_disabled()`) toggles a DRIVER bit that `FLAG_OFF` never set.
So 0048's commit message and §4k have it the wrong way round. Arming C2 needs
`echo 0 > cpu{0,1}/cpuidle/state1/disable`. The `deep_idle` knob is redundant at
best: writing 0 to it *sets* the DRIVER bit and disables the state a second way.
The three escape-hatch knobs (`skip_cpu1_wait`, `keep_mpu_on`, `skip_lowpower`) are
still valid and still what split the question below.

Every earlier "armed" run therefore had **two** vetoes in force at once: the 170 µs
QoS (§4m) and the USER bit. Neither one alone would have shown up.

### The ladder, with a hardware watchdog as the safety net

Hangs no longer cost a mains cycle. `omap_wdt` (WDT2, `4a314000.wdt`, WKUP domain)
is present and simply unarmed. Arm it at runtime, non-persistently:

```sh
busctl set-property org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager RuntimeWatchdogUSec t 30000000
dmesg -n 8     # so pr_info reaches the ramoops console record
```

A hang then becomes a **warm** reset about 50 s later, the unit boots back to
defaults (C2 off, knobs off, watchdog off), and ramoops survives. §4i explains how
to read it: `/var/lib/systemd/pstore/console-ramoops-0`. Three hangs were recovered
this way without anyone touching the box.

Each run: BT unbound, both C2 `disable=0`, knobs set, 60 s, C2 counters every 10 s.

| run | skip_cpu1_wait | keep_mpu_on | skip_lowpower | CPU1 | result |
|---|---|---|---|---|---|
| T1 | 1 | 1 | **1** | online | **4969 C2 entries in 60 s**, identical count on both CPUs, no errors |
| T2 | 1 | 1 | 0 | online | hang within 10 s of arming |
| T3 | 0 | 1 | 0 | online | hang within 10 s of arming |
| T3b | 0 | 1 | 0 | **offline** | hang within 10 s of arming |

ramoops for T3 and T3b (at loglevel 8) ends with the arming line itself, then
nothing: no oops, no warning, no lockup report.

### What that establishes

- **The coupled machinery works.** T1 ran the whole `omap_enter_idle_coupled()`
  path (rendezvous, tick broadcast onto the gptimer1 clockevent, `cpu_pm_enter`,
  the parallel barrier) thousands of times on both CPUs in lock-step. The handover
  suspect is dead from both ends.
- **The fatal step is `omap4_enter_lowpower()` putting a CPU into OFF from idle**,
  even with `mpu_pwrdm` left ON.
- **It is fatal for CPU0 on its own.** T3b had CPU1 hotplugged OFF
  (`cpu1_pwrdm 3 != 0` in the record), so there was no coupling and no rendezvous.
  CPU0 alone went OFF and never came back.
- Contrast: **CPU1** OFF through the same function works through hotplug (§2). The
  differences are which CPU it is, and how it wakes: hotplug wakes through the SMP
  boot path, idle through an interrupt and the `omap4_cpu_resume` wakeup address
  that the HS ROM must honour.
- This matches the r5/r6 boot hangs (§4l), where the same step was the first deep
  entry at boot.

### Correction from the stock-parity audit: `keep_mpu_on=1` never kept MPU ON

The table above reads as "a CPU going OFF is fatal even with the MPU ON". **The MPU
was not ON.** Mainline `pwrdms_setup()` arms MPU and CORE for RET with logic OFF at
boot, and nothing in the coupled idle path sets them back. 0048's `keep_mpu_on`
only *skips re-programming* them. Live on r7, before any test:

```
PM_MPU_PWRSTCTRL   0x4A306300 = 0x003c0601   next=RET, LOGICRETSTATE=0 (logic OFF)
PM_CORE_PWRSTCTRL  0x4A306700 = 0x03ff0f01   next=RET, logic OFF
PRM_VOLTCTRL       0x4A307B10 = 0x0000732a   AUTO_RET on MPU/IVA/CORE, permanent
```

So in T2, T3 and T3b, as soon as both CPUs were OFF (or CPU0 alone with CPU1 hotplugged
out), the MPU could drop into **OSWR**, which loses its logic. There was no
`cpu_cluster_pm_enter()`, so GIC/wakeupgen were not saved. Voltage auto-retention on
the TPS62361 rail could fire as well. Nothing could wake CPU0 after that. **So these
runs were the first MPU (and possibly CORE) hardware transitions on this port. They
are not a clean test of CPU OFF.**

The stock contrast (`reverse-eng/vmlinux.bin`):

- **Boot defaults.** Stock's `pwrdms_setup` (`0xc0012d04`) leaves mpu/core/cpu0/cpu1
  **ON**.
- **Per-entry programming.** Stock programs MPU/CORE only inside a deep entry and
  forces both back to ON right after (`0xc00686d8`/`0xc00686e4`).
- **VC auto-transition.** Stock disables it at boot (`omap_vc_set_auto_trans(…, 0)`)
  and arms MPU=RET only around entries with mpu < INA.
- **State table.** Stock's is **C1** WFI; **C2** CPUs OFF + MPU/CORE **INACTIVE**
  (1100 µs); **C3** CPUs OFF + MPU/CORE CSWR (1200 µs); **C4** MPU CSWR + CORE OSWR
  (1500 µs). CPU0 *did* go OFF from idle in every deep state.
- **No MPU OSWR in idle.** Stock never used it, which is what mainline's C3 does.
  Mainline's C2 (MPU CSWR) is stock's C3 on the MPU side.

### Hotplug was never a control for this path

§2's premise is corrected at its source. Hotplug skips `cpu_suspend`/`omap4_cpu_resume`
and the ROM interrupt-wake through SAR+0xa04, so the **resume half** of CPU OFF has
never run on this board. The audit ranks one resume item HIGH on its own:

- **CP15 writes on CPU0 resume.** Mainline's `cpu_ca9mp_do_resume`/`cpu_v7_do_resume`
  write Diagnostic, Power Control and ACTLR whenever they differ from the saved value.
- Stock's CPU0 resume sets only ACTLR.SMP, and only if NSACR[18] (`0xc0067a40`).
- On HS we are non-secure, so such a write is an undefined-instruction trap with the
  MMU off, i.e. a silent hang.

### Ranked next steps (from the audit, ordered by how cleanly each isolates)

1. Make `keep_mpu_on` really hold MPU (and a new `keep_core_on`, CORE) at **ON**, the
   way stock's knobs did. Re-run T3 with that fix. That is the first real test of
   CPU OFF on its own.
2. If it still hangs, suspect the CPU0 resume CP15 writes. Compare
   ACTLR/NSACR/PCR on CPU1 after a hotplug cycle against CPU0.
3. For parity: steelhead `pwrdms_setup` keeps mpu/core at ON, deep entries program
   and then restore ON; VC auto-transition off at boot; stock's table (C2 = MPU/CORE
   INA); i608 RTA + 4460 SRAM-LDO RETMODE; the coupled-case gaps (GICD disable before
   waking CPU1, CPU1 L2-wait, CPU1 wakeupgen/GICC mask).

## 4o. Kernel r8: MPU and CORE held ON, and CPU OFF still hangs (2026-09-23)

Kernel **6.18.48-r8** carries patch 0048 rev 2:

- `keep_mpu_on` now *programs* `mpu_pwrdm` ON on every CPU0 entry. It also
  clears `mpuss_can_lose_context`, because rev 1 left it set for C3 and ran
  `cpu_cluster_pm_exit()` without a matching enter.
- A new `keep_core_on` programs `core_pwrdm` ON from the parameter write, and
  restores the previous next state when cleared.
- The `deep_idle` knob is gone, since it toggled the wrong bit (§4n).

Patch 0024's comment and message are corrected too. r8 went on the unit through
`nq-kernel-ota` (trial boot from slot B, health-gated autopromote to slot A). A full
`nexusq-diag` sweep afterwards found no regression
(`nq-captures/20260923-091115/`).

**Clean T3** (`nq-deep-idle-ladder.sh 0 1 0 60 0 1`): BT released (QoS 4444 µs), CPU1
online, both CPUs waiting for each other, and MPU **and** CORE confirmed ON
(`pm_debug`: `mpu_pwrdm (ON)`, `core_pwrdm (ON)`, both `RET:0`). Result: a **hang
within seconds of arming**, as on r7. The watchdog brought the unit back warm on r8.
ramoops ends at the `pm_debug` read before arming, with no oops and no warning.

So the hang does **not** need the MPU or CORE to transition. What remains is the
CPU's own OFF → wake → resume path, which hotplug never exercises (§2 correction).
The audit ranks it as follows:

1. **CP15 writes on resume.** `cpu_ca9mp_do_resume` / `cpu_v7_do_resume` write the
   Diagnostic, Power Control and ACTLR registers whenever the saved value
   differs. Stock's CPU0 resume sets only ACTLR.SMP (if NSACR[18]). Non-secure on
   HS, such a write traps with the MMU off, which is a silent hang.
2. **SGI/PPI distributor mask before OFF** (stock `0xc006713c`) and CPU1's
   wakeupgen/GICC mask before OFF (`0xc00684bc`), both missing here.
3. The wake never arrives at all (wakeupgen routing for the broadcast timer).

**Next: breadcrumbs, not guesses.** A hang with the MMU off cannot print
anything, but SAR RAM survives a warm reset (patch 0044 already keeps the reboot
reason there). Have `sleep44xx.S` / `omap4_cpu_resume` write a step marker to a
free SAR word by physical address at each stage:

- before the SMC 0x108 pair;
- before WFI;
- first instruction after the ROM hands back;
- after each CP15 restore;
- MMU on.

After the watchdog reset, read the markers from `/dev/mem`. That localises the hang
to one instruction range in a single run.

### Also found by the r8 sweep (not caused by r8)

The r7 boot lost WiFi for about 10 h overnight, from t=8646 s (22:52 on 09-22) to
t=45356 s. It shows the TX-wedge signature `loss:100 sig:-44` and 348
`brcmf_escan_timeout`, with `roamoff=1` loaded. The only event just before it was
a USB gadget re-enumeration at 8625 s. This is untested and tracked in CHANGELOG
Known issues.

## Power target: stock's wall draw is unknown, so measure it (open, 2026-09-23)

No reliable public figure exists for the stock Nexus Q's idle draw:

- Google's Guidebook specs give only the integrated 35 W supply (85–265 V), the
  2 × 12.5 W / 8 Ω class-D amp, and "automatic shutdown for audio amp supply when
  not in use".
- Wikipedia and the 2012 reviews (Engadget, LaptopMag, michaelevans.org) repeat
  only those ratings.
- A search-engine hit claiming "1.82 W idle, Yokogawa WT310E" (lifetips.alibaba.com)
  is fabricated. The same page credits the Q with a Zigbee mesh, 3× 1080p RTSP
  streams and local ASR. Do not cite it.

**Plan.** Measure it ourselves:

- stock RAM-boot versus our build, on the same meter (≥0.1 W resolution);
- the same cabling for both (network, HDMI, speakers);
- idle only, read after >300 s of settling.

Stock idles with C1–C4 (CPUs OFF), so its number is the target for R2. Tracked in
the AI-handover Todoist project. Waiting on Petr to pick the meter.

## Where this stands (end of 2026-09-22) — paused here

- **R2 blockers found:** the BT-UART QoS (§4m) and the USER-disable bit (§4n).
  With both lifted, C2 runs on a live box through the whole coupled path (T1).
- **Every rung that powers a CPU OFF hangs.** Those rungs were not clean tests,
  because MPU/CORE were armed for RET/OSWR from boot and `keep_mpu_on` did not
  disarm them (§4n correction, confirmed from live PRM registers).
- **Instrument:** `scripts/diag/nq-deep-idle-ladder.sh`. The watchdog turns every
  hang into an unattended warm reset with ramoops.
- **Unit state at pause:** r7, all knobs default, C2/C3 disabled, watchdog off,
  BT bound, healthy.
- **Next (not started):** kernel r8, where 0048's `keep_mpu_on` programs MPU ON and
  a new `keep_core_on` does the same for CORE, the way stock's did. Flash boot.img
  only (only the built-in `cpuidle44xx.c` changes), then re-run T3. If it still
  hangs, go to the CPU0-resume CP15 writes (§4n, ranked step 2).
- **Nothing from this session is committed.** Changed: this doc,
  `scripts/diag/README.md`, and the new ladder script.

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

**R2 — ATTEMPTED AND BLOCKED (§4l).** Registering C2/C3 enabled hangs the board
before userspace; recovery needed the manual palm gesture and a reflash. Patch
0024's premise is confirmed, the patch stays in its `CPUIDLE_FLAG_OFF` form, and
ramoops could not capture the hang because escaping it required a mains cycle,
which scrubs DRAM. R2 no longer depends on R0.

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
- Does `cpuidle44xx`'s coupled path work on this board once domains transition?
  (`ARCH_NEEDS_CPU_IDLE_COUPLED=y` is confirmed in r7's `/proc/config.gz`, §4m.
  The path itself has never run with C2 selected on a live box.)
- What did stock's six tuning knobs actually gate? The literal-pool scan found
  only the `__param_*` structures; this kernel builds addresses with
  `movw`/`movt`, so a proper scan needs pair reconstruction over the whole
  `cpuidle44xx` text range.
- Can `smsc95xx` (ethernet) or `brcmfmac` (WiFi) wake the system? That decides
  whether R3 can keep the "a device connects to it" promise.
