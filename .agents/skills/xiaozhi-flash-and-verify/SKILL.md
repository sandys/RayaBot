---
name: xiaozhi-flash-and-verify
description: Flash a firmware build from out/ to the xiaozhi ESP32-S3 ball over the Windows COM port, then prove it works. Covers a hash-verified write that keeps NVS, boot-log evidence checks, LCD screenshots over serial (face demo), visual inspection, and parking. Use when asked to flash, install, test or demo firmware, check what the screen shows, take screenshots, or confirm the display and faces work.
---

# xiaozhi flash and verify

## Context & Purpose

**Scripts**
- `scripts/23-flash-firmware.sh` writes each partition separately, so NVS (WiFi, device identity) survives. Before writing it checks that a backup exists, that chip and flash size match, that security is off, and that the files fit.
- `scripts/28-face-demo.sh` runs the whole sequence: flash → boot → 8 screenshots → PASS/FAIL evidence → park.

**Screenshots** (dev builds only)
- They exist only with `CONFIG_XZ_DEV_SERIAL_SCREENSHOT`.
- The firmware prints `XZSHOT` blocks on serial, which become `logs/screens/*.jpg`.
- They show the frames LVGL rendered, not the glass itself.

**What the firmware shows offline**
- Stock firmware shows emoji faces only once it is online, because the assets are applied after the network connects. Offline it shows a robot icon.
- The dev face demo (`CONFIG_XZ_DEV_FACE_DEMO`) cycles the faces while the device is offline.
- When offline with the stored WiFi out of reach, the firmware enters WiFi setup after 60 s. It **speaks a prompt** and opens its `Xiaozhi-XXXX` hotspot.

## Step-by-Step Workflow

1. **Check for a backup.** A full backup for this MAC must exist in `backups/MAC/*-full-*.bin`. If it does not, run `scripts/22-backup-flash.sh --label REASON` (xiaozhi-backup-restore).
2. **Verify the build:** run `scripts/12-inspect-build.sh --label LABEL`.
3. **Read the plan:** run `scripts/23-flash-firmware.sh --dir out/sp-esp32-s3-1.28-box/LABEL --dry-run`.
4. **Flash:**
   - Dev face build, end to end: `scripts/28-face-demo.sh --dir out/sp-esp32-s3-1.28-box/LABEL`. The default directory is `dev-face-v2.5.2`.
   - Any other build:
     1. `scripts/23-flash-firmware.sh --dir out/sp-esp32-s3-1.28-box/LABEL`
     2. `scripts/25-serial-capture.sh --reset run --seconds 40 --label after-flash`
   - Screenshots only, from a dev build that is already flashed: `scripts/27-screenshot.sh --reset run --count 3`.
5. **Read the evidence:**
   - `regions written N` equals `hashes verified N`.
   - The boot log shows `App version`, `gc9a01: LCD panel create success`, `Backlight: Set brightness` and the `XZFACE` lines.
   - Check the 28 PASS/FAIL table.
6. **Open the screenshots** with an image viewer or the Read tool. Check that faces are present and the colours are right: yellow emoji, not cyan.
7. **Park:** 28 parks by default. Otherwise run `scripts/26-park-in-bootloader.sh`. If the user wants the device running, warn them first about the 60 s voice prompt. 28 keeps it running with `--leave-running`.
8. **Keep the evidence:**
   1. Copy the chosen screenshots and console log to `docs/evidence/TOPIC/`.
   2. Run `scripts/90-check-secrets.sh` (the board UUID must be redacted).
   3. Update README Status and the findings log, and add a CHANGES.md entry.

## Decision Points & Branching Logic

**Flashing**
- **23 refuses** (no backup, chip or size mismatch, security on, oversize file): fix the cause. Never bypass a check.
- **Hash not verified, or the write fails:**
  1. Re-run once.
  2. Then check the cable and port (xiaozhi-device-access).
  3. If the image may be broken, restore with `scripts/24-restore-flash.sh`.
- **`--erase-nvs` or `--merged`:** both wipe WiFi credentials and device identity. Use them only with explicit user approval.

**Screenshots**
- **No `XZSHOT` blocks:** the build is not a dev build (check its `sdkconfig` in `out/`), or the capture was too short. Raise `--seconds`.
- **Screenshot CRC failures:** re-run. If they persist, run `scripts/17-test-screenshot-protocol.sh`.
- **Wrong colours:** upstream `LvglDisplay::SnapshotToJpeg` swaps the RGB565 bytes and then labels the data little-endian. The dev patch uses its own snapshot instead, marked `colours=true` in `XZSHOT BEGIN`. Check the true asset colours with `python3 -I scripts/py/png_probe.py FILE`.

**Health and device behaviour**
- **`health` FAIL** (panic, watchdog, brownout):
  1. Capture longer with 25.
  2. Decode the backtrace against `out/.../debug/*.elf`, using addr2line inside the IDF container.
  3. If needed, restore the factory image.
- **The device must stay quiet:** park it before 60 s. There is no clean temporary mute, because the volume setting persists to NVS.
- **The device went online with the official server:** the firmware installs any newer version the server offers (`application.cc:493-498`). Re-flash the dev build if you still need it.

## Quality Criteria & Completion Checks

- **Write:** written regions = verified hashes.
- **Boot:**
  - The `App version` matches the build.
  - The panel was created and the backlight set.
  - No crash markers appear.
- **Display:** ≥ 3 CRC-valid screenshots show the expected screen (faces for the face demo), and you inspected them by eye.
- **Report honestly:** screenshots and log lines are indirect evidence. A human must confirm the glass lights up.
- **Device state** (parked, or running a named build) is stated, and README Status is updated.
