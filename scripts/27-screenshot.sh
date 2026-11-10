#!/usr/bin/env bash
# 27-screenshot.sh — get pictures of what the device is drawing on its LCD, over serial.
#
# Usage:
#   scripts/27-screenshot.sh --reset run                 # restart the app, save the first screenshot
#   scripts/27-screenshot.sh --reset run --count 3       # wait for three screenshots
#   scripts/27-screenshot.sh --count 1 --seconds 40      # no reset: wait for the next periodic one
#   scripts/27-screenshot.sh --label wifi-config --reset run
#
# Needs the DEV firmware build (Kconfig XZ_DEV_SERIAL_SCREENSHOT=y; patches/xz-dev-tools.patch,
# docs/build.md "Local changes to the firmware"):
# it snapshots the active LVGL screen, JPEG-encodes it and prints it base64-encoded on the
# console between "XZSHOT BEGIN" / "XZSHOT END" markers a few seconds after boot and then
# periodically. Stock firmware prints no such blocks and this script will report none found.
#
# What it does
#   1. scripts/25-serial-capture.sh records the console until --count END markers were seen
#      (or --seconds ran out)
#   2. scripts/py/extract_screenshots.py reassembles each block, checks length + CRC-32 and
#      writes logs/screens/<timestamp>[-label]-NN.jpg
#   3. prints the image paths (open them in any viewer; they are 240x240)
#
# What a screenshot proves — and does not
#   It is the frame LVGL rendered, i.e. what the firmware sends to the panel. It does not
#   prove the glass is lit: backlight and panel wiring are checked separately (boot log:
#   "gc9a01: LCD panel create success", "Backlight: Set brightness to …").
#
# Exit codes: 0 at least one valid screenshot written, 1 none.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local count=1 seconds=45 reset="none" label=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --count)   count="$2"; shift 2 ;;
      --seconds) seconds="$2"; shift 2 ;;
      --reset)   reset="$2"; shift 2 ;;
      --label)   label="$2"; shift 2 ;;
      -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done

  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local cap_label="shot${label:+-$label}"
  # (?s) lets '.' cross newlines: stop once <count> END markers have arrived.
  local until="(?s)(XZSHOT END.*){$count}"

  local rc=0
  "$XZ_SCRIPTS/25-serial-capture.sh" --quiet --reset "$reset" --seconds "$seconds" \
      --until "$until" --label "$cap_label" || rc=$?
  [[ $rc -eq 0 || $rc -eq 4 ]] || die "serial capture failed (exit $rc)"

  local cap="$XZ_LOGS/serial/latest.log"
  [[ -s "$cap" ]] || die "capture is empty: the device printed nothing"

  local outdir="$XZ_LOGS/screens"
  echo "=== screenshots ==="
  local erc=0
  python3 "$XZ_SCRIPTS/py/extract_screenshots.py" "$cap" --out-dir "$outdir" \
      --prefix "${stamp}${label:+-$label}" || erc=$?
  if [[ $erc -ne 0 ]]; then
    warn "no valid screenshot in the capture (is the dev firmware flashed?)"
    echo "--- last console lines ---"
    tail -15 "$cap"
  fi
  return $erc
}

xz_run_logged screenshot main "$@"
