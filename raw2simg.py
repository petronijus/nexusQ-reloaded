"""Convert a raw ext4 image to Android sparse format using ONLY RAW chunks
(compatible with old U-Boot fastboot implementations that don't support FILL chunks).

WHY EVERY BLOCK IS WRITTEN (no DONT_CARE) — learned the hard way 2026-06-28:
An earlier version emitted all-zero blocks as DONT_CARE chunks to shrink the image.
fastboot SKIPS DONT_CARE blocks (it does not write them), which is only correct if the
target partition was zeroed first. The Nexus Q's 2012 U-Boot does NOT pre-erase
userdata, so every DONT_CARE block kept whatever STALE data the eMMC already held from
the previous flash. That silently re-corrupted file regions that are supposed to be
zero — most visibly libpython's `.PyRuntime`/`.data.rel.ro`, whose zero-regions came
out full of garbage on-device, re-introducing the exact armv7 python SIGSEGV the gold
build had just fixed. Forensics: the on-device libpython differed from the (clean)
flashed image in exactly 47 4 KiB blocks, ALL of them image-zero -> device-garbage.

So a raw filesystem image flashed to a NON-erased partition MUST be written in full:
every block becomes a RAW chunk (zeros included), making the on-eMMC bytes identical to
the source image regardless of prior content. The cost is no compression (the sparse is
~the raw size); correctness is non-negotiable. DONT_CARE is intentionally NOT used.
"""

import struct
import sys
import os

SPARSE_HEADER_MAGIC = 0xED26FF3A
CHUNK_TYPE_RAW = 0xCAC1

FILE_HDR_SZ = 28
CHUNK_HDR_SZ = 12
BLK_SZ = 4096

# Cap each RAW chunk so no single chunk is enormous; 16384 blocks = 64 MiB, well within
# what the device's U-Boot fastboot handled before (it streamed ~95 MiB sends fine).
# (`fastboot -S <size>` re-splits the transfer anyway; this just keeps the chunk table
# tidy and avoids any single oversized-chunk edge case.)
CHUNK_MAX_BLKS = 16384


def convert(raw_path, sparse_path):
    raw_size = os.path.getsize(raw_path)
    total_blks = raw_size // BLK_SZ
    if raw_size % BLK_SZ != 0:
        print(f"WARNING: image size {raw_size} not aligned to {BLK_SZ}, truncating")

    n_chunks = (total_blks + CHUNK_MAX_BLKS - 1) // CHUNK_MAX_BLKS
    print(f"Input:  {raw_path} ({raw_size / 1024 / 1024:.1f} MB, {total_blks} blocks)")
    print(f"Encoding ALL blocks as RAW (no DONT_CARE) -> {n_chunks} chunks; "
          f"every block written so the flash is byte-exact on a non-erased partition.")

    with open(sparse_path, 'wb') as out, open(raw_path, 'rb') as inp:
        header = struct.pack('<IHHHHIIII',
                             SPARSE_HEADER_MAGIC,
                             1, 0,                 # major/minor version
                             FILE_HDR_SZ,
                             CHUNK_HDR_SZ,
                             BLK_SZ,
                             total_blks,
                             n_chunks,
                             0)                    # image checksum (unused)
        out.write(header)

        blks_left = total_blks
        chunk_i = 0
        while blks_left > 0:
            count = min(blks_left, CHUNK_MAX_BLKS)
            total_sz = CHUNK_HDR_SZ + count * BLK_SZ
            out.write(struct.pack('<HHII', CHUNK_TYPE_RAW, 0, count, total_sz))
            remaining = count * BLK_SZ
            while remaining > 0:
                buf = inp.read(min(remaining, 8 * 1024 * 1024))
                if not buf:
                    raise IOError(f"unexpected EOF in {raw_path} with {remaining} bytes left")
                out.write(buf)
                remaining -= len(buf)
            blks_left -= count
            chunk_i += 1
            if chunk_i % 50 == 0 or blks_left == 0:
                pct = (total_blks - blks_left) * 100 // total_blks
                print(f"  Writing: {pct}% ({chunk_i}/{n_chunks} chunks)")

    actual_size = os.path.getsize(sparse_path)
    print(f"Output: {sparse_path} ({actual_size / 1024 / 1024:.1f} MB, "
          f"{n_chunks} RAW chunks, {total_blks} blocks — all written)")
    print(f"Done: {actual_size / 1024 / 1024:.1f} MB written")


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <raw.img> <sparse.img>")
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
