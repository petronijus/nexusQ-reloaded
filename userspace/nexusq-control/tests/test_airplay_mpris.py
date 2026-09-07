"""AirPlay through shairport-sync's MPRIS interface.

2026-09-07, Petr: "ted muzeme pridat dalsi audio source aby byl presne takhle
ovladanej?" — after Spotify got a card, a queue and a position bar. AirPlay can,
and almost entirely with what is already there: shairport-sync is built with
metadata + dbus + mpris, and once it is pointed at the SESSION bus it publishes
title/artist/album, length, position and the four transport methods.

Two things this file exists to hold still.

**Cost.** Petr's condition was that none of this may make the Q slower. So
nothing polls: the watcher blocks on `busctl monitor` and reads properties only
after shairport has announced a change, which happens only when somebody is
using AirPlay. There is no timer here and there must never be one — a test
below asserts the module does not grow one.

**Decoding.** busctl's JSON wraps every value as {"type":..,"data":..} and an
artist arrives as a LIST even when there is one of them, so a naive read renders
`['Miles Davis']` under the sphere. And `Stopped` has to clear the card, the
same rule librespot's `stopped` got, or a finished AirPlay session stays on
screen forever.

⚠️ **The bus monitor is gone, and its removal is the lesson.** The first design
watched shairport's MPRIS signals with `busctl monitor`. It failed twice in one
evening: it fed itself (each property read we made put eight messages on the
bus, which the watcher read as news — 11 % busy to 68 %, 59 °C to 85 °C in a
minute), and once filtered, the signals we actually wanted never arrived, so the
app never learned playback had started and its play/pause icon sat inverted.
State now comes from PulseAudio, which this daemon has watched reliably for
months and which cannot feed itself. MPRIS is kept for the BUTTONS only — one
call per press, no monitor.
"""
import importlib.machinery
import importlib.util
import json
import os
import threading
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _Run:
    """A stand-in for subprocess.run: returncode + stdout, and a record of argv."""

    def __init__(self, out="", rc=0):
        self.out, self.rc, self.calls = out, rc, []

    def __call__(self, argv, **kw):
        self.calls.append(argv)
        return mock.Mock(returncode=self.rc, stdout=self.out, stderr="")


class _Bridge:
    def __init__(self, mod):
        self.lock = threading.Lock()
        self.transports = {"airplay": mod.AirPlayTransport()}
        self.state = {"nowPlaying": {"playing": False, "artist": "", "track": "",
                                     "album": "", "artUrl": "", "source": "",
                                     "transport": "none"}}
        self.sent = []
        self.airplay_sync = mod.Bridge.airplay_sync.__get__(self)
        self._apply_transport = mod.Bridge._apply_transport.__get__(self)
        self.transport_for = mod.Bridge.transport_for.__get__(self)

    def broadcast(self, event, data):
        self.sent.append((event, data))


PLAYING = json.dumps({"type": "s", "data": "Playing"})
STOPPED = json.dumps({"type": "s", "data": "Stopped"})
META = json.dumps({"type": "a{sv}", "data": {
    "xesam:title": {"type": "s", "data": "So What"},
    # A LIST, which is what MPRIS always sends, even for one artist.
    "xesam:artist": {"type": "as", "data": ["Miles Davis"]},
    "xesam:album": {"type": "s", "data": "Kind of Blue"},
    "mpris:artUrl": {"type": "s", "data": "file:///tmp/cover.jpg"},
}})


class TestMprisDecoding(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()

    def test_a_property_is_unwrapped_from_busctl_json(self):
        with mock.patch.object(self.mod.subprocess, "run", _Run(PLAYING)):
            self.assertEqual(self.mod._mpris_get("PlaybackStatus"), "Playing")

    def test_an_artist_list_becomes_one_line(self):
        with mock.patch.object(self.mod.subprocess, "run", _Run(META)):
            m = self.mod._mpris_metadata()
        self.assertEqual(m["xesam:artist"], "Miles Davis")
        self.assertEqual(m["xesam:title"], "So What")

    def test_several_artists_join(self):
        payload = json.dumps({"type": "a{sv}", "data": {
            "xesam:artist": {"type": "as", "data": ["Ella Fitzgerald", "Louis Armstrong"]}}})
        with mock.patch.object(self.mod.subprocess, "run", _Run(payload)):
            m = self.mod._mpris_metadata()
        self.assertEqual(m["xesam:artist"], "Ella Fitzgerald, Louis Armstrong")

    def test_shairport_absent_is_none_not_a_crash(self):
        """Before the first AirPlay session the name is simply not on the bus —
        the normal state, not an error."""
        with mock.patch.object(self.mod.subprocess, "run", _Run("", rc=1)):
            self.assertIsNone(self.mod._mpris_get("PlaybackStatus"))
            self.assertEqual(self.mod._mpris_metadata(), {})

    def test_garbage_output_is_none(self):
        with mock.patch.object(self.mod.subprocess, "run", _Run("not json")):
            self.assertIsNone(self.mod._mpris_get("PlaybackStatus"))


class TestAirPlayTransport(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()
        self.t = self.mod.AirPlayTransport()

    def test_controllable_only_while_a_session_exists(self):
        for status, expected in (("Playing", True), ("Paused", True), ("Stopped", False)):
            payload = json.dumps({"type": "s", "data": status})
            with mock.patch.object(self.mod.subprocess, "run", _Run(payload)):
                self.assertEqual(self.t.can_control(), expected, status)

    def test_methods_map_to_mpris_calls(self):
        for method, call in (("playPause", "PlayPause"), ("next", "Next"),
                             ("previous", "Previous")):
            runner = _Run("")
            with mock.patch.object(self.mod.subprocess, "run", runner):
                self.t.command(method)
            self.assertIn(call, runner.calls[-1])

    def test_an_unknown_method_is_refused(self):
        with self.assertRaises(self.mod.Err):
            self.t.command("selfDestruct")

    def test_a_refusal_from_mpris_surfaces(self):
        with mock.patch.object(self.mod.subprocess, "run", _Run("", rc=1)):
            with self.assertRaises(self.mod.Err):
                self.t.command("next")


class TestAirPlayStateFromPulse(unittest.TestCase):
    """Play/pause now comes from PA's view of shairport's sink-input."""

    PLAYING_SI = "Sink Input #7\n\tCorked: no\n\tapplication.name = \"ALSA plug-in [shairport-sync]\"\n"
    PAUSED_SI = "Sink Input #7\n\tCorked: yes\n\tapplication.name = \"ALSA plug-in [shairport-sync]\"\n"
    OTHER_SI = "Sink Input #4\n\tCorked: no\n\tapplication.name = \"librespot\"\n"

    def setUp(self):
        self.mod = load_daemon()
        self.b = _Bridge(self.mod)

    def _state(self, out):
        with mock.patch.object(self.mod.subprocess, "run", _Run(out)):
            return self.mod.airplay_pa_state(self.b)

    def test_uncorked_shairport_is_playing(self):
        self.assertEqual(self._state(self.PLAYING_SI), "playing")

    def test_corked_shairport_is_paused(self):
        self.assertEqual(self._state(self.PAUSED_SI), "paused")

    def test_no_shairport_at_all_is_none(self):
        self.assertIsNone(self._state(self.OTHER_SI))
        self.assertIsNone(self._state(""))

    def test_another_app_playing_is_not_airplay(self):
        self.assertIsNone(self._state(self.OTHER_SI + "\n"))


class TestAirPlaySync(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()
        self.b = _Bridge(self.mod)

    def _sync(self, state, meta=META):
        with mock.patch.object(self.mod.subprocess, "run", _Run(meta)):
            self.b.airplay_sync(state)
        return self.b.state["nowPlaying"]

    def test_playing_marks_it_playing_and_controllable(self):
        np = self._sync("playing")
        self.assertTrue(np["playing"])
        self.assertEqual(np["source"], "airplay")
        self.assertEqual(np["transport"], "device")

    def test_paused_keeps_the_session_but_stops_playing(self):
        """THE symptom: the app's icon must follow the real state, or pause
        becomes a one-way door with the indicator inverted."""
        self._sync("playing")
        np = self._sync("paused")
        self.assertFalse(np["playing"])
        self.assertEqual(np["source"], "airplay")
        self.assertEqual(np["transport"], "device",
                         "paused is still controllable — that is how you resume")

    def test_session_gone_clears_the_card(self):
        self._sync("playing")
        np = self._sync(None)
        self.assertEqual(np["source"], "")
        self.assertFalse(np["playing"])
        self.assertEqual(np["transport"], "none")

    def test_it_does_not_steal_the_screen_from_spotify(self):
        with self.b.lock:
            self.b.state["nowPlaying"] = dict(self.b.state["nowPlaying"],
                                              track="Kinkajou", source="spotify",
                                              playing=True)
        for state in ("playing", "paused", None):
            np = self._sync(state)
            self.assertEqual(np["source"], "spotify", state)
            self.assertEqual(np["track"], "Kinkajou", state)

    def test_no_metadata_is_fine_and_still_controllable(self):
        """AirPlay from macOS system audio sends none at all — measured. A blank
        card with live buttons is the honest rendering."""
        empty = json.dumps({"type": "a{sv}", "data": {}})
        np = self._sync("playing", meta=empty)
        self.assertEqual(np["track"], "")
        self.assertEqual(np["transport"], "device")

    def test_an_unchanged_state_wakes_nobody(self):
        """PA fires sink-input events for volume and more; re-broadcasting an
        identical state would spam every connected app."""
        self._sync("playing")
        self.b.sent.clear()
        self._sync("playing")
        self.assertEqual(self.b.sent, [])


class TestTheBusMonitorIsGone(unittest.TestCase):
    """It ran away once; it must not come back by accident."""

    def test_no_bus_monitor_anywhere(self):
        src = open(DAEMON).read()
        self.assertNotIn("airplay_watch_thread", src,
                         "the bus-monitor watcher must stay gone")
        state_fn = src[src.index("def airplay_pa_state"):src.index("def eq_restore_thread")]
        self.assertIn("pactl", state_fn, "state comes from PulseAudio")
        # The docstring EXPLAINS the monitor that was removed, so match the
        # CALL, not the word.
        self.assertNotIn('"monitor"', src)

    def test_mpris_is_only_reads_and_calls(self):
        """What is left of busctl must be short-lived: get-property and call."""
        src = open(DAEMON).read()
        for line in src.splitlines():
            if '"busctl"' in line or "'busctl'" in line:
                self.assertNotIn("monitor", line)


if __name__ == "__main__":
    unittest.main()
