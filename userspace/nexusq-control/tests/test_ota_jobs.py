"""Tests for OTA jobs (PROTOCOL §12d, docs/2026-11-15-ota-jobs.md).

What is pinned:
- A job is three apk processes -- plan (`--simulate -vv`), download
  (`cache download`), install (`upgrade` from the cache) -- run against a fake
  apk that writes a real --progress-fd. Their log and progress lines become the
  job's progress; a line of another phase is ignored and the phase only moves
  forward; the overall percent never goes back.
- The phases are recorded durably in order; the ring shows the download and
  the install in their own colours, then green (or red), then the theme; the
  result is applied (restarts, the bridge last and only after the job reads
  done; a reboot when base libc/init changed, recorded as `rebooting` first).
- Only the download is ever stopped (a stall, a shutdown); the install is never
  signalled, a shutdown waits for it and leaves the job for the next boot, and
  the runner never returns while apk runs, even when the disk fails under it.
- Room: the download, the growth apk reports and a margin, checked before the
  download starts. The package lists are tried again; a cache that holds lists
  goes on with them.
- The bridge's side: a second install is refused, an interrupted job is resumed
  (at most OTA_MAX_ATTEMPTS times), never while its unit may still run, a job
  interrupted while rebooting is done, progress is told only when something
  visible changed, and the end is told once, also across a bridge restart.
"""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest
from unittest.mock import patch

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON)
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()

FAKE_APK = textwrap.dedent(
    """\
    import json, os, sys, time
    plan = json.load(open(os.environ["FAKE_APK_PLAN"]))
    args = sys.argv[1:]
    with open(plan["argv_log"], "a") as f:
        f.write(json.dumps(args) + "\\n")

    def steps(name):
        fd = int(args[args.index("--progress-fd") + 1]) if "--progress-fd" in args else None
        for kind, arg in plan.get(name, []):
            if kind == "log":
                print(arg, flush=True)
            elif kind == "prog":
                os.write(fd, (arg + "\\n").encode())
            elif kind == "sleep":
                time.sleep(arg)
        open(plan["argv_log"] + "." + name + ".finished", "w").close()
        sys.exit(plan.get(name + "_rc", 0))

    if "update" in args:
        n = len(open(plan["argv_log"]).read().count("update") * "x")
        rcs = plan.get("update_rc", [0])
        sys.exit(rcs[min(n, len(rcs)) - 1])
    if "info" in args:
        print("linux-google-steelhead-6.18.48-r17")
        sys.exit(0)
    if "--simulate" in args:
        print(plan.get("simulate", ""))
        sys.exit(plan.get("simulate_rc", 0))
    if "cache" in args and "purge" in args:
        sys.exit(0)
    if "fetch" in args:
        steps("download")
    if "upgrade" in args:
        steps("install")
    sys.exit(0)
    """
)

W = 64 * 1024  # apk's per-package progress weight


def dl(done_bytes, done_pkgs, total_bytes, total_pkgs):
    return f"{done_bytes + done_pkgs * W}/{total_bytes + total_pkgs * W} fetch"


def inst(done, total):
    return f"{done}/{total} install"


SIMULATE = textwrap.dedent(
    """\
    The following packages will be upgraded:
      nexusqd nexusq-control
    Need to download 2.9 MiB of packages.
    After this operation, 16 KiB of additional disk space will be used.
    (1/2) Upgrading nexusqd (0.1.0-r28 -> 0.1.0-r29)
    (2/2) Upgrading nexusq-control (0.1.0-r69 -> 0.1.0-r70)
    OK: 2136.8 MiB in 998 packages"""
)
DOWNLOAD = [
    ("log", "Downloading nexusqd-0.1.0-r29"),
    ("prog", dl(0, 0, 3_000_000, 2)),
    ("prog", dl(1_000_000, 0, 3_000_000, 2)),
    ("log", "Downloading nexusq-control-0.1.0-r70"),
    ("prog", dl(3_000_000, 2, 3_000_000, 2)),
]
INSTALL = [
    ("log", "(1/2) Upgrading nexusqd (0.1.0-r28 -> 0.1.0-r29)"),
    ("prog", inst(1000, 4000)),
    ("log", "(2/2) Upgrading nexusq-control (0.1.0-r69 -> 0.1.0-r70)"),
    ("prog", inst(4000, 4000)),
    ("log", "OK: 2136.8 MiB in 998 packages"),
]


class Rig:
    """A temp root, the fake apk, and everything the runner calls out to."""

    def __init__(self, free=10 << 30, **plan):
        self.tmp = tempfile.mkdtemp()
        self.job_path = os.path.join(self.tmp, "lib", "job.json")
        self.live_path = os.path.join(self.tmp, "run", "ota.json")
        self.cache = os.path.join(self.tmp, "cache")
        self.argv_log = os.path.join(self.tmp, "argv.log")
        open(self.argv_log, "w").close()
        self.apk = os.path.join(self.tmp, "apk")
        with open(self.apk, "w") as f:
            f.write(f"#!{sys.executable}\n" + FAKE_APK)
        os.chmod(self.apk, os.stat(self.apk).st_mode | stat.S_IEXEC)
        self.plan = os.path.join(self.tmp, "plan.json")
        full = {"simulate": SIMULATE, "download": DOWNLOAD, "install": INSTALL, "argv_log": self.argv_log}
        full.update(plan)
        with open(self.plan, "w") as f:
            json.dump(full, f)
        self.ring = []
        self.cmds = []  # what run_cmd was asked to do, in order
        self.durable = []  # (state, phase) at every durable write
        self.slept = []
        self.free = free
        self.patches = [
            patch.object(MOD, "APK_BIN", self.apk),
            patch.object(MOD, "THEME_CONF_PATH", os.path.join(self.tmp, "no-theme.json")),
            patch.dict(os.environ, {"FAKE_APK_PLAN": self.plan}),
            patch.object(MOD, "_apk_flagged", lambda: []),
        ]
        for p in self.patches:
            p.start()
        real_write = MOD._ota_write

        def spy_write(path, obj):
            if path == self.job_path:
                self.durable.append((obj["state"], obj["phase"]))
            real_write(path, obj)

        self.patches.append(patch.object(MOD, "_ota_write", spy_write))
        self.patches[-1].start()

    def run_cmd(self, argv, **kw):
        self.cmds.append(list(argv))
        if argv[:1] == [self.apk]:
            return subprocess.run(argv, **kw)
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    def runner(self, kind="system", new=True):
        return MOD.OtaRunner(
            kind,
            job_path=self.job_path,
            live_path=self.live_path,
            cache_dir=self.cache,
            new=new,
            run=self.run_cmd,
            ring=self.ring.append,
            free_bytes=lambda path: self.free,
            ensure_repo=lambda: None,
            sleep=self.slept.append,
        )

    def job(self):
        with open(self.job_path) as f:
            return json.load(f)

    def apk_calls(self):
        with open(self.argv_log) as f:
            return [json.loads(ln) for ln in f if ln.strip()]

    def finished(self, name):
        return os.path.exists(f"{self.argv_log}.{name}.finished")

    def close(self):
        for p in reversed(self.patches):
            p.stop()
        shutil.rmtree(self.tmp)


class TestProgress(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.p = MOD.OtaProgress(clock=lambda: self.now)

    def test_log_lines_give_the_counts_and_the_package_of_their_phase(self):
        self.p.dl_pkgs = 140
        self.p.set_phase("downloading")
        self.assertTrue(self.p.feed_line("Downloading busybox-1.37.0-r30"))
        self.assertTrue(self.p.feed_line("Downloading abseil-cpp-strerror-20260817.0-r0"))
        self.assertEqual((self.p.pkgs_done, self.p.pkgs_total), (1, 140))
        self.assertEqual(self.p.current, "abseil-cpp-strerror")
        self.p.set_phase("installing")
        self.p.feed_line("(260/393) Upgrading device-google-steelhead (1.0-r117 -> 1.0-r132)")
        self.assertEqual((self.p.pkgs_done, self.p.pkgs_total), (259, 393))
        self.assertEqual(self.p.current, "device-google-steelhead")

    def test_other_lines_are_not_progress(self):
        self.p.set_phase("installing")
        for line in ("Executing busybox-1.37.0-r30.trigger", "OK: 2136.8 MiB in 998 packages", ""):
            self.assertFalse(self.p.feed_line(line))
            self.assertFalse(self.p.feed_progress(line))
        self.assertFalse(self.p.feed_progress("100/200 download"), "the install's own download is not the job's")

    def test_a_line_of_another_phase_is_ignored(self):
        # Two pipes: a download line can be read after the install began.
        self.p.set_phase("downloading")
        self.p.feed_progress(dl(0, 0, 100, 1))
        self.p.set_phase("installing")
        self.assertFalse(self.p.feed_progress(dl(100, 1, 100, 1)))
        self.assertFalse(self.p.feed_line("Downloading a-2-r0"))
        self.assertFalse(self.p.set_phase("downloading"), "the phase never goes back")
        self.assertEqual(self.p.phase, "installing")

    def test_progress_lines_give_the_phase_percent_and_the_bytes(self):
        self.p.dl_pkgs = 2
        self.p.set_phase("downloading")
        self.p.feed_line("Downloading a-1-r0")
        self.p.feed_progress(dl(1_000_000, 0, 3_000_000, 2))
        self.assertAlmostEqual(self.p.phase_pct, 100 * 1_000_000 / (3_000_000 + 2 * W), places=3)
        self.assertEqual(self.p.download_bytes(), (1_000_000, 3_000_000))
        self.p.set_phase("installing")
        self.p.feed_progress(inst(500, 1000))
        self.assertEqual(self.p.phase_pct, 50.0)
        self.assertEqual(self.p.download_bytes(), (None, None))

    def test_the_overall_percent_spans_the_phases_and_never_goes_back(self):
        self.assertEqual(self.p.percent(), 0)
        self.p.set_phase("downloading")
        self.assertEqual(self.p.percent(), 5)
        self.p.feed_progress(dl(100, 1, 100, 1))
        self.assertEqual(self.p.percent(), 60)
        self.p.set_phase("installing")
        self.assertEqual(self.p.percent(), 60)
        self.p.feed_progress(inst(10, 10))
        self.assertEqual(self.p.percent(), 95)
        self.assertEqual(self.p.percent("downloading", 10), 95, "never back")

    def test_eta_from_the_phase_rate_plus_the_install_while_downloading(self):
        self.p.install_pkgs = 100
        self.p.set_phase("downloading")
        self.p.feed_progress(dl(0, 0, 1000, 100))
        self.assertIsNone(self.p.eta())
        self.now += 60
        total = 1000 + 100 * W
        self.p.feed_progress(f"{total // 4}/{total} fetch")
        # 60 s for a quarter: 180 s left, plus 100 packages to install.
        self.assertAlmostEqual(self.p.eta(), 180 + 100 * MOD.OTA_INSTALL_S_PER_PKG, delta=2)

    def test_stalled_only_after_the_phase_limit(self):
        self.p.set_phase("downloading")
        self.p.feed_progress(dl(0, 0, 100, 1))
        self.now += MOD.OTA_DOWNLOAD_STALL_S - 1
        self.assertFalse(self.p.stalled())
        self.now += 2
        self.assertTrue(self.p.stalled())
        self.p.feed_progress(dl(10, 0, 100, 1))
        self.assertFalse(self.p.stalled(), "progress resets it")


class TestPlanAndArgv(unittest.TestCase):
    def test_the_plan_gives_changes_download_growth_and_what_to_fetch(self):
        self.assertEqual(
            MOD.ota_parse_plan(SIMULATE),
            {
                "changes": 2,
                "download": int(2.9 * (1 << 20)),
                "grow": 16 << 10,
                "fetch": ["nexusqd=0.1.0-r29", "nexusq-control=0.1.0-r70"],
            },
        )

    def test_the_plan_fetches_what_it_puts_on_the_system_only(self):
        plan = MOD.ota_parse_plan(
            "(1/4) Purging old-thing (1.0-r0)\n"
            "(2/4) Installing new-thing (2.0-r1)\n"
            "(3/4) Downgrading pinned (1.1-r0 -> 1.0-r3)\n"
            "(4/4) Reinstalling flagged (3.2-r1)\n"
        )
        self.assertEqual(plan["fetch"], ["new-thing=2.0-r1", "pinned=1.0-r3", "flagged=3.2-r1"])

    def test_a_tagged_repository_s_package_is_fetched_by_its_bare_name(self):
        plan = MOD.ota_parse_plan("(1/1) Upgrading foo@edge (1.0-r0 -> 1.1-r0)")
        self.assertEqual(plan["fetch"], ["foo=1.1-r0"])

    def test_a_shrinking_system_and_an_empty_plan(self):
        shrink = MOD.ota_parse_plan("After this operation, 3 MiB of disk space will be freed.")
        self.assertEqual(shrink["grow"], -(3 << 20))
        self.assertEqual(
            MOD.ota_parse_plan("OK: 2136.8 MiB in 998 packages"), {"changes": 0, "download": 0, "grow": 0, "fetch": []}
        )

    def test_the_system_job_never_installs_the_kernel(self):
        install = MOD.ota_install_argv("system", "/c", 7)
        self.assertEqual(install[install.index("--ignore") + 1], MOD._KERNEL_PKG)
        for flag in ("--cache-predownload", "--available", "upgrade"):
            self.assertIn(flag, install)
        plan = MOD.ota_plan_argv("system", "/c")
        self.assertEqual(plan[plan.index("--ignore") + 1], MOD._KERNEL_PKG)
        self.assertIn("--simulate", plan)

    def test_the_download_fetches_exactly_the_plan_under_cache_names(self):
        argv = MOD.ota_download_argv("/c", 7, ["nexusqd=0.1.0-r29"])
        self.assertEqual(
            argv[argv.index("fetch") :],
            ["fetch", "--pkgname-spec", MOD.APK_CACHENAME_SPEC, "-o", "/c", "nexusqd=0.1.0-r29"],
        )
        self.assertEqual(MOD.APK_CACHENAME_SPEC, "${name}-${version}.${hash:8}.apk", "apk's own cache name")

    def test_only_apk_update_refreshes_the_lists(self):
        age = ["--cache-max-age", str(MOD.OTA_LISTS_MAX_AGE_MIN)]

        def has(argv):
            return any(argv[i : i + 2] == age for i in range(len(argv)))

        self.assertTrue(has(MOD.ota_plan_argv("system", "/c")))
        self.assertTrue(has(MOD.ota_download_argv("/c", 7, [])))
        self.assertTrue(has(MOD.ota_install_argv("system", "/c", 7)))
        self.assertFalse(has(MOD._ota_common("/c", keep_lists=False)))

    def test_the_daemons_job_works_only_on_our_daemons(self):
        n = len(MOD.OTA_PACKAGES)
        self.assertEqual(MOD.ota_install_argv("daemons", "/c", 7)[-n:], list(MOD.OTA_PACKAGES))
        self.assertNotIn("--available", MOD.ota_install_argv("daemons", "/c", 7))


class TestRunner(unittest.TestCase):
    def rig(self, **kw):
        r = Rig(**kw)
        self.addCleanup(r.close)
        return r

    def test_a_successful_system_job(self):
        r = self.rig()
        self.assertEqual(r.runner().run(), 0)
        job = r.job()
        self.assertEqual((job["state"], job["phase"]), ("done", "done"))
        phases = [ph for _, ph in r.durable]
        order = ["preparing", "downloading", "installing", "applying", "done"]
        self.assertEqual([p for p in order if p in phases], order)
        self.assertEqual(phases.index("downloading") < phases.index("installing"), True)
        self.assertEqual(job["progress"]["percent"], 100)
        self.assertEqual(job["result"]["changed"], ["nexusqd", "nexusq-control"])
        self.assertEqual(job["result"]["daemons"], ["nexusqd", "nexusq-control"])

    def test_three_apk_processes_plan_download_install(self):
        r = self.rig()
        r.runner().run()
        kinds = []
        for a in r.apk_calls():
            if "update" in a:
                kinds.append("update")
            elif "--simulate" in a:
                kinds.append("plan")
            elif "fetch" in a:
                kinds.append("download")
            elif "purge" in a:
                kinds.append("purge")
            elif "upgrade" in a:
                kinds.append("install")
        self.assertEqual(kinds, ["update", "plan", "download", "install", "purge"])
        fetch = next(a for a in r.apk_calls() if "fetch" in a)
        self.assertEqual(fetch[-2:], ["nexusqd=0.1.0-r29", "nexusq-control=0.1.0-r70"], "exactly the plan")

    def test_the_ring_shows_both_phases_in_their_colours_then_green_then_the_theme(self):
        r = self.rig()
        r.runner().run()
        dl_cmds = [c for c in r.ring if c.startswith("progress") and c.endswith(" 0 70 160")]
        in_cmds = [c for c in r.ring if c.startswith("progress") and c.endswith(" 0 200 255")]
        self.assertTrue(dl_cmds and in_cmds, r.ring)
        self.assertLess(r.ring.index(dl_cmds[-1]), r.ring.index(in_cmds[0]))
        self.assertEqual(dl_cmds[-1], "progress 100 0 70 160")
        self.assertEqual(in_cmds[-1], "progress 100 0 200 255")
        green = r.ring.index(MOD.OTA_RING_OK)
        self.assertEqual(r.ring[green + 1 :], ["auto"], "a never-themed Q goes back to auto")

    def test_the_bridge_restarts_last_and_only_once_the_job_reads_done(self):
        r = self.rig()
        seen = []
        orig = r.run_cmd

        def run_cmd(argv, **kw):
            if argv[-1] == "nexusq-control":
                seen.append(r.job()["state"])
            return orig(argv, **kw)

        r.run_cmd = run_cmd
        r.runner().run()
        sysctl = [c for c in r.cmds if c[0] == "systemctl"]
        self.assertEqual(sysctl[0], ["systemctl", "daemon-reload"])
        self.assertIn(["systemctl", "restart", "nexusqd"], sysctl)
        self.assertEqual(sysctl[-1], ["systemctl", "--no-block", "restart", "nexusq-control"])
        self.assertEqual(seen, ["done"])

    def test_a_base_change_reboots_recorded_as_rebooting(self):
        install = [
            s if "nexusq-control" not in s[1] else ("log", "(2/2) Upgrading musl (1.2.6-r6 -> 1.2.6-r7)")
            for s in INSTALL
        ]
        r = self.rig(install=install)
        self.assertEqual(r.runner().run(), 0)
        job = r.job()
        self.assertEqual((job["state"], job["phase"]), ("running", "rebooting"))
        self.assertEqual(r.cmds[-1], ["systemctl", "--no-block", "reboot"])
        self.assertNotIn("auto", r.ring, "stays green into the reboot")

    def test_a_daemons_job_reports_what_it_upgraded(self):
        r = self.rig()
        r.runner("daemons").run()
        res = r.job()["result"]
        self.assertEqual(res["upgraded"], ["nexusq-control", "nexusqd"])
        self.assertTrue(res["restarting"])

    def test_nothing_to_install_is_done_without_a_download(self):
        r = self.rig(simulate="OK: 2136.8 MiB in 998 packages")
        self.assertEqual(r.runner().run(), 0)
        self.assertEqual(r.job()["state"], "done")
        self.assertFalse(r.finished("download") or r.finished("install"))

    def test_everything_cached_skips_the_download(self):
        r = self.rig(simulate=SIMULATE.replace("Need to download 2.9 MiB of packages.\n", ""))
        self.assertEqual(r.runner().run(), 0)
        self.assertFalse(r.finished("download"))
        self.assertTrue(r.finished("install"))

    def test_a_failed_transaction_fails_the_job_with_red(self):
        r = self.rig(install=INSTALL[:2] + [("log", "ERROR: musl-1.2.6-r7: BAD signature")], install_rc=1)
        self.assertEqual(r.runner().run(), 1)
        job = r.job()
        self.assertEqual((job["state"], job["phase"]), ("failed", "failed"))
        self.assertIn("BAD signature", job["error"])
        self.assertIn(MOD.OTA_RING_FAILED, r.ring)
        self.assertEqual(r.ring[-1], "auto")
        self.assertFalse([c for c in r.cmds if c[0] == "systemctl"], "nothing applied")

    def test_a_failed_download_fails_before_anything_changed(self):
        r = self.rig(download=DOWNLOAD[:3] + [("log", "ERROR: nexusqd-0.1.0-r29: network error")], download_rc=1)
        self.assertEqual(r.runner().run(), 1)
        self.assertIn("the download failed", r.job()["error"])
        self.assertFalse(r.finished("install"))

    def test_a_stalled_download_is_stopped_safely(self):
        r = self.rig(download=DOWNLOAD[:4] + [("sleep", 20)] + DOWNLOAD[4:])
        with patch.object(MOD, "OTA_DOWNLOAD_STALL_S", 0.3):
            self.assertEqual(r.runner().run(), 1)
        self.assertIn("no progress", r.job()["error"])
        self.assertFalse(r.finished("install"), "nothing installed")

    def test_a_job_that_would_not_fit_does_not_start_the_download(self):
        r = self.rig(free=64 << 20)
        self.assertEqual(r.runner().run(), 1)
        self.assertIn("not enough space", r.job()["error"])
        self.assertNotIn("fetch", [a for c in r.apk_calls() for a in c])

    def test_the_space_needed_is_the_download_the_growth_and_a_margin(self):
        need = int(2.9 * (1 << 20)) + (16 << 10) + MOD.OTA_SPACE_MARGIN
        r = self.rig(free=need + 1)
        self.assertEqual(r.runner().run(), 0)
        r2 = self.rig(free=need - (1 << 20))
        self.assertEqual(r2.runner().run(), 1)

    def test_only_this_plan_s_packages_in_the_cache_count_as_room(self):
        need = int(2.9 * (1 << 20)) + (16 << 10) + MOD.OTA_SPACE_MARGIN
        r = self.rig(free=need - (2 << 20))
        os.makedirs(r.cache)
        stale = os.path.join(r.cache, "nexusqd-0.1.0-r27.deadbeef.apk")  # superseded, from a failed job
        partial = os.path.join(r.cache, "nexusqd-0.1.0-r29.abcd1234.apk.tmp.4242")  # a stopped fetch
        for path in (stale, partial):
            with open(path, "wb") as f:
                f.write(b"x" * (4 << 20))
        self.assertEqual(r.runner().run(), 1, "neither counts as room")
        self.assertFalse(os.path.exists(partial), "the stopped fetch's leftover is removed")
        r2 = self.rig(free=need - (2 << 20))
        os.makedirs(r2.cache)
        with open(os.path.join(r2.cache, "nexusqd-0.1.0-r29.abcd1234.apk"), "wb") as f:
            f.write(b"x" * (4 << 20))
        self.assertEqual(r2.runner().run(), 0, "what the plan needs, already fetched, counts")

    def test_an_install_is_never_stopped_only_reported_stalled(self):
        r = self.rig(install=INSTALL[:2] + [("sleep", 2.5)] + INSTALL[2:])
        stalled_seen = []
        real = MOD._ota_write

        def watch(path, obj):
            if path == r.live_path and obj.get("stalled"):
                stalled_seen.append(obj["phase"])
            real(path, obj)

        with patch.object(MOD, "OTA_INSTALL_STALL_S", 0.3), patch.object(MOD, "_ota_write", watch):
            self.assertEqual(r.runner().run(), 0)
        self.assertEqual(r.job()["state"], "done")
        self.assertIn("installing", stalled_seen)

    def test_a_shutdown_during_the_download_leaves_the_job_for_the_next_boot(self):
        r = self.rig(download=DOWNLOAD[:3] + [("sleep", 20)] + DOWNLOAD[3:])
        runner = r.runner()
        threading.Timer(0.6, runner.on_sigterm).start()
        self.assertEqual(runner.run(), 0)
        self.assertEqual(r.job()["state"], "running")
        self.assertFalse(r.finished("install"))
        self.assertNotIn(MOD.OTA_RING_FAILED, r.ring)

    def test_a_shutdown_during_the_install_lets_apk_finish(self):
        # apk is never killed mid-commit: the runner waits for it, and the
        # job stays running so the next boot applies it.
        r = self.rig(install=INSTALL[:1] + [("sleep", 1.5)] + INSTALL[1:])
        runner = r.runner()
        orig = runner._install

        def install_then_shutdown():
            threading.Timer(0.5, runner.on_sigterm).start()
            return orig()

        runner._install = install_then_shutdown
        self.assertEqual(runner.run(), 0)
        self.assertTrue(r.finished("install"), "apk ran to its end")
        job = r.job()
        self.assertEqual((job["state"], job["phase"]), ("running", "installing"))
        self.assertFalse([c for c in r.cmds if c[0] == "systemctl"], "nothing applied during a shutdown")

    def test_a_shutdown_before_the_install_never_starts_it(self):
        r = self.rig()
        runner = r.runner()
        orig = runner._download

        def download_then_shutdown(plan):
            orig(plan)
            runner.on_sigterm()

        runner._download = download_then_shutdown
        self.assertEqual(runner.run(), 0)
        self.assertFalse(r.finished("install"))
        self.assertEqual(r.job()["state"], "running")

    def test_a_failing_disk_never_leaves_apk_behind(self):
        # The runner exiting early would have systemd SIGKILL apk with it.
        r = self.rig(install=INSTALL[:1] + [("sleep", 0.8)] + INSTALL[1:])
        real = MOD._ota_write

        def failing(path, obj):
            if obj.get("phase") == "installing":
                raise OSError(28, "No space left on device")
            real(path, obj)

        with patch.object(MOD, "_ota_write", failing):
            r.runner().run()
        self.assertTrue(r.finished("install"), "apk ran to its end")

    def test_a_line_that_cannot_be_read_never_leaves_apk_behind(self):
        r = self.rig(install=INSTALL[:1] + [("sleep", 0.5)] + INSTALL[1:])
        real = MOD.OtaProgress.feed_line

        def broken(prog, line):
            if "nexusq-control" in line:
                raise ValueError("unreadable")
            return real(prog, line)

        with patch.object(MOD.OtaProgress, "feed_line", broken):
            r.runner().run()
        self.assertTrue(r.finished("install"), "apk ran to its end")

    def test_the_package_lists_are_tried_again_and_a_cache_with_lists_goes_on(self):
        r = self.rig(update_rc=[1, 1, 0])
        self.assertEqual(r.runner().run(), 0)
        self.assertEqual(r.slept.count(MOD.OTA_INDEX_RETRY_S), 2)
        r2 = self.rig(update_rc=[1])
        os.makedirs(r2.cache)
        open(os.path.join(r2.cache, "APKINDEX.abc.tar.gz"), "w").close()
        self.assertEqual(r2.runner().run(), 0, "a resumed job goes on with the cached lists")
        r3 = self.rig(update_rc=[1])
        self.assertEqual(r3.runner().run(), 1)
        self.assertIn("could not refresh the package lists", r3.job()["error"])

    def test_a_late_start_with_no_job_waiting_does_nothing(self):
        # A resumed job's start can come after the bridge gave up on it: it
        # must not begin a fresh job, uncounted, behind the bridge's back.
        r = self.rig()
        self.assertEqual(r.runner(new=False).run(), 0)
        self.assertFalse(os.path.exists(r.job_path))
        self.assertEqual(r.apk_calls(), [])
        MOD._ota_write(r.job_path, MOD.ota_new_job("system"))
        self.assertEqual(r.runner(new=False).run(), 0)
        self.assertEqual(r.job()["state"], "done", "a waiting job runs")

    def test_apk_gone_with_a_pipe_held_open_ends_the_wait(self):
        # apk does not mark the progress fd close-on-exec: a process a package
        # script leaves behind can hold it open after apk exits.
        r = self.rig(install=INSTALL)
        apk = r.apk
        with open(apk) as f:
            body = f.read()
        body = body.replace(
            'open(plan["argv_log"] + "." + name + ".finished", "w").close()',
            'open(plan["argv_log"] + "." + name + ".finished", "w").close()\n'
            '    if name == "install":\n'
            "        import subprocess as sp\n"
            '        sp.Popen(["sleep", "30"], pass_fds=(fd,))',
        )
        with open(apk, "w") as f:
            f.write(body)
        with patch.object(MOD, "OTA_DRAIN_S", 0.5):
            t0 = MOD.time.monotonic()
            self.assertEqual(r.runner().run(), 0)
        self.assertLess(MOD.time.monotonic() - t0, 15)

    def test_the_cache_is_purged_after_success(self):
        r = self.rig()
        r.runner().run()
        self.assertTrue(any("purge" in c for c in r.apk_calls()))


class TestJobs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.job_path = os.path.join(self.tmp, "job.json")
        self.live_path = os.path.join(self.tmp, "live.json")
        self.active = set()
        self.started = []
        self.told = []
        self.now = 1000.0
        self.jobs = MOD.OtaJobs(
            progress=lambda j: self.told.append(("progress", j["phase"], j["progress"]["percent"])),
            finished=lambda j: self.told.append(("finished", j["state"])),
            unit_active=lambda kind: kind in self.active,
            start_unit=self._start,
            job_path=self.job_path,
            live_path=self.live_path,
            clock=lambda: self.now,
            wall=lambda: 1_790_000_000,
        )

    def _start(self, kind):
        self.started.append(kind)
        self.active.add(kind)

    def write(self, **kw):
        job = MOD.ota_new_job("system", lambda: 1_790_000_000)
        job.update(kw)
        MOD._ota_write(self.job_path, job)
        return job

    def test_start_records_the_job_and_starts_its_unit(self):
        job = self.jobs.start("system")
        self.assertEqual(self.started, ["system"])
        self.assertTrue(self.jobs.running())
        self.assertEqual(self.jobs.job()["id"], job["id"])

    def test_a_second_install_is_refused(self):
        self.jobs.start("system")
        with self.assertRaises(MOD.Err) as e:
            self.jobs.start("daemons")
        self.assertEqual(e.exception.code, "busy")

    def test_a_unit_that_will_not_start_fails_the_job(self):
        def refuse(kind):
            raise MOD.Err("unavailable", "cannot start the update: no such unit")

        self.jobs.start_unit = refuse
        with self.assertRaises(MOD.Err):
            self.jobs.start("system")
        self.assertEqual(self.jobs.job()["state"], "failed")
        self.assertFalse(self.jobs.running())

    def test_a_job_whose_unit_still_runs_is_left_alone(self):
        self.write(phase="installing")
        self.active.add("system")
        self.jobs.resume()
        self.assertEqual(self.started, [])
        self.assertEqual(self.jobs.job()["attempt"], 1)

    def test_an_interrupted_job_is_started_again(self):
        self.write(phase="installing")
        self.jobs.resume()
        j = self.jobs.job()
        self.assertEqual(self.started, ["system"])
        self.assertEqual((j["attempt"], j["resumed"], j["state"]), (2, True, "running"))

    def test_an_interrupted_job_gives_up_after_the_last_attempt(self):
        self.write(phase="installing", attempt=MOD.OTA_MAX_ATTEMPTS)
        self.jobs.resume()
        j = self.jobs.job()
        self.assertEqual(self.started, [])
        self.assertEqual(j["state"], "failed")
        self.assertIn("interrupted", j["error"])

    def test_a_job_interrupted_by_its_own_reboot_is_done(self):
        self.write(phase="rebooting")
        self.jobs.resume()
        self.assertEqual(self.jobs.job()["state"], "done")
        self.assertEqual(self.started, [])

    def test_progress_is_told_only_when_something_visible_changed(self):
        job = self.jobs.start("system")
        self.jobs.step()
        self.jobs.step()
        live = dict(job, phase="downloading")
        live["progress"] = dict(job["progress"], percent=12)
        MOD._ota_write(self.live_path, live)
        self.jobs.step()
        self.jobs.step()
        self.assertEqual(self.told, [("progress", "preparing", 0), ("progress", "downloading", 12)])

    def test_the_end_is_told_once_and_remembered(self):
        job = self.jobs.start("system")
        self.jobs.step()
        job.update(state="done", phase="done")
        MOD._ota_write(self.job_path, job)
        self.assertIsNone(self.jobs.step())
        self.assertIsNone(self.jobs.step())
        self.assertEqual(self.told[-1], ("finished", "done"))
        self.assertEqual(sum(1 for t in self.told if t[0] == "finished"), 1)
        # A new bridge (a restart) does not tell it again.
        self.told.clear()
        fresh = MOD.OtaJobs(
            progress=lambda j: self.told.append("progress"),
            finished=lambda j: self.told.append("finished"),
            unit_active=lambda kind: False,
            start_unit=self._start,
            job_path=self.job_path,
            live_path=self.live_path,
        )
        fresh.resume()
        fresh.step()
        self.assertEqual(self.told, [])

    def test_a_job_that_ended_while_no_bridge_watched_is_told_by_the_next(self):
        self.write(state="done", phase="done")
        self.jobs.step()
        self.assertEqual(self.told, [("finished", "done")])

    def test_a_unit_that_cannot_be_told_is_never_taken_for_gone(self):
        self.jobs.start("system")
        self.jobs.unit_active = lambda kind: None  # e.g. during the job's daemon-reexec
        self.jobs.step()
        self.now += MOD.OtaJobs.GONE_GRACE_S + 60
        self.jobs.step()
        self.jobs.resume()
        self.assertEqual(self.started, ["system"])
        self.assertEqual(self.jobs.job()["attempt"], 1)

    def test_an_unreadable_job_record_does_not_stop_the_watcher(self):
        MOD._ota_write(self.job_path, {"state": "running", "phase": "installing"})  # no kind
        self.assertIsNone(self.jobs.job())
        self.jobs.resume()
        self.assertEqual(self.started, [])

    def test_a_unit_that_vanished_is_resumed_after_the_grace(self):
        self.jobs.start("system")
        self.active.clear()  # the runner died
        self.jobs.step()
        self.now += MOD.OtaJobs.GONE_GRACE_S + 1
        self.jobs.step()
        self.assertEqual(self.started, ["system", "system"])
        self.assertEqual(self.jobs.job()["attempt"], 2)

    def test_the_live_copy_is_read_only_while_the_job_runs(self):
        job = self.jobs.start("system")
        MOD._ota_write(self.live_path, dict(job, phase="installing"))
        self.assertEqual(self.jobs.job()["phase"], "installing")
        job.update(state="done", phase="done")
        MOD._ota_write(self.job_path, job)
        self.assertEqual(self.jobs.job()["phase"], "done")


class TestUnitActive(unittest.TestCase):
    """Is the job's unit running: from its cgroup, or systemd when there is none."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.procs = os.path.join(self.tmp, "nexusq-ota@{}.service", "cgroup.procs")
        p = patch.object(MOD, "OTA_UNIT_CGROUP", self.procs)
        p.start()
        self.addCleanup(p.stop)

    def show(self, stdout, rc=0):
        return patch.object(
            MOD.subprocess, "run", lambda *a, **kw: subprocess.CompletedProcess(a, rc, stdout=stdout, stderr="")
        )

    def test_a_cgroup_with_processes_is_running_without_asking_systemd(self):
        os.makedirs(os.path.dirname(self.procs.format("system")))
        with open(self.procs.format("system"), "w") as f:
            f.write("4242\n")
        with patch.object(MOD.subprocess, "run", side_effect=AssertionError("forked systemctl")):
            self.assertIs(MOD._ota_unit_active("system"), True)

    def test_a_start_still_queued_is_running_not_gone(self):
        # A resumed job at boot: the start waits behind the boot, no cgroup yet.
        with self.show("ActiveState=inactive\nJob=1234\n"):
            self.assertIs(MOD._ota_unit_active("system"), True)

    def test_inactive_with_no_job_is_gone(self):
        with self.show("ActiveState=inactive\nJob=\n"):
            self.assertIs(MOD._ota_unit_active("system"), False)

    def test_an_answer_systemd_cannot_give_is_unknown(self):
        with self.show("", rc=1):
            self.assertIsNone(MOD._ota_unit_active("system"))
        with self.show("ActiveState=maintenance\nJob=\n"):
            self.assertIsNone(MOD._ota_unit_active("system"))


class TestBridgeMethods(unittest.TestCase):
    """installSystemUpdate / installNexusUpdate / getUpdateJob on a bare Bridge."""

    def setUp(self):
        self.b = object.__new__(MOD.Bridge)
        self.b.update_led = MockLed()
        self.started = []
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        self.b.ota = MOD.OtaJobs(
            progress=lambda j: None,
            finished=lambda j: None,
            unit_active=lambda kind: True,
            start_unit=self.started.append,
            job_path=os.path.join(tmp, "job.json"),
            live_path=os.path.join(tmp, "live.json"),
        )

    def test_async_install_answers_at_once_with_the_job(self):
        res, events = self.b.handle("installSystemUpdate", {"async": True})
        self.assertTrue(res["started"])
        self.assertEqual(res["job"]["kind"], "system")
        self.assertEqual(events[0][0], "updateProgress")
        self.assertEqual(self.started, ["system"])
        self.assertTrue(self.b.update_led.held)

    def test_the_daemon_track_is_a_daemons_job(self):
        res, _ = self.b.handle("installNexusUpdate", {"async": True})
        self.assertEqual(res["job"]["kind"], "daemons")

    def test_checks_answer_busy_while_a_job_runs(self):
        self.b.handle("installSystemUpdate", {"async": True})
        res, _ = self.b.handle("checkSystemUpdate", {})
        self.assertTrue(res["busy"])
        res, _ = self.b.handle("checkNexusUpdate", {})
        self.assertTrue(res["busy"])

    def test_a_second_install_is_busy_and_the_led_is_held_by_the_first(self):
        self.b.handle("installSystemUpdate", {"async": True})
        with self.assertRaises(MOD.Err) as e:
            self.b.handle("installNexusUpdate", {"async": True})
        self.assertEqual(e.exception.code, "busy")
        self.assertTrue(self.b.update_led.held, "no 'available' blink while the first job runs")

    def test_the_blocking_form_answers_like_before_jobs(self):
        def finish_soon():
            j = self.b.ota.job()
            j.update(
                state="done",
                phase="done",
                result={
                    "changed": ["musl"],
                    "daemons": [],
                    "rebootRecommended": True,
                    "systemdChanged": False,
                    "triggerErrors": [],
                    "output": "",
                },
            )
            MOD._ota_write(self.b.ota.job_path, j)

        threading.Timer(0.3, finish_soon).start()
        with patch.object(MOD.time, "sleep", lambda s: MOD.threading.Event().wait(0.05)):
            res, _ = self.b.handle("installSystemUpdate", {})
        self.assertTrue(res["ok"])
        self.assertTrue(res["rebootRecommended"])

    def test_the_blocking_form_raises_the_job_s_failure(self):
        def fail_soon():
            j = self.b.ota.job()
            j.update(state="failed", phase="failed", error="apk upgrade failed: BAD signature")
            MOD._ota_write(self.b.ota.job_path, j)

        threading.Timer(0.3, fail_soon).start()
        with patch.object(MOD.time, "sleep", lambda s: MOD.threading.Event().wait(0.05)):
            with self.assertRaises(MOD.Err) as e:
                self.b.handle("installSystemUpdate", {})
        self.assertIn("BAD signature", e.exception.message)

    def test_async_must_be_a_bool(self):
        with self.assertRaises(MOD.Err) as e:
            self.b.handle("installSystemUpdate", {"async": "yes"})
        self.assertEqual(e.exception.code, "bad_request")

    def test_get_update_job(self):
        self.assertEqual(self.b.handle("getUpdateJob", {})[0], {"job": None})
        self.b.handle("installSystemUpdate", {"async": True})
        self.assertEqual(self.b.handle("getUpdateJob", {})[0]["job"]["kind"], "system")


class MockLed:
    def __init__(self):
        self.held = False

    def hold(self, on):
        self.held = on

    def set(self, reason, on):
        pass


if __name__ == "__main__":
    unittest.main()
