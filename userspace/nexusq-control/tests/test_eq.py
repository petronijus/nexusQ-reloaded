"""Tests for the TAS5713 hardware-EQ verbs (PROTOCOL §14).

The EQ writes 3.23 fixed-point biquad coefficients into a 25 W amplifier, so
these tests pin the three things a slip would turn into a speaker hazard or a
silently-wrong EQ:

  * the shelving math is verified by its measured frequency response
    (full gain at the band edge, unity at the far edge, half-gain at the
    corner) — independent of the formulas that produced the coefficients;
  * the register packing (3.23, low 26 bits, a1/a2 negated) is compared
    word-for-word against the packing logic of a known-good TAS5713
    implementation (kungpfui/tas5713-biquad);
  * an unstable filter is refused outright, before any I2C write.
"""

import cmath
import importlib.machinery
import importlib.util
import json
import math
import os
import struct
import tempfile
import unittest
from unittest.mock import patch

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control_eq",
        importlib.machinery.SourceFileLoader("nexusq_control_eq", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()


def h_mag_db(coeffs, f, fs=48000):
    """|H| in dB of (b0,b1,b2,a1,a2) at frequency f — evaluated from the
    transfer function directly, so it checks the coefficients, not the code
    that made them."""
    b0, b1, b2, a1, a2 = coeffs
    z = cmath.exp(2j * math.pi * f / fs)
    h = (b0 + b1 / z + b2 / z**2) / (1 + a1 / z + a2 / z**2)
    return 20 * math.log10(abs(h))


def reference_pack(b, a):
    """The packing scheme of kungpfui/tas5713-biquad (ba_to_reg), reproduced
    verbatim as the independent ground truth: 3.23 two's complement big-endian
    words, top 6 bits masked, a1/a2 NEGATED, a0 omitted."""
    reg = bytearray()
    fmt = struct.Struct(">i")
    for b_co in b:
        reg += fmt.pack(int(round(b_co * 2 ** 23)))
        reg[-4] &= 0x03
    for a_co in a:
        reg += fmt.pack(int(round(-a_co * 2 ** 23)))
        reg[-4] &= 0x03
    return [struct.unpack(">I", reg[i:i + 4])[0] for i in range(0, 20, 4)]


class TestShelfResponse(unittest.TestCase):
    def test_unity_at_zero_gain(self):
        self.assertEqual(MOD._eq_words("bass", 0.0), list(MOD._EQ_UNITY))
        self.assertEqual(MOD._eq_words("treble", 0.0), list(MOD._EQ_UNITY))

    def test_low_shelf_response(self):
        for gain in (+6.0, -9.0, +12.0):
            c = MOD._eq_shelf_coeffs("low", gain, MOD.EQ_BASS_HZ)
            self.assertAlmostEqual(h_mag_db(c, 1), gain, delta=0.1)       # DC
            self.assertAlmostEqual(h_mag_db(c, 23999), 0.0, delta=0.1)    # Nyquist
            self.assertAlmostEqual(h_mag_db(c, MOD.EQ_BASS_HZ), gain / 2,
                                   delta=0.35)                            # corner

    def test_high_shelf_response(self):
        for gain in (+6.0, -12.0):
            c = MOD._eq_shelf_coeffs("high", gain, MOD.EQ_TREBLE_HZ)
            self.assertAlmostEqual(h_mag_db(c, 23000), gain, delta=0.25)
            self.assertAlmostEqual(h_mag_db(c, 10), 0.0, delta=0.1)
            self.assertAlmostEqual(h_mag_db(c, MOD.EQ_TREBLE_HZ), gain / 2,
                                   delta=0.35)


class TestPacking(unittest.TestCase):
    def test_matches_reference_implementation(self):
        for kind, gain, f0 in (("low", +6.0, 100.0), ("low", -12.0, 100.0),
                               ("high", +4.5, 8000.0), ("high", -7.0, 8000.0)):
            b0, b1, b2, a1, a2 = MOD._eq_shelf_coeffs(kind, gain, f0)
            ours = MOD._eq_pack((b0, b1, b2, a1, a2))
            ref = reference_pack([b0, b1, b2], [a1, a2])
            self.assertEqual(ours, ref, f"packing diverges for {kind} {gain} dB")

    def test_words_fit_26_bits(self):
        for gain in (-12.0, -0.5, 0.5, 12.0):
            for w in MOD._eq_words("bass", gain) + MOD._eq_words("treble", gain):
                self.assertLessEqual(w, 0x03FFFFFF)

    def test_refuses_unstable(self):
        # poles on/outside the unit circle must never reach the amp
        with self.assertRaises(MOD.Err):
            MOD._eq_pack((1.0, 0.0, 0.0, 0.0, 1.0))     # |a2| == 1
        with self.assertRaises(MOD.Err):
            MOD._eq_pack((1.0, 0.0, 0.0, -2.05, 1.05))  # pole at z ~ 1.02


class TestApplyAndPersist(unittest.TestCase):
    def _amixer_ok(self, calls):
        import subprocess

        def fake(*args, timeout=4):
            calls.append(args)
            return subprocess.CompletedProcess([], 0, stdout="ok", stderr="")
        return fake

    def test_set_eq_writes_both_channels_and_persists(self):
        calls = []
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            with patch.object(MOD, "_amixer", side_effect=self._amixer_ok(calls)):
                st = MOD.set_eq({"bass_db": 6.0, "treble_db": -3.0}, path=path)
            csets = [c for c in calls if c[0] == "cset"]
            names = sorted(c[1] for c in csets)
            self.assertEqual(names, ["name=CH1 - Biquad 0", "name=CH1 - Biquad 1",
                                     "name=CH2 - Biquad 0", "name=CH2 - Biquad 1"])
            for c in csets:
                self.assertEqual(len(c[2].split(",")), 5)
            # CH1 and CH2 of the same knob get identical coefficients
            by_name = {c[1]: c[2] for c in csets}
            self.assertEqual(by_name["name=CH1 - Biquad 0"],
                             by_name["name=CH2 - Biquad 0"])
            self.assertEqual(st["bass_db"], 6.0)
            self.assertEqual(st["treble_db"], -3.0)
            with open(path) as f:
                self.assertEqual(json.load(f),
                                 {"bass_db": 6.0, "treble_db": -3.0})

    def test_set_eq_clamps_to_range(self):
        calls = []
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            with patch.object(MOD, "_amixer", side_effect=self._amixer_ok(calls)):
                st = MOD.set_eq({"bass_db": 40, "treble_db": -99.9}, path=path)
            self.assertEqual(st["bass_db"], MOD.EQ_MAX_DB)
            self.assertEqual(st["treble_db"], -MOD.EQ_MAX_DB)

    def test_set_eq_rejects_non_numbers(self):
        for bad in ("loud", None, True, [6]):
            with self.assertRaises(MOD.Err):
                MOD.set_eq({"bass_db": bad}, path="/nonexistent/eq.json")

    def test_set_eq_partial_update_keeps_other_knob(self):
        calls = []
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            with patch.object(MOD, "_amixer", side_effect=self._amixer_ok(calls)):
                MOD.set_eq({"bass_db": 5.0}, path=path)
                st = MOD.set_eq({"treble_db": 2.0}, path=path)
            self.assertEqual(st["bass_db"], 5.0)
            self.assertEqual(st["treble_db"], 2.0)

    def test_failed_write_does_not_persist(self):
        import subprocess

        def fail(*args, timeout=4):
            return subprocess.CompletedProcess([], 1, stdout="", stderr="no such control")
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            with patch.object(MOD, "_amixer", side_effect=fail):
                with self.assertRaises(MOD.Err):
                    MOD.set_eq({"bass_db": 6.0}, path=path)
            self.assertFalse(os.path.exists(path))

    def test_eq_load_ignores_garbage(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            for garbage in ("not json", "null", '{"bass_db": "x", "treble_db": 99}'):
                with open(path, "w") as f:
                    f.write(garbage)
                self.assertEqual(MOD._eq_load(path),
                                 {"bass_db": 0.0, "treble_db": 0.0})


if __name__ == "__main__":
    unittest.main()
