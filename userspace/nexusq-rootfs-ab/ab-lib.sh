# ab-lib.sh -- the A/B rootfs layout, in one place (nexusq-rootfs-ab, 2026-09-26).
#
# Sourced by the two things that split the eMMC into slot A (p13 "userdata") and
# slot B (p14 "userdata_b"), which must produce the same table byte for byte:
#
#   - nexusq-resize-rootfs (device-google-steelhead), on the first boot after a
#     flash, while slot A is mounted but its ext4 is still only the image's size;
#   - init-split, the maintenance initramfs `nq-rootfs-ab split` boots once on a
#     unit whose ext4 already fills p13, with the rootfs unmounted.
#
# Plain POSIX sh + awk: it runs under the rootfs's busybox and under the
# initramfs's. The layout it computes on this eMMC is the one the Prague unit
# was split to by hand on 2026-08-20: p13 3200000 +13788160, p14 16988160
# +13789151, last usable LBA 30777310.

# TESTABLE:ab_layout
# ab_layout <disk sectors> <slot A start sector>: prints "<A size> <B start>
# <B size> <last usable LBA>" in 512-byte sectors for splitting everything from
# slot A's start to the end of the disk into two slots. The last usable LBA
# leaves the standard 33 sectors for the backup GPT plus its header's own
# sector; slot B starts on a 1 MiB (2048-sector) boundary, rounded down so A is
# never the larger of the two by more than that.
ab_layout() {
	_last=$(( $1 - 34 ))
	_avail=$(( _last - $2 + 1 ))
	_b_start=$(( (($2 + _avail / 2) / 2048) * 2048 ))
	echo "$(( _b_start - $2 )) $_b_start $(( _last - _b_start + 1 )) $_last"
}

# TESTABLE:ab_table
# ab_table <sfdisk -d dump file> <A partition node> <A size> <B node> <B start>
# <B size>: prints the sfdisk script for the split — the dump with slot A's size
# replaced, slot B appended (same type as A, name "userdata_b", fresh UUID), and
# the `last-lba:` header dropped so sfdisk recomputes it from the real disk size
# and writes the backup GPT where it belongs. Every other partition, the label
# id and the partition UUIDs are carried over byte for byte. Fails if slot A is
# not in the dump or slot B already is.
ab_table() {
	awk -v a="$2" -v asz="$3" -v b="$4" -v bst="$5" -v bsz="$6" '
		/^last-lba:/ { next }
		$1 == b      { dup = 1 }
		$1 == a {
			found = 1
			sub(/size= *[0-9]+/, "size=" asz)
			type = ""
			if (match($0, /type=[0-9A-Fa-f-]+/)) type = substr($0, RSTART, RLENGTH)
			print
			next
		}
		{ print }
		END {
			if (!found || dup) exit 1
			printf "%s : start=%s, size=%s, %s, name=\"userdata_b\"\n", b, bst, bsz, type
		}' "$1"
}

# TESTABLE:ab_fits
# ab_fits <minimum blocks> <used blocks> <slot A blocks> <reserve blocks>: prints
# "ok", or why the root ext4 cannot be shrunk into slot A. Two conditions:
#   - resize2fs's own minimum (`resize2fs -P`) must fit -- it refuses otherwise;
#   - what is actually USED (block count - free blocks) plus the reserve must fit,
#     so slot A is not left nearly full.
# The reserve is measured from the used blocks, NOT from the minimum: resize2fs's
# estimate carries its own slack, and the first version, which added the reserve
# to it, turned the cottage unit away -- 1 611 267 blocks minimum for 1 411 685
# used, against 1 723 520 in slot A (2026-09-26, the first automatic attempt).
# nq-rootfs-ab runs this before rebooting into the maintenance image and
# init-split runs it again on the unmounted filesystem, so both judge alike.
ab_fits() {
	if [ "$1" -gt "$3" ]; then
		echo "min$1-over-slot$3"
	elif [ $(( $2 + $4 )) -gt "$3" ]; then
		echo "used$2-plus-reserve$4-over-slot$3"
	else
		echo ok
	fi
}
