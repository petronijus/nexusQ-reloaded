# Keypad clkctrl "failed to enable" on 6.18.48-r23 (2026-10-11)

**Status:** investigated read-only. The mechanism is narrowed down but **not
confirmed**. Two fixes are drafted below and **not applied**: a clkctrl kernel
patch that also measures the failure, and a DTS change. Nothing was built,
flashed or committed.

## The error

Prague unit (`hostname` = `steelhead`, 192.168.20.246), first boot of
`6.18.48-r23` (2026-10-11 18:17):

```
[    1.130798] l4-wkup-clkctrl:0058:0: failed to enable
[    1.130889] ti-sysc 4a31c000.target-module: probe with driver ti-sysc failed with error -16
```

`l4-wkup-clkctrl:0058:0` is `CM_WKUP_KEYBOARD_CLKCTRL` (0x4a307878 =
0x4a307820 + 0x58). Its parent is `sys_32k_ck` and it carries the
`CLKF_SW_SUP` flag (`drivers/clk/ti/clk-44xx.c:635`). `4a31c000` is the OMAP4
keyboard controller (KBD) target module, defined in `omap4-l4.dtsi:1176` and
enabled by default. The steelhead DTS does not touch it.

## Evidence

### How often it happens

All 17 boots in the unit's journal were checked: `journalctl -k -b -16 … 0`,
covering 2026-09-23 to 2026-10-11 and kernels r16–r23.

| Kernel | Boots | With the error |
|---|---|---|
| r16, r17, r18 (PREEMPT_NONE) | 1 + 8 + 1 | 0 |
| r19, r20, r21 (PREEMPT_NONE) | 4 + 1 + 1 | 0 |
| r91 (PREEMPT + DEBUG_ATOMIC_SLEEP + DEBUG_PREEMPT) | 1 | 0 |
| r23 (PREEMPT) | 1 | **1** |

That is **1 in 17 boots overall (95 % CI about 0.2–29 %)**. `nq-captures/`
holds no full boot dmesg, so it adds no data. pstore is empty. The message
has never been recorded before: no hit in `docs/`, `CHANGELOG.md` or
`HANDOVER.md`.

### What changed between r91 and r23

The packaged configs (`output/linux-google-steelhead-6.18.48-r{21,91,23}.apk`,
`boot/config`) differ only in these ways:

- **r21 → r23:** `PREEMPT_NONE` became `PREEMPT`, which brings `PREEMPT_RCU`,
  `TASKS_RCU` and `UNINLINE_SPIN_UNLOCK` with it. The SGX options were added,
  and `modprobe.blacklist=pvrsrvkm_omap4_sgx540_120` was added to the cmdline.
- **r91 → r23:** `DEBUG_ATOMIC_SLEEP` and `DEBUG_PREEMPT` were removed. The
  SGX options were added: `SGX=y`, `SGX_DRM=y`, `PVRSGX_1_17_4948957=y`,
  `SGX_OMAP=m`.

The `omap4-steelhead.dtb` is **byte-identical** in r21, r91 and r23 (md5
`99d97586…`). The named-symbol diff of `System.map` r91 → r23 has no pvr or
sgx symbol and no new initcall. It contains only inlining churn and the
removed debug helpers. So the SGX `=y` options compile no built-in code, and
the module is not loaded. For this code path, **r23 is r91 without two debug
options**, and r91 booted clean.

With one failure in two PREEMPT boots against none in fifteen PREEMPT_NONE
boots, the chance that the single failure lands in the PREEMPT group anyway
is 2/17 ≈ 12 %. **The data does not tie the error to PREEMPT or to pvrsgx.**

### The clocksource did not switch during the poll

- `clocksource: Switched to clocksource 32k_counter` is at 0.386 s, about
  0.75 s before the failure.
- `sched_clock` and the clocksource are both the 32 kHz sync counter
  (30.5 µs resolution).
- The clockevent is GPTIMER1 (always-on, 32 kHz).

The 2000 µs timeout is therefore measured on a stable, monotonic 32 kHz
counter. That is about 65 counter ticks, and resolution cannot explain a
false timeout.

### Probe ordering is the same on every boot

`_SOURCE_MONOTONIC_TIMESTAMP` (the printk time) was compared for boots −7,
−4, −3, −2, −1 and 0. The KBD target module is probed at the same point on
every boot:

- after `gpiochip0` (GPIO1, wkup) registers and its two hogs are set
  (`tps62361-vsel0`, `msecure`);
- before the wkup pinmux `4a31e040` probes;
- 7–10 ms after `OMAP GPIO hardware version`.

On r23 the failure is printed 7.0 ms after that line, and the pinmux follows
1.5 ms later. That is the same spacing as on the good boots. There was no
visible extra stall, and no ordering change under PREEMPT or TASKS_RCU. The
ti-sysc probe of 4a31c000 enables the KBD on **every** boot (`sysc_init_module`
enables, resets and idles it). It failed once.

### The poll cannot be preempted

`_omap4_clkctrl_clk_enable()` (`drivers/clk/ti/clkctrl.c:128-167`) runs under
`clk_enable_lock()`, which takes `spin_lock_irqsave`. From that point the
poll loop runs with IRQs off:

```c
while (!_omap4_is_ready(clk_readl(&clk->enable_reg))) {
        if (_omap4_is_timeout(&timeout, OMAP4_MAX_MODULE_READY_TIME)) {
                pr_err("%s: failed to enable\n", ...);
                return -EBUSY;
        }
}
```

Neither preemption, an interrupt nor a migration can land inside it. Only
two things can produce the failure:

1. **(a) The handshake really is slow.** The KBD answered the PRCM
   idle-request deassert more than 2 ms after `MODULEMODE=2` was written.
   Its idle handshake runs in the 32 kHz domain, where a normal transition
   takes a few 30.5 µs cycles, so 65 cycles would be very abnormal.
2. **(b) The poll timed out falsely.** The CPU was held off for 2 ms or more
   between its last register read and the deadline check. With IRQs off,
   only hardware can do that: an interconnect stall, or the secure monitor
   on this HS part. The loop then gives up without reading the register
   again. Other TI pollers, and `read_poll_timeout_atomic()`, evaluate the
   condition one last time after the deadline. This one does not.

The log line cannot tell (a) from (b): it reports neither IDLEST, nor the
elapsed time, nor the number of polls.

### The error path also leaks a reference

When the poll times out, `_omap4_clkctrl_clk_enable()` returns `-EBUSY` but:

- it leaves `MODULEMODE=2` written;
- it does not undo `clkdm_clk_enable()`, so the `l4_wkup_clkdm` usecount
  stays one too high.

The clk core does not call `.disable` after a failed `.enable`. The unit
shows the outcome now: `CM_WKUP_KEYBOARD_CLKCTRL` = `0x00030000` (read
read-only through `/dev/mem`), so the module is disabled again. That was
`clk_disable_unused` cleaning up at late init, because
`l4-wkup-clkctrl:0058:0` has enable/prepare count 0. The clkdm usecount
cannot be cleaned up that way, so it stays leaked.

### Steelhead has no keypad, and stock had no keypad driver

- The stock kallsyms (`reverse-eng/tools/kallsyms.txt`) contain no
  `omap4_keypad_*` symbol, so stock built no omap4-keypad driver. The
  `omap4-keypad` string in `vmlinux.bin` is only the hwmod/device name. Stock
  did have the hwmod `omap44xx_kbd_hwmod` (`@0xc07158bc`: name `kbd`,
  clkctrl `0xfc307878`, main_clk `kbd_fck`, no mux). Stock's
  `omap_hwmod_setup_all` enabled, reset and idled it at boot, which is what
  ti-sysc does now.
- Stock leaves the keypad pads unused or repurposed: `kpd_col0` @0x182 is in
  `safe_mode` (`reverse-eng/stock-omap-mux-full.txt`), and the gpmc-shared
  kpd functions are not selected.
- `CONFIG_KEYBOARD_OMAP4` is not set in our defconfig.

The KBD module therefore has no function on this board.

## Root cause (best-supported hypothesis)

This is an **intermittent KBD clkctrl enable timeout**, seen in 1 of 17
boots so far, in the one place where the module is ever enabled: the
ti-sysc probe-time reset. It is **not shown to be caused by PREEMPT or
pvrsgx**:

- r23 is r91 minus two debug options on this path;
- the DTB is identical;
- the poll runs with IRQs off;
- the clocksource is stable;
- the probe ordering is unchanged.

The remaining split is (a) against (b) above. The clkctrl driver has two
real defects that make the event both possible and invisible:

- there is no final re-read after the deadline, so a held-off poller reports
  a module that became ready in time as failed;
- the error path leaks a clkdm usecount and leaves `MODULEMODE` set;
- it prints nothing that tells the two causes apart.

The same false timeout could hit any clkctrl module, at runtime too, through
a runtime-PM resume of a module that matters (MMC, I²C, DSS). That is why
the fix belongs in clkctrl and not only in the DTS.

**What would confirm it:** boot a kernel carrying draft patch 1 below, which
prints IDLEST, the elapsed time and the poll count. Make that a test build:
add a `pr_info` for any enable slower than 500 µs. Then reboot about 30–50
times; the unit is rebooted with `systemctl reboot` over ssh. The outcomes
read like this:

- a few polls and more than 2000 µs elapsed, or "ready only after timeout",
  means **(b)**, a false timeout;
- thousands of polls with IDLEST stuck at 1 (transitioning) means **(a)**, a
  slow module.

Under (a), the next step is to measure the KBD's normal enable latency and
compare it with stock's `omap4_cm_wait_module_ready`. Stock waits 2000 ×
`udelay(1)` plus the register-read overhead, so its effective timeout is
somewhat longer than ours.

## Proposed fix (drafted, NOT applied)

### 1. Kernel: clkctrl decides on a fresh read, reports and rolls back

Draft for `drivers/clk/ti/clkctrl.c`, as a future `kernel/patches/00NN-clk-ti-clkctrl-…`.
It is also worth sending upstream; ask first.

```c
/* in _omap4_clkctrl_clk_enable(), replacing the wait loop */
	u32 polls = 0;

	/* Wait until module is enabled */
	while (!_omap4_is_ready(val = ti_clk_ll_ops->clk_readl(&clk->enable_reg))) {
		polls++;
		if (_omap4_is_timeout(&timeout, OMAP4_MAX_MODULE_READY_TIME)) {
			/*
			 * The poller can be held off past the deadline after its
			 * last read (IRQs are off, but the interconnect or the
			 * secure side can still stall the CPU): decide on a fresh
			 * read, as read_poll_timeout_atomic() does.
			 */
			val = ti_clk_ll_ops->clk_readl(&clk->enable_reg);
			if (_omap4_is_ready(val)) {
				pr_warn("%s: ready only after the timeout (%u polls)\n",
					clk_hw_get_name(hw), polls);
				break;
			}
			pr_err("%s: failed to enable: idlest %u after %u polls%s\n",
			       clk_hw_get_name(hw), _omap4_idlest(val), polls,
			       _early_timeout ? " (early)" : "");
			/* Roll back what this call did: the clk core will not call .disable */
			val &= ~OMAP4_MODULEMODE_MASK;
			ti_clk_ll_ops->clk_writel(val, &clk->enable_reg);
			if (clk->clkdm)
				ti_clk_ll_ops->clkdm_clk_disable(clk->clkdm, hw->clk);
			return -EBUSY;
		}
	}
```

The elapsed time is implied by the timeout once the loop reaches the error
path. For the confirmation build, also print
`ktime_us_delta(ktime_get(), timeout.start)` when `!_early_timeout`. The
same "fresh read before failing" change applies to the disable loop
(`clkctrl.c:191-197`).

### 2. DTS: describe the board, no keypad

This matches the existing practice in `kernel/dts/omap4-steelhead.dts`
(HDQ `target-module@b2000`, `rng_target`). The node has no upstream label,
so it is referenced by path:

```dts
/*
 * Keyboard controller (KBD, 0x4a31c000, wkup domain, 32 kHz fclk). The Nexus Q
 * has no keypad: stock built no omap4-keypad driver and left the kpd pads in
 * safe mode or on other functions; CONFIG_KEYBOARD_OMAP4 is off. ti-sysc would
 * only enable, reset and idle it. clk_disable_unused keeps its clkctrl off.
 * See docs/2026-10-11-keypad-clkctrl-enable-failure.md.
 */
&{/ocp/interconnect@4a300000/segment@10000/target-module@c000} {
	status = "disabled";
};
```

This is a correct board description and removes the only consumer that
ever enables KBD. It **does not** fix the clkctrl defect, so ship it
together with patch 1, not instead of it. Stock-parity note: stock *did*
reset and idle the kbd hwmod at boot. Leaving the module untouched instead
is harmless, because it is unused and its clkctrl stays disabled (verified
now: `0x4a307878 = 0x00030000`). The fleet-safety and stock-parity agents
should still review the change before it is built.

## Device state read for this note (read-only)

`CM_WKUP_*` via a `PROT_READ` mmap of `/dev/mem`, at 2026-10-11 18:2x:

| Register | Value | Meaning |
|---|---|---|
| CLKSTCTRL `0x4a307800` | `0x3103` | HW_AUTO |
| L4_WKUP `0x820` | `0x1` | enabled |
| WDT2 `0x830` | `0x30000` | disabled |
| GPIO1 `0x838` | `0x1` | enabled |
| TIMER1 `0x840` | `0x1000002` | enabled |
| COUNTER_32K `0x850` | `0x1` | enabled |
| `0x858` | `0x30000` | disabled |
| KBD `0x878` | `0x30000` | disabled |

`clk_summary`: `l4-wkup-clkctrl:0058:0` has enable 0, prepare 0, rate 32768,
and is deviceless.
