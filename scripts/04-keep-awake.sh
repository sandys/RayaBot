#!/usr/bin/env bash
# 04-keep-awake.sh — stop the Windows host idling into sleep during a long unattended run.
#
# Usage:
#   scripts/04-keep-awake.sh --show         # only print power source + sleep timeouts
#   scripts/04-keep-awake.sh                # hold the PC awake for 10 hours (blocks; run in background)
#   scripts/04-keep-awake.sh --hours 3
#
# Why
#   If the laptop sleeps, WSL freezes and the board's USB port loses power, so an
#   overnight build/flash/test session silently stops. This holds a "system required"
#   execution-state request (what media players do) for the given time.
#
# What it changes: nothing persistent. No power-plan edits, no admin. The request
# disappears the moment the script ends or is killed. Closing the lid still sleeps
# the machine if the lid action says so (shown by --show).
# Output is also saved to logs/<timestamp>-keep-awake.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --show)  args+=(-ShowOnly); shift ;;
      --hours) [[ $# -ge 2 ]] || die "--hours needs a number"; args+=(-Hours "$2"); shift 2 ;;
      -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
  win_ps "$XZ_SCRIPTS/win/keep-awake.ps1" "${args[@]}"
}

xz_run_logged keep-awake main "$@"
