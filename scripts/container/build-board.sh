#!/usr/bin/env bash
# scripts/container/build-board.sh — the half of scripts/11-build-firmware.sh that runs INSIDE the container.
#
# Never run this on the host. 11-build-firmware.sh starts it as
#
#     xz_idf_run /xz/container/build-board.sh <mode> <board-dir> <variant> <label> [CONFIG_X=VALUE ...]
#
# with cwd = /project (the firmware tree). The image entrypoint has already sourced
# $IDF_PATH/export.sh, so idf.py and "python" (the IDF virtualenv) are on PATH.
#
#   <mode>        build | clean   (clean = delete build/, sdkconfig, sdkconfig.old first)
#   <board-dir>   path below main/boards, e.g. spotpear/sp-esp32-s3-1.28-box
#   <variant>     builds[].name from that board's config.json (the board name reported to the OTA server)
#   <label>       the name this build gets under out/<board>/ - decides who owns build/ (see below)
#   CONFIG_X=...  sdkconfig lines to apply on top of the stock configuration
#
# Why upstream's scripts/build.py and not our own idf.py calls
#   It is the canonical per-board entry point (firmware AGENTS.md, .github/workflows/build.yml):
#   it maps the board directory to its Kconfig symbol (CONFIG_BOARD_TYPE_...), writes that plus
#   config.json's sdkconfig_append into build/xiaozhi-build.sdkconfig.defaults, then runs
#       idf.py -DIDF_TARGET=<target> -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;build/xiaozhi-build.sdkconfig.defaults" \
#              -DBOARD_NAME=<variant> reconfigure     (this is also where managed components get downloaded)
#       idf.py build
#       idf.py merge-bin                              (-> build/merged-binary.bin)
#   and checks that Kconfig really accepted the board symbol. Calling it keeps us identical
#   to CI and immune to upstream reshuffling those steps.
#
# No stale state between labels
#   - sdkconfig: build.py moves it to sdkconfig.old and regenerates it from the defaults on
#     EVERY run, so an old sdkconfig (or a menuconfig edit) can never leak into a build.
#   - build/: belongs to exactly one board/variant/label, recorded in build/xz-build-id. If the
#     requested build is a different one, build/ + sdkconfig + sdkconfig.old are deleted first,
#     exactly like "clean". Same label again = incremental build.
#   - our extra sdkconfig lines: rewritten (or removed) on every run, see below.
#
# How the extra CONFIG_ lines get in without touching upstream files
#   build.py has no option for arbitrary sdkconfig lines. ESP-IDF, however, loads
#   "<file>.<target>" right after every <file> named in SDKCONFIG_DEFAULTS, if it exists
#   ($IDF_PATH/tools/cmake/kconfig.cmake; documented as target-specific sdkconfig defaults).
#   So the lines go into build/xiaozhi-build.sdkconfig.defaults.<target>: last file in the
#   list, highest priority, and inside the git-ignored build/. Because this leans on the name
#   build.py gives its own fragment, every requested line is checked against the final
#   sdkconfig afterwards - if a line did not take effect the build FAILS instead of
#   silently producing a stock image.
#
# Stage markers: XIAOZHI_BUILD_STAGES=1 makes build.py print "XIAOZHI_STAGE <name>"; they are
# time-stamped here so the log shows how long resolving / compiling / packaging took.
#
# Left behind for the host half: build/xz-toolchain.env (toolchain facts for build-info.txt)
# and build/xz-partition-table.csv (the partition table decoded by ESP-IDF's own tool).

set -euo pipefail

[[ $# -ge 4 ]] || { echo "usage: build-board.sh <build|clean> <board-dir> <variant> <label> [CONFIG_X=VALUE ...]" >&2; exit 2; }
mode="$1"; board_dir="$2"; variant="$3"; label="$4"; shift 4
appends=("$@")

[[ -f /.dockerenv && -f scripts/build.py ]] || { echo "build-board.sh: must run inside the container, in the firmware tree" >&2; exit 2; }
[[ "$mode" == build || "$mode" == clean ]] || { echo "build-board.sh: unknown mode '$mode'" >&2; exit 2; }

say() { printf '[container %(%H:%M:%S)T] %s\n' -1 "$*"; }

# cache_var NAME -> value of NAME in build/CMakeCache.txt (empty if unset). sed quits at the
# first hit instead of being piped into head, so pipefail never sees a SIGPIPE.
cache_var() { sed -n "/^$1:/{s/^[^=]*=//p;q}" build/CMakeCache.txt; }

# Prefix build.py's stage markers with the time; pass everything else through untouched.
stamp_stages() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == XIAOZHI_STAGE\ * ]]; then say "$line"; else printf '%s\n' "$line"; fi
  done
}

say "$(idf.py --version 2>/dev/null | tail -1), $(nproc) cpus, uid $(id -u):$(id -g), mode=$mode"

target="$(python -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["target"])' "main/boards/$board_dir/config.json")"

# ---- who owns build/ ?
build_id="board_dir=$board_dir variant=$variant label=$label"
wipe=""
if [[ "$mode" == clean ]]; then
  wipe="--clean was requested"
elif [[ -d build && ! -f build/xz-build-id ]]; then
  wipe="build/ exists but was not made by this script"
elif [[ -f build/xz-build-id && "$(cat build/xz-build-id)" != "$build_id" ]]; then
  wipe="build/ belongs to another build ($(cat build/xz-build-id))"
elif [[ -f build/CMakeCache.txt && "$(cache_var IDF_TARGET)" != "$target" ]]; then
  # build.py would run "idf.py fullclean" here, which also deletes our files in build/.
  wipe="build/ is configured for target $(cache_var IDF_TARGET), this board needs $target"
fi
if [[ -n "$wipe" ]]; then
  say "full rebuild: $wipe -> removing build/ sdkconfig sdkconfig.old (managed_components/ and dependencies.lock are kept)"
  rm -rf build sdkconfig sdkconfig.old
else
  say "incremental: build/ $([[ -d build ]] && echo "already belongs to this build" || echo "does not exist yet")"
fi
mkdir -p build
printf '%s\n' "$build_id" > build/xz-build-id

# ---- extra sdkconfig lines: always rewritten, never inherited from the previous run
rm -f build/xiaozhi-build.sdkconfig.defaults.*
if [[ ${#appends[@]} -gt 0 ]]; then
  hook="build/xiaozhi-build.sdkconfig.defaults.$target"
  {
    echo "# Generated by scripts/container/build-board.sh from --set / --sdkconfig-append (label $label)."
    echo "# ESP-IDF loads this right after build/xiaozhi-build.sdkconfig.defaults because of the .$target suffix."
    printf '%s\n' "${appends[@]}"
  } > "$hook"
  say "sdkconfig append (${#appends[@]} line(s)) -> $hook"
  printf '    %s\n' "${appends[@]}"
else
  say "sdkconfig append: none (stock configuration)"
fi

# ---- configure + build + merge, the upstream way
say "python scripts/build.py $board_dir --name $variant"
XIAOZHI_BUILD_STAGES=1 python scripts/build.py "$board_dir" --name "$variant" 2>&1 | stamp_stages

[[ -f sdkconfig && -f build/flasher_args.json && -f build/merged-binary.bin ]] \
  || { echo "build-board.sh: build.py reported success but sdkconfig / flasher_args.json / merged-binary.bin are missing" >&2; exit 1; }

# ---- did every requested line make it into the final sdkconfig?
if [[ ${#appends[@]} -gt 0 ]]; then
  say "checking the appended lines against the generated sdkconfig"
  rejected=0
  for line in "${appends[@]}"; do
    key="${line%%=*}"; value="${line#*=}"
    actual="$(grep -E "^(# )?${key}(=| is not set)" sdkconfig || true)"
    if [[ "$value" == n ]]; then
      # "not set" and "does not exist / dependency not met" both mean off.
      if grep -q "^${key}=" sdkconfig; then ok=0; else ok=1; fi
    else
      if grep -qxF -- "$line" sdkconfig; then ok=1; else ok=0; fi
    fi
    if [[ $ok -eq 1 ]]; then
      printf '    ok        %s\n' "$line"
    else
      printf '    REJECTED  %s   (sdkconfig has: %s)\n' "$line" "${actual:-no such symbol - unknown name or unmet dependency}"
      rejected=$((rejected + 1))
    fi
  done
  [[ $rejected -eq 0 ]] || { echo "build-board.sh: $rejected appended sdkconfig line(s) did not take effect - refusing to hand out this build" >&2; exit 1; }
fi

# ---- facts for the host half
pt_bin="$(python -c 'import json, sys; print(json.load(open(sys.argv[1]))["partition-table"]["file"])' build/flasher_args.json)"
python "$IDF_PATH/components/partition_table/gen_esp32part.py" "build/$pt_bin" > build/xz-partition-table.csv 2>/dev/null \
  || { echo "build-board.sh: gen_esp32part.py could not decode build/$pt_bin" >&2; exit 1; }
{
  /xz/container/idf-info.sh
  # The compiler comes from IDF's toolchain file, so it is not in CMakeCache.txt.
  cc="$(python -c 'import json, sys; print(json.load(open(sys.argv[1])).get("c_compiler", ""))' build/project_description.json)"
  printf 'c_compiler=%s\n' "$( { "$cc" --version 2>/dev/null || echo unknown; } | sed -n 1p )"
  printf 'idf_target=%s\n' "$(cache_var IDF_TARGET)"
  printf 'board_name=%s\n' "$(cache_var BOARD_NAME)"
  printf 'build_mode=%s\n' "$([[ -n "$wipe" ]] && echo "full rebuild ($wipe)" || echo incremental)"
} > build/xz-toolchain.env

say "done"
