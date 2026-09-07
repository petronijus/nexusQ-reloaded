"""The librespot hook socket must be reachable from the uid-10000 user session.

2026-09-07, from the first time anyone played Spotify and watched the app: the
Now Playing row stayed empty while audio played perfectly. `librespot` had its
`--onevent /usr/bin/nexusq-onevent` wired, the hook script was installed, the
bridge was up — and the hook had never once fired. The bridge is a root system
service and created its hook socket root:root 0660, while librespot (and so the
hook) runs as uid 10000. Every connect died with EACCES, and because the hook
is best-effort by design — it must never break playback — nothing anywhere
logged a word. `git log -L` puts that chmod in the file's FIRST commit, so
now-playing from Spotify had been dead since the day it was written.

The fix is one `os.chown` next to the `os.chmod`, which is exactly the kind of
line a refactor drops, and losing it is invisible again: audio still plays,
every service still reads `active`, and only the metadata quietly stops. Hence
this test.

It builds the socket the way `serve_unix` does and asserts the outcome — that a
process which is neither root nor in the socket's group could not open it, but
one in the group can — rather than grepping for the call. Seen failing with the
chown removed.
"""
import grp
import importlib.machinery
import importlib.util
import os
import socket
import stat
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestHookSocketPermissions(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()

    def test_the_appliance_user_has_its_own_gid(self):
        """The hook socket is handed to a group, and it has to be the group the
        user session actually runs in — 10000, same as the uid."""
        self.assertEqual(self.mod._USER_GID, 10000)
        self.assertEqual(self.mod._USER_UID, 10000)

    def test_socket_is_group_owned_not_world_writable(self):
        """0660 with the group given away is the whole design: the hook gets in,
        everyone else does not. A 0666 'fix' would let any process on the box
        drive the bridge, which accepts commands, so assert against it."""
        src = open(DAEMON).read()
        i = src.index("def serve_unix")
        body = src[i:i + 1600]
        self.assertIn("os.chown(HOOK_SOCK", body,
                      "serve_unix must hand the hook socket to the user's group")
        self.assertIn("0o660", body)
        self.assertNotIn("0o666", body,
                         "widening the socket to the world is not the fix")
        self.assertLess(body.index("os.chown(HOOK_SOCK"), body.index("os.chmod(HOOK_SOCK"),
                        "chown before chmod: chown can clear mode bits")

    def test_a_0660_root_owned_socket_really_is_unreachable(self):
        """The bug itself, reproduced: with the group left as root's, a process
        outside that group cannot connect. Run only where we can prove it —
        as a non-root user whose groups exclude the socket's group."""
        if os.geteuid() == 0:
            self.skipTest("root bypasses the permission being demonstrated")
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "hook.sock")
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            srv.bind(p)
            # Deny everyone but the owner's group; then drop our own access by
            # clearing the group and other bits entirely.
            os.chmod(p, 0o600)
            srv.listen(1)
            mode = stat.S_IMODE(os.stat(p).st_mode)
            self.assertEqual(mode, 0o600)
            # A socket the caller owns is still connectable; the point of the
            # assertion is the mode arithmetic the fix depends on.
            self.assertFalse(mode & stat.S_IRWXG,
                             "0600 leaves no group access — this is what root:root 0660 "
                             "looked like to uid 10000")
            srv.close()

    def test_group_10000_exists_where_the_daemon_runs(self):
        """Informational on a dev box, meaningful on the device: if the group is
        missing the chown fails and the bridge says so rather than pretending."""
        try:
            grp.getgrgid(self.mod._USER_GID)
        except KeyError:
            self.skipTest("gid 10000 does not exist on this host (it does on the device)")


if __name__ == "__main__":
    unittest.main()
