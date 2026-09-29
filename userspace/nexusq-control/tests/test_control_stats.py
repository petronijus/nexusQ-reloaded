"""The bridge's counters for nq-healthd (control r58, device r119).

health.jsonl records `ambient_wakes` and `tap_fixes` by reading the file this
class keeps in the bridge's RuntimeDirectory; nq-healthd parses `key value`
lines with strstr/atoll (tests/test_accounting.c on its side). Pinned: that
format, that a reader never sees a half-written file, and that a counter which
cannot be written never takes the bridge down with it.
"""

import importlib.machinery
import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control_stats", importlib.machinery.SourceFileLoader("nexusq_control_stats", DAEMON)
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()


class TestControlStats(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "stats")

    def read(self):
        with open(self.path) as f:
            return f.read()

    def test_starts_at_zero_in_the_healthd_format(self):
        MOD.ControlStats(self.path)
        self.assertEqual(self.read(), "ambient_wakes 0\ntap_fixes 0\n")

    def test_bumps_are_written_at_once(self):
        s = MOD.ControlStats(self.path)
        s.bump("ambient_wakes")
        s.bump("ambient_wakes")
        s.bump("tap_fixes")
        self.assertEqual(self.read(), "ambient_wakes 2\ntap_fixes 1\n")
        self.assertFalse(os.path.exists(self.path + ".tmp"))  # replaced, not left

    def test_an_unwritable_path_costs_nothing(self):
        s = MOD.ControlStats(os.path.join(self.tmp.name, "no", "such", "dir", "stats"))
        s.bump("ambient_wakes")  # must not raise
        self.assertEqual(s.counts["ambient_wakes"], 1)


if __name__ == "__main__":
    unittest.main()
