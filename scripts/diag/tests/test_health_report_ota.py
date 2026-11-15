"""Host tests for nq-health-report's update-job findings (device r133+,
nexusq-control r70+, PROTOCOL §12d).

What is being protected: an install job is never killed while it installs, so
one that hangs (a trigger that never returns) holds every install and check
`busy` until someone looks. The report must say when a job runs, warn when it
is stalled or has run for an hour, report a failed one, and warn about a
download cache left behind with no job running -- and stay quiet for a
snapshot from an image without the section.

Run from the repo root:
    python3 -m unittest discover -s scripts/diag/tests -v
"""

import importlib.machinery
import importlib.util
import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("nq_health_report", os.path.join(HERE, "..", "nq-health-report"))
spec = importlib.util.spec_from_loader("nq_health_report", loader)
MOD = importlib.util.module_from_spec(spec)
loader.exec_module(MOD)


def job(state="running", phase="installing", started=1000, updated=1300, stalled=False, error=None, percent=70):
    return {
        "id": "20261115-101500-system",
        "kind": "system",
        "state": state,
        "phase": phase,
        "attempt": 1,
        "startedAt": started,
        "updatedAt": updated,
        "stalled": stalled,
        "progress": {"percent": percent},
        "error": error,
    }


def snapshot(durable=None, live=None, cache_kb=0):
    def block(name, value):
        body = json.dumps(value) if value is not None else "(none)"
        return f"\n--- {name} ---\n{body}\n"

    return (
        "\n==================== UPDATE_JOB ====================\n"
        + block("job", durable)
        + block("live", live)
        + "\n--- units ---\n"
        + f"\n--- cache packages kB ---\n{cache_kb}\n"
        + "\n==================== PSTORE ====================\n(empty)\n"
        + "SNAPSHOT END\n"
    )


def kinds(snap):
    return {k: (sev, msg) for sev, k, msg in MOD.snapshot_update_job(snap)}


class UpdateJobFindings(unittest.TestCase):
    def test_a_running_job_is_info_with_its_live_progress(self):
        k = kinds(snapshot(job(percent=60), job(percent=71)))
        self.assertEqual(k["ota_job"][0], "info")
        self.assertIn("71%", k["ota_job"][1])

    def test_a_stalled_job_is_a_warning(self):
        k = kinds(snapshot(job(), job(stalled=True)))
        self.assertEqual(k["ota_stalled"][0], "warn")

    def test_a_job_running_for_an_hour_is_a_warning(self):
        k = kinds(snapshot(job(started=1000), job(updated=1000 + MOD.OTA_JOB_LONG_S + 60)))
        self.assertEqual(k["ota_long"][0], "warn")
        self.assertIn("61 min", k["ota_long"][1])

    def test_a_job_rebooting_to_finish_is_info(self):
        k = kinds(snapshot(job(phase="rebooting", updated=1000 + 2 * MOD.OTA_JOB_LONG_S)))
        self.assertEqual(k["ota_job"][0], "info")
        self.assertNotIn("ota_long", k)

    def test_a_failed_job_is_reported_with_its_reason(self):
        k = kinds(snapshot(job(state="failed", phase="failed", error="not enough space"), cache_kb=300 * 1024))
        self.assertIn("not enough space", k["ota_failed"][1])
        self.assertEqual(k["ota_cache_left"][0], "warn")

    def test_a_cache_while_a_job_runs_is_the_job_s(self):
        self.assertNotIn("ota_cache_left", kinds(snapshot(job(), cache_kb=300 * 1024)))

    def test_a_done_job_and_an_empty_cache_say_nothing(self):
        self.assertEqual(kinds(snapshot(job(state="done", phase="done"), cache_kb=4)), {})

    def test_an_image_without_the_section_says_nothing(self):
        self.assertEqual(MOD.snapshot_update_job("==================== SYSTEMD ====================\n"), [])

    def test_the_findings_reach_the_report(self):
        rows = [{"t_mono": 100 + 5 * i, "temp_mC": 60000, "freq": 350000} for i in range(12)]
        f, _ = MOD.analyze(rows, [], snapshot(job(), job(stalled=True)))
        self.assertIn("ota_stalled", {x["kind"] for x in f})


if __name__ == "__main__":
    unittest.main()
