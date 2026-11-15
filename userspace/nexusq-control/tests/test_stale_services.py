"""Tests for StaleUserServices: a user service an update left on its old binary.

What is pinned: a service whose running binary was replaced is restarted, but
only when its source is not playing or holding a track -- by the bridge's
memory AND by PulseAudio, which alone knows right after the update restarted
the bridge; PulseAudio not answering counts as busy; one that is current or not
running is left alone; a restart (here or by the diagnostics mode) is not
repeated within STALE_RETRY_S; the check is woken when playback goes idle and
after a successful install only. _proc_stale is checked against a real process
whose binary was deleted, _unit_streams against pactl output.
"""

import importlib.machinery
import importlib.util
import os
import shutil
import subprocess
import tempfile
import time
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
SPOT = "librespot.service"
AIR = "shairport-sync.service"


class Fake:
    def __init__(self):
        self.now = 1000.0
        self.stale = {SPOT: False, AIR: None}
        self.playing = set()
        self.streaming = {SPOT: False, AIR: False}
        self.restarted = []
        self.last = {}
        self.s = MOD.StaleUserServices(
            stale=lambda unit, exe: self.stale[unit],
            busy=lambda sid: sid in self.playing,
            streams=lambda unit: self.streaming[unit],
            restart=self._restart,
            restarted_at=self.last.get,
            clock=lambda: self.now,
        )

    def _restart(self, unit):
        self.restarted.append(unit)
        self.last[unit] = self.now


class TestStaleUserServices(unittest.TestCase):
    def test_nothing_stale_restarts_nothing_and_does_not_poll(self):
        f = Fake()
        self.assertIsNone(f.s.step())
        self.assertEqual(f.restarted, [])

    def test_a_stale_idle_service_is_restarted(self):
        f = Fake()
        f.stale[SPOT] = True
        self.assertEqual(f.s.step(), MOD.STALE_POLL_S)
        self.assertEqual(f.restarted, [SPOT])
        f.stale[SPOT] = False  # it came back on the new binary
        self.assertIsNone(f.s.step())
        self.assertEqual(f.restarted, [SPOT])

    def test_a_playing_service_waits_until_its_source_is_idle(self):
        f = Fake()
        f.stale[SPOT] = True
        f.playing.add("spotify")
        self.assertEqual(f.s.step(), MOD.STALE_POLL_S)
        self.assertEqual(f.restarted, [], "an update must never cut a song off")
        f.playing.clear()
        f.s.step()
        self.assertEqual(f.restarted, [SPOT])

    def test_a_stream_in_pulseaudio_is_busy_though_the_bridge_knows_nothing(self):
        # Right after the update restarted the bridge: nowPlaying is empty.
        f = Fake()
        f.stale[SPOT] = True
        f.streaming[SPOT] = True
        f.s.step()
        self.assertEqual(f.restarted, [], "a track that keeps playing must not be cut off")
        f.streaming[SPOT] = False
        f.s.step()
        self.assertEqual(f.restarted, [SPOT])

    def test_pulseaudio_not_answering_counts_as_busy(self):
        f = Fake()
        f.stale[SPOT] = True
        f.streaming[SPOT] = None
        f.s.step()
        self.assertEqual(f.restarted, [])

    def test_a_restart_by_the_diagnostics_mode_holds_this_one_back(self):
        f = Fake()
        f.stale[SPOT] = True
        f.last[SPOT] = f.now - 5  # the diagnostics mode restarted it just now
        f.s.step()
        self.assertEqual(f.restarted, [])

    def test_a_restart_that_does_not_take_is_retried_after_a_pause(self):
        f = Fake()
        f.stale[SPOT] = True
        f.s.step()
        f.now += MOD.STALE_RETRY_S - 1
        self.assertEqual(f.s.step(), MOD.STALE_POLL_S)
        self.assertEqual(f.restarted, [SPOT], "not hammered")
        f.now += 2
        f.s.step()
        self.assertEqual(f.restarted, [SPOT, SPOT])

    def test_each_service_is_judged_on_its_own(self):
        f = Fake()
        f.stale[SPOT] = True
        f.stale[AIR] = True
        f.playing.add("airplay")
        f.s.step()
        self.assertEqual(f.restarted, [SPOT])

    def test_the_bridge_builds_one_and_main_starts_it(self):
        src = open(DAEMON).read()
        self.assertIn("self.stale_services = StaleUserServices(", src)
        self.assertIn("threading.Thread(target=bridge.stale_services.run, daemon=True).start()", src)

    def test_never_while_an_update_job_runs(self):
        # A half-installed system is no place to start a player on its new binary.
        src = open(DAEMON).read()
        wiring = src[src.index("self.stale_services = StaleUserServices(") :]
        wiring = wiring[: wiring.index(")\n")]
        self.assertIn("self.ota.running()", wiring)

    def test_playback_going_idle_wakes_the_check(self):
        b = object.__new__(MOD.Bridge)
        b.lock = MOD.threading.Lock()
        b.clients = {}
        b.stale_services = MOD.StaleUserServices(None, None, None, None, None)
        b.broadcast("nowPlayingChanged", {"source": "spotify", "playing": True})
        self.assertFalse(b.stale_services.wake.is_set())
        b.broadcast("nowPlayingChanged", {"source": "spotify", "playing": False})
        self.assertTrue(b.stale_services.wake.is_set())

    def test_only_a_successful_install_wakes_the_check(self):
        # A failed or interrupted job can leave a new binary next to libraries it
        # does not have yet: restarting into that would crash-loop a player.
        for state, woken in (("done", True), ("failed", False)):
            with self.subTest(state=state):
                b = object.__new__(MOD.Bridge)
                b.lock = MOD.threading.Lock()
                b.clients = {}
                b.update_led = mock_led()
                b.stale_services = MOD.StaleUserServices(None, None, None, None, None)
                b._after_install = lambda: None
                b._ota_finished({"state": state, "phase": state})
                self.assertEqual(b.stale_services.wake.is_set(), woken)

    def test_the_diagnostics_mode_and_this_share_one_restart_record(self):
        b = object.__new__(MOD.Bridge)
        b._user_restarts = {}
        with patch.object(MOD, "_systemctl_user") as sc:
            b._restart_user_unit(SPOT)
        sc.assert_called_once_with("try-restart", SPOT, timeout=45)
        self.assertIn(SPOT, b._user_restarts)


def mock_led():
    class Led:
        def set(self, reason, on):
            pass

        def hold(self, on):
            pass

    return Led()


class TestUnitStreams(unittest.TestCase):
    PACTL = """Sink Input #12
\tDriver: protocol-native.c
\tProperties:
\t\tapplication.name = "ALSA plug-in [librespot]"
\t\tapplication.process.id = "4242"
Sink Input #13
\tProperties:
\t\tapplication.process.id = "777"
"""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.tmp, SPOT))
        with open(os.path.join(self.tmp, SPOT, "cgroup.procs"), "w") as f:
            f.write("4240\n4242\n")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def streams(self, stdout="", rc=0, exc=None, unit=SPOT):
        def run(*a, **kw):
            if exc:
                raise exc
            return subprocess.CompletedProcess(a, rc, stdout=stdout, stderr="")

        with patch.object(MOD, "_USER_CGROUP", self.tmp), patch.object(MOD.subprocess, "run", side_effect=run):
            return MOD._unit_streams(unit)

    def test_a_stream_owned_by_the_unit_is_seen(self):
        self.assertIs(self.streams(self.PACTL), True)

    def test_streams_of_other_processes_are_not_the_unit_s(self):
        self.assertIs(self.streams(self.PACTL.replace('"4242"', '"5000"')), False)

    def test_pulseaudio_not_answering_is_none(self):
        self.assertIsNone(self.streams(rc=1))
        self.assertIsNone(self.streams(exc=subprocess.TimeoutExpired("pactl", 6)))

    def test_a_unit_that_is_not_running_holds_no_stream(self):
        self.assertIs(self.streams(self.PACTL, unit=AIR), False)


class TestProcStale(unittest.TestCase):
    """Against a real process: a copy of `sleep` named like the service binary."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.cgroup = os.path.join(self.tmp, "app.slice")
        os.makedirs(os.path.join(self.cgroup, SPOT))
        self.exe = os.path.join(self.tmp, "librespot")
        shutil.copy(shutil.which("sleep"), self.exe)
        self.proc = subprocess.Popen([self.exe, "30"])
        with open(os.path.join(self.cgroup, SPOT, "cgroup.procs"), "w") as f:
            f.write(f"{self.proc.pid}\n")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                with open(f"/proc/{self.proc.pid}/comm") as f:
                    if f.read().strip() == "librespot":
                        break
            except OSError:
                pass
            time.sleep(0.02)

    def tearDown(self):
        self.proc.kill()
        self.proc.wait()
        shutil.rmtree(self.tmp)

    def stale(self, unit=SPOT, exe="librespot"):
        with patch.object(MOD, "_USER_CGROUP", self.cgroup):
            return MOD._proc_stale(unit, exe)

    def test_a_process_on_its_current_binary_is_not_stale(self):
        self.assertIs(self.stale(), False)

    def test_a_process_whose_binary_was_replaced_is_stale(self):
        # apk renames the new binary over the old one; the old inode lives on.
        new = self.exe + ".new"
        shutil.copy(self.exe, new)
        os.rename(new, self.exe)
        self.assertIs(self.stale(), True)

    def test_a_unit_that_is_not_running_is_none(self):
        self.assertIsNone(self.stale(unit=AIR, exe="shairport-sync"))

    def test_a_launcher_that_has_not_exec_d_its_binary_is_none(self):
        self.assertIsNone(self.stale(exe="shairport-sync"))


if __name__ == "__main__":
    unittest.main()
