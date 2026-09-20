"""HDMI as a selectable audio output (GitHub issue #5).

Two things here are easy to get wrong and both are silent when wrong, which is
why they are pinned:

  ORDER. HDMI carries audio inside the blanking intervals of a video stream, so
  the output has to be lit before the ALSA device is opened. Open it first and
  PulseAudio happily accepts the sink and plays into an unclocked DSS — no
  error, no sound. Likewise on the way out: the HDMI sink may only be unloaded
  after the streams have been moved off it, or unloading kills them instead of
  relocating them.

  AVAILABILITY. Before this, HDMI was dropped from listOutputs whenever no PA
  sink matched — and since the card is PULSE_IGNORE'd there never was one, so
  the row existed in the code since 2026-07-07 and was never once shown to a
  user. Availability now follows the cable, not the sink list.
"""

import importlib.machinery
import importlib.util
import os
import threading
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control_hdmi",
        importlib.machinery.SourceFileLoader("nexusq_control_hdmi", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()

SPEAKER = "alsa_output.platform-sound-tas5713.stereo-fallback"
SPDIF = "alsa_output.platform-sound-spdif.stereo-fallback"


class FakePulse:
    """A PulseAudio that records what was done to it, in order."""

    def __init__(self, sinks=None, log=None, open_ok=True):
        self._sinks = list(sinks if sinks is not None else [SPDIF, SPEAKER])
        self.log = log if log is not None else []
        self.open_ok = open_ok
        self.default = SPEAKER
        self.moved = []

    def sinks(self):
        return list(self._sinks)

    def default_sink(self):
        return self.default

    def set_default_sink(self, sink):
        self.default = sink
        self.log.append(("default", sink))

    def move_all_inputs(self, sink):
        self.moved.append(sink)
        self.log.append(("move", sink))

    def set_default_source(self, source):
        self.log.append(("source", source))

    def load_module(self, module, *args):
        self.log.append(("load", module))
        if not self.open_ok:
            return "7"          # module loads, device does not open
        self._sinks.append(MOD.HDMI_SINK_NAME)
        return "7"

    def module_index(self, module, needle):
        return "7" if MOD.HDMI_SINK_NAME in self._sinks else None

    def unload_module(self, index):
        self.log.append(("unload", index))
        if MOD.HDMI_SINK_NAME in self._sinks:
            self._sinks.remove(MOD.HDMI_SINK_NAME)


class FakeMixer:
    def get(self, sink):
        return 40, False

    def set_volume(self, sink, pct):
        pass

    def set_muted(self, sink, muted):
        pass


class Bridge:
    """The output-routing half of the bridge, without a whole daemon."""

    def __init__(self, pulse=None, log=None):
        self.lock = threading.Lock()
        self.log = log if log is not None else []
        self.pulse = pulse or FakePulse(log=self.log)
        self.mixer = FakeMixer()
        self.state = {"output": "speaker", "volume": 40, "muted": False}
        self.sent = []

    _sink_for_output = MOD.Bridge._sink_for_output
    _output_for_sink = MOD.Bridge._output_for_sink
    _hdmi_sink_up = MOD.Bridge._hdmi_sink_up
    _hdmi_sink_down = MOD.Bridge._hdmi_sink_down
    _list_outputs = MOD.Bridge._list_outputs
    _set_output = MOD.Bridge._set_output
    _hdmi_watch_step = MOD.Bridge._hdmi_watch_step
    # staticmethod() matters: read off the class it is already unwrapped, and
    # assigning the bare function here would turn it back into a bound method.
    _hdmi_connector_status = staticmethod(MOD.Bridge._hdmi_connector_status)

    def broadcast(self, event, data):
        self.sent.append((event, data))


def probe(connected=True, audio=True, sink="SAMSUNG"):
    return {"connected": connected, "audio": audio, "sink": sink,
            "detail": "basic audio", "enabled": True, "blank": "0"}


class TestListOutputs(unittest.TestCase):
    def test_nothing_in_the_port_hides_the_row(self):
        b = Bridge()
        with mock.patch.object(MOD, "hdmi_probe",
                               return_value=probe(connected=False, audio=False)):
            ids = [o["id"] for o in b._list_outputs()["outputs"]]
        self.assertNotIn("hdmi", ids)
        self.assertEqual(ids, ["speaker", "spdif"])

    def test_audio_capable_sink_is_offered_even_with_no_pa_sink_loaded(self):
        # The regression this whole change is about: the PA sink is loaded on
        # demand, so it is absent until HDMI is picked. Availability must not
        # depend on it.
        b = Bridge()
        with mock.patch.object(MOD, "hdmi_probe", return_value=probe()):
            outs = {o["id"]: o for o in b._list_outputs()["outputs"]}
        self.assertIn("hdmi", outs)
        self.assertTrue(outs["hdmi"]["available"])
        self.assertEqual(outs["hdmi"]["sink"], "")

    def test_dvi_monitor_is_shown_but_not_selectable(self):
        b = Bridge()
        with mock.patch.object(MOD, "hdmi_probe",
                               return_value=probe(audio=False)):
            outs = {o["id"]: o for o in b._list_outputs()["outputs"]}
        self.assertIn("hdmi", outs)
        self.assertFalse(outs["hdmi"]["available"])

    def test_probe_failure_degrades_to_hidden_not_to_an_exception(self):
        b = Bridge()
        with mock.patch.object(MOD, "hdmi_probe", return_value={}):
            ids = [o["id"] for o in b._list_outputs()["outputs"]]
        self.assertNotIn("hdmi", ids)


class TestSelectHdmi(unittest.TestCase):
    def _select(self, bridge, oid, hold=None):
        hold = hold or mock.Mock()
        with mock.patch.object(MOD, "hdmi_hold", hold), \
             mock.patch.object(MOD, "hdmi_probe", return_value=probe()), \
             mock.patch.object(MOD, "_sync_panel_applet"), \
             mock.patch.object(MOD, "_amixer"), \
             mock.patch.object(MOD, "nexusqd_send"):
            return bridge._set_output({"output": oid}), hold

    def test_the_output_is_lit_before_the_device_is_opened(self):
        log = []
        b = Bridge(log=log)
        b.pulse = FakePulse(log=log)

        def hold(on, grace=False):
            log.append(("hold", on))

        self._select(b, "hdmi", hold=hold)
        # The exact ordering is the feature: hold(True) must precede the
        # load-module, or PulseAudio opens a card whose DSS is unclocked.
        self.assertLess(log.index(("hold", True)),
                        log.index(("load", "module-alsa-sink")))

    def test_selecting_hdmi_routes_to_the_hdmi_sink(self):
        b = Bridge()
        res, _ = self._select(b, "hdmi")
        self.assertEqual(res[0], {"output": "hdmi"})
        self.assertEqual(b.pulse.moved, [MOD.HDMI_SINK_NAME])
        self.assertEqual(b.state["output"], "hdmi")

    def test_a_device_that_will_not_open_releases_the_hold_and_reports_it(self):
        log = []
        b = Bridge(log=log)
        b.pulse = FakePulse(log=log, open_ok=False)
        hold = mock.Mock()
        with self.assertRaises(MOD.Err):
            self._select(b, "hdmi", hold=hold)
        # It must not leave the display lit for an output nobody can use.
        hold.assert_has_calls([mock.call(True), mock.call(False)])

    def test_an_unexpected_failure_also_puts_the_display_back_down(self):
        # The live run that found the misplaced-method bug left the hold running
        # after the switch had already failed, so the DSS and the TMDS PHY stayed
        # powered for an output the user had just been refused.
        b = Bridge()
        b.pulse = FakePulse(log=b.log)
        b.pulse.load_module = mock.Mock(side_effect=AttributeError("boom"))
        hold = mock.Mock()
        with self.assertRaises(AttributeError):
            self._select(b, "hdmi", hold=hold)
        hold.assert_has_calls([mock.call(True), mock.call(False)])

    def test_selecting_hdmi_twice_does_not_stack_a_second_module(self):
        b = Bridge()
        self._select(b, "hdmi")
        loads = [e for e in b.log if e[0] == "load"]
        self._select(b, "hdmi")
        self.assertEqual([e for e in b.log if e[0] == "load"], loads)


class TestHdmiWatch(unittest.TestCase):
    """HDMI availability is the only one that changes by itself, so it has to be
    pushed.

    Petr hit this on 2026-09-20: he switched to the speaker, the soundbar dozed
    off once the Q stopped feeding it a signal, he switched the soundbar back
    on — and the app still showed HDMI greyed out, because `listOutputs` is
    fetched once at connect and `outputChanged` only ever carried the ACTIVE id.
    """

    def _bridge(self, connector):
        """A bridge whose view of the DRM connector is whatever the test says."""
        b = Bridge()
        b._hdmi_connector_status = lambda: connector
        return b

    def test_the_first_look_says_nothing(self):
        # A client fetches the list when it connects; announcing at startup
        # would just be noise on every bridge restart.
        b = self._bridge("connected")
        with mock.patch.object(MOD, "hdmi_probe", return_value=probe()):
            last = b._hdmi_watch_step(None)
        self.assertEqual(last, "connected")
        self.assertEqual(b.sent, [])

    def test_a_sink_coming_back_is_announced_with_the_full_list(self):
        b = self._bridge("connected")
        with mock.patch.object(MOD, "hdmi_probe", return_value=probe()):
            b._hdmi_watch_step("disconnected")
        self.assertEqual(len(b.sent), 1)
        event, data = b.sent[0]
        self.assertEqual(event, "outputsChanged")
        # The payload must be the whole listOutputs answer, so the app can apply
        # it with the same code path it uses at connect.
        self.assertIn("outputs", data)
        self.assertIn("active", data)
        outs = {o["id"]: o for o in data["outputs"]}
        self.assertTrue(outs["hdmi"]["available"])

    def test_a_sink_going_away_is_announced_too(self):
        b = self._bridge("disconnected")
        with mock.patch.object(MOD, "hdmi_probe",
                               return_value=probe(connected=False, audio=False)):
            b._hdmi_watch_step("connected")
        self.assertEqual(len(b.sent), 1)
        self.assertEqual(b.sent[0][0], "outputsChanged")

    def test_an_unchanged_connector_is_silent(self):
        # The point of comparing the cheap sysfs string first: the expensive
        # probe must not run, and no event must be sent, when nothing happened.
        b = self._bridge("connected")
        p = mock.Mock(return_value=probe())
        with mock.patch.object(MOD, "hdmi_probe", p):
            last = b._hdmi_watch_step("connected")
        self.assertEqual(last, "connected")
        self.assertEqual(b.sent, [])
        p.assert_not_called()

    def test_a_broken_broadcast_never_kills_the_watcher(self):
        b = self._bridge("connected")
        b.broadcast = mock.Mock(side_effect=RuntimeError("boom"))
        with mock.patch.object(MOD, "hdmi_probe", return_value=probe()):
            last = b._hdmi_watch_step("disconnected")
        # It must still advance, or it would re-fire on every single tick.
        self.assertEqual(last, "connected")


class TestTheFakeMatchesTheRealThing(unittest.TestCase):
    """The fakes above are only worth something if the real objects have the
    same surface.

    This is not theory. The first live run of this feature died with
    `'Pulse' object has no attribute 'load_module'`: the three module helpers
    had been added to Mixer instead of Pulse, because both classes have a
    `set_muted` and the edit anchored on the wrong one. Every test above still
    passed, because FakePulse supplies the methods itself — a mock describing a
    world that did not exist. These assertions are the cheap guard against that
    whole class of mistake."""

    def test_pulse_has_everything_the_hdmi_path_calls_on_it(self):
        for name in ("load_module", "unload_module", "module_index",
                     "sinks", "default_sink", "set_default_sink",
                     "move_all_inputs", "set_default_source"):
            self.assertTrue(callable(getattr(MOD.Pulse, name, None)),
                            f"Pulse.{name} is missing")

    def test_the_module_helpers_live_on_pulse_not_on_mixer(self):
        # Mixer speaks volume, Pulse speaks plumbing; putting these on Mixer is
        # exactly the bug that got shipped to the device once.
        for name in ("load_module", "unload_module", "module_index"):
            self.assertFalse(hasattr(MOD.Mixer, name),
                             f"Mixer.{name} belongs on Pulse")

    def test_the_fake_covers_the_real_surface(self):
        for name in ("sinks", "default_sink", "set_default_sink",
                     "move_all_inputs", "set_default_source",
                     "load_module", "unload_module", "module_index"):
            self.assertTrue(callable(getattr(FakePulse, name, None)),
                            f"FakePulse.{name} is missing")


class TestLeavingHdmi(unittest.TestCase):
    def test_streams_move_before_the_hdmi_sink_is_unloaded(self):
        log = []
        b = Bridge(log=log)
        b.pulse = FakePulse(log=log)

        def hold(on, grace=False):
            log.append(("hold", on))

        with mock.patch.object(MOD, "hdmi_hold", hold), \
             mock.patch.object(MOD, "hdmi_probe", return_value=probe()), \
             mock.patch.object(MOD, "_sync_panel_applet"), \
             mock.patch.object(MOD, "_amixer"), \
             mock.patch.object(MOD, "nexusqd_send"):
            b._set_output({"output": "hdmi"})
            log.clear()
            b._set_output({"output": "speaker"})

        # Unloading a sink that still owns a stream kills the stream; the move
        # has to happen first.
        self.assertLess(log.index(("move", SPEAKER)), log.index(("unload", "7")))
        # …and only then is the display released.
        self.assertLess(log.index(("unload", "7")), log.index(("hold", False)))

    def test_the_hdmi_sink_is_gone_afterwards(self):
        b = Bridge()
        with mock.patch.object(MOD, "hdmi_hold"), \
             mock.patch.object(MOD, "hdmi_probe", return_value=probe()), \
             mock.patch.object(MOD, "_sync_panel_applet"), \
             mock.patch.object(MOD, "_amixer"), \
             mock.patch.object(MOD, "nexusqd_send"):
            b._set_output({"output": "hdmi"})
            self.assertIn(MOD.HDMI_SINK_NAME, b.pulse.sinks())
            b._set_output({"output": "spdif"})
        self.assertNotIn(MOD.HDMI_SINK_NAME, b.pulse.sinks())

    def test_leaving_hdmi_lets_the_hold_linger_rather_than_dropping_it(self):
        # Releasing at once would mean every "switch to the speaker for a bit"
        # puts the receiver into a standby this board cannot wake it from.
        b = Bridge()
        hold = mock.Mock()
        with mock.patch.object(MOD, "hdmi_hold", hold), \
             mock.patch.object(MOD, "hdmi_probe", return_value=probe()), \
             mock.patch.object(MOD, "_sync_panel_applet"), \
             mock.patch.object(MOD, "_amixer"), \
             mock.patch.object(MOD, "nexusqd_send"):
            b._set_output({"output": "hdmi"})
            hold.reset_mock()
            b._set_output({"output": "speaker"})
        hold.assert_called_once_with(False, grace=True)

    def test_a_failed_switch_releases_at_once_with_no_grace(self):
        # Nothing to come back to, so the display must not linger.
        b = Bridge()
        b.pulse = FakePulse(log=b.log, open_ok=False)
        hold = mock.Mock()
        with mock.patch.object(MOD, "hdmi_hold", hold), \
             mock.patch.object(MOD, "hdmi_probe", return_value=probe()), \
             mock.patch.object(MOD, "_sync_panel_applet"), \
             mock.patch.object(MOD, "_amixer"), \
             mock.patch.object(MOD, "nexusqd_send"), \
             self.assertRaises(MOD.Err):
            b._set_output({"output": "hdmi"})
        self.assertIn(mock.call(False), hold.mock_calls)
        for c in hold.mock_calls:
            self.assertNotEqual(c, mock.call(False, grace=True))

    def test_picking_the_speaker_never_touches_the_hold_when_hdmi_was_never_up(self):
        # A plain speaker/spdif switch on a unit with nothing in the HDMI port
        # must not start systemctl churn on every tap.
        b = Bridge()
        hold = mock.Mock()
        with mock.patch.object(MOD, "hdmi_hold", hold), \
             mock.patch.object(MOD, "hdmi_probe",
                               return_value=probe(connected=False, audio=False)), \
             mock.patch.object(MOD, "_sync_panel_applet"), \
             mock.patch.object(MOD, "_amixer"), \
             mock.patch.object(MOD, "nexusqd_send"):
            b._set_output({"output": "spdif"})
        # It still asks, but with grace — and hdmi_hold() itself no-ops when
        # nothing is holding, rather than arming a timer for an idle unit.
        hold.assert_called_once_with(False, grace=True)


if __name__ == "__main__":
    unittest.main()


class TestHoldGracePeriod(unittest.TestCase):
    """The real `hdmi_hold`, with systemd faked, so the grace policy is pinned
    where it is actually implemented rather than at the call site."""

    def _run(self, on, grace=False, active=True, systemd_ok=True):
        calls = []

        def fake_run(argv, **kw):
            calls.append(list(argv))
            rc = 0 if systemd_ok or argv[0] != "systemd-run" else 1
            return mock.Mock(returncode=rc, stdout="", stderr="")

        with mock.patch.object(MOD.subprocess, "run", fake_run), \
             mock.patch.object(MOD, "hdmi_hold_active", return_value=active):
            MOD.hdmi_hold(on, grace=grace)
        return calls

    def test_a_graceful_leave_arms_a_timer_instead_of_stopping(self):
        calls = self._run(False, grace=True)
        armed = [c for c in calls if c[0] == "systemd-run"]
        self.assertEqual(len(armed), 1)
        self.assertIn(f"--unit={MOD.HDMI_RELEASE_UNIT}", armed[0])
        self.assertIn("--on-active=%d" % int(MOD.HDMI_HOLD_GRACE_S), armed[0])
        # …and it must NOT also stop the hold there and then.
        self.assertNotIn(["systemctl", "stop", MOD.HDMI_HOLD_UNIT], calls)

    def test_an_immediate_leave_really_stops_it(self):
        calls = self._run(False, grace=False)
        self.assertIn(["systemctl", "stop", MOD.HDMI_HOLD_UNIT], calls)
        self.assertEqual([c for c in calls if c[0] == "systemd-run"], [])

    def test_nothing_to_linger_for_arms_nothing(self):
        calls = self._run(False, grace=True, active=False)
        self.assertEqual(calls, [])

    def test_an_unarmable_timer_falls_back_to_stopping_now(self):
        # Better released early than held forever with nothing to take it down.
        calls = self._run(False, grace=True, systemd_ok=False)
        self.assertIn(["systemctl", "stop", MOD.HDMI_HOLD_UNIT], calls)

    def test_coming_back_cancels_a_pending_release(self):
        calls = self._run(True)
        self.assertIn(["systemctl", "stop", f"{MOD.HDMI_RELEASE_UNIT}.timer"],
                      calls)
        self.assertIn(["systemctl", "start", MOD.HDMI_HOLD_UNIT], calls)
