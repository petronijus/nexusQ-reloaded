"""scripts/check-overrides.py: an override must never fall silently behind upstream.

Each case builds a throwaway override (APKBUILD, upstream/APKBUILD.alpine,
upstream/upstream.json) and answers the script's questions to Alpine and
GitHub with canned replies, so nothing here touches the network.
"""

import contextlib
import io
import json
import os
import shutil
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
co = SourceFileLoader("check_overrides", str(ROOT / "scripts" / "check-overrides.py")).load_module()

BASE = """pkgname=demo
pkgver=1.0
pkgrel=0
makedepends="cargo"
options="!check net"

build() {
	make
}
"""
# Ours: the base with our pkgrel and a gate in build().
OURS = BASE.replace("pkgrel=0", "pkgrel=100").replace("\tmake\n", "\tgrep -q fix src.c\n\tmake\n")
CONF = {
    "alpine": "testing/demo",
    "github": "example/demo",
    "release": "v1.0",
    "prs": [{"number": 7, "head": "abcdef1234", "patches": ["0001"]}],
}


class CheckOverridesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.aport = self.tmp / "pmos" / "demo"
        (self.aport / "upstream").mkdir(parents=True)
        (self.aport / "APKBUILD").write_text(OURS)
        (self.aport / "upstream" / "APKBUILD.alpine").write_text(BASE)
        (self.aport / "upstream" / "upstream.json").write_text(json.dumps(CONF))
        self.alpine = BASE
        self.release = "v1.0"
        self.pr = {"state": "open", "merged": False, "head": {"sha": "abcdef1234567890"}}

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_check(self, merge=False, strict=False):
        def ask_github(repo, path):
            self.assertEqual(repo, "example/demo")
            return {"tag_name": self.release} if path == "/releases/latest" else self.pr

        return co.check(self.aport, merge, strict, fetch_alpine=lambda path: self.alpine, ask_github=ask_github)

    def run_main(self, argv=(), checker=None, skip=None):
        env = dict(os.environ)
        env.pop("NEXUSQ_SKIP_OVERRIDE_CHECK", None)
        if skip is not None:
            env["NEXUSQ_SKIP_OVERRIDE_CHECK"] = skip
        out = io.StringIO()
        old = dict(os.environ)
        os.environ.clear()
        os.environ.update(env)
        try:
            with contextlib.redirect_stdout(out):
                rc = co.main(list(argv), root=self.tmp, checker=checker or (lambda a, m, st: self.run_check(m, st)))
        finally:
            os.environ.clear()
            os.environ.update(old)
        return rc, out.getvalue()

    def test_an_unchanged_upstream_is_current(self):
        errors, warnings, _ = self.run_check()
        self.assertEqual((errors, warnings), ([], []))

    def test_a_new_pkgver_at_alpine_is_an_error(self):
        self.alpine = BASE.replace("pkgver=1.0", "pkgver=1.1")
        errors, _, _ = self.run_check(merge=True)
        self.assertEqual(len(errors), 1)
        self.assertIn("Alpine moved to 1.1", errors[0])
        self.assertEqual((self.aport / "APKBUILD").read_text(), OURS, "a pkgver bump must not be merged")

    def test_a_clean_alpine_change_unmerged_warns_a_build_and_stops_a_publish(self):
        self.alpine = BASE.replace('makedepends="cargo"', 'makedepends="cargo openssl-dev"')
        errors, warnings, _ = self.run_check(merge=False)
        self.assertEqual(errors, [])
        self.assertIn("--merge", warnings[0])
        errors, _, _ = self.run_check(merge=False, strict=True)
        self.assertEqual(len(errors), 1)
        self.assertIn("--merge", errors[0])
        self.assertEqual((self.aport / "APKBUILD").read_text(), OURS)

    def test_merge_takes_a_clean_alpine_change_and_bumps_pkgrel(self):
        self.alpine = BASE.replace('makedepends="cargo"', 'makedepends="cargo openssl-dev"')
        errors, warnings, _ = self.run_check(merge=True)
        self.assertEqual(errors, [])
        self.assertEqual(len(warnings), 1)
        merged = (self.aport / "APKBUILD").read_text()
        self.assertIn('makedepends="cargo openssl-dev"', merged)
        self.assertIn("grep -q fix src.c", merged, "our own change must survive the merge")
        self.assertIn("pkgrel=101", merged)
        self.assertEqual((self.aport / "upstream" / "APKBUILD.alpine").read_text(), self.alpine)
        # The next run sees Alpine's APKBUILD as the base again: current.
        self.assertEqual(self.run_check(merge=True)[:2], ([], []))

    def test_alpine_bumping_their_pkgrel_merges_without_a_conflict(self):
        # Alpine rebuilds bump pkgrel next to the lines they change; ours is r100.
        self.alpine = BASE.replace("pkgrel=0", "pkgrel=1").replace('makedepends="cargo"', 'makedepends="cargo nasm"')
        errors, _, _ = self.run_check(merge=True)
        self.assertEqual(errors, [])
        merged = (self.aport / "APKBUILD").read_text()
        self.assertIn("pkgrel=101", merged)
        self.assertIn('makedepends="cargo nasm"', merged)

    def test_a_conflicting_alpine_change_is_an_error_and_writes_nothing(self):
        self.alpine = BASE.replace("\tmake\n", "\tmake -j1\n")
        errors, _, _ = self.run_check(merge=True)
        self.assertEqual(len(errors), 1)
        self.assertIn("does not merge", errors[0])
        self.assertEqual((self.aport / "APKBUILD").read_text(), OURS)
        self.assertEqual((self.aport / "upstream" / "APKBUILD.alpine").read_text(), BASE)

    def test_a_new_upstream_release_warns_a_build_and_stops_a_publish(self):
        self.release = "v1.1"
        errors, warnings, _ = self.run_check()
        self.assertEqual(errors, [])
        self.assertIn("released v1.1", warnings[0])
        errors, _, _ = self.run_check(strict=True)
        self.assertEqual(len(errors), 1)
        self.assertIn("released v1.1", errors[0])

    def test_versions_that_disagree_are_an_error(self):
        (self.aport / "APKBUILD").write_text(OURS.replace("pkgver=1.0", "pkgver=1.1"))
        errors, _, _ = self.run_check()
        self.assertEqual(len(errors), 1)
        self.assertIn("different versions", errors[0])

    def test_main_exits_0_when_current_and_1_on_an_error(self):
        self.assertEqual(self.run_main()[0], 0)
        self.alpine = BASE.replace("pkgver=1.0", "pkgver=1.1")
        rc, out = self.run_main()
        self.assertEqual(rc, 1)
        self.assertIn("AN OVERRIDE IS OUT OF DATE", out)

    def test_main_passes_strict_through(self):
        self.release = "v1.1"
        self.assertEqual(self.run_main()[0], 0)
        self.assertEqual(self.run_main(["--strict"])[0], 1)

    def test_main_exits_2_when_upstream_cannot_be_asked(self):
        def unreachable(aport, merge, strict):
            raise co.Unreachable("https://example: network: down")

        rc, out = self.run_main(checker=unreachable)
        self.assertEqual(rc, 2)
        self.assertIn("cannot ask upstream for demo", out)

    def test_main_skips_a_named_override_loudly(self):
        self.alpine = BASE.replace("pkgver=1.0", "pkgver=1.1")
        for skip in ("demo", "other,demo", "1"):
            with self.subTest(skip=skip):
                rc, out = self.run_main(skip=skip)
                self.assertEqual(rc, 0)
                self.assertIn("demo SKIPPED", out)
        self.assertEqual(self.run_main(skip="other")[0], 1, "skipping another override must not skip this one")

    def test_a_merged_pr_is_a_warning(self):
        self.pr["merged"] = True
        self.pr["state"] = "closed"
        errors, warnings, _ = self.run_check()
        self.assertEqual(errors, [])
        self.assertEqual(len(warnings), 1)
        self.assertIn("PR #7 was merged", warnings[0])

    def test_a_pr_closed_unmerged_is_a_warning(self):
        self.pr["state"] = "closed"
        _, warnings, _ = self.run_check()
        self.assertTrue(any("closed without a merge" in w for w in warnings))

    def test_a_pr_whose_head_moved_is_a_warning(self):
        self.pr["head"]["sha"] = "1234567890abcdef"
        _, warnings, _ = self.run_check()
        self.assertEqual(len(warnings), 1)
        self.assertIn("moved from abcdef1234 to 1234567890", warnings[0])

    def test_the_overrides_are_found_by_their_upstream_json(self):
        self.assertEqual(co.overrides(self.tmp), [self.aport])

    def test_the_librespot_override_is_tracked(self):
        self.assertIn(ROOT / "pmos" / "librespot", co.overrides())


if __name__ == "__main__":
    unittest.main()
