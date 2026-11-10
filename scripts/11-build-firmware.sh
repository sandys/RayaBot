#!/usr/bin/env bash
# 11-build-firmware.sh — build the xiaozhi-esp32 firmware for one board inside docker and
#                        leave flash-ready artifacts in out/<board>/<label>/.
#
# Usage:
#   scripts/11-build-firmware.sh                          # sp-esp32-s3-1.28-box, label stock-<source ref>
#   scripts/11-build-firmware.sh --clean                  # delete build/ + sdkconfig first: full rebuild
#   scripts/11-build-firmware.sh --label NAME --set CONFIG_X=y [--set ...]
#   scripts/11-build-firmware.sh --label NAME --sdkconfig-append FILE
#   scripts/11-build-firmware.sh --board NAME [--variant NAME]
#
# Options
#   --board NAME      board directory name below firmware/xiaozhi-esp32/main/boards/<vendor>/
#                     (default: $XZ_BOARD or sp-esp32-s3-1.28-box); "vendor/name" works too.
#   --variant NAME    which builds[].name of the board's config.json to build. Only needed for
#                     boards that define several; ours defines one, named like the board.
#   --label NAME      name of this build under out/<board>/. Default: stock-<git describe>, i.e.
#                     stock-v2.5.2. A build that is not stock (modified source tree, --set,
#                     --sdkconfig-append) must be given a label, and not one starting with "stock-".
#   --clean           remove build/, sdkconfig and sdkconfig.old first. Downloaded components
#                     (managed_components/, dependencies.lock) and the compiler cache are kept.
#   --set CONFIG_X=V  one sdkconfig line on top of the stock configuration; repeatable. Strings
#                     need their quotes:  --set 'CONFIG_OTA_URL="http://192.168.1.10:8002/xiaozhi/ota/"'
#   --sdkconfig-append FILE
#                     the same, from a file of sdkconfig lines (CONFIG_X=V, "# CONFIG_X is not set",
#                     comments, blank lines); repeatable. Example: config/lang-en-us.sdkconfig
#                     Later lines win over earlier ones, in command-line order.
#
# What it does
#   1. checks the pinned docker image is present (scripts/13-idf-image.sh --pull fetches it) and
#      resolves the board name to its directory, e.g. spotpear/sp-esp32-s3-1.28-box
#   2. inside the container (scripts/container/build-board.sh) runs upstream's own entry point,
#          python scripts/build.py <vendor/board> --name <variant>
#      = configure (target, board Kconfig symbol, sdkconfig defaults; downloads the managed
#        components on the first run), idf.py build, idf.py merge-bin
#   3. copies what flasher_args.json lists - bootloader, partition table, OTA data, application,
#      assets image - under the same relative paths, plus flasher_args.json, flash_args,
#      merged-binary.bin (everything in one image, flash at 0x0), sdkconfig, dependencies.lock,
#      partition-table.csv and debug/ (ELF + map: needed to decode crash backtraces, not flashed)
#   4. writes build-info.txt (source ref + commit, ESP-IDF version, image digest, flash layout,
#      sha256 + size of every file) and SHA256SUMS; for a modified tree also source.diff
#   5. verifies the result with scripts/py/inspect_build.py (the engine of scripts/12-inspect-build.sh)
#      and only then replaces out/<board>/<label>/ - a failed build never touches out/
#
# Labels never share stale state
#   build/ in the firmware tree belongs to one board/variant/label at a time. Asking for another
#   one deletes build/ + sdkconfig first (a full rebuild, softened by ccache); the same label
#   again is incremental. sdkconfig itself is regenerated from the defaults on every run, and
#   every --set / --sdkconfig-append line is checked against the generated sdkconfig: a line
#   that did not take effect (unknown symbol, unmet dependency) fails the build.
#
# Re-runs are incremental; ccache and the component manager's downloads live in cache/idf-home.
# The first build takes several minutes and needs network access (components.espressif.com);
# docs/build.md has the measured times.
#
# It fails if the build changed anything "git status" reports in the upstream tree, or if
# anything it wrote does not belong to the calling user.
# Nothing here touches the device or a serial port.
# Output is also saved to logs/<timestamp>-build-firmware.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$XZ_SCRIPTS/lib/idf-docker.sh"

# NOTE for editing: xz_run_logged calls main on the left side of "||", which switches
# "set -e" off for everything below. Every step that can fail is checked explicitly.

# Board name -> directory below main/boards ("sp-esp32-s3-1.28-box" -> "spotpear/sp-esp32-s3-1.28-box").
resolve_board_dir() {
  local name="$1" boards="$XZ_FW_SRC/main/boards" hits=()
  if [[ -f "$boards/$name/config.json" ]]; then
    echo "$name"; return 0
  fi
  mapfile -t hits < <(cd "$boards" && find . -type f -path "*/$name/config.json" | sed 's|^\./||; s|/config\.json$||' | LC_ALL=C sort)
  case ${#hits[@]} in
    0) die "board '$name' not found below $boards (try: scripts/10-fetch-firmware-source.sh --info)" ;;
    1) echo "${hits[0]}" ;;
    *) die "board name '$name' is ambiguous, use vendor/name: ${hits[*]}" ;;
  esac
}

# Everything that separates the working tree from the checked-out commit, as one patch:
# changes to tracked files plus the files git neither tracks nor ignores.
write_source_diff() {
  local out="$1" file rc
  git -C "$XZ_FW_SRC" diff HEAD --binary > "$out" || return 1
  while IFS= read -r -d '' file; do
    rc=0
    git -C "$XZ_FW_SRC" diff --no-index --binary -- /dev/null "$file" >> "$out" || rc=$?
    [[ $rc -le 1 ]] || return 1          # 1 = "they differ", the expected answer
  done < <(git -C "$XZ_FW_SRC" ls-files --others --exclude-standard -z)
}

main() {
  local board="${XZ_BOARD:-sp-esp32-s3-1.28-box}" variant="" label="" clean=0 appends=() line
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --board)   [[ $# -ge 2 ]] || die "--board needs a name"; board="$2"; shift 2 ;;
      --variant) [[ $# -ge 2 ]] || die "--variant needs a name"; variant="$2"; shift 2 ;;
      --label)   [[ $# -ge 2 ]] || die "--label needs a name"; label="$2"; shift 2 ;;
      --clean)   clean=1; shift ;;
      --set)
        [[ $# -ge 2 ]] || die "--set needs CONFIG_NAME=VALUE"
        [[ "$2" =~ ^CONFIG_[A-Za-z0-9_]+=.+$ ]] || die "--set '$2': expected CONFIG_NAME=VALUE"
        appends+=("$2"); shift 2 ;;
      --sdkconfig-append)
        [[ $# -ge 2 ]] || die "--sdkconfig-append needs a file"
        [[ -f "$2" ]] || die "--sdkconfig-append: no such file: $2"
        while IFS= read -r line || [[ -n "$line" ]]; do
          line="${line%$'\r'}"
          line="${line%"${line##*[![:space:]]}"}"                       # trailing blanks
          if [[ "$line" =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
            appends+=("${BASH_REMATCH[1]}=n")
          elif [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            continue
          elif [[ "$line" =~ ^CONFIG_[A-Za-z0-9_]+=.+$ ]]; then
            appends+=("$line")
          else
            die "$2: not a sdkconfig line: $line"
          fi
        done < "$2"
        shift 2 ;;
      -h|--help) sed -n '2,59p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done

  # Later lines win, like in Kconfig: keep only the last assignment of each symbol.
  local -A last=()
  local i key kept=()
  for i in "${!appends[@]}"; do key="${appends[$i]%%=*}"; last[$key]=$i; done
  for i in "${!appends[@]}"; do
    key="${appends[$i]%%=*}"
    [[ "${last[$key]}" -ne "$i" ]] || kept+=("${appends[$i]}")
  done
  appends=("${kept[@]}")

  [[ -d "$XZ_FW_SRC/.git" ]] || die "firmware source missing: $XZ_FW_SRC (run scripts/10-fetch-firmware-source.sh)"
  xz_idf_image_check
  xz_build_lock

  # ---- what are we building
  local board_dir board_name cfg variants
  board_dir="$(resolve_board_dir "$board")" || return 1
  board_name="${board_dir##*/}"
  cfg="$XZ_FW_SRC/main/boards/$board_dir/config.json"
  variants="$(python3 -c '
import json, sys
print("\n".join(build["name"] for build in json.load(open(sys.argv[1], encoding="utf-8"))["builds"]))
' "$cfg")" || die "cannot read the builds of $cfg"
  if [[ -z "$variant" ]]; then
    [[ "$(wc -l <<<"$variants")" -eq 1 ]] || die "board $board_dir has several variants, pick one with --variant: $(tr '\n' ' ' <<<"$variants")"
    variant="$variants"
  else
    grep -qxF -- "$variant" <<<"$variants" || die "board $board_dir has no variant '$variant' (it has: $(tr '\n' ' ' <<<"$variants"))"
  fi

  local src_ref src_commit src_date src_status src_version stock=1
  src_ref="$(git -C "$XZ_FW_SRC" describe --tags --always)" || die "git describe failed in $XZ_FW_SRC"
  src_commit="$(git -C "$XZ_FW_SRC" rev-parse HEAD)" || die "git rev-parse failed in $XZ_FW_SRC"
  src_date="$(git -C "$XZ_FW_SRC" log -1 --format=%cI)" || die "git log failed in $XZ_FW_SRC"
  src_status="$(git -C "$XZ_FW_SRC" status --porcelain)" || die "git status failed in $XZ_FW_SRC"
  src_version="$(sed -n 's/^set(PROJECT_VER "\(.*\)")$/\1/p' "$XZ_FW_SRC/CMakeLists.txt")"
  [[ -z "$src_status" && ${#appends[@]} -eq 0 ]] || stock=0

  if [[ -z "$label" ]]; then
    [[ $stock -eq 1 ]] || die "this is not a stock build (modified source tree, --set or --sdkconfig-append): name it with --label"
    label="stock-$src_ref"
  fi
  [[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad --label '$label': letters, digits, '.', '_' and '-' only"
  [[ $stock -eq 1 || "$label" != stock-* ]] || die "label '$label' is reserved for unmodified builds; this one is not stock"

  local mode=build
  [[ $clean -eq 0 ]] || mode=clean
  local out_dir="$XZ_OUT/$board_name/$label" build_dir="$XZ_FW_SRC/build"
  local image_id image_digest
  image_id="$(xz_idf_image_id)" || die "docker image inspect failed"
  image_digest="$(xz_idf_image_digest)" || die "docker image inspect failed"

  echo "=== build plan ==="
  echo "  board:        $board_name  (main/boards/$board_dir, variant $variant)"
  echo "  source:       $src_ref ($src_commit), PROJECT_VER ${src_version:-unknown}, working tree $([[ -z "$src_status" ]] && echo clean || echo MODIFIED)"
  echo "  image:        $XZ_IDF_IMAGE ($image_digest)"
  echo "  label:        $label ($([[ $stock -eq 1 ]] && echo stock || echo "not stock"))$([[ $clean -eq 0 ]] || echo ", --clean")"
  echo "  sdkconfig:    $([[ ${#appends[@]} -eq 0 ]] && echo "stock defaults, nothing appended" || echo "${#appends[@]} appended line(s):")"
  [[ ${#appends[@]} -eq 0 ]] || printf '                  %s\n' "${appends[@]}"
  echo "  artifacts to: $out_dir"
  echo

  # ---- build (inside the container)
  local t0=$SECONDS rc=0
  xz_idf_run /xz/container/build-board.sh "$mode" "$board_dir" "$variant" "$label" "${appends[@]}" || rc=$?
  local build_secs=$((SECONDS - t0))
  [[ $rc -eq 0 ]] || die "BUILD FAILED (exit $rc) after ${build_secs} s - out/ was not touched; the error is above and in the log"
  echo
  log "build finished in ${build_secs} s ($((build_secs / 60)) min $((build_secs % 60)) s)"

  # ---- project rules: upstream tree as it was, nothing owned by someone else
  local status_after foreign
  status_after="$(git -C "$XZ_FW_SRC" status --porcelain)" || die "git status failed in $XZ_FW_SRC"
  [[ "$status_after" == "$src_status" ]] || die "the build changed what git status reports for the firmware tree. Before:
${src_status:-  (clean)}
After:
$status_after"
  foreign="$(find "$XZ_FW_SRC" "$XZ_IDF_HOME" \( ! -uid "$(id -u)" -o ! -gid "$(id -g)" \) -print -quit)"
  [[ -z "$foreign" ]] || die "ownership check failed: $foreign does not belong to $(id -un):$(id -gn)"

  # ---- collect into a staging directory next to the final one
  local stage="$XZ_OUT/$board_name/.$label.staging" flash_files offset rel
  rm -rf "$stage" || die "cannot clear $stage"
  mkdir -p "$stage/debug" || die "cannot create $stage"
  flash_files="$(python3 -I -B "$XZ_SCRIPTS/py/inspect_build.py" flash-files "$build_dir/flasher_args.json")" \
    || die "cannot read $build_dir/flasher_args.json"
  while IFS=$'\t' read -r offset rel; do
    [[ -f "$build_dir/$rel" ]] || die "flasher_args.json lists $rel (at $offset) but the build did not produce it"
    install -D -m 0644 "$build_dir/$rel" "$stage/$rel" || die "copy failed: $rel"
  done <<<"$flash_files"
  local f app_rel
  for f in flasher_args.json flash_args merged-binary.bin; do
    install -m 0644 "$build_dir/$f" "$stage/$f" || die "the build did not produce $f"
  done
  install -m 0644 "$build_dir/xz-partition-table.csv" "$stage/partition-table.csv" || die "the container did not write xz-partition-table.csv"
  install -m 0644 "$XZ_FW_SRC/sdkconfig" "$stage/sdkconfig" || die "no sdkconfig in the firmware tree"
  install -m 0644 "$XZ_FW_SRC/dependencies.lock" "$stage/dependencies.lock" || die "no dependencies.lock in the firmware tree"
  app_rel="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["app"]["file"])' "$build_dir/flasher_args.json")" \
    || die "flasher_args.json has no app entry"
  for f in "${app_rel%.bin}.elf" "${app_rel%.bin}.map" bootloader/bootloader.elf; do
    install -m 0644 "$build_dir/$f" "$stage/debug/$(basename "$f")" || die "the build did not produce $f"
  done
  if [[ ${#appends[@]} -gt 0 ]]; then
    {
      echo "# sdkconfig lines this build applied on top of the stock configuration"
      echo "# (scripts/11-build-firmware.sh --label $label; reuse with --sdkconfig-append <this file>)"
      printf '%s\n' "${appends[@]}"
    } > "$stage/sdkconfig.append" || die "cannot write sdkconfig.append"
  fi
  if [[ -n "$src_status" ]]; then
    write_source_diff "$stage/source.diff" || die "cannot capture the source modifications (git diff)"
  fi

  # ---- SHA256SUMS + build-info.txt
  # (the list is written next to the staging directory first, so that it does not list itself)
  ( cd "$stage" && find . -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 sha256sum ) > "$stage.sums" \
    || die "sha256sum failed"
  mv "$stage.sums" "$stage/SHA256SUMS" || die "cannot write SHA256SUMS"

  local logfile toolchain="$build_dir/xz-toolchain.env" patch
  logfile="$(ls -t "$XZ_LOGS"/*-build-firmware.log 2>/dev/null | head -1)"
  [[ -f "$toolchain" ]] || die "the container did not write $toolchain"
  {
    echo "# build-info.txt - written by scripts/11-build-firmware.sh"
    echo "# Describes the files next to it. Flash layout: flasher_args.json; check: scripts/12-inspect-build.sh"
    echo
    echo "board:           $board_name"
    echo "board dir:       main/boards/$board_dir"
    echo "variant:         $variant"
    echo "label:           $label"
    echo "stock build:     $([[ $stock -eq 1 ]] && echo yes || echo no)"
    echo "built:           $(date -Is)"
    echo "built on:        $(hostname) ($(uname -srm)), by $(id -un)"
    echo "build command:   python scripts/build.py $board_dir --name $variant   (in the container, cwd /project)"
    echo "build duration:  ${build_secs} s"
    echo "build log:       ${logfile#"$XZ_ROOT"/}"
    if [[ ${#appends[@]} -eq 0 ]]; then
      echo "sdkconfig append: none"
    else
      echo "sdkconfig append: ${#appends[@]} line(s), also in sdkconfig.append"
      printf '    %s\n' "${appends[@]}"
    fi
    echo
    echo "[source]"
    echo "source repo:     $(git -C "$XZ_FW_SRC" remote get-url origin 2>/dev/null || echo unknown)"
    echo "source ref:      $src_ref"
    echo "source commit:   $src_commit"
    echo "commit date:     $src_date"
    echo "project version: ${src_version:-unknown}"
    if [[ -z "$src_status" ]]; then
      echo "working tree:    clean (git status reports nothing, before and after the build)"
    else
      echo "working tree:    MODIFIED - the full delta against the commit is in source.diff"
      sed 's/^/    /' <<<"$src_status"
      for patch in "$XZ_ROOT"/patches/*.patch; do
        [[ -f "$patch" ]] || continue
        echo "patch:           $(basename "$patch") $(git -C "$XZ_FW_SRC" apply -R --check "$patch" 2>/dev/null && echo "applied" || echo "NOT applied") (sha256 $(sha256sum "$patch" | cut -d' ' -f1))"
      done
    fi
    echo
    echo "[toolchain]"
    echo "docker image:    $XZ_IDF_IMAGE"
    echo "image digest:    $image_digest"
    echo "image id:        $image_id"
    awk '{ key = $0; sub(/=.*/, "", key); value = $0; sub(/^[^=]*=/, "", value); gsub(/_/, " ", key)
           printf "%-16s %s\n", key ":", value }' "$toolchain"
    echo
    echo "[flash layout]   offset -> file, as in flasher_args.json (same paths, relative to this directory)"
    python3 -c '
import json, sys
args = json.load(open(sys.argv[1]))
settings, extra = args.get("flash_settings", {}), args.get("extra_esptool_args", {})
print("chip %s, flash mode %s, flash freq %s, flash size %s" % (
    extra.get("chip"), settings.get("flash_mode"), settings.get("flash_freq"), settings.get("flash_size")))
for offset, name in sorted(args["flash_files"].items(), key=lambda item: int(item[0], 0)):
    print("%-9s %s" % (offset, name))
print("%-9s %s" % ("0x0", "merged-binary.bin   (all of the above in ONE image - use it instead of them, not with them)"))
' "$stage/flasher_args.json" || die "cannot read the staged flasher_args.json"
    echo
    echo "[files]          sha256, bytes, path - the same hashes are in SHA256SUMS (sha256sum -c SHA256SUMS)"
    local hash path
    while read -r hash path; do
      printf '%s  %9d  %s\n' "$hash" "$(stat -c %s "$stage/$path")" "$path"
    done < "$stage/SHA256SUMS"
  } > "$stage/build-info.txt" || die "cannot write build-info.txt"

  # ---- verify, then publish
  echo
  python3 -I -B "$XZ_SCRIPTS/py/inspect_build.py" inspect "$stage" \
    || die "artifact check FAILED - out/ was not updated; the rejected files are in $stage"
  rm -rf "$out_dir" || die "cannot replace $out_dir"
  mv "$stage" "$out_dir" || die "cannot move the artifacts to $out_dir"
  foreign="$(find "$XZ_OUT" \( ! -uid "$(id -u)" -o ! -gid "$(id -g)" \) -print -quit)"
  [[ -z "$foreign" ]] || die "ownership check failed: $foreign does not belong to $(id -un):$(id -gn)"

  echo
  echo "=== done ==="
  echo "  artifacts:  ${out_dir#"$XZ_ROOT"/}/  ($(find "$out_dir" -type f | wc -l) files, $(du -sh "$out_dir" | cut -f1))"
  echo "  build time: ${build_secs} s ($((build_secs / 60)) min $((build_secs % 60)) s) - $(sed -n 's/^build_mode=//p' "$toolchain")"
  echo "  re-check:   scripts/12-inspect-build.sh --board $board_name --label $label"
}

xz_run_logged build-firmware main "$@"
