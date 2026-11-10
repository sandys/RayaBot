#!/usr/bin/env bash
# 92-check-gitignore.sh — prove .gitignore keeps out what must stay out and lets in what must be committed.
#
# Usage:
#   scripts/92-check-gitignore.sh              # check the repo's .gitignore (changes nothing)
#   scripts/92-check-gitignore.sh --untracked  # also list the untracked files that "git add -A" would take
#   scripts/92-check-gitignore.sh --selftest   # prove the checker catches a broken .gitignore
#                                              # (a throwaway repo under cache/, removed afterwards)
#
# Why
#   .gitignore is the first guard. Secret-bearing paths stay out: backups/, flash images anywhere,
#   raw serial captures, archives, keys. So do bulky re-creatable ones: firmware/, out/, cache/,
#   prebuilt/, tools/, logs/, state/. The pre-commit hook (scripts/90-check-secrets.sh) is the
#   second guard. A rule that is too broad fails the other way: it silently leaves evidence,
#   config or skill links out of commits. This script checks both directions. Git itself judges
#   sample paths (git check-ignore --no-index), so the files need not exist.
#
# Checks
#   ignored  sample paths that must be ignored, at least one per rule in .gitignore
#   kept     sample paths that must stay committable: evidence logs and screenshots, config
#            fragments, patches, scripts and their helpers, skills, the per-tool skill links,
#            the repo guide and its links
#   tracked  no tracked file matches an ignore rule (git ls-files -ci --exclude-standard)
#   Keep both sample lists in step with .gitignore and the Layout table in .agents/REPO_GUIDE.md.
#
# Exit status: 0 every expectation holds · 1 at least one failed · 2 could not run.
# Output is also saved to logs/<timestamp>-check-gitignore.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Must be ignored. Real names where they exist, so the samples look like what would leak.
MUST_IGNORE=(
  # secrets: dumps and their sidecars, flash images elsewhere, raw captures, archives, keys
  backups/aca704229d70/20261110-004927-factory-full-16MB.bin
  backups/aca704229d70/20261110-004927-factory-full-16MB.bin.txt
  backups/aca704229d70/20261110-004927-factory-full-16MB.bin.sha256
  docs/copied-dump.bin
  merged-binary.bin
  notes/capture.raw
  backups.zip dumps.7z dumps.rar logs.tar logs.tgz dump.bin.gz dump.bin.xz
  .env .env.local .gemini/.env server.pem server.key client.p12
  # large or re-creatable
  firmware/xiaozhi-esp32/main/main.cc
  out/sp-esp32-s3-1.28-box/dev-name-v2.5.2/build-info.txt
  cache/idf-home/.cache/ccache/stats
  prebuilt/README.txt
  tools/esptool.exe
  docs/xiaozhi.elf docs/xiaozhi.map
  esptool.exe scripts/win/helper.dll
  # per-machine state and per-run output
  state/device.env
  logs/20261110-085037-dev-demo.log
  logs/screens/20261110-085037-name-demo-01.jpg
  logs/serial/20261110-085037-shot-name-demo.raw
  # personal settings, Python, editors, operating systems
  .claude/settings.local.json CLAUDE.local.md
  scripts/py/__pycache__/check_skills.cpython-312.pyc scripts/py/stray.pyc
  .venv/bin/python3 venv/bin/python3
  .vscode/settings.json .idea/workspace.xml
  .README.md.swp .README.md.swo README.md~
  docs/.DS_Store docs/evidence/Thumbs.db desktop.ini
  docs/evidence/face-demo/console.log:Zone.Identifier
)

# Must stay committable.
MUST_KEEP=(
  .gitignore README.md CHANGES.md AGENTS.md CLAUDE.md GEMINI.md
  .agents/REPO_GUIDE.md
  .agents/skills/xiaozhi-flash-and-verify/SKILL.md
  .agents/skills/scripted-hardware-bringup/assets/script-template.sh
  .claude/skills/xiaozhi-flash-and-verify .gemini/skills/xiaozhi-flash-and-verify
  .githooks/pre-commit
  config/dev-name-demo.sdkconfig config/lang-en-us.sdkconfig
  patches/xz-dev-tools.patch
  scripts/28-dev-demo.sh scripts/lib/common.sh scripts/py/check_skills.py
  scripts/win/serial-capture.ps1 scripts/container/build-board.sh
  docs/build.md docs/board-dossier.md docs/device/chip-info.txt
  docs/evidence/factory-boot.log
  docs/evidence/face-demo/console.log docs/evidence/face-demo/20261110-065435-face-demo-01.jpg
  docs/evidence/name-demo/20261110-085037-name-demo-console.log
  docs/evidence/name-demo/20261110-085037-name-demo-listen.log
  docs/evidence/name-demo/20261110-085037-name-demo-01.jpg
  # a build's provenance, should evidence ever include it
  docs/evidence/name-demo/build-info.txt docs/evidence/name-demo/SHA256SUMS
)

# verdict <repo> <path>: what the repo's ignore rules say about <path> - ignored, kept or error.
verdict() {
  local rc=0
  git -C "$1" check-ignore -q --no-index -- "$2" || rc=$?
  case $rc in
    0) echo ignored ;;
    1) echo kept ;;
    *) echo error ;;
  esac
}

# rule <repo> <path>: the .gitignore line that matches <path>, e.g. ".gitignore:17:*.bin".
rule() {
  git -C "$1" check-ignore -v --no-index -- "$2" 2>/dev/null | cut -f1 || true
}

# report <check> <failures, one per line> <what a pass means>; returns 1 on failures.
report() {
  if [[ -z "$2" ]]; then
    printf '  PASS  %-8s %s\n' "$1" "$3"
  else
    printf '  FAIL  %-8s %s expectation(s) broken:\n%s' "$1" "$(grep -c . <<<"$2")" "$2"
    return 1
  fi
}

# check_repo <repo>: runs the three checks against that repo's rules; returns 0 when all hold.
check_repo() {
  local repo="$1" p v bad=0 miss_ignored="" miss_kept="" miss_tracked="" n_tracked
  for p in "${MUST_IGNORE[@]}"; do
    v="$(verdict "$repo" "$p")"
    [[ $v == ignored ]] || miss_ignored+="          $p  (git: $v)"$'\n'
  done
  for p in "${MUST_KEEP[@]}"; do
    v="$(verdict "$repo" "$p")"
    [[ $v == kept ]] || miss_kept+="          $p  (git: $v, by $(rule "$repo" "$p"))"$'\n'
  done
  while IFS= read -r p; do
    if [[ -n "$p" ]]; then
      miss_tracked+="          $p  (tracked, but matches $(rule "$repo" "$p"))"$'\n'
    fi
  done < <(git -C "$repo" ls-files -ci --exclude-standard)
  n_tracked="$(git -C "$repo" ls-files | wc -l)"
  report ignored "$miss_ignored" "all ${#MUST_IGNORE[@]} sample paths are ignored (secrets, re-creatable, per-machine, personal)" || bad=1
  report kept "$miss_kept" "all ${#MUST_KEEP[@]} sample paths stay committable (evidence, config, patches, scripts, skills)" || bad=1
  report tracked "$miss_tracked" "none of the $n_tracked tracked files matches an ignore rule" || bad=1
  return $bad
}

selftest() {
  mkdir -p "$XZ_ROOT/cache"
  local tmp fails=0
  tmp="$(mktemp -d "$XZ_ROOT/cache/gitignore-selftest.XXXXXX")"
  git -C "$tmp" init -q
  # expect <pass|fail> <case> [text the failure must name]
  expect() {
    local want="$1" what="$2" needle="${3:-}" out rc=0
    out="$(check_repo "$tmp")" || rc=$?
    if [[ $want == pass && $rc -eq 0 ]] || [[ $want == fail && $rc -ne 0 && "$out" == *"$needle"* ]]; then
      echo "  ok     $what"
    else
      fails=$((fails + 1))
      echo "  WRONG  $what (checker exit $rc)"
      sed 's/^/         /' <<<"$out"
    fi
  }
  cp "$XZ_ROOT/.gitignore" "$tmp/.gitignore"
  expect pass "the repo's .gitignore passes"
  grep -vx '/backups/' "$XZ_ROOT/.gitignore" >"$tmp/.gitignore"
  expect fail "without /backups/, the dump's sidecar files are no longer ignored" "factory-full-16MB.bin.txt"
  grep -vx '\*\.bin' "$XZ_ROOT/.gitignore" >"$tmp/.gitignore"
  expect fail "without *.bin, a dump copied into docs/ is no longer ignored" "docs/copied-dump.bin"
  { cat "$XZ_ROOT/.gitignore"; echo '*.log'; } >"$tmp/.gitignore"
  expect fail "an extra *.log rule would leave the evidence logs out of commits" "docs/evidence/factory-boot.log"
  cp "$XZ_ROOT/.gitignore" "$tmp/.gitignore"
  mkdir -p "$tmp/docs"
  printf 'not a dump\n' >"$tmp/docs/forced.bin"
  git -C "$tmp" add -f docs/forced.bin
  expect fail "a force-added file that matches a rule is reported" "docs/forced.bin"
  rm -rf "$tmp"
  if [[ $fails -eq 0 ]]; then
    log "selftest: OK - the checker passed the real .gitignore and caught all 4 broken ones"
  else
    log "selftest: FAILED - $fails case(s) judged wrong"
    return 1
  fi
}

main() {
  local untracked=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --untracked) untracked=1; shift ;;
      --selftest) selftest; return ;;
      -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
  git -C "$XZ_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { warn "$XZ_ROOT is not a git work tree"; return 2; }
  [[ -f "$XZ_ROOT/.gitignore" ]] || { warn "no .gitignore in $XZ_ROOT"; return 1; }

  echo "=== $XZ_ROOT/.gitignore ==="
  local rc=0
  check_repo "$XZ_ROOT" || rc=$?
  if [[ $untracked -eq 1 ]]; then
    echo "=== untracked files that git add -A would take ==="
    git -C "$XZ_ROOT" ls-files --others --exclude-standard | sed 's/^/  /'
  fi
  if [[ $rc -eq 0 ]]; then
    log "result: OK - .gitignore keeps the samples out and in as expected"
  else
    log "result: FAIL - fix .gitignore (or the sample lists, if the layout changed on purpose)"
  fi
  return $rc
}

xz_run_logged check-gitignore main "$@"
