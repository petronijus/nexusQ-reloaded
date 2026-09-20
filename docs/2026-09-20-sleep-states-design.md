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

## 1. The headline: no SoC power domain has ever transitioned

`/sys/kernel/debug/pm_debug/count`, after 2.4 h of uptime:

```
mpu_pwrdm   (ON), OFF:0, RET:0, INA:0, ON:1
cpu0_pwrdm  (ON), OFF:0, RET:0, INA:0, ON:1
cpu1_pwrdm  (ON), OFF:0, RET:0, INA:0, ON:1
core_pwrdm  (ON), OFF:0, RET:0, INA:0, ON:1
l4per_pwrdm (ON), OFF:0, RET:0, INA:0, ON:1
l3init_pwrdm(ON), OFF:0, RET:0, INA:0, ON:1
```

**The MPU, both CPUs and CORE have been ON since boot and have never once
changed state.** The only domains that ever go down are the peripheral ones that
driver runtime-PM switches off by themselves — `cam` (OFF:3), `abe` (OFF:4),
`gfx` (OFF:2), `ivahd`, `tesla`, `dss`, `cefuse`.

That is the whole answer to "the orb gets hot for nothing". Everything this port
has done for idle power so far — the `conservative` governor, the 350 MHz OPP
work, the `Nice=19` sweep, the pid-1 churn fix — has been shaving the *load* on
a chip whose power domains are pinned ON.

## 2. And the one transition we do attempt, fails

CPU hotplug uses the same `omap4_enter_lowpower()` machinery as the deep idle
states, so it is a free test of that path. Offlining CPU1:

```
online before: 0-1   ->  online now: 0   ->  online after: 0-1     (works)
cpu1_pwrdm (ON), OFF:0, RET:0, INA:0, ON:1                         (never went off)
pwrdm state mismatch(cpu1_pwrdm) 3 != 0
pwrdm state mismatch(cam_pwrdm) 3 != 0      ivahd, tesla, abe, gfx likewise
```

`3 != 0` is "programmed next state OFF, read back ON". So CPU1 is *logically*
unplugged while its power domain stays powered. The hotplug succeeds and the
power saving silently does not happen.

This is the first thing to root-cause. Until a power domain can be made to
transition at all, every rung below is theatre.

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

## 5. The design: a ladder, not a switch

Each rung is independently useful, independently testable, and does not depend on
the ones above it.

### R0 — cut the wakeup rate (no new sleep state at all)

Attack, in measured order: the idle `arecord` tap on the PA monitor (84 + 23 + 23
per second between PulseAudio, arecord and snd-aloop), then the brcmfmac SDIO
watchdog, then the Python daemons' poll loops. Zero risk, immediately lowers
temperature, and it is the **precondition** for anything below it paying off.

### R1 — the LED ring — *excluded from this design.* Petr is doing it differently.

### R2 — make a power domain actually transition, then register C2/C3

Root-cause §2 first: why does `cpu1_pwrdm` read back ON after being programmed
OFF? Only once a domain demonstrably transitions is it worth reverting patch 0024
(or narrowing it). Test on serial with ramoops armed — the historical failure was
a CPU1 cpuidle panic, so it must be recoverable.

This is the user's *"sleep mode with network and Bluetooth support"*: the network
stack stays fully up and only the silicon idles deeper.

### R3 — suspend-to-idle (`freeze`)

Already offered by the kernel (`/sys/power/state: freeze mem`), involves no
secure monitor, and freezes userspace — all 368 wakeups/s stop at once. Cheap to
try and it is the only rung that helps even if R2 turns out to be impossible.
Wake sources already enabled: TWL6030 RTC (which only started ticking in
v1.17.0), alarmtimer, both MMCs, USB.

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

1. **R0**, because it is free, measurable, and makes R2 worth having.
2. **§2 root cause** — a power domain that will not transition is the actual bug,
   and it blocks R2 and R4 both.
3. **R3**, cheap and independent; it may be most of what the user wants.
4. **R2**, then **R4**, in that order of risk.

## Open questions

- Why does a power domain programmed to OFF read back ON? PRCM? A clock domain
  dependency? The HS secure side? This is the load-bearing unknown.
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
