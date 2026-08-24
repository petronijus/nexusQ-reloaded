#!/usr/bin/env python3
"""Benchmark libspeexdsp builds on the exact resampling PulseAudio does.

WHY THIS EXISTS (2026-08-24): measuring a resampler change *inside* PulseAudio is
worthless on this device. `module-loopback`'s rate controller wanders — 48003 Hz
after a day of running, exactly 48000 Hz for a while after a restart — and speex
takes a COMPLETELY DIFFERENT code path per ratio (see below). So two in-situ
samples taken minutes apart are measuring different workloads, and the difference
swamps the thing under test. Chasing that cost a wrong conclusion once already.

This drives each .so directly through ctypes at a FIXED ratio, so the only
variable is the library.

⚠️ It also PINS THE CPU FREQUENCY (governor -> powersave, 350 MHz) for the run.
Without that the numbers are worthless in a different way: the benchmark itself
drags the clock up, the die throttles, and ns/frame then depends on which OPP the
sample happened to land on. Three unpinned runs of this same comparison reported
0.75x, 0.95x and 1.26x for the SAME pair of libraries; pinned, two runs agreed to
within 1.5 %. On the way out it restores the governor AND the `conservative`
tunables, because switching governor RESETS them — that silently reverted
down_threshold 60 -> 20 once.

The ratio's DENOMINATOR picks the inner loop:
  * small denominator (1/1, 147/160)  -> `resampler_basic_direct_single`, which
    is what speexdsp's hand-written NEON assembly accelerates;
  * huge denominator (16000/16001, the USB drift case) -> too many filter phases
    for the direct table, so it falls to the INTERPOLATE path, which has NO NEON
    implementation.
That is why a NEON build is 1.48x on Spotify and a wash on USB silence.

Usage:
    bench-speex-resampler.py [iters] [label=/path/to/libspeexdsp.so ...]

With no libraries given it benchmarks the installed one. Example:
    bench-speex-resampler.py 150 alpine=/tmp/alpine.so ours=/usr/lib/libspeexdsp.so.1.5.2
"""
import ctypes
import sys
import time

CH = 2
QUALITY = 1          # PA's `resample-method = auto` resolves to speex-float-1
FRAMES = 1200        # one TAS5713 period (25 ms @ 48 kHz)

# (label, in_rate, out_rate) — the three ratios that actually occur on this box.
CASES = [
    ("48000 -> 48003  (USB drift, the idle case)", 48000, 48003),
    ("48000 -> 48000  (1:1)",                      48000, 48000),
    ("44100 -> 48000  (Spotify, real playback)",   44100, 48000),
]


def bench(path, in_rate, out_rate, iters):
    """ns per frame, best-of-5 (the device is noisy and thermally throttled)."""
    lib = ctypes.CDLL(path)
    lib.speex_resampler_init.restype = ctypes.c_void_p
    lib.speex_resampler_init.argtypes = [ctypes.c_uint, ctypes.c_uint,
                                         ctypes.c_uint, ctypes.c_int,
                                         ctypes.POINTER(ctypes.c_int)]
    proc = lib.speex_resampler_process_interleaved_float
    proc.restype = ctypes.c_int
    proc.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                     ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_float),
                     ctypes.POINTER(ctypes.c_uint)]

    err = ctypes.c_int(0)
    st = lib.speex_resampler_init(CH, in_rate, out_rate, QUALITY,
                                  ctypes.byref(err))
    if not st or err.value != 0:
        raise SystemExit(f"{path}: resampler init failed (err={err.value})")

    inbuf = (ctypes.c_float * (FRAMES * CH))()
    outbuf = (ctypes.c_float * (FRAMES * CH * 2))()
    # Deliberately NOT silence: an all-zero buffer could hit a denormal or
    # early-out path and flatter the result.
    for i in range(FRAMES * CH):
        inbuf[i] = ((i * 2654435761) % 20011) / 20011.0 - 0.5

    def run(n):
        for _ in range(n):
            il = ctypes.c_uint(FRAMES)
            ol = ctypes.c_uint(FRAMES * 2)
            proc(st, inbuf, ctypes.byref(il), outbuf, ctypes.byref(ol))

    run(20)                                # warm up: page-ins + first filter build
    best = None
    for _ in range(5):
        t0 = time.perf_counter()
        run(iters)
        dt = time.perf_counter() - t0
        if best is None or dt < best:
            best = dt
    return best / (iters * FRAMES) * 1e9


CPUFREQ = "/sys/devices/system/cpu/cpufreq"


def _read(path, default=None):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return default


def _write(path, value):
    try:
        with open(path, "w") as fh:
            fh.write(str(value))
        return True
    except OSError:
        return False


def pin_cpu():
    """governor -> powersave. Returns state to hand back to restore_cpu()."""
    gov_path = f"{CPUFREQ}/policy0/scaling_governor"
    gov = _read(gov_path)
    if gov is None:
        print("  ! no cpufreq policy0 — results will be governor noise", file=sys.stderr)
        return None
    # Snapshot the conservative tunables FIRST: changing governor resets them.
    knobs = {k: _read(f"{CPUFREQ}/conservative/{k}")
             for k in ("down_threshold", "up_threshold", "sampling_rate",
                       "ignore_nice_load")}
    if not _write(gov_path, "powersave"):
        print("  ! cannot set governor (need root?) — results will be noisy",
              file=sys.stderr)
        return None
    time.sleep(2)
    print(f"  [cpu pinned: {_read(f'{CPUFREQ}/policy0/scaling_cur_freq')} kHz]")
    return gov, knobs


def restore_cpu(state):
    if not state:
        return
    gov, knobs = state
    _write(f"{CPUFREQ}/policy0/scaling_governor", gov)
    time.sleep(1)
    # Re-apply the tunables: the governor switch above wiped them back to
    # defaults, which is how a measured down_threshold=60 silently became 20.
    for k, v in knobs.items():
        if v is not None:
            _write(f"{CPUFREQ}/conservative/{k}", v)
    back = {k: _read(f"{CPUFREQ}/conservative/{k}") for k in knobs}
    print(f"  [cpu restored: governor={_read(f'{CPUFREQ}/policy0/scaling_governor')} "
          + " ".join(f"{k}={v}" for k, v in back.items() if v is not None) + "]")


def main():
    argv = sys.argv[1:]
    iters = 150
    if argv and argv[0].isdigit():
        iters, argv = int(argv[0]), argv[1:]
    libs = [tuple(a.split("=", 1)) for a in argv if "=" in a] or \
           [("installed", "/usr/lib/libspeexdsp.so.1.5.2")]

    state = pin_cpu()
    try:
        _run_cases(libs, iters)
    finally:
        restore_cpu(state)


def _run_cases(libs, iters):
    for label, in_rate, out_rate in CASES:
        print(f"\n=== {label} ===")
        res = {}
        for name, path in libs:
            try:
                res[name] = bench(path, in_rate, out_rate, iters)
            except OSError as e:
                print(f"  {name:22s} SKIP ({e})")
                continue
            print(f"  {name:22s} {res[name]:8.1f} ns/frame")
        if len(res) > 1:
            base_name, base = next(iter(res.items()))
            for name, ns in list(res.items())[1:]:
                print(f"  -> {name:20s} {base / ns:.2f}x "
                      f"{'faster' if ns < base else 'SLOWER'} than {base_name}")


if __name__ == "__main__":
    main()
