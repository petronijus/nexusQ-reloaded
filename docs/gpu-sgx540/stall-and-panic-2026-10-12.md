# The first GPU desktop: an 8-minute stall and a panic, 2026-10-12

Prague unit, kernel 6.18.48-r25 (trial slot B), device r127 with nexusq-sgx
r0 and nexusq-sgx-mesa r0 installed from local builds. The GPU desktop itself
works ([route-a-musl-2026-10-12.md](route-a-musl-2026-10-12.md)); this note is
about the two faults found while bringing it up. Neither is solved; one has a
fix built (r26, not yet booted).

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

## Fault 1: an 8-minute stall around the driver load/unload

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

- Prague unit: slot A r21 (booted after the panic), slot B r25; promote
  service still masked. Installed by hand (`apk add` of local builds, not from
  the OTA repo): device r127, nexusq-sgx r0, nexusq-sgx-mesa r0; blobs fetched
  in `/var/lib/sgx-ddk/lib`. On r21 the desktop starts on Pixman.
- r26 (r25 + 0075) built, not booted.

## Next

1. Boot r26 in the trial slot; run the stall monitor with USB unplugged,
   first-load-after-boot (the production path) several times across reboots,
   then with an earlier unload attempt (now EBUSY).
2. From the stacks: fix the stall at its cause.
3. Then the measurement gate (groundwork §4 Phase 5) before any release.
