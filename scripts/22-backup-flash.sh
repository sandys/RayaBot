#!/usr/bin/env bash
# 22-backup-flash.sh — read the ENTIRE flash chip into backups/ before anything is changed.
#
# Usage:
#   scripts/22-backup-flash.sh                 # full dump, stay in bootloader afterwards
#   scripts/22-backup-flash.sh --label factory # put a word in the file name
#   scripts/22-backup-flash.sh --run           # hard-reset into the application afterwards
#
# Why
#   A full dump (offset 0 .. end, here 16 MB) contains bootloader, partition table, NVS
#   (WiFi credentials, device activation), every app slot and the assets partition.
#   Writing it back with scripts/24-restore-flash.sh returns the device to exactly this state.
#   Secure boot / flash encryption are off on this board, so the dump is plain and restorable.
#
# What it does (read-only on the device)
#   - esptool read-flash 0 ALL  -> backups/<mac>/<timestamp>[-label]-full.bin
#     (the stub loader MD5-checks the transfer, so one pass is trustworthy)
#   - writes <file>.sha256 and a <file>.txt with the chip info used
#   - prints size + hash; refuses to overwrite an existing file
#
# Takes a few minutes for 16 MB over USB-Serial/JTAG.
# PRIVACY: the dump holds your WiFi password in the NVS partition. backups/ is not for sharing.
# Output is also saved to logs/<timestamp>-backup-flash.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$XZ_SCRIPTS/lib/device.sh"

main() {
  local after="no-reset" label=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run)   after="hard-reset"; shift ;;
      --label) [[ $# -ge 2 ]] || die "--label needs a word"; label="-$2"; shift 2 ;;
      -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done

  xz_load_device
  xz_port_lock

  log "identifying chip"
  local id; id="$(xz_esptool --after no-reset flash-id)"
  local mac size
  mac="$(grep -m1 -oE 'MAC: +[0-9a-f:]+' <<<"$id" | awk '{print $2}' | tr -d ':')"
  size="$(grep -m1 -oE 'Detected flash size: *[0-9]+MB' <<<"$id" | grep -oE '[0-9]+MB')"
  [[ -n "$mac" && -n "$size" ]] || { printf '%s\n' "$id"; die "could not read MAC / flash size"; }
  log "chip $mac, flash $size"

  local dir="$XZ_BACKUPS/$mac"
  mkdir -p "$dir"
  local file="$dir/$(date +%Y%m%d-%H%M%S)${label}-full-${size}.bin"
  [[ ! -e "$file" ]] || die "refusing to overwrite $file"

  log "reading flash -> $file"
  local t0=$SECONDS
  xz_esptool --after "$after" read-flash 0 ALL "$(win_path "$file")" | xz_progress_filter
  [[ -s "$file" ]] || die "dump file is missing or empty"

  local bytes; bytes="$(stat -c %s "$file")"
  local expect=$(( ${size%MB} * 1024 * 1024 ))
  [[ "$bytes" -eq "$expect" ]] || die "dump is $bytes bytes, expected $expect"

  ( cd "$dir" && sha256sum "$(basename "$file")" > "$(basename "$file").sha256" )
  printf '%s\n' "$id" > "$file.txt"
  chmod a-w "$file"

  echo
  echo "=== backup complete ==="
  echo "  file:    $file"
  echo "  size:    $bytes bytes ($size)"
  echo "  sha256:  $(cut -d' ' -f1 "$file.sha256")"
  echo "  took:    $(( SECONDS - t0 )) s"
  echo "  blank:   $(python3 - "$file" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
ff = data.count(b'\xff')
print(f"{100*ff/len(data):.1f}% of bytes are 0xFF (erased)")
PY
)"
  log "chip left in: $([[ $after == no-reset ]] && echo 'bootloader (download mode)' || echo 'application (hard reset)')"
}

xz_run_logged backup-flash main "$@"
