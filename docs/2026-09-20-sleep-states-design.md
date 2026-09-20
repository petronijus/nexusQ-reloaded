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
