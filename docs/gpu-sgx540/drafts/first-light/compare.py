"""Golden check for the sgxprobe output: renderer must be the SGX 540 and the
image must match the software reference within a tolerance.

Usage: compare.py <probe.txt> <image.ppm> <reference.ppm> [tolerance]
Exit 0 = pass, 1 = fail.
"""

import hashlib
import sys


def ppm(path):
    data = open(path, "rb").read()
    parts = data.split(b"\n", 3)
    assert parts[0] == b"P6", path
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


def main():
    txt, img, ref = sys.argv[1:4]
    tol = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    ok = True
    renderer = next((ln for ln in open(txt) if ln.startswith("GL_RENDERER")), "")
    if "PowerVR SGX 540" not in renderer:
        print("FAIL renderer:", renderer.strip() or "(none)")
        ok = False
    w1, h1, a = ppm(img)
    w2, h2, b = ppm(ref)
    if (w1, h1) != (w2, h2):
        print("FAIL size", (w1, h1), (w2, h2))
        return 1
    diffs = [abs(x - y) for x, y in zip(a, b)]
    worst = max(diffs)
    bad = sum(1 for i in range(0, len(diffs), 3) if max(diffs[i : i + 3]) > tol)
    print(f"sha256 image={hashlib.sha256(a).hexdigest()[:16]} ref={hashlib.sha256(b).hexdigest()[:16]}")
    print(f"max channel diff={worst} pixels over tol {tol}: {bad}/{w1 * h1}")
    if bad:
        ok = False
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


sys.exit(main())
