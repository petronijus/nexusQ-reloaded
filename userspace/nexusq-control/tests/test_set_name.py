"""setName over the LAN link (PROTOCOL §15).

The rename used to be reachable only through nexusq-setupd, i.e. only over a
bonded Bluetooth RFCOMM link. These tests pin the LAN equivalent: same hostname
rule, same identity file, same reply shape -- and the two things this path does
DIFFERENTLY from setupd's, both of which are easy to regress:

  * it re-advertises mDNS in-process instead of restarting nexusq-control
    (restarting would cut the connection the reply travels over), and
  * a failure to change the hostname must leave NO identity file behind.
"""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import tempfile
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


class _Ok:
    returncode = 0
    stdout = ""
    stderr = ""


class _Fail:
    returncode = 1
    stdout = ""
    stderr = "boom"


class TestSanitizeHostname(unittest.TestCase):
    """Must stay byte-identical to nexusq-setupd's rule -- a rename has to land
    on the same hostname whether it arrived over Bluetooth or over the LAN."""

    def test_cases(self):
        mod = load_daemon()
        for name, want in [
            ("Nexus Q", "nexus-q"),
            ("Obývák Q", "obyvak-q"),
            ("  Šumperák  ", "sumperak"),
            ("a__b", "a-b"),
            ("!!!", "nexusq"),
            ("", "nexusq"),
            ("x" * 80, "x" * 63),
        ]:
            self.assertEqual(mod.sanitize_hostname(name), want, name)


class TestSetName(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.mod.IDENTITY_PATH = os.path.join(self.tmp.name, "device.json")

    def _run_ok(self, *a, **k):
        self.calls.append(a[0])
        return _Ok()

    def test_rejects_bad_name(self):
        for bad in ({}, {"name": ""}, {"name": "   "}, {"name": 7}, {"name": None}):
            with self.assertRaises(self.mod.Err) as cm:
                self.mod.set_name(bad)
            self.assertEqual(cm.exception.code, "bad_request")

    def test_rejects_non_string_room(self):
        with self.assertRaises(self.mod.Err) as cm:
            self.mod.set_name({"name": "Q", "room": 5})
        self.assertEqual(cm.exception.code, "bad_request")

    def test_writes_identity_sets_hostname_and_readvertises(self):
        self.calls = []
        with patch.object(self.mod.subprocess, "run", side_effect=self._run_ok), \
             patch.object(self.mod, "_systemctl_user") as sysu, \
             patch.object(self.mod, "publish_mdns") as pub:
            out = self.mod.set_name({"name": "  Šumperák  ", "room": "cottage"})

        self.assertEqual(out, {"name": "Šumperák", "room": "cottage",
                               "hostname": "sumperak", "mdns": "sumperak.local"})
        self.assertIn(["hostnamectl", "set-hostname", "sumperak"], self.calls)
        with open(self.mod.IDENTITY_PATH) as f:
            self.assertEqual(json.load(f), {"name": "Šumperák", "room": "cottage"})
        # the globals the mDNS record and getDeviceInfo are built from
        self.assertEqual(self.mod.DEVICE_NAME, "Šumperák")
        self.assertEqual(self.mod.DEVICE_ROOM, "cottage")
        pub.assert_called_once()          # re-advertised...
        sysu.assert_called_once()         # ...and Spotify's name refreshed
        self.assertEqual(sysu.call_args[0][:2], ("restart", "librespot.service"))

    def test_does_not_restart_itself(self):
        """setupd ends with `systemctl restart nexusq-control`. Here that would
        kill the connection the reply is still travelling over."""
        self.calls = []
        with patch.object(self.mod.subprocess, "run", side_effect=self._run_ok), \
             patch.object(self.mod, "_systemctl_user"), \
             patch.object(self.mod, "publish_mdns"):
            self.mod.set_name({"name": "Q"})
        flat = [" ".join(c) for c in self.calls]
        self.assertFalse([c for c in flat if "nexusq-control" in c], flat)

    def test_hostname_failure_leaves_no_identity(self):
        with patch.object(self.mod.subprocess, "run", return_value=_Fail()), \
             patch.object(self.mod, "_systemctl_user"), \
             patch.object(self.mod, "publish_mdns") as pub:
            with self.assertRaises(self.mod.Err) as cm:
                self.mod.set_name({"name": "Q"})
        self.assertEqual(cm.exception.code, "internal")
        self.assertFalse(os.path.exists(self.mod.IDENTITY_PATH))
        pub.assert_not_called()

    def test_librespot_failure_does_not_fail_the_rename(self):
        """Spotify being switched off must not turn a successful rename into an
        error -- the name is already on disk by then."""
        self.calls = []
        with patch.object(self.mod.subprocess, "run", side_effect=self._run_ok), \
             patch.object(self.mod, "_systemctl_user",
                          side_effect=subprocess.TimeoutExpired("systemctl", 30)), \
             patch.object(self.mod, "publish_mdns"):
            out = self.mod.set_name({"name": "Q"})
        self.assertEqual(out["name"], "Q")
        self.assertTrue(os.path.exists(self.mod.IDENTITY_PATH))

    def test_room_defaults_to_current_not_blank(self):
        """A rename that omits `room` must not silently clear it."""
        self.calls = []
        self.mod.DEVICE_ROOM = "kitchen"
        with patch.object(self.mod.subprocess, "run", side_effect=self._run_ok), \
             patch.object(self.mod, "_systemctl_user"), \
             patch.object(self.mod, "publish_mdns"):
            out = self.mod.set_name({"name": "Q"})
        self.assertEqual(out["room"], "kitchen")


if __name__ == "__main__":
    unittest.main()
