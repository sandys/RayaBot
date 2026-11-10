#!/usr/bin/env bash
# 23-flash-firmware.sh — write a firmware build to the device. THIS CHANGES THE FLASH.
#
# Usage:
#   scripts/23-flash-firmware.sh --dir out/sp-esp32-s3-1.28-box/stock-v2.5.2
#   scripts/23-flash-firmware.sh --dir <build dir> --dry-run       # show the plan, write nothing
#   scripts/23-flash-firmware.sh --dir <build dir> --erase-nvs     # also wipe saved WiFi/settings
#   scripts/23-flash-firmware.sh --dir <build dir> --merged        # write merged-binary.bin at 0x0 instead
#   scripts/23-flash-firmware.sh --dir <build dir> --run           # reset into the app when done
#
# Input: a directory containing ESP-IDF's flasher_args.json (offset -> file map plus flash
# mode/freq/size) and the files it names — what scripts/11-build-firmware.sh puts in out/.
#
# Two ways of writing
#   default   each file at its own offset (bootloader, partition table, otadata, app, assets…),
#             exactly like "idf.py flash". Regions not named are left alone, so the NVS
#             partition (WiFi credentials, device identity, settings) SURVIVES.
#   --merged  one image from offset 0. Everything inside its span is overwritten, including
#             NVS (it becomes blank) — a factory-fresh device.
#   --erase-nvs  with the default mode, additionally erase the nvs partition so the firmware
#             starts unconfigured, without touching anything else.
#
# Safety checks before a single byte is written (all must pass):
#   1. a full backup for this chip's MAC exists under backups/<mac>/  (scripts/22-backup-flash.sh)
#   2. the build targets esp32s3 and its flash size matches the chip's
#   3. every file exists and fits inside the flash
#   4. secure boot and flash encryption are reported disabled by the chip
# esptool checks an MD5 of every region after writing ("Hash of data verified").
#
# By default the chip is left in the bootloader afterwards; start the new firmware and watch
# it with:  scripts/25-serial-capture.sh --reset run
# Output is also saved to logs/<timestamp>-flash-firmware.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$XZ_SCRIPTS/lib/device.sh"

main() {
  local dir="" dry=0 merged=0 erase_nvs=0 after="no-reset"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)       [[ $# -ge 2 ]] || die "--dir needs a path"; dir="$2"; shift 2 ;;
      --dry-run)   dry=1; shift ;;
      --merged)    merged=1; shift ;;
      --erase-nvs) erase_nvs=1; shift ;;
      --run)       after="hard-reset"; shift ;;
      -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
  [[ -n "$dir" ]] || die "--dir is required (try --help)"
  dir="$(cd "$dir" 2>/dev/null && pwd)" || die "no such directory: $dir"
  [[ -f "$dir/flasher_args.json" ]] || die "no flasher_args.json in $dir"
  [[ $merged -eq 1 && $erase_nvs -eq 1 ]] && die "--merged already blanks NVS; do not combine with --erase-nvs"

  # ---- build the plan from flasher_args.json (python: stdlib only) -----------------------
  local plan
  plan="$(python3 - "$dir" "$merged" <<'PY'
import json, os, struct, sys
d, merged = sys.argv[1], sys.argv[2] == "1"
fa = json.load(open(os.path.join(d, "flasher_args.json")))
fs = fa.get("flash_settings", {})
chip = fa.get("extra_esptool_args", {}).get("chip", "?")
print(f"SET chip {chip}")
for k in ("flash_mode", "flash_freq", "flash_size"):
    print(f"SET {k} {fs.get(k, 'keep')}")

def resolve(rel):
    for cand in (os.path.join(d, rel), os.path.join(d, os.path.basename(rel))):
        if os.path.isfile(cand):
            return cand
    return None

if merged:
    for name in ("merged-binary.bin", "merged_binary.bin", "merged.bin"):
        p = resolve(name)
        if p:
            print(f"FILE 0x0 {os.path.getsize(p)} {p}")
            break
    else:
        print("ERR no merged-binary.bin in the directory")
else:
    for off, rel in sorted(fa["flash_files"].items(), key=lambda kv: int(kv[0], 16)):
        p = resolve(rel)
        if p is None:
            print(f"ERR missing file for offset {off}: {rel}")
        else:
            print(f"FILE {off} {os.path.getsize(p)} {p}")

# Locate the nvs partition from the partition table binary, for --erase-nvs and for reporting.
pt = None
for off, rel in fa["flash_files"].items():
    if "partition" in os.path.basename(rel):
        pt = resolve(rel)
if pt:
    data = open(pt, "rb").read()
    for i in range(0, len(data), 32):
        e = data[i:i+32]
        if len(e) < 32 or e[:2] != b"\xaa\x50":
            break
        typ, sub, offset, size = e[2], e[3], *struct.unpack("<II", e[4:12])
        name = e[12:28].split(b"\0")[0].decode("ascii", "replace")
        print(f"PART {name} {typ} {sub} {offset:#x} {size:#x}")
PY
)"
  if grep -q '^ERR ' <<<"$plan"; then grep '^ERR ' <<<"$plan" >&2; die "build directory is incomplete"; fi

  local chip fmode ffreq fsize
  chip="$(awk '$1=="SET" && $2=="chip"{print $3}' <<<"$plan")"
  fmode="$(awk '$1=="SET" && $2=="flash_mode"{print $3}' <<<"$plan")"
  ffreq="$(awk '$1=="SET" && $2=="flash_freq"{print $3}' <<<"$plan")"
  fsize="$(awk '$1=="SET" && $2=="flash_size"{print $3}' <<<"$plan")"

  echo "=== flash plan for $dir ==="
  echo "  chip $chip, flash mode $fmode, freq $ffreq, size $fsize, mode: $([[ $merged -eq 1 ]] && echo 'MERGED image at 0x0 (NVS will be blank)' || echo 'per-partition (NVS preserved)')"
  awk '$1=="FILE"{printf "  write %-10s %9d bytes  %s\n", $2, $3, $4}' <<<"$plan"
  local nvs_off nvs_size
  nvs_off="$(awk '$1=="PART" && $2=="nvs"{print $5}' <<<"$plan")"
  nvs_size="$(awk '$1=="PART" && $2=="nvs"{print $6}' <<<"$plan")"
  [[ $erase_nvs -eq 1 ]] && echo "  erase nvs at $nvs_off size $nvs_size"
  echo "  partition table in this build:"
  awk '$1=="PART"{printf "    %-12s type %s sub %-3s offset %-10s size %s\n", $2, $3, $4, $5, $6}' <<<"$plan"

  # ---- safety checks ---------------------------------------------------------------------
  xz_load_device
  xz_port_lock
  [[ "$chip" == "esp32s3" ]] || die "build is for chip '$chip', device is esp32s3"

  log "querying chip"
  local sec id
  sec="$(xz_esptool --after no-reset get-security-info)"
  grep -q 'Secure Boot: Disabled' <<<"$sec"      || { printf '%s\n' "$sec"; die "secure boot is not reported disabled - refusing to flash"; }
  grep -q 'Flash Encryption: Disabled' <<<"$sec" || { printf '%s\n' "$sec"; die "flash encryption is not reported disabled - refusing to flash"; }
  id="$(xz_esptool --after no-reset flash-id)"
  local mac devsize
  mac="$(grep -m1 -oE 'MAC: +[0-9a-f:]+' <<<"$id" | awk '{print $2}' | tr -d ':')"
  devsize="$(grep -m1 -oE 'Detected flash size: *[0-9]+MB' <<<"$id" | grep -oE '[0-9]+MB')"
  [[ -n "$mac" && -n "$devsize" ]] || die "could not read MAC / flash size from the chip"
  echo "  device: MAC $mac, flash $devsize, secure boot off, flash encryption off"
  [[ "$fsize" == "$devsize" || "$fsize" == "keep" ]] || die "build expects $fsize flash, chip has $devsize"

  local backup
  backup="$(ls -1 "$XZ_BACKUPS/$mac"/*-full-*.bin 2>/dev/null | head -1 || true)"
  [[ -n "$backup" ]] || die "no full backup for $mac under backups/ - run scripts/22-backup-flash.sh first"
  echo "  backup present: $backup"

  local limit=$(( ${devsize%MB} * 1024 * 1024 )) bad=0
  while read -r _ off size path; do
    if (( off + size > limit )); then echo "  DOES NOT FIT: $path at $off"; bad=1; fi
  done < <(grep '^FILE ' <<<"$plan")
  [[ $bad -eq 0 ]] || die "a file does not fit in the flash"

  if [[ $dry -eq 1 ]]; then
    log "dry run: all checks passed, nothing written"
    return 0
  fi

  # ---- write -----------------------------------------------------------------------------
  if [[ $erase_nvs -eq 1 ]]; then
    [[ -n "$nvs_off" ]] || die "no nvs partition found in the build's partition table"
    log "erasing nvs ($nvs_off + $nvs_size)"
    xz_esptool --after no-reset erase-region "$nvs_off" "$nvs_size" | xz_progress_filter
  fi

  local args=()
  while read -r _ off _ path; do
    args+=("$off" "$(win_path "$path")")
  done < <(grep '^FILE ' <<<"$plan")

  log "writing flash"
  local t0=$SECONDS out rc=0
  out="$(xz_esptool --chip "$chip" --after "$after" write-flash \
          --flash-mode "$fmode" --flash-freq "$ffreq" --flash-size "$fsize" "${args[@]}" | xz_progress_filter)" || rc=$?
  printf '%s\n' "$out"
  [[ $rc -eq 0 ]] || die "esptool write-flash failed (exit $rc)"

  local nfiles nverified
  nfiles="$(grep -c '^FILE ' <<<"$plan")"
  nverified="$(grep -c 'Hash of data verified' <<<"$out" || true)"
  echo
  echo "=== flash result ==="
  echo "  regions written:  $nfiles"
  echo "  hashes verified:  $nverified"
  echo "  took:             $(( SECONDS - t0 )) s"
  [[ "$nverified" -eq "$nfiles" ]] || die "only $nverified of $nfiles regions were hash-verified"
  mkdir -p "$XZ_ROOT/state"
  {
    echo "# written by scripts/23-flash-firmware.sh on $(date -Is)"
    echo "XZ_FLASHED_DIR=$dir"
    echo "XZ_FLASHED_MODE=$([[ $merged -eq 1 ]] && echo merged || echo per-partition)"
    echo "XZ_FLASHED_NVS_ERASED=$erase_nvs"
  } > "$XZ_ROOT/state/last-flash.env"
  log "chip left in: $([[ $after == no-reset ]] && echo 'bootloader (run scripts/25-serial-capture.sh --reset run to start it)' || echo 'application (hard reset)')"
}

xz_run_logged flash-firmware main "$@"
