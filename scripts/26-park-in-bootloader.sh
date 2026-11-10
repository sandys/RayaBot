#!/usr/bin/env bash
# 26-park-in-bootloader.sh — stop the application and hold the chip in ROM download mode.
#
# Usage:  scripts/26-park-in-bootloader.sh
#
# Why
#   The stock firmware for this board powers itself down (GPIO3 low + deep sleep) after
#   ~290 s of idling when it thinks it is not charging. A sleeping chip disappears from
#   USB and can only be woken by hand. In download mode no application runs, so the
#   board stays on the bus indefinitely — the safe place to leave it between steps of
#   an unattended session. The display goes dark and the speaker is silent while parked.
#
# How
#   esptool resets the chip into the bootloader through the USB-Serial/JTAG control
#   lines (no BOOT button), reads the MAC as a liveness check, and exits with
#   --after no-reset. Nothing is written.
#
# To leave the bootloader again: scripts/25-serial-capture.sh --reset run   (or unplug/replug).
# Output is also saved to logs/<timestamp>-park-in-bootloader.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$XZ_SCRIPTS/lib/device.sh"

main() {
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0; }
  xz_load_device
  xz_port_lock
  local out; out="$(xz_esptool --after no-reset read-mac)" || { printf '%s\n' "$out"; die "could not reach the bootloader on $XZ_PORT"; }
  printf '%s\n' "$out" | grep -E 'Chip type|MAC:|Staying' | sort -u | sed 's/^/  /'
  grep -q 'Staying in bootloader' <<<"$out" || die "esptool did not confirm 'Staying in bootloader'"
  log "parked: $XZ_PORT is in download mode"
}

xz_run_logged park-in-bootloader main "$@"
