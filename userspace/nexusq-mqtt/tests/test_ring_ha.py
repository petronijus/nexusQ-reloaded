"""LED ring control from Home Assistant (2026-09-23).

The mapping from HA commands to bridge calls is pure and tested directly; the
link itself runs against a fake control bridge on a real TCP socket, so the
whole path — getState, broadcast events, a command, its echo — is exercised
without a broker or a device.
"""
import importlib.machinery
import importlib.util
import json
import os
import socket
import threading
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-mqtt")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_mqtt", importlib.machinery.SourceFileLoader("nexusq_mqtt", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()
NODE, PREFIX, DISC = "nexusq_f88fca2048e1", "nexusq", "homeassistant"


def bridge_state(on=True, schedule=False, ambient=True, level=200, brightness=200):
    st = {"brightness": brightness,
          "ring": {"on": on, "clockSynced": True,
                   "schedule": {"enabled": schedule, "off": "23:00", "on": "07:00"}}}
    if ambient is not None:
        st["ambient"] = {"enabled": ambient, "level": level, "clockSynced": True,
                         "location": {"zone": "Europe/Prague", "lat": 50.08, "lon": 14.43}}
    return st


def wait_for(pred, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.02)
    return False


class TestCommands(unittest.TestCase):
    def cmds(self, kind, payload, st=None):
        return MOD.ring_commands(kind, payload, st or bridge_state())

    def test_a_brightness_move_is_not_a_switch(self):
        # HA sends state ON with every brightness move. Passing that on as
        # setRing would count as a manual switch and turn the schedule off.
        self.assertEqual(self.cmds("light", b'{"state": "ON", "brightness": 120}'),
                         [("setBrightness", {"brightness": 120})])

    def test_switching_on_and_off(self):
        off = bridge_state(on=False)
        self.assertEqual(self.cmds("light", b'{"state": "ON"}', off), [("setRing", {"on": True})])
        self.assertEqual(self.cmds("light", b'{"state": "OFF"}'), [("setRing", {"on": False})])
        # on from off with a brightness: the level first, then the switch
        self.assertEqual(self.cmds("light", b'{"state": "ON", "brightness": 50}', off),
                         [("setBrightness", {"brightness": 50}), ("setRing", {"on": True})])

    def test_schedule_times_keep_the_schedule_state(self):
        on = bridge_state(schedule=True)
        self.assertEqual(self.cmds("off_at", b"22:30", on),
                         [("setRingSchedule", {"enabled": True, "off": "22:30"})])
        self.assertEqual(self.cmds("on_at", b"06:15"),
                         [("setRingSchedule", {"enabled": False, "on": "06:15"})])

    def test_switches(self):
        self.assertEqual(self.cmds("schedule", b"ON"), [("setRingSchedule", {"enabled": True})])
        self.assertEqual(self.cmds("ambient", b"OFF"), [("setAmbient", {"enabled": False})])

    def test_malformed_reaches_nothing(self):
        for kind, payload in (("light", b"ON"), ("light", b"[1]"), ("light", b'{"brightness": 0}'),
                              ("light", b'{"brightness": 999}'), ("light", b'{"brightness": true}'),
                              ("light", b"\xff\xfe"), ("schedule", b"on"), ("ambient", b"1"),
                              ("off_at", b"7:00"), ("on_at", b"24:00"), ("off_at", b"23:00; rm"),
                              ("nonsense", b"ON")):
            self.assertEqual(self.cmds(kind, payload), [], (kind, payload))


class TestStatePayload(unittest.TestCase):
    def test_shape(self):
        p = MOD.ring_state_payload(bridge_state(on=False, schedule=True, level=50))
        self.assertEqual(p, {"state": "OFF", "brightness": 200, "color_mode": "brightness",
                             "schedule": True, "off_at": "23:00", "on_at": "07:00",
                             "ambient": True, "level_pct": 25})

    def test_a_pre_ring_bridge_has_no_payload(self):
        self.assertIsNone(MOD.ring_state_payload({"brightness": 200}))

    def test_a_pre_ambient_bridge_leaves_ambient_out(self):
        p = MOD.ring_state_payload(bridge_state(ambient=None))
        self.assertNotIn("ambient", p)
        self.assertNotIn("level_pct", p)


class TestDiscovery(unittest.TestCase):
    def configs(self, st):
        return dict(MOD.ring_discovery_configs(NODE, "Obývák", PREFIX, st))

    def test_every_entity_with_a_full_bridge(self):
        c = self.configs(bridge_state())
        self.assertEqual(sorted(c), sorted([
            f"light/{NODE}/ring/config", f"switch/{NODE}/ring_schedule/config",
            f"text/{NODE}/ring_off_at/config", f"text/{NODE}/ring_on_at/config",
            f"switch/{NODE}/ambient/config", f"sensor/{NODE}/ring_level/config"]))
        ids = [cfg["unique_id"] for cfg in c.values()]
        self.assertEqual(len(ids), len(set(ids)))
        light = c[f"light/{NODE}/ring/config"]
        self.assertEqual(light["schema"], "json")
        self.assertEqual(light["command_topic"], f"{PREFIX}/{NODE}/ring/light/set")
        # the entity is available only while BOTH the Q and its bridge link are
        self.assertEqual(light["availability_mode"], "all")
        self.assertEqual([a["topic"] for a in light["availability"]],
                         [f"{PREFIX}/{NODE}/status", f"{PREFIX}/{NODE}/ring/available"])

    def test_missing_features_delete_their_entities(self):
        c = self.configs(bridge_state(ambient=None))
        self.assertIsNone(c[f"switch/{NODE}/ambient/config"])
        self.assertIsNone(c[f"sensor/{NODE}/ring_level/config"])
        self.assertIsNotNone(c[f"light/{NODE}/ring/config"])
        self.assertTrue(all(v is None for v in self.configs({"brightness": 1}).values()))

    def test_time_pattern_matches_the_bridge(self):
        import re
        cfg = self.configs(bridge_state())[f"text/{NODE}/ring_off_at/config"]
        self.assertTrue(re.match(cfg["pattern"], "23:59"))
        self.assertFalse(re.match(cfg["pattern"], "24:00"))


class FakeBridge:
    """The control bridge's TCP API: getState, the four ring methods, and a
    broadcast of the matching event to every connected client — as the real
    bridge does. `refuse` makes the named methods answer an error."""

    def __init__(self, st):
        self.st = st
        self.calls = []
        self.refuse = set()
        self.clients = []
        self.lock = threading.Lock()
        self.srv = socket.socket()
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(8)
        self.port = self.srv.getsockname()[1]
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            with self.lock:
                self.clients.append(c)
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    def _send(self, c, obj):
        try:
            c.sendall(json.dumps(obj).encode() + b"\n")
        except OSError:
            pass

    def broadcast(self, event, data):
        with self.lock:
            clients = list(self.clients)
        for c in clients:
            self._send(c, {"event": event, "data": data})

    def _serve(self, c):
        buf = b""
        while True:
            try:
                chunk = c.recv(4096)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                req = json.loads(line)
                m, p, rid = req["method"], req.get("params", {}), req.get("id")
                if m == "getState":
                    self._send(c, {"id": rid, "ok": True, "result": self.st})
                    continue
                self.calls.append((m, p))
                if m in self.refuse:
                    self._send(c, {"id": rid, "ok": False,
                                   "error": {"code": "unavailable", "message": "no"}})
                    continue
                event = self.apply(m, p)
                self._send(c, {"id": rid, "ok": True, "result": {}})
                self.broadcast(*event)

    def apply(self, m, p):
        ring = self.st["ring"]
        if m == "setRing":
            ring["on"] = p["on"]
            ring["schedule"]["enabled"] = False
            return "ringChanged", ring
        if m == "setRingSchedule":
            ring["schedule"].update({k: v for k, v in p.items() if k in ("off", "on")},
                                    enabled=p["enabled"])
            return "ringChanged", ring
        if m == "setBrightness":
            self.st["brightness"] = p["brightness"]
            return "brightnessChanged", {"brightness": p["brightness"]}
        if m == "setAmbient":
            self.st["ambient"]["enabled"] = p["enabled"]
            return "ambientChanged", self.st["ambient"]
        raise AssertionError(m)

    def close(self):
        with self.lock:
            clients = list(self.clients)
        for c in clients:
            try:
                c.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            c.close()
        self.srv.close()


class TestLinkAgainstABridge(unittest.TestCase):
    def setUp(self):
        self.bridge = FakeBridge(bridge_state(schedule=True))
        self.addCleanup(self.bridge.close)
        self.published = []
        patches = [mock.patch.object(MOD, "CONTROL_PORT", self.bridge.port),
                   mock.patch.object(MOD, "CONTROL_HOST", "127.0.0.1"),
                   mock.patch.object(MOD, "RING_RETRY_S", 1)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.link = MOD.RingLink(NODE, "Obývák", PREFIX, DISC,
                                 lambda t, p, r: self.published.append((t, p, r)))
        threading.Thread(target=self.link.listen, daemon=True).start()
        threading.Thread(target=self.link.worker, daemon=True).start()
        self.addCleanup(self._stop)

    def _stop(self):
        MOD._shutdown = True
        time.sleep(0.05)
        MOD._shutdown = False

    def last_state(self):
        for t, p, _ in reversed(self.published):
            if t == f"{PREFIX}/{NODE}/ring/state":
                return json.loads(p)
        return None

    def test_state_and_discovery_arrive_on_connect(self):
        self.assertTrue(wait_for(lambda: self.last_state() is not None))
        self.assertEqual(self.last_state()["state"], "ON")
        topics = [t for t, _, _ in self.published]
        self.assertIn(f"{DISC}/light/{NODE}/ring/config", topics)
        self.assertIn((f"{PREFIX}/{NODE}/ring/available", "online", True), self.published)

    def test_a_change_made_elsewhere_reaches_ha_at_once(self):
        # the app (or the 23:00 schedule) switches the ring off: the bridge
        # broadcasts, and HA sees it without waiting for a telemetry tick
        self.assertTrue(wait_for(lambda: self.last_state() is not None))
        ring = dict(self.bridge.st["ring"], on=False)
        self.bridge.broadcast("ringChanged", ring)
        self.assertTrue(wait_for(lambda: self.last_state()["state"] == "OFF"))

    def test_an_ha_command_goes_through_the_bridge_and_comes_back(self):
        self.assertTrue(wait_for(lambda: self.last_state() is not None))
        self.assertTrue(self.link.submit(f"{PREFIX}/{NODE}/ring/light/set", b'{"state": "OFF"}'))
        self.assertTrue(wait_for(lambda: self.last_state()["state"] == "OFF"))
        self.assertEqual(self.bridge.calls, [("setRing", {"on": False})])
        # the bridge's rule, not ours: a manual switch ended the schedule
        self.assertFalse(self.last_state()["schedule"])

    def test_a_refused_command_republishes_the_truth(self):
        self.assertTrue(wait_for(lambda: self.last_state() is not None))
        self.bridge.refuse.add("setAmbient")
        n = len(self.published)
        self.link.submit(f"{PREFIX}/{NODE}/ring/ambient/set", b"OFF")
        self.assertTrue(wait_for(lambda: any(
            t == f"{PREFIX}/{NODE}/ring/state" for t, _, _ in self.published[n:])))
        self.assertTrue(self.last_state()["ambient"])

    def test_foreign_topics_are_not_ours(self):
        self.assertFalse(self.link.submit("roon/Obyvak/state", b"playing"))
        self.assertFalse(self.link.submit(f"{PREFIX}/other_node/ring/light/set", b'{"state":"OFF"}'))

    def test_bridge_restart_marks_unavailable_then_recovers(self):
        self.assertTrue(wait_for(lambda: self.last_state() is not None))
        port = self.bridge.port
        self.bridge.close()
        self.assertTrue(wait_for(lambda: (f"{PREFIX}/{NODE}/ring/available", "offline", True)
                                 in self.published))
        # a new bridge on the same port (the service restarted)
        self.bridge = FakeBridge(bridge_state(on=False))
        self.addCleanup(self.bridge.close)
        p = mock.patch.object(MOD, "CONTROL_PORT", self.bridge.port)
        p.start()
        self.addCleanup(p.stop)
        self.assertNotEqual(port, self.bridge.port)
        self.assertTrue(wait_for(lambda: self.last_state()["state"] == "OFF", timeout=8))


if __name__ == "__main__":
    unittest.main()
