# Building the firmware (in docker)

Everything that compiles runs inside the official ESP-IDF image; nothing is installed on the
WSL host (project rule). The host only needs `docker` and `git`.

## Quick reference

```bash
scripts/13-idf-image.sh --pull                 # once: fetch espressif/idf:v6.1 (~8.5 GB, 5 min 35 s here)
scripts/10-fetch-firmware-source.sh            # firmware/xiaozhi-esp32 at the newest release tag (v2.5.2)

scripts/11-build-firmware.sh                   # stock build -> out/sp-esp32-s3-1.28-box/stock-v2.5.2/
scripts/12-inspect-build.sh --list             # what has been built
scripts/12-inspect-build.sh --label stock-v2.5.2

# English UI + voice prompts
scripts/11-build-firmware.sh --label lang-en-us --sdkconfig-append config/lang-en-us.sdkconfig

# Point the device at your own server (see "Server URL" below)
scripts/11-build-firmware.sh --label my-server \
    --set 'CONFIG_OTA_URL="http://192.168.1.10:8002/xiaozhi/ota/"'

# Development build with the face demo + serial screenshots (needs the dev patch)
scripts/19-patches.sh apply
scripts/11-build-firmware.sh --label dev-face-v2.5.2 \
    --sdkconfig-append config/lang-en-us.sdkconfig --sdkconfig-append config/dev-face-demo.sdkconfig
scripts/19-patches.sh revert                   # back to pristine upstream for stock builds
```

## Measured times (8 cores, WSL2)

| What | Time |
|---|---|
| `docker pull espressif/idf:v6.1` | 5 min 35 s |
| First full build (downloads ~100 managed components) | 8 min 21 s |
| Incremental rebuild, same label | 2 min 15 s |
| New label (forces `build/` + `sdkconfig` reset; ccache keeps it shorter than the first) | see the build log's last line |

## How a build is wired

* Image `espressif/idf:v6.1`, pinned by registry digest in `scripts/lib/idf-docker.sh`
  (`XZ_IDF_IMAGE_PIN_DIGEST`). A changed digest produces a warning, not a silent toolchain swap.
  This is the same image upstream CI uses (`.github/workflows/build.yml`). v2.5.2 needs
  ESP-IDF ≥ 6.0.1, so the 5.4 that older guides mention does not work.
* The container runs as your uid/gid. Mounts: the firmware tree → `/project`;
  `cache/idf-home` → `$HOME` (ccache plus the component manager's download cache persist
  there); `scripts/container` → `/xz/container` (read-only).
* Inside, upstream's own entry point runs:
  `python scripts/build.py spotpear/sp-esp32-s3-1.28-box --name sp-esp32-s3-1.28-box`
  (set-target, board Kconfig symbol, sdkconfig defaults, `idf.py build`, `merge-bin`).
* Results are copied to a staging directory and verified by `scripts/py/inspect_build.py`.
  Only a build that passes replaces `out/<board>/<label>/`; a failed one never touches `out/`.
* Every `--set` / `--sdkconfig-append` line is checked against the generated `sdkconfig`, so a
  typo or an unmet Kconfig dependency fails the build instead of producing a stock image.
* One IDF job at a time: `state/build.lock`. Another label wipes `build/` and `sdkconfig` first,
  so labels never share stale configuration.

## What is in `out/<board>/<label>/`

| File | Flash offset | Notes |
|---|---|---|
| `bootloader/bootloader.bin` | `0x0` | second-stage bootloader |
| `partition_table/partition-table.bin` | `0x8000` | v2 16 MB layout (`partitions/v2/16m.csv`) |
| `ota_data_initial.bin` | `0xd000` | makes the bootloader pick `ota_0` |
| `xiaozhi.bin` | `0x20000` | the application (`ota_0`, 3.94 MB slot, ~67 % used) |
| `generated_assets.bin` | `0x800000` | `assets` partition: text font, wake-word models, 21 PNG emoji faces (64×61) |
| `merged-binary.bin` | `0x0` | all of the above in one image; flash it *instead of* the parts |
| `flasher_args.json`, `flash_args` | | offset → file map; `scripts/23-flash-firmware.sh` reads it |
| `sdkconfig`, `dependencies.lock` | | exact configuration and component versions |
| `debug/*.elf`, `debug/*.map` | | not flashed; needed to decode crash backtraces |
| `build-info.txt`, `SHA256SUMS` | | provenance (source commit, image digest, tool versions) and hashes |

## Configuration knobs worth knowing

* **Server URL.** `CONFIG_OTA_URL` in `main/Kconfig.projbuild` (menu *Xiaozhi Assistant →
  Default OTA URL*), default `https://api.tenclass.net/xiaozhi/ota/`. The device asks this URL
  for firmware updates and for the WebSocket/MQTT address of the voice server. For a
  self-hosted [xiaozhi-esp32-server](https://github.com/xinnan-tech/xiaozhi-esp32-server), use
  `--set 'CONFIG_OTA_URL="http://<server-ip>:8002/xiaozhi/ota/"'`. An `ota_url` stored in NVS
  overrides the baked-in one (`scripts/30-analyze-flash-image.sh` reports both).
* **Language.** `config/lang-en-us.sdkconfig` selects `CONFIG_LANGUAGE_EN_US` (on-screen text and
  voice prompts). The stock default is `CONFIG_LANGUAGE_ZH_CN`.
* **Board.** Selected by `scripts/build.py` from `main/boards/spotpear/sp-esp32-s3-1.28-box/config.json`.
  Do not pick it by hand in menuconfig.
* **Exploring options.** `scripts/14-menuconfig.sh` opens menuconfig on the last build's
  configuration in a real terminal. `--delta` turns your changes into `--set` lines.

## Local changes to the firmware

Our changes live in `patches/xz-dev-tools.patch`; `scripts/19-patches.sh status|apply|revert|refresh`
manages it. The patch adds `main/xz_dev.cc` and a Kconfig menu *Local development tools (xz)*.
Everything is off by default, so a build with the patch applied and no `XZ_DEV_*` options set
behaves like stock.

| Option | Effect |
|---|---|
| `CONFIG_XZ_DEV_SERIAL_SCREENSHOT` | Snapshots the LVGL screen as JPEG and prints it base64-encoded on the console (`XZSHOT …`). `scripts/27-screenshot.sh` turns it into image files |
| `CONFIG_XZ_DEV_FACE_DEMO` | While offline, loads the PNG faces from the assets partition and shows one after another (`XZFACE …`). Stock firmware shows them only once online |

`scripts/17-test-screenshot-protocol.sh` tests the screenshot encoder against the host decoder
without hardware. Run it after any change to `xz_dev.cc`.
