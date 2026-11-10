#!/usr/bin/env bash
# 91-agent-skills.sh — keep the AI-agent setup consistent: one real copy of each skill, links per CLI tool.
#
# Usage:
#   scripts/91-agent-skills.sh check       # validate skills, links and the repo guide (default; changes nothing)
#   scripts/91-agent-skills.sh link        # (re)create the links below, then check
#   scripts/91-agent-skills.sh discover    # check, then ask the installed agent CLIs what they actually load
#   scripts/91-agent-skills.sh discover --claude   # ... also Claude Code: ONE small headless model call (haiku)
#   scripts/91-agent-skills.sh selftest    # prove the checker catches each kind of breakage (temp dir only)
#
# Layout (described in .agents/REPO_GUIDE.md)
#   .agents/skills/<name>/SKILL.md  the only real copy of each skill. Codex reads this directory directly.
#   .claude/skills/<name>           symlink -> ../../.agents/skills/<name>    (Claude Code)
#   .gemini/skills/<name>           symlink -> ../../.agents/skills/<name>    (Gemini CLI: 0.27.3 reads only
#                                   .gemini/skills; newer versions also read .agents/skills and prefer it)
#   AGENTS.md CLAUDE.md GEMINI.md   symlinks -> .agents/REPO_GUIDE.md         (Codex, Claude Code, Gemini CLI)
#
# What "link" changes: creates missing links, repoints wrong symlinks, removes links whose skill is
# gone. It refuses to replace a real file or directory (that would be a copy: move it into
# .agents/skills by hand first).
# What "check" verifies: scripts/py/check_skills.py (frontmatter, the four sections, paths the
# skills name, links, no copies, no symlink loops).
# What "discover" runs (read-only):
#   gemini skills list --all     Gemini CLI's own skill discovery, run from the repo root (no model call)
#   codex debug prompt-input     the prompt Codex would send, searched for each skill and the guide
#                                (no model call)
#   --claude: claude -p --model haiku --debug-file logs/<ts>-claude-debug.log, asked to list its
#   skills. Claude Code has no offline listing; this is one small request. Its debug log is written
#   while skills load, before the request, so it counts even when the request fails (auth, billing).
#   It names no skills, only the dirs and counts: the "Loading skills from:" line must include
#   .claude/skills, and "Loaded N unique skills (... project: K ...)" must have K = the number of
#   skills here. Skill directories in parent folders would also count towards K. When the request
#   succeeds, the reply must also name every skill. Without --claude: in a running session use
#   /reload-skills, then /skills.
#
# Exit status: 0 consistent (discover: and every CLI asked sees every skill) · 1 problems.
# Output is also saved to logs/<timestamp>-agent-skills.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

link_one() {   # link_one DEST TARGET  (TARGET relative to DEST's directory)
  local dest="$1" target="$2"
  if [[ -L "$dest" ]]; then
    [[ "$(readlink "$dest")" == "$target" ]] && return 0
    rm "$dest" && ln -s "$target" "$dest" && log "repointed $dest -> $target"
  elif [[ -e "$dest" ]]; then
    warn "refusing to replace a real file or directory: $dest (a copy; move it into .agents/skills by hand)"
    return 1
  else
    ln -s "$target" "$dest" && log "linked $dest -> $target"
  fi
}

do_link() {
  local rc=0 d name l f
  cd "$XZ_ROOT" || return 1
  local tool
  for tool in .claude .gemini; do
    mkdir -p "$tool/skills"
    for d in .agents/skills/*/; do
      name="$(basename "$d")"
      link_one "$tool/skills/$name" "../../.agents/skills/$name" || rc=1
    done
    for l in "$tool"/skills/*; do
      if [[ -L "$l" && ! -e "$l" ]]; then rm "$l"; log "removed dangling link $l"; fi
    done
  done
  for f in AGENTS.md CLAUDE.md GEMINI.md; do
    link_one "$f" ".agents/REPO_GUIDE.md" || rc=1
  done
  return $rc
}

do_discover() {
  local rc=0 n out names
  names="$(cd "$XZ_ROOT/.agents/skills" && ls -1d */ | tr -d /)"
  echo "=== Gemini CLI: gemini skills list --all ==="
  if command -v gemini >/dev/null 2>&1; then
    out="$(cd "$XZ_ROOT" && timeout 120 gemini skills list --all 2>&1 | sed 's/\x1b\[[0-9;]*m//g')" || true
    for n in $names; do
      if grep -q -w -- "$n" <<<"$out"; then echo "  ok     $n"; else echo "  MISSING $n"; rc=1; fi
    done
  else
    echo "  skip   gemini is not installed"
  fi
  echo "=== Codex: codex debug prompt-input ==="
  if command -v codex >/dev/null 2>&1; then
    out="$(cd "$XZ_ROOT" && timeout 120 codex debug prompt-input 2>&1)" || true
    for n in $names; do
      if grep -q -- "$n" <<<"$out"; then echo "  ok     $n"; else echo "  MISSING $n"; rc=1; fi
    done
    if grep -q 'Repo guide for AI agents' <<<"$out"; then echo "  ok     AGENTS.md (repo guide) is in the prompt"
    else echo "  MISSING AGENTS.md content in the prompt"; rc=1; fi
  else
    echo "  skip   codex is not installed"
  fi
  echo "=== Claude Code: claude -p --debug-file ==="
  if [[ "${1:-}" != "--claude" ]]; then
    echo "  info   not asked (add --claude for one small headless request); links verified above."
    echo "         In a running session: /reload-skills, then /skills"
  elif command -v claude >/dev/null 2>&1; then
    # The debug log can hold account and MCP details: keep it private (mode 600, logs/ is not in
    # git) and print only the lines that name a skill path.
    local dbg authfail hit
    dbg="$XZ_LOGS/$(date +%Y%m%d-%H%M%S)-claude-debug.log"
    ( umask 077; : >"$dbg" )
    out="$(cd "$XZ_ROOT" && timeout 300 claude -p --model haiku --max-turns 1 --debug-file "$dbg" \
      "Without using any tools: list the names of every skill available to you in this session, one per line, nothing else." 2>&1)" || true
    chmod 600 "$dbg" 2>/dev/null
    authfail="$(grep -i -E 'credit balance|invalid api key|not logged in|please run /login|authentication_error' <<<"$out" | head -2)"
    if [[ -n "$authfail" ]]; then
      echo "  note   the model call failed, so only the debug log counts:"
      sed 's/^/    | /' <<<"$authfail"
    fi
    local want got from
    want="$(wc -w <<<"$names")"
    from="$(grep -m1 'Loading skills from:' "$dbg" 2>/dev/null)"
    got="$(grep -m1 -o 'Loaded [0-9]* unique skills ([^)]*)' "$dbg" 2>/dev/null)"
    if grep -q -F "$XZ_ROOT/.claude/skills" <<<"$from"; then
      echo "  ok     debug log: loads project skills from $XZ_ROOT/.claude/skills"
    else
      echo "  PROBLEM debug log: no 'Loading skills from:' line with $XZ_ROOT/.claude/skills"; rc=1
    fi
    if [[ "$(grep -o 'project: [0-9]*' <<<"$got" | grep -o '[0-9]*$')" == "$want" ]]; then
      echo "  ok     debug log: ${got} -> project: $want = the $want skills here"
    else
      echo "  PROBLEM debug log: ${got:-no 'Loaded N unique skills' line}; expected project: $want"; rc=1
    fi
    if [[ -z "$authfail" ]]; then
      for n in $names; do
        if grep -q -- "$n" <<<"$out"; then echo "  ok     $n (named in the reply)"; else echo "  MISSING $n (not in the reply)"; rc=1; fi
      done
    fi
    echo "  log    $dbg (private: may hold account details)"
  else
    echo "  skip   claude is not installed"
  fi
  return $rc
}

main() {
  local cmd="${1:-check}"
  case "$cmd" in
    -h|--help) sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
    check) python3 -I -B "$XZ_SCRIPTS/py/check_skills.py" "$XZ_ROOT" ;;
    link) do_link; local rc=$?; python3 -I -B "$XZ_SCRIPTS/py/check_skills.py" "$XZ_ROOT" && return $rc ;;
    discover) local rc=0; python3 -I -B "$XZ_SCRIPTS/py/check_skills.py" "$XZ_ROOT" || rc=1; do_discover "${2:-}" || rc=1; return $rc ;;
    selftest) python3 -I -B "$XZ_SCRIPTS/py/selftest_check_skills.py" ;;
    *) die "unknown command: $cmd (check | link | discover [--claude] | selftest; try --help)" ;;
  esac
}

xz_run_logged agent-skills main "$@"
