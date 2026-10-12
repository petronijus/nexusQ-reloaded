# The first GPU desktop: an 8-minute stall and a panic, 2026-10-12

Prague unit, kernel 6.18.48-r25 (trial slot B), device r127 with nexusq-sgx
r0 and nexusq-sgx-mesa r0 installed from local builds. The GPU desktop itself
works ([route-a-musl-2026-10-12.md](route-a-musl-2026-10-12.md)); this note is
about the two faults found while bringing it up. Both are fixed: the panic by
kernel r26 (patch 0075), the stall by device r128 — and the stall turned out to
have nothing to do with the GPU (section "Fault 1, solved" below).

## What worked

- labwc rendering on the SGX540 (`WLR_RENDERER=gles2`, mesa-sgx, the DDK and
  the shim mapped in labwc; glslcompiler loaded). With an animated 640x360
  `wl_shm` window the GPU was runtime-active 26.2 s of 30 s.
- Environment scoping: lxqt-session, lxqt-panel and the systemd user manager
  had no `LD_*`/`NQ_SGX*` variable.
- Kill switch and fallback: `/etc/nexusq/gpu-off` → Pixman session; on r21
  (no GPU module) `nexusq-sgx.service` fails and the session starts on Pixman.
- Smoothness: a `wl_shm` client (mpv `--vo=wlshm`, software YUV→RGB) drops
  ~92 of 300 frames on the GPU compositor and ~95 on Pixman (labwc ~0.5 s CPU
  per 10 s either way): the client is the bottleneck, compositing on the GPU
  does not change it. mpv rendering through mesa-sgx (`--vo=gpu`, "dumb mode":
  no high-bit-depth FBOs) dropped **0 of 900 frames with the CPU at 350 MHz**.
  Giving GPU clients mesa-sgx is a separate decision (today only labwc gets
  it); the prototype launcher was `sgx-env` + `exec "$@"`.

## Fault 1: an 8-minute stall around the driver load/unload (first reading — wrong)

1. 00:06:40 `rmmod` (the driver had been used: probes, kmscube),
   00:06:46 `systemctl start tinydm` → `nexusq-sgx.service` → `modprobe`
   (`[drm] Initialized pvr … minor 1` at once) → then nothing for 8 minutes:
   a udev worker processing `card1` (SEQNUM 4031) hung, logind could not
   create session scopes (`Failed to start session scope … Operation timed
   out`), new ssh logins failed, `pvrsrvinit` did not finish. Ping answered;
   the HDMI showed the fbcon cursor.
2. 00:14:49.115 the USB gadget got a carrier (Petr plugged the cable);
   `pvrsrvinit` finished 0.66 s later, udevd killed the worker at 00:14:50, the
   desktop came up on the GPU.
3. Reproduced at 00:30 with a script pinned to CPU0: `rmmod` (this time
   `PVRLinuxFenceDeInit: 1 fences leaked`), 20 s idle — the script's next step,
   `systemctl start --no-block`, never returned; ssh dead again. A C3 disable
   ("kick") did not help (the script never got there: it was blocked in
   systemctl). Plugging USB at 00:43 led to fault 2.

What the data rules out: nq-healthd kept sampling every 5 s through both
stalls, at 350 MHz with load 0.1-0.4, and both CPUs kept entering C1/C2/C3
(C2/C3 are coupled states). So the CPUs and timers ran, nothing spun, nothing
sat in D state (the load average would show it). **PID 1 was unresponsive**
— everything that waits on it (logind, ssh logins, systemctl, service starts)
hung — and it woke when the USB link came up. The hypothesis "CPU1 stuck in
OFF" from the first stall does not survive this.

Common factor of both stalls: they followed an `rmmod` of a driver that had
been used (stall 1 then also a `modprobe`), and udev was handling a `card1`
event. No rule of ours matches DRM devices (only systemd's 50-udev-default,
60-drm, 60-seat-id-path, 70-uaccess, 71-seat). Where PID 1 sleeps is the next
measurement: [drafts/stall/stall-monitor.sh](drafts/stall/stall-monitor.sh)
records `/proc/<pid>/stack` of PID 1, udevd and its workers, logind and
pvrsrvinit plus SysRq w/l, without calling PID 1 synchronously itself.

## Fault 1, solved: a getty on the USB gadget console holds the console lock

Second session, same evening, kernel r26 (trial slot). What settled it:

1. `/proc/<pid>/stack` of another task is empty on ARM SMP, so the first
   monitor recorded nothing; `wchan` and `/proc/<pid>/syscall` work. During a
   stall **PID 1 sat in `flock(fd, LOCK_EX)`** (ARM syscall 143, wchan
   `locks_lock_inode_wait`), state S — so SysRq w, which lists D tasks, showed
   nothing. `/proc/locks` named the holder: an `(agetty)` child of PID 1 (a
   systemd executor before exec) with a write lock on `/dev/console` (`00:06:11`),
   asleep in `writev` (syscall 146, wchan `wait_woken`).
2. That executor starts `serial-getty@ttyGS0` (the USB ACM console). systemd
   262, for a unit with `TTYReset=yes`, takes the BSD lock on `/dev/console`
   in the executor and, still holding it, writes the OSC 3008 context sequence
   to the unit's tty with a blocking `fputs` + `fflush(stdout)`
   (`src/core/exec-invoke.c`, the "constructive" reset; unchanged on systemd
   main). On `ttyGS0` that write never ends while no USB host is attached:
   `gs_write_room()` returns 0 without a bound port
   (`drivers/usb/gadget/function/u_serial.c`).
3. A cable pull hangs up `ttyGS0`, agetty exits, `Restart=always` starts it
   again — and the new executor parks on the lock. Nothing notices until PID 1
   itself needs the lock for a TTY reset: the HDMI desktop (tinydm, TTYReset on
   tty1) starting or stopping, or getty@tty1 coming back. Then PID 1 blocks,
   and logind (session scopes), ssh logins, `systemctl` and the 30 s unit
   timeouts all stop. A host plugged in gives the port room, the write
   completes, the lock drops: "plugging USB in fixes it".
4. Every earlier stall fits: the journal shows `serial-getty@ttyGS0`
   restarting at each cable pull (19:52:41, 20:04:03, 20:17:53, 20:37:21) and a
   stall at the next tinydm start or stop. The GPU was only ever coincident
   (all tests started the desktop). The SGX driver loaded directly, then
   `nexusq-sgx.service`, and 40 console writes with the GPU loaded all behaved
   (`drafts/stall/stall-monitor-v2.sh`, `gpu-wake-probe.sh`).

Reproduction and proof without a cable (`drafts/stall/gadget-detach-test.sh`:
unbinding the gadget from its UDC is a cable pull for u_serial; rebinding is
the rescue, and the script reboots the unit itself if that fails):

| run | `TTYReset` on ttyGS0 | console lock after the unbind | trigger | PID 1 |
|---|---|---|---|---|
| control | yes (systemd default) | WRITE by `(agetty)`, `wait_woken` | restart getty@tty1 | silent 30 s, wchan `locks_lock_inode_wait`; answers 3 s after the rebind |
| fixed | no | none | restart getty@tty1 | answered throughout |
| fixed | no | none | `systemctl start tinydm` | answered throughout; desktop up on the GPU |
| fixed | no | none | `systemctl stop tinydm` | answered throughout |

**Fix (device r128):** `serial-getty@ttyGS0.service.d/10-nexusq-no-tty-reset.conf`
sets `TTYReset=no`. Without it the executor takes no lock and writes nothing;
agetty still waits for a host in its own write, which blocks nobody, and there
is no screen state to reset at the far end of an ACM link anyway. Fleet impact:
every unit without a USB host has the parked executor after any ttyGS0 getty
restart; it only bites when something resets a TTY in PID 1, which today is
mostly the HDMI desktop. `tests/test_aports.py` (`GadgetConsoleNoTtyReset`)
guards the drop-in and its install path (seen red with `TTYReset=yes` and with
the install removed).

The root cause upstream — a blocking write under the global console lock — is
worth reporting to systemd (not filed; needs Petr's word).

### Side effect found on the way: reading `/proc/tty/driver/*` hung the unit

Reading the serial driver's status file during the investigation hung CPU0
for good (RCU stall: `rcu_preempt kthread starved … ->cpu=0`, CPU1 not
reporting), the unit dropped off the network and needed a power cycle; the
ramoops record did not survive the cold start. Not investigated yet; until it
is, do not read `/proc/tty/driver/*` on a unit.

## Fault 2: a panic in dma_fence_release (fixed in r26, patch 0075)

ramoops of the reproduction boot: `rmmod` printed
`PVRLinuxFenceDeInit: 1 fences leaked`; when the stall ended, PID 1 closed a
dma-buf and oopsed: `Unable to handle kernel paging request at virtual address
bf4232c4`, `PC is at dma_fence_release+0x4c`, call trace `__fput` →
`dma_buf_release` → `drm_gem_dmabuf_release` → `omap_gem_free_object` →
`drm_gem_object_release` → `dma_resv_list_free` → `dma_fence_release`.
`bf4232c4` is in the unloaded module: a pvr fence sat in the reservation
object of an omapdrm buffer (labwc's scanout BO, held by PID 1) and outlived
`pvrsrvkm`; Linux 6.18's `dma_fence_release` reads `fence->ops->release`
unconditionally. Patch 0075 pins the module with its first fence (rmmod then
fails with EBUSY until reboot); a module_put in the release callback would
still return through freed text. Production never unloads the driver
(`nexusq-sgx.service` has no ExecStop), so only development is affected —
but a panic is a panic.

## State left behind

- Prague unit, 2026-10-12 21:30: running **r26 from the trial slot B** (slot A
  still r21; it came up on r26 even after the power cycle — to check), promote
  service still masked. Installed by hand: device r127, nexusq-sgx r0,
  nexusq-sgx-mesa r0, plus the r128 drop-in copied in place. tinydm enabled
  again, the desktop runs on the GPU.

## Next

1. Build device r128; the measurement gate (groundwork §4 Phase 5) before any
   release of the GPU packages.
2. The `/proc/tty/driver` hang above.
3. Report the systemd lock/blocking-write issue upstream (ask Petr first).
