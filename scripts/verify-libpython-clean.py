#!/usr/bin/env python3
"""
Deterministic build-integrity gate for libpython3.14.so.1.0 (and any armv7 lib).

ROOT CAUSE this guards against: the armv7 toolchain runs under qemu-user during the
build (pmbootstrap --no-cross). qemu's mmap zero-fill of the linker's output file is
buggy and NON-DETERMINISTICALLY leaves stale garbage in regions that the C standard
guarantees are zero -- specifically inside the PROGBITS sections .PyRuntime (holds
_PyRuntime / the main PyInterpreterState) and .data.rel.ro. When that garbage lands on
interp->types.builtins.num_initialized, CPython reads a wild type-index at the first
_PyStaticType_InitBuiltin and SIGSEGVs on real hardware (qemu false-passes it).

A CLEAN build has those "should be zero" regions actually zero; a CORRUPT build has
large contiguous non-zero garbage runs there. This check is OPTIMISATION-INDEPENDENT
(it does not compare against a reference binary): it flags long non-zero runs that sit
OUTSIDE both (a) the small statically-initialised head of each section and (b) the
dynamic-relocation slots (legit pointers). Clean builds score ~0; corrupt builds score
thousands.

Usage:  verify-libpython-clean.py <libpython3.14.so.1.0>   [--verbose]
Exit 0 = clean, 1 = corrupt, 2 = usage/parse error.
"""
import sys, struct

VERBOSE = "--verbose" in sys.argv
args = [a for a in sys.argv[1:] if not a.startswith("--")]
if len(args) != 1:
    print(__doc__); sys.exit(2)
path = args[0]
elf = open(path, "rb").read()

if elf[:4] != b"\x7fELF" or elf[4] != 1 or elf[5] != 1:
    print(f"ERROR: {path} is not a 32-bit LE ELF"); sys.exit(2)

# ELF32 header: e_shoff @0x20, e_shentsize @0x2e, e_shnum @0x30, e_shstrndx @0x32
(e_shoff,) = struct.unpack_from("<I", elf, 0x20)
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", elf, 0x2e)

# section table: name(4) type(4) flags(4) addr(4) off(4) size(4) link(4) info(4) align(4) entsize(4)
secs = []
for i in range(e_shnum):
    b = e_shoff + i * e_shentsize
    name, typ, flags, addr, off, size = struct.unpack_from("<IIIIII", elf, b)
    secs.append({"name": name, "type": typ, "addr": addr, "off": off, "size": size})
shstr_off = secs[e_shstrndx]["off"]

def secname(n):
    end = elf.index(b"\x00", shstr_off + n)
    return elf[shstr_off + n:end].decode("latin1")

for s in secs:
    s["nm"] = secname(s["name"])

# Collect ELF32 REL relocation r_offset (vaddr) values -> legit pointer slots to skip.
reloc_vaddrs = set()
for s in secs:
    if s["nm"] in (".rel.dyn", ".rel.plt", ".rela.dyn", ".rela.plt"):
        step = 12 if s["nm"].startswith(".rela") else 8
        for o in range(s["off"], s["off"] + s["size"], step):
            (r_off,) = struct.unpack_from("<I", elf, o)
            reloc_vaddrs.add(r_off & ~3)

# How much statically-initialised head to tolerate per section (bytes). The legit
# _PyRuntimeState_INIT / const tables live at the start; the corruption is large runs
# well past it. We additionally skip any word at a relocation site anywhere.
HEAD_TOLERANCE = {".PyRuntime": 0xF000, ".data.rel.ro": 0x0}
RUN_THRESHOLD = 256   # a contiguous non-zero run >= this many bytes outside relocs = garbage

verdict_bad = 0
report = []
for s in secs:
    if s["nm"] not in (".PyRuntime", ".data.rel.ro"):
        continue
    head = HEAD_TOLERANCE.get(s["nm"], 0)
    data = elf[s["off"]:s["off"] + s["size"]]
    nonzero_total = sum(1 for b in data if b)
    # find longest contiguous non-zero run that is NOT covered by reloc slots and is
    # past the tolerated head
    longest_run = 0
    run = 0
    garbage_bytes = 0
    for w in range(0, len(data) - 3, 4):
        vaddr = s["addr"] + w
        word = data[w:w + 4]
        is_zero = (word == b"\x00\x00\x00\x00")
        is_reloc = vaddr in reloc_vaddrs
        in_head = w < head
        if (not is_zero) and (not is_reloc) and (not in_head):
            run += 4
            garbage_bytes += sum(1 for x in word if x)
            longest_run = max(longest_run, run)
        else:
            run = 0
    flagged = longest_run >= RUN_THRESHOLD
    if flagged:
        verdict_bad += garbage_bytes
    report.append((s["nm"], s["size"], nonzero_total, garbage_bytes, longest_run, flagged))

print(f"=== libpython integrity check: {path} ===")
for nm, size, nz, gb, lr, fl in report:
    print(f"  {nm:14} size={size:8} nonzero={nz:8} garbage_outside_relocs={gb:8} "
          f"longest_run={lr:6} {'<<< CORRUPT' if fl else 'ok'}")

if verdict_bad > 0:
    print(f"RESULT: CORRUPT ({verdict_bad} garbage bytes in long non-zero runs outside "
          f"relocations) -- qemu-user mmap zero-fill failure; rebuild.")
    sys.exit(1)
print("RESULT: CLEAN")
sys.exit(0)
