"""Tests for the diagnostics mode (PROTOCOL §16).

What is pinned: the mode ends by itself; a running service is switched to the
other logging mode only when it is not playing; the mode a service RUNS in is
read from the process, so nothing has to be remembered across a bridge restart;
a launcher that has not exec'd its binary yet is never restarted for it.
"""

import importlib.machinery
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from unittest.mock import patch

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control",
        importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()
SPOT = "librespot.service"
AIR = "shairport-sync.service"


class Fake:
    """Two services, a clock, and what the restarts did to them."""

    def __init__(self, path):
        self.now = 1_790_000_000.0
        self.mode = {SPOT: False, AIR: None}     # AirPlay off
        self.playing = set()
        self.restarted = []
        self.events = []
        self.d = MOD.Diagnostics(
            proc_diag=lambda unit, exe: self.mode[unit],
            busy=lambda sid: sid in self.playing,
            restart=self._restart, notify=self.events.append,
            path=path, clock=lambda: self.now)

    def _restart(self, unit):
        self.restarted.append(unit)
        # the launcher reads the file again when it starts
        self.mode[unit] = MOD.diag_is_on(MOD.diag_load(self.d.path), self.now)


class TestDiagnostics(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "nexusq", "diagnostics.json")
        self.f = Fake(self.path)

    def test_off_by_default(self):
        v = self.f.d.view()
        self.assertFalse(v["enabled"])
        self.assertIsNone(v["until"])
        self.assertEqual(v["pending"], [])
        self.assertEqual([s["id"] for s in v["services"]], ["spotify", "airplay"])

    def test_on_writes_a_readable_file_and_restarts_when_idle(self):
        v = self.f.d.set({"enabled": True, "hours": 2})
        self.assertTrue(v["enabled"])
        self.assertEqual(v["until"], int(self.f.now + 7200))
        self.assertEqual(v["remainingS"], 7200)
        # the launchers run as uid 10000 and must be able to read it
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o644)
        self.assertEqual(v["pending"], ["spotify"])   # running, still normal
        self.f.d.step()
        self.assertEqual(self.f.restarted, [SPOT])
        self.assertEqual(self.f.d.view()["pending"], [])
        # a service that was not running needs nothing
        self.assertNotIn(AIR, self.f.restarted)

    def test_default_is_24_hours(self):
        v = self.f.d.set({"enabled": True})
        self.assertEqual(v["remainingS"], 24 * 3600)

    def test_never_cuts_a_song(self):
        self.f.playing.add("spotify")
        self.f.d.set({"enabled": True})
        wait = self.f.d.step()
        self.assertEqual(self.f.restarted, [])
        self.assertEqual(wait, MOD.DIAG_PENDING_POLL_S)  # keeps looking
        self.f.playing.clear()
        self.f.d.step()
        self.assertEqual(self.f.restarted, [SPOT])

    def test_expires_by_itself_and_goes_back_to_normal(self):
        self.f.d.set({"enabled": True, "hours": 1})
        self.f.d.step()
        self.f.restarted.clear()
        wait = self.f.d.step()
        self.assertEqual(wait, 3600)                    # sleeps to the expiry
        self.f.now += 3601
        self.f.d.step()
        st = json.load(open(self.path))
        self.assertIsNone(st["until"])
        self.assertEqual(st["endedAt"], 1_790_000_000.0 + 3600)
        self.assertEqual(self.f.restarted, [SPOT])     # back to normal logging
        v = self.f.d.view()
        self.assertFalse(v["enabled"])
        self.assertEqual(v["endedAt"], int(1_790_000_000 + 3600))
        # and it tells the clients
        self.assertFalse(self.f.events[-1]["enabled"])

    def test_off_by_hand(self):
        self.f.d.set({"enabled": True})
        self.f.d.step()
        v = self.f.d.set({"enabled": False})
        self.assertFalse(v["enabled"])
        self.assertEqual(v["pending"], ["spotify"])
        self.f.d.step()
        self.assertFalse(self.f.mode[SPOT])

    def test_a_starting_launcher_is_not_restarted(self):
        self.f.mode[SPOT] = "starting"      # still waiting for wlan0
        self.f.d.set({"enabled": True})
        self.assertEqual(self.f.d.view()["pending"], [])
        self.f.d.step()
        self.assertEqual(self.f.restarted, [])

    def test_mode_comes_from_the_process_not_memory(self):
        # a bridge restarted while diagnostics were on: a fresh object reads the
        # file and the processes, and finds nothing pending
        self.f.d.set({"enabled": True})
        self.f.d.step()
        again = Fake(self.path)
        again.now = self.f.now
        again.mode = dict(self.f.mode)
        self.assertEqual(again.d.view()["pending"], [])
        self.assertTrue(again.d.view()["enabled"])

    def test_countdown_alone_is_no_news(self):
        self.f.d.set({"enabled": True})
        self.f.d.step()
        n = len(self.f.events)
        self.f.now += 30
        self.f.d.step()
        self.assertEqual(len(self.f.events), n)

    def test_validation(self):
        for p in ({}, {"enabled": "yes"}, {"enabled": True, "hours": 0},
                  {"enabled": True, "hours": MOD.DIAG_MAX_H + 1},
                  {"enabled": True, "hours": "5"},
                  {"enabled": True, "hours": True}):
            with self.subTest(p=p), self.assertRaises(MOD.Err):
                self.f.d.set(p)
        self.assertFalse(os.path.exists(self.path))   # a refusal writes nothing

    def test_garbage_file_reads_as_off(self):
        os.makedirs(os.path.dirname(self.path))
        for doc in ("", "{", "[]", '{"until": "tomorrow"}', '{"until": true}'):
            with self.subTest(doc=doc):
                with open(self.path, "w") as f:
                    f.write(doc)
                self.assertFalse(self.f.d.view()["enabled"])


class TestProcDiag(unittest.TestCase):
    """_proc_diag against a fake cgroup and /proc."""

    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.cg = os.path.join(self.root.name, "cg")
        self.proc = os.path.join(self.root.name, "proc")

    def _proc(self, pid, comm, env):
        d = os.path.join(self.proc, str(pid))
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "comm"), "w") as f:
            f.write(comm + "\n")
        with open(os.path.join(d, "environ"), "wb") as f:
            f.write(b"\0".join(env) + b"\0")

    def _cgroup(self, unit, pids):
        d = os.path.join(self.cg, unit)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "cgroup.procs"), "w") as f:
            f.write("".join(f"{p}\n" for p in pids))

    def _run(self, unit, exe):
        real_open = open

        def fake_open(path, *a, **kw):
            if isinstance(path, str) and path.startswith("/proc/"):
                path = self.proc + path[len("/proc"):]
            return real_open(path, *a, **kw)
        with patch.object(MOD, "_USER_CGROUP", self.cg), \
                patch("builtins.open", fake_open):
            return MOD._proc_diag(unit, exe)

    def test_states(self):
        self.assertIsNone(self._run(SPOT, "librespot"))          # no cgroup
        self._cgroup(SPOT, [])
        self.assertIsNone(self._run(SPOT, "librespot"))          # empty
        self._cgroup(SPOT, [100])
        self._proc(100, "librespot-nexus", [b"HOME=/home/user"])
        self.assertEqual(self._run(SPOT, "librespot"), "starting")
        self._proc(100, "librespot", [b"HOME=/home/user"])
        self.assertIs(self._run(SPOT, "librespot"), False)
        self._proc(100, "librespot", [b"HOME=/home/user", b"NEXUSQ_DIAG=1"])
        self.assertIs(self._run(SPOT, "librespot"), True)
        # the first variable counts too, and a look-alike does not
        self._proc(100, "librespot", [b"NEXUSQ_DIAG=1"])
        self.assertIs(self._run(SPOT, "librespot"), True)
        self._proc(100, "librespot", [b"XNEXUSQ_DIAG=1", b"NEXUSQ_DIAG=10"])
        self.assertIs(self._run(SPOT, "librespot"), False)


if __name__ == "__main__":
    unittest.main()
