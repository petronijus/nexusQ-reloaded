"""Roon now-playing and control, fed by the Core's MQTT extension.

2026-09-08. Roon is the one source the Q cannot see for itself — RAAT carries
audio and nothing else — so everything here comes from the Core, mirrored onto
the household broker by `fjgalesloot/roon-extension-mqtt` and forwarded by
nexusq-mqtt. That makes Roon the *richest* of the three sources: title, artist,
album, a real fetchable cover, length and position, and working buttons.

**The safety property is the whole file.** That broker carries EVERY zone in the
house. Roon playing in the kitchen must never appear on the Q's screen, and a
button on the Q's screen must never pause the kitchen. The gate is the Q's own
`roon_in` PulseAudio source: Roon reaches this box only as RAAT audio, so if
that source is not RUNNING then whatever Roon is doing, it is not doing it here.

That gate is also what makes the zone self-identifying. A configured zone name
would go stale the moment Petr groups the Q with another output — Roon then
renames the zone (`Sphere` becomes `Home`, seen live on his Core) and a
hardcoded name would follow the wrong music or none at all.
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


class _Pulse:
    """Stands in for the PA probe: says whether roon_in is running."""

    def __init__(self, state="SUSPENDED"):
        self.state = state

    def source_state(self, name):
        return self.state if name == "roon_in" else ""


class _Bridge:
    def __init__(self, mod, pulse_state="RUNNING"):
        self.lock = threading.Lock()
        self.pulse = _Pulse(pulse_state)
        self.roon = {}
        self._roon_zone = None
        self.transports = {"roon": mod.RoonTransport(self)}
        self.state = {"nowPlaying": {"playing": False, "artist": "", "track": "",
                                     "album": "", "artUrl": "", "source": "",
                                     "transport": "none"}}
        self.sent = []
        for name in ("on_roon", "roon_sync", "_roon_our_zone", "roon_zone_name",
                     "roon_zone_state", "_apply_transport", "transport_for"):
            setattr(self, name, getattr(mod.Bridge, name).__get__(self))

    def broadcast(self, event, data):
        self.sent.append((event, data))


#: One zone, as the extension publishes it.
def feed(b, zone="Sphere", state="playing", title="Prashanti",
         artist="Ravi Shankar / Philip Glass", album="Passages", key="abc123"):
    for field, value in (
            ("state", state),
            ("is_play_allowed", "true"),
            ("is_pause_allowed", "true"),
            ("now_playing/three_line/line1", title),
            ("now_playing/three_line/line2", artist),
            ("now_playing/three_line/line3", album),
            ("now_playing/image_key", key)):
        b.on_roon(f"{zone}/{field}", value)


class TestOnlyOurOwnMusic(unittest.TestCase):
    """The safety property."""

    def setUp(self):
        self.mod = load_daemon()

    def test_roon_playing_elsewhere_never_reaches_the_screen(self):
        """THE one that matters: the kitchen is playing, this box is silent."""
        b = _Bridge(self.mod, pulse_state="SUSPENDED")
        feed(b, zone="Kitchen")
        np = b.state["nowPlaying"]
        self.assertEqual(np["source"], "")
        self.assertEqual(np["track"], "")
        self.assertEqual(np["transport"], "none")

    def test_it_appears_once_the_audio_is_actually_here(self):
        b = _Bridge(self.mod, pulse_state="RUNNING")
        feed(b)
        np = b.state["nowPlaying"]
        self.assertEqual(np["track"], "Prashanti")
        self.assertEqual(np["artist"], "Ravi Shankar / Philip Glass")
        self.assertEqual(np["album"], "Passages")
        self.assertEqual(np["source"], "roon")
        self.assertTrue(np["playing"])
        self.assertEqual(np["transport"], "device")

    def test_the_audio_stopping_clears_it(self):
        b = _Bridge(self.mod, pulse_state="RUNNING")
        feed(b)
        b.pulse.state = "SUSPENDED"
        b.roon_sync()
        np = b.state["nowPlaying"]
        self.assertEqual(np["source"], "")
        self.assertFalse(np["playing"])
        self.assertEqual(np["transport"], "none")

    def test_two_zones_playing_at_once_is_not_guessed(self):
        """Grouped zones and simultaneous playback are both real. With nothing
        to tell them apart, showing one at random would be worse than showing
        none."""
        b = _Bridge(self.mod, pulse_state="RUNNING")
        feed(b, zone="Sphere")
        b.roon.setdefault("Kitchen", {})["state"] = "playing"
        b.roon_sync()
        # It keeps the zone it had already adopted rather than flapping.
        self.assertEqual(b.roon_zone_name(), "Sphere")

    def test_it_does_not_steal_the_screen_from_spotify(self):
        b = _Bridge(self.mod, pulse_state="RUNNING")
        with b.lock:
            b.state["nowPlaying"] = dict(b.state["nowPlaying"],
                                         track="Kinkajou", source="spotify",
                                         playing=True)
        feed(b)
        self.assertEqual(b.state["nowPlaying"]["source"], "spotify")
        self.assertEqual(b.state["nowPlaying"]["track"], "Kinkajou")


class TestArtwork(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()

    def test_a_configured_core_gives_a_fetchable_url(self):
        """Unlike AirPlay's file:// path, the Core serves this over HTTP, so the
        phone can actually load it."""
        b = _Bridge(self.mod, pulse_state="RUNNING")
        with mock.patch.object(self.mod, "_roon_conf",
                               lambda: {"core_image_base": "http://core:9330"}):
            feed(b, key="deadbeef")
        url = b.state["nowPlaying"]["artUrl"]
        self.assertTrue(url.startswith("http://core:9330/api/image/deadbeef"), url)

    def test_no_configured_core_means_no_artwork_not_a_guess(self):
        """The Core's address is the household's; guessing it would put a broken
        image in the app, which is worse than the placeholder."""
        b = _Bridge(self.mod, pulse_state="RUNNING")
        with mock.patch.object(self.mod, "_roon_conf", lambda: {}):
            feed(b, key="deadbeef")
        self.assertEqual(b.state["nowPlaying"]["artUrl"], "")

    def test_no_image_key_means_no_url(self):
        b = _Bridge(self.mod, pulse_state="RUNNING")
        with mock.patch.object(self.mod, "_roon_conf",
                               lambda: {"core_image_base": "http://core:9330"}):
            feed(b, key="")
        self.assertEqual(b.state["nowPlaying"]["artUrl"], "")


class TestControl(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()

    def test_commands_go_to_the_playing_zone_with_roons_own_verbs(self):
        b = _Bridge(self.mod, pulse_state="RUNNING")
        feed(b, zone="Sphere")
        for method, verb in (("playPause", "playpause"), ("next", "next"),
                             ("previous", "previous")):
            sent = {}
            with mock.patch.object(self.mod, "_mqtt_publish",
                                   lambda t, p: sent.update(topic=t, payload=p)):
                b.transports["roon"].command(method)
            self.assertEqual(sent["topic"], "roon/Sphere/command")
            self.assertEqual(sent["payload"], verb)

    def test_no_zone_means_a_clear_refusal_not_a_stray_publish(self):
        b = _Bridge(self.mod, pulse_state="SUSPENDED")
        feed(b, zone="Kitchen")
        with mock.patch.object(self.mod, "_mqtt_publish",
                               side_effect=AssertionError("must not publish")):
            with self.assertRaises(self.mod.Err):
                b.transports["roon"].command("playPause")

    def test_an_unknown_method_is_refused(self):
        b = _Bridge(self.mod, pulse_state="RUNNING")
        feed(b)
        with self.assertRaises(self.mod.Err):
            b.transports["roon"].command("selfDestruct")

    def test_controllable_only_when_roon_says_so(self):
        b = _Bridge(self.mod, pulse_state="RUNNING")
        feed(b)
        self.assertTrue(b.transports["roon"].can_control())
        b.roon["Sphere"]["is_play_allowed"] = "false"
        b.roon["Sphere"]["is_pause_allowed"] = "false"
        self.assertFalse(b.transports["roon"].can_control())


class TestQuiet(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()

    def test_an_unchanged_state_wakes_nobody(self):
        """The extension republishes seek_position every second; re-broadcasting
        an identical now-playing would wake every connected app each time."""
        b = _Bridge(self.mod, pulse_state="RUNNING")
        feed(b)
        b.sent.clear()
        b.on_roon("Sphere/now_playing/seek_position", "42")
        self.assertEqual(b.sent, [])

    def test_a_malformed_topic_is_ignored(self):
        b = _Bridge(self.mod, pulse_state="RUNNING")
        for t in ("", "nofield", "/leadingslash"):
            b.on_roon(t, "x")           # must not raise
        self.assertEqual(b.state["nowPlaying"]["source"], "")


class TestSourceState(unittest.TestCase):
    """The gate reads one field out of `pactl list short sources`."""

    def setUp(self):
        self.mod = load_daemon()

    def test_the_state_is_the_last_column(self):
        # Real layout, taken off the device: index, name, module, spec, state.
        out = ("0\talsa_input.x\tmodule-alsa-card.c\ts16le 2ch 48000Hz\tSUSPENDED\n"
               "6\troon_in\tmodule-alsa-source.c\ts16le 2ch 48000Hz\tRUNNING\n")
        with mock.patch.object(self.mod, "_pactl", lambda *a, **k: out):
            self.assertEqual(self.mod.Pulse().source_state("roon_in"), "RUNNING")
            self.assertEqual(self.mod.Pulse().source_state("nope"), "")

    def test_pactl_failing_is_empty_not_an_exception(self):
        with mock.patch.object(self.mod, "_pactl", lambda *a, **k: None):
            self.assertEqual(self.mod.Pulse().source_state("roon_in"), "")


if __name__ == "__main__":
    unittest.main()
