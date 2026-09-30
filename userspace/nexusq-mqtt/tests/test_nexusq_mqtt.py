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
    spec = importlib.util.spec_from_loader("nexusq_mqtt", importlib.machinery.SourceFileLoader("nexusq_mqtt", DAEMON))
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
        self.packets = []  # (type_byte, body) in arrival order
        self.connect = None  # parsed CONNECT dict
        self.raw_publishes = []  # (topic, payload_bytes, retain_bool)
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
                    self.raw_publishes.append((body[2 : 2 + n].decode(), body[2 + n :], bool(first[0] & 0x01)))
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
            return buf[off + 2 : off + 2 + n].decode(), off + 2 + n

        proto, off = take_str(body, 0)
        level = body[off]
        flags = body[off + 1]
        (keepalive,) = struct.unpack_from("!H", body, off + 2)
        off += 4
        out = {"proto": proto, "level": level, "flags": flags, "keepalive": keepalive}
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
            "127.0.0.1",
            broker.port,
            client_id="nexusq_test",
            username="user",
            password="pass",
            will_topic="nexusq/status",
            will_payload="offline",
        )

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
            self.assertTrue(wait_for(lambda: len(broker.raw_publishes) >= 2))
            t0, p0, r0 = broker.raw_publishes[0]
            self.assertEqual((t0, p0, r0), ("nexusq/health/state", b'{"a":1}', True))
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
            self.assertEqual(broker.raw_publishes[0][1], payload.encode())
            cli.disconnect()
        finally:
            broker.close()


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------


class TestConfig(unittest.TestCase):
    def _write(self, obj):
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(obj, f)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_minimal_valid_with_defaults(self):
        conf = MOD.load_conf(self._write({"host": "h", "username": "u", "password": "p"}))
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
        conf = MOD.load_conf(self._write({"host": "h", "username": "u", "password": "p", "interval_s": 3}))
        self.assertEqual(conf["interval_s"], 10)
        conf = MOD.load_conf(self._write({"host": "h", "username": "u", "password": "p", "interval_s": 100000}))
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
        cur = {350000: 100, 700000: 300}  # went backwards -> reset
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
        pct, hist = MOD.window_residency(hist, {350: 100, 700: 100}, 0.0, window_s=3600)
        self.assertEqual(pct[350], 50.0)
        # t=1800: measured against t=0 (window still growing)
        pct, hist = MOD.window_residency(hist, {350: 1000, 700: 100}, 1800.0, window_s=3600)
        self.assertEqual(pct[350], 100.0)  # all growth was at 350
        # t=5400: the t=0 snapshot expired; base is now t=1800
        pct, hist = MOD.window_residency(hist, {350: 1000, 700: 1000}, 5400.0, window_s=3600)
        self.assertEqual(pct[700], 100.0)  # within the window only 700 grew
        self.assertEqual([t for t, _ in hist], [1800.0, 5400.0])

    def test_counter_reset_discards_history(self):
        hist = []
        _, hist = MOD.window_residency(hist, {350: 5000}, 0.0, window_s=3600)
        # counters went backwards -> reboot -> fresh start, since-boot fallback
        pct, hist = MOD.window_residency(hist, {350: 30, 700: 10}, 30.0, window_s=3600)
        self.assertEqual(pct[350], 75.0)
        self.assertEqual(len(hist), 1)

    def test_empty_snapshot_keeps_history(self):
        hist = [(0.0, {350: 1})]
        pct, hist2 = MOD.window_residency(hist, {}, 30.0, window_s=3600)
        self.assertEqual(pct, {})
        self.assertEqual(hist2, hist)


def cpuidle_tree(root, per_cpu):
    """A fake /sys/devices/system/cpu: per_cpu = [[(name, time_us, lat)...]]."""
    for c, states in enumerate(per_cpu):
        for i, (name, t, lat) in enumerate(states):
            d = os.path.join(root, f"cpu{c}", "cpuidle", f"state{i}")
            os.makedirs(d, exist_ok=True)
            for f, v in (("name", name), ("time", t), ("latency", lat)):
                with open(os.path.join(d, f), "w") as fh:
                    fh.write(f"{v}\n")
    os.makedirs(os.path.join(root, "cpufreq"), exist_ok=True)  # not a cpuN


STEELHEAD_LAT = {"C1": 4, "C2": 1100, "C3": 1200}


class TestCpuidle(unittest.TestCase):
    """C-state residency over the rolling hour, and the deep-idle veto."""

    def test_read_sums_cpus_and_keeps_latencies(self):
        root = tempfile.mkdtemp()
        cpuidle_tree(
            root,
            [[("C1", 10, 4), ("C2", 20, 1100), ("C3", 30, 1200)], [("C1", 1, 4), ("C2", 2, 1100), ("C3", 3, 1200)]],
        )
        with mock.patch.object(MOD, "CPUIDLE_ROOT", root):
            times, lat, ncpu = MOD.read_cpuidle()
        self.assertEqual(times, {"C1": 11, "C2": 22, "C3": 33})
        self.assertEqual(lat, STEELHEAD_LAT)
        self.assertEqual(ncpu, 2)

    def test_read_without_cpuidle(self):
        with mock.patch.object(MOD, "CPUIDLE_ROOT", "/nonexistent"):
            self.assertEqual(MOD.read_cpuidle(), ({}, {}, 0))
        root = tempfile.mkdtemp()
        os.makedirs(os.path.join(root, "cpu0"))  # a CPU without cpuidle
        with mock.patch.object(MOD, "CPUIDLE_ROOT", root):
            self.assertEqual(MOD.read_cpuidle(), ({}, {}, 0))

    def test_window_is_share_of_wall_time_per_cpu(self):
        # since boot: 2 CPUs x 100 s; 150 s of C3 summed = 75 % per CPU
        pct, hist = MOD.idle_window([], {"C1": 20e6, "C3": 150e6}, 2, 100.0, window_s=3600)
        self.assertEqual(pct, {"C1": 10.0, "C3": 75.0})
        # next 100 s: 190 s of C3 over 2 x 100 s -> 95 %, measured from t=100
        pct, hist = MOD.idle_window(hist, {"C1": 22e6, "C3": 340e6}, 2, 200.0, window_s=3600)
        self.assertEqual(pct, {"C1": 1.0, "C3": 95.0})
        self.assertEqual(len(hist), 2)

    def test_window_slides_and_clamps(self):
        hist = [(0.0, {"C3": 0}, 2)]
        pct, hist = MOD.idle_window(hist, {"C3": 7000e6}, 2, 4000.0, window_s=3600)
        # t=0 expired: no base left, so since boot (0 at monotonic 0) again
        self.assertEqual(pct["C3"], 87.5)
        # a counter ahead of the wall clock (sleep stretch booked late) clamps
        pct, _ = MOD.idle_window([], {"C3": 300e6}, 1, 100.0, window_s=3600)
        self.assertEqual(pct["C3"], 100.0)

    def test_window_restarts_on_reset_or_cpu_count(self):
        hist = [(10.0, {"C1": 5e6, "C3": 9e6}, 2)]
        _, h = MOD.idle_window(hist, {"C1": 1e6, "C3": 9e6}, 2, 20.0, window_s=3600)
        self.assertEqual(len(h), 1)  # counter went backwards
        _, h = MOD.idle_window(hist, {"C1": 6e6, "C3": 9e6}, 1, 20.0, window_s=3600)
        self.assertEqual(len(h), 1)  # a CPU went offline
        _, h = MOD.idle_window(hist, {"C1": 6e6, "C3": 9e6}, 2, 20.0, window_s=3600)
        self.assertEqual(len(h), 2)  # ordinary step
        pct, h = MOD.idle_window(hist, {}, 0, 20.0, window_s=3600)
        self.assertEqual((pct, h), ({}, hist))  # no cpuidle: history kept

    def test_blocked_rule(self):
        f = MOD.deep_idle_blocked
        self.assertFalse(f("C2,C3", MOD.QOS_NO_LIMIT, STEELHEAD_LAT))
        # playback's own request (1312 us) is above both exit latencies
        self.assertFalse(f("C2,C3", 1312, STEELHEAD_LAT))
        # the BT UART's 170 us vetoes both
        self.assertTrue(f("C2,C3", 170, STEELHEAD_LAT))
        # 1150 us vetoes C3 but C2 can still run
        self.assertFalse(f("C2,C3", 1150, STEELHEAD_LAT))
        self.assertTrue(f("C3", 1150, STEELHEAD_LAT))
        # nothing armed: deep idle impossible whatever the QoS
        self.assertTrue(f("", MOD.QOS_NO_LIMIT, STEELHEAD_LAT))
        # cannot say: older healthd, a kernel with only WFI, a failed QoS read
        self.assertIsNone(f(None, 170, STEELHEAD_LAT))
        self.assertIsNone(f("", 170, {"C1": 4}))
        self.assertIsNone(f("C2,C3", -1, STEELHEAD_LAT))
        self.assertIsNone(f("C2,C3", True, STEELHEAD_LAT))

    def test_veto_needs_persistence_and_span(self):
        with mock.patch.object(MOD, "VETO_MIN_SPAN_S", 600):
            hist = []
            share, judged, hist = MOD.veto_window(hist, True, 0.0, 3600)
            # one blocked sample is 100 % of nothing: no judgement yet
            self.assertEqual((share, judged), (100.0, None))
            for i in range(1, 20):
                share, judged, hist = MOD.veto_window(hist, True, 30.0 * i, 3600)
            self.assertIsNone(judged)  # 570 s: still too short
            share, judged, hist = MOD.veto_window(hist, True, 600.0, 3600)
            self.assertTrue(judged)  # 21/21 blocked over 600 s
            share, judged, hist = MOD.veto_window(hist, False, 630.0, 3600)
            share, judged, hist = MOD.veto_window(hist, False, 660.0, 3600)
            share, judged, hist = MOD.veto_window(hist, False, 690.0, 3600)
            self.assertEqual(share, round(100 * 21 / 24, 1))
            self.assertFalse(judged)  # 87.5 % < 90 %: transient
            # a sample that cannot say is not recorded
            n = len(hist)
            _, _, hist = MOD.veto_window(hist, None, 720.0, 3600)
            self.assertEqual(len(hist), n)

    def test_collect_publishes_idle_and_veto(self):
        root = tempfile.mkdtemp()
        cpuidle_tree(
            root, [[("C1", 1, 4), ("C2", 2, 1100), ("C3", 3, 1200)], [("C1", 1, 4), ("C2", 2, 1100), ("C3", 3, 1200)]]
        )
        health = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        health.write(json.dumps({"cstate_armed": "C2,C3", "qos_us": 170}) + "\n")
        health.close()
        self.addCleanup(os.unlink, health.name)
        with (
            mock.patch.object(MOD, "HEALTH_PATH", health.name),
            mock.patch.object(MOD, "CPUIDLE_ROOT", root),
            mock.patch.object(MOD, "TIS_PATH", "/nonexistent"),
            mock.patch.object(MOD, "USER_CGROUP", "/nonexistent"),
            mock.patch.object(MOD, "read_wifi", return_value=(None, None)),
            mock.patch.object(MOD, "read_volume", return_value=(None, None)),
            mock.patch.object(MOD, "read_uptime", return_value=1),
        ):
            win = MOD.Windows()
            state = MOD.collect(win)
        for k in ("idle_c1_pct", "idle_c2_pct", "idle_c3_pct"):
            self.assertIn(k, state)
        self.assertEqual(state["cstate_armed"], "C2,C3")
        self.assertEqual(state["cpu_latency_limit_us"], 170)
        self.assertEqual(state["deep_idle_blocked_pct"], 100.0)
        self.assertNotIn("deep_idle_blocked", state)  # window too short
        self.assertEqual(len(win.idle), 1)
        self.assertEqual(len(win.veto), 1)

    def test_unconstrained_qos_is_not_published(self):
        health = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        health.write(json.dumps({"cstate_armed": "C2,C3", "qos_us": MOD.QOS_NO_LIMIT}) + "\n")
        health.close()
        self.addCleanup(os.unlink, health.name)
        with (
            mock.patch.object(MOD, "HEALTH_PATH", health.name),
            mock.patch.object(MOD, "CPUIDLE_ROOT", "/nonexistent"),
            mock.patch.object(MOD, "TIS_PATH", "/nonexistent"),
            mock.patch.object(MOD, "USER_CGROUP", "/nonexistent"),
            mock.patch.object(MOD, "read_wifi", return_value=(None, None)),
            mock.patch.object(MOD, "read_volume", return_value=(None, None)),
            mock.patch.object(MOD, "read_uptime", return_value=1),
        ):
            state = MOD.collect(MOD.Windows())
        self.assertNotIn("cpu_latency_limit_us", state)
        # no cpuidle -> no latency table -> the veto cannot be judged
        self.assertNotIn("deep_idle_blocked_pct", state)


class TestDiagnosticsMode(unittest.TestCase):
    NOW = 1_790_000_000.0

    def _read(self, doc):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "diagnostics.json")
        if doc is not None:
            with open(path, "w") as f:
                f.write(doc)
        with mock.patch.object(MOD, "DIAG_PATH", path):
            return MOD.read_diagnostics(self.NOW)

    def test_states(self):
        self.assertEqual(self._read(None), {"diagnostics": False})
        self.assertEqual(self._read('{"until": null, "endedAt": 5}'), {"diagnostics": False})
        self.assertEqual(self._read(json.dumps({"until": self.NOW - 1})), {"diagnostics": False})
        self.assertEqual(
            self._read(json.dumps({"until": self.NOW + 3600})),
            {"diagnostics": True, "diagnostics_until": "2026-09-21T15:13:20Z"},
        )
        for doc in ("", "{", "[]", '{"until": true}', '{"until": "x"}'):
            with self.subTest(doc=doc):
                self.assertEqual(self._read(doc), {"diagnostics": False})


class TestCollect(unittest.TestCase):
    def test_omits_unavailable_and_maps_units(self):
        health = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        health.write(
            json.dumps(
                {
                    "temp_mC": 76500,
                    "freq": 350000,
                    "gov": "conservative",
                    "load1": "0.42",
                    "mem_avail_kB": 204800,
                    "nq_alive": 1,
                    "led_stall": 0,
                    "dmesg_err": 2,
                    "pstore": 0,
                }
            )
            + "\n"
        )
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

        with (
            mock.patch.object(MOD, "HEALTH_PATH", health.name),
            mock.patch.object(MOD, "TIS_PATH", tis.name),
            mock.patch.object(MOD, "USER_CGROUP", cgroup),
            mock.patch.object(MOD, "read_wifi", return_value=(-48, "TestNet")),
            mock.patch.object(MOD, "read_volume", return_value=(None, None)),
            mock.patch.object(MOD, "read_uptime", return_value=1234),
        ):
            win = MOD.Windows()
            state = MOD.collect(win)

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
        self.assertEqual(state["services"], {"spotify": False, "airplay": False, "roon": True, "usbaudio": False})
        self.assertEqual(win.tis[-1][1], {350000: 900, 700000: 100})

    def test_stale_healthd_drops_health_fields(self):
        health = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        health.write('{"temp_mC":76500,"freq":350000}\n')
        health.close()
        self.addCleanup(os.unlink, health.name)
        old = time.time() - 300
        os.utime(health.name, (old, old))
        with (
            mock.patch.object(MOD, "HEALTH_PATH", health.name),
            mock.patch.object(MOD, "TIS_PATH", "/nonexistent"),
            mock.patch.object(MOD, "USER_CGROUP", "/nonexistent"),
            mock.patch.object(MOD, "read_wifi", return_value=(None, None)),
            mock.patch.object(MOD, "read_volume", return_value=(None, None)),
            mock.patch.object(MOD, "read_uptime", return_value=None),
        ):
            state = MOD.collect(MOD.Windows())
        self.assertFalse(state["healthd_fresh"])
        self.assertNotIn("temp_c", state)
        self.assertNotIn("freq_mhz", state)


class TestWifiRepairs(unittest.TestCase):
    """The watchdog's repair count, as published to Home Assistant. Since
    firmware r3 a repair is a failure worth seeing, not routine
    (docs/2026-09-23-wifi-unicast-wedge-firmware.md)."""

    NOW = 1_790_200_000.0  # a set wall clock

    def wd(self, doc):
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        f.write(doc if isinstance(doc, str) else json.dumps(doc))
        f.close()
        self.addCleanup(os.unlink, f.name)
        return mock.patch.object(MOD, "WIFI_WD_PATH", f.name)

    def test_no_watchdog_publishes_nothing(self):
        with mock.patch.object(MOD, "WIFI_WD_PATH", "/nonexistent.json"):
            self.assertEqual(MOD.read_wifi_repairs(1000, self.NOW), {})

    def test_start_marker_is_zero_and_healthy(self):
        with self.wd({"repairs": 0}):
            self.assertEqual(
                MOD.read_wifi_repairs(1000, self.NOW), {"wifi_repairs": 0, "wifi_repaired_recently": False}
            )

    def test_recent_repair_raises_the_flag_with_its_time(self):
        with self.wd({"repairs": 2, "last_kind": "heal", "last_ok": True, "last_uptime": 1000}):
            out = MOD.read_wifi_repairs(1600, self.NOW)
        self.assertEqual(out["wifi_repairs"], 2)
        self.assertTrue(out["wifi_repaired_recently"])
        self.assertEqual(out["wifi_last_repair_kind"], "heal")
        self.assertIs(out["wifi_last_repair_ok"], True)
        # 600 s before now, in UTC, in the form a HA timestamp sensor parses
        self.assertEqual(out["wifi_last_repair"], time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(self.NOW - 600)))

    def test_a_day_old_repair_is_counted_but_no_longer_a_problem(self):
        with self.wd({"repairs": 1, "last_kind": "reconnect", "last_ok": False, "last_uptime": 100}):
            out = MOD.read_wifi_repairs(100 + 24 * 3600, self.NOW)
        self.assertEqual(out["wifi_repairs"], 1)
        self.assertFalse(out["wifi_repaired_recently"])
        self.assertIs(out["wifi_last_repair_ok"], False)

    def test_unset_clock_keeps_the_verdict_but_invents_no_time(self):
        # The RTC does not tick: right after boot time.time() can be 1970.
        # Recency comes from the two uptimes, so it is still right; a wall
        # clock time derived from an unset clock would be a lie.
        with self.wd({"repairs": 1, "last_kind": "heal", "last_ok": True, "last_uptime": 50}):
            out = MOD.read_wifi_repairs(80, 1000.0)
        self.assertTrue(out["wifi_repaired_recently"])
        self.assertNotIn("wifi_last_repair", out)

    def test_repair_from_the_future_is_ignored(self):
        # last_uptime > uptime cannot come from this boot (/run is tmpfs);
        # report the count but make no recency claim from it.
        with self.wd({"repairs": 1, "last_kind": "heal", "last_ok": True, "last_uptime": 5000}):
            out = MOD.read_wifi_repairs(100, self.NOW)
        self.assertEqual(out, {"wifi_repairs": 1, "wifi_repaired_recently": False})

    def test_unknown_uptime_reports_the_count_only(self):
        with self.wd({"repairs": 3, "last_kind": "heal", "last_ok": True, "last_uptime": 50}):
            out = MOD.read_wifi_repairs(None, self.NOW)
        self.assertEqual(out, {"wifi_repairs": 3, "wifi_repaired_recently": False})

    def test_garbage_is_ignored(self):
        for doc in ("", "{", "[]", '{"repairs":"3"}', '{"last_ok":true}'):
            with self.subTest(doc=doc), self.wd(doc):
                self.assertEqual(MOD.read_wifi_repairs(100, self.NOW), {})

    def test_collect_carries_the_fields(self):
        with (
            self.wd({"repairs": 1, "last_kind": "heal", "last_ok": True, "last_uptime": 1200}),
            mock.patch.object(MOD, "HEALTH_PATH", "/nonexistent"),
            mock.patch.object(MOD, "TIS_PATH", "/nonexistent"),
            mock.patch.object(MOD, "USER_CGROUP", "/nonexistent"),
            mock.patch.object(MOD, "read_wifi", return_value=(None, None)),
            mock.patch.object(MOD, "read_volume", return_value=(None, None)),
            mock.patch.object(MOD, "read_uptime", return_value=1234),
        ):
            state = MOD.collect(MOD.Windows())
        self.assertEqual(state["wifi_repairs"], 1)
        self.assertTrue(state["wifi_repaired_recently"])


# --------------------------------------------------------------------------
# HA discovery contract
# --------------------------------------------------------------------------


class TestDiscovery(unittest.TestCase):
    def setUp(self):
        self.configs = MOD.discovery_configs("nexusq_f88fca2048e1", "Obývák Q", "nexusq")

    def test_unique_ids_unique_and_topics_wellformed(self):
        uids = [cfg["unique_id"] for _, cfg in self.configs]
        self.assertEqual(len(uids), len(set(uids)))
        for topic, _ in self.configs:
            comp, node, key, tail = topic.split("/")
            self.assertIn(comp, ("sensor", "binary_sensor"))
            self.assertEqual(node, "nexusq_f88fca2048e1")
            self.assertEqual(tail, "config")

    def test_topics_are_per_device_and_device_block(self):
        # Until 2026-09-06 every entity of every device pointed at the flat
        # `<prefix>/health/state`, which names no device: Home Assistant showed
        # the cottage unit's numbers under Prague's `sensor.nexus_q_*` for ~7 h
        # even though each box was publishing to its own prefix on the broker.
        # The node_id (the factory WiFi MAC) is what separates them.
        for _, cfg in self.configs:
            self.assertEqual(cfg["state_topic"], "nexusq/nexusq_f88fca2048e1/health/state")
            self.assertEqual(cfg["availability_topic"], "nexusq/nexusq_f88fca2048e1/status")
            self.assertEqual(cfg["device"]["identifiers"], ["nexusq_f88fca2048e1"])
            self.assertEqual(cfg["device"]["name"], "Obývák Q")
            json.dumps(cfg)  # must be JSON-serializable

    def test_two_devices_never_share_a_state_topic(self):
        other = MOD.discovery_configs("nexusq_f88fca204ab1", "Šumperák Q", "nexusq")
        mine = {cfg["state_topic"] for _, cfg in self.configs}
        theirs = {cfg["state_topic"] for _, cfg in other}
        self.assertTrue(mine.isdisjoint(theirs))
        avail_mine = {cfg["availability_topic"] for _, cfg in self.configs}
        avail_theirs = {cfg["availability_topic"] for _, cfg in other}
        self.assertTrue(avail_mine.isdisjoint(avail_theirs))
        # and the discovery config topics themselves stay distinct
        self.assertTrue({t for t, _ in self.configs}.isdisjoint({t for t, _ in other}))

    def test_expected_entities_present(self):
        keys = {t.split("/")[2] for t, _ in self.configs}
        # "volume" is no longer a telemetry sensor: since r10 it is VolumeLink's
        # writable number (tests/test_volume_ha.py)
        self.assertNotIn("volume", {t.split("/")[2] for t, _ in self.configs})
        for expected in (
            "temp",
            "cpu_freq",
            "governor",
            "load1",
            "mem_avail",
            "uptime",
            "wifi_rssi",
            "opp350",
            "opp700",
            "opp920",
            "opp1200",
            "spotify",
            "airplay",
            "roon",
            "usbaudio",
            "nexusqd",
            "healthd",
            "wifi_repairs",
            "wifi_last_repair",
            "wifi_link",
            "idle_c1",
            "idle_c2",
            "idle_c3",
            "cpu_latency_limit",
            "deep_idle_blocked_share",
            "deep_idle",
            "diagnostics",
        ):
            self.assertIn(expected, keys)

    def test_wifi_repair_entities(self):
        by_key = {t.split("/")[2]: (t, cfg) for t, cfg in self.configs}
        topic, cfg = by_key["wifi_repairs"]
        self.assertTrue(topic.startswith("sensor/"))
        # a reboot resets the count to 0: total_increasing reads that as a
        # reset, not as repairs going away
        self.assertEqual(cfg["state_class"], "total_increasing")
        self.assertIn("value_json.wifi_repairs", cfg["value_template"])
        topic, cfg = by_key["wifi_last_repair"]
        self.assertEqual(cfg["device_class"], "timestamp")
        # 'None' (not 'unknown') is what HA's MQTT sensor treats as no value
        self.assertIn("default('None')", cfg["value_template"])
        topic, cfg = by_key["wifi_link"]
        self.assertTrue(topic.startswith("binary_sensor/"))
        self.assertEqual(cfg["device_class"], "problem")
        # healthy unless the device says it repaired the link recently; an
        # absent field (no watchdog, older device) must read healthy
        self.assertIn("wifi_repaired_recently | default(false)", cfg["value_template"])
        self.assertIn("'OFF' if (not (", cfg["value_template"])

    def test_deep_idle_entities(self):
        by_key = {t.split("/")[2]: (t, cfg) for t, cfg in self.configs}
        for key in ("c1", "c2", "c3"):
            self.assertIn(f"value_json.idle_{key}_pct", by_key[f"idle_{key}"][1]["value_template"])
        topic, cfg = by_key["deep_idle"]
        self.assertTrue(topic.startswith("binary_sensor/"))
        self.assertEqual(cfg["device_class"], "problem")
        # absent judgement (short window, older device) must read healthy
        self.assertIn("deep_idle_blocked | default(false)", cfg["value_template"])

    def test_opp_templates_reference_their_field(self):
        by_key = {t.split("/")[2]: cfg for t, cfg in self.configs}
        for mhz in (350, 700, 920, 1200):
            self.assertIn(f"value_json.opp{mhz}_pct", by_key[f"opp{mhz}"]["value_template"])


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
        with mock.patch.object(MOD, "MAC_PATH", macf.name), mock.patch.object(MOD, "IDENTITY_PATH", identf.name):
            node, name = MOD.device_identity()
        self.assertEqual(node, "nexusq_f88fca2048e1")
        self.assertEqual(name, "Obývák Q")

    def test_fallbacks(self):
        with (
            mock.patch.object(MOD, "MAC_PATH", "/nonexistent"),
            mock.patch.object(MOD, "IDENTITY_PATH", "/nonexistent"),
        ):
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
        port = self._serve(json.dumps({"id": 1, "result": {"volume": 42, "muted": True}}).encode() + b"\n")
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


class TestLinkReport(unittest.TestCase):
    """The reconnect loop's log lines: quiet while the network arrives at boot,
    one line per outage after that, every loss of an established link."""

    def test_boot_before_the_network_is_quiet(self):
        link = MOD.LinkReport(started=100.0)
        dns = OSError(-3, "Try again")
        self.assertIsNone(link.failed(106.0, dns))  # the 2026-09-30 boot: DNS not up yet
        self.assertIsNone(link.failed(116.0, dns))
        self.assertEqual(link.connected(121.0), "connected (attempt 3, 21 s after start)")

    def test_first_connect_says_plain_connected(self):
        self.assertEqual(MOD.LinkReport(started=0.0).connected(1.0), "connected")

    def test_a_broker_down_at_boot_is_reported_after_the_grace(self):
        link = MOD.LinkReport(started=0.0, grace_s=60)
        refused = ConnectionRefusedError(111, "Connection refused")
        self.assertIsNone(link.failed(30.0, refused))
        self.assertEqual(link.failed(70.0, refused), "broker not reachable: [Errno 111] Connection refused")
        self.assertIsNone(link.failed(130.0, refused))  # said once, not every retry

    def test_an_established_link_that_breaks_is_always_reported(self):
        link = MOD.LinkReport(started=0.0)
        link.connected(1.0)
        self.assertEqual(link.failed(500.0, MOD.MqttError("PINGRESP timeout")), "connection lost: PINGRESP timeout")
        self.assertEqual(link.connected(505.0), "connected")  # back at the first retry: nothing to add
        self.assertEqual(
            link.failed(900.0, MOD.MqttError("broker closed connection")), "connection lost: broker closed connection"
        )

    def test_an_outage_is_one_line_until_the_error_changes_and_its_end_says_how_long(self):
        link = MOD.LinkReport(started=0.0)
        link.connected(1.0)
        link.failed(1000.0, MOD.MqttError("broker closed connection"))
        refused = ConnectionRefusedError(111, "Connection refused")
        self.assertEqual(link.failed(1005.0, refused), "broker not reachable: [Errno 111] Connection refused")
        self.assertIsNone(link.failed(1015.0, refused))
        self.assertIsNone(link.failed(1035.0, refused))
        timeout = TimeoutError("timed out")
        self.assertEqual(link.failed(1075.0, timeout), "broker not reachable: timed out")
        self.assertEqual(link.connected(1135.0), "connected (broker was not reachable for 130 s, 4 attempts)")
        # and the next outage is reported afresh
        link.failed(2000.0, MOD.MqttError("socket lost"))
        self.assertEqual(link.failed(2005.0, refused), "broker not reachable: [Errno 111] Connection refused")


if __name__ == "__main__":
    unittest.main()
