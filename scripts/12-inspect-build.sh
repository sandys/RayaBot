#!/usr/bin/env bash
# 12-inspect-build.sh — describe and verify the firmware artifacts in out/<board>/<label>/.
#
# Usage:
#   scripts/12-inspect-build.sh                             # out/sp-esp32-s3-1.28-box/stock-<source ref>/
#   scripts/12-inspect-build.sh --label NAME [--board NAME]
#   scripts/12-inspect-build.sh --list                      # which builds exist under out/
#
# Options
#   --board NAME   directory under out/ (default: $XZ_BOARD or sp-esp32-s3-1.28-box)
#   --label NAME   directory under out/<board>/ (default: stock-<git describe of the firmware
#                  checkout>, i.e. stock-v2.5.2 - the same default as scripts/11-build-firmware.sh)
#   --list         print every out/<board>/<label>/ with its build date and size, then exit
#
# What it prints (everything is read from the files in out/, nothing is rebuilt)
#   - the build identity recorded in build-info.txt (source ref, ESP-IDF version, image digest)
#   - flash settings from flasher_args.json (chip, mode, frequency, size)
#   - the partition table, decoded from the binary: name, type, subtype, offset, size, end,
#     flags, and which file this build writes there
#   - every flash file: offset, size, the region it lands in, that region's capacity,
#     how full it is and how much is left
#   - the application descriptor: project name, version, ESP-IDF version, build date,
#     ELF sha256; plus chip id, supported chip revisions, checksum and hash of the image
#   - whether merged-binary.bin really is the sum of the parts, and whether every file
#     still has the sha256 recorded at build time (SHA256SUMS)
#
# Exit status
#   0  everything expected is there, fits its partition and is consistent
#   1  something is missing / does not fit / is corrupt - each problem is listed under "result"
#
# Runs on the WSL host with python3 (standard library only, scripts/py/inspect_build.py).
# No docker, no ESP-IDF, no esptool, no device. The partition table is additionally compared
# with the decode that ESP-IDF's own gen_esp32part.py made inside the container at build
# time (partition-table.csv), so our parser cannot drift from the real format unnoticed.
# Output is also saved to logs/<timestamp>-inspect-build.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

XZ_OUT="$XZ_ROOT/out"
XZ_FW_SRC="$XZ_ROOT/firmware/xiaozhi-esp32"

list_builds() {
  echo "=== builds under ${XZ_OUT#"$XZ_ROOT"/}/ ==="
  local info found=0
  while IFS= read -r info; do
    found=1
    printf '  %-62s built %s, %s\n' "${info%/build-info.txt}" \
      "$(sed -n 's/^built: *//p' "$XZ_OUT/$info" | head -1)" "$(du -sh "$XZ_OUT/${info%/build-info.txt}" | cut -f1)"
  done < <(cd "$XZ_OUT" 2>/dev/null && find . -mindepth 3 -maxdepth 3 -name build-info.txt -printf '%P\n' | LC_ALL=C sort)
  [[ $found -eq 1 ]] || echo "  none yet - run scripts/11-build-firmware.sh"
}

main() {
  local board="${XZ_BOARD:-sp-esp32-s3-1.28-box}" label=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --board) [[ $# -ge 2 ]] || die "--board needs a name"; board="$2"; shift 2 ;;
      --label) [[ $# -ge 2 ]] || die "--label needs a name"; label="$2"; shift 2 ;;
      --list)  list_builds; return 0 ;;
      -h|--help) sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
  command -v python3 >/dev/null || die "python3 is not installed"
  board="${board##*/}"                    # "vendor/name" is accepted like in 11-build-firmware.sh

  if [[ -z "$label" ]]; then
    local ref
    ref="$(git -C "$XZ_FW_SRC" describe --tags --always 2>/dev/null)" \
      || die "cannot derive the default label (no firmware checkout): pass --label"
    label="stock-$ref"
  fi

  local dir="$XZ_OUT/$board/$label"
  if [[ ! -d "$dir" ]]; then
    list_builds >&2
    die "no such build: ${dir#"$XZ_ROOT"/} (scripts/11-build-firmware.sh creates it)"
  fi
  python3 -I -B "$XZ_SCRIPTS/py/inspect_build.py" inspect "$dir"
}

xz_run_logged inspect-build main "$@"
