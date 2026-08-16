#!/usr/bin/env python3
"""Read the Nexus Q's idle OPP residency out of Home Assistant history.

This is the STANDING GOAL measurement tool (PLAN.md): what share of the time
the MPU spends at each OPP while the Q sits idle. It is a *passive* read — it
touches Home Assistant only, never the device, because an open ssh session
pushes the die to 74-79 C within seconds and drags the OPP up with it
(docs/2026-07-13, Finding 1).

Chain: kernel `time_in_state` deltas -> nq-healthd `opp_ms` -> nexusq-mqtt
rolling 1 h window -> MQTT discovery -> `sensor.nexus_q_time_at_*_mhz` -> here.
Never read the OPP off healthd's `freq` field: that is a spot read taken inside
healthd's own busy tick and is observer-biased by ~19 pp
(docs/2026-08-11-overnight-telemetry-analysis.md 4).

Usage:
    scripts/diag/ha-opp-window.py --days 3.5
    scripts/diag/ha-opp-window.py --days 3.5 --since '2026-08-13 12:00'

`--since` marks the start of the window you consider clean (e.g. after the last
ssh session or the OTA that is being A/B'd); everything before it is still
fetched and reported, but the headline figures come from the clean part.

Needs `op-cache` for the HA token (1Password item "Homeassistant API Token").
"""
import argparse
import json
import re
import statistics
import subprocess
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

HA = "http://homeassistant.home.arpa:8123"
CEST = timezone(timedelta(hours=2))

OPP_MHZ = (350, 700, 920, 1200)
OPP_MV = {350: 1025, 700: 1200, 920: 1313, 1200: 1380}
OPP = [f"sensor.nexus_q_time_at_{m}_mhz" for m in OPP_MHZ]
EXTRA = ["sensor.nexus_q_die_temperature", "sensor.nexus_q_uptime"]
SVC = [
    "binary_sensor.nexus_q_spotify_connect",
    "binary_sensor.nexus_q_airplay",
    "binary_sensor.nexus_q_roon",
    "binary_sensor.nexus_q_usb_audio",
    "binary_sensor.nexus_q_led_ring",
    "binary_sensor.nexus_q_health_sampler",
]

NUMERIC = re.compile(r"^-?[\d.]+$")


def ha_token():
    return subprocess.check_output(
        ["op-cache", "Homeassistant API Token", "credential"], text=True
    ).strip()


def fetch(entities, start, end, token, chunk_hours=6):
    """Fetch history as {entity_id: [(datetime, state_str), ...]}.

    HA's history endpoint SILENTLY TRUNCATES a long multi-entity response: a
    single 3.5 d call for 12 entities returned only the first 24 h and looked
    perfectly valid. So walk the window in chunks and merge, de-duplicating the
    boundary sample each chunk repeats.
    """
    series, seen = {}, set()
    t0 = start
    while t0 < end:
        t1 = min(t0 + timedelta(hours=chunk_hours), end)
        url = (
            f"{HA}/api/history/period/{urllib.parse.quote(t0.isoformat())}"
            f"?end_time={urllib.parse.quote(t1.isoformat())}"
            f"&filter_entity_id={','.join(entities)}"
            f"&minimal_response&no_attributes"
        )
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        for block in json.load(urllib.request.urlopen(req, timeout=120)):
            if not block:
                continue
            eid = block[0]["entity_id"]
            for s in block:
                ts = s.get("last_changed") or s.get("last_updated")
                if (eid, ts) in seen:
                    continue
                seen.add((eid, ts))
                series.setdefault(eid, []).append(
                    (datetime.fromisoformat(ts).astimezone(CEST), s["state"])
                )
        t0 = t1
    for pts in series.values():
        pts.sort()
    return series


def nums(series, eid, since=None):
    return [
        (t, float(s))
        for t, s in series.get(eid, [])
        if NUMERIC.match(s) and (since is None or t >= since)
    ]


def residency(series, since, label):
    print(f"\n--- OPP residency, {label} ---")
    print(f"{'OPP':<12} {'mean%':>7} {'median%':>8} {'p05%':>6} {'min%':>6} {'max%':>6} {'n':>6}")
    total = 0.0
    for m in OPP_MHZ:
        v = sorted(x for _, x in nums(series, f"sensor.nexus_q_time_at_{m}_mhz", since))
        if not v:
            continue
        total += statistics.fmean(v)
        print(
            f"{f'{m} MHz':<12} {statistics.fmean(v):7.2f} {statistics.median(v):8.2f} "
            f"{v[len(v) // 20]:6.2f} {v[0]:6.1f} {v[-1]:6.1f} {len(v):6d}"
            f"   {OPP_MV[m]} mV"
        )
    print(f"{'sum':<12} {total:7.2f}   (sanity: should be ~100)")
    t = [x for _, x in nums(series, "sensor.nexus_q_die_temperature", since)]
    if t:
        print(
            f"die temp     mean {statistics.fmean(t):.1f} C   "
            f"min {min(t):.1f}   max {max(t):.1f}   n={len(t)}"
        )


def conditions(series):
    print("--- conditions (were we actually idle?) ---")
    for eid in SVC:
        pts = series.get(eid, [])
        changes = [(t, s) for i, (t, s) in enumerate(pts) if i == 0 or s != pts[i - 1][1]]
        tail = "; ".join(f"{t:%m-%d %H:%M}={s}" for t, s in changes[-6:])
        print(f"{eid.split('.')[1]:<34} n={len(pts):<5d} {tail}")
    up = nums(series, "sensor.nexus_q_uptime")
    if up:
        verdict = "NO reboot" if up[-1][1] > up[0][1] else "REBOOT inside window"
        print(f"\nuptime: {up[0][1] / 86400:.2f} d -> {up[-1][1] / 86400:.2f} d ({verdict})")


def outliers(series):
    """Cluster the contaminated samples by hour — they are nearly always us."""
    print("\n--- outliers (expect them to coincide with your own ssh sessions) ---")
    checks = [
        ("sensor.nexus_q_time_at_350_mhz", "opp350 < 60 %", lambda x: x < 60, min),
        ("sensor.nexus_q_time_at_1200_mhz", "opp1200 > 3 %", lambda x: x > 3, max),
        ("sensor.nexus_q_die_temperature", "die > 65 C", lambda x: x > 65, max),
    ]
    for eid, label, bad, worst in checks:
        hits = [(t, x) for t, x in nums(series, eid) if bad(x)]
        if not hits:
            print(f"{label:<16} none")
            continue
        hours = {}
        for t, x in hits:
            hours.setdefault(t.strftime("%m-%d %H"), []).append(x)
        span = f"{hits[0][0]:%m-%d %H:%M} .. {hits[-1][0]:%m-%d %H:%M}"
        print(f"{label:<16} n={len(hits):<5d} {span}")
        for h in sorted(hours):
            print(f"    {h}h  n={len(hours[h]):<4d} worst={worst(hours[h])}")


def hourly(series):
    print("\n--- hourly mean opp350 (CEST) ---")
    buckets, temps = {}, {}
    for t, v in nums(series, OPP[0]):
        buckets.setdefault(t.replace(minute=0, second=0, microsecond=0), []).append(v)
    for t, v in nums(series, "sensor.nexus_q_die_temperature"):
        temps.setdefault(t.replace(minute=0, second=0, microsecond=0), []).append(v)
    for h in sorted(buckets):
        mean = statistics.fmean(buckets[h])
        temp = f"{statistics.fmean(temps[h]):4.1f} C" if h in temps else "  -   "
        print(f"{h:%m-%d %H}h  {mean:5.1f} %  n={len(buckets[h]):3d}  {temp}  {'#' * int(mean / 2)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=float, default=3.5, help="how far back to fetch")
    ap.add_argument("--since", help="start of the CLEAN window, 'YYYY-MM-DD HH:MM' CEST")
    ap.add_argument("--no-hourly", action="store_true", help="skip the hourly table")
    args = ap.parse_args()

    now = datetime.now(timezone.utc)
    start = now - timedelta(days=args.days)
    since = None
    if args.since:
        since = datetime.strptime(args.since, "%Y-%m-%d %H:%M").replace(tzinfo=CEST)

    series = fetch(OPP + EXTRA + SVC, start, now, ha_token())

    print(f"=== window {start.astimezone(CEST):%Y-%m-%d %H:%M} -> "
          f"{now.astimezone(CEST):%Y-%m-%d %H:%M} CEST ({args.days} d) ===\n")
    conditions(series)
    residency(series, None, "full window")
    if since:
        residency(series, since, f"clean window (from {since:%m-%d %H:%M} CEST)")
    outliers(series)
    if not args.no_hourly:
        hourly(series)


if __name__ == "__main__":
    main()
