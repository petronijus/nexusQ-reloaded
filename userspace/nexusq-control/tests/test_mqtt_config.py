"""Tests for the MQTT provisioning verbs (PROTOCOL §13).

The app is the ONLY provisioner of /etc/nexusq/mqtt.json — these pin the
contract: atomic 0600 write, verbatim password, validation, and that
getMqttStatus can NEVER leak the password.
"""

import importlib.machinery
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from unittest.mock import patch

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control",
        importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()


def _no_restart():
    """Patch out systemctl (no systemd on the test host) with a REAL
    CompletedProcess — a bare MagicMock leaks into get_mqtt_status()'s
    `active` field and breaks its JSON contract."""
    import subprocess
    return patch.object(
        MOD.subprocess, "run",
        return_value=subprocess.CompletedProcess([], 0, stdout="inactive",
                                                 stderr=""))


class TestSetMqttConfig(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "nexusq", "mqtt.json")

    def _set(self, p):
        with _no_restart():
            return MOD.set_mqtt_config(p, path=self.path)

    def test_writes_0600_and_verbatim_password(self):
        st = self._set({"host": " mqtt.home.arpa ", "username": " petronijus ",
                        "password": "s3cret with spaces  "})
        mode = stat.S_IMODE(os.stat(self.path).st_mode)
        self.assertEqual(mode, 0o600)
        conf = json.load(open(self.path))
        # host/username trimmed, password VERBATIM
        self.assertEqual(conf["host"], "mqtt.home.arpa")
        self.assertEqual(conf["username"], "petronijus")
        self.assertEqual(conf["password"], "s3cret with spaces  ")
        self.assertEqual(conf["port"], 1883)
        # returned status: provisioned, and NO password anywhere in it
        self.assertTrue(st["configured"])
        self.assertNotIn("s3cret", json.dumps(st))

    def test_optional_fields(self):
        self._set({"host": "h", "username": "u", "password": "p",
                   "port": 1884, "prefix": "qq", "interval_s": 60})
        conf = json.load(open(self.path))
        self.assertEqual(conf["port"], 1884)
        self.assertEqual(conf["prefix"], "qq")
        self.assertEqual(conf["interval_s"], 60)

    def test_out_of_range_interval_dropped(self):
        self._set({"host": "h", "username": "u", "password": "p",
                   "interval_s": 5})
        self.assertNotIn("interval_s", json.load(open(self.path)))

    def test_validation(self):
        for bad in ({"username": "u", "password": "p"},
                    {"host": "h", "password": "p"},
                    {"host": "h", "username": "u"},
                    {"host": " ", "username": "u", "password": "p"},
                    {"host": "h", "username": "u", "password": ""},
                    {"host": "h", "username": "u", "password": "p",
                     "port": 0},
                    {"host": "h", "username": "u", "password": "p",
                     "port": "1883"}):
            with self.assertRaises(MOD.Err):
                self._set(bad)
        self.assertFalse(os.path.exists(self.path))

    def test_overwrite_is_atomic_replacement(self):
        self._set({"host": "a", "username": "u", "password": "p1"})
        self._set({"host": "b", "username": "u", "password": "p2"})
        conf = json.load(open(self.path))
        self.assertEqual((conf["host"], conf["password"]), ("b", "p2"))
        self.assertEqual(os.listdir(os.path.dirname(self.path)),
                         ["mqtt.json"])  # no leftover tempfiles


class TestSetMqttConfigThroughTheStore(unittest.TestCase):
    """Since 2026-09-26 /etc/nexusq/mqtt.json is a symlink into the per-unit
    persist store (nq-persist, site/mqtt.json), so the site's broker survives a
    flash. A tmp-then-os.replace(link) would swap the LINK for a regular file:
    the app's change would work until the next flash, then silently vanish."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.store = os.path.join(self.dir.name, "persist", "site")
        os.makedirs(self.store)
        self.target = os.path.join(self.store, "mqtt.json")
        etc = os.path.join(self.dir.name, "etc", "nexusq")
        os.makedirs(etc)
        self.link = os.path.join(etc, "mqtt.json")
        os.symlink(self.target, self.link)

    def _set(self, p):
        with _no_restart():
            return MOD.set_mqtt_config(p, path=self.link)

    def test_writes_through_the_link_into_the_store(self):
        with open(self.target, "w") as f:
            json.dump({"host": "old", "username": "u", "password": "p0"}, f)
        self._set({"host": "new", "username": "u", "password": "p1"})
        self.assertTrue(os.path.islink(self.link), "the link was replaced by a file")
        self.assertEqual(os.readlink(self.link), self.target)
        self.assertEqual(json.load(open(self.target))["host"], "new")
        self.assertEqual(stat.S_IMODE(os.stat(self.target).st_mode), 0o600)
        self.assertEqual(sorted(os.listdir(self.store)), ["mqtt.json"])  # no tempfiles

    def test_first_provision_creates_the_store_file(self):
        # A dangling link: the store has no config yet (a fresh store).
        self._set({"host": "h", "username": "u", "password": "p"})
        self.assertTrue(os.path.islink(self.link))
        self.assertEqual(json.load(open(self.target))["host"], "h")

    def test_status_reads_through_the_link(self):
        self._set({"host": "h", "username": "u", "password": "p", "prefix": "q"})
        st = MOD.get_mqtt_status(self.link)
        self.assertTrue(st["configured"])
        self.assertEqual(st["prefix"], "q")


class TestGetMqttStatus(unittest.TestCase):
    def test_unconfigured(self):
        with _no_restart():
            st = MOD.get_mqtt_status(path="/nonexistent/mqtt.json")
        self.assertFalse(st["configured"])

    def test_configured_never_leaks_password(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "mqtt.json")
            with open(p, "w") as f:
                json.dump({"host": "h", "port": 1883, "username": "u",
                           "password": "TOPSECRET"}, f)
            with _no_restart():
                st = MOD.get_mqtt_status(path=p)
        self.assertTrue(st["configured"])
        self.assertEqual(st["username"], "u")
        self.assertNotIn("TOPSECRET", json.dumps(st))
        self.assertNotIn("password", st)


if __name__ == "__main__":
    unittest.main()
