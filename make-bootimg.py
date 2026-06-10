#!/usr/bin/env python3
"""Create an Android boot.img (header v0) for the Nexus Q U-Boot.

Replicates the exact header layout of the verified-booting images:
base 0x80000000, kernel_offset 0x8000, ramdisk_offset 0x1000000,
tags_offset 0x100, pagesize 2048. Kernel input is zImage with DTB
already appended; ramdisk is optional (embedded initramfs preferred,
U-Boot ignores the ramdisk section on partition boot anyway).
"""
import struct, sys, hashlib

def pad(data, pagesize=2048):
    rem = len(data) % pagesize
    return data + b'\x00' * (pagesize - rem) if rem else data

def main():
    if len(sys.argv) < 3:
        sys.exit("usage: make-bootimg.py <zImage-dtb> <out.img> [ramdisk] [cmdline]")
    kernel = open(sys.argv[1], 'rb').read()
    ramdisk = open(sys.argv[3], 'rb').read() if len(sys.argv) > 3 and sys.argv[3] != '-' else b''
    cmdline = (sys.argv[4] if len(sys.argv) > 4 else '').encode()

    base = 0x80000000
    hdr = struct.pack('<8s10I16s512s',
        b'ANDROID!',
        len(kernel),  base + 0x00008000,   # kernel size / addr
        len(ramdisk), base + 0x01000000,   # ramdisk size / addr
        0,            base + 0x00f00000,   # second size / addr
        base + 0x00000100,                 # tags addr
        2048, 0, 0,                        # pagesize, unused, unused
        b'',                               # board name
        cmdline.ljust(512, b'\x00'))
    sha = hashlib.sha1()
    for blob in (kernel, struct.pack('<I', len(kernel)),
                 ramdisk, struct.pack('<I', len(ramdisk)),
                 b'', struct.pack('<I', 0)):
        sha.update(blob)
    full_hdr = hdr + sha.digest().ljust(32, b'\x00')
    out = pad(full_hdr) + pad(kernel) + (pad(ramdisk) if ramdisk else b'')
    open(sys.argv[2], 'wb').write(out)
    print(f"{sys.argv[2]}: total {len(out)} bytes, kernel {len(kernel)}, ramdisk {len(ramdisk)}")
    if len(out) > 8 * 1024 * 1024:
        sys.exit("ERROR: image exceeds 8 MB boot partition!")

if __name__ == '__main__':
    main()
