"""Host tests for nq-health-report reading a log a power cut tore.

What is being protected: the record after the cut. ext4 leaves the tail of a
log written during a power cut as a run of NULs with no newline, and nq-healthd
before device r131 appended the next boot's first record to that line
(health.jsonl, 2026-10-14). The NULs must not cost the record behind them.

Run from the repo root:
    python3 -m unittest discover -s scripts/diag/tests -v
"""

import importlib.machinery
import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("nq_health_report", os.path.join(HERE, "..", "nq-health-report"))
spec = importlib.util.spec_from_loader("nq_health_report", loader)
MOD = importlib.util.module_from_spec(spec)
loader.exec_module(MOD)


class TestTornLog(unittest.TestCase):
    def load(self, data):
        with tempfile.NamedTemporaryFile("wb", suffix=".jsonl", delete=False) as fh:
            fh.write(data)
        self.addCleanup(os.unlink, fh.name)
        return MOD.load_jsonl(fh.name)

    def test_record_behind_the_nuls_is_kept(self):
        rows = self.load(b'{"t_mono":8746}\n' + b"\0" * 2664 + b'{"t_mono":27}\n{"t_mono":32}\n')
        self.assertEqual([r["t_mono"] for r in rows], [8746, 27, 32])

    def test_a_line_of_only_nuls_is_skipped(self):
        rows = self.load(b'{"t_mono":1}\n' + b"\0" * 16 + b'\n{"t_mono":2}\n')
        self.assertEqual([r["t_mono"] for r in rows], [1, 2])


if __name__ == "__main__":
    unittest.main()
