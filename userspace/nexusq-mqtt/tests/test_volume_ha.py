"""The Q's volume in Home Assistant (nexusq-mqtt r10).

Since device r117 the Q has one volume, the PulseAudio sink, which the app,
the knob, Spotify and AirPlay all move. HA gets a Volume number and a Mute
switch that call the app's own methods, and learns every change from the
bridge's volumeChanged broadcasts -- over the SAME bridge connection as the
LED ring (BridgeFeed).
"""
import json
import os
import sys
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_ring_ha import MOD, NODE, PREFIX, DISC, FakeBridge, bridge_state  # noqa: E402


def wait_for(pred, timeout=5):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.02)
    return False


class TestCommands(unittest.TestCase):
    def test_level(self):
        self.assertEqual(MOD.volume_commands("level", b"37"), [("setVolume", {"volume": 37})])
        self.assertEqual(MOD.volume_commands("level", "37.6"), [("setVolume", {"volume": 38})])
        self.assertEqual(MOD.volume_commands("level", b"0"), [("setVolume", {"volume": 0})])
        for bad in (b"", b"loud", b"-1", b"101", b"nan", b"\xff"):
            with self.subTest(bad=bad):
                self.assertEqual(MOD.volume_commands("level", bad), [])

    def test_mute(self):
        self.assertEqual(MOD.volume_commands("mute", b"ON"), [("setMuted", {"muted": True})])
        self.assertEqual(MOD.volume_commands("mute", b"OFF"), [("setMuted", {"muted": False})])
        self.assertEqual(MOD.volume_commands("mute", b"on"), [])
        self.assertEqual(MOD.volume_commands("other", b"ON"), [])


class TestDiscovery(unittest.TestCase):
    def test_entities_and_the_retired_sensor(self):
        cfgs = dict(MOD.volume_discovery_configs(NODE, "Obývák", PREFIX))
        num = cfgs[f"number/{NODE}/volume_level/config"]
        self.assertEqual((num["min"], num["max"], num["step"]), (0, 100, 1))
        self.assertEqual(num["command_topic"], f"{PREFIX}/{NODE}/volume/set")
        self.assertEqual(num["state_topic"], f"{PREFIX}/{NODE}/volume/state")
        sw = cfgs[f"switch/{NODE}/mute/config"]
        self.assertEqual(sw["command_topic"], f"{PREFIX}/{NODE}/volume/mute/set")
        # the old read-only sensor is deleted, not left stale in HA
        self.assertIsNone(cfgs[f"sensor/{NODE}/volume/config"])
        for c in (num, sw):
            self.assertEqual(c["availability_mode"], "all")
            json.dumps(c)


class TestOneConnection(unittest.TestCase):
    """The ring and the volume share one bridge connection."""

    def setUp(self):
        st = bridge_state()
        st.update(volume=40, muted=False)
        self.bridge = FakeBridge(st)
        self.addCleanup(self.bridge.close)
        self.published = []
        pub = lambda t, p, r: self.published.append((t, p, r))   # noqa: E731
        for p in (mock.patch.object(MOD, "CONTROL_PORT", self.bridge.port),
                  mock.patch.object(MOD, "CONTROL_HOST", "127.0.0.1"),
                  mock.patch.object(MOD, "RING_RETRY_S", 1)):
            p.start()
            self.addCleanup(p.stop)
        self.ring = MOD.RingLink(NODE, "Obývák", PREFIX, DISC, pub)
        self.vol = MOD.VolumeLink(NODE, "Obývák", PREFIX, DISC, pub)
        threading.Thread(target=MOD.BridgeFeed([self.ring, self.vol]).listen, daemon=True).start()
        threading.Thread(target=self.vol.worker, daemon=True).start()
        self.addCleanup(self._stop)

    def _stop(self):
        MOD._shutdown = True
        time.sleep(0.05)
        MOD._shutdown = False

    def vol_state(self):
        for t, p, _ in reversed(self.published):
            if t == f"{PREFIX}/{NODE}/volume/state":
                return json.loads(p)
        return None

    def test_both_get_their_state_from_one_getState(self):
        self.assertTrue(wait_for(lambda: self.vol_state() is not None))
        self.assertEqual(self.vol_state(), {"volume": 40, "muted": False})
        self.assertTrue(wait_for(lambda: any(t == f"{PREFIX}/{NODE}/ring/state"
                                             for t, _, _ in self.published)))
        with self.bridge.lock:
            self.assertEqual(len(self.bridge.clients), 1)

    def test_the_knob_reaches_ha(self):
        self.assertTrue(wait_for(lambda: self.vol_state() is not None))
        self.bridge.broadcast("volumeChanged", {"volume": 55, "muted": False})
        self.assertTrue(wait_for(lambda: self.vol_state() == {"volume": 55, "muted": False}))

    def test_ha_sets_the_volume_and_mute(self):
        self.assertTrue(wait_for(lambda: self.vol_state() is not None))
        self.assertTrue(self.vol.submit(f"{PREFIX}/{NODE}/volume/set", b"62"))
        self.assertTrue(wait_for(lambda: self.vol_state() == {"volume": 62, "muted": False}))
        self.assertTrue(self.vol.submit(f"{PREFIX}/{NODE}/volume/mute/set", b"ON"))
        self.assertTrue(wait_for(lambda: self.vol_state() == {"volume": 62, "muted": True}))
        self.assertEqual(self.bridge.calls, [("setVolume", {"volume": 62}),
                                             ("setMuted", {"muted": True})])

    def test_a_slider_burst_collapses_to_the_last_value(self):
        self.assertTrue(wait_for(lambda: self.vol_state() is not None))
        v = MOD.VolumeLink(NODE, "x", PREFIX, DISC, lambda *a: None, call=lambda *a: None)
        for n in (10, 20, 30, 40):
            v.submit(v.topics["level"], str(n).encode())
        self.assertEqual(v._queue, [("level", b"40")])

    def test_bridge_down_marks_unavailable(self):
        self.assertTrue(wait_for(lambda: self.vol_state() is not None))
        self.bridge.close()
        self.assertTrue(wait_for(lambda: (f"{PREFIX}/{NODE}/volume/available", "offline", True)
                                 in self.published))


if __name__ == "__main__":
    unittest.main()
