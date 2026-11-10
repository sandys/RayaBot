---
name: xiaozhi-device-access
description: Reach the xiaozhi ESP32-S3 ball from WSL2 through the Windows host. Find it on USB and get its COM port, set up the Windows esptool.exe, read chip info, record the serial console or boot log, and park the chip in the bootloader so it stays silent and powered. Use when the device is not found, a COM port, esptool or serial error appears, a boot log is needed, or before leaving the device unattended.
---

# xiaozhi device access

## Context & Purpose

- WSL2 cannot see USB. The board is plugged into Windows and appears as a COM port.
- Everything that touches the board runs on Windows through WSL interop:
  - `esptool.exe` under `tools/esptool-win/` (its path is in `state/esptool.env`)
  - PowerShell halves in `scripts/win/`
- The board uses the ESP32-S3's native USB-Serial/JTAG (`303A:1001`). esptool resets it into download mode itself, so no BOOT button is needed.
- The current port is in `state/device.env` (`XZ_PORT`). Override it per call with `XZ_PORT=COM7 scripts/...`. README "Hardware" lists this unit's port and MAC.
- Only one `scripts/2x` script may hold the port; they lock `state/port.lock` and wait up to 60 s.

## Step-by-Step Workflow

1. **New machine only:**
   - Run `scripts/00-survey-wsl.sh` and `scripts/01-survey-windows.sh`.
   - Run `scripts/04-keep-awake.sh --show`. Use `--hours N` for long unattended runs.
2. **Find the board:** run `scripts/02-list-usb.sh`. Expect a `<--` line with `303A:1001` and a COM port.
3. **If the board is absent:** run `scripts/03-wait-for-device.sh` and ask the user to replug. It returns `FOUND ... COMx` and writes `state/device.env`.
4. **Check esptool:** run `scripts/20-setup-esptool.sh --check`. Run it without flags to install esptool when it is missing.
5. **Identify the chip:** run `scripts/21-chip-info.sh`, which writes `docs/device/chip-info.txt`. Confirm all of these:
   - ESP32-S3
   - 16 MB flash
   - secure boot and flash encryption disabled
   - the MAC from README
6. **Record the console:** run `scripts/25-serial-capture.sh --reset run --seconds 30 --label NAME`. Add `--until 'REGEX'` to stop early. Read `logs/serial/latest.log`.
7. **Park the chip:** run `scripts/26-park-in-bootloader.sh` before leaving the device, and before the firmware's 60 s WiFi prompt.

## Decision Points & Branching Logic

**Board not found or not responding**
- **Nothing flagged in step 2:**
  - The cause is usually a charge-only cable, the power switch, or the board not plugged in.
  - Ask the user to replug with a data cable while `scripts/03-wait-for-device.sh` runs.
  - `VID_0000&PID_0002` (ENUMFAIL) means a cable or port fault.
- **NODRIVER:** the device is present but has no serial driver bound. Report this to the user. Do not install drivers yourself.
- **Device vanished after the app ran:**
  - The firmware may be in deep sleep. That only happens online, while idle, and when GPIO41 reads "not charging".
  - The user must cycle the power button.
  - Prevent it by parking, or with the "Enable Sleep Mode" checkbox (`docs/board-dossier.md`).
- **esptool cannot connect:** re-run step 2. Check that no Windows program (serial monitor, IDE) holds the port, then ask for a replug.

**Serial capture (`25-serial-capture.sh`) exit codes**
- **Exit 3:** the port could not be opened. Another 2x script or a Windows app holds it. Never run two 2x scripts at once.
- **Exit 4:** the port opened but was silent. The chip is parked in download mode, which is normal after scripts 21–24 and 26. Re-run with `--reset run`.

**Approaches to avoid**
- Never use usbipd or WSL USB passthrough: it needs admin and is not installed.
- Never install Python or esptool on Windows.

## Quality Criteria & Completion Checks

- `state/device.env` names the COM port that `02-list-usb.sh` reports.
- `docs/device/chip-info.txt` matches README Hardware: chip, flash size, MAC, security disabled.
- Logs captured with `--reset run` start at the `ESP-ROM:` banner.
- At the end, 26 printed `parked: COMx is in download mode`, or the user knows the device is running and that it will speak after 60 s offline.
