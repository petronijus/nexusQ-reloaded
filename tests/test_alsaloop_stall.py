"""The alsa-utils override's alsaloop, against a capture that stalls without
stopping (pmos/alsa-utils/0002) and then comes back (0003): no busy loop, no
playback re-prepare loop, one underrun recovery back to the target latency.

When the USB host stops sending, the UAC2 gadget's capture stays RUNNING
with its hardware pointer frozen. Unpatched alsaloop then polls the aloop
playback fd, which is ready (POLLOUT, then POLLERR in XRUN), finds nothing
to copy, and polls again at once: a full core under SCHED_FIFO until the
nexusq-uac2-in supervisor parks it (2026-11-01, `sched: RT throttling
activated`). When the host resumed, the underrun recovery refilled the
playback short of its latency and leaked the shared buffer's capture count,
so it underran every period until the buffer looked full and the loop
busy-polled the capture instead.

The test applies every pmos/alsa-utils patch that touches alsaloop/, in
APKBUILD order, to the unmodified upstream files in
tests/fixtures/alsa-utils-<pkgver>/ -- so what is tested is what ships, and a
patch that stops applying fails here -- then builds the patched pcmjob.c
with tests/alsaloop_stall_test.c, which simulates the two PCMs and poll() on
a simulated clock (tests/fake-alsa stands in for alsa-lib's header).
"""

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUSRC = ROOT / "pmos" / "alsa-utils"


def apkbuild_var(name: str) -> str:
    m = re.search(rf'^{name}="?([^"\n]*)"?\n', (AUSRC / "APKBUILD").read_text(), re.M)
    if not m:
        raise LookupError(f"no {name}= in pmos/alsa-utils/APKBUILD")
    return m.group(1)


def alsaloop_patches() -> list:
    """The patches in source= order that touch alsaloop/."""
    source = re.search(r'^source="(.*?)"', (AUSRC / "APKBUILD").read_text(), re.M | re.S).group(1).split()
    out = []
    for name in source:
        path = AUSRC / name
        if name.endswith(".patch") and re.search(r"^diff --git a/alsaloop/", path.read_text(), re.M):
            out.append(path)
    return out


class Stall(unittest.TestCase):
    def test_fixture_matches_the_packaged_version(self):
        fixture = ROOT / "tests" / "fixtures" / f"alsa-utils-{apkbuild_var('pkgver')}"
        self.assertTrue(
            (fixture / "alsaloop" / "pcmjob.c").is_file(),
            f"{fixture.relative_to(ROOT)} is missing: re-vendor alsaloop/ from the new tarball with the aport",
        )

    def test_the_stall_patches_are_packaged(self):
        names = [p.name for p in alsaloop_patches()]
        self.assertIn("0002-alsaloop-do-not-busy-poll-playback-while-capture-is-stalled.patch", names)
        self.assertIn("0003-alsaloop-refill-an-underrun-playback-to-the-target-latency.patch", names)

    def test_patched_poll_loop_sleeps_through_a_stalled_capture(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc, "a C compiler is needed (just doctor)")
        self.assertIsNotNone(shutil.which("patch"), "patch(1) is needed")
        fixture = ROOT / "tests" / "fixtures" / f"alsa-utils-{apkbuild_var('pkgver')}"
        with tempfile.TemporaryDirectory() as d:
            src = Path(d, "src")
            shutil.copytree(fixture, src)
            for p in alsaloop_patches():
                applied = subprocess.run(
                    ["patch", "-p1", "-s", "-N", "-i", str(p)], cwd=src, capture_output=True, text=True
                )
                self.assertEqual(applied.returncode, 0, f"{p.name} does not apply:\n{applied.stdout}{applied.stderr}")
            Path(d, "aconfig.h").write_text("#define ATTRIBUTE_UNUSED __attribute__((unused))\n")
            inc = ["-I", str(ROOT / "tests" / "fake-alsa"), "-I", d, "-I", str(src / "include")]
            inc += ["-I", str(src / "alsaloop")]
            exe = Path(d, "alsaloop_stall_test")
            obj = Path(d, "pcmjob.o")
            steps = [
                # upstream code: built as-is, its own warnings are not ours to fail on
                [cc, "-std=gnu11", "-O1", "-c", "-o", str(obj), *inc, str(src / "alsaloop" / "pcmjob.c")],
                [
                    cc,
                    "-std=gnu11",
                    "-O1",
                    "-Wall",
                    "-Wextra",
                    "-Wno-unused-parameter",
                    "-Werror",
                    *inc,
                    "-o",
                    str(exe),
                    str(ROOT / "tests" / "alsaloop_stall_test.c"),
                    str(obj),
                    "-lpthread",
                    "-lm",
                ],
            ]
            for step in steps:
                build = subprocess.run(step, capture_output=True, text=True)
                self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
