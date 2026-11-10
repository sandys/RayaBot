#!/usr/bin/env bash
# 03-wait-for-device.sh — block until the ESP32 enumerates on Windows USB. (run from WSL)
#
# Usage:
#   scripts/03-wait-for-device.sh                    # wait up to 1 hour
#   scripts/03-wait-for-device.sh --timeout 30000    # wait up to 30000 s (~8 h)
#   scripts/03-wait-for-device.sh --enumfail         # also stop on a failed-enumeration device
#
# Prints one line when the board appears and exits 0:
#   FOUND    <VID:PID> <COMx> <status> <name>     ready: use that COM port
#   NODRIVER <VID:PID> -      <status> <name>     present but no serial driver bound
#   ENUMFAIL 0000:0002 ...                         (only with --enumfail) cable/port problem
# Exit 2 on timeout.
#
# It also writes the result to state/device.env (XZ_PORT=COMx, XZ_VIDPID=...) so
# later scripts pick the port up without being told.
#
# Meant to be left running in the background while the board is being (re)plugged;
# returns immediately if the board is already there.
# Output is also saved to logs/<timestamp>-wait-for-device.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)  [[ $# -ge 2 ]] || die "--timeout needs seconds"; args+=(-TimeoutSec "$2"); shift 2 ;;
      --enumfail) args+=(-ReportEnumFail); shift ;;
      -h|--help)  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done

  local out rc=0
  out="$(win_ps "$XZ_SCRIPTS/win/wait-for-device.ps1" "${args[@]}")" || rc=$?
  printf '%s\n' "$out"

  local line
  line="$(printf '%s\n' "$out" | grep -E '^FOUND ' | head -1 || true)"
  if [[ -n "$line" ]]; then
    local vidpid port
    vidpid="$(awk '{print $2}' <<<"$line")"
    port="$(awk '{print $3}' <<<"$line")"
    mkdir -p "$XZ_ROOT/state"
    {
      echo "# written by scripts/03-wait-for-device.sh on $(date -Is)"
      echo "XZ_PORT=$port"
      echo "XZ_VIDPID=$vidpid"
    } > "$XZ_ROOT/state/device.env"
    log "device recorded in state/device.env: $port ($vidpid)"
  fi
  return $rc
}

xz_run_logged wait-for-device main "$@"
