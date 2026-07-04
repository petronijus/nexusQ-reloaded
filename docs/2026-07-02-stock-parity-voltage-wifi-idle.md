# 2026-07-02 — Stock-parity audit: OMAP4460 voltage domains, the CLK32KG naming trap, cpuidle, NFC

Stock-kernel audit (`reverse-eng/vmlinux.bin`, steelhead 3.0.8 SMP) done while
root-causing the 2026-07-02 boot-error inventory
(`docs/2026-07-02-boot-error-inventory.md`, items B12/B13/B15/B17). Everything
here is **evidence from the stock binary or the live device**, per the
verify-hypothesis-against-stock rule. Outcome: kernel patches **0023/0024/0025/
0027/0028** + the DTS changes in patch 0003 — **in tree, build in progress
2026-07-02, not yet flashed** (kernel pkgrel 26 → uname `#27`).
_(Update 2026-07-03: **flashed + verified** — B12/B13/B15/B17 all confirmed gone
on `#27`; per-item results in `docs/2026-07-02-boot-error-inventory.md`
§"FLASH-VERIFIED 2026-07-03". One new sibling finding, **B22**: the
`twl: not initialized` line survived as a ×22 burst from the 0013/0014 vdd_mpu
init path — a different call site than the VC-init one fixed here.)_

_(Update 2026-07-03, later: the audit was **extended into a full regulator
audit** — see the new **§6** below. Two major consequences: the §4 "dead
hardware" NFC verdict is **RETRACTED** (status: under investigation), and the
TWL6040 turned out to be **unused/unpopulated on steelhead** — never a dead
codec. B22 is fixed by patch 0030 in batch 2, built 2026-07-03, awaiting
flash.)_

_(Final update 2026-07-03: the §6.3 stock RAM-boot test ran — **the NFC chip
is healthy; our DTS muxed the wrong pads. NFC is FIXED and working on `#29`**
(batch 2b, kernel pkgrel 28). See the new **§7**. B22/B23 verified gone on
`#29`.)_

## 1. The OMAP4460 voltage-domain table (fixes B12)

Stock per-domain PMIC descriptors (`omap4_mpu_pmic` / `omap4_iva_pmic` /
`omap446x_core_pmic`):

| Domain | Rail owner | VC volt/cmd regs | ON voltage |
|--------|-----------|------------------|-----------|
| VDD_MPU | **TPS62361** (external, i2c `0x60`) | — (dedicated SR/VC path) | **1 375 000 µV** |
| VDD_IVA | TWL6030 **VCORE2** | `0x5B`/`0x5C` | **1 188 000 µV** |
| VDD_CORE | TWL6030 **VCORE1** | `0x55`/`0x56` | **1 200 000 µV** |

- Only **MPU** runs at 1.375 V, and on the 4460 that rail is the TPS62361 —
  **not** a TWL channel. Mainline `vc44xx_data.c` programs a blanket
  1 375 000 µV ON/ONLP into **all three** VC channels → the twl6030 vsel
  conversion for IVA+CORE ×(on, onlp) logged the ×4
  `twl6030_uv_to_vsel:OUT OF RANGE! non mapped vsel for 1375000 Vs max 1316660`
  and silently programmed the 1.35 V fallback vsel (an over-volted wake target
  for both TWL rails). → **patch 0027** (per-domain ON/ONLP voltages).
- **VCORE3 is unmapped by stock on the 4460** (`twl_set_4460vcore`, "unmap APE
  VCORE3"); mainline's 4430-default core channel pointed at it. → patch 0027
  also retargets the 4460 core VC channel to **VCORE1** (`0x55`/`0x56`).
- The `max 1316660` ceiling itself was a second bug: the SMPS_OFFSET efuse is
  read lazily and the first conversion runs from `omap_vc_init_channel()`
  (late_initcall, ~0.77 s) **before** the DT-probed twl-core is up (~3.9 s) —
  the read fails (`twl: not initialized` ×4) yet mainline **latched** the
  all-zero result as valid (ES1.0 scale forever). Live efuse read over i2c
  2026-07-02: **`SMPS_OFFSET=0x7f`, `SMPS_MULT=0x52`** (bit3 set → ES1.1+
  0.7–1.4 V scale, ceiling 1 417 960 µV). → **patch 0023** (no latch on fail +
  steelhead seed `0x7f`).

## 2. The CLK32KG "clk32kaudio" naming trap (fixes B17's clock path)

`steelhead_wifi_power` (stock, `0xc0077884`) powers the BCM4330 as:
**clk32k on → 300 ms settle → WLAN_EN high → 200 ms**.

The trap: the clock stock enables is requested under the consumer string
`"clk32kaudio"`, but the board data (`steelhead_twldata+0x8c`) wires that name
to the **TWL6030 CLK32KG regulator** (CFG_TRANS `0x8C`); the real CLK32KAUDIO
slot is NULL. Our DTS took the name at face value and used `<&twl 1>`
(CLK32KAUDIO, `0x8F`) — gating the **wrong pin**, so the BCM4330's 32 kHz LPO
never actually ran (WiFi *and* BT node). Fixes in the DTS (patch 0003):

- WiFi pwrseq + BT `clocks = <&twl 0>` (**CLK32KG**);
- `clk-settle-delay-ms = <300>` on the pwrseq, matching stock's 300 ms
  clk-before-WLAN_EN settle — a new optional `mmc-pwrseq-simple` property
  (**patch 0028**).

Caveat (per Petr): **5 GHz WiFi already works well** — this is stock-parity
*correctness*; no promises that it improves the known bulk-throughput issues.

## 3. Stock cpuidle: C1–C4, with C2+ behind the HS secure dispatcher (fixes B13)

Stock registers **C1–C4**; the C2+ MPUSS power transitions on this **HS** part
go through secure dispatcher services **`0x1c`/`0x1d`/`0x21`**. That is why
mainline's deep-idle path faulted with CPU1 online (the original reason for
`cpuidle.off=1`, v1.2.0) — the secure-side handshake is simply missing.
→ **patch 0024**: a **C1-only (WFI)** cpuidle driver on steelhead, replacing
`cpuidle.off=1` (removed from `CONFIG_CMDLINE`). Deep idle (C2+ via the secure
dispatcher) is a **future project**, not attempted here.

## 4. NFC PN544: pins MATCH stock — the chip is electrically dead (B15)

> **VERDICT RETRACTED 2026-07-03** — per the never-conclude-dead-hardware rule
> and the §6 regulator audit, the status is **UNDER INVESTIGATION**, not dead:
> software parity with stock is now COMPLETE (stock has no software power path
> for the PN544 at all, and our regulator steady-state matches stock
> bit-for-bit), so the no-ACK is **unexplained**. The "same category as the
> TWL6040" comparison collapsed too — the TWL6040 was never a dead chip (§6).
> Next discriminator: NFC under the stock RAM boot (§6.3). The original
> 2026-07-02 text below is kept as the record.
>
> **RESOLVED 2026-07-03 (later) — NFC FIXED; this section's "pins MATCH"
> verdict needs a correction: the NAMES matched but the audit compared
> LOGICAL pins, not the IOPAD offsets our DTS used.** The stock RAM boot
> (§6.3, executed) proved the chip healthy, and the live stock `omap_mux`
> dump showed our `nfc_pins` muxed the **dpm_emu3/4/5 debug pads**
> (`0x1b4`/`0x1b6`/`0x1b8`) instead of the real `usbb2_ulpitll_dat1/2/3`
> pads (`0x16a`/`0x16c`/`0x16e`) — so gpio162/163/164 were driven correctly
> at the controller but never reached the chip. Full story + fix in **§7**
> below and `docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md`.

Stock `nfc_gpios` (`0xc0719750`): en=**163** active-high, fw=**162**,
irq=**164** pull-up; `pn544_dev_ioctl` VEN timing 20/60 ms. Our DTS/driver
matched all of it — so the polarity-fallback warning was not a description bug.
Live probe 2026-07-02 (i2c-tools): **no ACK at 0x28 or anywhere on i2c-2** with
VEN high, VEN low, or in firmware-download mode (FW=1 + VEN=1); the driver's
exact 6-byte core-reset frame NAKed. Verdict: **dead hardware**, same category
as the TWL6040 codec on this unit. DTS node set `status = "disabled"`
(patch 0020's stock-faithful VEN settle is kept for a healthy unit).

## 5. Reusable RE tooling (preserve!)

This audit built reusable tooling that currently lives only in the **session
scratchpad**: a **kallsyms parser**, **`nqdis.py`** (targeted disassembler for
`vmlinux.bin`), and **`callers.py`** (xref/callers walker). They should be
**preserved into `reverse-eng/`** (gitignored dir, fine for tooling) before the
scratchpad is garbage-collected — not moved yet as of this note.

## 6. 2026-07-03 — full stock regulator audit: the steelhead_twldata array, the TWL6040 correction, the NFC retraction

Follow-up audit (2026-07-03) of the complete stock TWL6030 board data, done to
close the remaining power-path suspicions behind the NFC no-ACK and the old
"dead TWL6040" verdict. Outcome: **two major corrections** + the evidence that
our mainline regulator state is stock-parity complete.

### 6.1 The full stock `steelhead_twldata` regulator array

| TWL6030 slot | Stock wiring |
|--------------|--------------|
| **VAUX1** | **3.0 V, always-on, no consumer** |
| VAUX2, VAUX3 | boot-off |
| VPP, VUSIM | off |
| VANA, V2V1, VCXIO | always-on |
| VMMC | → hsmmc |
| VDAC | → `hdmi_vref` |
| VUSB | → twl usb |
| **CLK32KG** | boot_on, consumer string **"clk32kaudio"** (the §2 naming trap) |
| CLK32KAUDIO | slot **NULL** |
| codec (twl6040) pdata | slot **NULL** (`steelhead_twldata+0x24` @ `0xc0719b30`) |

Stock also runs `regulator_has_full_constraints`. A live `regulator_summary`
was captured on the running mainline device (2026-07-03 session transcripts):
**our mainline regulator state matches this array bit-for-bit** — software
parity on the power side is COMPLETE.

### 6.2 TWL6040 was NEVER a "dead codec" — the chip is unused/unpopulated

The 2026-06-10 verdict ("dead chip: no i2c ACK on 0x4b with rails +
AUDPWRON up") was **wrong in kind**, not in measurement:

- the stock 3.0.8 image contains **ZERO** twl6040/AUDPWRON code — whole-image
  string + symbol sweep over `reverse-eng/vmlinux.bin`;
- the twldata **codec pdata slot is NULL** (`steelhead_twldata+0x24` @
  `0xc0719b30`);
- stock's i2c1 board info registers **only `twl6030@0x48`** — nothing at 0x4b;
- the removed DTS node's `ti,audpwron-gpio` (gpio_127) had **no stock
  evidence** either.

So the missing ACK at 0x4b is the **stock-correct behaviour** of a chip that
is simply not used (and almost certainly not populated) on this board. Actions
(batch 2, in tree): twl6040 node + ABE sound card + `twl6040_pins` **deleted**
from the DTS (explanatory comment left in place), defconfig `TWL6040_CORE` /
`SND_SOC_TWL6040` / `SND_SOC_OMAP_ABE_TWL6040` / `CLK_TWL6040` disabled; the
DTB compiles with zero twl6040 refs (verified in the binary).

### 6.3 NFC: no stock software power path → the "dead" verdict is retracted

The audit closed the **last software suspicion** for the PN544 no-ACK:

- stock pn544 pdata = **3 gpios only** (en/fw/irq — §4);
- **`pn544_probe` makes zero regulator calls**; VBAT/PVDD ride hardwired rails;
- with §6.1 showing our rail state identical to stock's steady-state, there is
  **nothing left software could be doing differently**.

Software parity is COMPLETE and the no-ACK remains **UNEXPLAINED** → per the
never-conclude-dead-hardware rule the §4 verdict is **retracted**; status
"under investigation". **Next discriminator** (scheduled for the imminent
flash cycle): test NFC on this unit under the **stock RAM boot**
(`output/stock-adb-boot.img`; plan ready — unbind pn544 → sysfs gpio163 VEN
high → `i2cdetect`/`i2ctransfer` on 0x28 with pushed musl i2c-tools; the stock
kernel is confirmed to have i2c-dev via kallsyms). If stock ACKs, diff further
(i2c timing/pads); hardware measurement of the VBAT pin is the last resort.
The DTS pn544 comment was rewritten accordingly (node stays disabled so a
known-cause probe failure doesn't pollute every boot).

## 7. 2026-07-03 (flash cycle) — the stock RAM boot ran: chip HEALTHY, our PINMUX was wrong → NFC FIXED

The §6.3 discrimination test was executed during the batch-2 flash cycle and
settled the question in one session:

### 7.1 Stock RAM-boot evidence (the chip is alive)

`fastboot boot output/stock-adb-boot.img`, musl-static i2c-tools pushed over
adb. Under the stock kernel on THIS unit:

- `i2cdetect`: **ACK at 0x28 with VEN (gpio163) high**; **silent with VEN
  low**; ACK in fw-download mode (FW=1 + VEN=1) too;
- the driver's exact **6-byte core-reset frame accepted, rc=0**.

So every 2026-07-02 mainline-side "no ACK" measurement was true but
meaningless — the mainline kernel was never actually driving the chip.

### 7.2 The pinmux discovery (live `omap_mux` dump from the working kernel)

The stock kernel's `omap_mux` debugfs dump — taken while NFC was ACKing —
gave the ground truth our board-file reading never had:

| Pad | Offset | Stock value | Meaning |
|-----|--------|-------------|---------|
| `usbb2_ulpitll_dat1` | **0x16a** | `0x0003` | OUTPUT \| MODE3 → **gpio_162 FW** |
| `usbb2_ulpitll_dat2` | **0x16c** | `0x0003` | OUTPUT \| MODE3 → **gpio_163 VEN** |
| `usbb2_ulpitll_dat3` | **0x16e** | `0x011b` | INPUT_PULLUP \| MODE3 → **gpio_164 IRQ** |

Our DTS `nfc_pins` had **`0x1b4`/`0x1b6`/`0x1b8`** — the **dpm_emu3/4/5**
debug pads. The §4 audit passed because it verified the **logical** gpio
numbers, polarities and timings (which DID match stock) — it never checked
which **IOPAD offsets** our DTS was muxing for those gpios. Correction of
method for future audits: **a pinmux claim is only verified against pad
offsets from a live mux dump**, not against logical pin numbers.

The full dump is preserved at **`reverse-eng/stock-omap-mux-full.txt`**
(gitignored local artifact, non-redistributable dir) — the reference for any
future pinmux question on this board.

### 7.3 Fix + verification

`nfc_pins` corrected to the real pads + `pn544@28` re-enabled (patch 0003
regenerated; kernel pkgrel **28** → uname `#29`, "batch 2b"). On `#29`:
`NFC: Detecting nfc_en polarity` → **`NFC: nfc_en polarity : active high`**
(clean, no fallback), `/sys/class/nfc/nfc0` registered. **NFC works**; the
tag-read test is the remaining follow-up. Third confirmation of the
never-conclude-dead-hardware rule (ethernet, TWL6040, now NFC) — and the
**stock RAM-boot discrimination test is the gold standard** for
hardware-vs-software questions on this device.
