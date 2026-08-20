# Runs ON THE DEVICE, emits a gzipped cpio on stdout.
#
# The tools come from the device rather than being cross-built, so the image
# runs the same musl, the same ABI and the same binaries as the system it will
# operate on. Inputs arrive as environment assignments prepended by the caller:
#   EXTRA_TOOLS    absolute paths of device binaries to include in /sbin
#   FILES_TAR_B64  base64 of a tar of HOST files to unpack into the image
#   INIT_B64       base64 of the /init to install
set -eu
R=$(mktemp -d)
# NB: no brace expansion -- the device shell is busybox ash, which does not do it
for d in bin sbin usr/bin usr/sbin lib proc sys dev tmp mnt etc newroot; do
    mkdir -p "$R/$d"
done

# busybox first: it provides the shell and ~everything else via applets.
# NB: `printf` must be in this list. It is NOT an ash builtin in Alpine's
# busybox, so a script using it under `set -e` exits silently -- which is how
# nq-slot's record writer failed the first time this image was tested.
cp /usr/bin/busybox "$R/bin/busybox"
for a in sh ash mount umount ls cat echo sleep dmesg mkdir ln rm cp dd sync \
         ip ifconfig hostname poweroff reboot mknod grep sed awk tr \
         head tail md5sum stat find df seq touch chmod wc cut mktemp \
         switch_root pivot_root blkid dirname basename readlink uname \
         printf test true false env expr; do
    ln -sf /bin/busybox "$R/bin/$a"
done

# telnetd is NOT a busybox applet on Alpine -- it ships in busybox-extras, and
# `busybox --list` confirms it. Linking telnetd to /bin/busybox produces an
# image that comes up with no way into it at all.
cp /usr/bin/busybox-extras "$R/bin/busybox-extras"
ln -sf /bin/busybox-extras "$R/bin/telnetd"

for t in ${EXTRA_TOOLS:-}; do
    [ -x "$t" ] && cp "$t" "$R/sbin/" || true
done

# every shared library those binaries need, resolved by the device's own loader
for b in "$R"/sbin/* /usr/bin/busybox /usr/bin/busybox-extras; do
    [ -f "$b" ] || continue
    ldd "$b" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}'
done | sort -u | while read -r lib; do
    [ -f "$lib" ] || continue
    mkdir -p "$R$(dirname "$lib")"
    cp -n "$lib" "$R$lib" 2>/dev/null || true
done

# The musl loader, plus the libc symlinks that point AT it. ldd prints
#     /lib/ld-musl-armhf.so.1 (0x...)
#     libc.musl-armv7.so.1 => /lib/ld-musl-armhf.so.1 (0x...)
# and the loop above only sees the first form, so the name every binary actually
# records in its NEEDED entry would be missing from the image.
for l in /lib/ld-musl-*.so.1; do [ -f "$l" ] && cp -n "$l" "$R/lib/" || true; done
for l in /lib/libc.musl-*.so.1; do
    [ -e "$l" ] || continue
    cp -a "$l" "$R/lib/" 2>/dev/null \
        || ln -sf "$(basename "$(readlink -f "$l")")" "$R/lib/$(basename "$l")"
done

if [ -n "${FILES_TAR_B64:-}" ]; then
    printf '%s' "$FILES_TAR_B64" | base64 -d | tar -x -C "$R"
fi

printf '%s' "$INIT_B64" | base64 -d > "$R/init"
chmod +x "$R/init"
ln -sf /init "$R/sbin/init"
find "$R" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
find "$R/bin" "$R/sbin" -maxdepth 1 -type f -exec chmod +x {} + 2>/dev/null || true

( cd "$R" && find . | cpio -o -H newc 2>/dev/null | gzip -9 )
rm -rf "$R"
