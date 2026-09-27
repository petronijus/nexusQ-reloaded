"""The LED ring's visualiser records what the speaker plays (control r56).

nexusqd's tap is `arecord -D pulse`, which records PulseAudio's DEFAULT
source, and the bridge keeps that on the default sink's monitor. On the Prague
Q on 2026-09-27 the ring showed no visualisation during playback: the default
source was `usb_in`. nexusq-uac2-in had loaded that source after the bridge
set the monitor at boot, and postmarketOS's module-switch-on-connect makes
every new source the default and moves the tap onto it. device r118 unloads
that module; the bridge now also puts the default source back whenever it
drifts. PulseAudio restores its saved default at start, and on that unit the
saved default was usb_in.

Pinned: the reconcile itself, that pa_watch_thread runs it on subscribe and on
a server event, and that it follows PA's default sink rather than the bridge's
output state (a switch in progress must not be steered back).
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
        "nexusq_control_tap",
        importlib.machinery.SourceFileLoader("nexusq_control_tap", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()

SPEAKER = "alsa_output.platform-sound-tas5713.stereo-fallback"
SPDIF = "alsa_output.platform-sound-spdif.stereo-fallback"


class FakePulse:
    def __init__(self, default_sink=SPEAKER, default_source="usb_in", up=True):
        self.sink, self.source, self.up = default_sink, default_source, up
        self.source_writes = []

    def sinks(self):
        return [SPDIF, SPEAKER] if self.up else []

    def default_sink(self):
        return self.sink if self.up else None

    def default_source(self):
        return self.source if self.up else None

    def set_default_source(self, source):
        self.source_writes.append(source)
        self.source = source


class Bridge:
    def __init__(self, pulse, output="speaker"):
        self.lock = threading.Lock()
        self.pulse = pulse
        self.state = {"output": output, "volume": 30, "muted": False}
        self.volume_reconciles = 0

    _reconcile_source = MOD.Bridge._reconcile_source
    _active_sink = MOD.Bridge._active_sink
    _sink_for_output = MOD.Bridge._sink_for_output
    _output_for_sink = MOD.Bridge._output_for_sink

    def _reconcile_volume(self):
        self.volume_reconciles += 1
        return False


def run_one_subscribe(b, lines=()):
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
        try:
            MOD.pa_watch_thread(b)
        except Stop:
            pass


class TestReconcileSource(unittest.TestCase):
    def test_a_stolen_default_is_put_back(self):
        pulse = FakePulse(default_source="usb_in")
        self.assertTrue(Bridge(pulse)._reconcile_source())
        self.assertEqual(pulse.source, SPEAKER + ".monitor")

    def test_nothing_to_do_when_it_is_right(self):
        pulse = FakePulse(default_source=SPEAKER + ".monitor")
        self.assertFalse(Bridge(pulse)._reconcile_source())
        self.assertEqual(pulse.source_writes, [])

    def test_nothing_while_pulseaudio_is_down(self):
        pulse = FakePulse(up=False)
        self.assertFalse(Bridge(pulse)._reconcile_source())
        self.assertEqual(pulse.source_writes, [])

    def test_follows_the_default_sink_not_the_output_state(self):
        # _set_output has set the new default sink but not yet state["output"]:
        # the tap must go to the NEW output, never back to the old one
        pulse = FakePulse(default_sink=SPDIF, default_source=SPDIF + ".monitor")
        b = Bridge(pulse, output="speaker")
        self.assertFalse(b._reconcile_source())
        self.assertEqual(pulse.source_writes, [])


class TestWatchThread(unittest.TestCase):
    def test_subscribing_reconciles(self):
        # PulseAudio has just started and restored its saved default, usb_in
        pulse = FakePulse(default_source="usb_in")
        b = Bridge(pulse)
        run_one_subscribe(b)
        self.assertEqual(pulse.source, SPEAKER + ".monitor")
        self.assertEqual(b.volume_reconciles, 1)

    def test_a_server_event_reconciles(self):
        # USB audio starts: usb_in appears and takes the default
        pulse = FakePulse(default_source=SPEAKER + ".monitor")
        b = Bridge(pulse)

        def lines():
            pulse.source = "usb_in"
            yield "Event 'new' on source #4\n"
            yield "Event 'change' on server #4294967295\n"

        run_one_subscribe(b, lines())
        self.assertEqual(pulse.source, SPEAKER + ".monitor")
        self.assertEqual(pulse.source_writes, [SPEAKER + ".monitor"])


if __name__ == "__main__":
    unittest.main()
