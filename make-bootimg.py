#!/usr/bin/env python3
"""Create an Android boot.img (header v0) for the Nexus Q U-Boot.

Replicates the exact header layout of the verified-booting images:
base 0x80000000, kernel_offset 0x8000, tags_offset 0x100, pagesize 2048.
Kernel input is zImage with DTB already appended; ramdisk is optional.

RAMDISK ADDRESS -- measured, not guessed (2026-08-20)
The Android-stock offset for this board is 0x01000000, and using it silently
throws the ramdisk away on our kernel:

    INITRD: 0x81000000+0x001ab000 overlaps in-use memory region
     - disabling initrd

Our mainline kernel is far bigger than the 3.0.8 stock one and its image now
spans past 16 MB -- /proc/iomem on the running device reads

    80008000-80efffff : Kernel code
    81000000-811585cf : Kernel data

so the stock ramdisk address lands inside the kernel's own reserved memory.
The kernel notices, drops the initrd and falls through to root= on p13 -- which
looks exactly like "the bootloader ignored the ramdisk", and was written down as
that for a long time. It does not: U-Boot honours this header field, it just
placed the ramdisk where we told it to.

0x04000000 (= 0x84000000) sits ~40 MB clear of the kernel end and its appended
DTB (reserved to 0x8165ffdc), and far below the lowest carveout (0xaf3f0000),
inside the contiguous 0x80000000-0xafdfffff bank. Ramdisk-less images keep the stock
value, so they stay byte-identical to what is already flashed.
"""
import struct, sys, hashlib

RAMDISK_OFFSET_STOCK = 0x01000000   # Android-stock; INSIDE our kernel -> unusable
RAMDISK_OFFSET_SAFE  = 0x04000000   # see the module docstring before changing this

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
    # Only move the address when a ramdisk is actually present. With size 0 the
    # field is meaningless, so keeping the stock value there leaves every
    # ramdisk-less image byte-identical to the ones already flashed -- which is
    # what `nq-kernel-ota verify-self` compares against.
    rd_off = RAMDISK_OFFSET_SAFE if ramdisk else RAMDISK_OFFSET_STOCK
    hdr = struct.pack('<8s10I16s512s',
        b'ANDROID!',
        len(kernel),  base + 0x00008000,   # kernel size / addr
        len(ramdisk), base + rd_off,        # ramdisk size / addr
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
