#!/usr/bin/env python3
"""The release manifest: what a Nexus Q learns about a new release.

pmos/release-notes.json is written by hand for each release: its version,
date, a headline and one to five short items, each an icon, a title and one
sentence, in the words a user reads in the app ("what's new"), not the
CHANGELOG's. This tool checks that file and, at publish time, adds the version
of each of our packages the OTA repo carries, read from the APKINDEX it just
signed. The result is release.json beside the repo's armv7/ directory; the
Q's release watch (nexusq-control, PROTOCOL §12c) fetches it and compares the
packages with what it has installed.

    release_manifest.py check NOTES [--version X.Y.Z]
    release_manifest.py build NOTES APKINDEX.tar.gz OTA_LIST > release.json
    release_manifest.py republish PUBLISHED.json NEW.json

`check` is the author's gate (package-release.sh runs it with the release's
version); `build` is what publish-ota-repo.sh runs. Both refuse rather than
publish something a unit would reject or show wrongly.

Notes are written as a draft (`"draft": true`) until Petr approves them with
the release. `build` does not publish a draft: it exits 3, and the publish
keeps the release.json already on gh-pages, so a hotfix pushed meanwhile
never rings the fleet with unapproved text. `check --version` refuses a draft.
"""

import json
import re
import sys
import tarfile

SCHEMA = 1
# The icons the app draws (companion/app/lib/update/release_icons.dart) and the
# device accepts (nexusq-control RELEASE_ICONS). tests/ keeps the three equal.
ICONS = ("new", "sound", "speaker", "wifi", "bluetooth", "power", "lights", "music", "usb", "fix", "security")
# Published for nq-kernel-ota, never installed by apk: not a release package.
NOT_APK_INSTALLED = ("linux-google-steelhead",)
LIMITS = {"headline": 80, "title": 40, "text": 140}
_VERSION = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$")
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class ManifestError(ValueError):
    pass


class DraftNotes(ManifestError):
    """The notes are still a draft: nothing is published from them."""


def _text(obj, key, where):
    v = obj.get(key)
    if not isinstance(v, str) or not v.strip():
        raise ManifestError(f"{where}{key}: missing or empty")
    if v != v.strip():
        raise ManifestError(f"{where}{key}: leading or trailing whitespace")
    if len(v) > LIMITS[key]:
        raise ManifestError(f"{where}{key}: {len(v)} characters, at most {LIMITS[key]}")
    return v


def check_notes(notes, version=None):
    """The hand-written notes, strictly. Returns them; raises ManifestError."""
    if not isinstance(notes, dict):
        raise ManifestError("the notes are not a JSON object")
    known = {"schema", "version", "date", "headline", "items", "draft"}
    extra = set(notes) - known
    if extra:
        # `packages` in particular: it is derived from the index at publish time,
        # never typed by hand, or it would drift from what the repo carries.
        raise ManifestError(f"unexpected keys: {', '.join(sorted(extra))}")
    if notes.get("schema") != SCHEMA:
        raise ManifestError(f"schema must be {SCHEMA}")
    v = notes.get("version")
    if not isinstance(v, str) or not _VERSION.match(v):
        raise ManifestError("version must be X.Y.Z")
    if version is not None and v != version.lstrip("v"):
        raise ManifestError(f"the notes are for {v}, the release is {version}")
    if "draft" in notes and not isinstance(notes["draft"], bool):
        raise ManifestError("draft must be true or false")
    if version is not None and notes.get("draft"):
        raise DraftNotes(f'the notes for {v} are still a draft; approve them (drop "draft") to release')
    if not isinstance(notes.get("date"), str) or not _DATE.match(notes["date"]):
        raise ManifestError("date must be YYYY-MM-DD")
    _text(notes, "headline", "")
    items = notes.get("items")
    if not isinstance(items, list) or not 1 <= len(items) <= 5:
        raise ManifestError("items: one to five")
    for i, it in enumerate(items):
        where = f"items[{i}]."
        if not isinstance(it, dict) or set(it) != {"icon", "title", "text"}:
            raise ManifestError(f"{where[:-1]}: exactly icon, title and text")
        if it["icon"] not in ICONS:
            raise ManifestError(f"{where}icon: {it['icon']!r} is not one of {', '.join(ICONS)}")
        _text(it, "title", where)
        _text(it, "text", where)
    return notes


def index_versions(apkindex_tar):
    """name -> version of every package in a signed APKINDEX.tar.gz."""
    with tarfile.open(apkindex_tar) as t:
        raw = t.extractfile("APKINDEX").read().decode()
    out = {}
    for block in raw.split("\n\n"):
        fields = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
        if "P" in fields and "V" in fields:
            out[fields["P"]] = fields["V"]
    return out


def ota_names(ota_list_text):
    names = []
    for line in ota_list_text.splitlines():
        name = line.split("#", 1)[0].strip()
        if name:
            names.append(name)
    return names


def build(notes, versions, names):
    """The published manifest: the notes plus {package: version}."""
    check_notes(notes)
    if notes.get("draft"):
        raise DraftNotes(f"the notes for {notes['version']} are a draft; release.json is not rebuilt")
    pkgs = {}
    for name in names:
        if name in NOT_APK_INSTALLED:
            continue
        if name not in versions:
            raise ManifestError(f"{name} is in the OTA set but not in the index")
        pkgs[name] = versions[name]
    if not pkgs:
        raise ManifestError("no packages")
    return {**{k: v for k, v in notes.items() if k != "draft"}, "packages": pkgs}


def check_republish(old, new):
    """A change of packages is a new release. The same version published
    again with other packages would read as pending again on a unit that
    installed it, with notes it has already seen. `old`/`new` are manifests;
    `old` None when nothing is published yet."""
    if old is None or old.get("version") != new["version"]:
        return
    before, after = old.get("packages") or {}, new["packages"]
    if before != after:
        changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
        raise ManifestError(
            f"release {new['version']} is already published with other packages ({', '.join(changed)}); "
            "give pmos/release-notes.json a new version and its notes"
        )


def main(argv):
    if len(argv) >= 2 and argv[0] == "check":
        version = None
        if len(argv) == 4 and argv[2] == "--version":
            version = argv[3]
        elif len(argv) != 2:
            raise SystemExit(__doc__)
        with open(argv[1]) as f:
            check_notes(json.load(f), version)
        return 0
    if len(argv) == 4 and argv[0] == "build":
        with open(argv[1]) as f:
            notes = json.load(f)
        with open(argv[3]) as f:
            names = ota_names(f.read())
        json.dump(build(notes, index_versions(argv[2]), names), sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return 0
    if len(argv) == 3 and argv[0] == "republish":
        try:
            with open(argv[1]) as f:
                old = json.load(f)
        except (OSError, json.JSONDecodeError):
            old = None  # nothing published yet
        try:
            with open(argv[2]) as f:
                new = json.load(f)
        except OSError:
            return 0  # nothing new to publish (draft notes)
        check_republish(old, new)
        return 0
    raise SystemExit(__doc__)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except DraftNotes as e:
        print(f"release_manifest: {e}", file=sys.stderr)
        sys.exit(3)
    except (ManifestError, OSError, json.JSONDecodeError) as e:
        print(f"release_manifest: {e}", file=sys.stderr)
        sys.exit(1)
