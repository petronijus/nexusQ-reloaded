---
paths:
  - "kernel/**"
  - "pmos/linux-google-steelhead/**"
---
# Kernel

- The DTS ships through a patch: edit `kernel/dts/`, then regenerate the patch
  with `scripts/regen-dts-patch.sh`. Other patches come from the git patch
  stack (`git format-patch`); a hand edit breaks hunk headers easily.
- Every patch must apply with GNU `patch` on a pristine tree (abuild uses it,
  not `git apply`), and must be listed in `source=` of
  `pmos/linux-google-steelhead/APKBUILD`.
- Before building a fix, compare with the stock kernel (`reverse-eng/`, the
  stock-parity-auditor agent). Keep fixes that match stock even while the
  symptom is still open.
- `=m` modules live in the rootfs: a boot.img-only flash does not update them.
  The boot image stays ramdisk-less and under the 8 MB boot partition.
