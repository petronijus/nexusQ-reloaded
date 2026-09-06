"""nq-uac2-silence, producer mode: the guard must act on what PulseAudio really
holds open, not on its own memory of the last command it sent.

Background (2026-09-06): the Prague Q ran its amplifier for 4.75 days with
nothing playing. A live module reload had resumed `roon_in` behind the guard's
back on Sep 1; the guard was asleep on paper, the source was RUNNING in fact,
and nothing in the loop ever compared the two. These tests drive the loop with a
fake clock, a fake PulseAudio that honours `suspend`, and /proc files in a temp
dir, so a whole day of polling runs in milliseconds and nothing real is touched.
"""

import importlib.machinery
import importlib.util
import os
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "nq-uac2-silence")

OPEN = "state: RUNNING\nowner_pid   : 42\n"
CLOSED = "closed\n"


def load(env):
    """Import the script fresh under `env`; MODE/paths are read at import."""
    with mock.patch.dict(os.environ, env, clear=False):
        spec = importlib.util.spec_from_loader(
            "nq_uac2_silence",
            importlib.machinery.SourceFileLoader("nq_uac2_silence", SCRIPT))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    return mod


class FakeClock:
    """Deterministic time: sleep() advances monotonic() and runs a per-poll hook
    that plays the outside world (Roon opening its PCM, someone resuming the
    source by hand) and stops the loop when the script is over."""

    def __init__(self, on_poll):
        self.now = 1000.0
        self.polls = 0
        self.on_poll = on_poll

    def monotonic(self):
        return self.now

    def sleep(self, s):
        self.now += s
        self.polls += 1
        self.on_poll(self.polls)


class ProducerLoop(unittest.TestCase):
    POLL = 0.2
    SLEEP_AFTER = 10
    CONFIRM = 5

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.producer = os.path.join(self.tmp.name, "pcm0p-status")
        self.consumer = os.path.join(self.tmp.name, "pcm1c-status")
        self.write(self.producer, CLOSED)
        self.write(self.consumer, OPEN)          # PA starts with the source live
        self.mod = load({
            "NQ_WATCH_MODE": "producer",
            "NQ_PRODUCER_PCM": self.producer,
            "NQ_CONSUMER_PCM": self.consumer,
            "NQ_UAC2_SOURCE": "roon_in",
            "NQ_PRODUCER_POLL": str(self.POLL),
            "NQ_UAC2_SLEEP_AFTER": str(self.SLEEP_AFTER),
            "NQ_CONSUMER_CONFIRM": str(self.CONFIRM),
        })
        self.suspends = []                       # every (on) the guard asked for
        self.logs = []
        mock.patch.object(self.mod, "suspend", side_effect=self.fake_suspend).start()
        mock.patch.object(self.mod, "log", side_effect=self.logs.append).start()
        self.addCleanup(mock.patch.stopall)
        self.addCleanup(self.tmp.cleanup)

    def write(self, path, text):
        with open(path, "w") as f:
            f.write(text)

    def fake_suspend(self, on):
        """A PulseAudio that does what it is told: suspend closes the capture
        PCM, resume reopens it."""
        self.suspends.append(on)
        self.write(self.consumer, CLOSED if on else OPEN)
        return True

    def run_loop(self, script):
        """`script` maps poll number -> callable(watcher); the loop stops one
        poll after the highest key."""
        w = self.mod.Watcher()
        last = max(script)

        def on_poll(n):
            if n in script:
                script[n](w)
            if n > last:
                w.stop = True

        clock = FakeClock(on_poll)
        with mock.patch.object(self.mod, "time", clock):
            w.run_producer()
        return w

    def polls(self, seconds):
        return int(seconds / self.POLL)

    # -- the behaviour that already worked -------------------------------------
    def test_idle_producer_is_suspended_after_sleep_after(self):
        w = self.run_loop({self.polls(self.SLEEP_AFTER) + 2: lambda w: None})
        self.assertEqual(self.suspends, [True])
        self.assertTrue(w.asleep)

    def test_producer_opening_resumes(self):
        asleep = self.polls(self.SLEEP_AFTER) + 2
        w = self.run_loop({
            asleep: lambda w: self.write(self.producer, OPEN),
            asleep + 3: lambda w: None,
        })
        self.assertEqual(self.suspends, [True, False])
        self.assertFalse(w.asleep)

    # -- the hole: resumed behind our back --------------------------------------
    def test_external_resume_while_asleep_is_re_suspended(self):
        asleep = self.polls(self.SLEEP_AFTER) + 2
        # someone else (module reload, `pactl suspend-source roon_in 0`) reopens
        # the capture side; the producer stays closed
        w = self.run_loop({
            asleep: lambda w: self.write(self.consumer, OPEN),
            asleep + self.CONFIRM + 2: lambda w: None,
        })
        self.assertEqual(self.suspends, [True, True],
                         "the guard never noticed the source running behind its back")
        self.assertTrue(w.asleep)
        self.assertTrue(any("behind our back" in m for m in self.logs), self.logs)

    def test_external_resume_shorter_than_confirm_is_ignored(self):
        # PA's own suspend is asynchronous: the capture side may read open for a
        # moment after `suspend 1`. A blip shorter than CONFIRM must not fire.
        asleep = self.polls(self.SLEEP_AFTER) + 2
        self.run_loop({
            asleep: lambda w: self.write(self.consumer, OPEN),
            asleep + self.CONFIRM - 2: lambda w: self.write(self.consumer, CLOSED),
            asleep + self.CONFIRM + 4: lambda w: None,
        })
        self.assertEqual(self.suspends, [True])

    def test_external_resume_then_producer_opens_wakes_normally(self):
        # the re-suspend must not eat a real wake that follows it
        asleep = self.polls(self.SLEEP_AFTER) + 2
        w = self.run_loop({
            asleep: lambda w: self.write(self.consumer, OPEN),
            asleep + self.CONFIRM + 2: lambda w: self.write(self.producer, OPEN),
            asleep + self.CONFIRM + 5: lambda w: None,
        })
        self.assertEqual(self.suspends, [True, True, False])
        self.assertFalse(w.asleep)

    # -- the mirror hole: our resume did not take ---------------------------------
    def test_resume_that_did_not_take_is_repeated(self):
        asleep = self.polls(self.SLEEP_AFTER) + 2

        def open_producer_but_pa_ignores_us(w):
            self.write(self.producer, OPEN)
            # the next suspend(False) will be swallowed: PA keeps it closed
            self.mod.suspend.side_effect = self.swallow_once_then_obey

        w = self.run_loop({
            asleep: open_producer_but_pa_ignores_us,
            asleep + 1 + self.CONFIRM + 2: lambda w: None,
        })
        self.assertEqual(self.suspends, [True, False, False])
        self.assertEqual(open(self.consumer).read(), OPEN)
        self.assertTrue(any("resumed again" in m for m in self.logs), self.logs)

    def swallow_once_then_obey(self, on):
        self.suspends.append(on)
        self.mod.suspend.side_effect = self.fake_suspend
        return True                              # CLI send "succeeded", PA did nothing

    # -- unknown state is not a state ------------------------------------------
    def test_missing_consumer_file_disables_reconciliation(self):
        asleep = self.polls(self.SLEEP_AFTER) + 2
        self.run_loop({
            asleep: lambda w: os.unlink(self.consumer),
            asleep + self.CONFIRM + 4: lambda w: None,
        })
        self.assertEqual(self.suspends, [True])


class OtherEnd(unittest.TestCase):
    """snd-aloop pairs device 0 with device 1 of the same card."""

    def setUp(self):
        self.mod = load({"NQ_WATCH_MODE": "producer",
                         "NQ_PRODUCER_PCM": "/proc/asound/RoonLoop/pcm0p/sub0/status"})

    def test_pcm0p_pairs_with_pcm1c(self):
        self.assertEqual(self.mod.other_end("/proc/asound/RoonLoop/pcm0p/sub0/status"),
                         "/proc/asound/RoonLoop/pcm1c/sub0/status")

    def test_pcm1p_pairs_with_pcm0c(self):
        self.assertEqual(self.mod.other_end("/proc/asound/Loopback/pcm1p/sub3/status"),
                         "/proc/asound/Loopback/pcm0c/sub3/status")

    def test_default_consumer_is_derived(self):
        self.assertEqual(self.mod.CONSUMER_PCM, "/proc/asound/RoonLoop/pcm1c/sub0/status")

    def test_path_without_an_aloop_device_derives_nothing(self):
        # aloop has devices 0 and 1 only; anything else is not a cable end
        self.assertEqual(self.mod.other_end("/proc/asound/card2/pcm2p/sub0/status"), "")
        self.assertEqual(self.mod.other_end("/dev/snd/pcmC7D0p"), "")
        self.assertEqual(self.mod.other_end(""), "")


if __name__ == "__main__":
    unittest.main()
