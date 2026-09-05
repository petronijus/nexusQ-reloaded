import importlib.machinery
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestServicesForChanged(unittest.TestCase):
    """r29: a system update must restart the services whose binary changed —
    including nq-healthd (which ships inside device-google-steelhead, so its
    package name != its service name) and nexusq-mqtt (never restarted before).
    Regression guard for the 'app says up-to-date but old daemon keeps running
    until reboot' bug."""

    def setUp(self):
        self.mod = load_daemon()

    def test_device_pkg_restarts_nq_healthd(self):
        # THE regression: device-google-steelhead carries nq-healthd.
        svcs = self.mod._services_for_changed(["device-google-steelhead"])
        self.assertEqual(svcs, ["nq-healthd"])

    def test_mqtt_pkg_restarts_mqtt(self):
        self.assertEqual(self.mod._services_for_changed(["nexusq-mqtt"]),
                         ["nexusq-mqtt"])

    def test_self_named_daemons_still_map(self):
        for pkg in ("nexusqd", "nexusq-btagent", "nexusq-setupd", "nexusq-control"):
            self.assertEqual(self.mod._services_for_changed([pkg]), [pkg])

    def test_base_packages_map_to_nothing(self):
        # libc/init churn is handled by the reboot path, not a service restart.
        self.assertEqual(self.mod._services_for_changed(
            ["musl", "libcrypto3", "postmarketos-base"]), [])

    def test_dedup_and_order_preserved(self):
        changed = ["nexusqd", "device-google-steelhead", "nexusqd",
                   "nexusq-mqtt", "musl"]
        self.assertEqual(self.mod._services_for_changed(changed),
                         ["nexusqd", "nq-healthd", "nexusq-mqtt"])

    def test_empty(self):
        self.assertEqual(self.mod._services_for_changed([]), [])


class TestSystemctlPlan(unittest.TestCase):
    """r36: the systemctl calls after a system upgrade, in order. Measured
    2026-09-05 on the Prague unit: an in-place systemd 261 -> 262 upgrade left the
    running PID 1 unable to start any service (every restart exited 127 with no
    message; systemd-run reproduced it) until `systemctl daemon-reexec`. The
    restarts below ran in exactly that window. So when systemd itself changed the
    re-exec must come FIRST; otherwise a daemon-reload picks up replaced unit
    files. Pure function, so this pins the order without a systemd."""

    def setUp(self):
        self.mod = load_daemon()

    def test_systemd_changed_detection(self):
        f = self.mod._systemd_changed
        self.assertTrue(f(["musl", "systemd"]))
        self.assertTrue(f(["systemd-libs"]))
        self.assertTrue(f(["systemd-journald", "nexusqd"]))
        # names that merely CONTAIN systemd are not systemd
        self.assertFalse(f(["postmarketos-base-systemd", "nftables-systemd"]))
        self.assertFalse(f(["linux-pam-systemd"]))
        self.assertFalse(f([]))

    def test_reexec_comes_first_when_systemd_changed(self):
        plan = self.mod._systemctl_plan(["nexusqd", "nq-healthd"], True)
        self.assertEqual(plan, [
            ["systemctl", "daemon-reexec"],
            ["systemctl", "restart", "nexusqd"],
            ["systemctl", "restart", "nq-healthd"],
        ])

    def test_reexec_even_with_nothing_to_restart(self):
        # PID 1 must be usable for whatever comes next (the reboot call, the
        # bridge restart), so the re-exec is not conditional on our daemons.
        self.assertEqual(self.mod._systemctl_plan([], True),
                         [["systemctl", "daemon-reexec"]])

    def test_reload_not_reexec_when_only_units_changed(self):
        plan = self.mod._systemctl_plan(["nexusq-mqtt"], False)
        self.assertEqual(plan, [
            ["systemctl", "daemon-reload"],
            ["systemctl", "restart", "nexusq-mqtt"],
        ])

    def test_nothing_changed_nothing_to_do(self):
        self.assertEqual(self.mod._systemctl_plan([], False), [])

    def test_restart_order_is_fixed_and_control_is_never_in_it(self):
        daemons = ["nexusq-control", "nq-healthd", "nexusq-mqtt", "nexusqd",
                   "nexusq-setupd", "nexusq-btagent"]
        plan = self.mod._systemctl_plan(daemons, False)
        self.assertEqual([a[2] for a in plan if a[1] == "restart"],
                         ["nexusqd", "nexusq-btagent", "nexusq-setupd",
                          "nexusq-mqtt", "nq-healthd"])
        self.assertNotIn(["systemctl", "restart", "nexusq-control"], plan)


if __name__ == "__main__":
    unittest.main()
