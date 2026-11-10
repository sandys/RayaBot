# CHANGES

Running log of the work in this repo: what was done, what went wrong, and which approaches were tried and dropped.
- **Read "Do not repeat" before starting anything new.**
- The newest entry comes first. Times are IST.
- Add an entry for every working session or change of direction, using the template `.agents/skills/scripted-hardware-bringup/assets/changes-entry.md`.
- Facts about the device and firmware also go into README's findings log. This file is about the *work*.

## Do not repeat

| # | Tried or assumed | Why it was dropped | Do this instead |
|---|---|---|---|
| 1 | Pass the USB device into WSL2 (usbipd-win) | WSL2 sees no USB devices. usbipd is not installed and needs admin, which the Windows user lacks. | Windows `esptool.exe` against the COM port, launched from bash through WSL interop (`scripts/20`, `scripts/lib/device.sh`) |
| 2 | Install Python or esptool on Windows | No real Python on Windows, and no admin rights | Espressif's standalone `esptool.exe` (PyInstaller bundle) under `tools/` |
| 3 | Install ESP-IDF, pip packages or apt tools on the WSL host | User rule: host dependencies get messy | Pinned `espressif/idf` docker image. Host scripts use bash and the Python stdlib only. |
| 4 | ESP-IDF 5.x, as older xiaozhi guides say | xiaozhi v2.x (tag v2.5.2) needs ESP-IDF ≥ 6.0.1 | `espressif/idf:v6.1`, pinned by digest (`scripts/13`) |
| 5 | Expect stock firmware to show a face offline, or wait for WiFi to see one | The emoji PNGs are applied only after the network connects (`application.cc:370,437`). Offline shows a robot icon. | Dev face demo, `CONFIG_XZ_DEV_FACE_DEMO` in `patches/xz-dev-tools.patch` |
| 6 | Mute the speaker temporarily for unattended runs | The volume persists to NVS on every change (`audio_codec.cc:44`). There is no clean temporary mute. | Park the chip before the 60 s WiFi prompt (`scripts/26`; `scripts/28` parks by default) |
| 7 | Upstream `LvglDisplay::SnapshotToJpeg` for screenshots | It byte-swaps RGB565, then tells the encoder the data is little-endian, so colours are wrong (yellow shows as cyan) | The dev patch's own snapshot, marked `colours=true`; `scripts/py/png_probe.py` gives the true colours |
| 8 | A separate panel self-test firmware (subagent, scripts 50–59) | Produced nothing usable; shelved | LVGL screenshots over serial plus boot-log evidence (`scripts/27`, `scripts/28`) |
| 9 | Edit `sdkconfig` by hand, or keep menuconfig saves | Upstream `build.py` regenerates sdkconfig on every build | `--set` / `--sdkconfig-append` with `config/*.sdkconfig`; `scripts/14-menuconfig.sh --delta` |
| 10 | Keep our changes as edits or commits inside `firmware/` | The upstream checkout must stay resettable | `patches/*.patch` via `scripts/19-patches.sh` |
| 11 | Have a subagent mine the raw Claude session transcript (`.jsonl`) for history | Anthropic safeguards stopped it (`reasoning_extraction`) | Write CHANGES.md and the README findings log *during* the work |
| 12 | Copy skills per tool, or symlink a whole `.claude/skills` directory | Copies drift. Claude Code documents only per-skill links. | One canonical `.agents/skills/<name>`, with per-skill links in `.claude/skills` and `.gemini/skills`, kept by `scripts/91-agent-skills.sh link` |
| 13 | Plain substring matching of NVS secret values | False positives: short vendor test values inside longer strings, such as the base64 alphabet or a fake test token | Token-boundary matching plus a public-placeholder list (`scripts/py/secret_scan.py`) |
| 14 | Trust the current online docs for what an installed CLI does (Gemini's `.agents/skills` alias), or a model's answer for what it loaded | The installed Gemini CLI 0.27.3 predates the alias: its `skillManager.js` reads only `~/.gemini/skills` and `<project>/.gemini/skills`. A model's answer can fail on billing, or leave things out. | Ask the installed tool itself: `scripts/91-agent-skills.sh discover --claude` (Gemini's listing, the prompt Codex would send, Claude Code's debug log) |
| 15 | Speed up an LVGL animation with a shorter timer period, or raise `LV_INV_BUF_SIZE` | 33 → 10 ms changed nothing. Each step marked 38 changed areas, over LVGL's 32, so every redraw was the whole screen. The limit is a `#define` in managed LVGL code, not Kconfig. | Keep a step under 32 areas, and read `fps`, `px` and `full` in `XZNAME alive` (`main/xz_dev.cc`, `scripts/28`) |

## 2026-11-10 09:05–09:20 — a complete .gitignore, proved by scripts/92

The user asked whether the firmware binaries go into the commit. They don't: `out/` is ignored. The user then asked for a legitimate `.gitignore`.

**Work**
- **`.gitignore` rewritten** in four sections: secrets; large or re-creatable; per-machine; personal, Python, editors and OS. Each rule says why.
  - Kept: the eight folders (`backups/`, `firmware/`, `out/`, `cache/`, `prebuilt/`, `tools/`, `state/`, `logs/`), `.claude/settings.local.json`, Python caches.
  - New, matching anywhere in the tree:
    - `*.bin`, for a dump copied out of `backups/` or a firmware image.
    - `*.raw`, for serial captures, which name the board UUID.
    - Archives, `.env` files and keys.
    - `*.elf` and `*.map`, the 35 MB and 23 MB debug outputs.
    - `*.exe` and `*.dll`, untrusted downloads (rule 8).
    - `CLAUDE.local.md`, venvs, editor and OS files, and WSL's `*:Zone.Identifier`.
- **New `scripts/92-check-gitignore.sh`:**
  - Git itself judges sample paths (`git check-ignore --no-index`): 47 that must be ignored and 31 that must stay committable.
  - It also requires that no tracked file matches a rule.
  - `--untracked` lists what `git add -A` would take. `--selftest` covers 5 cases in a throwaway repo under `cache/`.
- **Results:**
  - Checks: 47/47, 31/31, and 0 of 111 tracked files. Selftest: 5/5.
  - `git status --ignored` shows the same eight folders as before, so nothing visible became hidden.
  - The untracked files are exactly the intended new ones.
- **Docs:** the repo guide (a Layout note and a "Keep in sync" line), the bring-up skill's finishing steps, and the README index and Status.

**Problems**
- None broke. The old `.gitignore` was correct but covered only the known folders. A dump or image copied elsewhere, a raw capture or an archive was left to the pre-commit hook alone. The hook scans file bytes as stored (`secret_scan.py` has no archive handling), so it cannot see into a compressed archive.

**Discarded**
- **Ignoring `*.log` or `*.jpg` everywhere** → it would drop the committed evidence in `docs/evidence/`. The selftest proves 92 catches a `*.log` rule.
- **`build/`, `managed_components/` and `sdkconfig.old` rules** → no ESP-IDF build runs outside `firmware/` (docker, outputs in `out/`). A rule for something that cannot happen would mislead.
- **Running 92 in the pre-commit hook** → not asked for, and `.gitignore` rarely changes. It can be added later.

## 2026-11-10 08:05–08:55 — animated name "Sandeep" instead of the face demo

The user asked for the text "Sandeep" on the screen instead of the faces, animated if possible.

**Work**
- **Dev patch** (`patches/xz-dev-tools.patch`, 5 files):
  - `CONFIG_XZ_DEV_NAME_DEMO` and `CONFIG_XZ_DEV_NAME_TEXT` in `main/xz_dev.cc`: a full-screen LVGL panel on top of the stock UI, created after `SetupUI()`.
    - The letters drop in one by one with a bounce, then bob in a travelling wave in scrolling rainbow colours.
    - A ring of 24 lights shows a bright light chasing round.
    - One `lv_timer` (30 ms) makes each step, writing only values that changed, and redraws it at once with `lv_refr_now`.
    - Shown only in the Starting state.
    - A task polls every 500 ms: it hides the panel in WiFi setup or online, and keeps it in front. It prints `XZNAME alive` every 5 s.
  - `CONFIG_XZ_DEV_WIFI_NO_AUTO_CONFIG` in `main/boards/common/wifi_board.cc`: no 60 s timeout timer, and no immediate setup mode when no WiFi is saved. BOOT still enters setup.
  - Kconfig help for all three options.
  - `scripts/17` host test still passes; the patch round-trips with revert and apply.
- **Font fit:** the firmware tries every enabled Montserrat size, largest first. It keeps the first whose glyph boxes (wave included) stay inside a circle 5 px inside the ring.
  - Glyph widths from LVGL's font files for "Sandeep": 162 / 180 / 197 / 215 px at 36 / 40 / 44 / 48 px.
  - `config/dev-name-demo.sdkconfig` therefore enables 44 and 40.
- **Script:** `scripts/28-face-demo.sh` became `scripts/28-dev-demo.sh --demo face|name`.
  - The name checks are name, shots (≥ 3 different pictures), motion and quiet.
  - Motion and quiet keep listening without a reset until about 72 s after boot, past the stock 60 s timeout.
  - The name demo leaves the device running; the face demo still parks.
  - References were updated in README, the two skills, `docs/build.md` and `scripts/29`.
- **Device runs** (all with 28):
  - 08:20, first flash: all checks PASS, but only 16 steps per second.
  - 08:27, timer 33 → 10 ms: still 16.
  - 08:42, the speed fix: 24–25 redraws per second, none of them whole-screen.
  - 08:49 and 08:51, `--no-flash` re-runs after the script fixes: PASS. The 08:51 run wrote `docs/evidence/name-demo/`.
- **Speed fix:**
  - Cause: LVGL keeps 32 changed areas per redraw, and a step marked 38 (README findings log, 08:42).
  - The dim lights follow the rainbow only every 6th step (`kDimEvery`).
  - Each step is redrawn at once, so two steps never share a redraw.
  - A redraw probe (`LV_EVENT_RENDER_START`, `FLUSH_START`, `RENDER_READY`) adds `fps`, `draw_ms`, `px` and `full` to `XZNAME alive`.
- **Script 28, second round:**
  - `motion` requires ≥ 15 steps/s, the redraw figures, and fewer than 1 in 10 whole-screen redraws.
  - The console copy starts at the first ROM banner.
  - `--evidence DIR` copies a passing run with UUID-shaped values redacted, and fails if one survives.
- **Also updated:** the repo guide's parking rule names the silent-build exception. The flash-and-verify skill covers `--evidence` and the 32-area limit.

**Problems**
- **Slow animation:** 16 steps per second, and every redraw was the whole screen (see the speed fix).
- **The first `--no-flash` run FAILed `motion` ("rising: NO"):**
  - The app was still running when 27 opened the port.
  - Its last heartbeat, cut off mid-line by the reset's ROM banner, headed the capture and looked like a restart.
  - Fix: the copy now starts at the first banner. Not the last one, because a crash and reboot during the run must stay visible.
- **The board UUID is in every boot log:** the evidence copy redacts it.
- **About 8,000 px per redraw are unexplained:** probably the stock UI's scrolling labels behind the panel. No area dump was made.

**Discarded**
- **A rotating full-screen `lv_arc` for the ring** → it redraws the whole 240×240 screen every frame. Small dot objects redraw only the lights that change.
- **One label for the whole word** → the letters could not move separately. Instead there is one label per letter, placed at its pen position from `lv_font_get_glyph_width(letter, next)`, so kerning is kept.
- **Fitting the font by line height** → too cautious: it rejects 44 px although the ink fits. Instead the firmware checks each glyph's box (`lv_font_get_glyph_dsc`; box top = `line_height - base_line - box_h - ofs_y`, `lv_draw_label.c:626`).
- **Drawing on `lv_layer_top()`** → the screenshot path snapshots only `lv_screen_active()`, so screenshots would not show the name. The panel is a child of the active screen instead; all stock screen objects are created earlier, in `SetupUI()`.
- **Not starting the network at all** → BOOT in the Starting state calls `EnterWifiConfigMode()`, which uses a `WifiManager` that was never initialised. Only the automatic setup-mode paths are switched off instead.
- **Muting the WiFi prompt** → the volume persists in NVS (Do not repeat #6). Not entering setup mode also keeps the open hotspot away.
- **A second copy of script 28 for the name** → generalised with `--demo` instead (DRY).
- **A shorter timer period (33 → 10 ms)** → no change: drawing, not the period, set the pace.
- **Stepping from the display's `LV_EVENT_REFR_START`** → rejected after reading `lv_refr.c`.
  - Without a perf monitor, LVGL's refresh timer pauses itself after each redraw, and only a change resumes it.
  - So a step that changed nothing would stop the animation for good.
  - Instead an `lv_timer` steps, then calls `lv_refr_now`.
- **Raising `LV_INV_BUF_SIZE`** → it is a `#define` inside the managed LVGL component, not a Kconfig option, and we don't edit managed components.
- **Hiding or unloading the stock screen to stop its scrolling labels** → it changes stock UI state for perhaps a third of a redraw. Not done.

## 2026-11-10 07:10–08:00 — git, CHANGES.md, secret guard, agent skills

**Work**
- **Git.** Repo initialised as a local repo with no remote. Baseline commit `6ad75bd`, 82 files.
  - `.gitignore` keeps out dumps, the upstream checkout, builds, caches, downloads, logs and machine state, with the reason for each.
- **Secret guard.** `scripts/90-check-secrets.sh` (engine `scripts/py/secret_scan.py`) is the pre-commit hook, via `.githooks/pre-commit` and `core.hooksPath`.
  - It refuses anything under `backups/` and any `.bin` over 64 KiB.
  - It refuses the value of every NVS key the analyser redacts, taken from every dump.
  - It prints file and key only. `--explain` shows the hit's line with the value masked.
  - `--selftest` (`scripts/py/selftest_secret_scan.py`) passes 15/15 checks on a synthetic dump.
- **Evidence.** The board UUID is redacted in `docs/evidence/face-demo/console.log`. The factory boot log is kept as `docs/evidence/factory-boot.log`, also redacted.
- **CHANGES.md.** This file was started and seeded from the README findings log and session notes.
- **Agent setup:**
  - `.agents/REPO_GUIDE.md`, with `AGENTS.md`, `CLAUDE.md` and `GEMINI.md` as symlinks to it.
  - Six skills in `.agents/skills/`, with per-skill symlinks in `.claude/skills/` and `.gemini/skills/`.
  - `scripts/91-agent-skills.sh link|check|discover|selftest`, with `scripts/py/check_skills.py`. Its selftest catches 15/15 kinds of breakage.
  - Layout chosen from the official Claude Code, claude.ai, Gemini CLI and Codex docs, then corrected against the installed tools.
  - Discovery verified with the real CLIs (`scripts/91-agent-skills.sh discover --claude`):
    - Gemini CLI: `gemini skills list` lists all 6.
    - Codex: `codex debug prompt-input` contains all 6 plus the repo guide.
    - Claude Code: its debug log shows `project: 6` loaded from `.claude/skills`. This running session also listed all 6 as available skills without `/reload-skills`.
  - The skill framework's own `validate_skill.py` passes all 6.

**Problems**
- **First secret scan: 4 hits.**
  - 2 were a short vendor test value inside longer strings (the base64 alphabet in the dev patch and test harness). Fix: token-boundary matching.
  - 1 was a public placeholder that a fake selftest token starts with. Fix: `-` and `_` now count as token characters, plus a placeholder list.
  - 1 was real: the board UUID in the committed evidence log. Fix: redacted.
- **Transcript-mining subagent stopped by safeguards** (API error `reasoning_extraction`, request `req_011CgtRop2b7TAaaWDntGMQf`). The overnight entry below is reconstructed from the README findings log instead, so small dead ends may be missing.
- **Broken doc reference.** The header of `scripts/27-screenshot.sh` pointed to a non-existent `docs/dev-patch.md`. It now points to `docs/build.md`.
- **Two docs URLs given by the user now redirect.** claude.com/blog goes to anthropic.com/engineering; developers.openai.com/codex/skills goes to learn.chatgpt.com/docs/build-skills.
- **The Gemini CLI docs carry a banner** saying Gemini CLI was replaced by Antigravity CLI on 2026-06-18.
- **First discovery run: Gemini listed none of the skills.**
  - Assumed from the current docs: Gemini reads `.agents/skills` itself, so `.gemini/skills` links were left out to avoid duplicates.
  - The installed 0.27.3 has no such alias: `gemini-cli-core/dist/src/skills/skillManager.js` and `config/storage.js` read only `~/.gemini/skills` and `<project>/.gemini/skills`.
  - Fix: per-skill links in `.gemini/skills/` too. Re-run: all 6 listed.
- **The headless Claude Code request failed with "Credit balance is too low".** The shell's `ANTHROPIC_API_KEY` takes precedence over the claude.ai login, so the model never answered.
  - First idea: look for `skills/<name>` paths in Claude Code's `--debug-file` log. It found nothing, because the log names no skills.
  - The log does record the skill directories and counts before the request: `Loaded 29 unique skills (… project: 6 …)`.
  - `discover --claude` now checks those lines, so it works even when the request fails.

**Discarded**
- **Mining the session transcript** → blocked → keep CHANGES.md current during work (Do not repeat #11).
- **Leaving out `.gemini/skills` links on the strength of the docs** → wrong for the installed version (#14).
- **A whole-directory `.claude/skills` link** → undocumented (#12).
- **Substring secret matching** → false positives (#13).
- **Re-running the Claude check under the claude.ai login** (`env -u ANTHROPIC_API_KEY`) → not needed, because the debug log is evidence. It would also change which account pays, so it is not done without asking.
- **Looking for skill names in Claude Code's debug log** → it has none. Use the directory and count lines.

**Open**
- **Claude Code's debug-log format is undocumented.** If an update changes the `Loaded N unique skills` line, `discover --claude` reports a PROBLEM and its parser in `scripts/91-agent-skills.sh` needs updating.
- **The guard only knows secrets that are in `backups/`.** A secret that never went through a dump (an API key typed into a config file) is not covered.

## 2026-11-10 00:30–07:06 — overnight bring-up: build, flash, face on screen

Reconstructed afterwards from the README findings log and session notes (see the 07:10 entry). The work paused 01:31–06:36 because the usage limit was hit.

**Work**
- **00:36–00:54 — device access.**
  - USB survey and discovery: `scripts/00`–`04`.
  - Windows esptool: `scripts/20`.
  - Chip info: `scripts/21`.
  - Full factory backup: `scripts/22`, 86 s, sha256 `4f1e9943…`.
  - Boot-log capture: `scripts/25`; parking: `scripts/26`.
- **00:42 — firmware source.** v2.5.2 checked out with `scripts/10`.
- **Docker build pipeline:** `scripts/11`, `12`, `13`, `14`.
  - Image pull: 335 s.
  - First full build: 501 s. Incremental builds: 90–135 s.
- **Flash-image analysis (analysis subagent):** `scripts/30`–`33`. Its selftest `scripts/39` passes 76/76.
- **06:37–06:40 — factory dump analysed.** NVS holds the vendor's test WiFi `spotpear-test` and official-server credentials. Reading the source showed stock firmware never shows faces offline.
- **Dev patch** `patches/xz-dev-tools.patch` (`main/xz_dev.cc`, behind Kconfig, off by default), managed with `scripts/19`:
  - serial JPEG screenshots, protocol-tested without hardware by `scripts/17`
  - the offline face demo
- **06:49 — first face-demo flash** with `scripts/28`: all five evidence checks PASS. 06:55: colour fix, rebuild, reflash, PASS again.
- **06:57–07:00 — restore round trip proven** with `scripts/29`: byte-identical read-back, boots 2.1.0. 07:01: dev build put back, chip parked.
- **07:05 — research dossier** `docs/board-dossier.md` (subagent). Its load-bearing claims were re-checked in the source.

**Problems**
- **00:36 — no USB device at all.** A charge-only cable, or the board was off. Fixed by a replug; `scripts/02` and `scripts/03` now print a checklist.
- **01:23 — first docker build (8 min 21 s) rejected by our own `SHA256SUMS` step.** Fixed in `scripts/11`. The check worked as designed: a failed build never touches `out/`.
- **`scripts/19-patches.sh refresh` left intent-to-add entries in the firmware checkout's index.** It now resets them, and the patch round trip is verified clean.
- **06:49 — faces cyan in the screenshots.**
  - `png_probe.py` showed the flashed PNGs are yellow (`#fde030`).
  - A byte swap maps `0xFF06` to that exact cyan.
  - Root cause is upstream (Do not repeat #7). Fixed in the dev patch.
- **A note said WiFi-setup mode shows a "gear" icon.** This was wrong: `"gear"` is in no icon table, and `SetEmotion` leaves the screen alone (`lcd_display.cc:1149-1168`). Corrected in the README.
- **Usage limit 01:31–06:36.** A five-hour stop. README Status made the restart cheap.

**Discarded**
- usbipd, Python on Windows, a host ESP-IDF, ESP-IDF 5.x (Do not repeat #1–4).
- Waiting for WiFi to see faces (#5); a temporary mute (#6); upstream screenshots (#7); the panel self-test firmware (#8).
- **Not taken from the dossier:** a board-only `SetEmotion("neutral")` after `SetupUI`, and changing `"gear"` to `"neutral"` in core code. The config-gated dev patch keeps upstream pristine.

**Open**
- **The glass:** a human still has to confirm that the glass lights up. Screenshots and log lines are indirect evidence.
- **Next step:** WiFi plus a voice server (official, or self-hosted with the user's API keys). This needs the user.
- **Hardware unknowns:**
  - Does the board revision match the schematic (GPIO41/GPIO3)?
  - How does the power button behave?
  - Is this the touch variant? The touch chip reads ID `0x00`.
- **Upstream bug report:** the snapshot colour bug is not reported upstream; that needs the user's OK.
