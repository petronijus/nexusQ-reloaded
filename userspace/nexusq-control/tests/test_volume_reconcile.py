"""The volume a client reads at boot is the Q's, not a made-up 50 (control r55).

Found on the Prague Q on 2026-09-27, right after the one-volume install: Home
Assistant showed Volume 50 while the sink, the bridge's own getState and the
room were all at 30. The sequence:

  1. the bridge starts before the user session's PulseAudio, cannot read the
     sink, and seeded state["volume"] with a made-up 50;
  2. nexusq-mqtt connects a few seconds later, calls getState and gets 50;
  3. _boot_output switches to the speaker once PulseAudio is up, reads the
     real 30 into state -- and discarded the events, because its comment said
     "no clients yet";
  4. pa_watch_thread then compared every sink event against a state that
     already said 30, so it never broadcast either.

So a client that connected early kept the wrong number until the next real
volume change. Pinned here: the level is unknown (null) until it is read, the
first subscribe reconciles and broadcasts, _boot_output broadcasts what
_set_output returns, and the relative commands never act on a guess.
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
        "nexusq_control_volrec",
        importlib.machinery.SourceFileLoader("nexusq_control_volrec", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()

SPEAKER = "alsa_output.platform-sound-tas5713.stereo-fallback"
SPDIF = "alsa_output.platform-sound-spdif.stereo-fallback"


class FakePulse:
    """PulseAudio that is either not up yet (no sinks, no default) or up."""

    def __init__(self, up=True, default=SPDIF):
        self.up = up
        self.default = default

    def sinks(self):
        return [SPDIF, SPEAKER] if self.up else []

    def default_sink(self):
        return self.default if self.up else None

    def set_default_sink(self, sink):
        self.default = sink

    def move_all_inputs(self, sink):
        pass

    def set_default_source(self, source):
        pass

    def module_index(self, module, needle):
        return None

    def unload_module(self, index):
        pass


class FakeMixer:
    def __init__(self, pulse, level=30, muted=False):
        self.pulse = pulse
        self.level, self.muted = level, muted
        self.writes = []

    def get(self, sink):
        if not self.pulse.up or not sink:
            return None, None
        return self.level, self.muted

    def set_volume(self, sink, pct):
        self.writes.append(("volume", pct))
        self.level, self.muted = pct, False

    def set_muted(self, sink, muted):
        self.writes.append(("muted", muted))
        self.muted = muted


class FakeFollow:
    def __init__(self):
        self.seen = []

    def volume_changed(self, vol, muted):
        self.seen.append((vol, muted))


class Bridge:
    """The volume half of the bridge, without a whole daemon."""

    def __init__(self, pulse, mixer, volume=None, muted=None, output="spdif"):
        self.lock = threading.Lock()
        self.pulse, self.mixer = pulse, mixer
        self.state = {"output": output, "volume": volume, "muted": muted}
        self.airplay_volume = FakeFollow()
        self.sent = []
        # inert: persisting the volume has its own tests (test_settings_persist.py)
        self.volumes = mock.Mock(settled=lambda oid: True, note=lambda *a: False,
                                 get=lambda oid: None)

    _active_sink = MOD.Bridge._active_sink
    _sink_for_output = MOD.Bridge._sink_for_output
    _output_for_sink = MOD.Bridge._output_for_sink
    _hdmi_sink_down = MOD.Bridge._hdmi_sink_down
    _set_output = MOD.Bridge._set_output
    _boot_output = MOD.Bridge._boot_output
    _reconcile_volume = MOD.Bridge._reconcile_volume
    _volume_cmd = MOD.Bridge._volume_cmd
    _restore_volume = MOD.Bridge._restore_volume
    _boot_available = MOD.Bridge._boot_available

    def _reconcile_source(self):
        return False              # the tap's source: test_tap_source.py

    def broadcast(self, event, data):
        self.sent.append((event, data))


def quiet():
    """The side effects _set_output and _volume_cmd reach outside the bridge."""
    return [mock.patch.object(MOD, name) for name in
            ("hdmi_hold", "_sync_panel_applet", "_amixer", "nexusqd_send")] + [
        # no saved output: the host's /etc must never steer a test
        mock.patch.object(MOD, "OUTPUT_CONF_PATH", "/nonexistent/output.json")]


class Patched(unittest.TestCase):
    def setUp(self):
        for p in quiet():
            p.start()
            self.addCleanup(p.stop)


class TestStartupState(unittest.TestCase):
    """The real Bridge.__init__, with PulseAudio not up yet."""

    def build(self, up):
        pulse = FakePulse(up=up)
        mixer = FakeMixer(pulse, level=30)
        started = []

        class NoThread:
            def __init__(self, target=None, daemon=None, args=()):
                started.append(target)

            def start(self):
                pass

        with mock.patch.object(MOD, "Pulse", return_value=pulse), \
             mock.patch.object(MOD, "Mixer", return_value=mixer), \
             mock.patch.object(MOD.threading, "Thread", NoThread):
            return MOD.Bridge()

    def test_no_made_up_level_before_pulseaudio(self):
        b = self.build(up=False)
        st, _ = b.handle("getState", {})
        self.assertIsNone(st["volume"])
        self.assertIsNone(st["muted"])

    def test_the_real_level_when_pulseaudio_is_up(self):
        b = self.build(up=True)
        st, _ = b.handle("getState", {})
        self.assertEqual((st["volume"], st["muted"]), (30, False))


class TestReconcile(Patched):
    def test_first_read_is_broadcast(self):
        pulse = FakePulse(up=True)
        b = Bridge(pulse, FakeMixer(pulse, level=30))
        self.assertTrue(b._reconcile_volume())
        self.assertEqual(b.sent, [("volumeChanged", {"volume": 30, "muted": False})])
        self.assertEqual(b.airplay_volume.seen, [(30, False)])

    def test_nothing_while_pulseaudio_is_down(self):
        pulse = FakePulse(up=False)
        b = Bridge(pulse, FakeMixer(pulse))
        self.assertFalse(b._reconcile_volume())
        self.assertEqual(b.sent, [])
        self.assertIsNone(b.state["volume"])

    def test_no_event_when_nothing_moved(self):
        pulse = FakePulse(up=True)
        b = Bridge(pulse, FakeMixer(pulse, level=30), volume=30, muted=False)
        self.assertFalse(b._reconcile_volume())
        self.assertEqual(b.sent, [])


class TestWatchThreadReconcilesOnSubscribe(Patched):
    """The Prague failure itself: a client holds a stale level, and no sink
    event comes. Subscribing must be enough to correct it."""

    def run_one_subscribe(self, b, lines=()):
        class Proc:
            stdout = iter(lines)

            def kill(self):
                pass

        class Stop(Exception):
            pass

        def sleep(_):
            raise Stop

        with mock.patch.object(MOD.subprocess, "Popen", return_value=Proc()), \
             mock.patch.object(MOD.time, "sleep", sleep):
            with self.assertRaises(Stop):
                MOD.pa_watch_thread(b)

    def test_stale_level_is_corrected_without_a_sink_event(self):
        pulse = FakePulse(up=True)
        b = Bridge(pulse, FakeMixer(pulse, level=30), volume=50, muted=False)
        self.run_one_subscribe(b)
        self.assertEqual(b.state["volume"], 30)
        self.assertIn(("volumeChanged", {"volume": 30, "muted": False}), b.sent)

    def test_sink_event_still_reconciles(self):
        pulse = FakePulse(up=True)
        mixer = FakeMixer(pulse, level=30)
        b = Bridge(pulse, mixer, volume=30, muted=False)

        def lines():
            mixer.level = 44          # the knob turns after the subscribe
            yield "Event 'change' on sink #1\n"

        self.run_one_subscribe(b, lines())
        self.assertEqual(b.sent, [("volumeChanged", {"volume": 44, "muted": False})])


class TestBootOutput(Patched):
    def test_the_switch_is_broadcast(self):
        pulse = FakePulse(up=True, default=SPDIF)
        b = Bridge(pulse, FakeMixer(pulse, level=30), volume=None, muted=None,
                   output="spdif")
        with mock.patch.object(MOD, "BOOT_OUTPUT", "speaker"):
            b._boot_output(attempts=1, pause_s=0)
        self.assertEqual(b.state["output"], "speaker")
        self.assertIn(("outputChanged", {"output": "speaker"}), b.sent)
        self.assertIn(("volumeChanged", {"volume": 30, "muted": False}), b.sent)

    def test_unknown_level_is_not_announced(self):
        pulse = FakePulse(up=True, default=SPDIF)
        mixer = FakeMixer(pulse)
        mixer.get = lambda sink: (None, None)     # the sink will not answer yet
        b = Bridge(pulse, mixer, volume=None, muted=None, output="spdif")
        _, events = b._set_output({"output": "speaker"})
        self.assertEqual(events, [("outputChanged", {"output": "speaker"})])


class TestRelativeCommandsNeverGuess(Patched):
    def test_adjust_reads_the_sink_when_unknown(self):
        pulse = FakePulse(up=True, default=SPEAKER)
        mixer = FakeMixer(pulse, level=30)
        b = Bridge(pulse, mixer, output="speaker")
        res, _ = b._volume_cmd("adjustVolume", {"steps": 2})
        self.assertEqual(res["volume"], 32)
        self.assertEqual(mixer.writes, [("volume", 32)])

    def test_toggle_mute_reads_the_sink_when_unknown(self):
        pulse = FakePulse(up=True, default=SPEAKER)
        mixer = FakeMixer(pulse, level=30, muted=True)
        b = Bridge(pulse, mixer, output="speaker")
        res, _ = b._volume_cmd("toggleMute", {})
        self.assertFalse(res["muted"])

    def test_refused_while_pulseaudio_is_down(self):
        pulse = FakePulse(up=False)
        mixer = FakeMixer(pulse)
        b = Bridge(pulse, mixer, output="speaker")
        with self.assertRaises(MOD.Err) as cm:
            b._volume_cmd("adjustVolume", {"steps": 2})
        self.assertEqual(cm.exception.code, "unavailable")
        self.assertEqual(mixer.writes, [])


if __name__ == "__main__":
    unittest.main()
