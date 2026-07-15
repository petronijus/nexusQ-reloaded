"""Unit tests for nexusq-btagent's pure logic.

The D-Bus plumbing needs a live BlueZ and is covered by on-device acceptance;
what is tested here is the part that is easy to get subtly wrong — the LED
ownership rules and the fail-open behaviour of the setupd check.
"""
import importlib.machinery
import importlib.util
import os
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-btagent")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_btagent", importlib.machinery.SourceFileLoader("nexusq_btagent", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestLedPlan(unittest.TestCase):
    """The ring keys off PAIRABLE — the only property that gates pairing.

    It used to key off Discoverable (with Pairable mirrored onto it). That was
    the wrong property and it silently broke outbound bonding: Pairable off at
    rest means no SMP bonding bit (HCI_BONDABLE), so the kernel marks the key
    non-persistent and bluez discards it — "successful" pairings that vanish on
    restart. Measured on a real MX Master 4, 2026-07-15.
    """

    def setUp(self):
        self.mod = load_daemon()

    def test_takes_ring_when_pairable_outside_setup(self):
        cmd, owns = self.mod.led_plan(pairable=True, owns_led=False,
                                      setup_running=False)
        self.assertEqual(cmd, self.mod.DISCOVERABLE_CMD)
        self.assertTrue(owns)

    def test_does_not_take_ring_while_setupd_owns_it(self):
        # setupd already spins its own blue and, on success, leaves the chosen
        # theme up — stomping on that is the bug this guard exists to prevent.
        cmd, owns = self.mod.led_plan(pairable=True, owns_led=False,
                                      setup_running=True)
        self.assertIsNone(cmd)
        self.assertFalse(owns)

    def test_releases_ring_when_no_longer_pairable(self):
        cmd, owns = self.mod.led_plan(pairable=False, owns_led=True,
                                      setup_running=False)
        self.assertEqual(cmd, self.mod.RELEASE_CMD)
        self.assertFalse(owns)

    def test_never_releases_a_ring_it_does_not_own(self):
        # The setup-success path: setupd applied a theme and exited, then turned
        # Discoverable off. We must not send "auto" and wipe that theme.
        cmd, owns = self.mod.led_plan(pairable=False, owns_led=False,
                                      setup_running=False)
        self.assertIsNone(cmd)
        self.assertFalse(owns)

    def test_idempotent_while_already_showing(self):
        cmd, owns = self.mod.led_plan(pairable=True, owns_led=True,
                                      setup_running=False)
        self.assertIsNone(cmd)
        self.assertTrue(owns)

    def test_yields_ownership_silently_when_setupd_starts(self):
        # REGRESSION (live 2026-07-15): we grabbed the ring in the gap while
        # setupd was still "activating" (it flips the adapter discoverable before
        # systemd reports it active). Holding ownership through setup meant that
        # when setup finished — applying a theme and turning discovery off — we
        # would then "release" and send "auto", wiping that theme.
        # Yield to setupd, and yield SILENTLY: no command, no ownership.
        cmd, owns = self.mod.led_plan(pairable=True, owns_led=True,
                                      setup_running=True)
        self.assertIsNone(cmd)
        self.assertFalse(owns)

    def test_setup_end_does_not_wipe_the_applied_theme(self):
        # The tail of that same scenario: setup finished, left its theme up, and
        # turned discovery off. Having yielded, we own nothing -> send nothing.
        cmd, owns = self.mod.led_plan(pairable=False, owns_led=False,
                                      setup_running=False)
        self.assertIsNone(cmd)
        self.assertFalse(owns)


class TestSetupdActive(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()

    @staticmethod
    def _systemctl_says(state, rc=0):
        return lambda *a, **k: subprocess.CompletedProcess(a, rc, stdout=state + "\n")

    def test_active(self):
        self.assertTrue(self.mod.setupd_active(run=self._systemctl_says("active")))

    def test_inactive(self):
        self.assertFalse(self.mod.setupd_active(
            run=self._systemctl_says("inactive", rc=3)))

    def test_activating_counts_as_active(self):
        # REGRESSION (live 2026-07-15): setupd makes the adapter discoverable
        # while still "activating" (systemctl exits NON-ZERO for that state), so
        # treating only "active" as active let us steal the ring from it.
        self.assertTrue(self.mod.setupd_active(
            run=self._systemctl_says("activating", rc=3)))

    def test_failed_is_not_active(self):
        self.assertFalse(self.mod.setupd_active(
            run=self._systemctl_says("failed", rc=3)))

    def test_unreadable_systemctl_means_the_ring_is_ours(self):
        # The ring is a SAFETY indicator: "dark == nobody can pair" must never
        # be a lie. If we cannot tell whether setupd is running, claim the ring
        # (worst case: we re-send the same blue setupd already shows). Skipping
        # it on a pairable adapter would be the lie this daemon prevents.
        def boom(*a, **k):
            raise OSError("no systemctl")
        self.assertFalse(self.mod.setupd_active(run=boom))

    def test_systemctl_timeout_means_the_ring_is_ours(self):
        # Observed live 2026-07-15: "systemctl is-active failed ... timed out
        # after 5 seconds" under load.
        def slow(*a, **k):
            raise subprocess.TimeoutExpired("systemctl", 5)
        self.assertFalse(self.mod.setupd_active(run=slow))


class TestLedSend(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()

    def test_missing_socket_is_not_fatal(self):
        # nexusqd being down must never take the BT agent with it.
        self.assertFalse(self.mod.led_send("spin 0 0 0",
                                           sock_path="/nonexistent/nexusqd.sock"))


class TestConstants(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()

    def test_capability_is_no_input_no_output(self):
        # The whole root cause: anything else (notably blueman's DisplayYesNo)
        # forces SSP into a model needing a prompt no attached device can answer.
        self.assertEqual(self.mod.AGENT_CAPABILITY, "NoInputNoOutput")

    def test_window_timeout_is_stock_parity(self):
        # 120 s = stock steelhead's own DiscoverableTimeout. Enforced by bluez's
        # timer, not ours, so a killed daemon cannot leave the Q pairable.
        self.assertEqual(self.mod.WINDOW_TIMEOUT, 120)

    def test_discoverable_cmd_matches_setupd_idle_spin(self):
        # "Open for pairing" must look the same whoever is driving the ring.
        self.assertEqual(self.mod.DISCOVERABLE_CMD, "spin 0 153 204")


class TestPairableIsTheGate(unittest.TestCase):
    """Regression guards for the rule that replaced `Pairable == Discoverable`.

    The old mirror held Pairable off at rest, which made every OUTBOUND bond
    temporary — no keys on disk, gone after a bluetoothd restart, so a mouse or
    keyboard would need re-pairing every boot. Measured chain (see the daemon
    header): Pairable -> HCI_BONDABLE -> SMP bonding bit -> kernel store_hint ->
    bluez persists the key.
    """

    def setUp(self):
        self.mod = load_daemon()

    def test_ring_follows_pairable_even_when_not_discoverable(self):
        # The exact case the old rule got wrong. An outbound pair needs Pairable
        # WITHOUT announcing us to the room — someone CAN pair us, so the ring
        # must be on, and nothing may force Pairable back off under whoever
        # opened the window.
        cmd, owns = self.mod.led_plan(pairable=True, owns_led=False,
                                      setup_running=False)
        self.assertEqual(cmd, self.mod.DISCOVERABLE_CMD)
        self.assertTrue(owns)

    def test_ring_dark_means_nobody_can_pair(self):
        # The one safety property this daemon exists for.
        cmd, owns = self.mod.led_plan(pairable=False, owns_led=True,
                                      setup_running=False)
        self.assertEqual(cmd, self.mod.RELEASE_CMD)
        self.assertFalse(owns)


if __name__ == "__main__":
    unittest.main()
