# 2026-07-03 — NFC FIXED (wrong pinmux pads) + batch-2b flash `#29` ACCEPTED

The day's headline: **NFC works.** The PN544 was never dead — our DTS muxed the
**wrong pads**, so the chip's control lines were never actually driven from
mainline. Found by the **stock RAM-boot discrimination test** during the batch-2
flash cycle; fixed in a regenerated patch 0003 (kernel pkgrel 27→**28**, batch
"2b"); flashed the same day as `6.12.12 #29-postmarketOS` + device r20 and the
full acceptance run **PASSED**. This validates the never-conclude-dead-hardware
rule for the third time (ethernet 2026-06-22, TWL6040 2026-07-03, now NFC).

## 1. The NFC root cause: `nfc_pins` muxed the dpm_emu debug pads

The DTS `nfc_pins` node used IOPAD offsets **`0x1b4`/`0x1b6`/`0x1b8`** — those
are the **`dpm_emu3/4/5` debug pads**, not the PN544's. The real pads for
gpio162/163/164 on steelhead are **`usbb2_ulpitll_dat1/2/3` at
`0x16a`/`0x16c`/`0x16e`**. So:

- the GPIO **controller** side was driven correctly (gpio162 FW / gpio163 VEN /
  gpio164 IRQ — the logical numbers matched stock all along, which is why the
  2026-07-02 "pins MATCH stock" audit passed: it compared **logical pins**, not
  the IOPAD **offsets** the DTS actually muxed);
- but the **pads** were never muxed to GPIO mode 3 → VEN/FW/IRQ never reached
  the chip → no i2c ACK at 0x28 under any VEN/fw combination → the chip looked
  **electrically dead** from every mainline-side probe (the 2026-07-02 verdict).

Two wrong verdicts on the way, both retracted before the truth landed:
1. **"dead hardware"** (2026-07-02 live probe) — it toggled gpios into unmuxed
   pads, so the probe proved nothing about the chip;
2. **"software parity complete → suspect board-level"** (2026-07-03 §6 regulator
   audit) — right about the power path, but nobody had compared the pinmux
   **offsets** against a live stock mux dump until the stock RAM boot.

## 2. How it was found: the stock RAM-boot discrimination test

`fastboot boot output/stock-adb-boot.img` (the adb-enabled stock 3.0.8 RAM
boot), musl-static i2c-tools pushed over adb. Under stock:

- `i2cdetect` **ACKs at 0x28** with VEN high; **silent with VEN low**; ACKs in
  fw-download mode too;
- the driver's exact **6-byte core-reset frame is accepted, rc=0** — the chip
  is alive and speaking HCI.

That instantly discriminated hardware-vs-software. Then the **live `omap_mux`
debugfs dump from the WORKING stock kernel** gave the exact pad truth:

```
0x16a usbb2_ulpitll_dat1 = 0x0003   (OUTPUT | MODE3 → gpio_162, FW)
0x16c usbb2_ulpitll_dat2 = 0x0003   (OUTPUT | MODE3 → gpio_163, VEN)
0x16e usbb2_ulpitll_dat3 = 0x011b   (INPUT_PULLUP | MODE3 → gpio_164, IRQ)
```

The full stock mux dump is preserved at **`reverse-eng/stock-omap-mux-full.txt`**
(gitignored local artifact, like the rest of `reverse-eng/`) — it is the
ground-truth reference for ANY future pinmux question on this board.

**Lesson (now the gold standard):** when a peripheral looks dead under mainline,
boot the stock kernel from RAM on the same unit and probe it there — one test
splits hardware from software definitively, and a live stock `omap_mux` dump
beats any board-file reading of logical pin numbers.

## 3. The fix (batch 2b, kernel pkgrel 28)

- `nfc_pins` corrected to `OMAP4_IOPAD(0x16a…0x16e)` with the stock modes/pulls
  (patch 0003 regenerated);
- the `pn544@28` node **re-enabled** (was `status = "disabled"` since the
  retracted dead-HW verdict); patch 0020's stock-faithful VEN settle still in
  place.

Verified on `#29` (final-boot dmesg):
```
pn544_hci_i2c 2-0028: NFC: Detecting nfc_en polarity
pn544_hci_i2c 2-0028: NFC: nfc_en polarity : active high
```
**CLEAN detection — no "Could not detect… fallback" line** (the original B15
symptom is gone by being *fixed*, not by disabling the node), and
`/sys/class/nfc/nfc0` exists. Tag-read testing is the remaining follow-up.

## 4. Batch-2b acceptance run (`#29`, 2026-07-03) — PASSED

Flashed: kernel `linux-google-steelhead` pkgrel **28** (uname
`#29-postmarketOS`, all 31 patches) + `device-google-steelhead` **r20**.
Capture: `nq-captures/20260703-144228/`; dmesg preserved in the session
scratchpad (`final-dmesg-29.txt`).

- **uname `#29`**, `nproc=2`.
- **B22 GONE:** `twl: not initialized` count = **0** in the whole boot (patch
  0030 verified). **B23 GONE:** no "Skipping twl internal clock init" (0031).
- **All batch-1 wins holding:** no OUT-OF-RANGE / cpuidle registration error /
  clkctrl ID>24 / deferred McPDM / PVDD dummies / vbus warning / Alternate-GPT.
- **WiFi factory MAC on air:** `f8:8f:ca:20:48:e1` (the NM
  `cloned-mac-address` pin works; brcmfmac/OTP bypassed at the NM layer).
  **NEW AND FINAL IP: `192.168.20.195`.** pwrseq probes @4.5 s.
- **CPU/power nominal:** governor `ondemand`, 1200 MHz @ **1 380 000 µV exact**,
  cpuidle C1 state0; thermal 69.8 °C idle / **91.8 °C peak** under load.
- **LED:** the `frame` bin_attr is readable (patch 0029), the fingerprint
  changes while animating, `nq-healthd --once` sampled `led_sum=4416`.
- **Audio:** only pulseaudio in `ps`; `Loopback` + `NexusQSpeaker` cards.
- **Remaining err/warn = exactly the known-open residue:** B4 (clm/txcap +
  `google,steelhead.bin` probe miss), B10 hw-breakpoint, B16 ramoops
  (cold boot), B21 (journald BPF/ACL, L2C aux, gpmc cs0, pmu affinity).

### NEW finding — ethernet PARTIAL COMEBACK (first carrier since v1.4.0)

`eth0` has **carrier=1 / operstate up for the first time since the v1.4.0
regression** (task #17) — dmesg `#29`:

```
[   74.521575] smsc95xx 1-1:1.0 eth0: Link is Up - 100Mbps/Full - flow control off
[   74.836364] smsc95xx 1-1:1.0 eth0: Link is Down
[   76.502716] smsc95xx 1-1:1.0 eth0: Link is Up - 100Mbps/Full - flow control off
```

But the link **flaps** (NM disconnect/connect within ~1 s) and **DHCP never
completes** — making `NetworkManager-wait-online.service` the ONE failed unit
this boot (the capture's yellow finding). Follow-ups (new open items):

1. **Root-cause the flap** — likely one of the batch clock changes (0025 clkdev
   / `CLK_TWL=y` / VC-voltage work) revived enumeration; this is a strong new
   lead for task #17 — the LAN9500A now enumerates AND links, so what's left is
   keeping the link up.
2. **Ship an eth0 NM profile with may-fail semantics** so wait-online doesn't
   fail the boot on a flapping/cable-less port.

### NEW finding — `led_frozen` still needs a static-by-design guard

The r20 frame fingerprint **works** (readable frame attr, real md5/byte-sum),
but the acceptance capture still ended verdict=CRIT on `led_frozen`: the
**screensaver intentionally locks a static frame after ~300 s idle**
(`SS_LOCK_S`) and the v1.6.5 keepalive re-commits **identical bytes** — so the
fingerprint legitimately stops changing on a perfectly healthy device.
`led_frozen` CRIT is therefore a **false positive on any idle device**, by
design, until guarded. Fix direction (open, `pmos/device-google-steelhead/
nq-healthd` + `scripts/diag/nq-health-report`): only escalate `led_frozen` to
CRIT when **`nq_resp=0` or `nexusqd_no_progress` co-fires**; a static frame
with a responsive daemon is INFO at most. Until fixed, diagnostics on an idle
device must expect this false CRIT.

## 5. Status after 2026-07-03 (end of day)

- **NFC: FIXED AND WORKING** (clean polarity detect, nfc0 registered; tag test
  pending). B15 closed for real.
- Image = the **v1.6.6 release candidate** (kernel r28 `#29` + device r20),
  accepted; release pending Petr's go.
- Open: the eth0 flap root-cause + NM may-fail profile (task #17, now with a
  live lead), the `led_frozen` static-by-design guard, then the standing
  B4/B10/B16/B21, U5 (watch), U6, U7, PA HDMI-UCM, deep cpuidle C2+.
