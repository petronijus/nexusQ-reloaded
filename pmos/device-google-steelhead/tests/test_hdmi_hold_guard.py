"""The hold's "put the console back on the black VT" guard.

⚠️ The LIVE interaction this guard exists for — toggling the HDMI desktop on and
off while the hold is running — is UNTESTED on hardware: the hold only runs with
an awake sink attached, and there was no way to keep the receiver awake long
enough (2026-09-20). What IS pinned here is the decision logic, so the part that
could do damage — a `chvt` underneath a running compositor — cannot happen by
accident.

The guard's contract:

    a real DRM master is present  -> do nothing, the screen is the compositor's
    no master, console drifted    -> re-park it on the hold's VT
    we cannot tell                -> do nothing; acting on a guess is the one
                                     outcome worse than a console on screen

The worst case if the live path is wrong is cosmetic (the console ends up on the
wrong VT). Audio does not depend on any of it — that only needs `fb0` unblanked,
which `_keep_lit()` handles separately.
"""

import importlib.machinery
import importlib.util
import os
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "nq-hdmi")


def load_tool():
    spec = importlib.util.spec_from_loader(
        "nq_hdmi_guard", importlib.machinery.SourceFileLoader("nq_hdmi_guard", TOOL))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_tool()

# Shapes taken from a real /sys/kernel/debug/dri/0/clients. The master column
# has moved between kernel versions, which is why the code finds it by NAME.
CLIENTS_NO_MASTER = """\
             command   tgid dev master a   uid      magic
                 Xorg    123   0       n     0          0
"""
CLIENTS_WITH_MASTER = """\
             command   tgid dev master a   uid      magic
                labwc    456   0       y     0          0
                 some    789   0       n     0          0
"""
# Same data, master column moved: a positional parser would read the wrong field.
CLIENTS_REORDERED = """\
             command master   tgid dev a   uid      magic
                labwc      y    456   0     0          0
"""


class TestDrmMasterDetection(unittest.TestCase):
    def _probe(self, text=None, boom=False):
        if boom:
            cm = mock.patch("builtins.open", side_effect=OSError)
        else:
            cm = mock.patch("builtins.open", mock.mock_open(read_data=text))
        with cm:
            return MOD._drm_master_present()

    def test_a_compositor_is_seen(self):
        self.assertIs(self._probe(CLIENTS_WITH_MASTER), True)

    def test_no_compositor_is_seen(self):
        self.assertIs(self._probe(CLIENTS_NO_MASTER), False)

    def test_the_master_column_is_found_by_name_not_position(self):
        self.assertIs(self._probe(CLIENTS_REORDERED), True)

    def test_unreadable_debugfs_is_dont_know_not_no(self):
        # The distinction that matters: None must never be mistaken for False,
        # or we would chvt underneath a compositor we simply could not see.
        self.assertIsNone(self._probe(boom=True))

    def test_a_header_we_do_not_understand_is_dont_know(self):
        self.assertIsNone(self._probe("some other format entirely\n"))

    def test_an_empty_file_is_dont_know(self):
        self.assertIsNone(self._probe(""))


class TestKeepBlackGuard(unittest.TestCase):
    def _hold(self):
        h = MOD.Hold.__new__(MOD.Hold)
        h.prev_vt = None
        h.prev_cursor = None
        h.parked = 0
        h._park_console = lambda: setattr(h, "parked", h.parked + 1)
        return h

    def _run(self, master, active_vt):
        h = self._hold()
        with mock.patch.object(MOD, "_drm_master_present", return_value=master), \
             mock.patch.object(MOD, "_read", return_value=active_vt):
            MOD.Hold._keep_black(h)
        return h.parked

    def test_it_reparks_when_the_console_drifted_and_nothing_holds_the_device(self):
        self.assertEqual(self._run(False, "tty1"), 1)

    def test_it_leaves_a_compositor_alone(self):
        # The damaging case: a chvt underneath labwc.
        self.assertEqual(self._run(True, "tty1"), 0)

    def test_it_does_nothing_when_it_cannot_tell(self):
        self.assertEqual(self._run(None, "tty1"), 0)

    def test_it_does_nothing_when_the_console_is_already_parked(self):
        self.assertEqual(self._run(False, f"tty{MOD.HOLD_VT}"), 0)


if __name__ == "__main__":
    unittest.main()
