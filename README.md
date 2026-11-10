# xiaozhi ESP32-S3 ball — build, flash and inspect from WSL2

Working notes and tooling for a **Spotpear ESP32-S3 1.28" round-LCD "XiaoZhi AI" ball**
([AliExpress listing](https://www.aliexpress.us/item/3256808441364518.html)), driven from
WSL2 on a Windows 11 laptop.

Goal: be able to build the [xiaozhi-esp32](https://github.com/78/xiaozhi-esp32) firmware,
flash it to the device, and see a face on the display — with every step captured as a
script so nothing has to be re-derived later.

> **Rule for this repo:** nothing is done as a one-off command. Every probe, check,
> build or flash is a documented script under `scripts/`, listed in the
> [script index](#script-index). If you do something new, script it and add it here.
> Log work, problems and abandoned approaches in [CHANGES.md](CHANGES.md).
> AI agents start at [.agents/REPO_GUIDE.md](.agents/REPO_GUIDE.md); `AGENTS.md`,
> `CLAUDE.md` and `GEMINI.md` link there.

## Status

_See the [findings log](#findings-log) at the bottom for the dated trail._

| Step | State |
|---|---|
| Device visible on USB | ✅ `303A:1001` on **COM11** (ESP32-S3 native USB-Serial/JTAG) |
| Talk to the bootloader | ✅ esptool v5.6.0 (Windows exe run from WSL), no BOOT button needed |
| Backup of factory flash | ✅ `backups/aca704229d70/20261110-004927-factory-full-16MB.bin` |
| Serial console capture | ✅ full boot log from the ROM banner (`logs/serial/`) |
| Factory firmware identified | ✅ xiaozhi **v2.1.0**, board `sp-esp32-s3-1.28-box` (`scripts/30-analyze-flash-image.sh`) |
| Firmware source | ✅ cloned, tag `v2.5.2` |
| Build in docker | ✅ stock `out/…/stock-v2.5.2/` and dev `out/…/dev-face-v2.5.2/` (ESP-IDF v6.1) |
| Flash our build | ✅ 5/5 regions hash-verified by the chip, 19 s, NVS kept |
| **Face on screen** | ✅ **our v2.5.2 build draws the xiaozhi emoji faces**: 8/8 screenshots from the device, see [below](#getting-a-face-on-the-screen) |
| Way back to factory | ✅ proven on the device: restore → read-back byte-identical → boots factory 2.1.0 (`scripts/29-test-restore.sh`) |
| Version control | ✅ local git, no remote. The pre-commit hook blocks device secrets (`scripts/90-check-secrets.sh`); [CHANGES.md](CHANGES.md) is the running log |
| AI-agent setup | ✅ 6 skills in `.agents/skills/` plus [repo guide](.agents/REPO_GUIDE.md). Claude Code, Gemini CLI and Codex each verified to load all 6 (`scripts/91-agent-skills.sh discover --claude`) |
| On the device now | dev face-demo build (`dev-face-v2.5.2`, English UI), **parked in the bootloader** (screen dark, silent) |
| Next | WiFi + a voice server (official xiaozhi.me, or self-hosted); see [next steps](#next-steps) |

## How the pieces connect

```
 WSL2 (Ubuntu 22.04)                     Windows 11 host                    device
 ┌──────────────────────────┐  interop   ┌────────────────────────┐  USB   ┌──────────────┐
 │ scripts/*.sh             │ ─────────► │ powershell.exe         │ ─────► │ ESP32-S3     │
 │ docker: espressif/idf    │  (.exe     │ esptool.exe  ► COM11   │  CDC   │ 303A:1001    │
 │ firmware/xiaozhi-esp32   │   calls)   │ scripts/win/*.ps1      │        │ 1.28" LCD    │
 └──────────────────────────┘            └────────────────────────┘        └──────────────┘
```

* WSL2 cannot see USB devices. The board is plugged into **Windows**, so everything that
  touches it runs on Windows, launched from bash through WSL interop.
* `usbipd-win` (USB passthrough into WSL) is **not** installed and needs admin; we do not
  depend on it.
* Builds happen in WSL inside the `espressif/idf` docker image; Windows only flashes.

## Hardware

Read from the device itself (`scripts/21-chip-info.sh` → `docs/device/chip-info.txt`, and the
factory boot log `docs/evidence/factory-boot.log`, board UUID redacted):

| | |
|---|---|
| Product | Spotpear ESP32-S3-1.28-BOX ("XiaoZhi AI voice chat robot ball") |
| Chip | ESP32-S3 (QFN56) rev v0.2, dual core 240 MHz, 40 MHz crystal |
| Memory | 16 MB quad SPI flash (JEDEC `20:4018`), 8 MB octal PSRAM (embedded, AP gen 3) — "N16R8" |
| MAC | `ac:a7:04:22:9d:70` |
| Security | Secure boot **off**, flash encryption **off**, no eFuse keys burned → freely reflashable and restorable |
| USB identity | `303A:1001` USB-Serial/JTAG → `USB Serial Device (COM11)`, in-box Windows driver, no bridge chip |
| Factory firmware | xiaozhi `2.1.0` (compiled Jan 26 2026), board/SKU `sp-esp32-s3-1.28-box` |
| xiaozhi board id | `sp-esp32-s3-1.28-box` (`main/boards/spotpear/sp-esp32-s3-1.28-box/`) |

From the firmware's `config.h` (the factory boot log confirms these drivers start):

| | |
|---|---|
| Display | GC9A01 240×240 round LCD on SPI (SCLK 4, MOSI 2, CS 5, DC 47, RST 38, backlight 42 inverted) |
| Audio | ES8311 codec on I2C (SDA 15, SCL 14), I2S (MCLK 16, WS 45, BCLK 9, DIN 10, DOUT 8), PA 46 |
| Touch | CST816D on I2C (SDA 11, SCL 7, RST 6, INT 12) — factory log reads chip ID `0x00`, so this unit may be the no-touch variant |
| Power | GPIO3 = power hold, GPIO41 = "charging" input, GPIO1 = battery ADC |
| Other | BOOT button GPIO0, LED GPIO48 |

### Things about this board that bite

* **USB data needs a real data cable.** With a charge-only cable Windows shows nothing at all.
* **No BOOT button gymnastics.** The USB-Serial/JTAG peripheral lets esptool reset the chip
  into download mode and back by itself.
* **Idle shutdown (online only).** The board code runs `PowerSaveTimer(-1, 60, 290)`. After
  290 s *idle* it drives GPIO3 low and deep-sleeps with no wake source set. That drops the device
  off USB until the power button is cycled. Three things normally prevent it:
  - The timer only counts in the Idle state, so an **offline device never sleeps**
    (`application.cc:1300-1303`).
  - It is disabled while GPIO41 reads high ("charging"). On the vendor schematic GPIO41 is a bare
    test pad read with the internal pull-up, so it should always read high, if this unit matches
    the schematic. The factory log shows `Power save timer disabled` 100 ms after boot.
  - The WiFi setup page's Advanced tab has an **Enable Sleep Mode** checkbox. Unticking it
    (NVS `wifi/sleep_mode`) turns the timer off for good.

  Details are in [`docs/board-dossier.md`](docs/board-dossier.md).
* **It has a speaker.** When the stored WiFi is out of reach, the firmware speaks a WiFi-setup
  prompt 60 s after boot. Unattended sessions park the chip before then
  (`scripts/26-park-in-bootloader.sh`).

## Getting a face on the screen

```bash
scripts/19-patches.sh apply                    # dev tooling into the firmware tree (off unless enabled)
scripts/11-build-firmware.sh --label dev-face-v2.5.2 \
    --sdkconfig-append config/lang-en-us.sdkconfig --sdkconfig-append config/dev-face-demo.sdkconfig
scripts/28-face-demo.sh                        # flash + boot + 8 screenshots + evidence checks + park
```

**To just look at it:** unplug and replug the USB cable, or run `scripts/25-serial-capture.sh --reset run`.
The faces change every 5 s. After 60 s the firmware gives up on the stored factory WiFi
(`spotpear-test`), **speaks a WiFi-setup prompt** and opens its hotspot, which should be
`Xiaozhi-9D71`. The name is `Xiaozhi-` plus the last two bytes of the softAP MAC (chip MAC + 1);
the screen shows the exact name. Going by the code, the faces keep cycling under the setup hint,
but nobody has watched that part yet. An offline device never shuts itself down
(`CanEnterSleepMode()` requires the Idle state, `application.cc:1300-1303`), so it can stay on.

Why a demo build is needed: stock firmware only shows emoji faces once it is **online**. The 21
PNG faces live in the `assets` partition and are loaded by `ActivationTask → CheckAssetsVersion →
assets.Apply()` after the network connects (`application.cc:370,437`). Offline, the stock screen
shows a robot icon, and the icon stays in WiFi setup mode. The setup alert asks for a `"gear"`
emotion that is in no icon table, and `SetEmotion` leaves the screen alone when a lookup fails
(`lcd_display.cc:1149-1168`). `CONFIG_XZ_DEV_FACE_DEMO`
(`patches/xz-dev-tools.patch`, `main/xz_dev.cc`) loads the same PNGs right after boot and cycles
them while offline. It never touches the screen once the device is online.

Evidence from the last run (`docs/evidence/face-demo/`), captured from the device over USB:

| # | t after boot | face | |
|---|---|---|---|
| 1 | 5.1 s | neutral | `docs/evidence/face-demo/20261110-065435-face-demo-01.jpg` |
| 5 | 25.1 s | loving (heart eyes) | `…-05.jpg` |
| 7 | 35.1 s | cool (sunglasses) | `…-07.jpg` |
| all 8 | | neutral, happy, laughing, funny, loving, winking, cool, relaxed | `console.log` has the boot log |

What the evidence does and does not prove: screenshots are the frames LVGL rendered, so they
prove our firmware runs, loads the assets and draws the faces. The boot log proves the GC9A01
panel driver initialised and the backlight was set to 75 %. That the glass physically lights up
still needs a human look.

**Upstream bug found on the way:** stock `LvglDisplay::SnapshotToJpeg()` byte-swaps the RGB565
buffer and then tells the encoder it is little-endian (`main/display/lvgl_display/lvgl_display.cc:332-345`
vs `jpg/image_to_jpeg.cpp:137-138`). On ESP32-S3 every colour except black and white comes out wrong:
yellow faces turn cyan (`docs/evidence/face-demo/stock-snapshot-bug-cyan-laughing.jpg`). This
affects the MCP `self.screen.snapshot` tool, not the display. Our dev screenshots take their own
snapshot without the swap.

## Layout

```
README.md            this file (index + runbook + findings)
CHANGES.md           running log: work, problems, discarded approaches ("Do not repeat")
AGENTS.md CLAUDE.md GEMINI.md    symlinks to .agents/REPO_GUIDE.md (instructions for AI agents)
.agents/             REPO_GUIDE.md + skills/ (the one real copy of each agent skill)
.claude/skills/ .gemini/skills/  per-skill symlinks into .agents/skills (scripts/91-agent-skills.sh)
.githooks/           pre-commit secret guard (scripts/90-check-secrets.sh --install-hook)
scripts/             every action, numbered by area (see index)
scripts/lib/         shared bash helpers (common.sh)
scripts/win/         PowerShell halves that run on the Windows host
docs/                longer write-ups, one topic per file
firmware/            upstream source checkouts (xiaozhi-esp32)                    [not in git]
out/                 build artifacts ready to flash                              [not in git]
cache/               docker ccache, component downloads, test scratch            [not in git]
prebuilt/            official prebuilt firmware downloads                        [not in git]
backups/             flash dumps from the device: WiFi password, tokens          [NEVER in git]
tools/               downloaded host tools (esptool for Windows, ...)            [not in git]
state/               small env files written by scripts (COM port, source ref)   [not in git]
logs/                timestamped output of every script run                      [not in git]
```

Write-ups in `docs/`:

* [`docs/build.md`](docs/build.md): the docker build, including quick reference, measured
  times, wiring, what lands in `out/`, config knobs and local firmware changes.
* [`docs/flash-image-analysis.md`](docs/flash-image-analysis.md): how to read an analyser report;
  what shipped on this device versus our build.
* [`docs/board-dossier.md`](docs/board-dossier.md): power, sleep and shutdown; what the screen
  shows when; the vendor wiki, schematic, BOM and pin cross-check; prebuilt images; ESPHome
  configs. This was research by a subagent; it cites source lines, and its load-bearing claims
  were re-checked in the source.
* `docs/device/chip-info.txt`: chip, flash, MAC and security state as read from the device.
* `docs/evidence/face-demo/`: the screenshots and boot log behind the "face on screen" result.

## Script index

Numbering: `0x` survey/discovery · `1x` source + build · `2x` device I/O (esptool, serial) ·
`3x` flash-image analysis · `4x` research helpers · `9x` repo hygiene (git, agent setup).

| Script | What it does | Touches device? |
|---|---|---|
| `scripts/00-survey-wsl.sh` | Tools, resources, docker and serial visibility on the WSL side | no |
| `scripts/01-survey-windows.sh` | User/elevation, usbipd, Python, esptool, drivers on the Windows side | no |
| `scripts/02-list-usb.sh [--all] [--watch N]` | USB devices + COM ports on Windows, flags ESP32-like ones, prints a verdict/checklist | read-only |
| `scripts/03-wait-for-device.sh [--timeout S]` | Blocks until an ESP32-like device enumerates; writes `state/device.env` (`XZ_PORT`) | read-only |
| `scripts/04-keep-awake.sh [--show] [--hours N]` | Shows Windows sleep timeouts; can hold the PC awake for N hours without changing settings | no |
| `scripts/10-fetch-firmware-source.sh [--ref R] [--info]` | Clones/updates `firmware/xiaozhi-esp32`, checks out newest release tag, records ref | no |
| `scripts/11-build-firmware.sh [--label L] [--set CONFIG_X=V] [--sdkconfig-append F] [--clean]` | **Builds the firmware in docker** (`espressif/idf:v6.1`, pinned by digest) with upstream's own `scripts/build.py`; verified artifacts + `build-info.txt` + `SHA256SUMS` land in `out/<board>/<label>/`. Every `--set` line is checked to have taken effect | no |
| `scripts/12-inspect-build.sh [--label L] [--list]` | Re-verifies a build in `out/`: partition table, offsets, fill levels, image checksums/SHA-256, app descriptor | no |
| `scripts/13-idf-image.sh [--pull]` | The only place the ~8.5 GB ESP-IDF image is pulled; shows its digest vs. the pin and the tool versions inside | no |
| `scripts/14-menuconfig.sh [--delta]` | menuconfig inside the container (needs a real terminal); `--delta` prints how the tree's config differs from the last build, as `--set` lines | no |
| `scripts/17-test-screenshot-protocol.sh` | Hardware-free test: compiles the device-side screenshot dumper natively (in docker), runs it, and checks the host decoder reproduces every payload byte-for-byte | no |
| `scripts/19-patches.sh status\|apply\|revert\|refresh` | Our local firmware changes live in `patches/*.patch`; this applies/reverts them on the upstream tree and regenerates the patch from the tree | no |
| `scripts/20-setup-esptool.sh [--force] [--version T]` | Downloads Espressif's standalone `esptool.exe` into `tools/esptool-win/`, records it in `state/esptool.env` | no |
| `scripts/21-chip-info.sh [--run]` | Chip model, flash id/size, MAC, secure-boot/flash-encryption state → `docs/device/chip-info.txt` | read-only, resets chip |
| `scripts/22-backup-flash.sh [--label L] [--run]` | Reads the whole flash into `backups/<mac>/…-full-16MB.bin` (+ sha256). ~90 s | read-only, resets chip |
| `scripts/23-flash-firmware.sh --dir D [--dry-run] [--erase-nvs] [--merged] [--run]` | **Writes** a build to the device after safety checks (backup exists, chip/flash size match, security off, files fit). Default keeps NVS | **writes flash** |
| `scripts/24-restore-flash.sh [--file F] [--dry-run] [--run]` | **Writes** a full backup back (sha256, size and MAC checked first) — the way home to factory state | **writes flash** |
| `scripts/25-serial-capture.sh [--reset run] [--seconds N] [--until RE] [--label L]` | Scripted serial monitor: records the console to `logs/serial/`, optionally restarting the app first | resets chip with `--reset run` |
| `scripts/26-park-in-bootloader.sh` | Stops the app and leaves the chip in download mode (stays on USB, silent, screen dark) | resets chip |
| `scripts/27-screenshot.sh [--reset run] [--count N] [--label L]` | Saves what the LCD is showing as `logs/screens/*.jpg`, decoded from the dev firmware's serial screenshot dump | resets chip with `--reset run` |
| `scripts/28-face-demo.sh [--no-flash] [--leave-running] [--dir D]` | **End to end:** flash the face-demo build, boot it, collect 8 screenshots, PASS/FAIL the boot-log evidence (app, panel, faces, shots, health), park before the 60 s WiFi prompt | **writes flash** |
| `scripts/29-test-restore.sh [--file F]` | **Proves the way home:** writes the factory backup back, reads the whole flash back before anything boots, requires a byte-identical match, boots it and checks the app version, then parks. Leaves the device on factory firmware | **writes flash** |
| `scripts/30-analyze-flash-image.sh <image.bin>` | Says exactly what is in a flash image (dump, merged binary or our build): bootloader, partition table, active OTA slot, app versions, **which board it was built for**, OTA URL, NVS keys (credentials redacted), assets contents | no |
| `scripts/31-fetch-prebuilt-firmware.sh [--board B] [--version T] [--list]` | Downloads the official prebuilt release ZIP for a board into `prebuilt/<version>/<board>/` (asset names read from the release, not guessed) | no |
| `scripts/32-compare-images.sh <a.bin> <b.bin>` | Partition-by-partition comparison of two images (e.g. a read-back after flashing vs. what was written); never prints NVS contents | no |
| `scripts/33-crosscheck-idf-tools.sh <image.bin>` | Cross-checks our parsers against Espressif's own tools (gen_esp32part, esptool image-info, NVS parser) inside docker | no |
| `scripts/39-selftest-flash-tools.sh` | 76 checks on synthetic images: 30/32 report damage correctly and never leak secrets | no |
| `python3 -I scripts/py/png_probe.py <file>` | Decodes PNGs embedded in any file (e.g. an assets image) with the stdlib and prints their true pixel colours; used to prove the screenshot colour bug | no |
| `scripts/90-check-secrets.sh [--tracked] [--explain] [--selftest] [--install-hook]` | **Pre-commit guard:** refuses commits containing anything under `backups/`, flash images, or the value of any NVS key the analyser redacts (WiFi password, server credentials, board UUID), taken from every dump in `backups/`. It prints file and key only, never a value. `--selftest` proves it on a synthetic dump | no |
| `scripts/91-agent-skills.sh check\|link\|discover [--claude]\|selftest` | Keeps the AI-agent setup consistent. There is one real copy of each skill in `.agents/skills/`, with per-skill links for Claude Code and Gemini CLI, and `AGENTS.md`/`CLAUDE.md`/`GEMINI.md` point to `.agents/REPO_GUIDE.md`. It validates frontmatter, the four sections and the script paths each skill names. `discover` asks the installed CLIs what they actually load | no |

Every script has a header comment with usage (`--help` prints it), and mirrors its output into `logs/`.

Supporting files: `scripts/lib/common.sh` (paths, logging, `win_ps`), `scripts/lib/device.sh`
(port lock, `xz_esptool`), `scripts/lib/idf-docker.sh` (pinned image, `xz_idf_run`, build lock),
`scripts/win/*.ps1` (the Windows halves: `list-usb`, `wait-for-device`, `survey-windows`,
`keep-awake`, `serial-capture`), `scripts/container/*` (the halves that run inside the ESP-IDF
container), `scripts/py/*.py` (standard-library Python used by the numbered scripts),
`config/*.sdkconfig` (named sets of build options for `--sdkconfig-append`), `patches/*.patch`
(our changes to the upstream firmware, managed by `19-patches.sh`).

## Conventions

* Scripts `source scripts/lib/common.sh` for paths (`XZ_ROOT`…), `log/warn/die`, `win_ps`
  (run a `.ps1` on Windows) and `xz_run_logged` (tee into `logs/`).
* **Only one process may hold the COM port.** Anything in the `2x` range takes the port
  exclusively; never run two of them at once.
* `state/device.env` holds the current port. Override per call with `XZ_PORT=COM7 scripts/...`.
* Upstream source under `firmware/` stays pristine; local changes live as patch files.

## Next steps

1. **Put it on your WiFi** (needs you).
   - Replug the device and wait about 60 s for the setup prompt. Pressing BOOT while it is still
     starting skips the wait (`sp-esp32-s3-1.28-box.cc:373-377`).
   - From a phone, join the hotspot (expected `Xiaozhi-9D71`; the screen shows the name), open
     `http://192.168.4.1` and pick a **2.4 GHz** network.
   - On the same page's Advanced tab, untick **Enable Sleep Mode** if the ball should never power
     itself down once online.
2. **Pick a voice server.**
   * Official: the build points at `https://api.tenclass.net/xiaozhi/ota/`. Once online, the
     device shows a 6-digit activation code to bind at [xiaozhi.me](https://xiaozhi.me). After
     that it is idle with the stock neutral face, and it shows its own faces from then on.
     At every boot, the firmware installs any newer version the server offers
     (`application.cc:493-498`), so the official server may replace this dev build with its own
     release. That is harmless, because faces work online either way. `scripts/28-face-demo.sh`
     puts the dev build back.
   * Self-hosted
     ([xinnan-tech/xiaozhi-esp32-server](https://github.com/xinnan-tech/xiaozhi-esp32-server), in
     docker): needs your LLM/ASR/TTS API keys. Then rebuild with
     `--set 'CONFIG_OTA_URL="http://<server-ip>:8002/xiaozhi/ota/"'`. Caveat: docker inside WSL2
     (NAT mode) is not reachable from the LAN by default. You need WSL mirrored networking or a
     Windows port proxy (admin), or run the server elsewhere.
3. **Back to factory at any time:** run `scripts/24-restore-flash.sh --dry-run`, then run it again
   without `--dry-run`. `scripts/29-test-restore.sh` proved this end to end on 2026-11-10: the
   read-back was byte-identical and it booted 2.1.0.
4. **Pristine upstream builds:** `scripts/19-patches.sh revert` before `scripts/11-build-firmware.sh`
   (the build script refuses to label a modified tree `stock-*`).
5. **Home Assistant instead of xiaozhi** (the listing's Dexcom idea). Community ESPHome configs
   exist for this ball:
   - [RealDeco/xiaozhi-esphome](https://github.com/RealDeco/xiaozhi-esphome)
     (`devices/Spotpear Balls/Ball_v2.yaml`)
   - the glucose monitor built on it,
     [rilucca/xiaozhi-spotpear-diabetes](https://github.com/rilucca/xiaozhi-spotpear-diabetes)
     ([forum thread](https://community.home-assistant.io/t/project-xiaozhi-specball-v2-esp32-s3-as-a-desktop-diabetes-monitor-voice-assistant/988264))

   The dossier reports that their pins match our `config.h`. ESPHome replaces xiaozhi entirely;
   the factory backup brings it back.

## Findings log

* **2026-11-10 00:36** — First USB survey: no Espressif / CH34x / CP210x / FTDI device
  present, and none remembered by Windows at all (`02-list-usb.sh --all`). Diagnosis:
  charge-only cable or board powered off.
* **2026-11-10 00:42** — After a replug the board enumerated as `303A:1001` on COM11
  (`03-wait-for-device.sh`). That is the ESP32-S3's built-in USB-Serial/JTAG, so no bridge
  chip and no driver install are involved.
* **2026-11-10 00:42** — Source cloned at `v2.5.2` (commit `49b4380`). Boards are grouped by
  vendor since v2; ours is `main/boards/spotpear/sp-esp32-s3-1.28-box`. This release needs
  ESP-IDF ≥ 6.0.1 (upstream CI builds with `espressif/idf:v6.1`), not the 5.4 that older
  guides mention.
* **2026-11-10 00:48** — `esptool.exe` v5.6.0 (Windows build) runs fine when launched from the
  WSL filesystem. `21-chip-info.sh`: ESP32-S3 rev v0.2, 16 MB flash, 8 MB PSRAM, secure boot
  and flash encryption both disabled. esptool enters download mode by itself over
  USB-Serial/JTAG.
* **2026-11-10 00:50** — Full factory backup taken in 86 s (1.6 Mbit/s):
  `backups/aca704229d70/20261110-004927-factory-full-16MB.bin`,
  sha256 `4f1e9943f0920336a592ef94d5823e9493eeebe72ce5a3d1fb3ee505d33e4896`, 74.9 % erased.
* **2026-11-10 00:52** — `04-keep-awake.sh --show`: laptop is on AC and its AC sleep timeout
  is 0 (never), so nothing needs to be held awake tonight. On battery it would sleep after 10 min.
* **2026-11-10 00:54** — `25-serial-capture.sh --reset run`: the COM port stays open across
  an RTS reset, so the log is complete from `ESP-ROM:`. Factory firmware is xiaozhi 2.1.0 for
  `sp-esp32-s3-1.28-box`; display, codec and LVGL start; it holds WiFi credentials but reports
  `No AP found` here and keeps rescanning. Chip parked in the bootloader afterwards.
* **2026-11-10 01:23–01:27** — First docker build (8 min 21 s) compiled, but the artifact
  check rejected it over a bug in the build script's own `SHA256SUMS` step, so `out/` was not
  touched. Fixed; the incremental rebuild (2 min 15 s) passed. Usage limit hit at ~01:31; work
  resumed 06:36.
* **2026-11-10 06:37** — `30-analyze-flash-image.sh` on the factory dump: NVS holds the
  vendor's test WiFi `spotpear-test` plus official-server MQTT/WebSocket credentials; assets
  partition holds 21 PNG emoji. Our build carries the same 21 emoji names.
  `39-selftest-flash-tools.sh`: 76/76.
* **2026-11-10 06:40** — Read the v2.5.2 source: offline, stock firmware never shows an emoji
  face (assets are applied only after the network connects). Hence the dev face demo.
* **2026-11-10 06:49** — Dev face-demo build flashed (18 s, 5/5 hashes verified, NVS kept);
  `28-face-demo.sh`: all 5 evidence checks PASS, 8/8 screenshots show faces. But the faces were
  **cyan**. `png_probe.py` showed the flashed PNGs are yellow (`#fde030`), and the arithmetic
  showed a byte swap turns yellow `0xFF06` into exactly that cyan. Root cause: upstream
  `SnapshotToJpeg()` swaps bytes, then tells the encoder the data is little-endian.
* **2026-11-10 06:55** — Dev screenshot switched to its own non-swapping snapshot; rebuilt
  (1 min 29 s), reflashed, re-verified: **all checks PASS, faces yellow as in the artwork**.
  Chip parked.
* **2026-11-10 06:57–07:00** — `29-test-restore.sh`: factory backup written back, then read back
  before anything booted. The read-back is **byte-identical** to the backup in all 9 regions
  (sha256 `4f1e9943…`), and it boots xiaozhi 2.1.0. The way home is proven, not just dry-run.
* **2026-11-10 07:01** — `28-face-demo.sh` put the dev build back: 5/5 hashes verified and all
  evidence checks PASS again. Chip parked.
* **2026-11-10 07:10–08:00** — Repo put under git (local only). Details and dead ends are in
  [CHANGES.md](CHANGES.md).
  - **Secret guard as the pre-commit hook.** Selftest 15/15. On its first run it caught the board
    UUID in an evidence log, which is now redacted.
  - **Agent setup.** Six skills plus the repo guide. All three installed CLIs load all six:
    - Gemini CLI 0.27.3: `gemini skills list`. It reads only `.gemini/skills`, despite newer docs.
    - Codex 0.166.0: `codex debug prompt-input`.
    - Claude Code 2.1.321: the running session listed all six without `/reload-skills`, and the
      headless debug log shows `project: 6`. The headless request itself failed with "Credit balance
      is too low": the shell's `ANTHROPIC_API_KEY` takes precedence over the claude.ai login.
* **2026-11-10 07:05** — Research dossier `docs/board-dossier.md` (subagent). I re-checked its
  load-bearing claims in the source. Findings:
  - On USB the ball should stay on overnight, online or not.
  - The `"gear"` in the WiFi-setup alert is a no-op, so the robot icon stays.
  - At boot the firmware installs any newer version the OTA server offers.
  - The WiFi setup page has an Enable Sleep Mode checkbox.
  - Community ESPHome configs for this ball exist; both repos and the forum thread were
    confirmed live.
