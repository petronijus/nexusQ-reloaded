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


if __name__ == "__main__":
    unittest.main()
