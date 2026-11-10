#!/usr/bin/env bash
# 30-analyze-flash-image.sh — say exactly what is inside a raw ESP32 flash image. Read-only, no device.
#
# Usage:
#   scripts/30-analyze-flash-image.sh <image.bin>               # full report, credentials redacted
#   scripts/30-analyze-flash-image.sh <image.bin> --source DIR  # cross-check against another xiaozhi-esp32 checkout
#   scripts/30-analyze-flash-image.sh <image.bin> --secrets     # NVS values unredacted - interactive terminal only
#
# <image.bin> must start at flash offset 0: a full dump from scripts/22-backup-flash.sh
# (backups/<mac>/*-full-16MB.bin), an official merged-binary.bin from scripts/31-fetch-prebuilt-firmware.sh,
# or out/<board>/<label>/merged-binary.bin from our own build. Shorter files are fine: whatever
# lies beyond the end of the file is reported as "not in this file".
#
# Why
#   (1) Identify a device: which firmware version and which xiaozhi board profile is on it, which
#       OTA slot boots, which server it talks to, whether WiFi credentials are stored.
#   (2) Sanity-check an image BEFORE flashing it: valid bootloader for the right chip, partition
#       table with a good MD5, an app whose checksum and SHA-256 hold, built for the right board.
#
# What it reports
#   - second-stage bootloader at 0x0: magic, chip id, SPI mode/speed/size bits, entry, segments,
#     checksum, appended SHA-256, bootloader descriptor (ESP-IDF version, build time)
#   - partition table at 0x8000: every entry, MD5 validity, which partitions CSV of the source
#     tree it equals, overlaps / out-of-flash entries
#   - otadata: both copies (sequence, state, CRC), the slot the bootloader selects and the slot
#     that would really boot once image validity is taken into account
#   - every app partition: segment walk, checksum, SHA-256, esp_app_desc_t (project, version,
#     compile date/time, ESP-IDF), the BOARD_NAME / BOARD_TYPE / source directory strings the
#     firmware carries - cross-checked against main/boards/**/config.json of the checked-out
#     source - and the OTA URL baked in
#   - NVS: pages, namespaces, every live key with type and value; credentials are REDACTED
#     (type and length only); erased-but-still-readable keys are listed by name
#   - other data partitions and the space outside partitions: size, how much is not 0xFF,
#     recognised formats (xiaozhi assets image, ESP-SR models, SPIFFS, ...)
#   - a summary, including the answer to "are WiFi credentials stored?" (SSID yes, password never)
#
# Exit status: 0 = analysed, nothing wrong · 3 = analysed, problems found (see "PROBLEM" lines
# in the summary) · 1 = could not run.
#
# PRIVACY: a device dump holds the WiFi password and server tokens. Default output is safe to
# keep in logs/ and docs/. With --secrets nothing is written to logs/ and the tool refuses to
# run unless stdout is a terminal, so secrets cannot land in a file, pipe or transcript.
# The image is untrusted data: it is only parsed (python3 -I, standard library, scripts/py/).
# Output is also saved to logs/<timestamp>-analyze-flash-image.log (not with --secrets).

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local image="" source_dir="$XZ_ROOT/firmware/xiaozhi-esp32" pyargs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --secrets) pyargs+=(--secrets); shift ;;
      --source)  [[ $# -ge 2 ]] || die "--source needs a directory"; source_dir="$2"; shift 2 ;;
      -h|--help) sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      -*) die "unknown argument: $1 (try --help)" ;;
      *)  [[ -z "$image" ]] || die "only one image at a time (got '$image' and '$1')"; image="$1"; shift ;;
    esac
  done
  [[ -n "$image" ]] || die "usage: scripts/30-analyze-flash-image.sh <image.bin> [--source DIR] [--secrets]"
  [[ -f "$image" && -r "$image" ]] || die "no such readable file: $image"
  if [[ -d "$source_dir/main/boards" ]]; then
    pyargs+=(--source "$source_dir")
  else
    warn "no firmware source at $source_dir: board names will not be cross-checked (scripts/10-fetch-firmware-source.sh)"
  fi
  python3 -I -B "$XZ_SCRIPTS/py/analyze_flash_image.py" "$image" "${pyargs[@]}"
}

# --secrets must never reach logs/: run without the tee. (The Python side also refuses unless
# stdout is a terminal.)
for arg in "$@"; do
  if [[ "$arg" == "--secrets" ]]; then
    warn "--secrets: output will contain credentials and is NOT saved to logs/"
    main "$@"
    exit $?
  fi
done
xz_run_logged analyze-flash-image main "$@"
