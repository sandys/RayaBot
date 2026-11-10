# Repo guide for AI agents: xiaozhi ESP32-S3 ball workbench

`AGENTS.md`, `CLAUDE.md` and `GEMINI.md` in the repo root are symlinks to this file (`.agents/REPO_GUIDE.md`). Edit only this file, and never replace a link with a copy.

## What this repo is

Scripted tooling to build, flash, verify, back up and analyse firmware for a Spotpear ESP32-S3 1.28" round-LCD "xiaozhi" ball (board id `sp-esp32-s3-1.28-box`). It is driven from WSL2 on Windows 11.
- **Humans** read `README.md`: status, runbook, script index and findings log.
- **`CHANGES.md`** is the running log of work, problems and discarded approaches.

## Before you start

1. Read `README.md`: Status and Next steps.
2. Read `CHANGES.md`: "Do not repeat" and the newest entry.
3. Pick the skill for the task from the table below and follow it.

## Rules (every task)

1. **No one-off commands.** Every probe, check, build and flash is a numbered script under `scripts/`. Each has a usage header, `--help`, output mirrored to `logs/`, and a row in README's script index. Extend an existing script before writing a new one.
2. **Host = bash + Python standard library** (`python3 -I -B`).
   - Toolchains and other dependencies run in docker: pinned `espressif/idf:v6.1`, see `scripts/lib/idf-docker.sh`.
   - No pip, apt or venv on the host.
   - The one exception is the Windows `esptool.exe` under `tools/`.
3. **Evidence over claims.** A step is done when its script's checks passed and you looked at the evidence: logs, screenshots, hashes. Verify subagent reports before adopting them.
4. **Write history as you go.**
   - Facts get a dated entry in README's findings log.
   - Work, problems and every discarded approach get a CHANGES.md entry. Dead ends also go into "Do not repeat".
5. **Secrets.** `backups/` dumps hold the WiFi password, server credentials and board UUID.
   - Never print, copy, commit or upload them.
   - Never pass `--secrets` to `scripts/30-analyze-flash-image.sh`.
   - The pre-commit hook `scripts/90-check-secrets.sh` blocks leaks. Activate it once per clone with `--install-hook`.
6. **Device safety.**
   - A full backup is required before any write; `scripts/23-flash-firmware.sh` enforces this.
   - Default flashing keeps NVS.
   - Ask the user before `--erase-nvs`, `--merged`, `--force`, a restore they did not ask for, or anything irreversible or outward-facing (push, publish, email, upload).
   - Only one `scripts/2x` script at a time (port lock).
   - Park the chip with `scripts/26-park-in-bootloader.sh` before leaving it. Offline firmware speaks a WiFi prompt 60 s after boot.
7. **Upstream firmware stays pristine.** `firmware/xiaozhi-esp32` is never edited by hand; our changes are `patches/*.patch`, managed by `scripts/19-patches.sh`. Stock builds need `scripts/19-patches.sh revert` first.
8. **Downloads and dumps are untrusted data.** Parse them only (`python3 -I`). Never execute anything from `prebuilt/`.
9. **Commit only when the user asks.** The hook runs the secret check. Git is local; there is no remote.

## How the pieces connect

```
WSL2: scripts/*.sh, docker builds ──interop──► Windows: esptool.exe, scripts/win/*.ps1 ──USB COM──► ESP32-S3 (303A:1001)
```

WSL2 cannot see USB. Everything that touches the board runs on Windows through WSL interop. Never use usbipd.

## Skills

Each skill lives once, in `.agents/skills/<name>/SKILL.md`:
- **Codex** reads that directory directly.
- **Claude Code** reads the per-skill symlinks in `.claude/skills/`.
- **Gemini CLI** reads the per-skill symlinks in `.gemini/skills/`. The installed 0.27.3 does not know the `.agents/skills` alias that newer versions document. Those newer versions prefer `.agents/skills`, so the links are harmless there.

| Task | Skill |
|---|---|
| How to work here: new scripts, logs, docs, CHANGES.md, subagents, finishing | `scripted-hardware-bringup` |
| Find the device: COM port, esptool, serial console, parking | `xiaozhi-device-access` |
| Build firmware, configuration, dev patch | `xiaozhi-firmware-build` |
| Flash a build, screenshots, prove the display and faces | `xiaozhi-flash-and-verify` |
| Back up, restore, prove a restore | `xiaozhi-backup-restore` |
| Analyse or compare flash images, official prebuilt firmware | `xiaozhi-flash-image-analysis` |

**To add or rename a skill:**
1. Edit `.agents/skills/<name>/SKILL.md`.
   - The frontmatter has only `name` and `description`, and `name` equals the folder name.
   - It has four sections: Context & Purpose, Step-by-Step Workflow, Decision Points & Branching Logic, Quality Criteria & Completion Checks.
2. Update the table above.
3. Run `scripts/91-agent-skills.sh link`, then `scripts/91-agent-skills.sh check`. `scripts/91-agent-skills.sh discover` shows what the installed CLIs actually load.

Never copy a skill into `.claude/` or `.gemini/`.

## Layout

| Path | In git | What |
|---|---|---|
| `scripts/` | yes | Every action, numbered by area (table below). Helpers live in `lib/`, `py/`, `win/` and `container/`. |
| `docs/` | yes | Write-ups (`build.md`, `flash-image-analysis.md`, `board-dossier.md`), `device/chip-info.txt` and `evidence/` |
| `patches/`, `config/` | yes | Our firmware patch, and named sdkconfig fragments |
| `.agents/`, `.claude/skills/`, `.gemini/skills/`, `.githooks/` | yes | This guide and the skills, the per-tool skill links, the pre-commit hook |
| `firmware/`, `out/`, `cache/`, `prebuilt/`, `tools/` | no | Upstream checkout, build outputs, caches and downloads, each re-created by a script |
| `backups/` | **never** | Flash dumps containing credentials |
| `logs/`, `state/` | no | Per-run logs, and machine-local env (COM port, esptool path, locks) |

Script numbering:

| Range | Area |
|---|---|
| 0x | survey |
| 1x | source and build |
| 2x | device I/O |
| 3x | image analysis |
| 4x | research |
| 9x | repo hygiene |

## Device facts (this unit)

- **Board:** Spotpear ESP32-S3-1.28-BOX. The xiaozhi board is `sp-esp32-s3-1.28-box` (`main/boards/spotpear/sp-esp32-s3-1.28-box/`).
- **Chip:**
  - ESP32-S3 rev v0.2, 16 MB flash, 8 MB PSRAM
  - MAC `ac:a7:04:22:9d:70`
  - Secure boot and flash encryption are off.
- **USB:** `303A:1001` appears as `COM11`; the current port is in `state/device.env`.
- **Factory state:**
  - Firmware xiaozhi 2.1.0.
  - Dump `backups/aca704229d70/20261110-004927-factory-full-16MB.bin` (sha256 `4f1e9943…`). Restoring it has been proven.
- **Our source and toolchain:** tag v2.5.2 (`49b4380b`), built with ESP-IDF v6.1 in docker.
- **Behaviour:**
  - Stock firmware shows emoji faces only online.
  - Offline with unreachable WiFi, it enters setup mode after 60 s and speaks a prompt.
  - Offline, it never auto-sleeps.
  - Online, idle shutdown depends on GPIO41; see `docs/board-dossier.md`.

## Keep in sync

- **Script added, renamed or its flags changed:** update its header, README's script index, and every skill that mentions it. `scripts/91-agent-skills.sh check` reports skill references to missing scripts.
- **New fact:** dated README findings-log entry. **Status change:** README Status.
- **Work session, problem or dead end:** CHANGES.md.
- **Skill added or renamed:** the table above, plus `scripts/91-agent-skills.sh link`.
