#!/usr/bin/env bash
# 32-compare-images.sh — compare two raw flash images partition by partition. Read-only, no device.
#
# Usage:
#   scripts/32-compare-images.sh <a.bin> <b.bin>
#
#   <a.bin>  the reference; its partition table defines the regions (it must start at flash
#            offset 0 and contain a partition table, e.g. the merged-binary.bin that was written)
#   <b.bin>  the image to check against it (e.g. a read-back from scripts/22-backup-flash.sh)
#
# Why
#   After flashing, read the flash back and compare it with what was written: a whole-file
#   diff is useless (the dump is 16 MB, the written image shorter, and NVS changes as soon as
#   the firmware runs), but "bootloader identical, ota_0 identical, nvs differs" answers the
#   question. It also shows what an OTA update or a restore changed between two dumps.
#
# What it prints, per region (bootloader area, partition-table sector, every partition of A,
# unallocated gaps, space after the last partition):
#   identical             all bytes present in both files are equal
#   DIFFERS               absolute offset of the first difference (+ offset inside the region),
#                         number of differing bytes and 4 KiB sectors; for app partitions the
#                         app descriptor (project, version, build time) of both sides
#   beyond end of file    the region is not inside A and/or B; if only one file has it, whether
#                         that part is blank (0xFF) or holds data
#   A region that is only partly inside the shorter file is compared over the common part.
#   nvs / otadata differences are flagged as "expected after the device has run".
#
# Exit status: 0 = no differences in what could be compared · 2 = differences found ·
# 1 = could not run (unreadable file, or <a.bin> has no partition table).
# No image contents are printed (offsets and counts only), so the log is safe to keep.
# Output is also saved to logs/<timestamp>-compare-images.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local files=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      -*) die "unknown argument: $1 (try --help)" ;;
      *)  files+=("$1"); shift ;;
    esac
  done
  [[ ${#files[@]} -eq 2 ]] || die "usage: scripts/32-compare-images.sh <a.bin> <b.bin>"
  local f
  for f in "${files[@]}"; do
    [[ -f "$f" && -r "$f" ]] || die "no such readable file: $f"
  done
  python3 -I -B "$XZ_SCRIPTS/py/compare_images.py" "${files[0]}" "${files[1]}"
}

xz_run_logged compare-images main "$@"
