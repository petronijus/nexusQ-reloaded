# 2026-07-08 — Audio crackle ("lupance") = memory-bus / DMA contention (diagnosed; live-only mitigations)

Follow-on to the same-day volume work
(`docs/2026-07-08-audio-volume-scale-and-bootlog-cleanup.md`). The long-standing
Spotify-playback **crackle / "lupance"** ("regular clicks; the audio doesn't
connect smoothly, it jumps back a little") on `librespot → PulseAudio → TAS5713`
is now **root-caused**, and a stack of **live-only** mitigations made it
"dramatically better, occasional glitch remaining."

> **MATURITY — READ FIRST.** Nothing here is shipped, baked, or committed.
> - The tuning below is **config-persistent** on the *running rootfs* (it survives
>   a reboot because it lives in `/etc/...`), but a **reflash wipes it** — none of
>   it is in the device package (`device-google-steelhead`) yet.
> - The manual **RT thread promotion** (`chrt`) and the **cpu_dma_latency** holder
>   are **runtime-only** — LOST on reboot.
> - The **root-cause fix** (give the audio SDMA bus priority) is **NOT implemented**.
> The only committed + baked audio work of the day is the volume/dial/boot-log
> change (commit `2634b45`, image **v1.7.3 / device r37**) — see the sibling note.
> - **UPDATE 2 (later same day):** a bake attempt (**v1.7.4 / device r38**)
>   **REGRESSED** — the **v1.7.4 artifact is UNUSABLE, do not flash it** (threshold
>   op-mode is harmful; systemd RT on the user services crash-loops audio). Details in
>   "Update 2" at the bottom.

## The diagnosis (headline)

The periodic/occasional crackle is **memory-bus / DMA contention on the L3/EMIF
interconnect**: the audio SDMA channel that refills the **McBSP2** FIFO
**underflows in hardware** when other bus masters — WiFi SDIO, the USB-ethernet
LAN9500A, memory-heavy tasks — contend for the interconnect. The starved FIFO
produces the click, and the "jumps back a little" is the stream re-syncing after
the gap.

It is **below** the two layers software normally reaches for:
- **Below the PA buffer.** The buffer feeds the DMA, but the **DMA → McBSP2 FIFO**
  refill is **hardware-timed**; a bigger buffer helps the *scheduler* jitter but
  cannot cover a bus-arbitration stall at the FIFO.
- **Below thread scheduling.** The SDMA is a **DMA engine + hardirq**, not a
  schedulable thread — so thread priority (even SCHED_FIFO) cannot move it. And
  the WiFi RX path is a **softirq (NAPI)**, which runs **above ALL userspace
  threads including SCHED_FIFO** — so no userspace RT priority can out-prioritize
  the contending traffic.

### Proven by elimination + a load test
- **Not a PA-buffer underrun / not CPU starvation / not network fetch:** **0**
  PulseAudio XRUN, **0** dmesg audio underruns, low CPU, librespot logs **clean**
  during steady playback.
- **Not the LED tap / not NFC:** stopping the nexusqd LED tap (`arecord` on the
  monitor) **and** the NFC daemon did **not** fix it.
- **It worsens with ANY concurrent activity — and it is NOT WiFi-specific.** Even
  the operator's **ssh over ETHERNET** (which is USB on this device — the
  LAN9500A) audibly breaks it. A deliberate **CPU + memory-bandwidth stress test**
  made it **"definitely worse"** (user's word).
- **Not (only) idle-retention latency:** `cpu_dma_latency = 0` (forbid deep CPU
  idle) did **not** fix it → it is bus **arbitration/contention**, not interconnect
  wake latency.

## What was applied LIVE (config-persistent; NONE baked into the device package)

In order of impact:

1. **`tsched=0` — the biggest win ("dramatically better").**
   `/etc/pulse/default.pa`: `load-module module-udev-detect tsched=0`. PA's
   **timer-based scheduling** was the main *periodic*-click source; with `tsched=0`
   PA falls back to **fixed ALSA fragments** (interrupt-driven) and the regular
   ticking largely stops.

2. **Bigger PA buffer.** `/etc/pulse/daemon.conf.d/60-nexusq-latency.conf`:
   `default-fragments = 8`, `default-fragment-size-msec = 50` (≈ **400 ms**,
   `buffer_size` 76800). With **hardware volume** the dome dial stays instant
   despite the big buffer (only the LED visualizer lags a little).
   - **683 ms tried and rejected** (too much latency).
   - **`soxr-mq` resampler tried and REVERTED** — too heavy for the OMAP4, it made
     the audio **CPU-fragile**; back to the default light resampler.

3. **Priority.** Same `60-*.conf`: `high-priority = yes`, `nice-level = -11`,
   `realtime-scheduling = yes`, `realtime-priority = 5`.
   - The `RTPRIO` rlimit was **0**, so PA's realtime request **silently fell back**.
     Fixed with a systemd drop-in
     `/etc/systemd/system/user@10000.service.d/10-nexusq-rtprio.conf`
     (`LimitRTPRIO=95`, `LimitNICE=-15`) → PA then has `RTPRIO=9` and **rtkit** runs.
   - **BUT** PA still only takes **high-priority (nice -11)**, not SCHED_FIFO for
     its IO thread (rtkit granted high-priority but not realtime). So the audio
     thread was manually promoted with **`chrt -f -p 55`** (and the librespot
     threads to 45). **That manual `chrt` is RUNTIME-ONLY and is LOST on reboot** —
     a permanent mechanism is still owed (a small service that promotes the
     `alsa-sink` thread, or fixing PA's realtime path).

**Net result:** "dramatically better, occasional glitch remaining." The residual
glitch is the bus/DMA contention above — which the software mitigations soften but
cannot eliminate.

## What survives the reboot the user just did

The user **hard-powered** the device to stop a runaway stress test (see below), so
the box booted back with only the config-persistent bits:

- **Survives:** `tsched=0`, the 400 ms buffer, `nice -11`, the `RTPRIO` limit, and
  `Speaker = zero` (this last one *is* baked — device r37, the volume fix).
- **LOST:** the manual RT `chrt` and the `cpu_dma_latency` holder (both runtime-only).

So the device boots "dramatically better than the start" **but without the RT
thread**.

## The real fix (NOT yet done — next focused step)

Give the **audio SDMA higher priority on the bus** so it wins arbitration and the
McBSP2 FIFO does not underflow under contention. A kernel patch + rebuild.
Candidate levers:

- OMAP4 sDMA channel **`HIGH_PRIORITY` bit** (`DMA4_CCR`) for the McBSP2 audio channel.
- L3 NoC / EMIF **initiator QoS** for the audio DMA path.
- **omap-mcbsp FIFO threshold** deeper + the mainline **omap-mcbsp PM QoS** patch
  (*"ASoC: omap-mcbsp: Add PM QoS support to prevent glitches"*) — check whether
  our 6.12.12 already carries it and whether the QoS value is tight enough.

**Also pending (baking):** port all the live tuning into the device package —
`tsched=0`, the `60-nexusq-latency.conf`, the `10-nexusq-rtprio.conf` drop-in —
**plus a permanent RT-thread-promotion mechanism** to replace the manual `chrt`.

## Operational note — stress test locked out ssh

The on-device stress test used **unbounded `while :;` CPU busy loops**; they
saturated both cores and **starved sshd**, locking out ssh on **all** transports →
the user had to **hard-power** the device. **Future on-device stress must be
`timeout`-bounded and niced** (e.g. `timeout 20 nice -n 19 …`) so it can never
wedge the control path.

---

## Update 2 (later 2026-07-08) — the v1.7.4 bake attempt REGRESSED; DO NOT flash it

> **MATURITY — still nothing shipped.** The v1.7.4 build baked the live tuning into
> `device-google-steelhead` **r38**, but the **v1.7.4 ARTIFACT is UNUSABLE** — two of
> the baked items are broken (one harmful, one crash-loops audio). The repo service
> files were corrected afterwards, but the **built v1.7.4 image still carries the bad
> config — do not flash it.** The root-cause kernel fix is still **not implemented**.

### What was baked into v1.7.4 (device r38) and how each fared

1. **McBSP2 `dma_op_mode=threshold`** via a boot service
   (`nexusq-mcbsp-threshold.service`) — **HARMFUL, reverted to `element` live.**
2. **`tsched=0`** into `default.pa` via the trigger — **keeper.**
3. **600 ms PA buffer** (`60-nexusq-latency.conf`) — **too long** (adds
   LED-visualizer lag); **~400 ms was the sweet spot.**
4. **`RTPRIO` limit drop-in** (`10-nexusq-rtprio.conf`) — fine, but insufficient on
   its own (see #5).
5. **RT via `CPUSchedulingPolicy=rr`** on `pulseaudio.service` + `librespot.service`
   — **BROKEN, crash-loops both user services → NO AUDIO.**

### 1. THRESHOLD op-mode is HARMFUL — reverted to ELEMENT

With `dma_op_mode=threshold` the playback was **"completely broken / interrupts
exactly like originally"** (user), with **0 PA XRUN and 0 dmesg XRUN** — so it is
audio **corruption/garble, not underrun**. This matches the stock-parity auditor's
channel-shift warning for threshold mode: mainline stereo runs **ELEMENT** →
`pkt_size = 2` / `threshold = 2` words; THRESHOLD raises maxburst/threshold and can
**shift channels**.

**Conclusion: threshold op-mode must NOT be used on this hardware.** The earlier
"threshold improved it" reading (Update 1 / the RT session) was **confounded** — RT
and WiFi-PM-off were applied around the same time; threshold's *isolated* effect is
neutral-to-harmful. **Action still owed (not yet done): remove/disable
`nexusq-mcbsp-threshold.service` from the device package.**

### 2. RT via systemd `CPUSchedulingPolicy=rr` on the USER services FAILS

Both user services crash-loop with
`status=214/SETSCHEDULER: Failed to set up CPU scheduling: Operation not permitted`
→ `pulseaudio` **and** `librespot` never start → **NO AUDIO**.

**Root cause:** even with the user manager's `LimitRTPRIO=95` (confirmed — user
manager pid rlimit `RTPRIO=95`) **and** per-service `LimitRTPRIO=95`, the child user
services still cannot `sched_setscheduler(SCHED_RR)` — the system
`DefaultLimitRTPRIO=0`, and user-session RT via `CPUSchedulingPolicy` needs
**`CAP_SYS_NICE`**, which user services lack.

The `CPUSchedulingPolicy` lines were **REMOVED** from the repo service files
(`pulseaudio.service`, `librespot.service`) — **the repo is fixed, but the v1.7.4
artifact still has them (unusable).** A permanent RT mechanism must be a **ROOT
promoter** (a system service that `chrt`s the PA `alsa-sink` + librespot threads —
root can always set RT; the live `chrt -f -p 55` worked), **NOT** user-service
`CPUSchedulingPolicy`.

### What actually helps (live-confirmed, impact order) — the keepers

`tsched=0` (biggest), **WiFi runtime-PM off**
(`/sys/class/net/wlan0/device/power/control = on`), the **PA buffer** (~**400 ms**
was the sweet spot; **600 ms adds LED-visualizer lag**), and the **RT `chrt`** (FIFO
~55 on the audio thread + ~45 librespot). Net at best: **"dramatically better,
occasional glitch."** The occasional residual is the bus/DMA contention (confirmed:
a CPU + memory stress test made it "definitely worse"; even the operator's ssh over
**ethernet** — which is USB on the device — breaks it, so it is not WiFi-specific).

### New clue — librespot suspected as a contributor

**Cold start:** the first **1–2 s** of the first stream after a cold boot is
"completely broken", then it **"catches" and stabilises** — classic **librespot
ramp-up** (its `--backend alsa --device pulse` path; librespot 0.8 has **no native
PulseAudio backend**, only rodio/alsa/pipe/subprocess). So part of the problem may be
**librespot itself**, separate from the DMA contention.

### The real root-cause fix (identified, NOT yet implemented)

From the stock-parity audit: set the OMAP4 **sDMA `HIGH_PRIORITY` bit**
(`CCR_READ_PRIORITY`, `BIT(6)` in `drivers/dma/ti/omap-dma.c` — **defined but never
applied to any channel**) on the **McBSP2** (mem→dev, sig 32 / tas5713) cyclic DMA
channel, so audio reads **outrank SDIO/USB** at the sDMA/L3 port.
`omap4_data.rw_priority = true` already enables the GCR path; **only the per-channel
bit is missing.** A small kernel patch. This addresses the contention **at the
source** and would help **librespot AND Bluetooth AND any player**.

### NEXT step — Bluetooth A2DP as a DIAGNOSTIC

Bring up the device as an **A2DP sink** (bluez + `pulseaudio-bluez` present; adapter
**"Google Nexus Q"**, BD addr **F8:8F:CA:20:49:E5** valid, A2DP sink endpoints
registered). Play from the phone over BT — this **BYPASSES librespot + WiFi**:
- BT audio **CLEAN** → the crackle is in the **source path** (librespot / WiFi).
- BT **also crackles** → it is in the **output path** (PA → TAS5713 → sDMA / McBSP2).

Pairing is currently **not completing** (being debugged). This is the key experiment
to localize the fault.

> **RESOLVED 2026-07-09 → the crackle is in the OUTPUT path.** The pairing failure
> was a real BT bug (the HCI UART had no `max-speed`; fixed by kernel patch `0040`,
> shipped v1.8.0). With A2DP working, the experiment ran: **A2DP crackles the SAME
> way as librespot** — so the fault is **NOT** in librespot/WiFi, it is in the shared
> **output** path (PA → TAS5713 → sDMA → McBSP2), confirming the DMA-contention
> hypothesis. Full write-up:
> `docs/2026-07-09-bluetooth-uart-max-speed-and-crackle-isolation.md`.

### Current live device state (v1.7.4 flashed, then hand-tuned)

`element` mode (threshold **reverted**), `tsched=0`, **600 ms** buffer, **WiFi PM
off** (live), **NO RT** (`CPUScheduling` removed live). **Audio works but still
interrupts.**
