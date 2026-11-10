#!/usr/bin/env bash
# 10-fetch-firmware-source.sh — get the xiaozhi-esp32 firmware source into firmware/xiaozhi-esp32.
#
# Usage:
#   scripts/10-fetch-firmware-source.sh              # clone (or update) and check out the newest v* release tag
#   scripts/10-fetch-firmware-source.sh --ref main   # check out a branch / tag / commit instead
#   scripts/10-fetch-firmware-source.sh --info       # don't touch anything, just print what is checked out
#
# What it does
#   - clones https://github.com/78/xiaozhi-esp32 (blob-less partial clone: fast, still has all tags)
#   - checks out the requested ref (default: highest version tag, for reproducible builds)
#   - prints the firmware version (PROJECT_VER in CMakeLists.txt), the number of supported
#     boards, and whether our board (XZ_BOARD, default sp-esp32-s3-1.28-box) exists
#   - records ref + commit in state/firmware-source.env
#
# It refuses to switch refs if the working tree has local modifications, so patches
# under development are never silently discarded.
# Output is also saved to logs/<timestamp>-fetch-firmware-source.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REPO_URL="https://github.com/78/xiaozhi-esp32.git"
SRC_DIR="$XZ_ROOT/firmware/xiaozhi-esp32"
BOARD="${XZ_BOARD:-sp-esp32-s3-1.28-box}"

print_info() {
  [[ -d "$SRC_DIR/.git" ]] || die "source not cloned yet: $SRC_DIR"
  local commit desc ver nboards
  commit="$(git -C "$SRC_DIR" rev-parse HEAD)"
  desc="$(git -C "$SRC_DIR" describe --tags --always 2>/dev/null || echo "$commit")"
  ver="$(grep -oE 'set\(PROJECT_VER "[^"]+"\)' "$SRC_DIR/CMakeLists.txt" | grep -oE '"[^"]+"' | tr -d '"' || true)"
  # A board is any directory holding a config.json. Since v2.x they are grouped by
  # vendor (main/boards/<vendor>/<board>/), older refs keep them flat (main/boards/<board>/).
  nboards="$(find "$SRC_DIR/main/boards" -name config.json | wc -l)"
  echo "=== firmware source ==="
  echo "  path:        $SRC_DIR"
  echo "  checked out: $desc ($commit)"
  echo "  commit date: $(git -C "$SRC_DIR" log -1 --format=%cI)"
  echo "  PROJECT_VER: ${ver:-unknown}"
  echo "  boards:      $nboards (directories with a config.json under main/boards/)"
  local bdir
  bdir="$(find "$SRC_DIR/main/boards" -type d -name "$BOARD" | head -1)"
  if [[ -n "$bdir" ]]; then
    echo "  our board:   $BOARD  -> ${bdir#"$SRC_DIR"/}"
    ls "$bdir" | sed 's/^/                 /'
  else
    echo "  our board:   $BOARD  -> NOT FOUND in this ref"
  fi
  if [[ -n "$(git -C "$SRC_DIR" status --porcelain)" ]]; then
    echo "  local modifications:"
    git -C "$SRC_DIR" status --short | sed 's/^/    /'
  else
    echo "  working tree: clean"
  fi
}

main() {
  local ref="" info_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ref)  [[ $# -ge 2 ]] || die "--ref needs a value"; ref="$2"; shift 2 ;;
      --info) info_only=1; shift ;;
      -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done

  if [[ $info_only -eq 1 ]]; then print_info; return 0; fi

  if [[ ! -d "$SRC_DIR/.git" ]]; then
    log "cloning $REPO_URL"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --filter=blob:none "$REPO_URL" "$SRC_DIR"
  else
    log "fetching updates"
    git -C "$SRC_DIR" fetch --tags --prune origin
  fi

  if [[ -z "$ref" ]]; then
    ref="$(git -C "$SRC_DIR" tag -l 'v*' | sort -V | tail -1)"
    [[ -n "$ref" ]] || die "no v* tags found; pass --ref explicitly"
    log "newest release tag is $ref"
  fi

  if [[ -n "$(git -C "$SRC_DIR" status --porcelain)" ]]; then
    local cur; cur="$(git -C "$SRC_DIR" describe --tags --always)"
    if [[ "$cur" != "$ref" ]]; then
      die "working tree has local modifications; refusing to switch from $cur to $ref"
    fi
    warn "working tree has local modifications; staying on $cur"
  else
    git -C "$SRC_DIR" -c advice.detachedHead=false checkout --quiet "$ref"
  fi

  mkdir -p "$XZ_ROOT/state"
  {
    echo "# written by scripts/10-fetch-firmware-source.sh on $(date -Is)"
    echo "XZ_FW_REF=$ref"
    echo "XZ_FW_COMMIT=$(git -C "$SRC_DIR" rev-parse HEAD)"
  } > "$XZ_ROOT/state/firmware-source.env"

  print_info
}

xz_run_logged fetch-firmware-source main "$@"
