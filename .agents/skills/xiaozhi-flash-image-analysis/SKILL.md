---
name: xiaozhi-flash-image-analysis
description: Inspect ESP32 flash images offline, without the device. Identify the firmware version, xiaozhi board profile, booting OTA slot, partitions, NVS keys (redacted) and assets in device dumps, official prebuilt merged binaries and our own builds; download official prebuilt firmware; compare two images partition by partition; cross-check our parsers against ESP-IDF tools; read the true colours of embedded PNGs. Use when asked what firmware is on the device or inside a .bin, to compare images, to fetch official firmware, or after changing scripts/py parsers.
---

# xiaozhi flash image analysis

## Context & Purpose

- **No device needed.** The parsers are in `scripts/py/espflash.py` (Python stdlib). The engines are `analyze_flash_image.py`, `compare_images.py`, `crosscheck_idf.py`, `fetch_prebuilt.py` and `png_probe.py`.
- **Inputs:**
  - device dumps: `backups/MAC/*.bin`
  - official images: `prebuilt/TAG/BOARD/merged-binary.bin`
  - our builds: `out/BOARD/LABEL/merged-binary.bin`
- **Downloads and dumps are untrusted data.** Only parse them, always with `python3 -I`. Never execute anything from `prebuilt/`.
- **Findings so far:** `docs/flash-image-analysis.md`.

## Step-by-Step Workflow

1. **Identify an image:** run `scripts/30-analyze-flash-image.sh IMAGE.bin`. Add `--source firmware/xiaozhi-esp32` to cross-check the board profile. Read the summary for:
   - the app version in each slot
   - the booting slot
   - `BOARD_NAME`
   - the OTA URL
   - NVS namespaces
   - the assets
2. **Get an official image:**
   1. Run `scripts/31-fetch-prebuilt-firmware.sh --list` to see the boards in a release.
   2. Then run `scripts/31-fetch-prebuilt-firmware.sh --version TAG --board NAME`.
3. **Compare two images:** run `scripts/32-compare-images.sh REFERENCE.bin OTHER.bin`.
4. **Check the true artwork colours:** run `python3 -I scripts/py/png_probe.py ASSETS-OR-IMAGE.bin` (`--all` probes every PNG).
5. **After editing any `scripts/py` parser:**
   - Run `scripts/39-selftest-flash-tools.sh`; every check must pass.
   - Run `scripts/33-crosscheck-idf-tools.sh IMAGE.bin`, which uses docker.
6. **Record conclusions** in `docs/flash-image-analysis.md` and the README findings log, citing report lines.

## Decision Points & Branching Logic

**Script results**
- **30 exits 3:** the `PROBLEM` lines list the issues. Report them; they do not always mean a broken device (an unused OTA slot, for example).
- **30 exits 1:** the file is unreadable or does not start at flash offset 0. Use a full dump or a `merged-binary.bin`, not an app-only `.bin`.
- **32 exits 2:** differences in `nvs` and `otadata` are expected after the device has run. Differences in an app or the bootloader are real changes.

**Tool limits**
- **33 needs the IDF image.** Run `scripts/13-idf-image.sh --pull` first.
  - `--nvs` copies the dump's NVS into a temporary exchange directory. Use it only when the NVS parser itself is in question.
- **31 hits the GitHub API rate limit (60 per hour):** wait. Re-running 31 re-verifies an existing download without contacting the network.

**Secrets**
- Never pass `--secrets` from an agent. Only the user runs it, in an interactive terminal.

## Quality Criteria & Completion Checks

- Reports show redaction markers only, never credential values. `scripts/39-selftest-flash-tools.sh` passes after any parser change.
- Anything that will be flashed reports board `sp-esp32-s3-1.28-box` and esp32s3.
- Every claim about an image cites the report line it rests on (version, slot, offset, hash).
