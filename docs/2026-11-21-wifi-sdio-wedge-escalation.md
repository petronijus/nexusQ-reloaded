# 2026-11-21 — the Wi-Fi chip that stopped answering, and the watchdog that could only ask NetworkManager

## What happened

The Prague Q vanished from the network on **2026-11-18 08:02 CET** and stayed
dark for three days, with power on and the system running (found 2026-11-21
when it was power-cycled by hand: its journal ran to 09:38 that morning).

- Boot 2026-11-16 18:53, uptime 37 h, signal -20 dBm, health fine.
- 08:02:19 the first line: `brcmfmac: brcmf_sdio_bus_rxctl: resumed on timeout`,
  then `-110` (timeout) on every command to the chip — `BRCMF_C_GET_ASSOCLIST`,
  `GET STA INFO`, `brcmf_run_escan`. 4 699 `scan error (-110)` lines by the end.
  The BCM4330 firmware stopped answering on the SDIO bus. The radio had been at
  -20 dBm the minute before: this is the chip, not the air.
- `nexusq-wifi-watchdog` did notice. In `wifi-watchdog.jsonl`: three `bad`
  checks, a `heal` at t=133826 (`nmcli device disconnect/connect`), `assoc:no`,
  then a `reconnect` every ~212 s for three days — about 1 200 of them, every
  one `assoc:no`. Home Assistant went `unavailable` at 07:04 UTC.

Not the 2026-08-30 failure (an nmcli connect that raced an empty scan cache)
and not the 2026-09-23 unicast wedge (fixed by firmware r3): the first
left NetworkManager unable to reconnect a healthy chip, the second left the
chip associated with TX dead. This one left the chip unreachable by the driver.
**Why the firmware hung at 08:02 is unknown** — the kernel log has no event
before it. The fix below does not depend on knowing.

## Root cause of the three days

Every repair the watchdog had was a call to NetworkManager. NetworkManager
cannot talk to a chip the driver cannot talk to, so the ladder had one rung and
the watchdog stood on it for three days. Nothing escalated, nothing rebooted.

## The fix (device r134): a repair ladder

`pmos/device-google-steelhead/nexusq-wifi-watchdog`, job 5 in its header. One
rung per **failed** repair; a repair that leaves a usable link, or any healthy
check, drops back to the bottom.

| rung | what | after |
|------|------|-------|
| soft | the existing `nmcli` bounce / reconnect | — |
| reset | `modprobe -r brcmfmac`, unbind + rebind the SDIO host (`480d5000.mmc`, whose `bcm4330-pwrseq` pulses the chip's reset line), `modprobe brcmfmac`, connect | 2 failed soft repairs |
| reboot | `systemctl reboot` | 2 failed resets |

The reboot is guarded, because a Q that cannot be fixed must not reboot-loop and
one reachable another way is not worth rebooting:

- no default route over another interface (ethernet, USB gadget);
- at least 600 s of uptime;
- fewer than 3 reboots in a row. The count is in
  `/var/lib/nexusq/persist/wifi-watchdog-reboots`, written *before* going down,
  and cleared after 20 healthy checks (~10 min).

The boot after a watchdog reboot starts with `repairs=1`, `last_kind=reboot`,
so Home Assistant's "WiFi repairs" counter shows it (the state file is in
tmpfs and would otherwise read 0 on the new boot).

Timeline of an outage like this one: ~7 min of soft repairs, then up to ~7 min
of resets, then the reboot. A chip reset on its own should end most wedges
within the first 90 s of the second stage.

Environment overrides: `NQ_WIFI_RESET_AFTER`, `NQ_WIFI_REBOOT_AFTER`,
`NQ_WIFI_MIN_UPTIME`, `NQ_WIFI_MAX_REBOOTS`, `NQ_WIFI_OK_TO_CLEAR`,
`NQ_PERSIST`, `NQ_WIFI_MMC`.

## Verification

- `tests/test_wifi_watchdog_escalation.sh` — 23 checks on the ladder, the
  reboot guard and the other-route test (the functions are extracted from the
  script by their `TESTABLE` markers). The other four watchdog suites still pass.
- **On the Prague Q, 2026-11-21 09:46**: the new script run with `BADLOSS=0`,
  `RESET_AFTER=0` so every check counted as bad and the first repair went
  straight to the reset rung. Two full chip resets: kernel `mmc4: card 0001
  removed` → `new high speed SDIO card` → firmware `5.90.125` loaded →
  associated, gateway reachable, in **39 s and 37 s**. The third was cut off
  by the end of the test (the box came back on its own; wlan0 stayed up).
  A forced run with the reboot rung and the other-route guard live was not
  done: a reboot is not something to trigger on the only unit within reach.
- Installed by hand on the Prague Q (the r131 script is in `/root/nexusq-wifi-watchdog.r131`
  there); running, `repairs: 0`.
- `test_wifi_watchdog_smoke.sh` (Alpine under docker) could not run: the Docker
  daemon was not running on the MacBook. It needs a run on a machine with Docker.

## Still open

- **Cottage Q** has no r134: it comes with the next system update.
- The first *natural* wedge will tell whether the reset rung alone is enough
  (expected) or the reboot rung gets used; look for `chip_reset` and `reboot`
  events in `wifi-watchdog.jsonl`.
- Why the firmware hangs at all. A hang after 37 h at -20 dBm with a quiet
  link points at the firmware/SDIO stack; nothing was captured. If it recurs,
  grab `nq-collect` *before* the reset (the log of the first 60 s is the
  evidence) — the ladder resets within ~7 min, so there is time.
