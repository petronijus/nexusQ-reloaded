"""Tests for the nexusq-setup-needed ExecCondition.

exit 0 = "run setup mode". Setup mode makes the adapter discoverable AND
pairable, and the agent auto-accepts (nothing on this appliance can answer a
prompt) — so a false "setup needed" hands a stranger a bond. These tests pin the
fail-CLOSED behaviour.
"""
import os
import subprocess
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "nexusq-setup-needed")


def run_with_fake_nmcli(body):
    """Run the script with a fake `nmcli` first on PATH.

    The force-flag branch (/run/nexusq-setup.force) is not covered here: it is an
    absolute path we must not create on the build host. It is exercised live —
    that flag is how the bridge's startSetupMode re-arms a provisioned device.
    """
    with tempfile.TemporaryDirectory() as bindir:
        fake = os.path.join(bindir, "nmcli")
        with open(fake, "w") as f:
            f.write("#!/bin/sh\n" + textwrap.dedent(body))
        os.chmod(fake, 0o755)
        env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"])
        return subprocess.run(["/bin/sh", SCRIPT], env=env,
                              capture_output=True, text=True)


class TestSetupNeeded(unittest.TestCase):
    def test_wifi_profile_present_means_no_setup(self):
        r = run_with_fake_nmcli('echo "802-11-wireless"\necho "802-3-ethernet"\nexit 0\n')
        self.assertEqual(r.returncode, 1, "provisioned device must not enter setup")

    def test_no_wifi_profile_means_setup(self):
        r = run_with_fake_nmcli('echo "802-3-ethernet"\nexit 0\n')
        self.assertEqual(r.returncode, 0, "unprovisioned device must enter setup")

    def test_empty_list_means_setup(self):
        r = run_with_fake_nmcli('exit 0\n')
        self.assertEqual(r.returncode, 0)

    def test_nmcli_failure_fails_CLOSED(self):
        # REGRESSION (diag 2026-07-15): the old version piped nmcli into grep and
        # discarded its exit code, so a transient NetworkManager wobble read as
        # "no wifi profile" -> a PROVISIONED device went discoverable+pairable.
        r = run_with_fake_nmcli('echo "Error: NetworkManager is not running." >&2\nexit 8\n')
        self.assertEqual(r.returncode, 1,
                         "nmcli failure must assume provisioned, never open a pairing window")

    def test_nmcli_missing_fails_CLOSED(self):
        with tempfile.TemporaryDirectory() as bindir:
            env = dict(os.environ, PATH=bindir)  # no nmcli at all
            r = subprocess.run(["/bin/sh", SCRIPT], env=env,
                               capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)


if __name__ == "__main__":
    unittest.main()
