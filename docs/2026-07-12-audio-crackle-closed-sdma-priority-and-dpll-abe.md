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

## 5. Release state — v1.8.1 = kernel r42 (finalized on Ubuntu, see §7)

- The user decided the release is **v1.8.1 with kernel r42**. An intermediate
  same-day **r41-only** build of that version passed the gate first (its artifacts
  had sha256 `5cc4e8c1…`/`46f31943…`) but was **superseded and overwritten** before
  release.
- The Windows-built v1.8.1 artifacts (verification gate passed 2026-07-12
  afternoon; boot sha256 `51748379…babd7bf`, sparse `ab6bc0dc…98b915`) were
  **SUPERSEDED the same evening** by the Ubuntu rebuild in §7 — the Windows rootfs
  shipped WITHOUT WiFi/BT firmware (the gotcha below). The r42 kernel *source* is
  identical between the two builds; the byte differences are rebuild artifacts.
- **The FINAL v1.8.1 artifacts + hashes are in §7.**

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
The final v1.8.1 rebuild + re-flash was handed over to the Ubuntu machine and
**completed the same evening — see §7** (the audio-fix verification above is
unaffected — it was done on the prior rootfs).

## 6. Session context — Windows build-host gotchas (durable)

- **MSYS/Git-Bash path mangling breaks the docker run**: `-v "$PWD:/src"` gets
  mangled (`/src` → `C:/Program Files/Git/src`). **Launch the docker build from
  PowerShell** on this machine (or neutralize with `MSYS_NO_PATHCONV=1`).
- **CRLF broke the build**: sed-parsed APKBUILD vars and the dos2unix whitelist
  choke on CRLF line endings. During the v1.8.1 build `core.autocrlf` was set
  **false machine-locally** and the worktree **renormalized to LF**.

## 7. FINAL v1.8.1 — Ubuntu rebuild + flash + 10/10 acceptance (2026-07-12 evening)

Completion of the Windows→Ubuntu handover: the image was rebuilt on
`petronijus-PC` with the **populated `./firmware/` overlay**, flashed, and
acceptance-swept. This closes the v1.8.1 release work (tag next).

### Build (full docker build, exit 0 — ALL verification gates PASS)

- Firmware staging confirmed: build log `Staged BCM4330 firmware` (NOT the empty
  fallback); rootfs `/lib/firmware/brcm/` complete — `brcmfmac4330-sdio.bin` +
  `.txt`, `BCM4330B1.hcd`, and the `google,steelhead` board-named aliases.
- Kernel: `linux-google-steelhead-6.12.12-r42` (`#43-postmarketOS`).
- DTB decompiled **from the packed boot.img** confirms the 0042 fix: `&mcbsp2`
  `assigned-clocks` (`abe_dpll_refclk_mux_ck` → `sys_clkin_ck`, `dpll_abe_ck`
  98304000).
- libpython ship gate CLEAN (3×); boot.img ramdisk-less **5,543,936 B**; sparse
  rootfs all-RAW **23 chunks**, de-sparse round-trip verified against the raw.

### FINAL artifact hashes (`output/nexusq-v1.8.1.sha256`)

- `nexusq-boot-v1.8.1.img` — sha256
  `6d55b3485e9b1704ec398348ed8e30e8fb50b4628f69a8337f1d60d6bfd42157`
- `nexusq-rootfs-v1.8.1-sparse.img` — sha256
  `ec3d47a03cb0ff73940ee40054e8153586b649856d1d2da36e162c16fe1c748d`
- `nexusq-rootfs-v1.8.1-raw.img` — sha256
  `d4f1bba550002f21f377c862bbe32bbe50185c9ee0eb183552d5f50c23bd6f2e`

These SUPERSEDE the Windows-build hashes in §5 (boot `51748379…`, sparse
`ab6bc0dc…`, raw `065baada…`). The boot.img was rebuilt too — **same r42
source**, the byte difference is only from the rebuild.

### Acceptance — full nexusq-diag sweep, **10/10 PASS** (`nq-captures/20260712-233542/`)

- `uname`: `6.12.12 #43-postmarketOS` (kernel r42).
- Clock fix live: `abe_dpll_refclk_mux_ck` under `sys_clkin_ck`, DPLL_ABE
  **98.304 MHz**.
- sDMA fix live: `GCR 0x00011010`, audio channel CCR bit6 = 1.
- **WiFi RESTORED** (the Windows-rootfs regression fixed): 5 GHz associated,
  IP **192.168.20.184**, factory MAC `f8:8f:ca:20:48:e1` correct.
- **BT RESTORED**: controller `F8:8F:CA:20:49:E5`, `Frame reassembly failed` = 0.
- Audio stack healthy: TAS5713 default sink, 48 kHz, `tsched=0`, Speaker at
  unity, idle-suspended.
- CPU 1.2 GHz reached, VDD_MPU **1380 mV exact**; thermal peak **96.7 °C**, no
  throttle (the thin-headroom watch-item stands).
- `dmesg` err/warn EMPTY; journal = only the 3 known externals; **0 failed
  units**; nexusqd / NFC / python3 healthy.

### ⚠️ Durable operational note — the WiFi DHCP lease CAN move

The router reassigned the lease **`.195` → `192.168.20.184`** on 2026-07-12
even though wlan0 keeps the pinned factory MAC (router-side reassignment; eth0's
random-per-boot MAC was already known). **The connect flow must not hardcode
`.195`** — treat any cached WiFi IP as a hint and re-discover by hostname
`steelhead` / factory MAC in the router leases.

### Remaining

- Tag `v1.8.1` (main session, right after this sweep) — closes the Todoist
  AI-handover item "finish v1.8.1 on Ubuntu".
- Human step: the user's listening test on the final image (the crackle fix was
  already user-confirmed on the earlier r42 boot).
