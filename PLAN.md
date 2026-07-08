# Nexus Q Reloaded -- Hardware Status & Plan

Status as of **2026-06-10** (after the boot/WiFi debugging session, see
HANDOFF.md "Session 2026-06-10" for root causes and access paths).

> **2026-07-08 — v1.7.0 (tagged release): NFC TAP-TO-SEND.** Tap a phone on the
> dome → the Q pushes a short text over NFC, shown in the companion app. Uses
> **reverse-HCE** (the 2011 PN544 can't host-card-emulate and Android Beam is gone,
> so the phone runs a HostApduService and the **Q is the ISO-DEP reader**). Enabler:
> kernel **patch 0037** — the pn544 driver now RATS-activates **any** ISO-DEP target
> (was Mifare-DESFire-only), so a modern Android HCE phone (ATQA 0x0004 / SAK 0x20)
> is reachable. Device `nexusq-nfc-send` daemon (owns `nfc0`, neard not installed) +
> companion native HCE. v1.7.0 also bundles the built-but-untagged work since
> v1.6.10 (PA-centric audio v1.6.14–16, volume dial → PA, ethernet-default,
> companion auto-reconnect). Package state: `device-google-steelhead` **r33**,
> `linux` **r37**, `nexusqd` **r7**, `nexusq-control` **r7**. VERIFIED on device.
> See `docs/2026-07-08-nfc-tap-to-send-reverse-hce.md`.
>
> **2026-07-06 — v1.6.10: THE BOOT LOG IS GENUINELY CLEAN (PUBLIC release in
> progress, no tag from here).** v1.6.9 still booted with **~15 err/warn lines**;
> v1.6.10 closes **all** of them — every one root-caused + fixed with a real fix,
> plus two authorized exceptional downgrades and two honestly-documented external
> lines. **Acceptance (clean flash, device `r28` / kernel pkgrel `35` / uname
> `#36`): `dmesg -l err,warn` EMPTY; `journalctl -b -p warning` = ONLY 3
> genuinely-external residuals.** Kernel patches **0033–0036** (brcmfmac
> nowarn-clm, drop HW_BREAKPOINT arch-select, L2C→pr_debug downgrade, btbcm
> 43:30:A0 BD_ADDR), defconfig **BPF** (`BPF_SYSCALL`/`BPF_JIT`/`CGROUP_BPF`) +
> `EXT4_FS_POSIX_ACL` + `SYN_COOKIES`, DTS `&pmu interrupt-affinity` / `&gpmc
> disabled` / `local-bd-address`, device pkg r22→r28 (PA autospawn off, dns-filter
> lo-guard, bluetooth confdir 0755, librespot readiness gate, bluetoothd
> `main.conf [LE]`, nsresourced disabled), new `firmware-google-steelhead` (r1,
> board-named brcmfmac symlinks). boot.img +~0.3 MB (BPF) → still < 8 MB.
> **BD_ADDR** now the real per-device `F8:8F:CA:20:49:E5` (was placeholder
> `43:30:A0:00:00:00`). **Whack-a-mole lesson:** the systemd IP-firewall notice
> fires once for the FIRST unit with `IPAddressDeny` — can't kill it per-unit,
> needs BPF or nothing. **No-serial lesson:** deep cpuidle C2/C3 stays BLOCKED
> (feasible code, but the suspend-to-RAM de-risk HUNG on resume and there is no
> serial console to debug it blind — deferred until serial exists). **3 external
> residuals:** eth-lan DHCP on a DHCP-less direct cable (environmental), kscreen
> `.service` D-Bus naming (upstream libkscreen), avahi No-NSS-mDNS (`nss-mdns`
> unpackaged). Thermal watch: peak ~94–99 °C under sustained load (no throttle).
> See `docs/2026-07-06-bootlog-cleanup.md` (rc1→rc5) + the v1.6.10 update in
> `docs/2026-07-02-boot-error-inventory.md`.
>
> **2026-07-06 — v1.6.9 BOOT-LOG CLEANUP: the boot log is now clean (PUBLIC
> release in progress).** The last two cosmetic log-noise items are fixed
> (device pkg **r23**, kernel **unchanged** `6.12.12-r32`/`#33`; **no functional
> change**): (1) **gkr-pam** "couldn't unlock the login keyring" on every ssh
> session — `/etc/pam.d/base-auth`+`base-session` drop the desktop-keyring PAM
> lines (gnome-keyring stays as an nm-applet/gvfs/webkit dep; `pam_systemd`
> preserved); 0 gkr lines verified. (2) **PulseAudio `module-alsa-card`** on the
> omap-hdmi-audio card — a `PULSE_IGNORE` udev rule; the r22 attempt pinned
> `KERNEL=="card1"` and was REJECTED (ALSA index is probe-order dependent — HDMI
> was card2 that boot), r23 matches the backing platform device
> `KERNELS=="omap-hdmi-audio.1.auto"` (index-independent). **bluetoothd** U5 left
> documented-benign. **Acceptance on r23 = ACCEPT:** 0 failed units, gkr=0, HDMI
> noise=0, eth cold-init works, WiFi/NFC/CPU healthy, no new regression; residual
> err/warn = the known-benign set. **Thermal watch:** peaked ~98–99 °C under
> sustained dual-core load (below the 100 °C trip, no throttle). **Backlog is now
> PROJECTS only:** NFC long-lived userspace (tap-to-pair), deep cpuidle C2+, the
> thermal-headroom watch. See `docs/2026-07-06-bootlog-cleanup.md` and the v1.6.9
> update in `docs/2026-07-02-boot-error-inventory.md`.
>
> **2026-07-06 — ETHERNET COLD-INIT FIXED, task #17 FULLY CLOSED (ships as
> v1.6.8, PUBLIC release in progress).** The LAN9500A "enumeration
> intermittency" was **not a kernel/ehci race** (correcting the note below) — it
> was a **pinmux miss**: `gpio_1` NENABLE (the LAN9500A power-enable) is pad
> `kpd_col2` @ CORE padconf `0x186`, but `ethernet_gpios` muxed only `gpio_62`
> NRESET (`0x08c`), so gpiolib drove the DATAOUT latch (debugfs "asserted")
> while the pad stayed safe_mode → the chip was never powered → PORTSC CCS=0 on
> cold boot. The "3/3 vs 0/3 boots" was stock priming (warm reboots from a stock
> RAM boot kept the chip attached). Fix: DTS `ethernet_gpios` +=
> `OMAP4_IOPAD(0x186, PIN_OUTPUT | MUX_MODE3)` (patch 0003; kernel pkgrel **32**,
> uname **`#33`**, commit **e33a1b4**); the `#31`/6c869e8 2500ms "settle" is
> reverted as a false positive, and the non-stock `gpio_159`/`0x164` mux dropped.
> **Gold-validated:** clean flash of `#33` + a true cold power-cycle → `eth0`
> 100Mbps/Full, 0 failed units. Task #17 is now fully closed (enumerate + link +
> the v1.6.7 NM serverless-DHCP-loop fix). See
> `docs/2026-07-06-eth-coldinit-resolved.md`.
>
> **2026-07-05 — v1.6.7 RELEASED + FLASHED (tag `v1.6.7` = kernel `#29`
> unchanged + device pkg r21: baked eth NM profiles + `led_static` healthd
> guard).** Accepted on device 2026-07-05: 3 clean boots, zero failed units,
> wait-online green, `led_static` guard live (33× info / 0 false CRIT in 91
> samples), NFC clean probe, factory WiFi MAC/.195, CPU/power nominal.
> **Task #17 NARROWED, not closed** (correcting the note below): the NM
> retry-loop half IS fixed and shipped, but the **LAN9500A enumeration
> intermittency is back** — 0/3 acceptance boots enumerated (USB CCS=0) vs 3/3
> on 2026-07-03/04 with the byte-identical kernel; a kernel/ehci bring-up race
> (patches 0006/0008/0012 area), not cpufreq, not r21. With the chip absent
> the boot stays clean (graceful degradation, verified ×3). See the 2026-07-05
> addendum in `docs/2026-07-04-ethernet-resolved-and-led-guard.md`.
>
> **2026-07-04 — v1.6.6 RELEASED (tag `v1.6.6` = the accepted `#29`/r20 image),
> and both post-acceptance open items CLOSED the same day:** (1) **ETHERNET
> RESOLVED, task #17 closed** — the `#29` "carrier flap" was NetworkManager's
> auto-generated-profile serverless-DHCP retry loop (deactivate's MAC reset
> bounced the LAN9500A carrier, the carrier event re-armed autoconnect; ~47 s
> period), not the link: NM detached, carrier held 90+ s / zero transitions /
> 0 errors. Fixed by baked eth0 profiles (device pkg **r21**, hot-deployed):
> `no-auto-default=eth0`, `eth-lan` (DHCP, `cloned-mac-address=permanent`,
> one retry), `eth-direct` (static 10.42.0.2, manual) + host profile
> `eth-direct-host`; `nm-online -s` rc=0, `ssh root@10.42.0.2` works.
> (2) **`led_frozen` static-by-design guard shipped** (healthd r21 +
> nq-health-report): crit only with distress co-signal, healthy static frame →
> info `led_static`. See `docs/2026-07-04-ethernet-resolved-and-led-guard.md`.
>
> **Flashed + acceptance-verified 2026-07-03, released 2026-07-04 as v1.6.6:** the
> boot-error-inventory fix batch — kernel patches 0023–0028 (twl6030 vsel/VC
> voltages, C1-only cpuidle replacing `cpuidle.off=1`, ti-sysc clkdev,
> phy-generic vbus, pwrseq clk-settle), governor back to `ondemand`, `CLK_TWL=y`
> + CLK32KG WiFi/BT clock fix, McPDM include dropped, PVDD supplies, NFC node
> disabled (then called "dead chip" — retracted, see batch 2 below), stable
> WiFi MAC, pipewire-autostart topology fix,
> baked-in ssh/WiFi access. **On device (`6.12.12 #27`, r19): 9/10 targeted
> dmesg error classes gone, zero failed units, governor `ondemand` @ exact OPP
> voltages, key-based `root@` ssh over gadget+WiFi, stable WiFi IP
> `192.168.20.175`.** Newly opened: the B22 `twl: not initialized` ×22 burst,
> B23 twl fck osc-rate, two nq-healthd tooling bugs, optional factory-MAC bake.
> See `CHANGELOG.md` [Unreleased] + `docs/2026-07-02-boot-error-inventory.md`
> §"FLASH-VERIFIED 2026-07-03".
>
> **BATCH 2b — FLASHED + ACCEPTED 2026-07-03 (kernel pkgrel 28 = uname `#29`,
> device r20): NFC IS FIXED AND WORKING.** The stock RAM-boot discrimination
> test (run during the flash cycle) proved the PN544 healthy and exposed the
> real bug: our `nfc_pins` muxed the **dpm_emu debug pads**
> (`0x1b4/0x1b6/0x1b8`) instead of the real `usbb2_ulpitll_dat1/2/3` pads
> (`0x16a/0x16c/0x16e`) — fixed in patch 0003, node re-enabled; `#29` detects
> `nfc_en polarity : active high` cleanly, `nfc0` registered. Batch 2 items all
> verified: B22 gone (patch 0030, `twl: not initialized` count = 0), B23 gone
> (0031), healthd led/vdd fixes live (0029 + r20), **factory WiFi MAC
> `f8:8f:ca:20:48:e1` on air — final IP `192.168.20.195`**. TWL6040 correction
> shipped (nodes/config removed). NEW: **ethernet partial comeback** — carrier
> up for the first time since v1.4.0 but flapping, DHCP never completes
> (task #17 lead); and `led_frozen` still needs a static-by-design guard
> _(both closed 2026-07-04, see the top note)_.
> This image **was released as v1.6.6 on 2026-07-04**. See
> `docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md` +
> `docs/2026-07-02-boot-error-inventory.md` §"BATCH 2b".
>
> **v1.6.5 (2026-07-01)** _(superseded by v1.6.6)_**.** A batch of device-side fixes + companion
> features on the v1.6.3 image (an interim **v1.6.4** was flashed internally to test the LED
> keepalive but never published — folded into v1.6.5; the 1.6.3 → 1.6.5 gap is intentional).
> Final pkgrels: `nexusqd` **r5**, `nexusq-control` **r4**, `device-google-steelhead` **r17**;
> `boot.img` byte-identical to v1.6.2/v1.6.3 (kernel unchanged). (1) **librespot no longer
> crash-loops on a fresh boot** — the ALSA `NexusQ` softvol control didn't exist yet when
> librespot opened its mixer (control created lazily on first PCM open, recreated empty each
> boot); `librespot.service` now bootstraps it with an `ExecStartPre` (`aplay … nexusq_soft`)
> — also fixes companion volume. (2) **color themes are now a BREATHING OVERRIDE** — new
> `nexusqd breathe R G B` (`CTL_BREATHE`) pulses the compositor manual layer (priority 8) in
> the theme hue with the same throb as the idle screensaver, **always visible** (over the
> music visualizer / a blanked screensaver); a companion theme maps to **just** `breathe R G B`
> (blue/warm/cool/rose/smoke/off). (The earlier screensaver-retint approach was reverted —
> it was invisible once the screensaver blanked / while music played.) (3) **the 5 music
> visualisations are selectable from the app** — bridge `setScene`/`listScenes`
> (→ `auto` + `scene 0..4`) + a separate app picker; color theme (breathing override, prio 8)
> and visualisation (music, prio 7) are independent. (4) **app-mute now lights the device
> mute LED** — new `nexusqd muted 0|1` (`CTL_SETMUTED`) calls the same `apply_mute_led()` the
> hardware key drives; the bridge's volume/mute path sends it. (5) **the LED ring no longer
> goes dark after a long idle** — the `steelhead-avr` fw starves without periodic frame
> *commits* once the screensaver locked/blanked and `nexusqd`'s `memcmp` write-gate went
> silent; fixed with a 1 Hz keepalive (`AVR_KEEPALIVE_S=1.0`). _(Deployed; "never wedges
> again" still needs an overnight idle soak — the wedge took ~20 h.)_ (6) **the companion
> bridge is reachable over WiFi** — new nftables drop-in `55_nexusq-control.nft` opens TCP
> 45015 on `wlan*`. _(Deferred to **v1.6.6**: companion volume/mute act on the ALSA softvol +
> mute LED but do NOT mirror to the LXQt desktop taskbar — app vs desktop can diverge; see
> HANDOFF.md.)_ See `CHANGELOG.md` ([1.6.5]),
> `docs/2026-07-01-led-ring-avr-starvation-keepalive.md` and
> `docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.
>
> **v1.6.3 (2026-06-30).** **A companion app and its on-device
> `nexusq-control` LAN bridge now ship** — a phone/desktop remote for the Q (volume,
> LED theme + brightness, now-playing), replacing the dead 2012 Google companion app.
> `nexusq-control` is a pure-Python3 daemon (new noarch aport `pmos/nexusq-control`,
> `userspace/nexusq-control/`) on **TCP 45015**, advertised over mDNS **`_nexusq._tcp`**,
> speaking a line-delimited JSON v1 protocol (`companion/PROTOCOL.md`). It fans out to:
> an ALSA **`nexusq_soft` softvol** (control `NexusQ`, layered on the v1.6.2 tee) for
> volume — the **same knob librespot uses** (`--mixer alsa --alsa-mixer-control NexusQ`),
> so Spotify-Connect and companion volume stay in lockstep — `nexusqd` over
> `/run/nexusqd.sock` for LED **theme + brightness** (new `nexusqd brightness <0-255>`),
> and a `librespot --onevent` hook for **now-playing**. The companion (`companion/app`)
> is a cross-platform **Flutter** app (sphere UI, animated ring, mDNS auto-discovery),
> built on the phone — **not** in the device image. The bridge is enabled at boot via a
> systemd preset (`95-nexusq.preset`) and its unit carries **no `After=`** ordering (an
> `After=nexusqd.service` formed a boot ordering cycle that systemd broke by **deleting
> the bridge's start job**, so it never auto-started — fixed by dropping `After=`).
> **Verified live:** the bridge auto-starts (`active`), answers every protocol method,
> volume works, and the LED visualizer still tracks playback. Transport
> (play/pause/next) is `unavailable` in v1 by design (librespot has no local transport
> API). See `CHANGELOG.md` ([1.6.3]) and `docs/2026-06-30-companion-app-RE.md`.
>
> **v1.6.2 (2026-06-30).** **The LED music visualizer now reacts to
> Spotify playback.** v1.6.1 sent librespot straight to the speaker, so nexusqd's
> snd-aloop audio tap got nothing and the ring stayed idle; v1.6.2 makes the `nexusq`
> ALSA PCM a TEE (`multi` + `route`) that duplicates the 48 kHz stereo to BOTH the
> TAS5713 speaker AND `hw:Loopback,0`, and adds `/etc/modules-load.d/snd-aloop.conf`
> to auto-load the loopback. nexusqd's existing `arecord` on `hw:Loopback,1` drives
> the FFT/beat ring while the speaker plays (speaker = timing master, loopback slave
> is `plughw` so it never blocks playback). `device-google-steelhead` pkgrel 12;
> verified live (ring pulses to music, no ALSA/xrun, NRestarts=0). See `CHANGELOG.md`.
>
> **v1.6.1 (2026-06-29).** **TAS5713 speaker audio works** and
> **Spotify Connect (librespot) is baked into the build.** The v1.6.0 speaker path
> played exactly 2× too fast — fixed by kernel patch 0022 (derives McBSP2 `CLKGDV`
> from the real fclk + a minimal I2S frame); on-device a 60 s clip now plays in
> **60.00 s** (was ~30 s). `device-google-steelhead` (pkgrel 11) now ships the enabled
> `librespot.service`, the `nexusq` ALSA PCM (`asound.conf`, by card NAME) and the
> `60_spotify.nft` drop-in, so the Spotify "Nexus Q" target survives a flash. See
> `CHANGELOG.md` and `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.
>
> **v1.6.0 (2026-06-28).** Added a **working armv7 `python3`** on the
> device — flash-verified from a clean flash. The fix was the byte-exact all-RAW
> `raw2simg.py` flash (the on-device SIGSEGV was a flash bug, not a build bug); v1.6.0
> ships a plain default-linker (bfd) `python3` rebuild with a build-integrity gate as a
> safety net (a gold-linker workaround was tried and dropped as unnecessary).
> `onboard`/`blueman`/`sleep-inhibitor`/`gdb` are no longer down. Plus zram swap and
> user namespaces. See `CHANGELOG.md` and `docs/2026-06-28-session-findings.md`.

## Hardware Map

| Subsystem | Status | Detail |
|-----------|--------|--------|
| Kernel + boot | ✅ works | mainline 6.12.12, ≤8 MB image; flaky boot ~1 in 3 (retry helps). _(Updated 2026-06-28: now built with Alpine GCC 15.2 and boots — the old "GCC 13.3 only" no longer holds for the pmbootstrap path.)_ |
| HDMI video | ✅ works | omapdrm, framebuffer console |
| HDMI audio | 🟠 needs audio-EDID sink | _(Updated 2026-07-02)_ the ALSA card registers, but with no audio-capable EDID sink PulseAudio can't build a profile for `platform-omap-hdmi-audio.1.auto` (item U4). Speaker path (TAS5713) is the working audio output |
| eMMC + rootfs | ✅ works | postmarketOS (systemd variant) on userdata |
| WiFi (BCM4330) | ✅ works | _(Corrected 2026-07-02)_ the same-day "dead on the live unit" verdict was **wrong** — the DHCP **IP had moved** (NM randomized locally-administered MAC → fresh lease per boot; device was up at `192.168.20.142`). The v1.5.0 `mpc=0` fix cured the idle loss/latency. _(Characterized 2026-07-07: 5 GHz is **healthy, NOT flaky** — −48 dBm, 0 discarded/retry pkts, 2.6 ms jitter, 0 % loss; bulk **~34 Mbit/s is a HARDWARE CEILING** of the 2010-era 1×1 802.11n chip on SDIO, not a bug — same cipher does ~80 over ethernet so the crypto/CPU ceiling ≈80 and WiFi is the limit; 2 streams aggregate to less; `powersave=2` no change; ~100× the appliance's need. 2.4 GHz retested = also stable/not flaky but strictly worse (~13–16 Mbit). See `docs/2026-07-07-wifi-characterization-and-ethernet-default.md`.)_ _(Verified 2026-07-03 on `#27`:)_ `wifi-stable-mac.conf` holds — auto-joins the baked profile, stable IP `192.168.20.175` (on-air MAC = the chip's OTP `14:7d:c5:3a:35:b5`, not the factory `f8:8f:ca:20:48:e1` — _resolved in batch 2b, **verified on `#29` 2026-07-03**: NM `cloned-mac-address=F8:8F:CA:20:48:E1` pin, since brcmfmac ignores nvram `macaddr=`; the **factory MAC is on air** and the **final IP is `192.168.20.195`**_); the CLK32KG stock-parity clock fix + `CONFIG_CLK_TWL=y` retired the ~25 s pwrseq defer (B17 — pwrseq @4.31 s). clm_blob still missing (B4). `docs/2026-07-02-boot-error-inventory.md` |
| USB gadget network | ✅ works | RNDIS 172.16.42.1, SSH via nexus-diag.service. _(2026-07-07: demoted to FALLBACK — the direct-cable **ethernet path `10.42.0.2` is now the default** deploy/control transport: ~80 Mbit/s, 0.62 ms, fixed IP; the gadget's `enx*` renames per boot.)_ |
| **TAS5713 amplifier** | ✅ works | _(Updated 2026-07-07, v1.6.13/v1.6.15)_ sound card (ALSA card `NexusQSpeaker`, McBSP2 I2S → TAS5713) plays at **correct pitch/speed** (v1.6.0 2× bug fixed by patch 0022). **⚠️ physically SILENT until v1.6.13** — `mcbsp2_pins` muxed the wrong balls (`abe_dmic_*`), so the amp got no clock/data/frame (`aplay` rc=0); fixed to stock pads `0x0f6/0x0fa/0x0fc` MUX_MODE0 → user-confirmed audible. Since **v1.6.15** it is one selectable **PulseAudio** output (was direct ALSA); librespot feeds PA as an input. See `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md` + `docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md` |
| Bluetooth (BCM4330) | ✅ works | _(Updated 2026-07-06, v1.6.10)_ `hci0` up, `BCM4330B1.hcd` patchram loads every boot (`Proxima - BCM4330B1 37.4 MHz Class 1.5`, build 0482). **BD_ADDR is now the real per-device `F8:8F:CA:20:49:E5`** (DTS `local-bd-address` + kernel patch 0036 teaching btbcm the `43:30:A0` placeholder) — was the non-unique, group-bit-set placeholder `43:30:A0:00:00:00`. The U5 `bluetoothd: Failed to set default system config` line is FIXED (bluez `main.conf [LE]` populated so the MGMT TLV is non-empty) — not the earlier "benign" |
| TWL6040 codec | ⚪ not populated/unused | _(Corrected 2026-07-03)_ **never a codec on this board**: stock 3.0.8 has ZERO twl6040/AUDPWRON code, the twldata codec pdata slot is NULL, stock i2c1 registers only `twl6030@0x48` — the 2026-06-10 "dead chip" verdict measured stock-correct behaviour (no chip to ACK at 0x4b). Node + ABE card + pins removed from the DTS, defconfig options off (shipped on `#29`, 2026-07-03). No headset path **by design**; audio = TAS5713 + HDMI. Was "🔴 dead hardware" |
| NFC (PN544) | ✅ WORKS | _(FIXED 2026-07-03 — was "🔴 dead hardware" 2026-07-02, then "🟠 under investigation")_ the chip was always healthy: our `nfc_pins` muxed the **wrong pads** (dpm_emu3/4/5 debug pads `0x1b4/0x1b6/0x1b8` instead of `usbb2_ulpitll_dat1/2/3` @ `0x16a/0x16c/0x16e`), so VEN/FW/IRQ never reached it. Proven by the stock RAM-boot test (ACK at 0x28, core-reset frame rc=0) + the live stock `omap_mux` dump (`reverse-eng/stock-omap-mux-full.txt`). Fixed in patch 0003 (kernel pkgrel 28), node re-enabled; on `#29`: `nfc_en polarity : active high` **clean**, `/sys/class/nfc/nfc0` present. **Tap-to-send shipped v1.7.0 (2026-07-08)** — reverse-HCE (Q = ISO-DEP reader, phone runs HCE), kernel patch 0037 RATS-activates any ISO-DEP target. See `docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md` + `docs/2026-07-08-nfc-tap-to-send-reverse-hce.md` |
| TMP101 temp sensor | ✅ works | _(Updated 2026-07-02)_ `lm75` autoloads, `hwmon0: sensor 'tmp101'` (though `temp1_input not attached to any thermal zone`) |
| LED ring (32× RGB) | ✅ works | mainline 6.12 driver `leds-steelhead-avr` (Plan 1, merged, auto-loads) + `nexusqd` daemon (Plan 2: idle glow, themes, CLI, autostart) -- behind `steelhead-avr` MCU (i2c `1-0020`). _(Updated 2026-07-01, v1.6.5:_ the ring **no longer goes dark after long idle** — the AVR fw starves without periodic frame commits; `nexusqd` now sends a 1 Hz keepalive re-commit. Color themes now **breathe** the hue (`nexusqd breathe R G B`) and the 5 music visualisations are app-selectable. See `docs/2026-07-01-led-ring-avr-starvation-keepalive.md` + `docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.) |
| Ethernet (LAN9500A) | ✅ works from cold | _(✅ FULLY FIXED 2026-07-06, task #17 CLOSED — was "🟠 enumeration intermittent" 2026-07-05, briefly "CLOSED" 2026-07-04, "🟠 sw bug", and a wrong "dead hardware" verdict)_ fixed in v1.1.0/v1.3.0 (patches 0006/0012), **regressed** in v1.4.0, enumeration+carrier **came back with batch 2b/`#29`** (2026-07-03), the "flap" was root-caused 2026-07-04 as **NM's serverless-DHCP retry loop** (fixed by baked eth0 NM profiles, device r21, v1.6.7: `no-auto-default=eth0` + `eth-lan` + `eth-direct` static + host `eth-direct-host`; `ssh root@10.42.0.2` works). The **enumeration** half was root-caused 2026-07-06 as a **pinmux miss**: `gpio_1` NENABLE = pad `kpd_col2` @ padconf `0x186`, which `ethernet_gpios` never muxed → gpiolib drove the DATAOUT latch (debugfs "asserted") but the pad stayed safe_mode → chip never powered → CCS=0 (the "0/3 vs 3/3" was stock priming, not a race). Fixed by the DTS pad mux (patch 0003, kernel `#33`, commit e33a1b4; 2500ms settle reverted as a false positive). **Gold-validated:** clean flash + true cold power-cycle → `eth0` 100Mbps/Full, 0 failed units. Ships v1.6.8. Caveat: no MAC EEPROM → random hw MAC per boot (LAN lease changes; pin a cloned MAC if needed). `docs/2026-07-06-eth-coldinit-resolved.md` (+ `docs/2026-07-04-ethernet-resolved-and-led-guard.md` for the NM half) |
| SMP (2nd core) | ✅ works | _(Updated 2026-06-28)_ dual-core since v1.2.0 — patch 0009 `dsb_sev()` in prepare + `cpuidle.off=1`; `nproc=2` re-confirmed live. See `docs/SMP-second-core.md` |

## Plan (by priority)

### 1. TAS5713 amplifier  ✅ DONE 2026-06-29 (v1.6.1 software) · physically AUDIBLE 2026-07-07 (v1.6.13)
The reason this device exists. **✅ speaker audio works at correct pitch/speed — the
v1.6.0 2× too-fast bug was root-caused and fixed (kernel patch 0022).**
> ⚠️ **Correction 2026-07-07:** the v1.6.1 "works" was **software-pipeline-only** — the
> physical amp was SILENT until v1.6.13 because `mcbsp2_pins` muxed the wrong balls
> (`abe_dmic_*`), leaving the real McBSP2 I2S balls in `safe_mode` (`aplay` rc=0 but no
> clock/data/frame). Fixed to stock pads `0x0f6/0x0fa/0x0fc` MUX_MODE0 → user-confirmed
> audible. See `docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md`.
- [x] DTS: `simple-audio-card` "NexusQ-Speaker" wiring McBSP2 → TAS5713
- [x] DTS: MCLK 12.288 MHz (dpll_per_m3x2 61.44 MHz → auxclk1 /5 → fref_clk1_out
      pad 0x19a); McBSP2 master (clkx/fsx pads OUTPUT), SRG from abe_24m_fclk
- [x] `snd-soc-omap-mcbsp` module enabled (=m) and probing
- [x] `speaker-test -D plughw:NexusQSpeaker` runs clean (rc=0, no dmesg errors)
- [x] **listening/timing test done 2026-06-29 — REVEALED A 2× SPEED BUG.** 10 s of
      `S16_LE` silence to `hw:1,0` plays in **5.00 s** (0.50× = 2× too fast, all
      rates). librespot/Spotify tracks therefore end in half real time and the player
      auto-skips ~40 s in. `func_mcbsp2_gfclk` reads 24.576 MHz (=512×48k, correct),
      so the ×2 is **downstream** (SRG divider / I2S frame width / TAS5713 MCLK
      16 vs 12.288 MHz — B7 family, `docs/2026-06-19-boot-warnings-followup.md`).
- [x] ✅ **FIXED the FSYNC 2× clock bug (kernel patch 0022, v1.6.1).** Root cause: with
      `simple-audio-card` mastering McBSP2, the generic card sets only `mclk-fs` and
      never calls `snd_soc_dai_set_clkdiv()`, so `omap-mcbsp` left `CLKGDV=0` (bit clock
      = the undivided 24.576 MHz fclk) and sized the frame as `in_freq/rate = 256` BCLK
      → **FSYNC = 96 kHz = 2× too fast**. The patch derives `CLKGDV` from the real fclk
      (`mcbsp->fclk`) + a minimal `wlen*channels` I2S frame, reproducing the factory
      registers (CLKGDV=15, BCLK 1.536 MHz, 32-BCLK frame, FSYNC 48 kHz). **Verified on
      hardware:** 60 s of audio plays in **60.00 s** (1.000×; was ~30 s = 0.50×). The
      "B7 TAS5713 MCLK 16 vs 12.288" lead was a **red herring** (mainline `tas571x` has
      no `.set_sysclk`, so MCLK never gates FSYNC). Cross-checked vs
      `reverse-eng/vmlinux.bin`. See `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.

### 2. Bluetooth  ✅ DONE 2026-06-10
- [x] firmware installed (BCM.hcd + BCM4330B1.hcd); loads automatically at boot
      ("Proxima - BCM4330B1 37.4 MHz Class 1.5" -- device-specific config)
- [x] scan finds devices; controller powered, name "Google Nexus Q"
- [ ] pair a BT keyboard when at hand (solves GUI input)

### 3. HDMI audio smoke test  🟠 blocked by monitor
- [x] tested 2026-06-10: ALSA opens fail with -22 because the Philips 190C
      (DVI-era panel) provides no audio EDID ("timeout reading edid").
      Retest against a real TV/AV receiver -- expected to work.

### 4. GUI: lightweight Wayland desktop (weston)  ✅ DONE 2026-06-19
Decision: device runs **primarily headless**; desktop is for occasional
debugging/ops on the HDMI port. Switched X11/XFCE → Wayland/weston so the
future SGX540 GPU path is viable (X11/glamor ES2 is the broken path on the SGX
blobs -- see docs/2026-06-19-gpu-sgx540-acceleration-research.md §5).
- [x] **was** XFCE4 + lightdm (2026-06-10, X11, llvmpipe). **Removed 2026-06-19**
      (`apk del postmarketos-ui-xfce4 lightdm`).
- [x] **now** `postmarketos-ui-weston` + `tinydm` (auto-login, no greeter).
      Reproducible: `docker-build.sh` `ui = weston`; device package ships
      `/etc/xdg/weston/weston.ini` + `weston-nexusq.desktop` session + a
      post-install that sets the default tinydm session.
- [x] **pixman** SW renderer forced (`[core] renderer=pixman` + explicit
      `--config`): lighter than GL-on-llvmpipe on the single A9. Idle bg #000F14.
- [x] headless-tolerant: `require-input=false` (DRM backend otherwise aborts
      with "failed to create input devices" -- no keyboard/mouse attached).
- [x] verified live on `192.168.20.179`: weston auto-starts on HDMI-A-1
      (1024x768@60), survives reboot, ~190 MB RAM.
- [~] input: a **BLE** mouse/keyboard (e.g. Logitech MX Master 4) pairs +
      bonds fine over the BCM4330, but delivers **no input** until the kernel
      has `CONFIG_UHID` — HID-over-GATT (HOGP) needs `/dev/uhid` to spawn the
      input device. Symptom without it: `Paired: yes`/`Connected: yes` yet
      bluetoothd loops `input-hog profile accept failed` and no `/dev/input/event*`
      appears. **Fixed in `steelhead_defconfig` (CONFIG_UHID=y + CONFIG_HIDRAW=y,
      2026-06-19) — pending a kernel rebuild + boot reflash.** `CONFIG_BT_HIDP=m`
      only covers Classic-BT HID, not BLE. The bond lives on the rootfs, so a
      boot-only reflash keeps it; the mouse will just connect once uhid is present.
      Alt: USB OTG mouse/Logi-Bolt receiver (sacrifices the gadget network).

### 5. TWL6040 codec  ⚪ NOT POPULATED — closed 2026-06-10 as "dead HW", CORRECTED 2026-07-03
- [x] root-caused: chip never ACKs on I2C 0x4b (-121/EREMOTEIO) with all
      inputs verified live: V1V8+V2V1 rails enabled, CLK32KG running,
      AUDPWRON (gpio_127) raised, bus healthy (TWL6030 ACKs on 0x48-0x4a).
      Second dead chip on this unit (with ethernet). Headset jack gone;
      TAS5713 speaker path and HDMI audio are unaffected.
- [x] sound + twl6040 nodes disabled in DTS -> clean boot, no deferred loop
- [x] **CORRECTION 2026-07-03: the verdict above was wrong in kind — the chip
      is simply unused/unpopulated on steelhead, not dead.** Stock 3.0.8 has
      ZERO twl6040/AUDPWRON code (whole-image string+symbol sweep), the twldata
      codec pdata slot is NULL (`steelhead_twldata+0x24` @ `0xc0719b30`), stock
      i2c1 board info registers only `twl6030@0x48`, and gpio_127 as AUDPWRON
      had no stock evidence. The missing ACK is stock-correct. Batch 2 (flashed
      2026-07-03 on `#29`) DELETES the node + ABE card + `twl6040_pins` from the DTS
      and drops TWL6040_CORE/SND_SOC_TWL6040/SND_SOC_OMAP_ABE_TWL6040/
      CLK_TWL6040 from the defconfig. Evidence:
      `docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §6.2.

### 6. NFC + temp sensor  ✅ (NFC FIXED 2026-07-03 — wrong pinmux pads)
- [x] TMP101: lm75 module added, binds, reads 41.75 °C on the board
- [x] PN544: NFC modules added (NFC_SHDLC=y was the missing dep), driver
      binds, `nfc0` registers. 🟠 "could not detect nfc_en polarity" warning
      -- chip health unverified until tested with an actual NFC tag
- [x] **CLOSED 2026-07-02: the PN544 is DEAD HARDWARE on this unit.** Live i2c
      probe: no ACK at 0x28 (or anywhere on i2c-2) with VEN high, low, or in
      fw-download mode; the driver's exact 6-byte core-reset frame NAKed —
      after first stock-verifying that our pins/polarity/timing MATCH
      (`nfc_gpios`: en=163 active-high, fw=162, irq=164; 20/60 ms VEN). DTS
      node `status = "disabled"` (flashed 2026-07-03; boot is clean of the
      polarity line). Same category as the TWL6040.
      See `docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §4.
- [ ] **RE-OPENED 2026-07-03: the "dead hardware" verdict is RETRACTED** (we
      never conclude dead hardware). The stock regulator audit proved stock has
      NO software power path for the PN544 (pdata = 3 gpios, zero regulator
      calls in `pn544_probe`; VBAT/PVDD hardwired) and our regulator state
      matches stock bit-for-bit → software parity COMPLETE, the no-ACK is
      **unexplained**. Next: NFC test under the stock RAM boot
      (`output/stock-adb-boot.img`), scheduled for the imminent flash cycle;
      then i2c timing/pads diff; VBAT pin measurement as last resort.
      See `docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §6.3.
- [x] **✅ FIXED 2026-07-03 — the stock RAM-boot test settled it: the chip is
      HEALTHY, our pinmux was WRONG.** `nfc_pins` muxed the dpm_emu3/4/5 debug
      pads (`0x1b4/0x1b6/0x1b8`); the real pads are `usbb2_ulpitll_dat1/2/3`
      (`0x16a/0x16c/0x16e` — from the live stock `omap_mux` dump,
      `reverse-eng/stock-omap-mux-full.txt`), so VEN/FW/IRQ never reached the
      chip and every mainline-side probe was meaningless. Under stock: ACK at
      0x28 with VEN high, core-reset frame accepted rc=0. Fixed in patch 0003
      (kernel pkgrel 28, "batch 2b"), `pn544@28` re-enabled; on `#29`:
      `nfc_en polarity : active high` clean, `nfc0` registered.
      See `docs/2026-07-03-nfc-pinmux-fix-and-batch2b-acceptance.md` +
      `docs/2026-07-02-stock-parity-voltage-wifi-idle.md` §7.
- [x] **NFC tap-to-send SHIPPED 2026-07-08 (v1.7.0, device r33 / kernel r37).**
      The RF path is exercised end-to-end via **reverse-HCE** (the Q is the ISO-DEP
      reader, the phone runs a HostApduService): `nexusq-nfc-send` daemon pushes a
      text to the companion app on each tap. Enabler = kernel **patch 0037**
      (RATS-activate any ISO-DEP target, not just DESFire). neard is NOT installed —
      the daemon owns `nfc0`. See `docs/2026-07-08-nfc-tap-to-send-reverse-hce.md`.
      _(Deferred: send IP/mDNS as the payload for tap-to-onboard; C-rewrite the
      Python reader.)_

### 7. TOSLINK / SPDIF output (audio)  ✅ DONE 2026-07-07 (v1.6.13 kernel / v1.6.15 output)
Optical out is driven by the OMAP4's own McASP block -- fully independent of
the (absent) TWL6040 codec. `spdif_dit` node already exists in the DTS.
- [x] mainline support confirmed — `davinci-mcasp` already knows `ti,omap4-mcasp-audio`
      + DIT/IEC958; NO driver patch needed (defconfig `SND_SOC_DAVINCI_MCASP=m` +
      `SND_SOC_SPDIF=m`)
- [x] wired a second simple-audio-card `sound_spdif` (`NexusQ-SPDIF`): `&mcasp0` DIT →
      `spdif_dit`, new `mcasp_spdif_pins` (`0x0f8` MUX_MODE2, AXR0 out). Probe `-EINVAL`
      fixed with `format="i2s"` + mcasp bit/frame-master
- [x] a selectable PulseAudio output ("Optický výstup") since v1.6.15; PA pinned to
      48 kHz so the DIT locks (44.1 kHz → "off by 88435 PPM")
- [ ] listen-test into a real DAC / AV receiver (built · flash-verify pending)
- Payoff for a vinyl/music household: bit-perfect digital out into a hi-fi DAC.
  Full record: `docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md`

### 8. Flaky boot (research)
- [ ] needs UART serial console (requires opening the device / soldering)
- [ ] until then workaround: power-cycle again
- Candidates: U-Boot DRAM init, kernel early race

### 9. LED ring  ✅ DONE 2026-06-19 (driver + daemon)
The 32 RGB LEDs sit behind the steelhead-AVR MCU (i2c `1-0020`, DT node
`avr@20` compatible "google,steelhead-avr"). The AVR speaks a simple
register-write i2c protocol (from AOSP `drivers/misc/steelhead_avr_regs.h`):
  - 0x02 LED_MODE   (0x02 = HOST full control, 0x00 boot anim, 0x03 power-up)
  - 0x03 SET_ALL    payload R,G,B
  - 0x04 SET_RANGE  start, count, R,G,B...
  - 0x05 COMMIT     (0x00 immediate, 0x01 interpolate)
  - 0x06 SET_MUTE ; 0x07 GET_COUNT ; 0x08 HW_TYPE ; 0x09 HW_REV ; 0x0A FW_VER
- [x] verified from userspace via /dev/i2c-1 (no driver bound): AVR reports
      HW_TYPE=0x01 (SPHERE), LED count=32; "HOST mode + SET_ALL dim-blue +
      COMMIT" lit the whole ring blue. Reads work with plain write-then-read.
- [x] **driver (Plan 1):** mainline 6.12 `leds-steelhead-avr` — multicolor LED
      class for the 32 ring + mute, batch `frame` sysfs channel, mute/volume keys
      via threaded IRQ, AVR-reset restore. Merged to `main`, auto-loads at boot,
      validated live. Plan: `docs/superpowers/plans/2026-06-19-led-ring-kernel-driver.md`.
- [x] **daemon + CLI (Plan 2):** `nexusqd` (C11/musl) — idle glow, theme palettes,
      `/run/nexusqd.sock` control + `nexusled` CLI, mute key, postmarketOS aport,
      systemd autostart (verified across reboot). `userspace/nexusqd/`, `pmos/nexusqd/`.
      Plan: `docs/superpowers/plans/2026-06-19-nexusqd-daemon.md`.
- [x] **Plan 2b (done 2026-06-19):** pixel-perfect volume-ring + mute + true idle
      `#000F14` in the priority-10 reaction-layer seam (exact algo in
      `docs/2026-06-19-volume-mute-RE.md`). Verified live: fade-in + brightness levels +
      mute LED (#001E28/#006B8E) + idle #000F14. Volume ring is a rotary encoder (evtest).
- [x] **Plan 3 idle screensaver (done 2026-06-19):** pixel-perfect port of the factory
      ICS ParticleScreensaver LED path (RE'd from the tungsten-ian67k factory image →
      deodexed Visualizer.odex; `docs/2026-06-19-particle-screensaver-RE.md`). The ring
      breathes a uniform `#0099CC × A` (#000F14 ↔ #007AA3, 10 s cosine), 5 s fade-in,
      locks dim after 300 s without audio, blanks after 600 s. Compositor layer priority 5;
      `nexusled auto` resumes it after a manual override. Verified live (breathing + colors).
- [x] **Plan 3b music-reactive (done 2026-06-20):** all 5 scenes (Waveform/WaveformSolid/
      Circles/PointMorph/StarField) + AudioCapture/FFT/BeatProcessor ported pixel-perfect from
      the decompiled `Visualizer.apk` and wired into `nexusqd` (audio tap = arecord).
      Verified live: a track drives the ring.
      RE: `docs/2026-06-19-music-effects-RE.md`. _(Since **v1.6.15** the tap reads the
      active output's **PulseAudio monitor** — `arecord -D pulse`, follows output
      selection — instead of the snd-aloop loopback, plus an **AGC** so the ring reacts
      to the music at any listening volume; see
      `docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md`.)_
- [x] **Spotify Connect (librespot) baked into the build 2026-06-29 (v1.6.1)** —
      `librespot 0.8.0` (libmdns backend) advertises "Nexus Q"; phone discovers,
      authenticates and streams over **5 GHz** WiFi (the 2.4 GHz bulk stall no longer
      blocks it). `device-google-steelhead` (pkgrel 11) `depends librespot` and ships
      the enabled `librespot.service`, the `nexusq` ALSA PCM (`asound.conf`, forced
      48 kHz, by card NAME) and `60_spotify.nft` (wlan UDP 5353 + TCP 37879) — survives
      a flash. Audio is now at correct pitch (the §1 2× bug is fixed).
      See `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.
- [x] **LED follow-on: drive the music-reactive scenes off the live Spotify stream
      ✅ DONE 2026-06-30 (v1.6.2).** Was blocked on WiFi + the audio tap; resolved by
      teeing the `nexusq` PCM to BOTH the speaker and the snd-aloop loopback (`multi` +
      `route`) and auto-loading snd-aloop (`/etc/modules-load.d/snd-aloop.conf`).
      nexusqd's `arecord` on `hw:Loopback,1` now sees the playback and the ring reacts.
      Verified live (ring pulses to Spotify, no ALSA/xrun, NRestarts=0).
      `device-google-steelhead` pkgrel 12. See `CHANGELOG.md`.
- [x] **Idle AVR keepalive ✅ DONE 2026-07-01 (v1.6.5).** The ring went dark after a long
      idle (~20 h): the `steelhead-avr` fw starves without periodic frame *commits*, and
      `nexusqd`'s `memcmp(pk,lastpk)` write-gate suppressed all commits once the idle
      screensaver locked (`SS_LOCK_S=300 s`, `ledAlpha` constant `0.1`) / blanked
      (`SS_BLANK_S=600 s`) to a static frame. Fix: re-commit the current frame every
      `AVR_KEEPALIVE_S=1.0 s` even when unchanged (`nexusqd` pkgrel 5; keepalive landed at
      r3). Not HW / not a commit-mode / not a regression. _(Deployed + running; overnight
      idle soak still pending to prove it never re-wedges.)_ See
      `docs/2026-07-01-led-ring-avr-starvation-keepalive.md`.
- [x] **Breathing color themes + app-selectable visualisations + app-mute LED ✅ DONE
      2026-07-01 (v1.6.5).** New `nexusqd breathe R G B` (`CTL_BREATHE`) drives the
      compositor **manual layer (priority 8)** with a `breathe` flag — pulsing the ring in
      the theme hue with the same throb as the idle screensaver, **always visible** (over the
      music visualizer / a blanked screensaver); a companion color theme maps to **just**
      `breathe R G B` (blue/warm/cool/rose/smoke/off). _(The earlier screensaver-retint
      approach — a `br/bg/bb` base color + `screensaver_set_color` — was reverted as invisible
      once the screensaver blanked / while music played.)_ Separately, the bridge exposes the
      existing 5 `scene 0..4` RenderEngine effects (waveform/waveformsolid/circles/pointmorph/
      starfield) via `setScene`/`listScenes` (→ `auto` + `scene N`) and the app gained a
      VISUALIZATION picker — breathing override (prio 8) and music visualisation (prio 7) are
      independent. And new `nexusqd muted 0|1` (`CTL_SETMUTED`) lights the same
      `apply_mute_led()` mute LED as the hardware key, driven from the bridge's volume/mute
      path. `nexusqd` pkgrel 5, `nexusq-control` pkgrel 4. See
      `docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.
- [ ] LED follow-ons (remaining): scene auto-cycling (FadeTransition not ported);
      ship the musl apk (currently a static binary deployed over USB); overnight idle
      soak to confirm the AVR-keepalive fix holds.

### 10. SMP / second core  ✅ DONE 2026-06-22 (v1.2.0)
- [x] root cause was **not** a U-Boot CPU1-state problem but two mainline gaps:
      a missing `dsb_sev()` in `omap4_smp_prepare_cpus` (patch 0009) + a secondary
      cpuidle panic (boot `cpuidle.off=1`). Both Cortex-A9 online, `nproc=2`,
      `taint=0`; re-confirmed live 2026-06-28. Full writeup `docs/SMP-second-core.md`.
- [x] **cpuidle C1 (WFI) restored 2026-07-02 — ✅ verified on device 2026-07-03:**
      patch 0024 registers a C1-only cpuidle driver on steelhead and
      `cpuidle.off=1` is dropped from the cmdline (it made `cpuidle_register()`
      log "failed to register cpuidle driver" every boot, item B13). On `#27`:
      `cpuidle/state0` = "C1 - CPUx ON, MPUSS ON", governor `menu`, no
      registration error.
- [ ] follow-on: deep idle C2+ — stock has C1–C4 but C2+ traps into the HS
      secure dispatcher (services 0x1c/0x1d/0x21); a dedicated future project.
      **BLOCKED on serial-console access (2026-07-06):** the code path is feasible
      (mainline has the OMAP4460 HS secure idle dispatcher) but the suspend-to-RAM
      de-risk step **HUNG on resume**, and there is **no serial console** on this
      device (fastboot + ssh + stock/our build only; pstore doesn't survive the
      DRAM re-init) to debug a resume hang blind. Deferred until serial exists —
      do NOT re-attempt C2+ blind.

### 11. Companion app + LAN control bridge  ✅ DONE 2026-06-30 (v1.6.3)
A modern phone/desktop remote for the Q + the on-device bridge it talks to — replacing
the dead 2012 Google "Nexus Q" companion (its Android@Home cloud was killed in 2013).
- [x] **RE'd the original Google companion app** to recover the control-RPC vocabulary
      (`setMasterVolume`/`getMasterMute`/`setBrightness`/`setTheme`/`getPlayState`) →
      drove the v1 protocol. `docs/2026-06-30-companion-app-RE.md`.
- [x] **v1 protocol** (`companion/PROTOCOL.md`) — line-delimited JSON over **TCP 45015**,
      mDNS **`_nexusq._tcp`**; methods getState, setVolume/adjustVolume/setMuted/
      toggleMute, setTheme/listThemes/**setBrightness**, getPlayState, getDeviceInfo;
      events on change. Trusted-LAN, no auth in v1.
- [x] **`nexusq-control` device bridge** (new noarch aport `pmos/nexusq-control`,
      `userspace/nexusq-control/`, pure Python3 stdlib). Fans out to: ALSA `nexusq_soft`
      softvol (volume), `nexusqd` `/run/nexusqd.sock` (theme/brightness), `librespot
      --onevent` hook (now-playing). Degrades gracefully when a backend is down.
- [x] **Software master volume** — `asound.conf` `nexusq_soft` softvol (control `NexusQ`)
      over the v1.6.2 tee; `librespot.service` uses `--device nexusq_soft --mixer alsa
      --alsa-mixer-control NexusQ --onevent` so Spotify-Connect + companion share one knob.
- [x] **`nexusqd brightness <0-255>`** — software ring-brightness scalar (no firmware change).
- [x] **Companion Flutter app** (`companion/app`) — sphere UI, animated LED ring, mDNS
      auto-discovery; volume + LED theme/brightness + now-playing. Built on the phone,
      **not** in the device image.
- [x] **Boot enablement (the hard part).** The bridge is enabled durably via a systemd
      **preset** `95-nexusq.preset` (an aport `/usr/lib` vendor wants and a bare `/etc`
      symlink were both stripped by the image build's `systemctl preset-all` +
      postmarketOS's `disable *` catch-all). Its unit carries **no `After=`** — an
      `After=nexusqd.service` formed a boot ordering cycle (`nexusq-control` → `nexusqd`
      → `multi-user.target` → `nexusq-control`) that systemd resolved by **deleting the
      bridge's start job**, so it was enabled but never auto-started; manual
      `systemctl start` took a different path and masked it. `device-google-steelhead`
      pkgrel 15; `nexusq-control` aport pkgrel 2; `nexusqd` pkgrel 2. Full finding +
      journal evidence: `docs/2026-07-01-companion-bridge-boot-enablement.md`.
- [x] **Verified live on hardware** (clean v1.6.3 flash): bridge `active`, answers all
      methods, volume works, LED visualizer still tracks playback, `systemctl
      is-system-running` = running.
- [x] **Reachable over WiFi ✅ DONE 2026-07-01 (v1.6.5).** The bridge was only reachable
      over the USB-gadget net — over WiFi (the app's normal path) it was firewalled off.
      New nftables drop-in `55_nexusq-control.nft` opens TCP 45015 on `wlan*` (mDNS reuses
      the UDP 5353 rule in `60_spotify.nft`); `device-google-steelhead` pkgrel 17. Verified
      live: `getState` answers over WiFi.
- [x] **`setScene`/`listScenes` + breathing themes + app-mute LED ✅ DONE 2026-07-01
      (v1.6.5).** `setTheme` now maps to **just** `breathe R G B` (a breathing override on the
      compositor manual layer, priority 8, always visible) instead of a solid fill; new
      `setScene`/`listScenes` picks one of the 5 music visualisations (`auto` + `scene 0..4`);
      `getState` gained a `scene` field; and the volume/mute path also sends `nexusqd muted
      0|1` so a companion mute lights the device mute LED. `nexusq-control` pkgrel 4,
      `nexusqd` pkgrel 5. The app gained a VISUALIZATION picker. See
      `docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.
- [x] **librespot softvol bootstrap ✅ DONE 2026-07-01 (v1.6.5).** librespot crash-looped on
      a fresh boot (`Could not find Alsa mixer control`) because the `NexusQ` softvol control
      is created lazily on first `nexusq_soft` PCM open (and recreated empty each boot) but
      librespot opens its mixer before the sink; `librespot.service` now bootstraps the
      control with `ExecStartPre=-… aplay -D nexusq_soft …` — also fixes companion volume.
      `device-google-steelhead` pkgrel 17.
- [ ] **follow-on (v1.6.6): unify app + hardware + desktop + Spotify volume/mute.** The
      companion volume/mute act on the ALSA `NexusQ` softvol (the Spotify/librespot stream) +
      the mute LED (`nexusqd muted 0|1`), but do **not** mirror to the **LXQt desktop taskbar**
      volume/mute icon. The physical keys emit `KEY_MUTE`/`KEY_VOLUME*` events the desktop
      catches (→ taskbar + desktop audio) and nexusqd reads (→ mute LED); the app path goes
      straight to the softvol, so app vs desktop can diverge. Investigate whether the desktop
      drives ALSA `Master` vs PulseAudio/PipeWire, and whether emitting `uinput` KEY events or
      driving the canonical control is cleaner. **Not done.**
- [ ] follow-on: transport (play/pause/next) — `unavailable` in v1 (librespot has no
      local transport API); a future backend (e.g. go-librespot HTTP) could fill it in.
