"""The per-unit settings survive a flash (device r116).

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

    def test_scene(self):
        link, target = self.link("scene.json")
        self.assertIsNone(self.mod._scene_load(link), "dangling must read as never chosen")
        self.mod._scene_save("starfield", link)
        self.assert_written_through(link, target)
        self.assertEqual(self.mod._scene_load(link), "starfield")

    def test_output(self):
        link, target = self.link("output.json")
        self.assertIsNone(self.mod._output_load(link))
        self.mod._output_save("spdif", link)
        self.assert_written_through(link, target)
        self.assertEqual(self.mod._output_load(link), "spdif")

    def test_volume(self):
        link, target = self.link("volume.json")
        store = self.mod.VolumeStore(path=link, delay=3600)
        store.settle("speaker")
        store.note("speaker", 23, True)
        store.flush()
        self.assert_written_through(link, target)
        self.assertEqual(self.mod.VolumeStore(path=link).get("speaker"), (23, True))

    def test_diagnostics(self):
        # read by the launchers as uid 10000: still 0644 through the link
        link, target = self.link("diagnostics.json")
        self.mod.diag_write({"until": 5.0, "since": 1.0, "hours": 24, "endedAt": None}, link)
        self.assert_written_through(link, target)
        self.assertEqual(os.stat(target).st_mode & 0o777, 0o644)
        self.assertEqual(self.mod.diag_load(link)["until"], 5.0)

    def test_a_plain_file_still_works(self):
        # an image without the store, or a unit that never booted r116
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
        with tempfile.TemporaryDirectory() as d, \
                mock.patch.object(mod, "SCENE_CONF_PATH", os.path.join(d, "scene.json")), \
                mock.patch.object(mod, "nexusqd_send", side_effect=lambda l: sent.append(l) or True):
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


# --- everything the app sets survives a flash (Petr, 2026-09-28) ------------
import sys  # noqa: E402
sys.path.insert(0, HERE)
import test_volume_reconcile as vr  # noqa: E402

VMOD = vr.MOD


class TestSceneIsKept(unittest.TestCase):
    def test_set_scene_writes_it_and_a_new_bridge_reports_it(self):
        mod = load_daemon()
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "scene.json")
            with mock.patch.object(mod, "SCENE_CONF_PATH", path), \
                    mock.patch.object(mod, "nexusqd_send", return_value=True):
                bare_bridge(mod).handle("setScene", {"scene": "pointmorph"})
                self.assertEqual(mod._scene_load(), "pointmorph")

    def test_the_boot_restore_sends_the_saved_scene(self):
        mod = load_daemon()
        sent = []
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "scene.json")
            mod._scene_save("circles", path)
            with mock.patch.object(mod, "nexusqd_send", side_effect=lambda l: sent.append(l) or True):
                mod.scene_restore_thread(path)
        self.assertEqual(sent, ["scene 2"])

    def test_nothing_saved_nothing_sent(self):
        mod = load_daemon()
        with mock.patch.object(mod, "nexusqd_send") as send:
            mod.scene_restore_thread("/nonexistent/scene.json")
        send.assert_not_called()


class _Boot(vr.Patched):
    """The volume-half fake bridge with a REAL VolumeStore and output file."""

    def setUp(self):
        super().setUp()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.output_conf = os.path.join(self.tmp.name, "output.json")
        p = mock.patch.object(VMOD, "OUTPUT_CONF_PATH", self.output_conf)
        p.start()
        self.addCleanup(p.stop)

    def bridge(self, level=30, muted=False, output="spdif"):
        pulse = vr.FakePulse(up=True, default=vr.SPDIF)
        mixer = vr.FakeMixer(pulse, level=level, muted=muted)
        b = vr.Bridge(pulse, mixer, output=output)
        b.volumes = VMOD.VolumeStore(path=os.path.join(self.tmp.name, "volume.json"),
                                     delay=3600)
        return b, mixer


class TestOutputIsKept(_Boot):
    def test_boot_goes_to_the_saved_output(self):
        VMOD._output_save("spdif")
        b, _ = self.bridge(output="speaker")
        with mock.patch.object(VMOD, "BOOT_OUTPUT", "speaker"):
            b._boot_output(attempts=1, pause_s=0)
        self.assertEqual(b.state["output"], "spdif")

    def test_nothing_saved_is_the_speaker(self):
        b, _ = self.bridge()
        with mock.patch.object(VMOD, "BOOT_OUTPUT", "speaker"):
            b._boot_output(attempts=1, pause_s=0)
        self.assertEqual(b.state["output"], "speaker")

    def test_hdmi_without_a_sink_on_the_cable_falls_back_and_keeps_the_choice(self):
        VMOD._output_save("hdmi")
        b, _ = self.bridge()
        with mock.patch.object(VMOD, "BOOT_OUTPUT", "speaker"), \
                mock.patch.object(VMOD, "hdmi_probe", return_value={"connected": False}):
            b._boot_output(attempts=1, pause_s=0)
        self.assertEqual(b.state["output"], "speaker")
        # the TV was off at boot; the user's choice is still HDMI
        self.assertEqual(VMOD._output_load(), "hdmi")

    def test_only_the_users_choice_is_saved(self):
        b, _ = self.bridge()
        b.handle = VMOD.Bridge.handle.__get__(b)
        with mock.patch.object(VMOD, "BOOT_OUTPUT", "speaker"):
            b._boot_output(attempts=1, pause_s=0)
        self.assertIsNone(VMOD._output_load(), "a boot switch is not a choice")
        VMOD.Bridge.handle(b, "setOutput", {"output": "spdif"})
        self.assertEqual(VMOD._output_load(), "spdif")


class TestVolumeIsKept(_Boot):
    def test_a_flash_gets_the_saved_volume_back(self):
        # the store says 23 % muted; the fresh sink says PulseAudio's default
        b, mixer = self.bridge(level=100)
        b.volumes.levels["speaker"] = (23, True)
        with mock.patch.object(VMOD, "BOOT_OUTPUT", "speaker"):
            b._boot_output(attempts=1, pause_s=0)
        self.assertEqual((mixer.level, mixer.muted), (23, True))
        self.assertEqual((b.state["volume"], b.state["muted"]), (23, True))

    def test_a_normal_reboot_writes_nothing_to_the_sink(self):
        b, mixer = self.bridge(level=23)
        b.volumes.levels["speaker"] = (23, False)
        with mock.patch.object(VMOD, "BOOT_OUTPUT", "speaker"):
            b._boot_output(attempts=1, pause_s=0)
        self.assertNotIn(("volume", 23), mixer.writes)

    def test_the_default_is_not_noted_before_the_restore(self):
        # pa_watch_thread's first reconcile can come before _boot_output: the
        # fresh sink's 100 % must not overwrite the saved 23 %
        b, _ = self.bridge(level=100, output="speaker")
        b.volumes.levels["speaker"] = (23, False)
        b._reconcile_volume()
        self.assertEqual(b.volumes.get("speaker"), (23, False))

    def test_the_knob_is_noted_once_settled(self):
        b, mixer = self.bridge(level=30, output="speaker")
        b.volumes.settle("speaker")
        mixer.level = 41                     # the dome knob, straight into PA
        b._reconcile_volume()
        self.assertEqual(b.volumes.get("speaker"), (41, False))

    def test_the_app_is_noted(self):
        b, _ = self.bridge(level=30, output="speaker")
        b.volumes.settle("speaker")
        b._volume_cmd("setVolume", {"volume": 12})
        self.assertEqual(b.volumes.get("speaker"), (12, False))

    def test_a_drag_is_one_write(self):
        path = os.path.join(self.tmp.name, "drag.json")
        store = VMOD.VolumeStore(path=path, delay=0.2)
        store.settle("speaker")
        with mock.patch.object(VMOD, "write_json_through",
                               wraps=VMOD.write_json_through) as w:
            for v in range(10, 40):
                store.note("speaker", v, False)
            import time
            time.sleep(0.5)
        self.assertEqual(w.call_count, 1)
        self.assertEqual(VMOD.VolumeStore(path=path).get("speaker"), (39, False))

    def test_garbage_in_the_file_is_ignored(self):
        path = os.path.join(self.tmp.name, "bad.json")
        with open(path, "w") as f:
            json.dump({"outputs": {"speaker": {"volume": 400, "muted": False},
                                   "tv": {"volume": 5, "muted": False},
                                   "spdif": {"volume": 30, "muted": "no"}}}, f)
        self.assertEqual(VMOD.VolumeStore(path=path).levels, {})
