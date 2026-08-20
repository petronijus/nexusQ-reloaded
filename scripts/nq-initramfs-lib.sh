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

nq_build_cpio() {
    local dev=$1 init_file=$2 files_dir=$3 out=$4
    shift 4
    local extra_tools="$*"

    [ -f "$init_file" ] || { echo "no such init: $init_file" >&2; return 1; }

    local files_b64=""
    if [ "$files_dir" != "-" ]; then
        [ -d "$files_dir" ] || { echo "no such files dir: $files_dir" >&2; return 1; }
        files_b64=$(tar -C "$files_dir" -cf - . | base64 -w0)
    fi
    local init_b64
    init_b64=$(base64 -w0 < "$init_file")

    echo "=== collecting from $dev ===" >&2
    {
        printf 'EXTRA_TOOLS=%s\n'   "'$extra_tools'"
        printf 'FILES_TAR_B64=%s\n' "'$files_b64'"
        printf 'INIT_B64=%s\n'      "'$init_b64'"
        cat "$_NQ_LIB_DIR/initramfs/_remote-collect.sh"
    } | "${NQ_SSH[@]}" "$dev" 'sh -s' > "$out"

    local sz
    sz=$(stat -c %s "$out")
    [ "$sz" -gt 100000 ] || { echo "cpio is only $sz B -- collection failed" >&2; return 1; }
    echo "initramfs: $sz bytes" >&2
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
    python3 "$_NQ_LIB_DIR/../make-bootimg.py" "$tmp/zImage-dtb" "$out" "$cpio" "rescue"
    rm -rf "$tmp"

    local sz cap=8388608
    sz=$(stat -c %s "$out")
    if [ "$sz" -gt "$cap" ]; then
        echo "IMAGE IS $sz B -- the 8 MiB boot/recovery partitions cannot hold it" >&2
        return 1
    fi
    echo "$out: $sz B ($(( (cap - sz) / 1024 )) KiB spare in an 8 MiB slot)" >&2
}
