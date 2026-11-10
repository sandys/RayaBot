---
name: scripted-hardware-bringup
description: Working method for hardware bring-up in this repo. Every probe, check, build and flash becomes a numbered, documented, logged script; README.md (script index, status, findings log) and CHANGES.md (work, problems, discarded approaches) stay current; heavy tooling runs in docker; results count only with evidence; subagents get a full brief and their claims are verified; secrets and the device stay protected. Use when starting work or an investigation, before running any ad-hoc command, when adding or changing a script, when delegating to subagents, or when finishing and writing up a task.
---

# Scripted hardware bring-up

## Context & Purpose

Use this skill whenever work starts, changes direction or ends in this repo, and before any command that probes, checks, builds or flashes. It encodes how the 2026-11-10 bring-up was run, so later sessions reproduce results instead of re-deriving them.

Rules:
- **Nothing one-off.** Each action is a script under `scripts/`, documented in its header and indexed in `README.md`.
- **Evidence decides.** A step is done when its checks pass and you have inspected the evidence.
- **Write history as you go.** Put facts in the `README.md` findings log; put work, problems and dead ends in `CHANGES.md`.
- **Keep the host clean.** Use only bash and the Python standard library on the host. Everything else runs in docker.

## Step-by-Step Workflow

1. **Orient.** Read `README.md` (Status, Next steps), then the newest `CHANGES.md` entry and its "Do not repeat" table. When firmware is involved, run `scripts/19-patches.sh status` and `scripts/12-inspect-build.sh --list`.
2. **Look for an existing script** in the README script index before typing a command. Reuse or extend it.
3. **If no script fits, create one:**
   - Name it `scripts/NN-verb-object.sh`. Choose NN by range:

     | Range | Area |
     |---|---|
     | 0x | survey |
     | 1x | source and build |
     | 2x | device I/O |
     | 3x | image analysis |
     | 4x | research |
     | 9x | repo hygiene |
   - Start from [assets/script-template.sh](assets/script-template.sh). The header gives usage, why, what it changes and exit codes, and `--help` prints it. Source `scripts/lib/common.sh`, plus `scripts/lib/device.sh` for the serial port. End with `xz_run_logged NAME main "$@"`.
   - Put Python in `scripts/py/` (stdlib only, run as `python3 -I -B`), container halves in `scripts/container/`, and Windows halves in `scripts/win/*.ps1`.
   - Add the script's row to the README script index in the same change.
4. **Run the script.** Read its log in `logs/`, not just its last line.
5. **Judge the evidence yourself.** Treat a script's PASS as a claim to check:
   - Open the screenshots.
   - Read the boot logs.
   - Compare the hashes.
   - Trace surprises to source lines (`file:line`).
6. **Record the result:**
   - README: update the Status table and add a dated findings-log entry.
   - CHANGES.md: add an entry from [assets/changes-entry.md](assets/changes-entry.md).
   - Add every abandoned approach to "Do not repeat".
7. **Delegate** independent, bounded work to subagents using [assets/subagent-brief.md](assets/subagent-brief.md). Before adopting any load-bearing claim a subagent returns, verify it against source, docs or device output.
8. **Finish:**
   - Park the device, or state what it is running.
   - Run `scripts/90-check-secrets.sh --tracked` and confirm it is clean.
   - Run `scripts/91-agent-skills.sh check` after any skill or guide edit.
   - Commit only when the user asked. The pre-commit hook re-runs the secret check.

## Decision Points & Branching Logic

- **A command fails:** read the log, fix the script (not just the invocation) and re-run. Record the problem in CHANGES.md.
- **A dependency is missing:** run it in the pinned ESP-IDF image (`scripts/lib/idf-docker.sh`) or another container. Never use pip, apt or venv on the host.
- **The approach is already listed in "Do not repeat":** use the recorded alternative, or write down what changed since.
- **You abandon an approach:** add a "Do not repeat" row (what, why, instead) in the same session.
- **A step is irreversible or outward-facing:** ask the user first. This covers erasing NVS, restoring another unit's dump, pushing, publishing, emailing, uploading and spending money.
- **A subagent stalls, drifts or produces nothing:** stop it, record it, then narrow the brief or do the work yourself. Never brief a subagent to read raw session transcripts; safeguards stopped that on 2026-11-10.
- **The device will be unattended or it is night:** park it before the 60 s WiFi voice prompt with `scripts/26-park-in-bootloader.sh`.
- **The session may end (usage limits):** keep README Status and Next steps current so work can resume cold.

## Quality Criteria & Completion Checks

- Every device interaction maps to a script in the README index. No undocumented ad-hoc probes remain.
- Each new script has header usage, a working `--help`, output in `logs/` and a README row. It never prints secrets.
- Claims in docs cite evidence: a log path, screenshot, hash, URL or `file:line`.
- README Status, the findings log and CHANGES.md are updated, and both `scripts/90-check-secrets.sh --tracked` and `scripts/91-agent-skills.sh check` pass.
- The final message states the device state (parked, or which build is running) and what is unverified.
