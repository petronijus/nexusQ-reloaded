"""Host tests for nexusq-mqtt: the wire protocol against a real (fake) TCP
broker, config validation, collectors on fixture files, and the HA discovery
payload contract. Run from the repo root:

    python3 -m unittest discover -s userspace/nexusq-mqtt/tests -v
"""

import importlib.machinery
import importlib.util
import json
import os
import socket
import struct
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-mqtt")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_mqtt", importlib.machinery.SourceFileLoader(
            "nexusq_mqtt", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()


# --------------------------------------------------------------------------
# a minimal fake MQTT broker: accepts one client, parses packets, records them
# --------------------------------------------------------------------------

class FakeBroker:
    """Accepts one client, parses MQTT packets, records CONNECT + PUBLISHes
    (with the retain bit from the raw header byte), answers CONNACK/PINGRESP."""

    def __init__(self, connack_rc=0):
        self.connack_rc = connack_rc
        self.packets = []          # (type_byte, body) in arrival order
        self.connect = None        # parsed CONNECT dict
        self.raw_publishes = []    # (topic, payload_bytes, retain_bool)
        self._srv = socket.socket()
        self._srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._srv.bind(("127.0.0.1", 0))
        self._srv.listen(1)
        self.port = self._srv.getsockname()[1]
        self.conn = None
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        try:
            self.conn, _ = self._srv.accept()
            self.conn.settimeout(5)
            while True:
                first = self._recv_exact(1)
                if first is None:
                    return
                length = 0
                for shift in range(0, 28, 7):
                    b = self._recv_exact(1)
                    if b is None:
                        return
                    length |= (b[0] & 0x7F) << shift
                    if not b[0] & 0x80:
                        break
                body = self._recv_exact(length) if length else b""
                if length and body is None:
                    return
                ptype = first[0] & 0xF0
                self.packets.append((ptype, body))
                if ptype == 0x10:
                    self.connect = self._parse_connect(body)
                    self.conn.sendall(bytes([0x20, 2, 0, self.connack_rc]))
                elif ptype == 0x30:
                    (n,) = struct.unpack_from("!H", body, 0)
                    self.raw_publishes.append(
                        (body[2:2 + n].decode(), body[2 + n:],
                         bool(first[0] & 0x01)))
                elif ptype == 0xC0:  # PINGREQ -> PINGRESP
                    self.conn.sendall(b"\xd0\x00")
                elif ptype == 0xE0:  # DISCONNECT
                    return
        except OSError:
            pass

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            try:
                chunk = self.conn.recv(n - len(buf))
            except OSError:
                return None
            if not chunk:
                return None
            buf += chunk
        return buf

    @staticmethod
    def _parse_connect(body):
        def take_str(buf, off):
            (n,) = struct.unpack_from("!H", buf, off)
            return buf[off + 2:off + 2 + n].decode(), off + 2 + n

        proto, off = take_str(body, 0)
        level = body[off]
        flags = body[off + 1]
        (keepalive,) = struct.unpack_from("!H", body, off + 2)
        off += 4
        out = {"proto": proto, "level": level, "flags": flags,
               "keepalive": keepalive}
        out["client_id"], off = take_str(body, off)
        if flags & 0x04:
            out["will_topic"], off = take_str(body, off)
            out["will_payload"], off = take_str(body, off)
        if flags & 0x80:
            out["username"], off = take_str(body, off)
        if flags & 0x40:
            out["password"], off = take_str(body, off)
        return out

    def drop(self):
        """Kill the client connection the way a dying broker does: shutdown()
        actually sends the FIN even while the serve thread blocks in recv on
        the same fd — a bare close() from another thread does not."""
        if self.conn is not None:
            try:
                self.conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.conn.close()

    def close(self):
        self.drop()
        if self._srv is not None:
            try:
                self._srv.close()
            except OSError:
                pass


def wait_for(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


# --------------------------------------------------------------------------
# wire protocol
# --------------------------------------------------------------------------

class TestRemainingLength(unittest.TestCase):
    def test_boundaries(self):
        self.assertEqual(MOD._remaining_len(0), b"\x00")
        self.assertEqual(MOD._remaining_len(127), b"\x7f")
        self.assertEqual(MOD._remaining_len(128), b"\x80\x01")
        self.assertEqual(MOD._remaining_len(16383), b"\xff\x7f")
        self.assertEqual(MOD._remaining_len(16384), b"\x80\x80\x01")

    def test_too_large(self):
        with self.assertRaises(MOD.MqttError):
            MOD._remaining_len(268435456)


class TestConnect(unittest.TestCase):
    def _client(self, broker):
        return MOD.MqttClient(
            "127.0.0.1", broker.port, client_id="nexusq_test",
            username="user", password="pass",
            will_topic="nexusq/status", will_payload="offline")

    def test_connect_packet_contents(self):
        broker = FakeBroker()
        try:
            cli = self._client(broker)
            cli.connect()
            self.assertTrue(wait_for(lambda: broker.connect is not None))
            c = broker.connect
            self.assertEqual(c["proto"], "MQTT")
            self.assertEqual(c["level"], 4)
            self.assertEqual(c["client_id"], "nexusq_test")
            self.assertEqual(c["will_topic"], "nexusq/status")
            self.assertEqual(c["will_payload"], "offline")
            self.assertEqual(c["username"], "user")
            self.assertEqual(c["password"], "pass")
            # clean session + will + will-retain, will QoS 0
            self.assertTrue(c["flags"] & 0x02)
            self.assertTrue(c["flags"] & 0x04)
            self.assertTrue(c["flags"] & 0x20)
            self.assertFalse(c["flags"] & 0x18)
            cli.disconnect()
        finally:
            broker.close()

    def test_auth_refused(self):
        broker = FakeBroker(connack_rc=5)
        try:
            cli = self._client(broker)
            with self.assertRaisesRegex(MOD.MqttError, "not authorized"):
                cli.connect()
        finally:
            broker.close()

    def test_publish_retain_and_payload(self):
        broker = FakeBroker()
        try:
            cli = self._client(broker)
            cli.connect()
            cli.publish("nexusq/health/state", '{"a":1}', retain=True)
            cli.publish("nexusq/x", "plain", retain=False)
            self.assertTrue(
                wait_for(lambda: len(broker.raw_publishes) >= 2))
            t0, p0, r0 = broker.raw_publishes[0]
            self.assertEqual((t0, p0, r0),
                             ("nexusq/health/state", b'{"a":1}', True))
            t1, p1, r1 = broker.raw_publishes[1]
            self.assertEqual((t1, p1, r1), ("nexusq/x", b"plain", False))
            cli.disconnect()
        finally:
            broker.close()

    def test_maintain_detects_broker_close(self):
        broker = FakeBroker()
        try:
            cli = self._client(broker)
            cli.connect()
            self.assertTrue(wait_for(lambda: broker.conn is not None))
            broker.drop()
            with self.assertRaises(MOD.MqttError):
                # the close may need a beat to surface through select
                for _ in range(50):
                    cli.maintain()
                    time.sleep(0.02)
        finally:
            broker.close()

    def test_large_payload_roundtrip(self):
        """>127-byte body exercises multi-byte remaining-length encoding."""
        broker = FakeBroker()
        try:
            cli = self._client(broker)
            cli.connect()
            payload = "x" * 5000
            cli.publish("nexusq/big", payload)
            self.assertTrue(wait_for(lambda: len(broker.raw_publishes) >= 1))
            self.assertEqual(broker.raw_publishes[0][1],
                             payload.encode())
            cli.disconnect()
        finally:
            broker.close()


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------

class TestConfig(unittest.TestCase):
    def _write(self, obj):
        f = tempfile.NamedTemporaryFile(
            "w", suffix=".json", delete=False)
        json.dump(obj, f)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_minimal_valid_with_defaults(self):
        conf = MOD.load_conf(self._write(
            {"host": "h", "username": "u", "password": "p"}))
        self.assertEqual(conf["port"], 1883)
        self.assertEqual(conf["interval_s"], 30)
        self.assertEqual(conf["prefix"], "nexusq")
        self.assertEqual(conf["discovery_prefix"], "homeassistant")

    def test_missing_required(self):
        for missing in ("host", "username", "password"):
            obj = {"host": "h", "username": "u", "password": "p"}
            del obj[missing]
            with self.assertRaisesRegex(MOD.ConfigError, missing):
                MOD.load_conf(self._write(obj))

    def test_interval_clamped(self):
        conf = MOD.load_conf(self._write(
            {"host": "h", "username": "u", "password": "p",
             "interval_s": 3}))
        self.assertEqual(conf["interval_s"], 10)
        conf = MOD.load_conf(self._write(
            {"host": "h", "username": "u", "password": "p",
             "interval_s": 100000}))
        self.assertEqual(conf["interval_s"], 600)

    def test_bad_json(self):
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        f.write("{nope")
        f.close()
        self.addCleanup(os.unlink, f.name)
        with self.assertRaises(MOD.ConfigError):
            MOD.load_conf(f.name)

    def test_missing_file(self):
        with self.assertRaises(MOD.ConfigError):
            MOD.load_conf("/nonexistent/mqtt.json")


# --------------------------------------------------------------------------
# collectors
# --------------------------------------------------------------------------

class TestHealthTail(unittest.TestCase):
    def test_last_line_wins_and_torn_line_skipped(self):
        f = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        f.write('{"temp_mC":70000}\n{"temp_mC":80000}\n{"torn')
        f.close()
        self.addCleanup(os.unlink, f.name)
        with mock.patch.object(MOD, "HEALTH_PATH", f.name):
            sample, age = MOD.read_health()
        self.assertEqual(sample.get("temp_mC"), 80000)
        self.assertIsNotNone(age)
        self.assertLess(age, 5)

    def test_missing_file(self):
        with mock.patch.object(MOD, "HEALTH_PATH", "/nonexistent.jsonl"):
            sample, age = MOD.read_health()
        self.assertEqual(sample, {})
        self.assertIsNone(age)


class TestOppResidency(unittest.TestCase):
    def test_window_delta(self):
        prev = {350000: 1000, 700000: 1000}
        cur = {350000: 1900, 700000: 1100}
        pct = MOD.opp_residency(prev, cur)
        self.assertEqual(pct[350000], 90.0)
        self.assertEqual(pct[700000], 10.0)

    def test_counter_reset_falls_back_to_absolute(self):
        prev = {350000: 5000}
        cur = {350000: 100, 700000: 300}   # went backwards -> reset
        pct = MOD.opp_residency(prev, cur)
        self.assertEqual(pct[350000], 25.0)
        self.assertEqual(pct[700000], 75.0)

    def test_empty(self):
        self.assertEqual(MOD.opp_residency({}, {}), {})


class TestWindowResidency(unittest.TestCase):
    """The rolling 1 h window: shares are measured against the OLDEST
    in-window snapshot, expired history is pruned, a kernel counter reset
    discards the whole history instead of poisoning an hour of readings."""

    def test_grows_from_daemon_start_then_slides(self):
        hist = []
        # t=0: since-boot fallback (no history yet)
        pct, hist = MOD.window_residency(hist, {350: 100, 700: 100}, 0.0,
                                         window_s=3600)
        self.assertEqual(pct[350], 50.0)
        # t=1800: measured against t=0 (window still growing)
        pct, hist = MOD.window_residency(hist, {350: 1000, 700: 100}, 1800.0,
                                         window_s=3600)
        self.assertEqual(pct[350], 100.0)   # all growth was at 350
        # t=5400: the t=0 snapshot expired; base is now t=1800
        pct, hist = MOD.window_residency(hist, {350: 1000, 700: 1000}, 5400.0,
                                         window_s=3600)
        self.assertEqual(pct[700], 100.0)   # within the window only 700 grew
        self.assertEqual([t for t, _ in hist], [1800.0, 5400.0])

    def test_counter_reset_discards_history(self):
        hist = []
        _, hist = MOD.window_residency(hist, {350: 5000}, 0.0, window_s=3600)
        # counters went backwards -> reboot -> fresh start, since-boot fallback
        pct, hist = MOD.window_residency(hist, {350: 30, 700: 10}, 30.0,
                                         window_s=3600)
        self.assertEqual(pct[350], 75.0)
        self.assertEqual(len(hist), 1)

    def test_empty_snapshot_keeps_history(self):
        hist = [(0.0, {350: 1})]
        pct, hist2 = MOD.window_residency(hist, {}, 30.0, window_s=3600)
        self.assertEqual(pct, {})
        self.assertEqual(hist2, hist)


class TestCollect(unittest.TestCase):
    def test_omits_unavailable_and_maps_units(self):
        health = tempfile.NamedTemporaryFile(
            "w", suffix=".jsonl", delete=False)
        health.write(json.dumps({
            "temp_mC": 76500, "freq": 350000, "gov": "conservative",
            "load1": "0.42", "mem_avail_kB": 204800, "nq_alive": 1,
            "led_stall": 0, "dmesg_err": 2, "pstore": 0}) + "\n")
        health.close()
        self.addCleanup(os.unlink, health.name)
        tis = tempfile.NamedTemporaryFile("w", delete=False)
        tis.write("350000 900\n700000 100\n")
        tis.close()
        self.addCleanup(os.unlink, tis.name)
        cgroup = tempfile.mkdtemp()
        os.makedirs(f"{cgroup}/roon.service")
        with open(f"{cgroup}/roon.service/cgroup.procs", "w") as f:
            f.write("1234\n")

        with mock.patch.object(MOD, "HEALTH_PATH", health.name), \
                mock.patch.object(MOD, "TIS_PATH", tis.name), \
                mock.patch.object(MOD, "USER_CGROUP", cgroup), \
                mock.patch.object(MOD, "read_wifi",
                                  return_value=(-48, "TestNet")), \
                mock.patch.object(MOD, "read_volume",
                                  return_value=(None, None)), \
                mock.patch.object(MOD, "read_uptime", return_value=1234):
            state, hist = MOD.collect([])

        self.assertEqual(state["temp_c"], 76.5)
        self.assertEqual(state["freq_mhz"], 350)
        self.assertEqual(state["governor"], "conservative")
        self.assertEqual(state["load1"], 0.42)
        self.assertEqual(state["mem_avail_mb"], 200)
        self.assertTrue(state["nexusqd_alive"])
        self.assertTrue(state["healthd_fresh"])
        self.assertEqual(state["opp350_pct"], 90.0)
        self.assertEqual(state["opp700_pct"], 10.0)
        self.assertEqual(state["wifi_rssi_dbm"], -48)
        self.assertEqual(state["wifi_ssid"], "TestNet")
        self.assertEqual(state["uptime_s"], 1234)
        # volume unavailable -> omitted, never null
        self.assertNotIn("volume_pct", state)
        self.assertNotIn("muted", state)
        # services: only roon has a live cgroup
        self.assertEqual(state["services"], {
            "spotify": False, "airplay": False,
            "roon": True, "usbaudio": False})
        self.assertEqual(hist[-1][1], {350000: 900, 700000: 100})

    def test_stale_healthd_drops_health_fields(self):
        health = tempfile.NamedTemporaryFile(
            "w", suffix=".jsonl", delete=False)
        health.write('{"temp_mC":76500,"freq":350000}\n')
        health.close()
        self.addCleanup(os.unlink, health.name)
        old = time.time() - 300
        os.utime(health.name, (old, old))
        with mock.patch.object(MOD, "HEALTH_PATH", health.name), \
                mock.patch.object(MOD, "TIS_PATH", "/nonexistent"), \
                mock.patch.object(MOD, "USER_CGROUP", "/nonexistent"), \
                mock.patch.object(MOD, "read_wifi",
                                  return_value=(None, None)), \
                mock.patch.object(MOD, "read_volume",
                                  return_value=(None, None)), \
                mock.patch.object(MOD, "read_uptime", return_value=None):
            state, _ = MOD.collect([])
        self.assertFalse(state["healthd_fresh"])
        self.assertNotIn("temp_c", state)
        self.assertNotIn("freq_mhz", state)


# --------------------------------------------------------------------------
# HA discovery contract
# --------------------------------------------------------------------------

class TestDiscovery(unittest.TestCase):
    def setUp(self):
        self.configs = MOD.discovery_configs(
            "nexusq_f88fca2048e1", "Obývák Q", "nexusq")

    def test_unique_ids_unique_and_topics_wellformed(self):
        uids = [cfg["unique_id"] for _, cfg in self.configs]
        self.assertEqual(len(uids), len(set(uids)))
        for topic, _ in self.configs:
            comp, node, key, tail = topic.split("/")
            self.assertIn(comp, ("sensor", "binary_sensor"))
            self.assertEqual(node, "nexusq_f88fca2048e1")
            self.assertEqual(tail, "config")

    def test_shared_topics_and_device_block(self):
        for _, cfg in self.configs:
            self.assertEqual(cfg["state_topic"], "nexusq/health/state")
            self.assertEqual(cfg["availability_topic"], "nexusq/status")
            self.assertEqual(cfg["device"]["identifiers"],
                             ["nexusq_f88fca2048e1"])
            self.assertEqual(cfg["device"]["name"], "Obývák Q")
            json.dumps(cfg)  # must be JSON-serializable

    def test_expected_entities_present(self):
        keys = {t.split("/")[2] for t, _ in self.configs}
        for expected in ("temp", "cpu_freq", "governor", "load1",
                         "mem_avail", "uptime", "wifi_rssi", "volume",
                         "opp350", "opp700", "opp920", "opp1200",
                         "spotify", "airplay", "roon", "usbaudio",
                         "nexusqd", "healthd"):
            self.assertIn(expected, keys)

    def test_opp_templates_reference_their_field(self):
        by_key = {t.split("/")[2]: cfg for t, cfg in self.configs}
        for mhz in (350, 700, 920, 1200):
            self.assertIn(f"value_json.opp{mhz}_pct",
                          by_key[f"opp{mhz}"]["value_template"])


class TestIdentity(unittest.TestCase):
    def test_mac_and_name(self):
        macf = tempfile.NamedTemporaryFile("w", delete=False)
        macf.write("f8:8f:ca:20:48:e1\n")
        macf.close()
        self.addCleanup(os.unlink, macf.name)
        identf = tempfile.NamedTemporaryFile("w", delete=False)
        json.dump({"name": "Obývák Q", "room": "obyvak"}, identf)
        identf.close()
        self.addCleanup(os.unlink, identf.name)
        with mock.patch.object(MOD, "MAC_PATH", macf.name), \
                mock.patch.object(MOD, "IDENTITY_PATH", identf.name):
            node, name = MOD.device_identity()
        self.assertEqual(node, "nexusq_f88fca2048e1")
        self.assertEqual(name, "Obývák Q")

    def test_fallbacks(self):
        with mock.patch.object(MOD, "MAC_PATH", "/nonexistent"), \
                mock.patch.object(MOD, "IDENTITY_PATH", "/nonexistent"):
            node, name = MOD.device_identity()
        self.assertEqual(node, "nexusq_000000000000")
        self.assertEqual(name, "Nexus Q")


class TestVolumeFromControl(unittest.TestCase):
    """Volume now comes from nexusq-control's persistent `pactl subscribe`
    instead of forking pactl/amixer every publish. The fallback must survive a
    bridge that is down, because publishing telemetry must never depend on the
    companion bridge being healthy."""

    def _serve(self, reply, *, close_early=False):
        """One-shot loopback server standing in for nexusq-control."""
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]

        def run():
            try:
                c, _ = srv.accept()
                c.recv(4096)
                if not close_early:
                    c.sendall(reply)
                c.close()
            except OSError:
                pass
            finally:
                srv.close()

        threading.Thread(target=run, daemon=True).start()
        return port

    def _with_port(self, port):
        MOD.CONTROL_HOST, MOD.CONTROL_PORT = "127.0.0.1", port

    def test_reads_volume_and_mute(self):
        port = self._serve(json.dumps(
            {"id": 1, "result": {"volume": 42, "muted": True}}).encode() + b"\n")
        self._with_port(port)
        self.assertEqual(MOD.volume_from_control(), (42, True))

    def test_accepts_a_bare_state_object(self):
        port = self._serve(json.dumps({"volume": 7, "muted": False}).encode() + b"\n")
        self._with_port(port)
        self.assertEqual(MOD.volume_from_control(), (7, False))

    def test_bridge_down_returns_none(self):
        # nothing listening: must fall through to the mixer probes, not raise
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.bind(("127.0.0.1", 0))
        port = srv.getsockname()[1]
        srv.close()
        self._with_port(port)
        self.assertIsNone(MOD.volume_from_control())

    def test_garbage_reply_returns_none(self):
        port = self._serve(b"not json at all\n")
        self._with_port(port)
        self.assertIsNone(MOD.volume_from_control())

    def test_missing_fields_return_none(self):
        port = self._serve(json.dumps({"result": {"volume": None}}).encode() + b"\n")
        self._with_port(port)
        self.assertIsNone(MOD.volume_from_control())

    def test_connection_closed_without_reply(self):
        port = self._serve(b"", close_early=True)
        self._with_port(port)
        self.assertIsNone(MOD.volume_from_control())


if __name__ == "__main__":
    unittest.main()
