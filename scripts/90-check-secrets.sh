#!/usr/bin/env bash
# 90-check-secrets.sh — keep device secrets out of git: refuse commits that would contain them.
#
# Usage:
#   scripts/90-check-secrets.sh                  # check what is staged for the next commit (default)
#   scripts/90-check-secrets.sh --tracked        # check every tracked file
#   scripts/90-check-secrets.sh --explain        # also show each hit's line, value masked
#   scripts/90-check-secrets.sh --selftest       # prove the checker on a synthetic dump (no repo changes)
#   scripts/90-check-secrets.sh --install-hook   # run the staged check before every commit
#                                                # (git config core.hooksPath .githooks)
#
# Why
#   backups/ holds full flash dumps whose NVS partition contains the WiFi password, the xiaozhi
#   server's MQTT/websocket credentials and the board UUID. .gitignore keeps backups/ out of git,
#   but a forced add, a copied serial log or a pasted value would still leak them into history.
#
# What it checks (scripts/py/secret_scan.py, on the index version of each file)
#   - no path under backups/, and no flash image (*.bin) larger than 64 KiB
#   - no file contains the value of any NVS key that scripts/30-analyze-flash-image.sh redacts,
#     taken from every dump under backups/. Values stay in memory; only file + key are printed.
#     A match counts only as a token of its own (not inside a longer [A-Za-z0-9_-] run); values
#     under 6 chars and public placeholders (e.g. vendor test defaults) are not searched.
#   Bypass for a deliberate exception: git commit --no-verify (say why in CHANGES.md).
#
# Exit status: 0 clean · 1 leak or forbidden file (listed by path and NVS key) · 2 could not run.
# Output is also saved to logs/<timestamp>-check-secrets.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local mode="--staged" install=0 extra=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --staged|--tracked) mode="$1"; shift ;;
      --explain) extra+=(--explain); shift ;;
      --selftest) python3 -I -B "$XZ_SCRIPTS/py/selftest_secret_scan.py"; return ;;
      --install-hook) install=1; shift ;;
      -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
  git -C "$XZ_ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$XZ_ROOT is not a git repository (git init first)"

  if [[ $install -eq 1 ]]; then
    [[ -x "$XZ_ROOT/.githooks/pre-commit" ]] || die "missing or not executable: .githooks/pre-commit"
    git -C "$XZ_ROOT" config core.hooksPath .githooks
    log "pre-commit hook active: every 'git commit' first runs .githooks/pre-commit (this script, --staged)"
    return 0
  fi

  python3 -I -B "$XZ_SCRIPTS/py/secret_scan.py" --repo "$XZ_ROOT" --backups "$XZ_BACKUPS" "$mode" "${extra[@]}"
}

xz_run_logged check-secrets main "$@"
