#!/usr/bin/env bash
# 19-patches.sh — manage our local changes to the upstream firmware as patch files.
#
# Usage:
#   scripts/19-patches.sh status     # for each patches/*.patch: applied / not applied / conflicts
#   scripts/19-patches.sh apply      # apply every patch that is not applied yet
#   scripts/19-patches.sh revert     # un-apply every applied patch -> pristine upstream tree
#   scripts/19-patches.sh refresh    # rewrite patches/xz-dev-tools.patch from the current working tree
#
# Why patch files
#   firmware/xiaozhi-esp32 is an upstream checkout that we want to be able to update or
#   reset at any time. Our own changes (dev tooling such as the serial screenshot dump)
#   therefore live in patches/ in this repo, not as commits or loose edits over there.
#   A stock build is "revert, then build"; a dev build is "apply, then build".
#
# Workflow for changing a patch
#   1. scripts/19-patches.sh apply
#   2. edit files inside firmware/xiaozhi-esp32
#   3. scripts/19-patches.sh refresh      (captures ALL tracked changes + new files under main/
#                                          into patches/xz-dev-tools.patch)
#   4. scripts/19-patches.sh revert && scripts/19-patches.sh apply   (proves it round-trips)
#
# "applied" is decided by git itself: a patch counts as applied when it reverse-applies
# cleanly (git apply -R --check), and as applicable when it forward-applies cleanly.
# Output is also saved to logs/<timestamp>-patches.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SRC_DIR="$XZ_ROOT/firmware/xiaozhi-esp32"
PATCH_DIR="$XZ_ROOT/patches"
MAIN_PATCH="$PATCH_DIR/xz-dev-tools.patch"

patch_state() {   # prints: applied | clean | conflict
  local p="$1"
  if git -C "$SRC_DIR" apply -R --check "$p" 2>/dev/null; then echo applied
  elif git -C "$SRC_DIR" apply --check "$p" 2>/dev/null; then echo clean
  else echo conflict; fi
}

list_patches() { find "$PATCH_DIR" -maxdepth 1 -name '*.patch' 2>/dev/null | sort; }

cmd_status() {
  echo "=== patches against $(git -C "$SRC_DIR" describe --tags --always) ==="
  local p any=0
  while read -r p; do
    [[ -n "$p" ]] || continue
    any=1
    printf '  %-10s %s  (%s)\n' "$(patch_state "$p")" "$(basename "$p")" \
      "$(git -C "$SRC_DIR" apply --numstat "$p" 2>/dev/null | awk '{a+=$1; d+=$2; n++} END{printf "%d files, +%d -%d", n, a, d}')"
  done < <(list_patches)
  [[ $any -eq 1 ]] || echo "  (no patch files in patches/)"
  echo "=== working tree ==="
  if [[ -n "$(git -C "$SRC_DIR" status --porcelain)" ]]; then
    git -C "$SRC_DIR" status --short | sed 's/^/  /'
  else
    echo "  clean (pristine upstream)"
  fi
}

cmd_apply() {
  local p st
  while read -r p; do
    [[ -n "$p" ]] || continue
    st="$(patch_state "$p")"
    case "$st" in
      applied)  log "already applied: $(basename "$p")" ;;
      clean)    git -C "$SRC_DIR" apply --whitespace=nowarn "$p"; log "applied: $(basename "$p")" ;;
      conflict) git -C "$SRC_DIR" apply --check "$p" || true; die "patch does not apply: $(basename "$p")" ;;
    esac
  done < <(list_patches)
  cmd_status
}

cmd_revert() {
  local p st
  while read -r p; do
    [[ -n "$p" ]] || continue
    st="$(patch_state "$p")"
    if [[ "$st" == "applied" ]]; then
      git -C "$SRC_DIR" apply -R --whitespace=nowarn "$p"; log "reverted: $(basename "$p")"
    else
      log "not applied: $(basename "$p")"
    fi
  done < <(list_patches | sort -r)
  cmd_status
}

cmd_refresh() {
  mkdir -p "$PATCH_DIR"
  # Tell git about new source files so they show up in the diff, without staging content.
  local new
  new="$(git -C "$SRC_DIR" ls-files --others --exclude-standard -- main | grep -E '\.(cc|c|cpp|h|hpp|txt|yml|json|csv|projbuild)$' || true)"
  if [[ -n "$new" ]]; then
    # shellcheck disable=SC2086
    git -C "$SRC_DIR" add -N -- $new
  fi
  local tmp; tmp="$(mktemp)"
  git -C "$SRC_DIR" diff --no-color -- . ':(exclude)sdkconfig' ':(exclude)sdkconfig.old' > "$tmp"
  # Drop the intent-to-add index entries again: left in place, a later "revert" (which deletes
  # the files) would make the pristine tree report them as deleted in "git status".
  local ita
  ita="$(git -C "$SRC_DIR" diff --name-only --diff-filter=A -- main 2>/dev/null || true)"
  if [[ -n "$ita" ]]; then
    # shellcheck disable=SC2086
    git -C "$SRC_DIR" reset --quiet -- $ita
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; die "working tree has no changes to capture"; }
  mv "$tmp" "$MAIN_PATCH"
  log "wrote $MAIN_PATCH"
  git -C "$SRC_DIR" apply --numstat "$MAIN_PATCH" | awk '{printf "  +%-4s -%-4s %s\n", $1, $2, $3}'
}

main() {
  [[ -d "$SRC_DIR/.git" ]] || die "firmware source missing: run scripts/10-fetch-firmware-source.sh"
  case "${1:-status}" in
    status)  cmd_status ;;
    apply)   cmd_apply ;;
    revert)  cmd_revert ;;
    refresh) cmd_refresh ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command: $1 (status | apply | revert | refresh)" ;;
  esac
}

xz_run_logged patches main "$@"
