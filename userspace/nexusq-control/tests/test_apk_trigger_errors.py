"""nexusq-control r66-r68: a committed apk transaction whose trigger failed is not a
failed update.

postmarketos-mkinitfs 2.12.0-r1 (2026-10-12) moved its binary to /usr/bin but
its trigger still runs /usr/sbin/mkinitfs, so every `apk upgrade` on the units
exited 1 with "1 error". The packages were installed; the app reported the
update as failed and skipped the daemon restarts, leaving the old daemons
running. A transaction that really failed must still be reported as one.
"""

import importlib.machinery
import importlib.util
import os
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON)
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run(rc, stderr, stdout=""):
    return subprocess.CompletedProcess(["apk"], rc, stdout=stdout, stderr=stderr)


# Verbatim from the Prague Q, 2026-10-13 (`apk add nexusq-sgx-...-r1.apk`).
TRIGGER_ONLY = """(1/1) Upgrading nexusq-sgx (1.17.4948957-r0 -> 1.17.4948957-r1)
Executing busybox-1.38.0-r7.trigger
Executing systemd-262-r4.trigger
Executing postmarketos-mkinitfs-2.12.0-r1.trigger
* /proc/self/fd/7: line 20: /usr/sbin/mkinitfs: not found
ERROR: lib/apk/exec/postmarketos-mkinitfs-2.12.0-r1.trigger: exited with error 127
Executing postmarketos-base-systemd-92-r0.trigger
1 error; 2141.5 MiB in 993 packages
"""

REAL_FAILURE = """ERROR: unable to select packages:
  nexusq-control-1.0-r99:
    breaks: world[nexusq-control<50]
"""


# Verbatim from the Prague Q's /var/log/apk.log, 2026-10-14: apk remembers the
# failed mkinitfs trigger, so a transaction that runs no trigger at all still
# ends "1 error" and exits 1 (r67 called this a failed update) ...
REMEMBERED_ONLY = """(1/1) Upgrading nexusq-control (0.1.0-r66 -> 0.1.0-r67)
Executing busybox-1.38.0-r7.trigger
Executing systemd-262-r4.trigger
Executing postmarketos-base-systemd-92-r0.trigger
* No new system units to preset
* No new user units to preset
1 error; 2141.5 MiB in 993 packages
"""

# ... and one that runs it again counts it twice.
KERNEL_UPGRADE = """(1/1) Upgrading linux-google-steelhead (6.18.48-r30 -> 6.18.48-r31)
Executing busybox-1.38.0-r7.trigger
Executing kmod-34.2-r1.trigger
Executing postmarketos-mkinitfs-2.12.0-r1.trigger
* /proc/self/fd/7: line 20: /usr/sbin/mkinitfs: not found
ERROR: lib/apk/exec/postmarketos-mkinitfs-2.12.0-r1.trigger: exited with error 127
2 errors; 2141.5 MiB in 993 packages
"""

# `apk fix --simulate` on that unit: the package apk keeps flagged.
FIX_MKINITFS = """(1/1) Reinstalling postmarketos-mkinitfs (2.12.0-r1)
1 error; 2141.6 MiB in 993 packages
"""


class ApkFailed(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()
        self.flagged = []
        self.mod._apk_flagged = lambda: self.flagged

    def test_success_is_not_a_failure(self):
        self.assertIsNone(self.mod._apk_failed(run(0, "OK: 2141.5 MiB in 993 packages\n")))

    def test_trigger_only_error_is_not_a_failure(self):
        r = run(1, TRIGGER_ONLY)
        self.assertIsNone(self.mod._apk_failed(r))
        self.assertEqual(self.mod._apk_trigger_errors(r), ["postmarketos-mkinitfs-2.12.0-r1"])
        self.assertEqual(self.mod._apk_changed(r), ["nexusq-sgx"])

    def test_unsatisfiable_upgrade_is_a_failure(self):
        why = self.mod._apk_failed(run(1, REAL_FAILURE))
        self.assertIn("unable to select packages", why)

    def test_trigger_error_next_to_a_real_one_is_a_failure(self):
        why = self.mod._apk_failed(run(2, TRIGGER_ONLY + "ERROR: nexusqd-1.0-r30: BAD signature\n"))
        self.assertIn("BAD signature", why)

    def test_our_own_trigger_failing_is_a_failure(self):
        # device-google-steelhead's trigger pins the amplifier's Speaker gain at
        # unity: if it fails, the update must not be reported as done.
        own = TRIGGER_ONLY.replace(
            "ERROR: lib/apk/exec/postmarketos-mkinitfs-2.12.0-r1.trigger",
            "ERROR: lib/apk/exec/device-google-steelhead-1.0-r130.trigger",
        )
        why = self.mod._apk_failed(run(1, own))
        self.assertIn("device-google-steelhead", why)

    def test_nonzero_exit_without_an_error_line_is_a_failure(self):
        self.assertTrue(self.mod._apk_failed(run(1, "fetch failed\n")))

    def test_remembered_inert_trigger_error_is_not_a_failure(self):
        self.flagged = ["postmarketos-mkinitfs"]
        self.assertIsNone(self.mod._apk_failed(run(1, REMEMBERED_ONLY)))
        self.assertIsNone(self.mod._apk_failed(run(1, KERNEL_UPGRADE)))

    def test_an_error_nothing_accounts_for_is_a_failure(self):
        # "1 error" with no ERROR line and nothing flagged: something else failed.
        self.assertIn("1 error(s)", self.mod._apk_failed(run(1, REMEMBERED_ONLY)))
        # One more error than the inert trigger line and the flag explain.
        self.flagged = ["postmarketos-mkinitfs"]
        self.assertTrue(self.mod._apk_failed(run(1, KERNEL_UPGRADE.replace("2 errors", "3 errors"))))

    def test_another_flagged_package_is_a_failure(self):
        self.flagged = ["postmarketos-mkinitfs", "device-google-steelhead"]
        self.assertIn("device-google-steelhead", self.mod._apk_failed(run(1, REMEMBERED_ONLY)))

    def test_apk_fix_unavailable_is_a_failure(self):
        self.flagged = None
        self.assertTrue(self.mod._apk_failed(run(1, REMEMBERED_ONLY)))

    def test_flagged_packages_come_from_apk_fix(self):
        mod = load_daemon()
        mod._apk = lambda *a, timeout=90: run(1, FIX_MKINITFS) if a[:2] == ("fix", "--simulate") else None
        self.assertEqual(mod._apk_flagged(), ["postmarketos-mkinitfs"])


class InstallPathsUseIt(unittest.TestCase):
    """Both OTA tracks go through _apk_failed, so a trigger-only error reaches the
    restart tail and is reported in triggerErrors."""

    def setUp(self):
        self.mod = load_daemon()
        self.mod._ensure_ota_repo = lambda: None
        self.mod._apk_flagged = lambda: []

    def fake_apk(self, upgrade_result):
        def _apk(*args, timeout=90):
            return upgrade_result if args[0] == "upgrade" else run(0, "")

        return _apk

    def test_system_update_restarts_after_a_trigger_error(self):
        self.mod._apk = self.fake_apk(run(1, TRIGGER_ONLY.replace("nexusq-sgx", "device-google-steelhead")))
        res = self.mod.install_system_update()
        self.assertTrue(res["ok"])
        self.assertEqual(res["daemons"], ["nq-healthd"])
        self.assertEqual(res["triggerErrors"], ["postmarketos-mkinitfs-2.12.0-r1"])

    def test_nexus_update_reports_a_real_failure(self):
        self.mod._apk = self.fake_apk(run(1, REAL_FAILURE))
        with self.assertRaises(self.mod.Err):
            self.mod.install_nexus_update()


if __name__ == "__main__":
    unittest.main()
