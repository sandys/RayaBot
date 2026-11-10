#!/usr/bin/env bash
# 14-menuconfig.sh — open ESP-IDF's menuconfig (the Kconfig text UI) inside the build container,
#                    then turn what you changed into lines for scripts/11-build-firmware.sh.
#
# Usage:
#   scripts/14-menuconfig.sh            # the UI. Needs a real terminal: run it yourself, not through a pipe
#   scripts/14-menuconfig.sh --delta    # no UI: only print how the tree's sdkconfig differs from the last build
#
# What it works on
#   The build that is configured in the firmware tree right now = the last one
#   scripts/11-build-firmware.sh ran (board and label are recorded in
#   firmware/xiaozhi-esp32/build/xz-build-id). Build first, then explore its configuration here.
#   "Xiaozhi Assistant" is the project's own menu: board type, OTA URL, language, wake word, ...
#
# Why the result is not simply "saved"
#   menuconfig writes firmware/xiaozhi-esp32/sdkconfig, but upstream's build.py regenerates
#   that file from the sdkconfig defaults on EVERY build - the next 11-build-firmware.sh run
#   throws your edits away. The durable form of a configuration change in this project is a
#   few CONFIG_ lines handed to the build:
#       scripts/11-build-firmware.sh --label NAME --sdkconfig-append FILE     (or --set 'CONFIG_X=...')
#   So after you quit the UI this script prints exactly those lines: the difference between
#   the sdkconfig you just saved and the one the last build used (out/<board>/<label>/sdkconfig).
#   The same lines are written to state/menuconfig-delta.sdkconfig, ready for --sdkconfig-append.
#
# Keys inside the UI: arrows / Enter to navigate, Space or Y/N to toggle, "/" to search for a
# symbol, "?" for help on the selected option, S to save, Q to quit (it asks whether to save).
#
# Only the report (not the full-screen UI) is saved to logs/<timestamp>-menuconfig.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$XZ_SCRIPTS/lib/idf-docker.sh"

BUILD_ID="$XZ_FW_SRC/build/xz-build-id"
DELTA_FILE="$XZ_ROOT/state/menuconfig-delta.sdkconfig"

# Sets board_name / label / reference from the build that owns firmware/xiaozhi-esp32/build.
load_configured_build() {
  [[ -f "$BUILD_ID" && -f "$XZ_FW_SRC/build/CMakeCache.txt" && -f "$XZ_FW_SRC/sdkconfig" ]] \
    || die "nothing is configured in the firmware tree yet - run scripts/11-build-firmware.sh first"
  local id board_dir
  id="$(cat "$BUILD_ID")"
  board_dir="$(sed -n 's/^board_dir=\([^ ]*\) .*$/\1/p' <<<"$id")"
  label="$(sed -n 's/^.* label=\(.*\)$/\1/p' <<<"$id")"
  [[ -n "$board_dir" && -n "$label" ]] || die "cannot read $BUILD_ID: $id"
  board_name="${board_dir##*/}"
  reference="$XZ_OUT/$board_name/$label/sdkconfig"
  [[ -f "$reference" ]] \
    || die "the last build ($board_name, label $label) never finished - no ${reference#"$XZ_ROOT"/} to compare with; run scripts/11-build-firmware.sh"
}

report() {
  echo "=== sdkconfig of $board_name / $label ==="
  echo "  as built:  ${reference#"$XZ_ROOT"/}"
  echo "  in tree:   ${XZ_FW_SRC#"$XZ_ROOT"/}/sdkconfig  (what menuconfig edits; the next build regenerates it)"
  local delta
  delta="$(python3 -I -B "$XZ_SCRIPTS/py/inspect_build.py" config-delta "$reference" "$XZ_FW_SRC/sdkconfig")" \
    || die "could not compare the two sdkconfig files"
  if [[ -z "$delta" ]]; then
    echo "  no differences - nothing was changed (or nothing was saved)"
    return 0
  fi
  echo
  echo "=== changed: $(grep -c '' <<<"$delta") line(s) to append ==="
  printf '%s\n' "$delta"
  mkdir -p "$XZ_ROOT/state"
  {
    echo "# sdkconfig changes made in menuconfig on $(date -Is)"
    echo "# relative to ${reference#"$XZ_ROOT"/}"
    printf '%s\n' "$delta"
  } > "$DELTA_FILE" || die "cannot write $DELTA_FILE"
  echo
  echo "Saved to ${DELTA_FILE#"$XZ_ROOT"/}. To build with these changes (they are NOT in any build yet):"
  if [[ -f "${reference%/sdkconfig}/sdkconfig.append" ]]; then
    echo "  scripts/11-build-firmware.sh --board $board_name --label NEW-NAME \\"
    echo "      --sdkconfig-append ${reference#"$XZ_ROOT"/}.append --sdkconfig-append ${DELTA_FILE#"$XZ_ROOT"/}"
  else
    echo "  scripts/11-build-firmware.sh --board $board_name --label NEW-NAME --sdkconfig-append ${DELTA_FILE#"$XZ_ROOT"/}"
  fi
  echo "Copy the file somewhere permanent (e.g. config/) if the variant is worth keeping."
}

main() {
  local delta_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delta) delta_only=1; shift ;;
      -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
  command -v python3 >/dev/null || die "python3 is not installed"

  local board_name label reference
  load_configured_build

  if [[ $delta_only -eq 0 ]]; then
    [[ -t 0 && -t 1 ]] || die "menuconfig needs an interactive terminal on stdin and stdout (use --delta to only print the difference)"
    xz_idf_image_check
    xz_build_lock
    log "menuconfig for $board_name / $label in $XZ_IDF_IMAGE (quit with Q)"
    # Not wrapped in xz_run_logged: a full-screen UI must own the terminal, and its
    # escape sequences would be useless in a log.
    xz_idf_run --tty idf.py menuconfig || die "idf.py menuconfig exited with an error"
  fi

  xz_run_logged menuconfig report
}

main "$@"
