"""Transport routing (PROTOCOL §5).

The point of `nowPlaying.transport` is that a client never has to know which
source is playing to know whether its buttons work. These pin the two ways that
can go wrong: promising `device` for a backend that is not actually there (dead
buttons, the fault the field exists to remove), and routing a command to the
wrong source.
"""

import importlib.machinery
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control_transport",
        importlib.machinery.SourceFileLoader("nexusq_control_transport", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()


class FakeBackend:
    """Stands in for the DACP / Roon backends."""

    def __init__(self, controllable=True, result=None, boom=None):
        self.controllable = controllable
        self.result = result
        self.boom = boom
        self.calls = []

    def can_control(self):
        return self.controllable

    def command(self, method):
        self.calls.append(method)
        if self.boom:
            raise self.boom
        return self.result


class Bridge:
    """The routing half of the bridge, without standing a whole daemon up."""

    def __init__(self, source="", playing=False):
        import threading
        self.lock = threading.Lock()
        self.transports = {}
        self.state = {"nowPlaying": {"playing": playing, "artist": "", "track": "",
                                     "album": "", "artUrl": "", "source": source,
                                     "transport": "none"}}
        self.sent = []

    def broadcast(self, ev, data):
        self.sent.append((ev, data))

    transport_for = MOD.Bridge.transport_for
    _apply_transport = MOD.Bridge._apply_transport
    dispatch_transport = MOD.Bridge.dispatch_transport


class TestTransportFor(unittest.TestCase):
    def test_spotify_is_always_the_clients_job(self):
        b = Bridge(source="spotify")
        self.assertEqual(b.transport_for("spotify"), "spotify-web")

    def test_a_source_with_no_backend_promises_nothing(self):
        b = Bridge(source="airplay")
        self.assertEqual(b.transport_for("airplay"), "none")

    def test_a_backend_that_cannot_control_yet_promises_nothing(self):
        # e.g. AirPlay connected but the sender has not sent its DACP token
        b = Bridge(source="airplay")
        b.transports["airplay"] = FakeBackend(controllable=False)
        self.assertEqual(b.transport_for("airplay"), "none")

    def test_a_live_backend_is_device(self):
        b = Bridge(source="airplay")
        b.transports["airplay"] = FakeBackend()
        self.assertEqual(b.transport_for("airplay"), "device")

    def test_nothing_playing_is_none(self):
        b = Bridge(source="")
        b.transports["airplay"] = FakeBackend()
        self.assertEqual(b._apply_transport(dict(b.state["nowPlaying"]))["transport"],
                         "none")


class TestDispatch(unittest.TestCase):
    def test_spotify_is_refused_with_a_reason_naming_the_field(self):
        b = Bridge(source="spotify", playing=True)
        with self.assertRaises(MOD.Err) as cm:
            b.dispatch_transport("playPause")
        self.assertIn("spotify-web", str(cm.exception))

    def test_a_source_without_a_backend_is_refused(self):
        b = Bridge(source="airplay", playing=True)
        with self.assertRaises(MOD.Err):
            b.dispatch_transport("next")

    def test_the_command_reaches_the_backend_of_the_PLAYING_source(self):
        b = Bridge(source="airplay", playing=True)
        air, roon = FakeBackend(result={}), FakeBackend(result={})
        # roon FIRST on purpose: dicts keep insertion order, so registering the
        # playing source first lets a "just take the first backend" bug pass.
        b.transports["roon"], b.transports["airplay"] = roon, air
        b.dispatch_transport("next")
        self.assertEqual(air.calls, ["next"])
        self.assertEqual(roon.calls, [], "went to the wrong source")

    def test_a_backend_reporting_play_state_updates_and_announces_it(self):
        b = Bridge(source="airplay", playing=True)
        b.transports["airplay"] = FakeBackend(result={"playing": False})
        res, events = b.dispatch_transport("playPause")
        self.assertEqual(res["playing"], False)
        self.assertEqual(b.state["nowPlaying"]["playing"], False)
        self.assertEqual([e[0] for e in events], ["nowPlayingChanged"])
        self.assertEqual(events[0][1]["transport"], "device")

    def test_a_backend_that_does_not_know_leaves_the_state_alone(self):
        # next/previous cannot report a play state; guessing would flicker the
        # app's button until the source's own metadata caught up.
        b = Bridge(source="airplay", playing=True)
        b.transports["airplay"] = FakeBackend(result={})
        res, events = b.dispatch_transport("next")
        self.assertEqual(events, [])
        self.assertTrue(b.state["nowPlaying"]["playing"])

    def test_a_backend_blowing_up_becomes_unavailable_not_a_traceback(self):
        b = Bridge(source="airplay", playing=True)
        b.transports["airplay"] = FakeBackend(boom=OSError("no route to sender"))
        with self.assertRaises(MOD.Err) as cm:
            b.dispatch_transport("playPause")
        self.assertIn("no route to sender", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
