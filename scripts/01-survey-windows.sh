#!/usr/bin/env bash
# 01-survey-windows.sh — what does the Windows host have? (run from WSL)
#
# Usage:  scripts/01-survey-windows.sh
#
# Read-only. Runs scripts/win/survey-windows.ps1 on the Windows host through
# WSL interop and reports user / elevation, usbipd, Python, esptool, winget,
# and which USB-serial drivers are loaded.
#
# Why it matters: the ESP32 is plugged into Windows, not WSL. This tells us
# whether we can pass the USB device into WSL (usbipd-win, needs admin) or
# must flash from the Windows side (esptool.exe against a COM port, no admin).
# Output is also saved to logs/<timestamp>-survey-windows.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() { win_ps "$XZ_SCRIPTS/win/survey-windows.ps1"; }

xz_run_logged survey-windows main "$@"
