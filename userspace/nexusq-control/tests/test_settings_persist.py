"""The per-unit settings survive a flash (device r106).

theme.json, ring.json, eq.json and eq-presets.json under /etc/nexusq are
symlinks into the persist store, like device.json since r103. A write that
replaces the LINK with a regular file still "works" -- the setting shows up --
and the next flash loses it again, silently. Pin, for every one of them, that
the link survives, the target carries the content, and a dangling link (a
store that has never held the setting) behaves as "never set".
"""
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import threading
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class LinkedSetting(unittest.TestCase):
    """A link /etc-nexusq/<name> -> store/settings/<name>, dangling at first."""

    def setUp(self):
        self.mod = load_daemon()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = os.path.join(self.tmp.name, "persist", "settings")
        os.makedirs(os.path.join(self.tmp.name, "etc-nexusq"))

    def link(self, name):
        target = os.path.join(self.store, name)
        link = os.path.join(self.tmp.name, "etc-nexusq", name)
        os.symlink(target, link)
        return link, target

    def assert_written_through(self, link, target):
        self.assertTrue(os.path.islink(link), "the link was replaced by a regular file")
        self.assertTrue(os.path.isfile(target), "the store holds nothing")
        self.assertEqual(sorted(os.listdir(self.store)), [os.path.basename(target)],
                         "temp file left behind")


class TestEverySettingWritesThroughItsLink(LinkedSetting):
    def test_theme(self):
        link, target = self.link("theme.json")
        self.assertIsNone(self.mod._theme_load(link), "dangling must read as never themed")
        self.mod._theme_save("rose", link)
        self.assert_written_through(link, target)
        self.assertEqual(self.mod._theme_load(link), "rose")

    def test_ring(self):
        link, target = self.link("ring.json")
        ring = self.mod.Ring(path=link, send=lambda line: True, synced=lambda: True)
        self.assertTrue(ring.snapshot()["on"], "dangling must read as never set")
        ring.set_on({"on": False})
        self.assert_written_through(link, target)
        self.assertFalse(self.mod.Ring(path=link, send=lambda line: True,
                                       synced=lambda: True).snapshot()["on"])

    def test_eq(self):
        link, target = self.link("eq.json")
        with mock.patch.object(self.mod, "eq_supported", return_value=True), \
             mock.patch.object(self.mod, "_eq_apply"):
            self.mod.set_eq({"bass_db": 3.0}, path=link)
        self.assert_written_through(link, target)
        with open(target) as f:
            self.assertIn("bands", json.load(f))

    def test_eq_presets(self):
        link, target = self.link("eq-presets.json")
        self.mod._eq_user_presets_write(
            [{"id": "vinyl", "label": "Vinyl", "bands": [], "preamp_db": 0.0}], link)
        self.assert_written_through(link, target)
        with open(target) as f:
            self.assertEqual(json.load(f)["presets"][0]["id"], "vinyl")

    def test_a_plain_file_still_works(self):
        # an image without the store, or a unit that never booted r106
        plain = os.path.join(self.tmp.name, "theme.json")
        self.mod._theme_save("warm", plain)
        self.assertFalse(os.path.islink(plain))
        self.assertEqual(self.mod._theme_load(plain), "warm")


def bare_bridge(mod):
    """Just enough of a Bridge for handle(): no PulseAudio, no threads."""
    b = object.__new__(mod.Bridge)
    b.lock = threading.Lock()
    b.state = {"theme": "blue", "scene": "waveform", "brightness": 255}
    b.ring = mock.Mock(snapshot=mock.Mock(return_value={"on": True}))
    b.brightness = mock.Mock(snapshot=mock.Mock(return_value={"enabled": False}))
    return b


class TestSceneLeavesTheThemeAlone(unittest.TestCase):
    def test_set_scene_sends_only_the_scene(self):
        # `auto` before `scene N` cleared the theme's breathing override until
        # the next setTheme or reboot, while getState still reported the theme.
        mod = load_daemon()
        sent = []
        with mock.patch.object(mod, "nexusqd_send", side_effect=lambda l: sent.append(l) or True):
            result, events = bare_bridge(mod).handle("setScene", {"scene": "circles"})
        self.assertEqual(sent, ["scene 2"])
        self.assertEqual(result, {"scene": "circles"})


class TestThemeStateComesFromTheFile(unittest.TestCase):
    def test_get_state_reports_a_theme_written_by_setupd(self):
        # The setup wizard picks the theme AFTER setName restarted the bridge;
        # setupd writes theme.json, and the bridge must report that, not the
        # copy it read at start-up.
        mod = load_daemon()
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "theme.json")
            mod._theme_save("cool", path)
            with mock.patch.object(mod, "THEME_CONF_PATH", path):
                st, _ = bare_bridge(mod).handle("getState", {})
        self.assertEqual(st["theme"], "cool")

    def test_no_file_keeps_the_bridge_default(self):
        mod = load_daemon()
        with tempfile.TemporaryDirectory() as d:
            with mock.patch.object(mod, "THEME_CONF_PATH", os.path.join(d, "none.json")):
                st, _ = bare_bridge(mod).handle("getState", {})
        self.assertEqual(st["theme"], "blue")


if __name__ == "__main__":
    unittest.main()
