#!/usr/bin/env bash
# 02-list-usb.sh — find the ESP32 on the Windows host's USB bus. (run from WSL)
#
# Usage:
#   scripts/02-list-usb.sh              # present USB devices + COM ports + verdict
#   scripts/02-list-usb.sh --all        # also devices Windows remembers but that are unplugged
#   scripts/02-list-usb.sh --watch 30   # print hot-plug arrivals/removals for 30 s
#
# Read-only. Runs scripts/win/list-usb.ps1 on Windows. Known ESP32 identities
# (Espressif 303A:*, CH340/CH343/CH9102, CP210x, FTDI) are flagged with "<--"
# and the COM port they got is printed — that COM port is what every later
# script (esptool, serial monitor) needs.
#
# If nothing is flagged, the verdict section prints a checklist (data cable,
# power switch, BOOT button). A device stuck at "VID_0000&PID_0002" means the
# cable/port is electrically connected but enumeration fails.
# Output is also saved to logs/<timestamp>-list-usb.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)   args+=(-All); shift ;;
      --watch) [[ $# -ge 2 ]] || die "--watch needs a number of seconds"; args+=(-Watch "$2"); shift 2 ;;
      -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
  win_ps "$XZ_SCRIPTS/win/list-usb.ps1" "${args[@]}"
}

xz_run_logged list-usb main "$@"
