# 2026-07-12 — Playback crackle CLOSED: two independent layers (sDMA read-priority r41 + DPLL_ABE sys_clkin r42)

The crackle investigation
(`docs/2026-07-08-audio-crackle-dma-contention.md` →
`docs/2026-07-09-bluetooth-uart-max-speed-and-crackle-isolation.md`) is **CLOSED**.
The "lupance" turned out to be **TWO independent faults stacked on top of each
other**, both fixed and both hardware-verified 2026-07-12:

| Layer | Symptom | Fix | Commit |
|---|---|---|---|
| A — bus/DMA contention | load-**correlated** drops (worse with ssh/scp/WiFi/USB traffic) | kernel **r41**, patch **0041** (sDMA read priority) | `fc7e280` |
| B — two free-running crystals | metronomic **~1/s** click, load-**independent** | kernel **r42**, patch **0042** (DPLL_ABE ← sys_clkin) | `9f76754` |

Final state: **user-confirmed perfectly clean playback** on kernel
`#43-postmarketOS` (r42) — *"bez jedinyho zaskobrtnuti"*.

## 1. Layer A — load-correlated drops → sDMA HIGH read priority (r41, patch 0041)

The fix owed since 2026-07-08/09: `drivers/dma/ti/omap-dma.c` defines
`CCR_READ_PRIORITY` (`BIT(6)`) but never applied it to any channel. Patch **0041**
sets it on the **cyclic (audio) channel** and reserves a high-priority thread in the
GCR (**`HI_THREAD_RESERVED = 1`**), so the McBSP2 FIFO-refill reads outrank SDIO/USB
at the sDMA/L3 port.

**Verified live on device:**

- `GCR = 0x00011010` (HI_THREAD_RESERVED=1 present),
- the active audio channel (**ch20**) has **CCR bit6 = 1**.

**Effect — and the key diagnostic pivot:** after r41 the crackle became
**load-INDEPENDENT** — ssh/scp bus load no longer affected it at all. What remained
was a strictly metronomic ~1/s click. That behavioral change is what isolated
layer B (a periodic, traffic-immune click is a *clock* signature, not a contention
signature).

## 2. Layer B — the metronomic ~1/s click = TWO FREE-RUNNING CRYSTALS (r42, patch 0042)

### Root cause

Mainline `clk-44xx.c` reparents the DPLL_ABE reference
(**`CM_ABE_PLL_REF_CLKSEL`**, `abe_dpll_refclk_mux_ck`) to **sys_32k** (the
32.768 kHz watch crystal) for deep-idle PM — idle states steelhead never enters
(C1-only, patch 0024). Meanwhile the TAS5713 **MCLK** (auxclk1 12.288 MHz) derives
from **DPLL_PER / sys_clkin** (the 38.4 MHz system crystal). So the McBSP2
bit/frame clocks and the amp MCLK sat on **different crystals**: each is an exact
48 kHz multiple in its own timebase, and they drift at the crystals' relative ppm
offset — **~21 ppm ≈ one sample slip per second at 48 kHz** = the metronomic click.

**Stock never has this topology.** The stock-parity audit found that the stock
**x-loader AND the second-stage bootloader both force the mux to SYS_CLK and lock
DPLL_ABE at exactly 98.304 MHz (M=64/N=24)**, and the stock kernel never touches it
— our port was **actively undoing the bootloader's correct setting** at clk init.
Evidence trail:

- **x-loader** `prcm_init` tail, file offsets **`0x5c7c–0x5ca0`**: `bic #1` on
  `CM_ABE_PLL_REF_CLKSEL` (`0x4a30610c`) — mux forced to SYS_CLK.
- **bootloader** (second stage), file offsets **`0x1e0c–0x1e30`**: same sequence.
- **stock kernel** `board-steelhead` `steelhead_init`:
  `clk_get`/`clk_set_parent` chain at **`0xc0016770`+** in
  `reverse-eng/vmlinux.bin` — parents set, DPLL_ABE left as the bootloader locked it.

### Fix — kernel r42, patch 0042

`kernel/patches/0042-ARM-dts-omap4-steelhead-abe-dpll-ref-sys-clkin.patch` — DTS
`assigned-clocks` on `&mcbsp2`: reparent `abe_dpll_refclk_mux_ck` →
`sys_clkin_ck` and relock `dpll_abe_ck` at **98304000** (assigned-clock parents are
applied before rates, so the relock uses the new reference). Single reference
crystal for the whole audio path = the stock topology.

**Verified on device (kernel `#43-postmarketOS`):** `clk_summary` shows
`abe_dpll_refclk_mux_ck` under `sys_clkin_ck` (38.4 MHz) and `dpll_abe_ck` at
**98304000**; playback is clean — user-confirmed, not a single dropout.

## 3. ⚠️ REPO GOTCHA (learned the hard way): editing `kernel/dts/omap4-steelhead.dts` alone does NOT reach the build

The DTS enters the kernel tree **via patches** (`0003` + follow-ups) —
`kernel/patches/*.patch` is what the build scripts stage into the kernel source;
`kernel/dts/omap4-steelhead.dts` is the reference copy only. **The first r42 build
was a silent no-op** (the boot.img carried the old DTB) until the DTB verification
step caught it; the change had to become **patch 0042** to take effect.

**Rule: any DTS change must land as a `kernel/patches/` patch (new patch or a
regenerated 0003), and the built DTB must be verified to contain the change.**

## 4. Build-infra fixes (commit `554175b`, `scripts/build-kernel-boot.sh`)

Three failure modes hit while building r41/r42:

1. **Stale-apk trap** — the newest-glob apk selection grabbed a *stale* kernel apk
   from the persistent work-volume repo instead of the one just built. Fixed:
   select by **exact `pkgver-pkgrel`** parsed from the staged APKBUILD.
2. `ls | head` under `pipefail` → **SIGPIPE, rc 141**. Fixed: no pipe-into-head.
3. Newer `postmarketos-installkernel` installs **`boot/vmlinuz-<kernelrelease>`**
   instead of `boot/vmlinuz`. Fixed: extract the whole `boot/` tree and **glob
   `vmlinuz*`** (busybox tar has no `--wildcards`).

## 5. Release state — v1.8.1 = kernel r42 (released same evening)

- The user decided the release is **v1.8.1 with kernel r42**. An intermediate
  same-day **r41-only** build of that version passed the gate first (its artifacts
  had sha256 `5cc4e8c1…`/`46f31943…`) but was **superseded and overwritten** before
  release.
- Final v1.8.1 artifacts (full verification gate passed 2026-07-12 evening; the
  Docker-crash-interrupted extraction was redone and every hash proven end-to-end):
  - `nexusq-boot-v1.8.1.img` — sha256 `517483798331b57e79564cb7e47412a18f673691ee7e9afbb8af67cb9babd7bf`
    (bit-identical to the DTB-verified `boot-r42-abe-sysclk.img`)
  - `nexusq-rootfs-v1.8.1-sparse.img` — sha256 `ab6bc0dcd92451bac5920a358bf040d230bd63cdb6b1c634fe1387ddb398b915`
    (all-RAW, 34 chunks; de-sparse round-trip == raw `065baada6e9931b36f67dba4a101d76dbab3909171af154815a7b037ce025a24`)
  - rootfs proven to install `linux-google-steelhead-6.12.12-r42`, init=systemd,
    python3 3.14.5-r5 with the libpython ship gate CLEAN.
- **Flashed to the device** (boot + userdata) the same evening — **but this rootfs
  shipped WITHOUT WiFi/BT firmware** (see below) and must be rebuilt + re-flashed
  before the v1.8.1 tag.

### ⚠️ Firmware-overlay machine-setup gotcha (found by the flash)

The flashed rootfs had **no `wlan0`** and `/lib/firmware/brcm/` empty:
`firmware-google-steelhead` was the **empty-fallback variant**. Root cause: the
gitignored `./firmware/` overlay (bcm4330.hcd + bcmdhd.cal from
`private/firmware/`) had **never been populated on the Windows build machine** —
`docker-build.sh`'s `[ -f "$SRC/firmware/bcm4330.hcd" ]` check silently packs the
empty package. It is populated there now (2026-07-12). **On any new build machine:
`cp private/firmware/bcm4330.hcd private/firmware/bcmdhd.cal firmware/` first**,
and check the build log for `Staged BCM4330 firmware` (NOT the empty fallback).
The verification gate must include `/lib/firmware/brcm/` contents from now on.
Final v1.8.1 rebuild + re-flash + tag handed over to the Ubuntu machine (the
audio-fix verification above is unaffected — it was done on the prior rootfs).

## 6. Session context — Windows build-host gotchas (durable)

- **MSYS/Git-Bash path mangling breaks the docker run**: `-v "$PWD:/src"` gets
  mangled (`/src` → `C:/Program Files/Git/src`). **Launch the docker build from
  PowerShell** on this machine (or neutralize with `MSYS_NO_PATHCONV=1`).
- **CRLF broke the build**: sed-parsed APKBUILD vars and the dos2unix whitelist
  choke on CRLF line endings. During the v1.8.1 build `core.autocrlf` was set
  **false machine-locally** and the worktree **renormalized to LF**.
