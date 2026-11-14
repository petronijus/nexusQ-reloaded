#!/usr/bin/env python3
"""Keep the overrides of distro packages current with their upstream.

An override (pmos/<pkg>/ with an upstream/upstream.json) is Alpine's package
rebuilt with our patches. Left alone it freezes: Alpine fixes the package, the
upstream project releases, the patch we carry is merged, and the Q keeps the
copy taken on the day. This script is the update path:

- Alpine's APKBUILD is compared with the copy the override was based on
  (upstream/APKBUILD.alpine). A change is merged into ours three-way with
  `git merge-file` when run with --merge (on the host; the builder container
  mounts the repo read-only), which also bumps our pkgrel and takes the new
  base. A conflict, or a new pkgver at Alpine (the patches need a re-base, and
  their package would outrank ours), is an error.
- An upstream release newer than the one the patches were taken for: re-base
  the patches, or drop the ones the release carries.
- A carried pull request that was merged upstream, closed, or whose head moved
  since it was taken: the patch still works, but someone has to look.
- Our APKBUILD, the base and upstream.json must name the same version; a
  re-base that updated one and not the others is an error.

How hard each finding stops depends on who asks. An image build (default)
stops only on what makes the override wrong or outranked: a new pkgver at
Alpine, an Alpine change that conflicts, versions that disagree. The rest is a
warning there, so a hotfix build is never held up by upstream activity that
harms no unit. A publish (--strict) also stops on an unmerged Alpine change
and on a new upstream release: nothing goes out to the fleet behind upstream.

Exit status: 0 current (warnings allowed), 1 an override needs work, 2 the
check could not run (network, or an upstream answered with an HTTP error).
NEXUSQ_SKIP_OVERRIDE_CHECK names overrides to leave out (`librespot`, or a
comma-separated list), or is `1` to leave out all of them (offline work only);
either way loudly. GITHUB_TOKEN, when set, is sent to the GitHub API, whose
unauthenticated limit is 60 requests an hour.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALPINE_RAW = "https://raw.githubusercontent.com/alpinelinux/aports/master/{path}/APKBUILD"
GITHUB_API = "https://api.github.com/repos/{repo}{path}"
TIMEOUT = 20


class Unreachable(Exception):
    """An upstream could not be asked: the network, or an HTTP error status."""


def fetch(url):
    headers = {"User-Agent": "nexusq-check-overrides"}
    token = os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.read().decode()
    except urllib.error.HTTPError as e:
        # The server answered: not a network problem, and the cure differs.
        if e.code == 404:
            hint = "the path moved (Alpine moves packages from testing/ to community/): fix upstream.json"
        elif e.code in (403, 429) and "api.github.com" in url:
            hint = "GitHub's API rate limit (60/hour unauthenticated): set GITHUB_TOKEN"
        else:
            hint = "the server refused the request"
        raise Unreachable(f"{url}: HTTP {e.code} -- {hint}") from None
    except (urllib.error.URLError, OSError) as e:
        raise Unreachable(f"{url}: network: {e}") from None


def github(repo, path):
    return json.loads(fetch(GITHUB_API.format(repo=repo, path=path)))


def field(apkbuild, name):
    m = re.search(rf"^{name}=(\S*)", apkbuild, re.M)
    return m.group(1).strip("\"'") if m else None


def set_pkgrel(apkbuild, rel):
    return re.sub(r"^pkgrel=\S*", f"pkgrel={rel}", apkbuild, count=1, flags=re.M)


def merge_apkbuild(ours, base, theirs):
    """Merge Alpine's change (base -> theirs) into ours: (merged, clean?).

    The pkgrel line is taken out of the merge. Ours is far above Alpine's on
    purpose, and Alpine bumps theirs at every rebuild, so merged as text it
    would conflict with every such bump and with any change next to it. Both
    sides get the base's value for the merge; the result gets ours + 1, since
    the merged build is a new revision of ours.
    """
    base_rel = field(base, "pkgrel")
    merged, clean = merge3(set_pkgrel(ours, base_rel), base, set_pkgrel(theirs, base_rel))
    return set_pkgrel(merged, int(field(ours, "pkgrel")) + 1), clean


def merge3(ours, base, theirs):
    """git merge-file: (merged text, clean?)."""
    with tempfile.TemporaryDirectory() as d:
        paths = []
        for name, text in (("ours", ours), ("base", base), ("theirs", theirs)):
            p = Path(d) / name
            p.write_text(text)
            paths.append(str(p))
        r = subprocess.run(
            ["git", "merge-file", "-p", "-L", "ours", "-L", "base", "-L", "alpine", *paths],
            capture_output=True,
            text=True,
        )
    if r.returncode < 0 or r.returncode > 127:
        raise RuntimeError(f"git merge-file failed: {r.stderr.strip()}")
    return r.stdout, r.returncode == 0


def check(aport, merge, strict=False, fetch_alpine=None, ask_github=None):
    """Check one override. Returns (errors, warnings, notes)."""
    fetch_alpine = fetch_alpine or (lambda path: fetch(ALPINE_RAW.format(path=path)))
    ask_github = ask_github or github
    errors, warnings, notes = [], [], []
    name = aport.name
    conf = json.loads((aport / "upstream" / "upstream.json").read_text())
    ours_path = aport / "APKBUILD"
    base_path = aport / "upstream" / "APKBUILD.alpine"
    ours, base = ours_path.read_text(), base_path.read_text()
    # Findings that only a publish stops on.
    release_findings = errors if strict else warnings

    versions = {"APKBUILD": field(ours, "pkgver"), "upstream/APKBUILD.alpine": field(base, "pkgver")}
    if "release" in conf:
        versions["upstream.json release"] = conf["release"].lstrip("v")
    if len(set(versions.values())) != 1:
        errors.append(
            f"{name}: the override names different versions ("
            + ", ".join(f"{k} {v}" for k, v in versions.items())
            + "). A re-base updates all three."
        )

    theirs = fetch_alpine(conf["alpine"])
    if theirs == base:
        notes.append(f"{name}: Alpine's APKBUILD unchanged since the override was taken")
    elif field(theirs, "pkgver") != field(base, "pkgver"):
        errors.append(
            f"{name}: Alpine moved to {field(theirs, 'pkgver')} (the override is based on "
            f"{field(base, 'pkgver')}). Their package now outranks ours on every Q: re-base "
            f"the patches on the new version, then take Alpine's APKBUILD as the new base."
        )
    else:
        merged, clean = merge_apkbuild(ours, base, theirs)
        if not clean:
            errors.append(
                f"{name}: Alpine changed their APKBUILD and it does not merge into ours "
                f"cleanly. Merge by hand: base pmos/{name}/upstream/APKBUILD.alpine, "
                f"theirs {ALPINE_RAW.format(path=conf['alpine'])}."
            )
        elif merge:
            ours_path.write_text(merged)
            base_path.write_text(theirs)
            warnings.append(
                f"{name}: merged Alpine's APKBUILD change and bumped pkgrel to "
                f"{field(merged, 'pkgrel')}. Review `git diff pmos/{name}`, "
                f"name the revision in the CHANGELOG and commit it."
            )
        else:
            release_findings.append(
                f"{name}: Alpine changed their APKBUILD (it merges cleanly). Run "
                f"`scripts/check-overrides.py --merge` on the host, review and commit."
            )

    if "github" in conf:
        repo = conf["github"]
        latest = ask_github(repo, "/releases/latest").get("tag_name")
        if latest and latest != conf["release"]:
            release_findings.append(
                f"{name}: {repo} released {latest}; the patches were taken for "
                f"{conf['release']}. Re-base them, and drop the ones {latest} carries."
            )
        for pr in conf.get("prs", []):
            info = ask_github(repo, f"/pulls/{pr['number']}")
            if info.get("merged"):
                warnings.append(
                    f"{name}: PR #{pr['number']} was merged upstream. Keep patches "
                    f"{', '.join(pr['patches'])} until a release carries it, then drop them."
                )
            elif info.get("state") == "closed":
                warnings.append(
                    f"{name}: PR #{pr['number']} was closed without a merge. Find out why "
                    f"before the next release of patches {', '.join(pr['patches'])}."
                )
            head = (info.get("head") or {}).get("sha", "")
            if head and not head.startswith(pr["head"]):
                warnings.append(
                    f"{name}: PR #{pr['number']} moved from {pr['head']} to {head[:10]} "
                    f"since its patches were taken. Review the new commits and re-take them."
                )
    return errors, warnings, notes


def overrides(root=ROOT):
    return sorted(p.parents[1] for p in (root / "pmos").glob("*/upstream/upstream.json"))


def banner(lines):
    width = max(len(line) for line in lines) + 4
    print("#" * width)
    for line in lines:
        print(f"# {line}")
    print("#" * width)


def main(argv=None, root=ROOT, checker=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--merge", action="store_true", help="merge Alpine's APKBUILD changes into the overrides")
    ap.add_argument("--strict", action="store_true", help="publish: also stop on unmerged or newer upstream")
    args = ap.parse_args(argv)
    checker = checker or check
    skip = {s.strip() for s in os.environ.get("NEXUSQ_SKIP_OVERRIDE_CHECK", "").split(",") if s.strip()}
    tracked = overrides(root)
    all_errors, all_warnings = [], []
    for aport in tracked:
        if "1" in skip or aport.name in skip:
            banner(
                [f"check-overrides: {aport.name} SKIPPED (NEXUSQ_SKIP_OVERRIDE_CHECK).", "Not compared with upstream."]
            )
            continue
        try:
            errors, warnings, notes = checker(aport, args.merge, args.strict)
        except Unreachable as e:
            banner([f"check-overrides: cannot ask upstream for {aport.name}:", str(e)[:240]])
            return 2
        for n in notes:
            print(f"check-overrides: {n}")
        all_errors += errors
        all_warnings += warnings
    if all_warnings:
        banner(["check-overrides: LOOK AT THIS"] + all_warnings)
    if all_errors:
        banner(["check-overrides: AN OVERRIDE IS OUT OF DATE"] + all_errors)
        return 1
    names = ", ".join(a.name for a in tracked) or "none"
    print(f"check-overrides: tracked overrides current with upstream ({names}); an override without")
    print("  pmos/<pkg>/upstream/upstream.json is not tracked by this script")
    return 0


if __name__ == "__main__":
    sys.exit(main())
