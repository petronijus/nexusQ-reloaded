# Handovers held on the Colony board for NexusQ

Saved 2026-09-21 before the NexusQ session was removed from the board.
The board is not a place to keep the only copy of anything.

## Deep C-states: the blocker is the SELECTION path, not entry

- id `hnd_780948b21c8e669c`, state `open`, for petr.parkan.janda
- left by petr.parkan.janda at 2026-09-21T21:37:04+00:00

Kernel 6.18.48-r7 is on the unit with the runtime knobs; everything is reversible by reboot, no mains cycle needed. Read docs/2026-09-20-sleep-states-design.md 4i-4l plus the commit message of 7867f37.

WHAT IS ELIMINATED. The entry path is not fatal: four configurations (rendezvous on/off, MPU programmed or not, omap4_enter_lowpower called or not) all survive on a running box. Idle depth is not the blocker: with the pollers stopped the mean idle is 1554us against C2's 960us threshold. State locking is not the blocker: cpuidle_driver_state_disabled clears the DRIVER bit and writing 0 to sysfs disable clears the USER bit, and with both clear disable reads 0 on both cpus. Prediction is doubtful too - teo behaves the same as menu.

WHAT IS LEFT. The governor never SELECTS C2: usage, above and below all stay 0, and above/below only move once a state is chosen. Prime suspect: C2/C3 carry CPUIDLE_FLAG_COUPLED, cpuidle44xx.c never sets dev->coupled_cpus itself, and cpuidle_coupled_register_device() returns success WITHOUT building the coupled structure when that mask is empty. coupled_cpus is supposed to come from cpuidle_register()'s second argument (we pass cpu_online_mask) - I did NOT verify that it actually propagates, because I grepped driver.c when cpuidle_register lives in cpuidle.c. Start there, then read the coupled branch of cpuidle_enter().

ALSO OPEN, unrelated: six power domains (cam, ivahd, tesla, dss, abe, gfx) log 'pwrdm state mismatch 3 != 0' - programmed OFF, read back ON. They do reach OFF sometimes, so it is not a hard failure, but it is unused silicon drawing power. enable_off_mode is 0.
