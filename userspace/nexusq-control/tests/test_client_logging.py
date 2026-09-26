"""Connect/disconnect logging: the app's connections are logged, the Q's own
loopback daemons are not.

nexusq-mqtt opens a connection for getState on every 30 s publish, and each one
used to write two journal lines — ~5 800 a day of nothing, measured on the
cottage Q on 2026-09-26. An app connecting from the LAN is exactly what one wants
to see, so that must keep logging.
"""
import importlib.machinery
import importlib.util
import os
import socket
import unittest
from unittest.mock import patch

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeBridge:
    def add_client(self, sock):
        return 1

    def remove_client(self, cid):
        pass


class TestClientLogging(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()

    def _run(self, addr):
        """Run client_thread against a peer that hangs up at once; return the
        log lines it wrote."""
        ours, peer = socket.socketpair()
        peer.close()
        lines = []
        with patch.object(self.mod, "log", lambda *a: lines.append(" ".join(map(str, a)))):
            self.mod.client_thread(FakeBridge(), ours, addr)
        return lines

    def test_loopback_daemon_is_not_logged(self):
        self.assertEqual(self._run(("127.0.0.1", 41136)), [])

    def test_whole_loopback_net_is_quiet(self):
        self.assertEqual(self._run(("127.0.1.1", 5000)), [])

    def test_app_on_the_lan_is_logged(self):
        lines = self._run(("192.168.48.20", 51234))
        self.assertEqual(len(lines), 2)
        self.assertIn("client connected", lines[0])
        self.assertIn("client disconnected", lines[1])

    def test_odd_addr_shapes_default_to_logging(self):
        # Never silence something we cannot identify.
        self.assertTrue(self.mod._logs_connection(None))
        self.assertTrue(self.mod._logs_connection(()))


if __name__ == "__main__":
    unittest.main()
