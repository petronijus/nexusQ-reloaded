"""`stopped` clears now-playing; `paused` does not.

2026-09-07, from Petr with Spotify finished and the app still showing the last
song: "pokud tam ted nic nehraje, nemelo by tam bejt now playing title a image,
proste tam nic neni". The bridge treated `stopped` exactly like `paused` — flip
`playing` to false, keep the metadata — so a track that had ended minutes ago
kept its title (and its cover, once there was one) on the screen with no way for
the app to tell the difference.

Pause and stop are genuinely different and the distinction is the whole point of
this file: a paused track is loaded and about to resume, so it SHOULD stay on
screen; a stopped one is gone. librespot reports both, and only this handler can
tell the app which it was.
"""
import importlib.machinery
import importlib.util
import os
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _Bridge:
    """The smallest thing `on_hook` needs: state, a lock, and a broadcast sink."""

    def __init__(self, mod):
        self.lock = threading.Lock()
        self.state = {
            "volume": 30,
            "muted": False,
            "nowPlaying": {"playing": False, "artist": "", "track": "", "album": "",
                           "artUrl": "", "source": "", "transport": "none"},
        }
        self.sent = []
        # `transport_for` consults this map for non-Spotify sources; empty is
        # the honest default here (no AirPlay/Roon backend exists yet), and it
        # is what makes a cleared source resolve to "none".
        self.transports = {}
        self.sent = self.sent
        # on_hook routes through the real transport mapping, so borrow those
        # too rather than stubbing them — the point is the shipped behaviour.
        self.on_hook = mod.Bridge.on_hook.__get__(self)
        self._apply_transport = mod.Bridge._apply_transport.__get__(self)
        self.transport_for = mod.Bridge.transport_for.__get__(self)

    def broadcast(self, event, data):
        self.sent.append((event, data))


PLAYING = {"kind": "track_changed", "name": "Kinkajou", "artists": "Les Baxter",
           "album": "Ritual of the Savage", "cover": "https://i.example/300"}


class TestNowPlayingStopped(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()
        self.b = _Bridge(self.mod)

    def _np(self):
        return self.b.state["nowPlaying"]

    def test_track_changed_fills_everything(self):
        self.b.on_hook(dict(PLAYING))
        np = self._np()
        self.assertEqual(np["track"], "Kinkajou")
        self.assertEqual(np["artist"], "Les Baxter")
        self.assertEqual(np["album"], "Ritual of the Savage")
        self.assertEqual(np["artUrl"], "https://i.example/300")
        self.assertEqual(np["source"], "spotify")
        self.assertTrue(np["playing"])

    def test_paused_keeps_the_track_on_screen(self):
        """A paused track is loaded and one tap from resuming — showing it is
        correct, and clearing it here would be the opposite bug."""
        self.b.on_hook(dict(PLAYING))
        self.b.on_hook({"kind": "paused"})
        np = self._np()
        self.assertFalse(np["playing"])
        self.assertEqual(np["track"], "Kinkajou")
        self.assertEqual(np["artUrl"], "https://i.example/300")

    def test_stopped_clears_it(self):
        """THE regression: stopped used to keep the metadata, so the app showed
        a finished song indefinitely."""
        self.b.on_hook(dict(PLAYING))
        self.b.on_hook({"kind": "stopped"})
        np = self._np()
        self.assertFalse(np["playing"])
        self.assertEqual(np["track"], "")
        self.assertEqual(np["artist"], "")
        self.assertEqual(np["album"], "")
        self.assertEqual(np["artUrl"], "")
        self.assertEqual(np["source"], "")

    def test_stopped_is_broadcast_so_clients_hear_it(self):
        """Clearing it in our own dict is half a fix: a connected app only finds
        out through the event."""
        self.b.on_hook(dict(PLAYING))
        self.b.sent.clear()
        self.b.on_hook({"kind": "stopped"})
        events = [e for e, _ in self.b.sent]
        self.assertIn("nowPlayingChanged", events)
        data = dict(self.b.sent[-1][1])
        self.assertEqual(data.get("track", ""), "")

    def test_stop_then_play_again_is_clean(self):
        """No leftovers from the previous song when a new one starts."""
        self.b.on_hook(dict(PLAYING))
        self.b.on_hook({"kind": "stopped"})
        self.b.on_hook({"kind": "track_changed", "name": "Quiet Village",
                        "artists": "Les Baxter", "album": "", "cover": ""})
        np = self._np()
        self.assertEqual(np["track"], "Quiet Village")
        self.assertEqual(np["album"], "")
        self.assertEqual(np["artUrl"], "")
        self.assertTrue(np["playing"])


if __name__ == "__main__":
    unittest.main()
