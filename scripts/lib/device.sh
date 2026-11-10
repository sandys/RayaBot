#!/usr/bin/env bash
# scripts/lib/device.sh — helpers for scripts that talk to the ESP32 (the 2x range).
#
# Source it after common.sh:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#     source "$XZ_SCRIPTS/lib/device.sh"
#
# What it gives you
#   xz_load_device        load state/device.env + state/esptool.env; sets XZ_PORT, XZ_ESPTOOL
#                         (an XZ_PORT already in the environment wins: XZ_PORT=COM7 scripts/21-...)
#   xz_port_lock          take the exclusive lock on the serial port for the rest of the script;
#                         a second script that wants the port waits up to 60 s, then fails
#   xz_esptool <args...>  run the Windows esptool.exe as: esptool --port $XZ_PORT <args...>
#   xz_port_present       0 if $XZ_PORT currently exists on Windows (cheap registry check)
#
# Background
#   The board is a Windows COM port. esptool.exe is a Windows program started through WSL
#   interop, so any file path handed to it must be a Windows path: use win_path from common.sh.
#   Only one program can have a COM port open; the lock stops two of our scripts colliding.

xz_load_device() {
  local env_port="${XZ_PORT:-}"
  [[ -f "$XZ_ROOT/state/device.env" ]]  && source "$XZ_ROOT/state/device.env"
  [[ -f "$XZ_ROOT/state/esptool.env" ]] && source "$XZ_ROOT/state/esptool.env"
  [[ -n "$env_port" ]] && XZ_PORT="$env_port"
  [[ -n "${XZ_PORT:-}" ]]    || die "no serial port known: run scripts/03-wait-for-device.sh or set XZ_PORT=COMx"
  [[ -x "${XZ_ESPTOOL:-}" ]] || die "esptool.exe not installed: run scripts/20-setup-esptool.sh"
  export XZ_PORT XZ_ESPTOOL
}

xz_port_lock() {
  mkdir -p "$XZ_ROOT/state"
  exec 9>"$XZ_ROOT/state/port.lock"
  if ! flock -w 60 9; then
    die "serial port is in use by another script (state/port.lock held for >60 s)"
  fi
}

xz_port_present() {
  ( cd /mnt/c && reg.exe query 'HKLM\HARDWARE\DEVICEMAP\SERIALCOMM' 2>/dev/null ) | tr -d '\r' | grep -qE "[[:space:]]${XZ_PORT}\$"
}

xz_esptool() {
  # stdin is detached so esptool never waits on a prompt.
  # CR -> LF so esptool's in-place progress bar becomes separate lines (see xz_progress_filter).
  "$XZ_ESPTOOL" --port "$XZ_PORT" "$@" </dev/null | tr '\r' '\n' | sed '/^[[:space:]]*$/d'
}

# Thin out esptool progress output: keep every non-progress line, but of the
# "…  37.5% …" lines only print one each time the figure has advanced by >= 10 points.
#   xz_esptool read-flash ... | xz_progress_filter
xz_progress_filter() {
  awk '
    match($0, /[0-9]+(\.[0-9]+)? ?%/) {
      pct = substr($0, RSTART, RLENGTH); sub(/ ?%/, "", pct); pct += 0
      if (pct < last) last = -10
      if (pct - last >= 10 || pct >= 100) { print; fflush(); last = pct }
      next
    }
    { print; fflush(); last = -10 }
  '
}
