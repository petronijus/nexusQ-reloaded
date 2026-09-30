"""The alsa-utils override's patch (pmos/alsa-utils/0001): alsaloop's
setscheduler(), tested on the host.

This takes the function from the patch's post-image -- so what is tested is
what ships -- and builds tests/alsaloop_sched_test.c around it with a fake
pthread scheduling API: an inherited SCHED_FIFO/SCHED_RR is kept (the priority
nexusq-uac2-in gives alsaloop with chrt), an ordinary thread still asks for
Round Robin at the top, and nothing is logged on the paths that used to print
"Scheduler getparam failed." at every start.
"""

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILE = "alsaloop/alsaloop.c"


def post_image(patch: str, path: str) -> str:
    """The patched lines of every hunk for `path`, context and additions, in order."""
    m = re.search(
        rf"^diff --git a/{re.escape(path)} b/{re.escape(path)}\n(.*?)(?=^diff --git |^-- \n|\Z)", patch, re.M | re.S
    )
    if not m:
        raise LookupError(f"the patch does not touch {path}")
    out = []
    for line in m.group(1).split("\n"):
        if line.startswith("@@"):
            out.append("")
        elif line.startswith((" ", "+")) and not line.startswith("+++"):
            out.append(line[1:])
    return "\n".join(out)


def function(source: str, signature: str) -> str:
    """`signature` through the closing brace at column 0, with its leading comment if any."""
    start = source.index(signature)
    comment = source.rfind("/*", 0, start)
    if comment != -1 and source[comment:start].rstrip().endswith("*/"):
        start = comment
    end = re.compile(r"^}$", re.M).search(source, start)
    if not end:
        raise LookupError(f"no closing brace after {signature!r}")
    return source[start : end.end()] + "\n"


class Setscheduler(unittest.TestCase):
    def test_the_patched_function(self):
        patches = sorted((ROOT / "pmos" / "alsa-utils").glob("0001-alsaloop-*.patch"))
        self.assertEqual(len(patches), 1, "exactly one alsaloop patch in pmos/alsa-utils")
        body = function(post_image(patches[0].read_text(), FILE), "static void setscheduler(void)\n{")
        self.assertIn("pthread_getschedparam", body)
        cc = shutil.which("cc")
        self.assertIsNotNone(cc, "a C compiler is needed (just doctor)")
        with tempfile.TemporaryDirectory() as d:
            Path(d, "setscheduler.inc").write_text(body)
            exe = Path(d, "alsaloop_sched_test")
            build = subprocess.run(
                [
                    cc,
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-I",
                    d,
                    "-o",
                    str(exe),
                    str(ROOT / "tests" / "alsaloop_sched_test.c"),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
