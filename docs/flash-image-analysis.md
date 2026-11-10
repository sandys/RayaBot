# Flash image analysis

Tools for answering "what exactly is on this device / in this file?" without touching the device.
All of them are read-only, use only the Python standard library on the host, and never print
credentials (the NVS partition of a real device holds the WiFi password and server tokens).

| Script | Use it for |
|---|---|
| `scripts/30-analyze-flash-image.sh <image.bin>` | Full report on an image that starts at flash offset 0 (device dump, official `merged-binary.bin`, our `out/…/merged-binary.bin`) |
| `scripts/31-fetch-prebuilt-firmware.sh` | Download the official release ZIP for a board into `prebuilt/<version>/<board>/` |
| `scripts/32-compare-images.sh <a.bin> <b.bin>` | Which partitions differ between two images (e.g. a read-back after flashing vs. what was written) |
| `scripts/33-crosscheck-idf-tools.sh <image.bin>` | Our parsers vs. Espressif's own tools (run inside the ESP-IDF container) |
| `scripts/39-selftest-flash-tools.sh` | 76 checks on synthetic images: damage is reported, secrets never leak |

Exit status of `30`: `0` analysed and nothing wrong, `3` problems found (see the `PROBLEM`
lines in the summary), `1` could not run.

## How to read a report

* **second-stage bootloader** — header checks (magic `0xE9`, chip id `0x0009` = ESP32-S3), SPI
  mode/speed/size bits the ROM uses to read the rest of the flash, checksum and appended SHA-256.
* **partition table** — every entry, MD5 validity, and which upstream CSV it equals.
* **otadata** — both copies, sequence numbers, and the slot that actually boots. The
  bootloader picks the highest valid sequence; `would boot` also takes image validity into account.
* **app partitions** — segment walk, checksum, SHA-256 and the `esp_app_desc_t` (project,
  version, build time, ESP-IDF version). The **board identity** section finds the board name and
  type strings the firmware carries and cross-checks them against `main/boards/**/config.json`
  of the checked-out source. That is how a dump tells you which board profile a device runs.
* **NVS** — namespaces and keys with types. Credentials, tokens and identifiers are shown as
  `<redacted: N chars>`. `--secrets` reveals them only on an interactive terminal and never
  writes them to `logs/`.
* **other partitions** — recognised formats, e.g. a xiaozhi assets image with its file list.

## What shipped on this device (factory dump, 2026-11-10)

`scripts/30-analyze-flash-image.sh backups/aca704229d70/20261110-004927-factory-full-16MB.bin`

| | |
|---|---|
| Bootloader | valid, built Jan 26 2026 09:22:50 (ESP-IDF "HEAD-HASH-NOTFOUND", a vendor build) |
| Partition table | v2 16 MB layout, identical to `partitions/v2/16m.csv`; MD5 valid |
| Boot slot | `ota_0` (otadata copy 0, seq 1, VALID); `ota_1` blank |
| App | xiaozhi **2.1.0**, compiled Jan 26 2026 09:30:05, ELF sha256 `0ad36ae4…` (matches the boot log) |
| Board | `sp-esp32-s3-1.28-box`, confirmed against the source tree (built from the pre-v2 flat `main/boards/<board>` layout) |
| OTA URL | `https://api.tenclass.net/xiaozhi/ota/` (stock default) |
| NVS | `wifi`: SSID **`spotpear-test`** (the vendor's factory test network) + password; `mqtt` + `websocket`: endpoints of the official xiaozhi server with credentials; `board`: uuid; `display`: theme `light` |
| Assets | xiaozhi assets image, 24 files, 1.41 MB, checksum ok: text font, wake-word models, 21 PNG emoji |

So the device was set up and tested at the factory against the official server, on a WiFi
network that does not exist here. That is why its boot log loops on `No AP found`.

## Our build, for comparison

`scripts/30-analyze-flash-image.sh out/sp-esp32-s3-1.28-box/stock-v2.5.2/merged-binary.bin`
reports xiaozhi 2.5.2, ESP-IDF v6.1, the same board identity (now from the vendor-grouped
directory), the same partition layout, an empty NVS, and an assets image with the same 21 emoji
names (different text font: `font_noto_sans_common_16_4`).
