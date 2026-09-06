import importlib.machinery
import importlib.util
import json
import os
import tempfile
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


class TestThemePersistence(unittest.TestCase):
    """r37: the colour theme survives a reboot and a bridge restart. Before, it
    lived only in memory — every boot breathed blue again, and after each OTA
    restart of the bridge the app said "blue" while the ring kept the old hue."""

    def setUp(self):
        self.mod = load_daemon()
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "nexusq", "theme.json")

    def tearDown(self):
        self.tmp.cleanup()

    def test_never_themed_reads_as_none(self):
        self.assertIsNone(self.mod._theme_load(self.path))

    def test_save_then_load_round_trips(self):
        self.mod._theme_save("warm", self.path)
        self.assertEqual(self.mod._theme_load(self.path), "warm")
        with open(self.path) as f:
            self.assertEqual(json.load(f), {"theme": "warm"})
        # no temp file left behind
        self.assertEqual(os.listdir(os.path.dirname(self.path)), ["theme.json"])

    def test_unknown_or_torn_file_reads_as_none(self):
        os.makedirs(os.path.dirname(self.path))
        for body in ('{"theme": "plaid"}', '{"theme": 7}', '[]', '{"the', ''):
            with open(self.path, "w") as f:
                f.write(body)
            self.assertIsNone(self.mod._theme_load(self.path), body)

    def test_every_shipped_theme_is_loadable(self):
        for name in self.mod.THEME_CMDS:
            self.mod._theme_save(name, self.path)
            self.assertEqual(self.mod._theme_load(self.path), name)

    def test_save_failure_is_an_unavailable_error(self):
        with mock.patch.object(self.mod.os, "replace", side_effect=OSError("ro fs")):
            with self.assertRaises(self.mod.Err) as cm:
                self.mod._theme_save("rose", self.path)
        self.assertEqual(cm.exception.code, "unavailable")

    def test_restore_sends_the_stored_theme_to_nexusqd(self):
        self.mod._theme_save("cool", self.path)
        sent = []
        with mock.patch.object(self.mod, "nexusqd_send", side_effect=lambda c: sent.append(c) or True):
            self.mod.theme_restore_thread(self.path)
        self.assertEqual(sent, self.mod.THEME_CMDS["cool"])

    def test_restore_sends_nothing_when_never_themed(self):
        # A box the user never themed keeps nexusqd's stock idle look — no
        # `breathe` is forced on it.
        with mock.patch.object(self.mod, "nexusqd_send") as send:
            self.mod.theme_restore_thread(self.path)
        send.assert_not_called()

    def test_restore_retries_until_nexusqd_is_up(self):
        self.mod._theme_save("rose", self.path)
        answers = iter([False, False, True])
        with mock.patch.object(self.mod, "nexusqd_send", side_effect=lambda c: next(answers)) as send, \
                mock.patch.object(self.mod.time, "sleep") as sleep:
            self.mod.theme_restore_thread(self.path)
        self.assertEqual(send.call_count, 3)
        self.assertEqual(sleep.call_count, 2)


if __name__ == "__main__":
    unittest.main()
