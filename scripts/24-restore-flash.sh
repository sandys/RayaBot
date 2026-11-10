#!/usr/bin/env bash
# 24-restore-flash.sh — write a full-flash backup back to the device. THIS OVERWRITES EVERYTHING.
#
# Usage:
#   scripts/24-restore-flash.sh                      # restore the factory backup of the connected chip
#   scripts/24-restore-flash.sh --file backups/<mac>/<name>-full-16MB.bin
#   scripts/24-restore-flash.sh --dry-run            # run every check, write nothing
#   scripts/24-restore-flash.sh --run                # reset into the restored firmware when done
#
# What it does
#   Puts the device back into the exact state captured by scripts/22-backup-flash.sh:
#   bootloader, partition table, NVS (WiFi credentials, device identity), all app slots, assets.
#   The image is written unmodified (--flash-mode/freq/size keep), so the result is
#   byte-identical to the dump.
#
# Checks before writing (all must pass)
#   1. the backup's sha256 matches its .sha256 file (the dump has not been altered)
#   2. the backup is exactly as large as the chip's flash
#   3. the backup directory name (MAC) matches the connected chip — a dump from another unit
#      carries that unit's identity and calibration, so that needs --force
#   4. secure boot and flash encryption are reported disabled
#
# Takes about 3 minutes for 16 MB. esptool skips nothing: the whole image is written and
# its MD5 is verified by the chip afterwards.
# Output is also saved to logs/<timestamp>-restore-flash.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$XZ_SCRIPTS/lib/device.sh"

main() {
  local file="" dry=0 force=0 after="no-reset"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)    [[ $# -ge 2 ]] || die "--file needs a path"; file="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --force)   force=1; shift ;;
      --run)     after="hard-reset"; shift ;;
      -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done

  xz_load_device
  xz_port_lock

  log "querying chip"
  local sec id mac devsize
  sec="$(xz_esptool --after no-reset get-security-info)"
  grep -q 'Secure Boot: Disabled' <<<"$sec"      || { printf '%s\n' "$sec"; die "secure boot is not reported disabled - refusing"; }
  grep -q 'Flash Encryption: Disabled' <<<"$sec" || { printf '%s\n' "$sec"; die "flash encryption is not reported disabled - refusing"; }
  id="$(xz_esptool --after no-reset flash-id)"
  mac="$(grep -m1 -oE 'MAC: +[0-9a-f:]+' <<<"$id" | awk '{print $2}' | tr -d ':')"
  devsize="$(grep -m1 -oE 'Detected flash size: *[0-9]+MB' <<<"$id" | grep -oE '[0-9]+MB')"
  [[ -n "$mac" && -n "$devsize" ]] || die "could not read MAC / flash size from the chip"

  if [[ -z "$file" ]]; then
    file="$(ls -1 "$XZ_BACKUPS/$mac"/*-factory-full-*.bin 2>/dev/null | head -1 || true)"
    [[ -n "$file" ]] || die "no factory backup found under backups/$mac/ - pass --file"
  fi
  [[ -f "$file" ]] || die "no such backup: $file"
  file="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"

  echo "=== restore plan ==="
  echo "  device: MAC $mac, flash $devsize"
  echo "  image:  $file"

  [[ -f "$file.sha256" ]] || die "missing $file.sha256 - cannot prove the dump is intact"
  ( cd "$(dirname "$file")" && sha256sum --check --quiet "$(basename "$file").sha256" ) || die "sha256 mismatch: the backup file has changed since it was taken"
  echo "  sha256: OK ($(cut -d' ' -f1 "$file.sha256"))"

  local bytes expect
  bytes="$(stat -c %s "$file")"; expect=$(( ${devsize%MB} * 1024 * 1024 ))
  [[ "$bytes" -eq "$expect" ]] || die "backup is $bytes bytes but the flash is $expect"
  echo "  size:   OK ($bytes bytes)"

  local owner; owner="$(basename "$(dirname "$file")")"
  if [[ "$owner" != "$mac" ]]; then
    [[ $force -eq 1 ]] || die "backup belongs to $owner, connected chip is $mac (use --force to override)"
    warn "restoring a dump from a different unit ($owner) because of --force"
  else
    echo "  owner:  OK (same MAC)"
  fi

  if [[ $dry -eq 1 ]]; then
    log "dry run: all checks passed, nothing written"
    return 0
  fi

  log "writing $bytes bytes from offset 0"
  local t0=$SECONDS out rc=0
  out="$(xz_esptool --chip esp32s3 --after "$after" write-flash \
          --flash-mode keep --flash-freq keep --flash-size keep 0x0 "$(win_path "$file")" | xz_progress_filter)" || rc=$?
  printf '%s\n' "$out"
  [[ $rc -eq 0 ]] || die "esptool write-flash failed (exit $rc)"
  grep -q 'Hash of data verified' <<<"$out" || die "esptool did not confirm 'Hash of data verified'"

  echo
  echo "=== restore result ==="
  echo "  hash verified by the chip, took $(( SECONDS - t0 )) s"
  rm -f "$XZ_ROOT/state/last-flash.env"
  log "chip left in: $([[ $after == no-reset ]] && echo 'bootloader (run scripts/25-serial-capture.sh --reset run to start it)' || echo 'application (hard reset)')"
}

xz_run_logged restore-flash main "$@"
