#!/usr/bin/env bash
# test-xzshot.sh — runs INSIDE the ESP-IDF container (started by scripts/17-test-screenshot-protocol.sh).
#
# Usage (inside the container):
#   bash /xz/container/test-xzshot.sh <work-dir> <comma-separated payload sizes>
#
# Compiles the device-side screenshot dumper (<work-dir>/src/xz_dev.cc, unmodified) together
# with the fake ESP-IDF headers and harness in /xz/container/xzshot-host, using the image's
# own *native* C++ compiler, and runs it. Results, all inside <work-dir>:
#   harness             the test binary
#   expected/NN.bin     the bytes the fake display handed to the dumper
#   device-output.log   exactly what the dumper printed (what a serial capture would contain)
#
# Exit codes: 0 ok, 3 the image has no native C++ compiler, anything else = compile/run failure.
set -euo pipefail

work="${1:?work dir}"
sizes="${2:?payload sizes}"
stubs=/xz/container/xzshot-host

cxx="$(command -v g++ || command -v c++ || command -v clang++ || true)"
if [[ -z "$cxx" ]]; then
  echo "NO_NATIVE_CXX: this image has no g++/c++/clang++"
  exit 3
fi
echo "compiler: $cxx ($("$cxx" --version | head -1))"

count="$(tr ',' '\n' <<<"$sizes" | grep -c .)"
"$cxx" -std=c++17 -O1 -Wall -Wextra -Werror \
  -DXZ_DEV_HOST_TEST \
  -I "$stubs" \
  -DCONFIG_XZ_DEV_SCREENSHOT_COUNT="$count" \
  -DXZ_TEST_SIZES="$sizes" \
  "$work/src/xz_dev.cc" "$stubs/harness.cc" -o "$work/harness"
echo "compiled: $work/harness"

rm -rf "$work/expected"; mkdir -p "$work/expected"
"$work/harness" "$work/expected" > "$work/device-output.log"
echo "ran: $(grep -c '^XZSHOT BEGIN' "$work/device-output.log") screenshot blocks, $(wc -l < "$work/device-output.log") lines of output"
