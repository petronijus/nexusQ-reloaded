"""The connection chime (Petr, 2026-09-28): the stock Nexus Q's polaris chime
when something takes the Q -- Spotify, Bluetooth, AirPlay or Roon.

What is pinned here is WHEN it plays, because a chime in the wrong place is
worse than none: at midnight when librespot re-authenticates on its own, on
every resume after a pause, or on a bridge restart in the middle of a song.

- Spotify and Bluetooth say when they connect (librespot's session_connected,
  a bluez card appearing): each is a chime, a duplicate within seconds is not.
- AirPlay and Roon only start and stop sending audio: a start is a new
  connection only after CHIME_GAP_S without that source, and a source already
  running when the bridge starts is not announced.
- Two chimes never play over each other, and a missing sound file is quiet.
"""
import importlib.machinery
import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")
ONEVENT = os.path.join(HERE, "..", "nexusq-onevent")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()


class _Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def chime(clock=None):
    played = []
    c = MOD.Chime(path="/x/polaris.ogg", play=lambda p: played.append(p) or True,
                  clock=clock or _Clock())
    return c, played


class TestExplicitSources(unittest.TestCase):
    def test_a_connection_chimes(self):
        c, played = chime()
        self.assertTrue(c.connected("spotify"))
        self.assertEqual(played, ["/x/polaris.ogg"])

    def test_a_duplicate_within_seconds_does_not(self):
        clock = _Clock()
        c, played = chime(clock)
        c.connected("spotify")
        clock.t += MOD.CHIME_DEDUPE_S - 1
        self.assertFalse(c.connected("spotify"))
        clock.t += 2
        self.assertTrue(c.connected("spotify"))
        self.assertEqual(len(played), 2)

    def test_sources_are_independent(self):
        c, played = chime()
        c.connected("spotify")
        self.assertTrue(c.connected("bluetooth"))
        self.assertEqual(len(played), 2)

    def test_explicit_sources_chime_even_right_after_start(self):
        # a Spotify selection seconds after a bridge restart is still a person
        c, played = chime()
        self.assertTrue(c.connected("spotify"))


class TestDerivedSources(unittest.TestCase):
    def after_grace(self):
        clock = _Clock()
        c, played = chime(clock)
        clock.t += MOD.CHIME_START_GRACE_S + 1
        return clock, c, played

    def test_audio_arriving_chimes(self):
        clock, c, played = self.after_grace()
        self.assertTrue(c.activity("airplay", True))
        self.assertEqual(len(played), 1)

    def test_steady_audio_chimes_once(self):
        clock, c, played = self.after_grace()
        for _ in range(5):
            c.activity("airplay", True)
        self.assertEqual(len(played), 1)

    def test_a_pause_is_not_a_new_connection(self):
        clock, c, played = self.after_grace()
        c.activity("roon", True)
        c.activity("roon", False)
        clock.t += MOD.CHIME_GAP_S - 1
        self.assertFalse(c.activity("roon", True))
        self.assertEqual(len(played), 1)

    def test_a_long_silence_is(self):
        clock, c, played = self.after_grace()
        c.activity("roon", True)
        c.activity("roon", False)
        clock.t += MOD.CHIME_GAP_S + 1
        self.assertTrue(c.activity("roon", True))
        self.assertEqual(len(played), 2)

    def test_the_gap_counts_from_when_it_went_quiet(self):
        # an hour of music, then a short pause: still no chime on resume
        clock, c, played = self.after_grace()
        c.activity("airplay", True)
        clock.t += 3600
        c.activity("airplay", True)
        c.activity("airplay", False)
        clock.t += 30
        self.assertFalse(c.activity("airplay", True))

    def test_running_when_the_bridge_started_is_not_announced(self):
        clock = _Clock()
        c, played = chime(clock)
        clock.t += MOD.CHIME_START_GRACE_S - 1
        self.assertFalse(c.activity("airplay", True))
        self.assertEqual(played, [])

    def test_first_arrival_after_start_quietly_is_announced(self):
        # seen idle at start, arrives later: a connection
        clock = _Clock()
        c, played = chime(clock)
        c.activity("roon", False)
        clock.t += 5
        self.assertTrue(c.activity("roon", True))


class TestPlaying(unittest.TestCase):
    def test_never_two_at_once(self):
        with tempfile.NamedTemporaryFile(suffix=".ogg") as f:
            c = MOD.Chime(path=f.name)
            running = mock.Mock()
            running.poll.return_value = None          # still playing
            with mock.patch.object(MOD.subprocess, "Popen", return_value=running) as popen:
                self.assertTrue(c.connected("spotify"))
                self.assertFalse(c.connected("bluetooth"))
                self.assertEqual(popen.call_count, 1)
                running.poll.return_value = 0          # finished
                self.assertTrue(c.connected("roon-like"))
                self.assertEqual(popen.call_count, 2)

    def test_plays_the_file_through_the_user_pulseaudio(self):
        with tempfile.NamedTemporaryFile(suffix=".ogg") as f:
            c = MOD.Chime(path=f.name)
            with mock.patch.object(MOD.subprocess, "Popen") as popen:
                c.connected("spotify")
            argv = popen.call_args.args[0]
            self.assertEqual(argv[0], "paplay")
            self.assertEqual(argv[-1], f.name)
            self.assertEqual(popen.call_args.kwargs["env"]["PULSE_SERVER"], MOD.PULSE_SERVER)

    def test_a_missing_file_is_quiet(self):
        c = MOD.Chime(path="/nonexistent/polaris.ogg")
        with mock.patch.object(MOD.subprocess, "Popen") as popen:
            self.assertFalse(c.connected("spotify"))
        popen.assert_not_called()


class TestBluezCard(unittest.TestCase):
    CARDS = ("0\talsa_card.platform-sound-spdif\tmodule-alsa-card.c\n"
             "1\talsa_card.platform-sound-tas5713\tmodule-alsa-card.c\n"
             "7\tbluez_card.48_EF_1C_00_11_22\tmodule-bluez5-device.c\n")

    def test_a_bluetooth_card(self):
        self.assertEqual(MOD.bluez_card_for(7, self.CARDS), "bluez_card.48_EF_1C_00_11_22")

    def test_other_cards_are_not(self):
        self.assertIsNone(MOD.bluez_card_for(1, self.CARDS))
        self.assertIsNone(MOD.bluez_card_for(17, self.CARDS))   # 1 != 17


class _Recorder:
    def __init__(self):
        self.calls = []

    def connected(self, source):
        self.calls.append(("connected", source))

    def activity(self, source, active):
        self.calls.append(("activity", source, active))


class TestWiring(unittest.TestCase):
    """Each source reaches the chime from where the bridge learns of it."""

    def fake(self, *methods):
        b = mock.Mock()
        b.chime = _Recorder()
        b.lock = threading.Lock()
        for m in methods:
            setattr(b, m, getattr(MOD.Bridge, m).__get__(b))
        return b

    def test_spotify_from_the_librespot_hook(self):
        b = self.fake("on_hook")
        b.on_hook({"kind": "session_connected"})
        self.assertEqual(b.chime.calls, [("connected", "spotify")])

    def test_bluetooth_from_a_new_bluez_card(self):
        b = self.fake("on_pa_card_new")
        out = subprocess.CompletedProcess([], 0, stdout=TestBluezCard.CARDS)
        with mock.patch.object(MOD, "_pactl", return_value=out):
            b.on_pa_card_new(1)
            b.on_pa_card_new(7)
        self.assertEqual(b.chime.calls, [("connected", "bluetooth")])

    def test_the_watcher_hands_card_events_over(self):
        b = mock.Mock()
        proc = mock.Mock()
        proc.stdout = iter(["Event 'new' on card #7\n", "Event 'change' on card #7\n"])
        with mock.patch.object(MOD.subprocess, "Popen", side_effect=[proc, FileNotFoundError]), \
                mock.patch.object(MOD.time, "sleep"):
            MOD.pa_watch_thread(b)
        b.on_pa_card_new.assert_called_once_with(7)

    def test_airplay_from_its_pulseaudio_stream(self):
        b = self.fake("airplay_sync")
        b.state = {"nowPlaying": {"source": "spotify"}}   # someone else on screen
        b.airplay_sync("playing")
        b.airplay_sync(None)
        self.assertEqual(b.chime.calls, [("activity", "airplay", True),
                                         ("activity", "airplay", False)])

    def test_roon_from_its_zone_reaching_the_q(self):
        b = self.fake("roon_sync")
        b.state = {"nowPlaying": {"source": "spotify"}}
        b._roon_our_zone = lambda: "Sphere"
        b.roon_sync()
        b._roon_our_zone = lambda: None
        b.roon_sync()
        self.assertEqual(b.chime.calls, [("activity", "roon", True),
                                         ("activity", "roon", False)])


class TestOneventHook(unittest.TestCase):
    def run_hook(self, event):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "hook.sock")
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            srv.bind(path)
            srv.listen(1)
            srv.settimeout(3)
            got = []

            def accept():
                try:
                    conn, _ = srv.accept()
                    got.append(conn.recv(4096))
                    conn.close()
                except OSError:
                    pass
            t = threading.Thread(target=accept)
            t.start()
            subprocess.run([sys.executable, ONEVENT],
                           env={**os.environ, "PLAYER_EVENT": event,
                                "NEXUSQ_HOOK_SOCK": path}, timeout=10)
            t.join(4)
            srv.close()
            return [json.loads(x) for x in got]

    def test_session_connected_is_forwarded(self):
        self.assertEqual(self.run_hook("session_connected"), [{"kind": "session_connected"}])

    def test_session_disconnected_still_stops(self):
        self.assertEqual(self.run_hook("session_disconnected"), [{"kind": "stopped"}])


if __name__ == "__main__":
    unittest.main()
