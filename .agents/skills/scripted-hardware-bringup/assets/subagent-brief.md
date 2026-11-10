# Subagent brief

Fill in every field. The brief is all the agent knows, and you will only see its summary.

- **Goal:** one sentence describing the outcome, not the method.
- **Context:** what is known or ruled out. Link README.md sections, CHANGES.md entries and file paths.
- **Scope:** what it may read, and what it may write (a new doc? a script under scripts/? nothing?).
- **Must not:**
  - Touch the device or COM port, unless this agent owns it exclusively.
  - Install anything on the host.
  - Print or copy secrets (backups/, NVS values).
  - Push, publish, email or upload.
  - Read raw session transcripts.
- **Rules:**
  - New probes become documented scripts (scripted-hardware-bringup).
  - Heavy tools run in docker.
  - Cite `file:line` or a URL for every claim, and mark guesses "(inference)".
- **Deliverable:** the exact files and/or report format, with a length limit.
- **Done when:** the checks it must run and report (script exit codes, test output).

When the report arrives, re-check every load-bearing claim yourself before adopting it.
