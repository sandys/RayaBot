#!/usr/bin/env bash
# 33-crosscheck-idf-tools.sh — check our flash-image parsers against Espressif's own tools. No device.
#
# Usage:
#   scripts/33-crosscheck-idf-tools.sh <image.bin>         # partition table, bootloader, apps, synthetic NVS
#   scripts/33-crosscheck-idf-tools.sh <image.bin> --nvs   # ... plus the image's own NVS partition (see PRIVACY)
#
# Why
#   scripts/30-analyze-flash-image.sh and scripts/32-compare-images.sh use our own parsers
#   (scripts/py/espflash.py, Python standard library only, nothing installed on the host).
#   This script is the proof that those parsers agree with the reference implementations:
#   it feeds the same bytes to Espressif's tools and compares the answers fact by fact.
#
# What runs where
#   host       scripts/py/crosscheck_idf.py prepare: cuts <image.bin> into partition table,
#              bootloader region and app partitions; writes two NVS test vectors as CSV
#   container  scripts/container/flash-crosscheck.sh, inside the pinned ESP-IDF image the builds
#              use (scripts/lib/idf-docker.sh, scripts/13-idf-image.sh --pull if it is missing):
#                gen_esp32part.py       binary partition table -> CSV, verifies its MD5
#                esptool image-info     header, segments, checksum, SHA-256, descriptors
#                nvs_partition_gen      builds NVS images (format v2 and legacy v1) from the CSVs
#                nvs_tool.py            decodes NVS partitions to JSON
#   host       scripts/py/crosscheck_idf.py compare: MATCH / MISMATCH for every fact
#   The exchange directory is cache/idf-home/flash-crosscheck (= /home/builder/flash-crosscheck
#   in the container); it is private (mode 700) and removed when the script exits.
#
# PRIVACY
#   Without --nvs nothing secret leaves the image: only firmware regions and synthetic NVS data
#   are processed. With --nvs the image's NVS partition (it holds the WiFi password) is copied
#   into the exchange directory for the duration of the run so that nvs_tool.py can read it.
#   Its values are compared inside crosscheck_idf.py and are never printed or logged - the
#   report lists key names and MATCH/MISMATCH only.
#
# Exit status: 0 = everything matches · 4 = a mismatch or a failing tool · 1 = could not run.
# Output is also saved to logs/<timestamp>-crosscheck-idf-tools.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$XZ_SCRIPTS/lib/idf-docker.sh"

WORK_NAME="flash-crosscheck"

main() {
  local image="" pyargs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --nvs) pyargs+=(--nvs); shift ;;
      -h|--help) sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      -*) die "unknown argument: $1 (try --help)" ;;
      *)  [[ -z "$image" ]] || die "only one image at a time"; image="$1"; shift ;;
    esac
  done
  [[ -n "$image" ]] || die "usage: scripts/33-crosscheck-idf-tools.sh <image.bin> [--nvs]"
  [[ -f "$image" && -r "$image" ]] || die "no such readable file: $image"
  xz_idf_image_check

  # One run at a time: the exchange directory has a fixed name so that a leftover of a killed
  # run (which may hold an NVS copy) is always removed by the next start.
  mkdir -p "$XZ_ROOT/state" "$XZ_IDF_HOME"
  exec 7>"$XZ_ROOT/state/flash-crosscheck.lock"
  flock -n 7 || die "another cross-check is running (state/flash-crosscheck.lock is held)"
  local work="$XZ_IDF_HOME/$WORK_NAME"
  rm -rf "$work"
  trap 'rm -rf "$XZ_IDF_HOME/$WORK_NAME"' EXIT
  mkdir -m 700 "$work"

  echo "=== preparing $(basename "$image") ==="
  python3 -I -B "$XZ_SCRIPTS/py/crosscheck_idf.py" prepare "$image" "$work" \
    --container-dir "/home/builder/$WORK_NAME" "${pyargs[@]}" || die "could not prepare the cross-check"

  echo
  echo "=== running Espressif's tools in $XZ_IDF_IMAGE ==="
  local out rc=0
  out="$(xz_idf_run bash /xz/container/flash-crosscheck.sh "/home/builder/$WORK_NAME" 2>&1)" || rc=$?
  grep -E '^(ran:|flash-crosscheck:)' <<<"$out" | sed 's/^/  /' || true
  [[ $rc -eq 0 ]] || { tail -5 <<<"$out" >&2; die "the container run failed (exit $rc)"; }

  echo
  python3 -I -B "$XZ_SCRIPTS/py/crosscheck_idf.py" compare "$image" "$work" "${pyargs[@]}"
}

xz_run_logged crosscheck-idf-tools main "$@"
