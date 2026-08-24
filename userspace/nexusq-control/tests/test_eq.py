"""Tests for the TAS5713 hardware-EQ verbs (PROTOCOL §14).

The EQ writes 3.23 fixed-point biquad coefficients into a 25 W amplifier, so
these tests pin the things a slip would turn into a speaker hazard or a
silently-wrong EQ:

  * the filter math is verified by its measured frequency response (shelves:
    full gain at the band edge, unity at the far edge, half-gain at the corner;
    peaking: full gain at f0, unity far away) — independent of the formulas
    that produced the coefficients;
  * the register packing (3.23, low 26 bits, a1/a2 negated) is compared
    word-for-word against the packing logic of a known-good TAS5713
    implementation (kungpfui/tas5713-biquad);
  * an unstable filter is refused outright, before any I2C write, and so is a
    coefficient that would not fit 3.23 — a wrapped coefficient is worse than a
    declined filter (that is exactly what the 32-bit `max` bug produced);
  * the preamp really attenuates, so an "auto" that promises headroom delivers it;
  * the v1 two-knob config still loads, and v1 `bass_db`/`treble_db` requests
    still work, so the shipped 1.14.0 app keeps working against this daemon.
"""

import cmath
import importlib.machinery
import importlib.util
import json
import math
import os
import struct
import subprocess
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
    """|H| in dB of (b0,b1,b2,a1,a2) at f — evaluated from the transfer function
    directly, so it checks the coefficients, not the code that made them."""
    b0, b1, b2, a1, a2 = coeffs
    z = cmath.exp(-2j * cmath.pi * f / fs)
    h = (b0 + b1 * z + b2 * z * z) / (1 + a1 * z + a2 * z * z)
    return 20 * math.log10(abs(h))


def reference_pack(b, a):
    """Packing logic of kungpfui/tas5713-biquad, reproduced verbatim."""
    fmt = struct.Struct(">i")
    reg = bytearray()
    for b_co in b:
        reg += fmt.pack(int(round(b_co * 2 ** 23)))
        reg[-4] &= 0x03
    for a_co in a:
        reg += fmt.pack(int(round(-a_co * 2 ** 23)))
        reg[-4] &= 0x03
    return [struct.unpack(">I", reg[i:i + 4])[0] for i in range(0, 20, 4)]


def band(kind="peaking", f=1000.0, gain=0.0, q=0.707, enabled=True):
    return {"type": kind, "freq_hz": f, "gain_db": gain, "q": q, "enabled": enabled}


def amixer_ok(calls):
    def fake(*args, timeout=4):
        calls.append(args)
        return subprocess.CompletedProcess([], 0, stdout="ok", stderr="")
    return fake


class TestFilterResponse(unittest.TestCase):
    def test_unity_at_zero_gain(self):
        self.assertEqual(MOD._eq_words(band(gain=0.0)), list(MOD._EQ_UNITY))
        self.assertEqual(MOD._eq_words(band("lowshelf", 100.0, 0.0)),
                         list(MOD._EQ_UNITY))

    def test_disabled_band_is_unity_even_with_gain(self):
        self.assertEqual(MOD._eq_words(band(gain=9.0, enabled=False)),
                         list(MOD._EQ_UNITY))

    def test_low_shelf_response(self):
        for gain in (+6.0, -9.0, +12.0):
            c = MOD._eq_shelf_coeffs("lowshelf", gain, 100.0)
            self.assertAlmostEqual(h_mag_db(c, 1), gain, delta=0.1)        # DC
            self.assertAlmostEqual(h_mag_db(c, 23999), 0.0, delta=0.1)     # Nyquist
            self.assertAlmostEqual(h_mag_db(c, 100.0), gain / 2, delta=0.35)

    def test_high_shelf_response(self):
        for gain in (+6.0, -12.0):
            c = MOD._eq_shelf_coeffs("highshelf", gain, 8000.0)
            self.assertAlmostEqual(h_mag_db(c, 23000), gain, delta=0.25)
            self.assertAlmostEqual(h_mag_db(c, 10), 0.0, delta=0.1)
            self.assertAlmostEqual(h_mag_db(c, 8000.0), gain / 2, delta=0.35)

    def test_peaking_response(self):
        for gain in (+6.0, -6.0, +12.0):
            for f0, q in ((200.0, 1.0), (1000.0, 0.707), (5000.0, 4.0)):
                c = MOD._eq_peak_coeffs(gain, f0, q)
                self.assertAlmostEqual(h_mag_db(c, f0), gain, delta=0.1,
                                       msg=f"{gain} dB @ {f0} Hz Q={q}")
                # far below and far above the band it must not touch anything
                self.assertAlmostEqual(h_mag_db(c, f0 / 40), 0.0, delta=0.3)
                self.assertAlmostEqual(h_mag_db(c, min(23000, f0 * 40)), 0.0,
                                       delta=0.5)

    def test_higher_q_is_narrower(self):
        wide = MOD._eq_peak_coeffs(6.0, 1000.0, 0.5)
        tight = MOD._eq_peak_coeffs(6.0, 1000.0, 4.0)
        # an octave away the tight filter must have fallen off much further
        self.assertLess(h_mag_db(tight, 2000.0), h_mag_db(wide, 2000.0) - 1.0)

    def test_chain_response_sums_the_bands(self):
        bands = MOD._eq_default_bands()
        bands[0]["gain_db"] = 6.0        # low shelf @ 100 Hz
        bands[6]["gain_db"] = -6.0       # high shelf @ 8 kHz
        self.assertAlmostEqual(MOD._eq_response_db(bands, 1.0), 6.0, delta=0.15)
        self.assertAlmostEqual(MOD._eq_response_db(bands, 23000.0), -6.0, delta=0.3)
        self.assertAlmostEqual(MOD._eq_response_db(bands, 1000.0), 0.0, delta=0.6)

    def test_preamp_shifts_the_whole_chain(self):
        bands = MOD._eq_default_bands()
        for f in (50.0, 1000.0, 12000.0):
            flat = MOD._eq_response_db(bands, f, 0.0)
            cut = MOD._eq_response_db(bands, f, -6.0)
            self.assertAlmostEqual(cut - flat, -6.0, delta=1e-6)


class TestHeadroom(unittest.TestCase):
    def test_flat_chain_has_zero_headroom(self):
        self.assertAlmostEqual(MOD._eq_headroom_db(MOD._eq_default_bands()), 0.0,
                               delta=0.05)

    def test_boost_shows_positive_headroom(self):
        bands = MOD._eq_default_bands()
        bands[0]["gain_db"] = 9.0
        self.assertAlmostEqual(MOD._eq_headroom_db(bands), 9.0, delta=0.4)

    def test_auto_preamp_cancels_the_peak(self):
        calls = []
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            bands = MOD._eq_default_bands()
            bands[2]["gain_db"] = 8.0
            with patch.object(MOD, "_amixer", side_effect=amixer_ok(calls)):
                st = MOD.set_eq({"bands": bands, "auto_preamp": True}, path=path)
            self.assertLess(st["preamp_db"], 0.0)
            # after auto-preamp the chain must no longer be able to clip
            self.assertLessEqual(st["headroom_db"], 0.05)


class TestPacking(unittest.TestCase):
    def test_matches_reference_implementation(self):
        cases = [MOD._eq_shelf_coeffs("lowshelf", +6.0, 100.0),
                 MOD._eq_shelf_coeffs("lowshelf", -12.0, 100.0),
                 MOD._eq_shelf_coeffs("highshelf", +4.5, 8000.0),
                 MOD._eq_peak_coeffs(+6.0, 1000.0, 0.707),
                 MOD._eq_peak_coeffs(-9.0, 300.0, 2.0)]
        for b0, b1, b2, a1, a2 in cases:
            ours = MOD._eq_pack((b0, b1, b2, a1, a2))
            self.assertEqual(ours, reference_pack([b0, b1, b2], [a1, a2]))

    def test_words_fit_26_bits(self):
        for gain in (-12.0, -0.5, 0.5, 12.0):
            for kind, f in (("lowshelf", 100.0), ("highshelf", 8000.0),
                            ("peaking", 1000.0)):
                for w in MOD._eq_words(band(kind, f, gain)):
                    self.assertLessEqual(w, 0x03FFFFFF)

    def test_refuses_unstable(self):
        with self.assertRaises(MOD.Err):
            MOD._eq_pack((1.0, 0.0, 0.0, 0.0, 1.0))     # |a2| == 1
        with self.assertRaises(MOD.Err):
            MOD._eq_pack((1.0, 0.0, 0.0, -2.05, 1.05))  # pole at z ~ 1.02

    def test_refuses_out_of_3_23_range(self):
        # 3.23 holds [-4, 4); a coefficient past that must be declined, never
        # wrapped — wrapping is what the 32-bit `max` bug did to the amp.
        with self.assertRaises(MOD.Err):
            MOD._eq_pack((4.5, 0.0, 0.0, 0.0, 0.0))

    def test_preamp_scales_only_the_feed_forward_half(self):
        b = band("peaking", 1000.0, 6.0, 1.0)
        plain = MOD._eq_words(b)
        quiet = MOD._eq_words(b, preamp_lin=0.5)
        for i in range(3):                                  # b0, b1, b2 halve
            self.assertAlmostEqual(_signed(quiet[i]), _signed(plain[i]) / 2,
                                   delta=2)
        for i in (3, 4):                                    # a1, a2 untouched
            self.assertEqual(quiet[i], plain[i])

    def test_preamp_on_a_flat_band_is_a_pure_gain(self):
        w = MOD._eq_words(band(gain=0.0), preamp_lin=0.5)
        self.assertEqual(w, [0x00400000, 0, 0, 0, 0])


def _signed(word):
    return word - (1 << 26) if word >= (1 << 25) else word


class TestApplyAndPersist(unittest.TestCase):
    def test_writes_every_band_on_both_channels(self):
        calls = []
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            with patch.object(MOD, "_amixer", side_effect=amixer_ok(calls)):
                MOD.set_eq({"bass_db": 6.0}, path=path)
            csets = [c for c in calls if c[0] == "cset"]
            names = sorted(c[1] for c in csets)
            self.assertEqual(names, sorted(
                f"name=CH{ch} - Biquad {i}"
                for ch in (1, 2) for i in range(MOD.EQ_BANDS)))
            by_name = {c[1]: c[2] for c in csets}
            for i in range(MOD.EQ_BANDS):          # both channels identical
                self.assertEqual(by_name[f"name=CH1 - Biquad {i}"],
                                 by_name[f"name=CH2 - Biquad {i}"])
                self.assertEqual(len(by_name[f"name=CH1 - Biquad {i}"].split(",")), 5)

    def test_bands_round_trip_and_persist(self):
        calls = []
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            bands = MOD._eq_default_bands()
            bands[3].update(gain_db=-4.5, freq_hz=1200.0, q=2.5)
            with patch.object(MOD, "_amixer", side_effect=amixer_ok(calls)):
                st = MOD.set_eq({"bands": bands}, path=path)
            self.assertEqual(st["bands"][3]["gain_db"], -4.5)
            self.assertEqual(st["bands"][3]["freq_hz"], 1200.0)
            self.assertEqual(st["bands"][3]["q"], 2.5)
            with open(path) as f:
                self.assertEqual(json.load(f)["bands"][3]["freq_hz"], 1200.0)
            self.assertEqual(MOD.get_eq(path)["bands"][3]["gain_db"], -4.5)

    def test_clamps_every_field(self):
        calls = []
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            bands = MOD._eq_default_bands()
            bands[1].update(gain_db=99.0, freq_hz=90000.0, q=500.0)
            bands[2].update(gain_db=-99.0, freq_hz=0.1, q=0.001)
            with patch.object(MOD, "_amixer", side_effect=amixer_ok(calls)):
                st = MOD.set_eq({"bands": bands, "preamp_db": -900.0}, path=path)
            self.assertEqual(st["bands"][1]["gain_db"], MOD.EQ_MAX_DB)
            self.assertEqual(st["bands"][1]["freq_hz"], MOD.EQ_MAX_HZ)
            self.assertEqual(st["bands"][1]["q"], MOD.EQ_MAX_Q)
            self.assertEqual(st["bands"][2]["gain_db"], -MOD.EQ_MAX_DB)
            self.assertEqual(st["bands"][2]["freq_hz"], MOD.EQ_MIN_HZ)
            self.assertEqual(st["bands"][2]["q"], MOD.EQ_MIN_Q)
            self.assertEqual(st["preamp_db"], MOD.EQ_PREAMP_MIN_DB)

    def test_preamp_is_never_positive(self):
        calls = []
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            with patch.object(MOD, "_amixer", side_effect=amixer_ok(calls)):
                st = MOD.set_eq({"preamp_db": 6.0}, path=path)
            self.assertEqual(st["preamp_db"], 0.0)

    def test_rejects_bad_shapes(self):
        for p in ({"bands": "loud"}, {"bands": [{}] * (MOD.EQ_BANDS + 1)},
                  {"bass_db": "loud"}, {"preamp_db": True}):
            with self.assertRaises(MOD.Err):
                MOD.set_eq(p, path="/nonexistent/eq.json")

    def test_garbage_band_falls_back_to_default_not_an_error(self):
        calls = []
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            with patch.object(MOD, "_amixer", side_effect=amixer_ok(calls)):
                st = MOD.set_eq({"bands": ["nonsense", None, 7]}, path=path)
            self.assertEqual(len(st["bands"]), MOD.EQ_BANDS)
            self.assertEqual(st["bands"][0]["freq_hz"],
                             MOD._eq_default_bands()[0]["freq_hz"])

    def test_failed_write_does_not_persist(self):
        def fail(*args, timeout=4):
            return subprocess.CompletedProcess([], 1, stdout="",
                                               stderr="no such control")
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            with patch.object(MOD, "_amixer", side_effect=fail):
                with self.assertRaises(MOD.Err):
                    MOD.set_eq({"bass_db": 3.0}, path=path)
            self.assertFalse(os.path.exists(path))


class TestLegacyCompat(unittest.TestCase):
    """The shipped 1.14.0 app knows only bass_db/treble_db. It must keep working."""

    def test_v1_config_file_migrates(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            with open(path, "w") as f:
                json.dump({"bass_db": 4.0, "treble_db": -2.0}, f)
            st = MOD._eq_load(path)
            lo, hi = MOD._eq_legacy_indices(st["bands"])
            self.assertEqual(st["bands"][lo]["gain_db"], 4.0)
            self.assertEqual(st["bands"][hi]["gain_db"], -2.0)

    def test_view_still_exposes_bass_and_treble(self):
        calls = []
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            with patch.object(MOD, "_amixer", side_effect=amixer_ok(calls)):
                st = MOD.set_eq({"bass_db": 5.0, "treble_db": -3.0}, path=path)
            self.assertEqual(st["bass_db"], 5.0)
            self.assertEqual(st["treble_db"], -3.0)
            self.assertEqual(st["max_bands"], MOD.EQ_BANDS)

    def test_v1_request_leaves_the_other_bands_alone(self):
        calls = []
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eq.json")
            bands = MOD._eq_default_bands()
            bands[3]["gain_db"] = 5.0
            with patch.object(MOD, "_amixer", side_effect=amixer_ok(calls)):
                MOD.set_eq({"bands": bands}, path=path)
                st = MOD.set_eq({"bass_db": 2.0}, path=path)
            self.assertEqual(st["bands"][3]["gain_db"], 5.0)
            self.assertEqual(st["bass_db"], 2.0)


class TestPresets(unittest.TestCase):
    def test_every_preset_is_writable_and_within_limits(self):
        for p in MOD.list_eq_presets()["presets"]:
            self.assertEqual(len(p["bands"]), MOD.EQ_BANDS)
            self.assertLessEqual(p["preamp_db"], 0.0)
            for b in p["bands"]:
                self.assertLessEqual(abs(b["gain_db"]), MOD.EQ_MAX_DB)
                # must actually pack — a preset that cannot be written is a bug
                MOD._eq_words(b)

    def test_flat_preset_is_flat(self):
        flat = next(p for p in MOD.list_eq_presets()["presets"] if p["id"] == "flat")
        self.assertTrue(all(abs(b["gain_db"]) < 0.05 for b in flat["bands"]))

    def test_presets_carry_enough_preamp_not_to_clip(self):
        for p in MOD.list_eq_presets()["presets"]:
            self.assertLessEqual(MOD._eq_headroom_db(p["bands"], p["preamp_db"]),
                                 0.05, msg=p["id"])


class TestUserPresets(unittest.TestCase):
    """Saving your own preset writes a SEPARATE file from the live EQ, so the
    worst a mangled preset list can do is lose presets — never the EQ."""

    def paths(self, d):
        return os.path.join(d, "eq-presets.json"), os.path.join(d, "eq.json")

    def test_save_then_list_returns_it_after_the_builtins(self):
        with tempfile.TemporaryDirectory() as d:
            pp, _ = self.paths(d)
            bands = MOD._eq_default_bands()
            bands[2]["gain_db"] = 4.5
            r = MOD.save_eq_preset({"name": "Vinyl", "bands": bands, "preamp_db": -3.0},
                                   path=pp)
            self.assertEqual(r["id"], "u:vinyl")
            presets = r["presets"]
            builtin = [x for x in presets if x["builtin"]]
            user = [x for x in presets if not x["builtin"]]
            self.assertEqual(len(builtin), len(MOD.EQ_PRESETS))
            self.assertEqual([x["id"] for x in user], ["u:vinyl"])
            # builtins keep their place at the front
            self.assertTrue(all(x["builtin"] for x in presets[:len(builtin)]))
            self.assertEqual(user[0]["label"], "Vinyl")
            self.assertEqual(user[0]["bands"][2]["gain_db"], 4.5)
            self.assertEqual(user[0]["preamp_db"], -3.0)

    def test_it_survives_a_restart(self):
        with tempfile.TemporaryDirectory() as d:
            pp, _ = self.paths(d)
            MOD.save_eq_preset({"name": "Night", "bands": MOD._eq_default_bands()}, path=pp)
            again = MOD.list_eq_presets(path=pp)["presets"]
            self.assertIn("u:night", [x["id"] for x in again])

    def test_saving_the_same_name_replaces_rather_than_duplicates(self):
        with tempfile.TemporaryDirectory() as d:
            pp, _ = self.paths(d)
            b1 = MOD._eq_default_bands()
            b1[0]["gain_db"] = 3.0
            b2 = MOD._eq_default_bands()
            b2[0]["gain_db"] = -3.0
            MOD.save_eq_preset({"name": "Vinyl", "bands": b1}, path=pp)
            r = MOD.save_eq_preset({"name": "vinyl ", "bands": b2}, path=pp)
            user = [x for x in r["presets"] if not x["builtin"]]
            self.assertEqual(len(user), 1)
            self.assertEqual(user[0]["bands"][0]["gain_db"], -3.0)

    def test_no_bands_given_snapshots_the_live_eq(self):
        with tempfile.TemporaryDirectory() as d:
            pp, ep = self.paths(d)
            bands = MOD._eq_default_bands()
            bands[5]["gain_db"] = -6.0
            with patch.object(MOD, "_amixer", side_effect=amixer_ok([])), \
                 patch.object(MOD, "eq_supported", return_value=True):
                MOD.set_eq({"bands": bands, "preamp_db": -2.0}, path=ep)
            r = MOD.save_eq_preset({"name": "Now"}, path=pp, eq_path=ep)
            saved = next(x for x in r["presets"] if x["id"] == "u:now")
            self.assertEqual(saved["bands"][5]["gain_db"], -6.0)
            self.assertEqual(saved["preamp_db"], -2.0)

    def test_delete_removes_only_that_one(self):
        with tempfile.TemporaryDirectory() as d:
            pp, _ = self.paths(d)
            MOD.save_eq_preset({"name": "A", "bands": MOD._eq_default_bands()}, path=pp)
            MOD.save_eq_preset({"name": "B", "bands": MOD._eq_default_bands()}, path=pp)
            r = MOD.delete_eq_preset({"id": "u:a"}, path=pp)
            self.assertEqual([x["id"] for x in r["presets"] if not x["builtin"]], ["u:b"])

    def test_a_builtin_cannot_be_deleted(self):
        with tempfile.TemporaryDirectory() as d:
            pp, _ = self.paths(d)
            # refused for BEING a builtin, not merely for being absent from the
            # user file — otherwise the guard could vanish and nothing would tell
            with self.assertRaises(MOD.Err) as cm:
                MOD.delete_eq_preset({"id": "loudness"}, path=pp)
            self.assertIn("built-in", str(cm.exception))
            with self.assertRaises(MOD.Err):
                MOD.delete_eq_preset({"id": "u:nope"}, path=pp)
            with self.assertRaises(MOD.Err):
                MOD.delete_eq_preset({}, path=pp)

    def test_a_nameless_or_symbol_only_name_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            pp, _ = self.paths(d)
            for bad in ({}, {"name": "   "}, {"name": "***"}, {"name": 7},
                        {"name": "x" * (MOD.EQ_PRESET_NAME_MAX + 1)}):
                with self.assertRaises(MOD.Err, msg=bad):
                    MOD.save_eq_preset(bad, path=pp)

    def test_saved_presets_are_capped(self):
        with tempfile.TemporaryDirectory() as d:
            pp, _ = self.paths(d)
            for i in range(MOD.EQ_USER_PRESET_MAX):
                MOD.save_eq_preset({"name": f"p{i}", "bands": MOD._eq_default_bands()},
                                   path=pp)
            with self.assertRaises(MOD.Err):
                MOD.save_eq_preset({"name": "one too many",
                                    "bands": MOD._eq_default_bands()}, path=pp)
            # ...but replacing an existing one still works at the cap
            MOD.save_eq_preset({"name": "p0", "bands": MOD._eq_default_bands()}, path=pp)

    def test_a_corrupt_file_loses_presets_but_not_the_eq(self):
        with tempfile.TemporaryDirectory() as d:
            pp, ep = self.paths(d)
            with open(pp, "w") as f:
                f.write("{not json at all")
            self.assertEqual([x for x in MOD.list_eq_presets(path=pp)["presets"]
                              if not x["builtin"]], [])
            self.assertEqual(len(MOD.get_eq(ep)["bands"]), MOD.EQ_BANDS)

    def test_out_of_range_stored_values_are_clamped_not_trusted(self):
        with tempfile.TemporaryDirectory() as d:
            pp, _ = self.paths(d)
            bands = MOD._eq_default_bands()
            bands[0]["gain_db"] = 99.0
            with open(pp, "w") as f:
                json.dump({"presets": [{"id": "u:evil", "label": "Evil",
                                        "bands": bands, "preamp_db": -99.0}]}, f)
            got = next(x for x in MOD.list_eq_presets(path=pp)["presets"]
                       if x["id"] == "u:evil")
            self.assertLessEqual(abs(got["bands"][0]["gain_db"]), MOD.EQ_MAX_DB)
            self.assertGreaterEqual(got["preamp_db"], MOD.EQ_PREAMP_MIN_DB)
            MOD._eq_words(got["bands"][0])  # still packable => still writable

    def test_a_saved_preset_is_writable_like_a_builtin(self):
        with tempfile.TemporaryDirectory() as d:
            pp, _ = self.paths(d)
            bands = MOD._eq_default_bands()
            bands[1]["gain_db"] = 11.0
            MOD.save_eq_preset({"name": "Loud", "bands": bands, "preamp_db": -11.0},
                               path=pp)
            got = next(x for x in MOD.list_eq_presets(path=pp)["presets"]
                       if x["id"] == "u:loud")
            for b in got["bands"]:
                MOD._eq_words(b)


class TestRestore(unittest.TestCase):
    def test_flat_config_skips_the_write(self):
        calls = []
        with patch.object(MOD, "_amixer", side_effect=amixer_ok(calls)), \
             patch.object(MOD, "_eq_load", return_value={
                 "bands": MOD._eq_default_bands(), "preamp_db": 0.0}):
            MOD.eq_restore_thread()
        self.assertEqual(calls, [])

    def test_non_flat_config_is_rewritten(self):
        calls = []
        bands = MOD._eq_default_bands()
        bands[0]["gain_db"] = 3.0
        with patch.object(MOD, "_amixer", side_effect=amixer_ok(calls)), \
             patch.object(MOD, "eq_supported", return_value=True), \
             patch.object(MOD, "_eq_load",
                          return_value={"bands": bands, "preamp_db": 0.0}):
            MOD.eq_restore_thread()
        self.assertEqual(len([c for c in calls if c[0] == "cset"]),
                         2 * MOD.EQ_BANDS)


if __name__ == "__main__":
    unittest.main()
