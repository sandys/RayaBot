#!/usr/bin/env bash
# 20-setup-esptool.sh — install Espressif's esptool for *Windows* into tools/esptool-win/.
#
# Usage:
#   scripts/20-setup-esptool.sh              # download newest release if not already present
#   scripts/20-setup-esptool.sh --force      # re-download even if present
#   scripts/20-setup-esptool.sh --version v5.1.0
#   scripts/20-setup-esptool.sh --check      # only verify the installed exe accepts the options we use
#
# Why a Windows build, when we work in WSL?
#   The ESP32 is attached to the Windows host as COMxx; WSL2 cannot open it.
#   Espressif publishes a self-contained esptool.exe (PyInstaller bundle, no Python
#   needed, no admin needed). bash can launch it directly through WSL interop, so
#   every flashing script here calls that exe and hands it Windows-style paths.
#
# What it does
#   - asks the GitHub API for the release (latest by default) of espressif/esptool
#   - downloads the *windows-amd64.zip asset and unpacks it under tools/esptool-win/<version>/
#   - runs "esptool.exe version" to prove the exe starts from this location
#   - writes state/esptool.env (XZ_ESPTOOL=<path to esptool.exe>) for scripts/lib/device.sh
#
# Nothing is installed on Windows itself: the exe lives in this repo and runs from the
# \\wsl.localhost share.
# Output is also saved to logs/<timestamp>-setup-esptool.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# The 2x scripts call esptool with v5-style names (write-flash, --flash-mode, --after no-reset…).
# esptool has renamed its commands and options before (v4 used write_flash / --flash_mode), so
# prove the installed exe understands every spelling we depend on. No device is touched.
check_cli() {
  local exe="$1" bad=0
  echo "=== command-line compatibility of $("$exe" version | tail -1 | tr -d '\r') ==="
  local top wf
  top="$("$exe" --help 2>&1 | tr -d '\r')"
  wf="$("$exe" write-flash --help 2>&1 | tr -d '\r')"
  local item
  for item in chip-id flash-id read-mac get-security-info read-flash write-flash erase-region; do
    if grep -qE "(^|[[:space:]])$item([[:space:]]|\$)" <<<"$top"; then printf '  ok       command %s\n' "$item"
    else printf '  MISSING  command %s\n' "$item"; bad=1; fi
  done
  for item in --port --chip --before --after; do
    if grep -q -- "$item" <<<"$top"; then printf '  ok       global option %s\n' "$item"
    else printf '  MISSING  global option %s\n' "$item"; bad=1; fi
  done
  for item in no-reset hard-reset default-reset; do
    if grep -q -- "$item" <<<"$top"; then printf '  ok       reset mode %s\n' "$item"
    else printf '  MISSING  reset mode %s\n' "$item"; bad=1; fi
  done
  for item in --flash-mode --flash-freq --flash-size keep; do
    if grep -q -- "$item" <<<"$wf"; then printf '  ok       write-flash %s\n' "$item"
    else printf '  MISSING  write-flash %s\n' "$item"; bad=1; fi
  done
  [[ $bad -eq 0 ]] || die "this esptool does not accept everything scripts/2x-*.sh use; pin a version with --version"
}

main() {
  local force=0 version="latest" check_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)   force=1; shift ;;
      --check)   check_only=1; shift ;;
      --version) [[ $# -ge 2 ]] || die "--version needs a tag like v5.1.0"; version="$2"; shift 2 ;;
      -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done

  local dest="$XZ_TOOLS/esptool-win"
  mkdir -p "$dest" "$XZ_ROOT/state"

  if [[ $force -eq 0 && -f "$XZ_ROOT/state/esptool.env" ]]; then
    # shellcheck disable=SC1091
    source "$XZ_ROOT/state/esptool.env"
    if [[ -x "${XZ_ESPTOOL:-}" ]]; then
      log "already installed: $XZ_ESPTOOL (use --force to re-download)"
      check_cli "$XZ_ESPTOOL"
      return 0
    fi
  fi
  [[ $check_only -eq 0 ]] || die "--check: esptool is not installed yet (run without --check)"

  local api="https://api.github.com/repos/espressif/esptool/releases/latest"
  [[ "$version" == "latest" ]] || api="https://api.github.com/repos/espressif/esptool/releases/tags/$version"
  log "querying $api"
  local meta; meta="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$api")"

  local tag url name
  tag="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' <<<"$meta")"
  read -r name url < <(python3 -c '
import json, sys
rel = json.load(sys.stdin)
for a in rel["assets"]:
    n = a["name"].lower()
    if n.endswith(".zip") and ("windows-amd64" in n or "win64" in n):
        print(a["name"], a["browser_download_url"]); break
else:
    sys.exit("no windows-amd64 zip asset in release")
' <<<"$meta")
  log "release $tag, asset $name"

  local vdir="$dest/$tag"
  rm -rf "$vdir"; mkdir -p "$vdir"
  curl -fsSL -o "$vdir/$name" "$url"
  echo "  sha256: $(sha256sum "$vdir/$name" | cut -d' ' -f1)  $name"
  unzip -q -o "$vdir/$name" -d "$vdir"

  local exe; exe="$(find "$vdir" -type f -iname 'esptool.exe' | head -1)"
  [[ -n "$exe" ]] || die "esptool.exe not found inside $name"
  chmod +x "$(dirname "$exe")"/*.exe

  log "smoke test: $exe version"
  "$exe" version || die "esptool.exe did not start from $exe"

  {
    echo "# written by scripts/20-setup-esptool.sh on $(date -Is)"
    echo "XZ_ESPTOOL=$exe"
    echo "XZ_ESPTOOL_VERSION=$tag"
  } > "$XZ_ROOT/state/esptool.env"
  log "recorded in state/esptool.env"
  echo "  companion tools: $(cd "$(dirname "$exe")" && ls *.exe | tr '\n' ' ')"
  check_cli "$exe"
}

xz_run_logged setup-esptool main "$@"
