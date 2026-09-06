"""_systemctl_user must reach the uid-10000 manager without opening a session.

`--machine=user@.host` works, and it was the only form anyone had found: the
comment beside it records, correctly, that root cannot connect to the local user
bus. What it missed is that root does not have to connect AS root — it can drop
to uid 10000 first, and then the plain `--user` transport is available.

The difference is not cosmetic. Each `--machine` call opens a PAM session and a
transient unit, and on systemd 262 every unit start on this image emits five
lines of coredumpd/pids.max noise (the manager's ExecCondition fails because
6.18 does not report PIDFD_INFO_COREDUMP_SIGNAL, and CONFIG_CGROUP_PIDS is off).
Measured on the device, three calls: 34 journal lines through --machine, 0
through setpriv, with identical answers from is-active, show -p, list-units and
CanStart.
"""

import importlib.machinery
import importlib.util
import os
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control",
        importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestUserSystemctlTransport(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()
        self.runs = []
        p = mock.patch.object(
            self.mod.subprocess, "run",
            side_effect=lambda cmd, **kw: self.runs.append((cmd, kw))
            or mock.Mock(returncode=0, stdout="active\n", stderr=""))
        p.start()
        self.addCleanup(mock.patch.stopall)

    def argv(self):
        self.assertEqual(len(self.runs), 1, "expected exactly one subprocess")
        return self.runs[0][0]

    def test_drops_to_the_appliance_user_instead_of_opening_a_session(self):
        self.mod._systemctl_user("is-active", "roon.service")
        argv = self.argv()
        self.assertEqual(argv[0], "setpriv")
        self.assertIn("--reuid=10000", argv)
        self.assertIn("--regid=10000", argv)
        # --clear-groups would drop `audio` too; the bridge starts units that
        # need it (librespot, roon), so supplementary groups are set from the
        # user's own, not thrown away.
        self.assertNotIn("--clear-groups", argv)

    def test_no_machine_transport_anywhere(self):
        self.mod._systemctl_user("is-active", "roon.service")
        joined = " ".join(self.argv())
        self.assertNotIn("--machine", joined,
                         "the PAM session per call is the whole point of this change")

    def test_user_manager_env_is_passed(self):
        self.mod._systemctl_user("is-active", "roon.service")
        argv = self.argv()
        self.assertIn("XDG_RUNTIME_DIR=/run/user/10000", argv)
        self.assertIn("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/10000/bus", argv)

    def test_the_actual_systemctl_command_is_unchanged(self):
        self.mod._systemctl_user("enable", "--now", "roon.service")
        argv = self.argv()
        tail = argv[argv.index("systemctl"):]
        self.assertEqual(tail, ["systemctl", "--user", "enable", "--now",
                                "roon.service"])

    def test_timeout_is_still_honoured(self):
        self.mod._systemctl_user("mask", "--now", "roon.service", timeout=30)
        self.assertEqual(self.runs[0][1]["timeout"], 30)
        self.assertTrue(self.runs[0][1]["capture_output"])
        self.assertTrue(self.runs[0][1]["text"])


if __name__ == "__main__":
    unittest.main()
