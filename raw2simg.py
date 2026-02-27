"""Convert a raw ext4 image to Android sparse format using only RAW and DONT_CARE
chunks (compatible with old U-Boot fastboot implementations that don't support
FILL chunks)."""

import struct
import sys
import os

SPARSE_HEADER_MAGIC = 0xED26FF3A
CHUNK_TYPE_RAW = 0xCAC1
CHUNK_TYPE_DONT_CARE = 0xCAC3

FILE_HDR_SZ = 28
CHUNK_HDR_SZ = 12
BLK_SZ = 4096

ZERO_BLOCK = b'\x00' * BLK_SZ


def convert(raw_path, sparse_path):
    raw_size = os.path.getsize(raw_path)
    total_blks = raw_size // BLK_SZ
    if raw_size % BLK_SZ != 0:
        print(f"WARNING: image size {raw_size} not aligned to {BLK_SZ}, truncating")
        total_blks = raw_size // BLK_SZ

    print(f"Input:  {raw_path} ({raw_size / 1024 / 1024:.1f} MB, {total_blks} blocks)")

    chunks = []
    with open(raw_path, 'rb') as f:
        current_type = None
        current_start = 0
        current_count = 0
        raw_data_ranges = []

        for i in range(total_blks):
            block = f.read(BLK_SZ)
            is_zero = (block == ZERO_BLOCK)
            block_type = CHUNK_TYPE_DONT_CARE if is_zero else CHUNK_TYPE_RAW

            if block_type == current_type:
                current_count += 1
            else:
                if current_type is not None:
                    chunks.append((current_type, current_start, current_count))
                current_type = block_type
                current_start = i
                current_count = 1

            if i % 10000 == 0 and i > 0:
                pct = i * 100 // total_blks
                print(f"  Scanning: {pct}% ({i}/{total_blks} blocks, {len(chunks)} chunks so far)")

        if current_type is not None:
            chunks.append((current_type, current_start, current_count))

    raw_chunks = sum(1 for t, _, _ in chunks if t == CHUNK_TYPE_RAW)
    dc_chunks = sum(1 for t, _, _ in chunks if t == CHUNK_TYPE_DONT_CARE)
    raw_blocks = sum(c for t, _, c in chunks if t == CHUNK_TYPE_RAW)
    dc_blocks = sum(c for t, _, c in chunks if t == CHUNK_TYPE_DONT_CARE)

    sparse_size = FILE_HDR_SZ + len(chunks) * CHUNK_HDR_SZ + raw_blocks * BLK_SZ
    print(f"Chunks: {len(chunks)} total ({raw_chunks} RAW, {dc_chunks} DONT_CARE)")
    print(f"Blocks: {raw_blocks} data + {dc_blocks} empty = {total_blks} total")
    print(f"Output: {sparse_path} ({sparse_size / 1024 / 1024:.1f} MB, "
          f"{100 - raw_blocks * 100 / total_blks:.0f}% compression)")

    with open(sparse_path, 'wb') as out:
        header = struct.pack('<IHHHHIIII',
                             SPARSE_HEADER_MAGIC,
                             1, 0,
                             FILE_HDR_SZ,
                             CHUNK_HDR_SZ,
                             BLK_SZ,
                             total_blks,
                             len(chunks),
                             0)
        out.write(header)

        with open(raw_path, 'rb') as inp:
            for chunk_type, start, count in chunks:
                if chunk_type == CHUNK_TYPE_RAW:
                    total_sz = CHUNK_HDR_SZ + count * BLK_SZ
                    chunk_hdr = struct.pack('<HHII', chunk_type, 0, count, total_sz)
                    out.write(chunk_hdr)
                    inp.seek(start * BLK_SZ)
                    remaining = count * BLK_SZ
                    while remaining > 0:
                        read_sz = min(remaining, 1024 * 1024)
                        out.write(inp.read(read_sz))
                        remaining -= read_sz
                else:
                    chunk_hdr = struct.pack('<HHII', chunk_type, 0, count, CHUNK_HDR_SZ)
                    out.write(chunk_hdr)

    actual_size = os.path.getsize(sparse_path)
    print(f"Done: {actual_size / 1024 / 1024:.1f} MB written")


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <raw.img> <sparse.img>")
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
