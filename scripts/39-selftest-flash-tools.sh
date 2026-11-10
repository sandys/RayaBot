#!/usr/bin/env bash
# 39-selftest-flash-tools.sh — prove the flash-image tools (30, 32) still work and still hide secrets.
#
# Usage:
#   scripts/39-selftest-flash-tools.sh           # run all checks (a few seconds)
#   scripts/39-selftest-flash-tools.sh --keep    # keep the synthetic images for a closer look
#
# Why
#   scripts/30-analyze-flash-image.sh is run on device dumps that contain the owner's WiFi
#   password, and its output goes to logs/ and docs/. This test is the guard for that: it
#   plants known fake secrets in a synthetic NVS partition and fails if any of them shows up
#   in the default output. Run it after every change to scripts/py/*.py.
#
# What it does (no real dump, no network, no device - everything is generated in a temp dir)
#   - builds a 4 MB flash image: bootloader, partition table, otadata, two apps (one with the
#     v2.x string layout, one with the v1.x layout), a 6-page NVS with WiFi/MQTT/websocket
#     credentials, multi-page blobs and an erased old password, a model and an assets partition
#   - runs the same Python entry points scripts 30 and 32 use, as separate processes, and checks
#     the reports: values decoded correctly, secrets absent, --secrets refused without a
#     terminal and effective when forced, boot-slot selection and fallback, damaged / truncated
#     / random files reported with exit status 3 instead of a crash, compare results and offsets
#
# Limits: the image writer in the test is our own code. Agreement with Espressif's tools is
# checked separately by scripts/33-crosscheck-idf-tools.sh (in the build container).
#
# Exit status: 0 = every check passed, 1 = at least one failed (each failure is listed).
# Output is also saved to logs/<timestamp>-selftest-flash-tools.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local pyargs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep) pyargs+=(--keep); shift ;;
      -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
  if [[ -d "$XZ_ROOT/firmware/xiaozhi-esp32/main/boards" ]]; then
    pyargs+=(--source "$XZ_ROOT/firmware/xiaozhi-esp32")
  else
    warn "no firmware source checkout: the board cross-check assertions are skipped"
  fi
  python3 -I -B "$XZ_SCRIPTS/py/selftest_flash_tools.py" "${pyargs[@]}"
}

xz_run_logged selftest-flash-tools main "$@"
