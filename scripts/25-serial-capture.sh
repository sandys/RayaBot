#!/usr/bin/env bash
# 25-serial-capture.sh — record the ESP32's serial console for N seconds (a scripted serial monitor).
#
# Usage:
#   scripts/25-serial-capture.sh --reset run --seconds 30            # restart the app and record its boot log
#   scripts/25-serial-capture.sh --seconds 60                        # just listen, no reset
#   scripts/25-serial-capture.sh --reset run --until 'Wifi|WiFi' --seconds 90
#   scripts/25-serial-capture.sh --label after-flash --reset run     # label goes into the file name
#   scripts/25-serial-capture.sh --send 'help' --send-after 8        # type a line into the console
#   scripts/25-serial-capture.sh --quiet ...                         # don't echo, only save
#
# What it does
#   Runs scripts/win/serial-capture.ps1 on Windows against the board's COM port.
#   With --reset run the port is opened first and the chip is then reset through the
#   USB-Serial/JTAG RTS line, so the log starts at the ROM banner ("ESP-ROM:...").
#   This also takes the chip OUT of download mode and starts the installed application.
#
# Files
#   logs/serial/<timestamp>[-label].raw   exact bytes received
#   logs/serial/<timestamp>[-label].log   readable text (ANSI colours stripped)
#   logs/serial/latest.log                copy of the most recent .log
#
# Exit codes: 0 captured, 3 port could not be opened, 4 opened but nothing received.
#
# NOTE this takes the serial port exclusively (see scripts/lib/device.sh); it waits up to
# 60 s for another 2x script to finish.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$XZ_SCRIPTS/lib/device.sh"

main() {
  local seconds=20 reset="none" until="" label="" send="" send_after=5 quiet=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --seconds)    seconds="$2"; shift 2 ;;
      --reset)      reset="$2"; shift 2 ;;
      --until)      until="$2"; shift 2 ;;
      --label)      label="-$2"; shift 2 ;;
      --send)       send="$2"; shift 2 ;;
      --send-after) send_after="$2"; shift 2 ;;
      --quiet)      quiet=1; shift ;;
      -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
  [[ "$reset" == "run" || "$reset" == "none" ]] || die "--reset must be 'run' or 'none'"

  xz_load_device
  xz_port_lock

  local dir="$XZ_LOGS/serial"
  mkdir -p "$dir"
  local base; base="$dir/$(date +%Y%m%d-%H%M%S)${label}"
  local raw="$base.raw" txt="$base.log"
  : > "$raw"

  local args=(-Port "$XZ_PORT" -Seconds "$seconds" -OutFile "$(win_path "$raw")" -Reset "$reset")
  [[ -n "$until" ]] && args+=(-Until "$until")
  [[ -n "$send"  ]] && args+=(-Send "$send" -SendAfter "$send_after")
  [[ $quiet -eq 1 ]] && args+=(-Quiet)

  log "capturing $XZ_PORT for up to ${seconds}s (reset=$reset) -> $raw"
  local rc=0
  win_ps "$XZ_SCRIPTS/win/serial-capture.ps1" "${args[@]}" || rc=$?

  # Readable copy: strip ANSI colour sequences and carriage returns.
  sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r$//' "$raw" > "$txt"
  cp -f "$txt" "$dir/latest.log"
  log "saved: $txt ($(wc -l < "$txt") lines, $(stat -c %s "$raw") bytes raw)"
  return $rc
}

xz_run_logged serial-capture main "$@"
