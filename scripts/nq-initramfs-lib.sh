# Shared host-side helpers for building Nexus Q initramfs boot images.
#
# Both images this repo builds -- the offline rescue environment and the A/B
# rootfs selector -- need the same things: device binaries with the device's own
# musl, the USB gadget brought up (there is no serial console on this board), and
# an Android boot image packed the way this u-boot wants it. That collection
# logic had four separate bugs in it the first time, each of which produced an
# image that came up as a black box; it exists once, here, so they only ever have
# to be found once.
#
# Usage:
#   . scripts/nq-initramfs-lib.sh
#   nq_build_cpio <dev> <init-file> <files-dir|-> <out.cpio.gz> [device-tool ...]
#   nq_pack_bootimg <dev> <cpio.gz> <out.img>

NQ_SSH=(ssh -o StrictHostKeyChecking=no -o BatchMode=yes)
_NQ_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Build the initramfs by running scripts/make-ab-initramfs.py ON THE DEVICE,
# against its live root. That collector is the same one the image build runs
# against the rootfs it just produced -- one implementation, two places it is
# pointed at, instead of two that drift apart. It parses ELF dynamic sections and
# writes the cpio itself, so it needs no ldd, no cpio and no architecture it can
# execute.
nq_build_cpio() {
    local dev=$1 init_file=$2 files_dir=$3 out=$4
    shift 4
    local extra_tools="$*"

    [ -f "$init_file" ] || { echo "no such init: $init_file" >&2; return 1; }

    local rdir="/tmp/nq-initramfs-build"
    "${NQ_SSH[@]}" "$dev" "rm -rf $rdir && mkdir -p $rdir/extra" || return 1
    scp -q -o StrictHostKeyChecking=no -o BatchMode=yes \
        "$_NQ_LIB_DIR/make-ab-initramfs.py" "$init_file" "$dev:$rdir/" || return 1
    "${NQ_SSH[@]}" "$dev" "mv $rdir/$(basename "$init_file") $rdir/init" || return 1

    if [ "$files_dir" != "-" ]; then
        [ -d "$files_dir" ] || { echo "no such files dir: $files_dir" >&2; return 1; }
        tar -C "$files_dir" -cf - . | "${NQ_SSH[@]}" "$dev" "tar -x -C $rdir/extra" || return 1
    fi

    echo "=== collecting from $dev ===" >&2
    "${NQ_SSH[@]}" "$dev" \
        "python3 $rdir/make-ab-initramfs.py / $rdir/init $rdir/extra $rdir/out.cpio.gz $extra_tools" >&2 \
        || return 1
    "${NQ_SSH[@]}" "$dev" "cat $rdir/out.cpio.gz" > "$out"
    "${NQ_SSH[@]}" "$dev" "rm -rf $rdir"

    local sz
    sz=$(stat -c %s "$out")
    [ "$sz" -gt 100000 ] || { echo "cpio is only $sz B -- collection failed" >&2; return 1; }
}

# The image must carry the kernel the device is actually running, not whatever
# happens to be lying around: /boot/vmlinuz is only right once `nq-kernel-ota
# promote` has reconciled the package database, and for a long time it was not.
nq_pack_bootimg() {
    local dev=$1 cpio=$2 out=$3
    local tmp
    tmp=$(mktemp -d)
    "${NQ_SSH[@]}" "$dev" 'cat /boot/vmlinuz' > "$tmp/vmlinuz"
    "${NQ_SSH[@]}" "$dev" 'cat /boot/omap4-steelhead.dtb 2>/dev/null || cat /boot/dtbs/omap4-steelhead.dtb' > "$tmp/dtb"
    cat "$tmp/vmlinuz" "$tmp/dtb" > "$tmp/zImage-dtb"

    # The kernel's OWN CONFIG_CMDLINE, not a placeholder. CONFIG_CMDLINE_FORCE
    # means the kernel ignores whatever is in this header, so a wrong value here
    # boots perfectly -- and then `nq-kernel-ota verify-self`, which repacks from
    # /boot and compares against the boot slot, reports MISMATCH and looks like a
    # corrupted slot. This field cost exactly that once: images built here
    # carried the literal string "rescue".
    local cmdline
    cmdline=$("${NQ_SSH[@]}" "$dev" \
        "sed -n 's/^CONFIG_CMDLINE=\"\(.*\)\"\$/\1/p' /boot/config | head -1")
    [ -n "$cmdline" ] || { echo "no CONFIG_CMDLINE in the device's /boot/config" >&2; return 1; }

    python3 "$_NQ_LIB_DIR/../make-bootimg.py" "$tmp/zImage-dtb" "$out" "$cpio" "$cmdline"
    rm -rf "$tmp"

    local sz cap=8388608
    sz=$(stat -c %s "$out")
    if [ "$sz" -gt "$cap" ]; then
        echo "IMAGE IS $sz B -- the 8 MiB boot/recovery partitions cannot hold it" >&2
        return 1
    fi
    echo "$out: $sz B ($(( (cap - sz) / 1024 )) KiB spare in an 8 MiB slot)" >&2
}
