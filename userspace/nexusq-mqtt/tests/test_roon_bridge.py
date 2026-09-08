"""Roon reaches the Q through this daemon's broker connection.

2026-09-08, Petr: "hele roon ma mqtt, muzes se podivat do extensions ... to by
mozna bylo uplne nejdednodussi, ne?" — and it was, by a long way. Roon is the
one source the Q cannot see for itself: RAAT carries audio and nothing else, so
the endpoint never learns the track and has no local transport. The Core knows
everything, and `fjgalesloot/roon-extension-mqtt` already mirrors every zone
onto the household broker this daemon is already connected to. Reading it costs
one SUBSCRIBE.

Two things here are safety, not plumbing, and are the reason this file exists.

**The subscribe set is bounded.** `roon/#` also carries every output's grouping
candidates and source controls — hundreds of retained messages per zone that
nothing reads. Each forwarded message is a unix-socket connection to the
bridge, so a wildcard here is a burst of work on a two-core box every time the
broker reconnects.

**The publish socket is a WHITELIST.** It exists so the bridge can send
play/pause to one Roon zone. The same broker carries Home Assistant,
zigbee2mqtt, the blinds and both Nexus Qs' telemetry — a bug on the other side
of that socket must not be able to reach any of it.
"""
import importlib.machinery
import importlib.util
import json
import os
import socket
import tempfile
import threading
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


class TestPublishWhitelist(unittest.TestCase):
    """What the bridge is allowed to put on somebody else's broker."""

    def setUp(self):
        self.mod = load_daemon()

    def test_a_zone_command_is_allowed(self):
        self.assertTrue(self.mod._publish_allowed("roon/Sphere/command"))
        self.assertTrue(self.mod._publish_allowed("roon/nexus-speakers/command"))

    def test_nothing_else_on_the_roon_tree_is(self):
        for t in ("roon/Sphere/settings/set/shuffle",
                  "roon/Sphere/outputs/Sphere/volume/set",
                  "roon/Sphere/outputs/Sphere/power",
                  "roon/Sphere/state",
                  "roon/Sphere/command/extra"):
            self.assertFalse(self.mod._publish_allowed(t), t)

    def test_other_peoples_devices_are_not(self):
        """The blinds, the lights, the other Q's telemetry, HA's own tree."""
        for t in ("homeassistant/light/kitchen/set",
                  "zigbee2mqtt/bedroom/set",
                  "blinds-cc1101/living/command",
                  "nexusq-sumperak/health/state",
                  "command", "", "/command"):
            self.assertFalse(self.mod._publish_allowed(t), t)

    def test_wildcards_are_refused(self):
        """A wildcard in a PUBLISH is malformed MQTT, and `roon/+/command`
        would be every zone in the house at once."""
        for t in ("roon/+/command", "roon/#/command", "roon/#"):
            self.assertFalse(self.mod._publish_allowed(t), t)


class TestSubscribeSet(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()

    def test_it_asks_for_what_the_card_needs(self):
        f = self.mod.ROON_FILTERS
        for needed in ("state", "now_playing/three_line/line1",
                       "now_playing/three_line/line2",
                       "now_playing/three_line/line3",
                       "now_playing/image_key", "now_playing/length",
                       "now_playing/seek_position", "is_play_allowed"):
            self.assertTrue(any(x.endswith(needed) for x in f), needed)

    def test_it_is_bounded_not_a_wildcard_dump(self):
        """`roon/#` was the tempting one-liner; it is hundreds of retained
        messages per zone, each of which would be a socket connection."""
        self.assertNotIn("roon/#", self.mod.ROON_FILTERS)
        for x in self.mod.ROON_FILTERS:
            self.assertNotIn("#", x)


class TestForwarding(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()

    def test_the_root_is_stripped_so_the_bridge_sees_zone_first(self):
        sent = []

        class FakeSock:
            def __enter__(s): return s
            def __exit__(s, *a): return False
            def settimeout(s, t): pass
            def connect(s, p): pass
            def sendall(s, b): sent.append(b.decode())

        with mock.patch.object(self.mod.socket, "socket", lambda *a, **k: FakeSock()):
            self.mod.roon_forward("roon/Sphere/now_playing/three_line/line1", b"Prashanti")
        msg = json.loads(sent[0])
        self.assertEqual(msg["kind"], "roon")
        self.assertEqual(msg["topic"], "Sphere/now_playing/three_line/line1")
        self.assertEqual(msg["value"], "Prashanti")

    def test_a_foreign_topic_is_dropped(self):
        sent = []

        class FakeSock:
            def __enter__(s): return s
            def __exit__(s, *a): return False
            def settimeout(s, t): pass
            def connect(s, p): pass
            def sendall(s, b): sent.append(b)

        with mock.patch.object(self.mod.socket, "socket", lambda *a, **k: FakeSock()):
            self.mod.roon_forward("zigbee2mqtt/bedroom/state", b"on")
        self.assertEqual(sent, [])

    def test_a_dead_bridge_never_raises(self):
        """Telemetry must not stop because the bridge is restarting; the
        extension publishes retained, so the next connect re-delivers it."""
        with mock.patch.object(self.mod.socket, "socket",
                               side_effect=OSError("no such socket")):
            self.mod.roon_forward("roon/Sphere/state", b"playing")   # must not raise


class TestClientCanReceive(unittest.TestCase):
    """The client was a publisher only; receiving is new and its framing is
    where a subtle bug would hide."""

    def setUp(self):
        self.mod = load_daemon()

    def _client(self):
        c = self.mod.MqttClient("h", 1883, "id", "u", "p", "w/t", "off")
        return c

    def test_an_incoming_publish_is_decoded(self):
        got = []
        c = self._client()
        c.on_message = lambda t, p: got.append((t, p))
        topic = b"roon/Sphere/state"
        body = len(topic).to_bytes(2, "big") + topic + b"playing"
        c._rxbuf = bytes([0x30]) + self.mod._remaining_len(len(body)) + body
        c.sock = object()
        with mock.patch.object(self.mod.select, "select", return_value=([], [], [])):
            c._drain()
        self.assertEqual(got, [("roon/Sphere/state", b"playing")])

    def test_a_handler_that_throws_does_not_kill_the_daemon(self):
        c = self._client()
        c.on_message = lambda t, p: 1 / 0
        topic = b"roon/Sphere/state"
        body = len(topic).to_bytes(2, "big") + topic + b"playing"
        c._rxbuf = bytes([0x30]) + self.mod._remaining_len(len(body)) + body
        c.sock = object()
        with mock.patch.object(self.mod.select, "select", return_value=([], [], [])):
            c._drain()   # must not raise

    def test_subscribe_builds_a_qos0_packet_per_filter(self):
        c = self._client()
        sent = []
        c._send = lambda b: sent.append(b)
        c.subscribe(["a/b", "c/d"])
        pkt = sent[0]
        self.assertEqual(pkt[0], 0x82)
        self.assertIn(b"a/b", pkt)
        self.assertIn(b"c/d", pkt)
        self.assertTrue(pkt.endswith(b"\x00"), "last filter's QoS byte")

    def test_subscribing_to_nothing_sends_nothing(self):
        c = self._client()
        sent = []
        c._send = lambda b: sent.append(b)
        c.subscribe([])
        self.assertEqual(sent, [])


if __name__ == "__main__":
    unittest.main()
