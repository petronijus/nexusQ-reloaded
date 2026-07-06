# Changelog

All notable changes to Nexus Q Reloaded. Format follows
[Keep a Changelog](https://keepachangelog.com/). Versioning is tag-only
(milestone-based) — there is no version string in the source.

## [1.6.9] - 2026-07-06

> Boot-log cleanup: the two residual once-per-boot / per-ssh log-noise items
> are gone (gkr-pam keyring, PulseAudio HDMI card) — the boot log is now clean.
> Device pkg r23; kernel unchanged `#33-postmarketOS` (boot.img byte-identical
> to v1.6.8). Cosmetic only, no functional change.

> Framed for **v1.6.9** (PUBLIC build + release in progress, handled
> separately — no git tag from here). All cosmetic boot-log cleanup, **no
> functional change**; device pkg **r23**, kernel **unchanged** `6.12.12-r32`
> (uname `#33`). Acceptance **ACCEPT on r23** (clean fastboot flash): **0 failed
> units**, gkr=0, HDMI-audio noise=0, ethernet cold-init works (100Mbps/Full),
> WiFi/NFC/CPU healthy, no new regression; the residual err/warn are all the
> known-benign set. Watch-item: under sustained dual-core load the SoC peaked
> **~98–99 °C** (below the 100 °C passive trip, no throttle) — the known thin
> thermal headroom.

### Fixed
- **Boot-log cleanup (cosmetic, device pkg r23; no functional change).** Two
  once-per-boot / per-ssh log-noise items on an otherwise-clean boot, both
  root-caused and fixed (not masked):
  - **`gkr-pam: couldn't unlock the login keyring`** on every key-based ssh
    session — `/etc/pam.d/base-auth`+`base-session` now shadow the Alpine base
    to drop the desktop-keyring PAM lines (gnome-keyring is a hard dep of
    nm-applet/gvfs/webkit so it stays installed; nothing here uses the user
    keyring; `pam_systemd`/`pam_rundir` → `XDG_RUNTIME_DIR` preserved, and every
    base-session line is `-session optional` so a stale copy can never block
    login). Verified: **0 gkr lines across fresh logins, sessions register**
    (`loginctl`).
  - **PulseAudio `module-alsa-card: Failed to find a working profile`** on the
    omap-hdmi-audio card every boot — a `PULSE_IGNORE` udev rule tells PA to
    skip it (the card is a snd-soc-dummy-DAI with no usable IEC958 sink; HDMI
    carries desktop video only, device audio is TAS5713 + snd-aloop).
    - **r22 → r23 correction:** the first attempt (r22) pinned
      `KERNEL=="card1"` and was **rejected in acceptance** — the ALSA card index
      is **probe-order dependent** (HDMI enumerated as `card2` that boot), so the
      rule tagged the wrong card and PA still errored. r23 matches the backing
      **platform device** instead: `SUBSYSTEM=="sound", KERNEL=="card*",
      KERNELS=="omap-hdmi-audio.1.auto"` — index-independent. Verified on r23:
      `PULSE_IGNORE=1` lands only on the HDMI card, **0 module-alsa-card errors**.
    - **Lesson:** ALSA card indices are probe-order dependent — a per-card udev
      rule (`PULSE_IGNORE` and friends) MUST match by backing device (`KERNELS=`)
      or card id, **never** by `cardN` index.
- `bluetoothd: Failed to set default system config for hci0` is left as
  **documented-benign**: bluez sends `MGMT_OP_SET_DEF_SYSTEM_CONFIG` regardless
  of `main.conf` and the BCM4330B1 rejects the batch, but the controller
  initialises and works (`Powered: yes`) — no clean suppression exists.

## [1.6.8] - 2026-07-06

> Ethernet works from a cold boot at last: the LAN9500A cold-init bug (task
> #17) is fixed and gold-validated (clean fastboot flash + true cold
> power-cycle → eth0 100Mbps/Full, 0 failed units). Kernel `#33-postmarketOS`
> (r32), device pkg r21.

> Framed for **v1.6.8** (PUBLIC build + release in progress). Kernel
> `linux-google-steelhead` pkgrel **32** (uname **`#33`**); no device-pkg change.

### Fixed
- **ETHERNET COLD-INIT FIXED — task #17 FULLY CLOSED (2026-07-06).** The
  LAN9500A now enumerates from a **true cold boot** after a clean flash. Root
  cause (same class as the NFC pinmux bug): `gpio_1` NENABLE — the LAN9500A
  power-enable — is pad **`kpd_col2` at CORE padconf offset `0x186`**, but the
  DTS `ethernet_gpios` node muxed only `gpio_62` NRESET (`0x08c`); `0x186` was
  omitted (a prior comment wrongly placed `gpio_1` in the wkup padconf). So
  gpiolib drove the `gpio_1` DATAOUT latch (debugfs read "asserted") while the
  pad stayed in **safe_mode** and NENABLE never reached the chip → the LAN9500A
  was never powered, never drove D+, and the port sat at **PORTSC CCS=0** on
  every cold boot. The healthy USB3320 PHY (its pads ARE muxed) masked it. Stock
  muxes both pads (`omap_mux_init_gpio` 1 & 62 @ VA `0xc00178d0`/`dc`, value
  `0x0e03`). **Fix:** DTS `ethernet_gpios` += `OMAP4_IOPAD(0x186, PIN_OUTPUT |
  MUX_MODE3)` (patch 0003; kernel pkgrel **32**, uname **`#33`**). Proven three
  ways: (a) a live mmio write of the pad register `0x4A100184` → `eth0` attach at
  100Mbps from the cold-failed state; (b) bidirectional causality (pad set →
  attach, pad cleared → detach); (c) **GOLD STANDARD** — a clean fastboot flash
  of `#33` + a **true cold power-cycle** → `eth0` enumerates **100Mbps/Full,
  0 failed units** (clean-flash warm boot #1 also enumerated). Commit
  **e33a1b4**. Together with the r21 NM eth profiles (v1.6.7, the
  serverless-DHCP-loop fix), ethernet is now fully working from cold: enumerate +
  link + no DHCP retry loop. `docs/2026-07-06-eth-coldinit-resolved.md`.
  - **Correction — the 2500ms "attach-ready settle" (kernel `#31`, commit
    6c869e8, "closes #17") was a FALSE POSITIVE, not a fix.** Those "5/5" boots
    all descended from a stock RAM boot via warm reboots that never cut LAN9500A
    power, so the stock-initialized chip just stayed attached; a clean flash /
    true cold boot without stock still failed. e33a1b4 **reverts** the patch 0006
    power block to stock timing (`udelay(100)`/`udelay(2)`, dropping the disproven
    200ms/50ms/2500ms delays) and removes the non-stock `gpio_159` (`0x164`) pad
    mux + `steelhead-eth-phy-reset-gpios` property (stock leaves that pad in
    safe_mode; not wired to the LAN9500A).
  - **Lesson (for future gpio bring-up):** debugfs / `gpiolib` reporting a line
    "asserted" only means the **DATAOUT latch** is driven — NOT that the pad is
    routed to the pin. Always verify the **IOPAD mux** against a live stock
    `omap_mux` dump (`reverse-eng/stock-omap-mux-full.txt`); a healthy sibling
    (here the USB3320 PHY) can mask a completely unmuxed control line. Probe live
    with the aligned `/root/mmio` helper + ULPI viewport reads — **never** python
    mmap (it wedges INSNREG05).
- **eth0 hw MAC is random per boot** — the LAN9500A has no MAC EEPROM, so on a
  real LAN the DHCP lease/IP changes every boot (match by hostname, not eth MAC).

## [1.6.7] - 2026-07-05

> Device pkg **r21** (kernel unchanged: `6.12.12-r28`, `#29-postmarketOS`).
> Flashed + accepted 2026-07-05: zero failed units across 3 boots (the baked
> eth profiles handle both a present and an ABSENT ethernet chip gracefully —
> `NetworkManager-wait-online` green either way), `led_static` guard verified
> live (33× info, zero false CRIT in 91 samples), NFC clean probe, WiFi factory
> MAC/.195, CPU/power nominal.

### Known issues
- **LAN9500A enumeration intermittency is BACK (task #17 REOPENED, narrowed):**
  on the acceptance boots the chip did not enumerate at all (USB CCS=0, 0/3
  boots; the 2026-07-03/04 boots enumerated 3/3 with the byte-identical
  kernel). The NM retry-loop half of #17 IS fixed (this release); the
  remaining half is the kernel/ehci bring-up race — the direct-cable
  `eth-direct` workflow was verified end-to-end on 2026-07-04 on an
  enumerated boot and is unaffected when the chip appears.
  _(RESOLVED 2026-07-06 in [Unreleased]/v1.6.8 — the enumeration half was the
  unmuxed `gpio_1` NENABLE pad; task #17 FULLY CLOSED, gold-validated from a
  true cold boot.)_

### Fixed
- **ETHERNET NM-LAYER RESOLVED (2026-07-04; task #17 narrowed, see Known
  issues).** The `#29` "partial
  comeback / carrier flap" was fully explained and fixed. The LAN9500A/driver
  is **fully healthy** (revived by batch 2b): with NM detached, carrier held
  90+ s with **zero transitions**, 100Mbps/Full, 0 rx/tx errors, under
  `ondemand` (rules out the cpufreq-timing theory for the current image). The
  "flap" was **NetworkManager's auto-generated "Wired connection 1" DHCP retry
  loop** on a wire with no DHCP server (the direct PC↔Nexus cable): 45 s DHCP
  timeout → deactivate resets the cloned "stable" MAC → the MAC write bounces
  the LAN9500A carrier → the carrier event resets NM's autoconnect-retries
  counter → reactivate — self-arming, ~47 s period, 14 811 journal lines in
  29 h; it also failed `NetworkManager-wait-online` (the one failed unit in the
  `#29` acceptance). Fix (`device-google-steelhead` **r21**, also hot-deployed
  to the running device): `eth-no-auto-default.conf` (`no-auto-default=eth0`) +
  baked `eth-lan.nmconnection` (DHCP, `dhcp-timeout=30`,
  `autoconnect-retries=1`, **`cloned-mac-address=permanent`** — no MAC churn →
  no carrier bounce → the retry counter sticks) + `eth-direct.nmconnection`
  (static 10.42.0.2/24 + 10.0.0.2/24, never-default, manual activation). Host
  side: persistent NM profile `eth-direct-host` on petronijus-PC `enp7s0`
  (10.42.0.1/24 + 10.0.0.1/24) — the direct-cable workflow needs zero ad-hoc
  setup on either end. Verified live 2026-07-04: eth0 settles at
  "disconnected" quietly (0 re-activations), carrier stable, **`nm-online -s`
  rc=0**, `nmcli c up eth-direct` → ping 3/3 (0.77 ms avg) → **`ssh
  root@10.42.0.2` works**. Caveat: eth0's hw MAC is **random per boot** (no
  MAC EEPROM) — on a real LAN the DHCP lease/IP changes per boot; pin a fixed
  cloned MAC in eth-lan if stable LAN identity is ever wanted.
  `docs/2026-07-04-ethernet-resolved-and-led-guard.md`.
- **`led_frozen` static-by-design guard (2026-07-04)** — the other open item
  from the `#29` acceptance. `nq-healthd` (r21, hot-deployed + restarted) now
  emits crit `led_frozen` **only when the frozen frame co-fires with distress**
  (`nq_resp=0` or `nq_progress=0`); a static frame with a healthy daemon emits
  **info `led_static`** (the screensaver locks a static frame by design).
  `scripts/diag/nq-health-report` mirrors the logic and splits the summary into
  `led_frozen_events` / `led_static_events`. Regression-tested on the
  `nq-captures/20260703-144228/` capture: verdict **CRIT → OK** with
  `led_static … 25 occasion(s)`.

> Deployment note: device pkg **r21** is baked in this image; the 2026-07-04
> hot-deploy is superseded — the device runs the flashed v1.6.7 image since
> 2026-07-05 (no regression window). No kernel change in this batch.

## [1.6.6] - 2026-07-04

> The whole 2026-07-02 boot-error fix batch below was **flashed 2026-07-03 and
> the acceptance run PASSED** — uname `#27-postmarketOS`, zero failed units,
> **9/10 targeted dmesg error classes gone** (only the `twl: not initialized`
> line survived, mutated into the new B22 burst). Kernel
> `linux-google-steelhead` pkgrel **26** (patches 0023–0028),
> `device-google-steelhead` pkgrel **19**. Inventory + per-item verification:
> `docs/2026-07-02-boot-error-inventory.md` ("FLASH-VERIFIED 2026-07-03");
> stock-parity evidence: `docs/2026-07-02-stock-parity-voltage-wifi-idle.md`.
>
> **Batch 2 shipped as batch "2b" — FLASHED AND ACCEPTED 2026-07-03**: during
> the flash cycle the scheduled **stock RAM-boot NFC discrimination test** found
> the real NFC bug (**wrong pinmux pads** — see the headline Fixed entry), so
> patch 0003 was regenerated once more and the kernel went out at pkgrel **28**
> (uname **`#29-postmarketOS`**, patches 0029–0031 + the NFC pinmux fix; all 31
> patches apply GNU-patch-clean) with `device-google-steelhead` pkgrel **20**.
> Acceptance on `#29` PASSED: **NFC detects cleanly**, B22/B23 lines gone
> (`twl: not initialized` count = 0), all batch-1 wins holding, the **factory
> WiFi MAC `f8:8f:ca:20:48:e1` on air** — final IP **`192.168.20.195`** — ring
> fingerprint via the readable `frame` attr, CPU/power nominal (ondemand,
> 1200 MHz @ 1 380 mV exact). One new finding: **ethernet partial comeback**
> (see Known issues). Capture `nq-captures/20260703-144228/`; full story:
> `docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md`. This image
> **is v1.6.6** (kernel `#29-postmarketOS`, r28 + device r20).

### Fixed
- **NFC (PN544) IS FIXED AND WORKING — the DTS muxed the WRONG PADS (B15,
  closed for real 2026-07-03).** `nfc_pins` used IOPAD `0x1b4`/`0x1b6`/`0x1b8`
  — the **dpm_emu3/4/5 debug pads** — while the real PN544 pads for
  gpio162/163/164 are **`usbb2_ulpitll_dat1/2/3` at `0x16a`/`0x16c`/`0x16e`**:
  the GPIO controller drove the right lines but the pads were never muxed to
  GPIO, so VEN/FW/IRQ never reached the chip and it looked electrically dead
  from every mainline probe (both prior verdicts — "dead hardware" 2026-07-02
  and "software parity complete, suspect board-level" — retracted). Found by
  the **stock RAM-boot discrimination test** (`fastboot boot
  output/stock-adb-boot.img` + musl i2c-tools over adb: chip ACKs at 0x28 with
  VEN high, exact 6-byte core-reset frame accepted rc=0, silent with VEN low)
  and the live **`omap_mux` debugfs dump from the working stock kernel**
  (`0x16a`/`0x16c` = `0x0003` OUTPUT|MODE3, `0x16e` = `0x011b`
  INPUT_PULLUP|MODE3; full dump preserved locally at
  `reverse-eng/stock-omap-mux-full.txt`). Fix: `nfc_pins` corrected + the
  `pn544@28` node re-enabled (patch 0003 regenerated, kernel pkgrel **28**).
  Verified on `#29`: `NFC: nfc_en polarity : active high` — **clean, no
  fallback** — and `/sys/class/nfc/nfc0` exists. Tag-read test pending.
  `docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md`.
- **twl6030 `OUT OF RANGE! non mapped vsel for 1375000` ×4 + `twl: not
  initialized` ×4 (B12)** — two stock-parity kernel patches: **0023** stops
  latching a failed early SMPS_OFFSET efuse read as valid (and seeds steelhead
  with the efuse value read live over i2c: `SMPS_OFFSET=0x7f`, `SMPS_MULT=0x52`);
  **0027** replaces mainline's blanket 1 375 000 µV VC ON/ONLP with the stock
  per-domain voltages (MPU 1 375 000 / IVA 1 188 000 / CORE 1 200 000 µV — the
  ×4 was the IVA+CORE VC channels ×(on,onlp)) and retargets the 4460 core VC
  channel VCORE3→VCORE1 (`0x55`/`0x56`; stock unmaps VCORE3).
- **`failed to register cpuidle driver` (B13)** — patch **0024** registers a
  C1-only (WFI) cpuidle driver on steelhead and `cpuidle.off=1` is dropped from
  `CONFIG_CMDLINE`. (Stock has C1–C4; C2+ needs the HS secure dispatcher
  services 0x1c/0x1d/0x21 — a future project.)
- **clkctrl `device ID is greater than 24` ×3 (B14)** — patch **0025**: ti-sysc
  child named clocks registered via `clkdev_add()` (no 24-char device-ID limit).
- **hsusb1-phy `dummy supplies not allowed for exclusive requests (id=vbus)`
  (B20)** — patch **0026**: usb_phy_generic gets its optional vbus supply with
  `devm_regulator_get_optional()`.
- **bcm4330-pwrseq ~25 s deferred probe (B17)** — `CONFIG_CLK_TWL=m`→`y` (the
  module deferred the pwrseq's 32k clock provider; WiFi only came up ~31 s) +
  the **CLK32KG naming-trap fix**: WiFi pwrseq + BT clocks `<&twl 1>`→`<&twl 0>`
  (stock enables TWL6030 **CLK32KG** 0x8C under the misleading consumer name
  "clk32kaudio" — our old CLK32KAUDIO value gated the wrong pin, so the BCM4330
  LPO never ran) + `clk-settle-delay-ms = <300>` (patch **0028**, new optional
  `mmc-pwrseq-simple` property) matching stock's clk→300 ms→WLAN_EN→200 ms.
  Parity correctness — 5 GHz WiFi already worked; no throughput claims.
  Verified 2026-07-03: pwrseq probes @4.31 s, mmc pwrseq allocated @6.10 s
  (was ~27 s).
- **`40132000.target-module` permanent deferred probe (B18)** — the
  `omap4-mcpdm.dtsi` include is dropped: McPDM's pdmclk provider is the dead
  TWL6040, and McPDM is unusable without the codec. _(2026-07-03: "dead"
  corrected to "absent" — the TWL6040 is unpopulated/unused on steelhead, see
  under Changed; the fix stands either way.)_
- **tas571x `PVDD_A..D not found, using dummy regulator` ×4 (B19)** — new
  `amp_pvdd` fixed regulator wired to the four PVDD supplies (deliberately no
  voltage props: rail unmeasured, TAS5713 spec 8–26 V, driver only enables).
- **PulseAudio-vs-PipeWire session conflict (U4)** — config-topology fix:
  PulseAudio is the pmOS backend and pipewire is only a library dep, but its XDG
  autostart double-started a second sound server and `pipewire-pulse.socket` had
  no service package behind it. Now: `Hidden=true` autostart overrides in
  `/etc/xdg/nexusq/` (via an `XDG_CONFIG_DIRS` prepend in `nexusq-wayland.sh`)
  + the orphaned user socket masked. (The PA HDMI-audio profile failure is a
  separate open item.) `device-google-steelhead` pkgrel 19 (was written up at
  18; the flashed apk is r19). Verified on device 2026-07-03: only pulseaudio
  in `ps`, no pipewire/wireplumber, no socket error.
- **Wandering WiFi IP** — the device's WiFi IP changed every boot because
  NetworkManager used a randomized locally-administered MAC (fresh DHCP lease
  per boot; this masqueraded as "WiFi dead" on 2026-07-02). New
  `wifi-stable-mac.conf` pins `cloned-mac-address=permanent` + disables scan
  MAC randomization. Verified 2026-07-03: WiFi auto-joins the baked profile,
  **stable IP `192.168.20.175`**. Note the on-air MAC is now the chip's OTP
  `14:7d:c5:3a:35:b5`, not the factory `f8:8f:ca:20:48:e1` (brcmfmac never
  reads the factory-cal MAC) — boot-stable; optionally bake `macaddr=` into
  the nvram to restore the factory identity (open decision).
- **Access regression (root ssh unreachable after a flash)** — `docker-build.sh`
  Phase 6 now stages `private/access/authorized_keys` → `/root/.ssh` +
  `/etc/skel/.ssh` (0600) and `private/access/wifi.nmconnection` →
  `/etc/NetworkManager/system-connections/` (0600, skipped when empty), so a
  clean reflash comes up reachable. The WiFi profile is generated per machine by
  the new `scripts/gen-wifi-profile.sh` (PSK from 1Password at run time; output
  gitignored even in the private overlay). Verified 2026-07-03: key-based
  `ssh root@` works over both the USB gadget (`172.16.42.1`) and WiFi after a
  clean flash. (A reflash regenerates the device ssh host key — `ssh-keygen -R`
  the stale entries.)
- **`twl: not initialized` ×22 burst @0.78 s (B22)** — patch **0030** _(verified
  GONE on `#29` 2026-07-03 — zero occurrences in the whole boot)_: `mfd: twl-core` exports a
  **`twl_is_ready()`** predicate; OMAP4 `omap_twl.c` gates the SMPS_OFFSET
  efuse read attempt AND the patch-0014 retask poll on it, and the retask work
  latches the real efuse the moment twl is up. Full call-site accounting of the
  ×22: per domain (IVA, CORE) 3 nonzero VC voltages ×2 read attempts (the
  `uv_to_vsel` path reads once directly and once via its `vsel_to_uv` range
  check) + the zero off-voltage ×1 + 2 VP limits ×2 = 11, × 2 domains = 22;
  the +2 poll repeats came from the 0014 retask probe.
- **`Skipping twl internal clock init and using bootloader value (unknown osc
  rate)` (B23)** — patch **0031** _(verified GONE on `#29` 2026-07-03)_: twl-core
  `clocks_init()` gated to the **twl4030 class**. The originally planned DTS fix
  (twl `fck = <&sys_clkin_ck>`) was investigated and **REJECTED as actively
  harmful**: on twl6030 the CFG_BOOT/PROTECT_KEY offsets resolve to unrelated
  Phoenix PM registers (absolute `0x24`/`0x2D`, next to PHOENIX_DEV_ON); no
  mainline twl6030 board wires an fck; stock printed the same line.
- **nq-healthd `led_frozen` permanent false CRIT** — patch **0029** _(verified on
  `#29` 2026-07-03: frame attr readable, fingerprint changes while animating,
  `led_sum=4416` sampled — but see the NEW static-by-design guard item under
  Known issues)_ makes the `leds-steelhead-avr` `frame` bin_attr **readable
  (0644)** — the system previously had NO readable ring-state source (nexusqd
  renders exclusively through the write-only `frame`, so the classdev
  `brightness` files stay 0) — and `nq-healthd` (r20) fingerprints the frame
  attr (md5 + byte sum), keeping the brightness loop only as a pre-0029
  fallback.
- **nq-healthd `vdd_mismatch` false warnings** (`device-google-steelhead` r20,
  _verified on `#29` 2026-07-03: no false vdd warnings in the acceptance
  capture_) — freq/vdd were sampled non-atomically, so a DVFS
  transition between the reads fabricated adjacent-OPP mismatches (17/71
  samples in the 2026-07-03 acceptance capture, healthy power path);
  `vdd_mismatch` is now evaluated only when `scaling_cur_freq` holds across the
  vdd read.
- **WiFi factory-MAC identity restored** _(verified on `#29` 2026-07-03:
  `f8:8f:ca:20:48:e1` on air, final IP **`192.168.20.195`** — closes the
  "open decision" from the acceptance run)_ — a live driver-reload test proved
  **brcmfmac/firmware IGNORES the nvram `macaddr=`** (the chip's OTP
  `14:7d:c5:3a:35:b5` always wins), so the fix is at the **NM layer**: the
  baked profile + `scripts/gen-wifi-profile.sh` now pin
  `cloned-mac-address=F8:8F:CA:20:48:E1`. After the flash the device appears
  under the factory MAC — new DHCP lease, the IP changes one final time from
  `192.168.20.175`.

### Changed
- **Default cpufreq governor back to `ondemand`** (+`CONFIG_CPU_FREQ_STAT=y` for
  `time_in_state`) — the v1.5.0 switch to `conservative` was deliberate but its
  rationale was disproven 2026-06-28. Verified on device 2026-07-03: governor
  `ondemand`, `time_in_state` present, 1200 MHz @ 1 380 000 µV under load /
  920 MHz @ 1 317 000 µV idle (exact OPP tracking).
- **NFC (PN544) node disabled in the DTS** — the chip was proven **electrically
  dead** on the reference unit (no i2c ACK at 0x28 with VEN high/low/fw-download,
  core-reset frame NAKed; pins/polarity/timing stock-verified MATCH first). Same
  dead-HW category as the TWL6040. Was "driver binds, chip untested".
  **RETRACTED 2026-07-03** (was "dead hardware", now **under investigation** —
  never conclude dead hardware): the stock-parity regulator audit closed the
  last software suspicion — stock has **NO software power path** for the PN544
  (pdata = 3 gpios only, `pn544_probe` makes zero regulator calls; VBAT/PVDD
  ride hardwired rails) and the full stock `steelhead_twldata` regulator array
  matches our live mainline regulator state bit-for-bit, so software parity is
  COMPLETE and the no-ACK is **unexplained**, not explained-as-dead. Next
  discriminator: NFC test on this unit under the stock RAM boot
  (`output/stock-adb-boot.img`), scheduled for the imminent flash cycle. Node
  stays disabled meanwhile; the DTS comment is rewritten accordingly. Evidence:
  `docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §4/§6.
  **RESOLVED 2026-07-03 — the stock RAM-boot test found it: the chip is
  HEALTHY, our pinmux was wrong** (dpm_emu pads instead of usbb2_ulpitll_dat).
  The node is **re-enabled** and NFC **works** — see the headline entry under
  Fixed.
- **TWL6040 was NEVER a "dead codec" — the chip is unused/unpopulated on
  steelhead** _(flashed + boot-verified on `#29` 2026-07-03)_: the stock 3.0.8 kernel contains
  **ZERO** twl6040/AUDPWRON code (whole-image string+symbol sweep over
  `reverse-eng/vmlinux.bin`), the twldata codec pdata slot is NULL
  (`steelhead_twldata+0x24` @ `0xc0719b30`), and stock's i2c1 board info
  registers only `twl6030@0x48` — the missing ACK at `0x4b` (the 2026-06-10
  "dead chip" verdict) is **stock-correct behaviour**. The twl6040 node, the
  ABE sound card and `twl6040_pins` are **DELETED** from the DTS (explanatory
  comment left in place; the removed node's `ti,audpwron-gpio` gpio_127 had no
  stock evidence either), and the defconfig drops `TWL6040_CORE` /
  `SND_SOC_TWL6040` / `SND_SOC_OMAP_ABE_TWL6040` / `CLK_TWL6040`. DTB compiled
  with zero twl6040 refs (verified in the binary).
- **i2c1–4 scl/sda pads `PIN_INPUT_PULLUP` → `PIN_INPUT`** _(flashed on `#29`
  2026-07-03)_ — stock-exact (mux `0x100`; the board has external pulls).
- `device-google-steelhead` depends + `i2c-tools`, `gptfdisk` (both needed for
  live diagnostics/GPT work).

### Known issues
- **2026-07-02 last-boot error inventory + 2026-07-03 acceptance**
  (`docs/2026-07-02-boot-error-inventory.md`): the dmesg/`journalctl -p err`
  sweep of the v1.6.5-era boot (`6.12.12 #26`) opened **B12–B21 / U4–U7**; the
  fix batch above was flash-verified 2026-07-03 on `#27`
  (B12/B13/B14/B15/B17/B18/B19/B20/U4 + B8 all confirmed gone). Opened by the
  acceptance run and **fixed by batch 2b — flashed + re-accepted on `#29`
  2026-07-03**: **B22** `twl: not initialized` ×22 burst @0.78 s (patch 0030 —
  count 0 on `#29`), **B23** `Skipping twl internal clock init…` (patch
  0031 — NOT the originally planned twl-fck DTS wiring, which proved harmful),
  the two **nq-healthd tooling bugs** (`led_frozen` false CRIT — patch 0029 +
  healthd r20 frame fingerprint; `vdd_mismatch` non-atomic sampling — healthd
  r20), and the **WiFi factory-MAC** identity (NM `cloned-mac-address` pin;
  brcmfmac ignores nvram `macaddr=`; on air on `#29`, final IP
  `192.168.20.195`). Still genuinely open: **U5** bluetoothd
  config error (did not reproduce on `#27`/`#29` — watching), BT BD_ADDR is the
  default-pattern `43:30:A0:00:00:00` (no per-device address); the PulseAudio
  **HDMI-audio UCM profile**, **U6** gkr-pam ssh-session noise, **U7**
  nsresourced bpf-lsm, **B16** ramoops invalid-buffer error (cold boot), **B21**
  minor L2C/gpmc/pmu/journald batch, **B4** (clm/txcap blobs + the
  `brcmfmac4330-sdio.google,steelhead.bin` probe miss), **B10** hw-breakpoint,
  deep cpuidle C2+ (HS secure dispatcher). **B8** (Alternate GPT invalid) is
  **FIXED on-device 2026-07-03** (p13 shrunk 33 sectors + backup GPT relocated,
  atomic `sgdisk`; survived the reboot — no "Alternate GPT" line on `#27`).
  Thermal headroom is thin under sustained dual-core
  load: peak **91.8 °C** vs the 100 °C passive trip (~8 °C) — genuine but
  expected; watch it.
  _(The morning claim "WiFi dead on the live unit" was **wrong** — the IP had
  moved due to the randomized-MAC DHCP lease; corrected same day.)_
- **Ethernet PARTIAL COMEBACK on `#29` (2026-07-03)** — `eth0` shows
  **carrier=1 / operstate up for the first time since the v1.4.0 regression**
  (task #17): `smsc95xx … eth0: Link is Up - 100Mbps/Full` @74.5 s — but the
  link **flaps** (Down within ~1 s, NM disconnect/connect loop) and DHCP never
  completes, making `NetworkManager-wait-online.service` the one failed unit
  of the boot. Likely one of the batch clock changes revived enumeration — a
  strong new lead for task #17. Open follow-ups: root-cause the flap; ship an
  eth0 NM profile with may-fail semantics so wait-online tolerates a
  flapping/cable-less port. _(RESOLVED 2026-07-04 — the flap was NM's
  auto-generated-profile DHCP retry loop, the link itself is healthy; see
  [Unreleased] and `docs/2026-07-04-ethernet-resolved-and-led-guard.md`.)_
- **`led_frozen` still needs a static-by-design guard** — the r20 frame
  fingerprint works, but the screensaver intentionally locks a **static**
  frame after ~300 s idle and the keepalive re-commits identical bytes, so
  `led_frozen` CRIT fires on a healthy idle device (the 2026-07-03 acceptance
  capture's verdict=CRIT was exactly this). Fix direction: only CRIT when
  `nq_resp=0` or `nexusqd_no_progress` co-fires (`nq-healthd` +
  `scripts/diag/nq-health-report`). Until then, expect this false positive on
  idle devices. _(SHIPPED 2026-07-04 exactly as described — healthd r21 +
  nq-health-report emit info `led_static` for a healthy static frame; see
  [Unreleased].)_

## [1.6.5] - 2026-07-01

> The whole batch below ships as a single release **v1.6.5**. An interim **v1.6.4** was
> built + flashed internally to test the LED-ring AVR keepalive but was **never published**;
> it was folded, with the librespot softvol fix + breathing themes + the visualisation
> picker, into v1.6.5. The 1.6.3 → 1.6.5 version-number gap is intentional.

Device-side fixes and companion features on the v1.6.3 image, verified on a **clean flash**:
the **LED ring no longer goes dark after a long idle** (AVR starvation), the **companion
bridge is now reachable over WiFi**, **librespot no longer crash-loops on a fresh boot**
(softvol bootstrap), color themes are now a **breathing** animation, and the **5 music
visualisations are selectable from the app**. `boot.img` is **byte-identical** to
v1.6.2/v1.6.3 (kernel unchanged; md5 `36a3dec2c4a493710dffa18c4d796236`), so an already
up-to-date device only needs the userdata reflash. Final pkgrels: `nexusqd` **r5**,
`nexusq-control` **r4**, `device-google-steelhead` **r17**. The companion APK is rebuilt +
reinstalled separately (not part of the device image). See
`docs/2026-07-01-led-ring-avr-starvation-keepalive.md` and
`docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.

### Fixed
- **librespot crash-loops on a fresh boot — "Could not find Alsa mixer control"
  (`device-google-steelhead` pkgrel 17).** The ALSA `NexusQ` **softvol** control
  (`asound.conf`) does not exist until the `nexusq_soft` PCM is first opened, and it is
  recreated empty every boot, but librespot opens its ALSA mixer control **before** the
  sink → it exits and `Restart=on-failure` respawns it into the same missing-control state
  forever (a reboot never helps). Fix: `librespot.service` gained
  `ExecStartPre=-/bin/sh -c 'timeout 5 aplay -q -D nexusq_soft -f cd -d 1 /dev/zero'`,
  which opens `nexusq_soft` once (1 s of silence) to create the control before librespot's
  mixer opens. Also fixes companion **volume** (the bridge's `amixer NexusQ set` needs the
  same control to exist).
- **LED ring goes dark after long idle — fixed with a 1 Hz AVR keepalive (`nexusqd`
  pkgrel 5; the keepalive itself landed at r3, later rels add `breathe`/`muted` below).**
  The `steelhead-avr` MCU firmware (fw `0x00`) **starves**: it stops lighting
  the ring if the host sends no frame *commit* for too long (a host-frame watchdog). The
  kernel driver `frame_write` (`kernel/drivers/leds-steelhead-avr.c`, sysfs
  `/sys/bus/i2c/devices/1-0020/frame`) sends `SET_RANGE` + `COMMIT` on **every** write, but
  `nexusqd`'s render loop pushed a frame only when it **changed** (a `memcmp(pk, lastpk)`
  gate). Once the idle screensaver locks to a **static** frame (`SS_LOCK_S = 300 s` →
  `ledAlpha` constant `0.1`, breathing stops) and blanks (`SS_BLANK_S = 600 s`), the frame
  stops changing → `memcmp` identical → `nexusqd` stops committing → the AVR starves → ring
  dark until `nexusqd` restarts (~20 h to manifest on the live unit). **Not** hardware
  (a direct sysfs write lights the ring), **not** a commit-mode issue (both
  `AVR_COMMIT_IMMEDIATE=0` and `AVR_COMMIT_INTERPOLATE=1` display fine at 1 write / 4 s),
  **not** a regression. Fix: a keepalive — re-commit the current frame every
  `AVR_KEEPALIVE_S = 1.0 s` even when unchanged. Adds nothing during animation (the frame
  already changes each tick); idle costs ~1 cheap 96-byte-payload i2c frame write/s.
  _(Caveat: mechanically deployed and running, but the "never wedges again" proof needs an
  overnight idle soak — the wedge took ~20 h.)_

### Added
- **Color themes are now a breathing override, not a solid fill** (`nexusqd` pkgrel 5,
  `nexusq-control` pkgrel 4). New `nexusqd` control command **`breathe R G B`**
  (`CTL_BREATHE`) drives the **compositor manual layer (priority 8)** with a new `breathe`
  flag: it pulses the ring in the theme hue using the **same throb envelope as the idle
  screensaver** (`screensaver_throb`, `A = 0.1 + 0.35*(1 - throb)`) but at priority 8 it is
  **always visible** — over the music visualizer and over a blanked/idle screensaver. This
  fixes "pick a color, ring stays dark" (the earlier screensaver-retint approach was
  invisible once the screensaver blanked or while music played, and was **reverted** —
  `screensaver.c/.h` no longer carry `br/bg/bb`/`screensaver_set_color`). A companion color
  theme now maps (in the bridge) to **just** `breathe R G B` (no `auto`). Theme set redefined
  to breathing hues: **blue** (`#0099CC`, the original) / **warm** (`#FF5A0A`) / **cool**
  (`#00C88C`) / **rose** (`#FF285A`) / **smoke** (`#6E7387`) / **off** (blank); the stale
  `spectrum`/`trackinfo` themes were dropped.
- **Five music visualisations selectable from the app** (`nexusq-control` pkgrel 4 +
  companion app). `nexusqd` already had `scene 0..4` (the 5 RenderEngine effects
  waveform / waveformsolid / circles / pointmorph / starfield, shown while audio plays);
  the bridge gained **`setScene` / `listScenes`** (maps a name → `auto` + `scene N`) and a
  `scene` field in `getState`, and the Flutter app gained a separate **VISUALIZATION**
  picker. A color theme (breathing override hue, priority 8) and a visualisation
  (music-reactive effect, priority 7) are now two **independent** controls.
- **App-mute now lights the device mute LED** (`nexusqd` pkgrel 5, `nexusq-control`
  pkgrel 4). New `nexusqd` command **`muted 0|1`** (`CTL_SETMUTED`) sets the mute state and
  calls the same `apply_mute_led()` (dim-teal `#001E28`/`#006B8E` AVR mute LED) the hardware
  mute key drives. The bridge's `setVolume`/`adjustVolume`/`setMuted`/`toggleMute` path now
  also sends `muted 0|1`, so a companion mute has a device-side ring indicator.
- **Companion bridge reachable over WiFi.** New nftables drop-in
  `pmos/device-google-steelhead/55_nexusq-control.nft` opens **TCP 45015 on `wlan*`** so the
  companion app reaches the `nexusq-control` bridge over WiFi (previously only over the
  USB-gadget net; it had been live-patched but not baked). mDNS `_nexusq._tcp` discovery
  reuses the UDP 5353 rule from `60_spotify.nft`. `device-google-steelhead` pkgrel 17.
  Verified live: `getState` returns the "Nexus Q" state over WiFi.

## [1.6.3] - 2026-06-30

A **companion app** and its on-device control bridge — a phone/desktop remote for the
Q (volume, LED theme + brightness, now-playing), replacing the dead 2012 Google
companion app. See `companion/` and `docs/2026-06-30-companion-app-RE.md`.

### Added
- **`nexusq-control` — a LAN control bridge** (new noarch aport `pmos/nexusq-control`).
  A pure-Python3 daemon on TCP **45015**, advertised over mDNS **`_nexusq._tcp`**,
  speaking a v1 JSON protocol (`companion/PROTOCOL.md`). It fans out to: ALSA softvol
  (volume/mute), `nexusqd` over `/run/nexusqd.sock` (LED theme + brightness), and a
  `librespot --onevent` hook (now-playing metadata). Enabled via the device package.
- **Software master volume.** `asound.conf` gains a `nexusq_soft` **softvol** PCM with a
  single ALSA control **`NexusQ`**, layered on top of the v1.6.2 audio tee
  (`nexusq_soft` → `nexusq` tee → TAS5713 speaker **and** the visualizer loopback). One
  knob is shared by librespot (`--mixer alsa --alsa-mixer-control NexusQ`) and the
  companion, so Spotify-Connect volume and companion volume stay in lockstep — and the
  LED visualizer still tracks the (post-volume) output.
- **`nexusqd brightness <0-255>`** control command + a software ring-brightness scalar
  (no firmware change).
- **Companion app** (`companion/app`) — a cross-platform Flutter remote (sphere UI,
  animated LED ring, mDNS auto-discovery; volume + LED theme/brightness + now-playing).
  Built and installed separately on the phone — **not** part of the device image.
- Reverse-engineering of the original Google Nexus Q companion app
  (`com.google.android.setupwarlock`) — its control-RPC vocabulary informed the v1
  protocol (`docs/2026-06-30-companion-app-RE.md`).

### Changed
- `librespot.service` now plays via `--device nexusq_soft --mixer alsa
  --alsa-mixer-control NexusQ --onevent /usr/bin/nexusq-onevent`.
- `device-google-steelhead` pkgrel 15 (`depends nexusq-control`; the bridge is
  enabled durably via a systemd **preset** `95-nexusq.preset` — the aport's
  `/usr/lib` vendor wants and a bare `/etc` symlink were both stripped by the
  image build's `systemctl preset-all` + postmarketOS's `disable *` catch-all).

### Known issues
- **Transport (play/pause/next) is `unavailable` in v1** — librespot is a
  Spotify-Connect receiver with no local transport API; control happens from the
  Spotify app.

## [1.6.2] - 2026-06-30

The **LED music visualizer** now reacts to Spotify playback. v1.6.1 routed
librespot straight to the speaker, so nexusqd's audio tap (the snd-aloop loopback)
got nothing and the ring stayed idle while music played.

### Fixed
- **LED visualizer is fed from playback (audio TEE).** The `nexusq` ALSA PCM is now
  a tee (`multi` + `route`) that duplicates librespot's stereo to BOTH the TAS5713
  speaker AND the snd-aloop loopback (`hw:Loopback,0`), all at 48 kHz. nexusqd's
  existing tap (`arecord` on `hw:Loopback,1` @ 48 kHz, `userspace/nexusqd`) drives
  the FFT/beat visualizer while the speaker plays. The speaker is the timing
  master; the loopback slave is `plughw`, so it adapts to whatever rate the cable
  is at (nexusqd's arecord may have set it) and never blocks playback — verified:
  the tee opens whether the tone-playback or nexusqd's arecord grabs the loopback
  first, and the tone reaches `hw:Loopback,1` at 48 kHz.

### Added
- **snd-aloop auto-loaded.** New `/etc/modules-load.d/snd-aloop.conf` (the kernel
  ships `CONFIG_SND_ALOOP=m`); without it the `Loopback` card doesn't exist and the
  visualizer tap can't open. `device-google-steelhead` pkgrel 12.

### Known issues
- The Spotify Connect session can briefly go "inactive" on the first play and
  reconnect (librespot "context is not available" — a single-track-vs-playlist
  context quirk; no ALSA error); playback is stable afterwards.

## [1.6.1] - 2026-06-29

Working **TAS5713 speaker audio** and **Spotify Connect**, baked into the build. The
v1.6.0 speaker path played exactly 2× too fast (root-caused and fixed here);
`librespot` is now part of the image, so the Spotify "Nexus Q" target survives a
flash. See `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.

### Fixed
- **TAS5713 amplifier played EXACTLY 2× too fast — fixed (kernel patch 0022).**
  Root cause: with `simple-audio-card` driving the McBSP2 → TAS5713 I2S link in
  bit/frame-master mode, the generic card only sets `mclk-fs` and never calls
  `snd_soc_dai_set_clkdiv()`, so `omap-mcbsp` left `CLKGDV = 0` (bit clock = the
  *undivided* 24.576 MHz functional clock) and sized the frame as `in_freq/rate =
  256` BCLK → **FSYNC = 96 kHz for a 48 kHz stream = 2× too fast**. Tracks reached
  their end in half the real time, so librespot auto-skipped ~40 s in. Fix:
  `kernel/patches/0022-ASoC-omap-mcbsp-derive-CLKGDV-from-fclk-simple-card.patch`
  derives `CLKGDV` from the real functional-clock rate (`mcbsp->fclk`) and uses a
  minimal `wlen*channels` I2S frame when the machine driver supplied no explicit
  divider — reproducing the factory kernel's registers exactly (CLKGDV = 15, BCLK
  1.536 MHz, 32-BCLK frame, FSYNC 48 kHz). **Verified on hardware:** 60 s of audio
  to the speaker now plays in **60.00 s (ratio 1.000×)** — was ~30 s (0.50×). Method
  was pure timing (no speaker needed). Cross-checked against `reverse-eng/vmlinux.bin`
  (stock-parity audit). The earlier "B7 TAS5713 MCLK 16 vs 12.288 MHz" concern is a
  red herring for this bug — the mainline `tas571x` codec has no `.set_sysclk`, so
  MCLK never gates FSYNC.

### Added
- **Spotify Connect (librespot) baked into the build.** `device-google-steelhead`
  now `depends` on `librespot` (Alpine edge/testing, 0.8.0, `libmdns` zeroconf
  backend — coexists with `avahi-daemon` on UDP 5353 via `SO_REUSEPORT`) and ships:
  - `/etc/systemd/system/librespot.service` (enabled) — `librespot --name "Nexus Q"
    --device nexusq --bitrate 320 --format S16 --ap-port 443 --zeroconf-port 37879
    --cache /var/cache/librespot`.
  - `/etc/asound.conf` — defines the `nexusq` PCM (`plug` → `hw:CARD=NexusQSpeaker,0`
    forced to **48000 Hz**). The McBSP2/TAS5713 link only clocks the 48 kHz family
    cleanly, so 44.1 kHz Spotify is resampled to 48 k; with patch 0022 that is an
    exact 48 kHz (correct pitch).
  - `/etc/nftables.d/60_spotify.nft` — opens `wlan*` UDP 5353 (mDNS) + TCP 37879
    (zeroconf HTTP) so the phone can discover "Nexus Q".
  Discovery + auth + streaming verified over 5 GHz WiFi; `--ap-port 443` dodges
  VLAN20 blocking librespot's default AP port 4070.

### Changed
- **Audio is addressed by card NAME, not number.** The TAS5713 speaker and HDMI race
  for card 0/1 across boots, so `asound.conf`/librespot use `hw:CARD=NexusQSpeaker,0`
  (via the `nexusq` PCM) — a hardcoded `plughw:1,0` would have played into HDMI after
  an unlucky reboot.
- **TAS5713 25 W speaker amp: now working** (was "software-verified, listening test
  pending"). First fully verified speaker playback.

## [1.6.0] - 2026-06-28

First release with a **working `python3` on the device**, hardware-verified from a
clean flash. Over 1.5.0: a working armv7 python3 — the actual fix was the
`raw2simg.py` byte-exact (all-RAW) flash; the on-device SIGSEGV was a flash bug, not
a build bug (a local `python3` rebuild supersedes Alpine's broken `-r2`, with a
build-integrity gate + ship gate kept as a safety net) — plus zram compressed swap,
user namespaces, on-device `gdb`/`python3-dbg`, and a live re-confirmation of
dual-core SMP + cpufreq-to-1.2 GHz power/thermal.

### Added
- **zram compressed swap.** Kernel `CONFIG_ZRAM=m` plus
  `deviceinfo_zram_swap_algo="lzo-rle"` brings up `postmarketos-zram-swap`. The
  mainline ZRAM module here only carries the lzo/lzo-rle backend, so the service's
  default **zstd** failed (`zramctl: failed to set algorithm: Invalid argument`)
  and swap never came up; lzo-rle is also the CPU-cheap pick for this Cortex-A9.
  Verified live: `/dev/zram0` lzo-rle, 1.4 G, active `[SWAP]`. (linux APKBUILD
  pkgrel 23→24.)
- **User namespaces** — `CONFIG_USER_NS=y`. Verified live:
  `max_user_namespaces=7716`, `unshare --user` works.
- **Dual-core SMP re-confirmed on the full-rootfs image** — `nproc=2`,
  `cpu/online=0-1`, both Cortex-A9 in `/proc/cpuinfo`. (SMP shipped in 1.2.0; this
  corrects any stale "CPU1 not brought up / SMP is groundwork" framing — it is done
  and working on the current image.)
- **CPU power/thermal health confirmed live** — scales 350/700/920/1200 MHz,
  reaches 1.2 GHz under load, VDD_MPU tracks the OPP exactly (1200→1380, 920→1317,
  350→1025 mV; abb_mpu FBB@Nitro 1375 mV). Idle ~70 °C, peak 95 °C under sustained
  2-core load (no throttle; 100 °C passive trip not reached).

### Changed
- **Build infra: local `python3` override aport + gated Phase 7d.**
  `docker-build.sh` stages `pmos/python3/` → `main/python3` (Phase 6) and builds it
  (`pmbootstrap --no-cross build python3 --arch armv7`, Phase 7d) so a higher pkgrel
  (now r5) supersedes Alpine's broken `python3-3.14.5-r2` in the rootfs. The override
  drops `--with-lto` + `--enable-optimizations` and the `!gettext-dev` makedepends
  token (pmbootstrap's apk wrapper rejects `!` entries), keeps stock `-O2` and the
  **default linker (bfd)**. Phase 7d gates every built libpython with
  `scripts/verify-libpython-clean.py` and rebuilds on residual corruption (pkgrel-exact
  apk selection, no stale-apk glob); Phase 10 re-gates the installed rootfs libpython
  before emitting an image — a build-integrity safety net (the on-device crash was a
  flash bug, see Fixed; this only guarantees the build feeding the flash is clean).
- **`device-google-steelhead` no longer masks `sleep-inhibitor.service`; adds
  on-device debug tools.** The `/dev/null` mask was removed in favour of fixing the
  root cause (the python crash, now fixed below); the image also ships `gdb` (16.3) +
  `python3-dbg` (used to coredump-debug the crash on hardware; gdb links `libpython`,
  so it works once python links a clean libpython). (device APKBUILD pkgrel 6→10.)

### Fixed
- **Flash: the rootfs sparse image is now byte-exact (all-RAW, no `DONT_CARE`).**
  `raw2simg.py` (raw ext4 → Android sparse for the 2012 U-Boot fastboot, which lacks
  FILL-chunk support) used to emit every all-zero 4 KiB block as a `DONT_CARE` chunk to
  shrink the image — but fastboot **skips** `DONT_CARE` blocks, which is only correct
  on a **pre-erased** partition. The Nexus Q's U-Boot does **not** erase `userdata`, so
  each skipped block kept STALE data from the previous flash, re-corrupting on-device
  file zero-regions — specifically libpython's `.PyRuntime` / `.data.rel.ro` (PROGBITS,
  read during `Py_Initialize`) — which was **the actual and only root cause of the
  on-device armv7 python SIGSEGV (rc 139)**, even though the flashed (and built) image
  was provably clean. Forensic signature distinguishing flash- from build-corruption:
  the on-device libpython differed from the (gate-CLEAN) flashed image in **exactly 47**
  4 KiB blocks, **all** "image-zero → device-garbage", 0 other
  (`.PyRuntime longest_run 30652`); the image gated CLEAN, the device gated CORRUPT, and
  `scp`-ing the clean image libpython over the device's → `python3 -S -c ''` rc 0
  instantly — proof it was the flash, not the build. **Fix:** `raw2simg.py` now encodes
  **every** block as RAW (no `DONT_CARE`), so the flash is byte-exact regardless of prior
  eMMC content (sparse ≈ raw size; correctness over compression). Verified by a de-sparse
  round-trip (md5 of de-sparsed == raw image) **and** on hardware: a fresh flash (no
  live-patch) of a default-linker (bfd) build gives `/usr/lib/libpython3.14.so.1.0` md5
  `79a0d4ace1358bb2d94c8a4d72479da9`, `SYSPY_OK 3.14.5 … [GCC 15.2.0]`, `SYS_PY_RC=0`.
  Lesson: integrity-verify what the **device** runs, not just the built artifact. See
  `docs/2026-06-28-session-findings.md`.
- **armv7 `python3` works on the device — the on-device SIGSEGV was the FLASH bug
  above, not a build bug.** Alpine's `python3-3.14.5-r2` SIGSEGVed deterministically on
  the Cortex-A9 (`python3 -S -c ''` → rc 139 during `Py_Initialize`), taking down
  `onboard`, `blueman-applet`, `sleep-inhibitor.service` and `gdb` (it links
  `libpython`). The **single root cause** was the `raw2simg.py` `DONT_CARE` flash bug
  (above): a re-flash over non-erased eMMC left stale garbage in libpython's
  should-be-zero `.PyRuntime` / `.data.rel.ro`, landing on
  `interp->types.builtins.num_initialized` (read back as `0xf0012b00`) → wild
  type-index deref → SIGSEGV. v1.6.0 ships a local `pmos/python3/` override (same 3.14.5
  at a higher pkgrel, **r5**, **default linker / bfd**) so it supersedes Alpine's `-r2`;
  the override drops `--with-lto` + `--enable-optimizations` and the `!gettext-dev`
  makedepends token, keeps stock `-O2`. **A qemu-user "linker mmap zero-fill corrupts
  the build" theory and a gold-linker workaround (`-fuse-ld=gold
  -Wl,--no-mmap-output-file`, `binutils-gold` makedep) were investigated and DROPPED as
  unnecessary** — the build was never reproducibly corrupt: 6 independent default-linker
  builds were all integrity-gate-clean, and a bfd build (gold-note absent, libpython md5
  `79a0d4ace1358bb2d94c8a4d72479da9`), flashed via the corrected all-RAW `raw2simg`, ran
  `python3 -S -c ''` rc 0 on the real device (6/6 clean would be ~1.6 % if a real 50 %
  build coin-flip existed). Retained — **not** as a "gold fix" but as a cheap
  **build-integrity safety net** that catches zero-region corruption from any source:
  `scripts/verify-libpython-clean.py` (flags long non-zero runs in those zero-regions;
  clean ≤52 B, corrupt ≥22000 B, threshold 256), run in a Phase-7d gate+retry loop and
  again as a Phase-10 ship gate, with pkgrel-exact apk selection. Other early suspects
  also disproven: LTO/PGO, LDREXD alignment, gnu2/TLSDESC, optimization level. The
  all-RAW flash fix above is what actually fixed the device; the gate only guarantees the
  build feeding it is clean. See `docs/2026-06-28-session-findings.md`.
- **Build-pipeline: rootfs python ≠ the verified apk — fixed.** Phase 7d's old bare
  `python3-3.14.5-r*.apk` glob could match a *stale* apk in the persistent work-volume
  repo rather than the one just built, so the rootfs could install a different build than
  the one gated. Fixed by selecting the **exact `pkgver-pkgrel`** apk, gating that file,
  and re-gating the **installed** rootfs libpython at ship time (the version-only check
  that green-lit a mismatch is gone). _(The apparent "two r4 builds, one crashes / one
  runs" that first surfaced this was almost certainly a post-flash device pull — the
  flash bug above — misread as build corruption, not a real build coin-flip.)_

### Known issues / in progress
- **On-board LAN9500A Ethernet still down** — the v1.4.0 cpufreq boot-timing
  regression is unchanged: `smsc95xx` registers but the device never enumerates, no
  `eth0`. Use WiFi / the USB gadget. (Fix tracked for 1.4.1.)

## [1.5.0] - 2026-06-27

### Added
- **NFC: the PN544 stack is built into the kernel** (NFC / HCI / PN544 / PN544_I2C
  `=y`) with stock-faithful tweaks — a 20 ms VEN settle and a level-triggered IRQ.
  The chip is proven alive (it ACKs i2c when powered); full NFC functionality is a
  follow-up.
- **Nexus Q diagnostics suite.** `nq-healthd` continuously watches the things that
  silently fail in the field (LED-ring / nexusqd hangs, VDD_MPU-vs-OPP drift,
  thermal throttle, kernel errors) and logs to `/var/log/nq-health`;
  `nq-diag-snapshot` captures a full one-shot device snapshot. Both ship enabled in
  the device image, with host-side helpers (`scripts/diag/`) and a `nexusq-diag`
  skill to collect and analyse it over the best available link.
- **nexusqd** now signals systemd readiness + watchdog via `sd_notify`
  (self-contained, no libsystemd dependency), so the LED-ring daemon runs as a
  proper `Type=notify` unit.
- **SSH out of the box** — the device image now ships `openssh` (server + client),
  so the Nexus Q is reachable over the network and the USB gadget without any
  manual install.
- **Composite USB gadget** — a deterministic RNDIS network (`172.16.42.1`) **plus**
  an ACM serial console, bound every boot from configfs. This is the reliable
  fallback link when the on-board ethernet is down, and replaces the old, fragile
  RNDIS→ACM swap that could leave the gadget unbound (no net and no console).

### Changed
- **DTS regulators now point at the real board rails** — DSS `vdda_video`→vcxio,
  tmp101 `vs`→v1v8, the Bluetooth `vbat`/`vddio`, and the TAS5713 amp `AVDD`/`DVDD`→a
  3V3 rail replace placeholder dummies. The spurious "supplying voltage" warnings
  drop from 10 to 5.
- **Default cpufreq governor → `conservative`** (vs `ondemand`). _(Correction
  2026-06-28: this entry's claim that idle "settles at 350 MHz" is not what the
  live device does — idle actually hovers ~920 MHz because `nexusqd`'s LED-ring
  polling keeps the CPU busy, dipping to 350 MHz only briefly. ~70 °C idle. See
  `docs/2026-06-28-session-findings.md`.)_
- **Ethernet (LAN9500A) is reliable again** — it came up on every boot tested in
  v1.5.0 (the v1.4.0 cpufreq-build bring-up intermittency was not reproducible),
  sustaining full ~100 Mbit/s line-rate throughput.
- **Device image UI:** added `nm-tray` (network applet), `blueman` (Bluetooth
  manager) and `breeze-icons` to the LXQt-Wayland session.

### Fixed
- **WiFi: the BCM4330 radio no longer sleeps when idle.** brcmfmac forced the
  firmware `mpc` (Minimum Power Consumption) iovar on, powering the radio down
  between packets — ~30 % packet loss and 270–530 ms latency. A new brcmfmac `mpc`
  module parameter plus a device modprobe.d conf (`mpc=0`) keep it awake (the
  Nexus Q is mains-powered): loss 30 %→0 %, latency 270–530 ms→4–59 ms. Stock-proven
  to be a driver gap — the same firmware + nvram works under the vendor `bcmdhd`.
- **WiFi: disabled brcmfmac P2P** on the BCM4330 — the firmware advertises P2P but
  cannot create the P2P_DEVICE interface, which spammed the log with failed p2p-dev
  creations and orphaned "event handler failed (72)" errors.
- **boot: silenced the benign ti-sysc active-timer `-EBUSY`** probe error for
  GPTIMER1 (an always-on system clockevent owned by the timer core).
- **boot: the systemd rootfs no longer drops to emergency mode.** pmbootstrap
  generated an `/etc/fstab` with a `/boot` entry for a separate boot partition that
  this single-partition (root-only) flash layout does not have; systemd failed that
  mount → `emergency.target`, and `root` was locked so the console was unusable. The
  image build now strips the `/boot` fstab line and unlocks `root`.
- **the device image now actually ships systemd** (explicit
  `deviceinfo_systemd="always"`). Without the opt-in pmbootstrap defaulted to
  OpenRC, silently dropping the entire systemd device integration — nexusqd,
  nq-healthd and the USB-gadget units never ran.

### Known issues
- **WiFi 2.4 GHz bulk throughput** is limited by Bluetooth coexistence (the BCM4330
  combo shares one 2.4 GHz antenna) on a g-only AP — **use 5 GHz for full speed**
  (~26–30 Mbit/s, 802.11n). See
  `docs/2026-06-26-wifi-mpc-fix-and-bulk-bufferbloat.md`.

## [1.4.0] - 2026-06-26

### Added
- **MPU CPU frequency scaling — on-demand up to 1.2 GHz (3.4× the old floor).** 🚀
  The OMAP4460 was pinned at its 350 MHz boot OPP; it now scales across
  350 / 700 / 920 / 1200 MHz under the `ondemand` governor. Built up in small,
  hardware-validated stages, each cross-checked against this unit's
  reverse-engineered stock kernel:
  - VDD_MPU is handed from the TWL6030 VCORE1 SMPS to the external **TPS62361**
    regulator over the PRM Voltage-Controller SR-i2c — the same hand-over stock does.
  - A thin "VC-bridge" `cpu-supply` regulator lets `cpufreq-dt` scale the rail
    through the OMAP voltage layer (VP force-update), at the stock-measured nominal
    voltages (1025 / 1203 / 1317 / 1380 mV).
  - At the 1.2 GHz OPP, **Forward Body Bias** is engaged on VDD_MPU via the on-chip
    ABB LDO — required for stable 1.2 GHz operation.
  - **Thermal throttling**: at the 100 °C trip the CPU cooling drops the frequency
    and ramps it back as it cools, so sustained full load stays safe.
- **USB serial debug console.** The USB gadget is now an ACM serial console
  (`/dev/ttyACM0` on the host, with a `steelhead login:` prompt) that survives
  reboots and leaves fastboot untouched.

### Changed
- The USB gadget no longer exposes a host-side network interface — it was swapped
  from the RNDIS network gadget to the serial console above. Use the on-board
  ethernet / WiFi for networking.

### Known issues
- **On-board LAN9500A USB-Ethernet is down — a regression from 1.3.0.** 🌐 The
  Ethernet that 1.3.0 fixed no longer enumerates on these cpufreq builds: the
  LAN9500A fails to connect (the EHCI port's `PORTSC` connect-status stays 0). It
  is a boot-timing side-effect of the voltage/cpufreq changes, which tipped the
  formerly-marginal connect timing into consistent failure. WiFi works in the
  meantime; a fix (a settle delay in the ethernet bring-up, or reordering the
  voltage init) is tracked for 1.4.1.

## [1.3.0] - 2026-06-24

### Fixed
- **On-board LAN9500A USB-Ethernet now works on mainline 6.12** 🌐 — the
  long-standing "intermittent / never enumerates" problem is **resolved**. The
  chip enumerates on every boot (`0424:9e00` → `smsc95xx … eth0`), the link comes
  up at 100 Mbps/Full and passes traffic cleanly. Verified on hardware: 5/5
  reboots all enumerate, 600 sustained pings at **0 % loss**, 410 MB moved with
  **zero** rx/tx/CRC/drop errors. Root cause was two combined bugs, both found by
  stock-parity auditing against the factory Android kernel:
  - **Patch 0012** (`mfd: omap-usb-host`): mainline only enables the per-port
    UTMI functional clock (`usb_host_hs_utmi_pN_clk` — the L3INIT CLKCTRL
    OPTFCLKEN gate) for **TLL/HSIC** port modes. An external-PHY (`ehci-phy`)
    port falls through to `default:` and never gets its clock, so the port-1 UTMI
    link block ran unclocked (`clk_summary` showed it disabled) and the
    controller never latched the downstream connect (PORTSC CCS stuck 0). Added
    `OMAP_EHCI_PORT_MODE_PHY` to the clock enable/disable paths.
  - **Patch 0006** (`usb: ehci-omap`): stock's `omap_ehci_soft_phy_reset` (the
    UHH softreset / gpio pulse / clock re-park / ULPI register burst) is **not**
    the EHCI `.reset` hook — it is a runtime `ehci_hub_control` *recovery*
    handler that only fires when a port reset/resume times out, **after** a
    device has connected. We were running that whole sequence at bring-up, which
    blocked the very first connect. The `.reset` hook is now a plain
    `ehci_setup()` bring-up (the USB3320's reset defaults already put it in host
    mode); the ULPI/UHH recovery helpers are retained for a future hub_control
    hook.

### Changed
- All kernel patch headers now carry `petronijus@bastla.com` (was a work email /
  placeholder).

## [1.2.0] - 2026-06-23

### Added
- **Second CPU core (dual-core SMP) now works** 🧠 — the OMAP4460 ES1.1 **HS**
  ("steelhead") had always silently dead-locked with `CONFIG_SMP=y`. Two changes:
  - Kernel patch `0009-ARM-OMAP4-steelhead-SEV-in-prepare-wake-cpu1` — stock
    issues a `dsb_sev()` at the end of `omap4_smp_prepare_cpus` after writing
    `AUX_CORE_BOOT_1`; mainline omitted it, so CPU1 (parked in the ROM WFE
    holding pen) never re-read the boot address. Adding the SEV releases it.
  - `cpuidle.off=1` on the cmdline (stock = `cpuidle44xx.disallow_smp_idle`) —
    OMAP4 secondary deep-idle faults → "Attempted to kill the idle task" panic
    on `swapper/1`. Disabling cpuidle keeps SMP stable.
  - `CONFIG_SMP=y`, `CONFIG_NR_CPUS=2`, `CONFIG_HOTPLUG_CPU=y`, `cpu@1` restored
    in the DTS. **Verified on hardware**: both cores online (`nproc` = 2), load
    spreads across CPUs, idle desktop ~70 % idle (the second core absorbs the
    software-rendered compositor that saturated single-core).
  - Kernel switched to **LZMA** compression to keep the now-larger SMP image
    under the ~6.6 MB U-Boot boot-partition ceiling.
- **HDMI EDID now reads + the desktop is visible.** DDC pads
  (`hdmi_scl 0x09c` / `hdmi_sda 0x09e`) changed from `PIN_INPUT_PULLUP` to
  `PIN_INPUT` — the forced internal pull-up fought the board's external DDC
  pull-ups and corrupted the I²C, so EDID never read. Then patch
  `0010-drm-omapdrm-hdmi4-cap-pixel-clock-steelhead` adds `.mode_valid` to the
  hdmi4 bridge capping the pixel clock at 75 MHz: the wlroots compositor was
  selecting the monitor's native 1440×900 @ 106.5 MHz (which the OMAP4 HDMI PLL
  can't generate → blank), and `video=` only constrains fbcon, not the
  compositor. With the cap, wlroots picks **1280×720 @ 60 Hz** and the
  LXQt-Wayland desktop renders. **Verified on hardware.** Native 1440×900 is a
  follow-up (omapdrm PLL).
- **Rotary volume + mute keys work again** 🎛️ — patch
  `0011-leds-steelhead-avr-drain-key-fifo-at-probe`. The `steelhead-avr` keys
  were dead: the AVR holds INT low while its KEY_FIFO is non-empty, the driver
  requests an `IRQF_TRIGGER_FALLING` irq, so a FIFO with stale entries at probe
  left INT already-low → no falling edge → the irq never fired → the FIFO was
  never drained (a latent driver bug; "worked sometimes" = a boot that probed
  with an empty FIFO). Draining the FIFO in probe releases INT and arms the edge.
  **Verified on hardware**: the IRQ fires (0 → 118), `KEY_VOLUMEUP/DOWN` stream as
  you rotate the dome, and the LED ring (driven by `nexusqd`) responds again. The
  AVR was detecting keys all along — confirmed by reading its KEY_FIFO directly
  over i²c. (Mapping the keys to actual audio volume + fixing the
  pulseaudio/wireplumber audio stack is a remaining userspace follow-up.)

### Changed
- **WiFi (BCM4330) power-save disabled by default** — NetworkManager drop-in
  `wifi.powersave = 2` shipped by the device package. Fixes severe latency jitter
  (ping avg ~175 ms, spikes 545–660 ms → stable ~15 ms). Bulk throughput is a
  separate firmware limitation, untouched.

### Added (ethernet, partial)
- Kernel patch `0006` gains stock's **1 ms `udelay(1000)` ULPI pre-reset settle**
  in `omap_ehci_soft_phy_reset` (stock VA `0xc0329ba4`). Real stock parity, but
  not sufficient to make LAN9500A enumeration deterministic — see Known issues.

### Tooling / docs
- `scripts/build-kernel-boot.sh` — fast docker kernel-only rebuild + boot.img
  repack reusing the warm `nexusq-workdir` volume (skips the rootfs).
- Comprehensive writeups: `docs/SMP-second-core.md`,
  `docs/2026-06-22-smp-session-findings.md`, `docs/ethernet-bringup-procedure.md`,
  `docs/2026-06-23-session-findings.md`,
  `docs/2026-06-23-ethernet-continuation.md`.
- `reverse-eng/` ground-truth: stock 3.0.8 SMP `vmlinux.bin` extracted for the
  stock-parity-auditor (gitignored; recreation in `reverse-eng/README.md`).

## [1.1.0] - 2026-06-22

### Added
- **Ethernet (LAN9500A) now works** 🎉 — the soldered on-board SMSC LAN9500A
  USB-ethernet enumerates and carries traffic. Two kernel changes did it:
  - `0006-usb-ehci-omap-steelhead-keep-ethernet-port-alive-ulp` — steelhead
    host-init in `ehci-omap`: INSNREG01 burst thresholds, a ULPI Function-Control
    soft reset of the USB3320 PHY *before* `usb_add_hcd()`, and
    `usb_disable_autosuspend()` on the root hub so the idle port is not
    clock-gated away.
  - `0008-mfd-omap-usb-host-steelhead-UHH-HOSTCONFIG-connect` — program
    `UHH_HOSTCONFIG` to the vendor's `0x11c` (set `P1_CONNECT_STATUS`, leave
    `APP_START_CLK` clear) so the EHCI latches the port-1 connect. Measured
    mainline default was `0x1c`; the stock Android 3.0 kernel uses `0x11c`.

  The long-standing "ethernet is dead hardware" verdict was **wrong** — the stock
  kernel enumerates the same chip on this unit, proving the HW is fine and the bug
  was ours. **Verified on hardware** (#8 kernel): `eth0` (`0424:9e00` → `smsc95xx`)
  links at 100 Mbps/Full and passes bidirectional traffic — 0% packet loss over a
  direct cable, zero rx/tx/CRC/frame errors after ~660 MB moved. Throughput
  ~30–60 Mbps (USB2 / single-core OMAP4 bound, not a link fault). Reach the device
  over ethernet with the persistent `eth-direct` NetworkManager profile
  (static `10.42.0.2/24`).
- Kernel patch `0007-clk-ti-composite-implement-divider-round-set-rate` — OMAP4
  `ti,composite-clock` nodes (gate + divider) had stub `round_rate`/`set_rate`
  returning `-EINVAL`, so any `clk_set_rate()` on them failed. Delegated both to
  `ti_clk_divider_ops` (as `recalc_rate` already did). Fixes the TAS5713
  amplifier MCLK: `dpll_per_m3x2_ck` now sets to 61.44 MHz →
  `auxclk1_ck` = 12.288 MHz (256 × 48 kHz). **Verified on hardware** (#4 kernel):
  clock rates correct, ALSA card 0 `NexusQ-Speaker` registers cleanly, no
  `couldn't set dpll_per_m3x2_ck` error.
- `CONFIG_SRAM=y` in the defconfig (OMAP4 on-chip SRAM driver).
- Tooling: `scripts/regen-dts-patch.sh` (regenerate patch 0003 from the working
  DTS) and `scripts/extract-and-repack.sh` (pull kernel+DTB from the build
  chroot pkgdir and repack a partition-sized boot image — a fast path that skips
  the rootfs build).
- **Build fix:** the recurring `abuild create_apks` "Permission denied" on
  `/home/pmos/packages//pmos/armv7/...apk` is fixed. On a reused `nexusq-workdir`
  volume `$WORK/packages` was owned by the container `pmos` (uid 1000) while
  abuild inside the chroot runs as uid 12345, so it could not write its `.apk`.
  `docker-build.sh` Phase 7a now `chown`s `$WORK/packages` to 12345 before the
  build, so `linux-google-steelhead-*.apk` is created cleanly and `pmbootstrap
  install` runs. `extract-and-repack.sh` is kept as a fast path, no longer a
  required workaround.
- **Build fix:** clearing the armv7 ccache out-of-band leaves its directory owned
  by uid 1000, so abuild inside the chroot (uid 12345) then hits `ccache: error:
  Permission denied` at `make olddefconfig`. `docker-build.sh` Phase 7a now also
  `chown`s `$WORK/cache_ccache_armv7` to 12345 (alongside `$WORK/packages`).

### Changed
- DTS: delete the upstream `cpu@1` node to match the single-core build
  (`CONFIG_SMP=n`). Clears the early-DT `nodes greater than max cores 1` warning
  and the resulting kernel taint (was 512, now 0). Re-add together with the
  deferred OMAP4460 SMP / CPU1 bring-up. Patch 0003 regenerated accordingly.
- Device root password is now read at runtime from a gitignored `.nexus_pw`
  (no hard-coded credential in the SSH/flash helpers).

### Known limitations
- Rootfs image build (`pmbootstrap install`, Phase 9) currently fails on a
  `device-google-steelhead` post-install step (exit 127); the kernel `.apk` and
  boot image build fine, so kernel/DTB iteration is unaffected. Reflash boot only.

## [0.1.0] - 2026-06-10

First public milestone — **postmarketOS userspace boots on the Nexus Q**.

### Working
- Mainline Linux 6.12 LTS boots on TI OMAP4460 (`steelhead`); postmarketOS
  (systemd) comes up from the userdata partition.
- SSH access over USB gadget and over WiFi (BCM4330, original calibration).
- Audio amplifier path (TAS5713) and BT auto-firmware load; sensors.
- HDMI framebuffer console, eMMC + all partitions detected.
- Device tree, defconfig and kernel patches under `kernel/`; pmbootstrap build
  pipeline (`docker-build.sh`) and flashing helpers (`build-and-flash.sh`).
- Release images: `nexusq-boot-v0.1.0.img` + `nexusq-rootfs-v0.1.0-sparse.img`
  (see `INSTALL.md`).

### Known limitations
- Single-core only (SMP disabled due to a U-Boot bug).
- Ethernet is dead hardware on this unit.
- TAS5713 amplifier bring-up is the next roadmap item (`PLAN.md`).

See `HANDOFF.md` for technical notes and root-cause analysis.
