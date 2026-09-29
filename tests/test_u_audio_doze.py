"""Kernel patch 0059 (u_audio doze): its decisions, tested on the host.

The patch creates drivers/usb/gadget/function/u_audio_doze.h, which holds the
doze decisions free of kernel headers. This extracts that file from the patch
as it sits in kernel/patches -- so what is tested is what ships -- and builds
and runs tests/u_audio_doze_test.c against it with the host compiler.
"""

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEADER = "drivers/usb/gadget/function/u_audio_doze.h"


def new_file_from_patch(patch: str, path: str) -> str:
    """The content of a file the patch creates (a `new file mode` section)."""
    m = re.search(
        rf"^diff --git a/{re.escape(path)} b/{re.escape(path)}\nnew file mode .*?\n.*?^@@ -0,0 \+1,(\d+) @@.*?\n",
        patch,
        re.M | re.S,
    )
    if not m:
        raise LookupError(f"the patch does not create {path}")
    lines = patch[m.end() :].split("\n")[: int(m.group(1))]
    assert all(line.startswith("+") for line in lines), "a new-file hunk holds only added lines"
    return "\n".join(line[1:] for line in lines) + "\n"


class DozeDecisions(unittest.TestCase):
    def test_the_patched_decisions(self):
        patches = sorted((ROOT / "kernel" / "patches").glob("*-usb-gadget-u_audio-doze-*.patch"))
        self.assertEqual(len(patches), 1, "exactly one u_audio doze patch in kernel/patches")
        cc = shutil.which("cc")
        self.assertIsNotNone(cc, "a C compiler is needed (just doctor)")
        with tempfile.TemporaryDirectory() as d:
            Path(d, "u_audio_doze.h").write_text(new_file_from_patch(patches[0].read_text(), HEADER))
            exe = Path(d, "u_audio_doze_test")
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
                    str(ROOT / "tests" / "u_audio_doze_test.c"),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
