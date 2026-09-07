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
        self.airplay_refresh = mod.Bridge.airplay_refresh.__get__(self)
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


class TestAirPlayNowPlaying(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()
        self.b = _Bridge(self.mod)

    def _refresh(self, status_payload, meta_payload=META):
        outs = [status_payload, meta_payload]

        def run(argv, **kw):
            return mock.Mock(returncode=0, stdout=outs.pop(0) if outs else "", stderr="")

        with mock.patch.object(self.mod.subprocess, "run", run):
            self.b.airplay_refresh()
        return self.b.state["nowPlaying"]

    def test_playing_fills_the_card_and_marks_it_controllable(self):
        np = self._refresh(PLAYING)
        self.assertEqual(np["track"], "So What")
        self.assertEqual(np["artist"], "Miles Davis")
        self.assertEqual(np["album"], "Kind of Blue")
        self.assertEqual(np["source"], "airplay")
        self.assertTrue(np["playing"])
        # `device` is what tells the app its own buttons will work.
        self.assertEqual(np["transport"], "device")

    def test_art_is_not_forwarded_because_it_is_a_local_file(self):
        """mpris:artUrl is file:// in shairport's cache. Passing it on would put
        a path in the app that the phone cannot fetch, which renders as a broken
        image rather than the placeholder."""
        np = self._refresh(PLAYING)
        self.assertEqual(np["artUrl"], "")

    def test_stopped_clears_the_card(self):
        self._refresh(PLAYING)
        np = self._refresh(STOPPED)
        self.assertEqual(np["track"], "")
        self.assertEqual(np["source"], "")
        self.assertFalse(np["playing"])
        self.assertEqual(np["transport"], "none")

    def test_stopped_does_not_clobber_another_source(self):
        """A stray AirPlay `Stopped` must not wipe a Spotify track: shairport
        announces its own idleness whether or not it is what is playing."""
        with self.b.lock:
            self.b.state["nowPlaying"] = dict(self.b.state["nowPlaying"],
                                              track="Kinkajou", source="spotify",
                                              playing=True)
        np = self._refresh(STOPPED)
        self.assertEqual(np["track"], "Kinkajou")
        self.assertEqual(np["source"], "spotify")

    def test_one_change_does_not_read_the_status_twice(self):
        """The watcher reads PlaybackStatus, then Metadata. `_apply_transport`
        must NOT go and read PlaybackStatus a third time — that is the same
        question answered milliseconds earlier, and the Q may not get slower for
        having AirPlay."""
        calls = []

        outs = [PLAYING, META]

        def run(argv, **kw):
            calls.append(argv)
            return mock.Mock(returncode=0, stdout=outs.pop(0) if outs else "", stderr="")

        with mock.patch.object(self.mod.subprocess, "run", run):
            self.b.airplay_refresh()

        reads = [c for c in calls if "get-property" in c]
        self.assertEqual(len(reads), 2,
                         f"expected PlaybackStatus + Metadata, got {len(reads)} reads")
        self.assertEqual(self.b.state["nowPlaying"]["transport"], "device")

    def test_a_change_is_broadcast(self):
        self._refresh(PLAYING)
        self.assertIn("nowPlayingChanged", [e for e, _ in self.b.sent])


class TestTheRunawayCannotComeBack(unittest.TestCase):
    """The regression that mattered, 2026-09-07.

    The first cut refreshed on ANY line the bus monitor produced. Measured on
    the box: idle, the monitor is silent — but each property read WE make puts
    eight messages on the bus (the call, its return, and NameOwnerChanged as our
    short-lived busctl client appears and goes). So one read caused two reads,
    those sixteen lines, and so on. The Q went 11 % → 68 % busy, pinned at
    1.2 GHz, and 59 °C → 85 °C within a minute.

    The filter below is the whole defence, so these assertions are the shapes of
    our OWN traffic, which must never be mistaken for news.
    """

    def setUp(self):
        self.mod = load_daemon()

    def test_a_properties_changed_signal_is_news(self):
        line = json.dumps({"type": "signal", "member": "PropertiesChanged",
                           "interface": "org.freedesktop.DBus.Properties",
                           "path": "/org/mpris/MediaPlayer2"})
        self.assertTrue(self.mod._mpris_is_change(line))

    def test_our_own_property_read_is_not(self):
        """A method_call and its return: what a busctl get-property looks like
        on the wire. Reacting to these is what fed the loop."""
        for kind in ("method_call", "method_return"):
            line = json.dumps({"type": kind, "member": "Get",
                               "interface": "org.freedesktop.DBus.Properties",
                               "path": "/org/mpris/MediaPlayer2"})
            self.assertFalse(self.mod._mpris_is_change(line), kind)

    def test_the_bus_announcing_our_own_client_is_not(self):
        """NameOwnerChanged fires as our short-lived busctl connects and goes —
        twice per read, and it IS a signal, so only the member check stops it."""
        line = json.dumps({"type": "signal", "member": "NameOwnerChanged",
                           "interface": "org.freedesktop.DBus",
                           "path": "/org/freedesktop/DBus"})
        self.assertFalse(self.mod._mpris_is_change(line))

    def test_a_signal_on_another_path_is_not(self):
        line = json.dumps({"type": "signal", "member": "PropertiesChanged",
                           "interface": "org.freedesktop.DBus.Properties",
                           "path": "/org/pulseaudio/core1"})
        self.assertFalse(self.mod._mpris_is_change(line))

    def test_junk_and_blanks_are_not(self):
        for line in ("", "   ", "not json", "{", '{"type":"signal"}'):
            self.assertFalse(self.mod._mpris_is_change(line), repr(line))

    def test_bursts_are_coalesced(self):
        """One track change makes shairport emit several PropertiesChanged, and
        each refresh is two busctl spawns — so there is a debounce, and it has
        to be short enough that nobody sees it."""
        self.assertGreater(self.mod._AIRPLAY_DEBOUNCE_S, 0)
        self.assertLess(self.mod._AIRPLAY_DEBOUNCE_S, 1.0)

    def test_the_watcher_filters_before_it_acts(self):
        """Belt and braces: the loop body must consult the filter, not the raw
        line. A refresh reached from an unfiltered line is the runaway."""
        src = open(DAEMON).read()
        i = src.index("def airplay_watch_thread")
        body = src[i:src.index("def eq_restore_thread")]
        j = body.index("for line in proc.stdout")
        k = body.index("airplay_refresh")
        self.assertIn("_mpris_is_change", body[j:k],
                      "the read loop must filter before refreshing")


class TestCostsNothingWhenIdle(unittest.TestCase):
    """Petr's condition: none of this may make the Q slower."""

    def test_the_watcher_has_no_timer(self):
        src = open(DAEMON).read()
        i = src.index("def airplay_watch_thread")
        body = src[i:src.index("def eq_restore_thread")]
        self.assertIn("busctl", body)
        self.assertIn("monitor", body)
        # A sleep exists only on the RETRY path; a periodic poll would show up
        # as a timer or a sleep inside the read loop.
        self.assertNotIn("Timer", body)
        self.assertNotIn("threading.Event", body)

    def test_nothing_reads_mpris_on_a_schedule(self):
        """The only callers of the property reads are the watcher (after an
        announcement) and the transport backend (on a button press)."""
        src = open(DAEMON).read()
        for line in src.splitlines():
            if "_mpris_get(" in line and "def " not in line:
                self.assertNotIn("Timer", line)


if __name__ == "__main__":
    unittest.main()
