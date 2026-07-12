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

## 5. Release state — v1.8.1 built + verified, NOT tagged; r42 supersedes r41

- A **v1.8.1 full image** (kernel **r41**, rootfs content identical to v1.8.0) was
  built 2026-07-12 and **passed the full verification gate**. Artifacts in
  `output/`:
  - `nexusq-boot-v1.8.1.img` — sha256 `5cc4e8c1b48874fc67fc12f5d33069b91bb2b6edadfddc3aa83a97f3bfaec55d`
  - `nexusq-rootfs-v1.8.1-sparse.img` — sha256 `46f31943485db3e01fddc194ad5ed159a96a9abb0757ea607d4dd7fdcdd9f4ca`
- **NOT tagged/released** — the decision (release v1.8.1 as-is vs going straight to
  a **v1.9.0** with r42) is still open with the user. **r42 supersedes r41 as the
  current kernel** (r42 = r41 + patch 0042); the r42 boot.img
  (`output/boot-r42-abe-sysclk.img`) is what runs on the device now.

## 6. Session context — Windows build-host gotchas (durable)

- **MSYS/Git-Bash path mangling breaks the docker run**: `-v "$PWD:/src"` gets
  mangled (`/src` → `C:/Program Files/Git/src`). **Launch the docker build from
  PowerShell** on this machine (or neutralize with `MSYS_NO_PATHCONV=1`).
- **CRLF broke the build**: sed-parsed APKBUILD vars and the dos2unix whitelist
  choke on CRLF line endings. During the v1.8.1 build `core.autocrlf` was set
  **false machine-locally** and the worktree **renormalized to LF**.
