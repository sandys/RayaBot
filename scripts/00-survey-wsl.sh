#!/usr/bin/env bash
# 00-survey-wsl.sh — what does the WSL2 (Linux) side of this machine have?
#
# Usage:  scripts/00-survey-wsl.sh
#
# Read-only. Reports:
#   - kernel / distro
#   - which build + flashing tools are installed (python, git, cmake, ninja, esptool, idf.py, docker, usbip)
#   - whether WSL->Windows interop works (powershell.exe, cmd.exe)
#   - CPU / RAM / free disk (an ESP-IDF build wants ~10 GB disk and a few GB RAM)
#   - whether any serial device is visible *inside* WSL (/dev/ttyUSB*, /dev/ttyACM*)
#   - docker usability without sudo
#
# Why it matters: it decides HOW we build (native ESP-IDF vs docker) and HOW we
# reach the device (inside WSL via usbipd, or on the Windows host via COM ports).
# Output is also saved to logs/<timestamp>-survey-wsl.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  echo "=== kernel / distro ==="
  uname -srm
  grep -E '^(PRETTY_NAME)=' /etc/os-release | cut -d= -f2- | tr -d '"'

  echo
  echo "=== tools on PATH ==="
  local t
  for t in python3 pip3 git cmake ninja esptool.py esptool idf.py usbip lsusb docker \
           powershell.exe cmd.exe usbipd.exe wslpath curl wget unzip xxd strings; do
    printf '  %-16s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo MISSING)"
  done
  echo "  python3 version: $(python3 --version 2>&1)"

  echo
  echo "=== resources ==="
  echo "  cpus: $(nproc)"
  free -h | awk 'NR==2{print "  ram:  total " $2 ", available " $7}'
  df -h "$XZ_ROOT" | awk 'NR==2{print "  disk: " $4 " free on " $1 " (" $5 " used)"}'

  echo
  echo "=== serial devices visible inside WSL ==="
  if compgen -G '/dev/ttyUSB*' >/dev/null || compgen -G '/dev/ttyACM*' >/dev/null; then
    ls -la /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
  else
    echo "  none (expected: WSL2 has no USB passthrough unless usbipd-win attaches a device)"
  fi
  echo "  lsusb:"
  lsusb 2>&1 | sed 's/^/    /'

  echo
  echo "=== ESP-IDF ==="
  echo "  IDF_PATH=${IDF_PATH:-<unset>}"
  ls -d "$HOME"/esp* "$HOME"/.espressif 2>/dev/null | sed 's/^/  found: /' || true
  [[ -d "$HOME/.espressif" || -n "${IDF_PATH:-}" ]] || echo "  no native ESP-IDF install found"

  echo
  echo "=== docker ==="
  if command -v docker >/dev/null; then
    if docker info >/dev/null 2>&1; then
      echo "  docker daemon reachable without sudo: YES"
      docker version --format '  client {{.Client.Version}} / server {{.Server.Version}}' 2>/dev/null || true
      echo "  espressif images already pulled:"
      docker images --format '    {{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null | grep -i espressif || echo "    none"
    else
      echo "  docker installed but daemon NOT reachable as $(id -un):"
      docker info 2>&1 | tail -2 | sed 's/^/    /'
    fi
  else
    echo "  docker not installed"
  fi
}

xz_run_logged survey-wsl main "$@"
