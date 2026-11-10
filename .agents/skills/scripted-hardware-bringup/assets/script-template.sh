#!/usr/bin/env bash
# NN-verb-object.sh — one line on what this does. Say READ-ONLY, or WRITES FLASH / CHANGES X.
#
# Usage:
#   scripts/NN-verb-object.sh                  # the common case
#   scripts/NN-verb-object.sh --option VALUE   # one line per option
#
# Why
#   The question this script answers, or the step it makes repeatable.
#
# What it does
#   1. ...
#   2. ...
#   What it changes (files, device, nothing) and what it never does (print secrets, ...).
#
# Exit status: 0 ok · 1 failed (say what to check) · other codes only if they mean something.
# Output is also saved to logs/<timestamp>-verb-object.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# Touches the serial port? Also:  source "$XZ_SCRIPTS/lib/device.sh"
#   (xz_load_device, xz_port_lock, xz_esptool; only one 2x script may hold the port)

main() {
  local opt=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --option) [[ $# -ge 2 ]] || die "--option needs a value"; opt="$2"; shift 2 ;;
      -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done

  log "doing the thing${opt:+ with $opt}"
  # The work. Print evidence (paths, hashes, PASS/FAIL lines), never secret values.
}

xz_run_logged verb-object main "$@"
