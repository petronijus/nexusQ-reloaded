"""Resolve a Debian dependency closure against two Packages indexes, minus an installed set.

Usage: resolve.py <maemo Packages> <debian Packages> <installed dpkg status> pkg...
Maemo entries win over Debian ones. Prints: name version filename sha256 origin
"""

import re
import sys


def parse(path):
    out = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for block in fh.read().split("\n\n"):
            fields = {}
            key = None
            for line in block.splitlines():
                if line.startswith((" ", "\t")) and key:
                    fields[key] += "\n" + line
                    continue
                if ":" in line:
                    key, _, val = line.partition(":")
                    fields[key] = val.strip()
            if "Package" in fields:
                out.setdefault(fields["Package"], fields)
                for prov in re.split(r",\s*", fields.get("Provides", "")):
                    name = prov.split(" ")[0].strip()
                    if name:
                        out.setdefault("virtual:" + name, fields)
    return out


def main():
    maemo, debian, status = parse(sys.argv[1]), parse(sys.argv[2]), parse(sys.argv[3])
    installed = {n for n, f in status.items() if not n.startswith("virtual:") and "installed" in f.get("Status", "")}
    installed |= {n[len("virtual:") :] for n in status if n.startswith("virtual:")}
    want = list(sys.argv[4:])
    done = {}
    while want:
        name = want.pop()
        name = name.split(":")[0]
        if name in done or name in installed:
            continue
        rec, origin = maemo.get(name), "maemo"
        if rec is None:
            rec, origin = debian.get(name), "debian"
        if rec is None:
            rec, origin = maemo.get("virtual:" + name), "maemo"
        if rec is None:
            rec, origin = debian.get("virtual:" + name), "debian"
        if rec is None:
            print("MISSING", name, file=sys.stderr)
            continue
        real = rec["Package"]
        if real in installed:
            done[name] = None
            continue
        done[name] = (rec, origin)
        done[real] = (rec, origin)
        deps = rec.get("Depends", "") + ("," + rec["Pre-Depends"] if rec.get("Pre-Depends") else "")
        for alt in re.split(r",\s*", deps):
            alt = alt.strip()
            if not alt:
                continue
            choices = [c.strip().split(" ")[0].split(":")[0] for c in alt.split("|")]
            if any(c in installed for c in choices):
                continue
            want.append(choices[0])
    seen = set()
    for _name, val in sorted(done.items()):
        if val is None:
            continue
        rec, origin = val
        if rec["Package"] in seen:
            continue
        seen.add(rec["Package"])
        print(rec["Package"], rec["Version"], rec["Filename"], rec["SHA256"], rec.get("Installed-Size", "?"), origin)


main()
