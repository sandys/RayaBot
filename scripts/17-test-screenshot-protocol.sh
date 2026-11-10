#!/usr/bin/env bash
# 17-test-screenshot-protocol.sh — prove the device-side screenshot dumper and the host-side
# decoder agree, without any hardware.
#
# Usage:  scripts/17-test-screenshot-protocol.sh
#
# Why
#   The dev firmware prints screenshots on the serial console (main/xz_dev.cc, added by
#   patches/xz-dev-tools.patch) and scripts/py/extract_screenshots.py reassembles them.
#   A base64 or CRC slip on either side would only show up after a 10-minute
#   build-and-flash cycle. This catches it in seconds.
#
# What it does
#   1. takes xz_dev.cc — from the firmware tree if the patch is applied, otherwise straight
#      out of the patch file
#   2. inside the ESP-IDF docker image (nothing is compiled on the host) builds that exact
#      file against fake ESP-IDF headers (scripts/container/xzshot-host/) with the image's
#      native g++, and runs it with a fake display that returns known payloads whose sizes
#      sit on every awkward boundary: 1, 2, 3 bytes (base64 padding), 71/72/73 and 144
#      (the 72-byte line length), and two larger ones
#   3. feeds the program's output to extract_screenshots.py and compares every decoded
#      file byte-for-byte with what the fake display handed out
#   4. runs the decoder's own negative tests (dropped line, wrong CRC must be rejected)
#
# Exit status: 0 only if every payload round-trips and the negative tests pass.
# Output is also saved to logs/<timestamp>-test-screenshot-protocol.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$XZ_SCRIPTS/lib/idf-docker.sh"

SIZES="1,2,3,71,72,73,144,5000,20001"

main() {
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0; }
  xz_idf_image_check

  local work="$XZ_IDF_HOME/xzshot-test"      # = /home/builder/xzshot-test inside the container
  rm -rf "$work"; mkdir -p "$work/src" "$work/decoded"

  # 1. the device-side source
  if [[ -f "$XZ_FW_SRC/main/xz_dev.cc" ]]; then
    cp "$XZ_FW_SRC/main/xz_dev.cc" "$work/src/xz_dev.cc"
    echo "source: firmware tree (patch applied)"
  else
    local patch="$XZ_ROOT/patches/xz-dev-tools.patch"
    [[ -f "$patch" ]] || die "neither main/xz_dev.cc nor $patch exists"
    ( cd "$work/src" && git apply --include='main/xz_dev.cc' "$patch" && mv main/xz_dev.cc . && rmdir main )
    echo "source: extracted from patches/xz-dev-tools.patch"
  fi
  echo "        $(sha256sum "$work/src/xz_dev.cc" | cut -c1-16)…  $(wc -l < "$work/src/xz_dev.cc") lines"

  # 2. compile + run inside the container
  echo "=== device side (in $XZ_IDF_IMAGE) ==="
  xz_idf_run bash /xz/container/test-xzshot.sh /home/builder/xzshot-test "$SIZES"

  # 3. decode on the host and compare
  echo "=== host side ==="
  local out rc=0
  out="$(python3 "$XZ_SCRIPTS/py/extract_screenshots.py" "$work/device-output.log" --out-dir "$work/decoded" --prefix t)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/  /'

  local fail=0 i=0 size
  echo "=== byte-for-byte comparison ==="
  for size in ${SIZES//,/ }; do
    i=$((i + 1))
    local exp got
    exp="$(printf '%s/expected/expected-%02d.bin' "$work" "$i")"
    got="$(printf '%s/decoded/t-%02d.jpg' "$work" "$i")"
    if [[ -f "$exp" && -f "$got" ]] && cmp -s "$exp" "$got" && [[ "$(stat -c %s "$got")" -eq "$size" ]]; then
      printf '  PASS  %6d bytes\n' "$size"
    else
      printf '  FAIL  %6d bytes  (expected %s, decoded %s)\n' "$size" \
        "$([[ -f "$exp" ]] && stat -c %s "$exp" || echo missing)" "$([[ -f "$got" ]] && stat -c %s "$got" || echo missing)"
      fail=1
    fi
  done

  echo "=== decoder negative tests ==="
  python3 "$XZ_SCRIPTS/py/extract_screenshots.py" --self-test || fail=1

  [[ $fail -eq 0 && $rc -eq 0 ]] || die "screenshot protocol test FAILED"
  log "screenshot protocol test passed: device encoder and host decoder agree on ${i} payloads"
}

xz_run_logged test-screenshot-protocol main "$@"
