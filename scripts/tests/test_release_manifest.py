"""scripts/release_manifest.py: the notes a release is published with.

Pinned: the hand-written notes are refused when a unit would show them wrong
(too long, an icon the app cannot draw, a typed package list, the wrong
release); the published manifest carries every OTA package from the signed
index except the kernel payload, and fails when one is missing; what it
builds, the Q's own parser accepts; the icon vocabulary is the same in the
tool, on the device and in the app.
"""

import copy
import importlib.machinery
import importlib.util
import io
import json
import re
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load(path, name):
    spec = importlib.util.spec_from_loader(name, importlib.machinery.SourceFileLoader(name, str(path)))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


RM = load(ROOT / "scripts" / "release_manifest.py", "release_manifest")
DRAFT = json.loads((ROOT / "pmos" / "release-notes.json").read_text())
# The notes as they are once approved with the release.
NOTES = {k: v for k, v in DRAFT.items() if k != "draft"}


def apkindex(tmp, pkgs):
    raw = "\n\n".join(f"C:Q1x=\nP:{p}\nV:{v}\nA:armv7" for p, v in pkgs.items()) + "\n\n"
    path = Path(tmp) / "APKINDEX.tar.gz"
    with tarfile.open(path, "w:gz") as t:
        data = raw.encode()
        info = tarfile.TarInfo("APKINDEX")
        info.size = len(data)
        t.addfile(info, io.BytesIO(data))
    return path


class Notes(unittest.TestCase):
    def test_the_committed_notes_pass(self):
        RM.check_notes(DRAFT)
        RM.check_notes(NOTES)

    def test_a_draft_is_not_released_and_not_published(self):
        # The fleet must not ring with unapproved text: a hotfix publish while
        # the notes are a draft rebuilds no release.json (publish-ota-repo.sh
        # keeps the published one), and a release refuses them.
        draft = {**NOTES, "draft": True}
        RM.check_notes(draft)
        with self.assertRaises(RM.DraftNotes):
            RM.check_notes(draft, "v" + NOTES["version"])
        with self.assertRaises(RM.DraftNotes):
            RM.build(draft, {"nexusqd": "0.1.0-r25"}, ["nexusqd"])
        with self.assertRaises(RM.ManifestError):
            RM.check_notes({**NOTES, "draft": "yes"})
        approved = {**NOTES, "draft": False}
        self.assertNotIn("draft", RM.build(approved, {"nexusqd": "0.1.0-r25"}, ["nexusqd"]))

    def test_what_the_gate_refuses(self):
        def bad(change):
            n = copy.deepcopy(NOTES)
            change(n)
            return n

        cases = {
            "a typed package list": bad(lambda n: n.update(packages={"nexusqd": "0.1.0-r1"})),
            "schema 2": bad(lambda n: n.update(schema=2)),
            "a v-prefixed version": bad(lambda n: n.update(version="v2.0.0")),
            "a long headline": bad(lambda n: n.update(headline="x" * 81)),
            "padded text": bad(lambda n: n["items"][0].update(text=" padded")),
            "an icon the app has not got": bad(lambda n: n["items"][0].update(icon="rocket")),
            "a long title": bad(lambda n: n["items"][0].update(title="t" * 41)),
            "a long text": bad(lambda n: n["items"][0].update(text="t" * 141)),
            "an extra item key": bad(lambda n: n["items"][0].update(url="https://x")),
            # exactly six, whatever the current notes hold (2.0.0 had five)
            "six items": bad(lambda n: n.update(items=[n["items"][0]] * 6)),
            "no items": bad(lambda n: n.update(items=[])),
        }
        for what, n in cases.items():
            with self.subTest(what), self.assertRaises(RM.ManifestError):
                RM.check_notes(n)

    def test_the_notes_must_be_for_the_release_being_cut(self):
        RM.check_notes(NOTES, "v" + NOTES["version"])
        with self.assertRaises(RM.ManifestError):
            RM.check_notes(NOTES, "v9.9.9")


class Build(unittest.TestCase):
    def test_packages_come_from_the_index_the_kernel_does_not(self):
        with tempfile.TemporaryDirectory() as d:
            idx = apkindex(d, {"nexusqd": "0.1.0-r25", "linux-google-steelhead": "6.18.48-r19", "other": "1-r0"})
            m = RM.build(NOTES, RM.index_versions(idx), ["nexusqd", "linux-google-steelhead"])
        self.assertEqual(m["packages"], {"nexusqd": "0.1.0-r25"})
        self.assertEqual(m["version"], NOTES["version"])

    def test_a_package_missing_from_the_index_stops_the_publish(self):
        with self.assertRaises(RM.ManifestError):
            RM.build(NOTES, {"nexusqd": "0.1.0-r25"}, ["nexusqd", "nexusq-control"])

    def test_the_ota_list_is_read_like_the_publish_script_reads_it(self):
        text = "# comment\nnexusqd\n\n  nexusq-control   # trailing\n"
        self.assertEqual(RM.ota_names(text), ["nexusqd", "nexusq-control"])

    def test_what_is_built_the_device_accepts(self):
        control = load(ROOT / "userspace" / "nexusq-control" / "nexusq-control", "nexusq_control")
        names = RM.ota_names((ROOT / "pmos" / "ota-packages.list").read_text())
        versions = {n: "0.1.0-r1" for n in names}
        rel = control.parse_release(RM.build(NOTES, versions, names))
        self.assertEqual(rel["version"], NOTES["version"])
        self.assertEqual([i["icon"] for i in rel["items"]], [i["icon"] for i in NOTES["items"]])


class Republish(unittest.TestCase):
    def test_the_same_version_with_other_packages_is_refused(self):
        old = {**NOTES, "packages": {"nexusqd": "0.1.0-r25"}}
        RM.check_republish(None, old)  # a first publish
        RM.check_republish(old, dict(old))  # the same release again
        other = "99.0.0" if NOTES["version"] != "99.0.0" else "98.0.0"  # any other version
        RM.check_republish(old, {**NOTES, "version": other, "packages": {"nexusqd": "0.1.0-r26"}})
        with self.assertRaises(RM.ManifestError):
            RM.check_republish(old, {**NOTES, "packages": {"nexusqd": "0.1.0-r26"}})


class Icons(unittest.TestCase):
    def test_the_tool_the_device_and_the_app_know_the_same_icons(self):
        control = load(ROOT / "userspace" / "nexusq-control" / "nexusq-control", "nexusq_control")
        self.assertEqual(tuple(control.RELEASE_ICONS), RM.ICONS)
        dart = (ROOT / "companion" / "app" / "lib" / "update" / "release_icons.dart").read_text()
        app = re.findall(r"^\s*'([a-z]+)':\s*Icons\.", dart, re.M)
        self.assertEqual(tuple(app), RM.ICONS)


if __name__ == "__main__":
    unittest.main()
