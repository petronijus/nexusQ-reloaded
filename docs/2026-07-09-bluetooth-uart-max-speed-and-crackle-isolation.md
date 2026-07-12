# 2026-07-09 — Bluetooth A2DP fixed (BT UART max-speed) + crackle ISOLATED to the output path

Two results this session, tightly linked. Bringing up **Bluetooth A2DP** was the
diagnostic experiment owed at the end of the crackle investigation
(`docs/2026-07-08-audio-crackle-dma-contention.md`, "NEXT step — Bluetooth A2DP as a
DIAGNOSTIC"). Getting A2DP to work required first fixing a real BT bug — and once it
worked, it answered the crackle question.

Ships as **v1.8.0** (kernel `linux` r39 → **r40**, device `device-google-steelhead`
**r38**). v1.7.4 is burned (see the 2026-07-08 note "Update 2"); v1.8.0 is its
working successor — the v1.7.4 bad configs are removed and the crackle mitigation is
now the safe subset (`tsched=0` baked + Speaker-unity pin + +24 dB ceiling).

## 1. Bluetooth A2DP now reliable — ROOT CAUSE = BT HCI UART had no `max-speed`

The BCM4330 Bluetooth HCI runs over **UART2**. Our DTS `&uart2` BT node had **no
`max-speed` property**, so the `hci_bcm` driver left `oper_speed = 0` and **never
synchronised the host UART to the baud the BCM4330 firmware operates at**. Host and
controller drifted apart, producing:

- a stream of `Bluetooth: hci0: Frame reassembly failed (-84)` (**EILSEQ** —
  corrupted HCI bytes on the wire),
- HCI command **tx timeouts**,
- a **phantom "Connected" state** that did not reflect reality,
- A2DP audio arriving in **corrupt bursts** (~1 s of sound then several seconds of
  silence), the phone ultimately dropping the link (**HCI reason 0x13**,
  remote-user-terminated).

This — **NOT** WiFi/BT coexistence, and **NOT** HFP/SCO — was the real cause of every
past "BT won't stay connected / reports the wrong state" symptom. Both earlier
guesses (coexistence, HFP/SCO) were wrong.

### Fix — kernel patch `0040`

`kernel/patches/0040-ARM-dts-omap4-steelhead-bt-uart-max-speed-3M.patch` adds to the
BT node:

```
max-speed = <3000000>;   /* 3 Mbaud — the operating baud stock ran the BT UART at */
```

Stock Android ran the steelhead BT UART at **3 Mbaud**; matching it lets `hci_bcm`
command both the controller and the host UART to the same rate so the link is clean.
Hardware flow control (**RTS/CTS**) is already muxed in `uart2_pins` — no pinmux
change needed. Kernel pkgrel → **40**.

### Verified on device (after a boot.img flash)

- `Frame reassembly failed` count = **0** (was **26+** per session).
- Controller address = correct unicast **F8:8F:CA:20:49:E5** (the `local-bd-address`
  is honoured; not the old non-unique `43:30:A0:00:00:00` placeholder).
- Pairing + A2DP playback **stable**, user-confirmed: *"bluetooth jede, perfektni
  prace."*

### The A2DP path on the Q (now a real, baked capability)

```
phone → BT (A2DP) → PulseAudio bluez_source (s24le / 48 kHz, no resample) → looped to the TAS5713 sink
```

## 2. Crackle ISOLATED to the output path (the whole point of bringing up A2DP)

A2DP is a **completely different INPUT path** from librespot (it bypasses librespot
**and** WiFi entirely: `phone → BT → PA` vs `WiFi → librespot → PA`). The diagnostic
question was: does the crackle follow the input, or the shared output?

**Result: A2DP shows the SAME periodic drops as librespot.** Therefore the crackle
is **NOT** in the app, **NOT** in librespot, **NOT** in WiFi/network — it is in the
**COMMON OUTPUT path**:

```
PulseAudio → TAS5713 → sDMA → McBSP2
```

This **confirms** the 2026-07-08 bus / DMA-contention hypothesis directly (two
independent input paths, one shared symptom).

### Outstanding crackle fix (identified, NOT done yet)

The OMAP4 **sDMA `HIGH_PRIORITY`** patch: set `CCR_READ_PRIORITY` (`BIT(6)` in
`drivers/dma/ti/omap-dma.c` — defined but never applied to any channel) on the
**McBSP2** cyclic DMA channel so the audio reads outrank SDIO/USB at the sDMA/L3
port. `omap4_data.rw_priority = true` already enables the GCR path; only the
per-channel bit is missing. Would help **any** player (librespot, BT, cast).

## 3. v1.7.4 crackle-bake reverted — v1.8.0 keeps only the safe subset

The unusable v1.7.4 artifact's bad additions are **removed** from the device package
(`device-google-steelhead` r38):

- **REMOVED** — the McBSP2 THRESHOLD op-mode service
  (`nexusq-mcbsp-threshold.service`); threshold garbles audio on this hardware
  (channel-shift, corruption not underrun).
- **REMOVED** — the 600 ms PA buffer (`60-nexusq-latency.conf`); user-rejected.
- **REMOVED** — the RT scheduling configs (`10-nexusq-rtprio.conf` +
  `CPUSchedulingPolicy` on the user units); crashed pulseaudio/librespot with
  `214/SETSCHEDULER` (user services can't `SCHED_RR` without `CAP_SYS_NICE`).

**KEPT as the working crackle mitigation:**

- **`tsched=0`** baked into `/etc/pulse/default.pa` via the apk **trigger** (the
  device package now also triggers on `/etc/pulse`; patches `module-udev-detect` →
  `module-udev-detect tsched=0`, same trigger pattern as the TAS5713 mixer path).
- the **TAS5713 Speaker-unity pin** (`[Element Speaker] volume = zero`, so PA drives
  only Master), and the **+24 dB volume ceiling** — both from v1.7.2/v1.7.3.

## Maturity

- **Kernel 0040 (BT fix): VERIFIED live** on device after a boot.img flash (counts +
  address + user-confirmed A2DP above).
- **Full v1.8.0 rootfs image: BUILT + pending on-device verification** (a full build
  is running in parallel; the `tsched=0` bake + v1.7.4 revert land in the rootfs, not
  boot.img, so they need a full flash to confirm).
- The **crackle root-cause fix (sDMA HIGH_PRIORITY)** is still **not implemented** —
  the outstanding audio task.

> **RESOLVED 2026-07-12 — the crackle investigation is CLOSED.** The sDMA
> `HIGH_PRIORITY` fix landed as kernel **r41** patch `0041` and killed the
> load-correlated component — which revealed a SECOND, independent fault: a
> metronomic ~1/s load-independent click from **two free-running crystals**
> (mainline reparented the DPLL_ABE reference to sys_32k while the TAS5713 MCLK
> sits on the 38.4 MHz crystal), fixed by kernel **r42** patch `0042` (DPLL_ABE
> relocked from sys_clkin at 98.304 MHz — stock topology). Hardware-verified,
> user-confirmed perfectly clean playback. (Also: v1.8.0 was tagged 2026-07-10.)
> Full write-up: `docs/2026-07-12-audio-crackle-closed-sdma-priority-and-dpll-abe.md`.
