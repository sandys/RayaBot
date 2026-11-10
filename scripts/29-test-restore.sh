#!/usr/bin/env bash
# 29-test-restore.sh — prove the way back to factory works: restore, read back, compare, boot.
#                      THIS OVERWRITES THE WHOLE FLASH with the factory backup.
#
# Usage:
#   scripts/29-test-restore.sh                 # restore the factory backup of the connected chip
#   scripts/29-test-restore.sh --file backups/<mac>/<name>-full-16MB.bin
#
# Steps (each one must pass before the next runs)
#   1. scripts/24-restore-flash.sh   writes the backup (sha256, size, MAC and security checked first;
#                                    the chip MD5-verifies the write); chip stays in the bootloader
#   2. scripts/22-backup-flash.sh    reads the whole flash back BEFORE anything boots
#                                    (booting would let the firmware write to NVS)
#   3. scripts/32-compare-images.sh  backup vs read-back: every partition must be identical
#   4. boot check                    restarts into the restored firmware for 25 s and checks the
#                                    boot log for the app version recorded in the backup
#   5. scripts/26-park-in-bootloader.sh  well before the firmware's 60 s WiFi timeout, so no voice
#                                    prompt plays
#
# Afterwards the device runs the factory firmware. Put a build back with
# scripts/23-flash-firmware.sh (or scripts/28-face-demo.sh).
# Output is also saved to logs/<timestamp>-test-restore.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$XZ_SCRIPTS/lib/device.sh"

main() {
  local file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file) [[ $# -ge 2 ]] || die "--file needs a path"; file="$2"; shift 2 ;;
      -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
  xz_load_device
  local mac_dir
  if [[ -z "$file" ]]; then
    file="$(ls -1 "$XZ_BACKUPS"/*/*-factory-full-*.bin 2>/dev/null | head -1 || true)"
    [[ -n "$file" ]] || die "no factory backup under backups/ (scripts/22-backup-flash.sh --label factory)"
  fi
  mac_dir="$(dirname "$file")"

  # The app version the backup should boot, from the analyser (no device needed).
  local want
  want="$("$XZ_SCRIPTS/30-analyze-flash-image.sh" "$file" 2>/dev/null | grep -m1 -E '^  app ota_[01]: +xiaozhi' | grep -oE 'xiaozhi [0-9][^,]*' | awk '{print $2}' || true)"
  [[ -n "$want" ]] || die "could not read the app version from $file"
  echo "=== restore round trip: $(basename "$file") (boots xiaozhi $want) ==="

  echo "############ 1. restore ############"
  "$XZ_SCRIPTS/24-restore-flash.sh" --file "$file" || die "restore failed"

  echo "############ 2. read back (before anything boots) ############"
  local before; before="$(ls -1 "$mac_dir"/*-full-*.bin | sort)"
  "$XZ_SCRIPTS/22-backup-flash.sh" --label after-restore || die "read-back failed"
  local readback
  readback="$(comm -13 <(printf '%s\n' "$before") <(ls -1 "$mac_dir"/*-full-*.bin | sort) | tail -1)"
  [[ -n "$readback" ]] || die "could not find the read-back file"

  echo "############ 3. compare ############"
  local cmp_out cmp_rc=0
  cmp_out="$("$XZ_SCRIPTS/32-compare-images.sh" "$file" "$readback" 2>&1)" || cmp_rc=$?
  printf '%s\n' "$cmp_out" | grep -vE '^\[' | sed 's/^/  /'
  local same=0
  [[ "$(sha256sum < "$file" | cut -d' ' -f1)" == "$(sha256sum < "$readback" | cut -d' ' -f1)" ]] && same=1
  if [[ $same -eq 1 ]]; then
    echo "  whole image: IDENTICAL (sha256 $(cut -c1-16 <<<"$(sha256sum < "$readback")")…)"
    rm -f "$readback" "$readback.sha256" "$readback.txt"
    echo "  (read-back deleted: it is a byte-for-byte duplicate of the backup)"
  else
    die "read-back differs from the backup (compare exit $cmp_rc) - kept: $readback"
  fi

  echo "############ 4. boot check ############"
  local rc=0
  "$XZ_SCRIPTS/25-serial-capture.sh" --quiet --reset run --seconds 25 --label restored-boot || rc=$?
  local cap="$XZ_LOGS/serial/latest.log"
  local got; got="$(grep -m1 -oE 'App version: +[^ ]+' "$cap" | awk '{print $3}' || true)"

  echo "############ 5. park ############"
  "$XZ_SCRIPTS/26-park-in-bootloader.sh" || warn "park failed - the firmware may speak its WiFi prompt after 60 s"

  echo "############ result ############"
  grep -E 'App version|Project name|SKU=|LCD panel create|Backlight: Set|WifiStation' "$cap" | head -8 | sed 's/^/  /'
  if [[ "$got" == "$want" && $rc -eq 0 ]]; then
    log "RESTORE VERIFIED: flash identical to the backup, and it boots xiaozhi $got"
  else
    die "restored image did not boot as expected (wanted $want, log says '${got:-nothing}', capture exit $rc)"
  fi
}

xz_run_logged test-restore main "$@"
