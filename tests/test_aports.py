"""Tripwires for the aports: what abuild silently ignores must not drift.

docker-build.sh and scripts/build-kernel-boot.sh copy EVERY
kernel/patches/*.patch into the kernel aport, but abuild applies only the
patches named in the APKBUILD's `source=`. A patch that is committed but not
listed is staged, never applied, and the build still succeeds — the kernel just
lacks the fix (bit us with patch 0012, the UTMI clock). The reverse, a listed
patch that does not exist, fails the build late, after the docker setup.

For the aports whose files live next to their APKBUILD, a file that is not in
`source=` never reaches $srcdir: it is dead weight that reads as shipped.

And where one source is kept twice — once next to the aport that packs it,
once next to the unit tests that exercise it — the two must stay identical.
"""

import hashlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PMOS = ROOT / "pmos"
# abuild runs these itself; they are named by convention, not listed in source=.
INSTALL_SCRIPT = re.compile(r"\.(pre|post)-(install|upgrade|deinstall)$|\.trigger$")


def sources(apkbuild: Path) -> list[str]:
    """The file names in an APKBUILD's source="…" (URLs and `name::url` renames excluded)."""
    m = re.search(r'^source="(.*?)"', apkbuild.read_text(), re.S | re.M)
    if not m:
        return []
    words = m.group(1).split()
    return [w for w in words if "://" not in w]


class KernelPatches(unittest.TestCase):
    def test_every_committed_patch_is_applied_and_every_listed_patch_exists(self):
        committed = {p.name for p in (ROOT / "kernel" / "patches").glob("*.patch")}
        listed = {s for s in sources(PMOS / "linux-google-steelhead" / "APKBUILD") if s.endswith(".patch")}
        self.assertTrue(committed, "no kernel patches found; the layout changed")
        self.assertEqual(
            sorted(committed - listed),
            [],
            "in kernel/patches but not in source= of pmos/linux-google-steelhead/APKBUILD: "
            "staged by the build, never applied",
        )
        self.assertEqual(sorted(listed - committed), [], "in source= but missing from kernel/patches")


class SelfContainedAports(unittest.TestCase):
    """Aports that carry their own files (the others are staged by docker-build.sh)."""

    APORTS = [
        d
        for d in sorted(PMOS.iterdir())
        if (d / "APKBUILD").is_file() and any(p.name != "APKBUILD" for p in d.iterdir() if p.is_file())
    ]

    def test_the_self_contained_aports_are_found(self):
        self.assertIn(PMOS / "device-google-steelhead", self.APORTS)

    def test_every_file_next_to_an_apkbuild_is_in_its_source_list(self):
        for aport in self.APORTS:
            with self.subTest(aport=aport.name):
                listed = {Path(s).name for s in sources(aport / "APKBUILD")}
                stray = sorted(
                    p.name
                    for p in aport.iterdir()
                    if p.is_file()
                    and p.name != "APKBUILD"
                    and not INSTALL_SCRIPT.search(p.name)
                    and p.name not in listed
                )
                self.assertEqual(stray, [], f"files in pmos/{aport.name}/ that source= does not list")

    def test_every_listed_local_source_exists(self):
        for aport in self.APORTS:
            with self.subTest(aport=aport.name):
                missing = sorted(s for s in sources(aport / "APKBUILD") if "$" not in s and not (aport / s).is_file())
                self.assertEqual(missing, [], f"source= of pmos/{aport.name} names files that do not exist")


class ShippedCopies(unittest.TestCase):
    """One source, two copies: the build packs one, the unit tests read the other."""

    # (the copy the aport packs, the copy `just test-c` tests)
    PAIRS = [
        ("pmos/device-google-steelhead/nq-healthd.c", "userspace/nq-healthd/nq-healthd.c"),
    ]

    def test_the_shipped_copy_is_the_tested_copy(self):
        for shipped, tested in self.PAIRS:
            with self.subTest(shipped=shipped):
                self.assertEqual(
                    hashlib.sha256((ROOT / shipped).read_bytes()).hexdigest(),
                    hashlib.sha256((ROOT / tested).read_bytes()).hexdigest(),
                    f"{shipped} and {tested} differ: the device would run code the tests never saw. "
                    f"Edit {tested}, then copy it over {shipped}.",
                )


if __name__ == "__main__":
    unittest.main()
