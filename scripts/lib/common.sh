#!/usr/bin/env bash
# scripts/lib/common.sh — shared helpers for every script in this project.
#
# Source it, never execute it:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# What it gives you
#   XZ_ROOT / XZ_SCRIPTS / XZ_LOGS / XZ_TOOLS / XZ_BACKUPS / XZ_DOCS   project paths
#   log / warn / die             messages on stderr (die exits 1)
#   win_path <linux-path>        Linux path -> Windows path (\\wsl.localhost\... or C:\...)
#   win_ps <script.ps1> [args]   run a PowerShell script on the Windows host, CRs stripped
#   xz_run_logged <name> <cmd>   run cmd, mirror stdout+stderr into logs/<timestamp>-<name>.log
#
# Why the Windows helpers exist
#   This project runs inside WSL2, but the ESP32 is plugged into the *Windows* host.
#   WSL2 has no direct USB access, so anything that touches the device (listing
#   COM ports, flashing, serial monitor) is executed on Windows through WSL interop
#   (powershell.exe / *.exe are callable from bash).

set -euo pipefail

XZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
XZ_SCRIPTS="$XZ_ROOT/scripts"
XZ_LOGS="$XZ_ROOT/logs"
XZ_TOOLS="$XZ_ROOT/tools"
XZ_BACKUPS="$XZ_ROOT/backups"
XZ_DOCS="$XZ_ROOT/docs"
export XZ_ROOT XZ_SCRIPTS XZ_LOGS XZ_TOOLS XZ_BACKUPS XZ_DOCS

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# Linux path -> Windows path. Files under /home become \\wsl.localhost\<distro>\home\...
win_path() { wslpath -w "$1"; }

# Run a PowerShell script (stored in this repo) on the Windows host.
#   win_ps scripts/win/foo.ps1 -Arg value
# - runs from C:\ so Windows tools don't complain about a UNC working directory
# - ExecutionPolicy Bypass applies to this one process only; nothing is changed on the host
win_ps() {
  local script="$1"; shift
  [[ -f "$script" ]] || die "no such PowerShell script: $script"
  command -v powershell.exe >/dev/null || die "powershell.exe not reachable (is WSL interop enabled?)"
  local wscript; wscript="$(win_path "$script")"
  ( cd /mnt/c && powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$wscript" "$@" ) | tr -d '\r'
}

# Run a command and keep a timestamped copy of everything it printed in logs/.
#   xz_run_logged survey-wsl main "$@"
# The log path is printed on stderr at the end. Exit status is the command's.
xz_run_logged() {
  local name="$1"; shift
  mkdir -p "$XZ_LOGS"
  local logfile; logfile="$XZ_LOGS/$(date +%Y%m%d-%H%M%S)-$name.log"
  local rc=0
  { "$@" 2>&1 || rc=$?; exit $rc; } | tee "$logfile" || rc=$?
  log "log saved: $logfile"
  return $rc
}
