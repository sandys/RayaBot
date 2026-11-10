---
name: xiaozhi-backup-restore
description: Back up the full 16 MB flash of the xiaozhi ESP32-S3 ball, restore a backup, and prove the round trip with a byte-identical read-back and a boot check. The WiFi password and server credentials inside the dumps stay private throughout. Use before any risky flash, or when asked to return to factory firmware, recover a bricked or misbehaving device, or find out what a restore or OTA update changed.
---

# xiaozhi backup and restore

## Context & Purpose

**Dump files**
- Each backup is `backups/MAC/TIMESTAMP[-label]-full-16MB.bin`, with a `.sha256` and a `.txt` beside it.
- The NVS partition inside holds the WiFi password, server credentials and the board UUID.
- Never print, copy outside `backups/`, commit or upload a dump. `.gitignore` excludes it, and the pre-commit hook `scripts/90-check-secrets.sh` blocks leaks.

**Restores**
- A restore writes everything: bootloader, partition table, NVS, both app slots and assets. The result is byte-identical to the dump.
- The factory backup of this unit, with its sha256, is listed in README Status and in the README findings log (2026-11-10 00:50).

## Step-by-Step Workflow

1. **Back up:** run `scripts/22-backup-flash.sh --label REASON`. It takes about 90 s. Record the printed sha256.
2. **Identify a dump without the device:** run `scripts/30-analyze-flash-image.sh DUMP`. Its output is redacted.
3. **Restore:**
   1. Confirm with the user, unless they asked for the restore. It replaces the current firmware and settings.
   2. Run `scripts/24-restore-flash.sh --dry-run` (add `--file F` for a dump other than the factory one) and read the checks.
   3. Run it again without `--dry-run`. It takes about 3 min.
4. **Prove a restore end to end:** run `scripts/29-test-restore.sh [--file F]`. It restores, reads the flash back before anything boots, compares, boots, checks the version, then parks.
5. **Compare two images:** run `scripts/32-compare-images.sh A.bin B.bin`. Differences in `nvs` and `otadata` are expected once the firmware has run.
6. **Put the working build back** afterwards if the user wants it (xiaozhi-flash-and-verify).

## Decision Points & Branching Logic

**Restore checks fail**
- **The backup's sha256 does not match its `.sha256`:** the file was altered. Stop and use another backup.
- **MAC mismatch:** the dump belongs to another unit and carries that unit's identity and calibration. It needs `--force` and explicit user approval; refuse by default.

**Round trip fails**
- **Read-back differs (`29` fails):**
  1. Keep the read-back.
  2. Inspect the regions with 32.
  3. Re-run the restore once.
  4. If it still differs, suspect the cable or flash, and do not boot.
- **Boot check fails** (wrong or missing `App version`):
  1. Capture longer with `scripts/25-serial-capture.sh --reset run --seconds 60`.
  2. Inspect the otadata slot selection with 30.

**Seeing secret values**
- Only the user may do this, in their own terminal: `scripts/30-analyze-flash-image.sh DUMP --secrets`. It refuses when its output is piped.
- An agent never runs this, and never sets `XZ_SECRETS_TO_PIPE`.

## Quality Criteria & Completion Checks

- **Backup:**
  - The `.bin` and `.sha256` exist.
  - The size equals the flash size (16 MB).
  - The sha256 is recorded in the README findings log.
- **Round trip:**
  - `whole files: byte-identical`
  - all regions `identical`
  - `RESTORE VERIFIED` with the expected app version
- **Secrets:** no values appear in logs, docs or commits, and `scripts/90-check-secrets.sh --tracked` passes.
- **End state** is stated: factory firmware parked, or a named build re-flashed.
