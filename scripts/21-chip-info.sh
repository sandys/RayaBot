#!/usr/bin/env bash
# 21-chip-info.sh — ask the ESP32's ROM bootloader what the hardware is. Read-only.
#
# Usage:
#   scripts/21-chip-info.sh              # leave the chip in the bootloader afterwards (default)
#   scripts/21-chip-info.sh --run        # hard-reset back into the application afterwards
#
# What it reads (nothing is written to flash or eFuse)
#   chip-id            chip model + revision, features (PSRAM size), crystal, USB mode, MAC
#   flash-id           SPI flash manufacturer / device id / detected size
#   get-security-info  secure-boot and flash-encryption state  <-- must be OFF before we flash
#
# How it reaches the chip
#   The board's USB port is the ESP32-S3's built-in USB-Serial/JTAG. esptool toggles the
#   virtual DTR/RTS lines, which that peripheral turns into "reset into download mode" —
#   no BOOT button needed. While in download mode the application is not running, so the
#   stock firmware's idle timer cannot put the chip into deep sleep. That is why the
#   default here is to STAY in the bootloader (--after no-reset): the port stays alive.
#
# Results are saved to docs/device/chip-info.txt (latest) and logs/<timestamp>-chip-info.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$XZ_SCRIPTS/lib/device.sh"

main() {
  local after="no-reset"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run) after="hard-reset"; shift ;;
      -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done

  xz_load_device
  xz_port_lock
  mkdir -p "$XZ_DOCS/device"
  local out="$XZ_DOCS/device/chip-info.txt"

  {
    echo "# chip info read by scripts/21-chip-info.sh on $(date -Is)"
    echo "# port $XZ_PORT, esptool $("$XZ_ESPTOOL" version | tail -1 | tr -d '\r')"
    echo
    echo "=== chip-id ==="
    xz_esptool --after no-reset chip-id
    echo
    echo "=== flash-id ==="
    xz_esptool --after no-reset flash-id
    echo
    echo "=== get-security-info ==="
    xz_esptool --after "$after" get-security-info
  } | tee "$out"

  echo
  echo "=== summary ==="
  grep -E 'Chip type|Features|Crystal|USB mode|MAC:|Manufacturer|Device:|Detected flash size|Flash voltage|Secure Boot|Flash Encryption|Flags:|Key Purposes|SPI Boot Crypt|Chip ID|API Version' "$out" | sort -u | sed 's/^/  /' || true
  if grep -qiE 'Secure Boot: *Enabled|Flash Encryption: *Enabled' "$out"; then
    warn "SECURITY FEATURES ARE ENABLED - do NOT flash before understanding the consequences"
  fi
  log "chip left in: $([[ $after == no-reset ]] && echo 'bootloader (download mode)' || echo 'application (hard reset)')"
  log "saved: $out"
}

xz_run_logged chip-info main "$@"
