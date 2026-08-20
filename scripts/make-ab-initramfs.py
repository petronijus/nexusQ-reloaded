#!/usr/bin/env python3
"""Build a Nexus Q initramfs from a rootfs TREE.

The tree can be a live root (`/`, running on the device) or the rootfs chroot the
build produces -- same code either way, which is the point: the image the build
ships and the image built from a running device come out of one implementation
instead of two that drift.

Why not ldd + cpio + gzip: the build resolves this inside a container where the
target binaries are armv7 and cannot be executed, and where cpio may not be
installed at all. So the ELF dynamic section is parsed directly and the cpio is
written here. No external tools, no architecture assumptions, no shelling out.

    make-ab-initramfs.py <rootfs> <init-file> <extra-dir|-> <out.cpio.gz> [bin ...]

`bin` entries are paths INSIDE the rootfs (e.g. /usr/sbin/e2fsck); their shared
libraries are resolved recursively and copied along with them.
"""
import gzip, os, stat, struct, sys

# Every applet the two inits and the tools they carry actually reach for.
# NB: `printf` must be here. It is NOT an ash builtin in Alpine's busybox, so a
# script using it under `set -e` exits silently -- which is exactly how nq-slot's
# record writer failed the first time this image was tested.
APPLETS = """sh ash mount umount ls cat echo sleep dmesg mkdir ln rm cp dd sync
ip ifconfig hostname poweroff reboot mknod grep sed awk tr head tail md5sum stat
find df seq touch chmod wc cut mktemp switch_root pivot_root blkid dirname
basename readlink uname printf test true false env expr""".split()

# telnetd is NOT a busybox applet on Alpine -- it ships in busybox-extras.
# Linking it to busybox produces an image with no way into it at all, on a board
# with no serial console.
EXTRAS_APPLETS = ["telnetd"]


def elf_needed(path):
    """DT_NEEDED names from an ELF file, or [] if it is not one."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF":
        return []
    is64, little = data[4] == 2, data[5] == 1
    end = "<" if little else ">"
    if is64:
        e_shoff, = struct.unpack_from(end + "Q", data, 0x28)
        e_shentsize, e_shnum = struct.unpack_from(end + "HH", data, 0x3A)
    else:
        e_shoff, = struct.unpack_from(end + "I", data, 0x20)
        e_shentsize, e_shnum = struct.unpack_from(end + "HH", data, 0x2E)

    dyn = strtab = None
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh_type, = struct.unpack_from(end + "I", data, off + 4)
        if is64:
            sh_offset, sh_size = struct.unpack_from(end + "QQ", data, off + 0x18)
            sh_link, = struct.unpack_from(end + "I", data, off + 0x28)
        else:
            sh_offset, sh_size = struct.unpack_from(end + "II", data, off + 0x10)
            sh_link, = struct.unpack_from(end + "I", data, off + 0x18)
        if sh_type == 6:                      # SHT_DYNAMIC
            dyn = (sh_offset, sh_size, sh_link)
    if dyn is None:
        return []
    off, size, link = dyn
    loff = e_shoff + link * e_shentsize
    if is64:
        str_off, = struct.unpack_from(end + "Q", data, loff + 0x18)
    else:
        str_off, = struct.unpack_from(end + "I", data, loff + 0x10)

    needed, step = [], 16 if is64 else 8
    for p in range(off, off + size, step):
        if is64:
            d_tag, d_val = struct.unpack_from(end + "qQ", data, p)
        else:
            d_tag, d_val = struct.unpack_from(end + "iI", data, p)
        if d_tag == 0:                        # DT_NULL
            break
        if d_tag == 1:                        # DT_NEEDED
            s = data.index(b"\0", str_off + d_val)
            needed.append(data[str_off + d_val:s].decode())
    return needed


class Image:
    """Files staged for the archive: path -> (mode, payload)."""

    def __init__(self, root):
        self.root = root
        self.entries = {}

    def _real(self, p):
        return os.path.join(self.root, p.lstrip("/"))

    def dir(self, path, mode=0o755):
        self.entries.setdefault(path, (stat.S_IFDIR | mode, b""))

    def symlink(self, path, target):
        self.entries[path] = (stat.S_IFLNK | 0o777, target.encode())

    def file(self, path, data, mode=0o644):
        self.entries[path] = (stat.S_IFREG | mode, data)

    def copy(self, src_in_root, dest=None, mode=None):
        """Copy a file out of the rootfs, following symlinks, keeping its mode."""
        real = self._real(src_in_root)
        if not os.path.exists(real):
            return False
        dest = dest or src_in_root
        st = os.stat(real)
        with open(real, "rb") as f:
            self.file(dest, f.read(), mode if mode is not None else (st.st_mode & 0o777))
        return True

    def copy_lib(self, libpath):
        """Copy a library, PRESERVING it if it is a symlink.

        /lib/libc.musl-armv7.so.1 is a symlink to ld-musl-armhf.so.1. Copying it
        as a plain file works, but it puts the same half-megabyte in the image
        twice -- which matters when the whole thing has to fit an 8 MiB slot next
        to a 5.5 MB kernel. Keep the link, and make sure its target is there.
        """
        real = self._real(libpath)
        if not os.path.lexists(real):
            return
        if os.path.islink(real):
            target = os.readlink(real)
            self.symlink(libpath, target)
            resolved = target if target.startswith("/") else os.path.normpath(
                os.path.join(os.path.dirname(libpath), target))
            self.copy(resolved, resolved, 0o755)
        else:
            self.copy(libpath, libpath, 0o755)

    def copy_with_libs(self, src_in_root, dest_dir="/lib"):
        """Copy a binary and, recursively, every library it names."""
        if not self.copy(src_in_root):
            return False
        pending, seen = list(elf_needed(self._real(src_in_root))), set()
        while pending:
            soname = pending.pop()
            if soname in seen:
                continue
            seen.add(soname)
            for d in ("/lib", "/usr/lib"):
                cand = os.path.join(d, soname)
                if os.path.lexists(self._real(cand)):
                    self.copy_lib(cand)
                    pending += elf_needed(os.path.realpath(self._real(cand)))
                    break
        return True


def write_cpio(entries, out_path):
    """newc archive, gzipped. Written here so the build needs no cpio binary."""
    blobs = []
    ino = 1
    for path in sorted(entries):
        mode, payload = entries[path]
        name = ("." + path).encode() + b"\0"
        hdr = b"070701" + b"".join(
            b"%08x" % v for v in (
                ino, mode, 0, 0, 1, 0, len(payload), 0, 0, 0, 0, len(name), 0))
        blobs.append(hdr + name)
        blobs.append(b"\0" * (-len(hdr + name) % 4))
        blobs.append(payload)
        blobs.append(b"\0" * (-len(payload) % 4))
        ino += 1
    name = b"TRAILER!!!\0"
    hdr = b"070701" + b"".join(b"%08x" % v for v in
                               (ino, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, len(name), 0))
    blobs.append(hdr + name)
    blobs.append(b"\0" * (-len(hdr + name) % 4))
    raw = b"".join(blobs)
    with gzip.GzipFile(out_path, "wb", compresslevel=9, mtime=0) as g:
        g.write(raw)
    return len(raw)


def main():
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    root, init_file, extra_dir, out = sys.argv[1:5]
    extra_bins = sys.argv[5:]

    img = Image(root)
    for d in ("/bin", "/sbin", "/usr", "/usr/bin", "/usr/sbin", "/lib",
              "/proc", "/sys", "/dev", "/tmp", "/mnt", "/etc", "/newroot"):
        img.dir(d)

    busybox = next((p for p in ("/usr/bin/busybox", "/bin/busybox")
                    if os.path.exists(img._real(p))), None)
    if not busybox:
        sys.exit(f"no busybox in {root}")
    img.copy_with_libs(busybox)
    _, payload = img.entries.pop(busybox)
    img.file("/bin/busybox", payload, 0o755)
    for a in APPLETS:
        img.symlink(f"/bin/{a}", "/bin/busybox")

    extras = "/usr/bin/busybox-extras"
    if img.copy(extras, "/bin/busybox-extras", 0o755):
        for a in EXTRAS_APPLETS:
            img.symlink(f"/bin/{a}", "/bin/busybox-extras")
    else:
        sys.exit("busybox-extras is missing -- the image would have no telnetd, "
                 "and this board has no serial console")

    # The musl loader plus the libc symlink names binaries actually record in
    # their NEEDED entries -- ld-musl-armhf.so.1 is the interpreter, but every
    # binary asks for libc.musl-armv7.so.1.
    libdir = os.path.join(root, "lib")
    if os.path.isdir(libdir):
        for f in os.listdir(libdir):
            if f.startswith("ld-musl-") or f.startswith("libc.musl-"):
                img.copy_lib(f"/lib/{f}")

    # Missing is fatal, not a warning. An image silently built without the tool
    # it was asked for is a defect that only shows up as wrong behaviour later:
    # without nq-slot the A/B initramfs falls back to slot A for ever, and that
    # looks exactly like a normal, healthy boot.
    for b in extra_bins:
        if not img.copy_with_libs(b):
            sys.exit(f"ERROR: {b} is not in {root} — refusing to build an "
                     f"initramfs that is missing a tool it was asked for")

    if extra_dir != "-":
        for dirpath, _, files in os.walk(extra_dir):
            for f in files:
                full = os.path.join(dirpath, f)
                rel = "/" + os.path.relpath(full, extra_dir)
                with open(full, "rb") as fh:
                    img.file(rel, fh.read(), 0o755 if os.access(full, os.X_OK) else 0o644)
                img.dir(os.path.dirname(rel))

    with open(init_file, "rb") as f:
        img.file("/init", f.read(), 0o755)
    img.symlink("/sbin/init", "/init")

    raw = write_cpio(img.entries, out)
    print(f"  initramfs: {len(img.entries)} entries, {raw} B raw, "
          f"{os.path.getsize(out)} B gzipped -> {out}")


if __name__ == "__main__":
    main()
