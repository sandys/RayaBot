---
name: xiaozhi-firmware-build
description: Build xiaozhi-esp32 firmware for the Spotpear sp-esp32-s3-1.28-box board inside the pinned ESP-IDF docker image. Covers sdkconfig overrides (English UI, OTA or self-hosted server URL, any CONFIG_ option), the local dev patch (face demo, serial screenshots), labelled verified outputs in out/, and patch maintenance. Use when asked to build or rebuild firmware, change its configuration or menuconfig options, update the firmware source, or edit the dev patch.
---

# xiaozhi firmware build

## Context & Purpose

- **Source:** `firmware/xiaozhi-esp32`, upstream 78/xiaozhi-esp32. Tag v2.5.2 needs ESP-IDF ≥ 6.0.1.
- **Builds run only in docker:** `espressif/idf:v6.1`, pinned by digest in `scripts/lib/idf-docker.sh`. The host has no ESP-IDF; never install one.
- **Our firmware changes** live only in `patches/*.patch`, managed by `scripts/19-patches.sh`.
- **Configuration** is sdkconfig lines only, from `config/*.sdkconfig` or `--set`. `build.py` regenerates sdkconfig on every build, so hand edits and saved menuconfig changes are lost.
- **Output:** `out/<board>/<label>/`
  - `flasher_args.json`, `merged-binary.bin`
  - `build-info.txt`, `SHA256SUMS`
  - `debug/` ELF
  - `source.diff` when the tree is modified
- More detail: `docs/build.md`.

## Step-by-Step Workflow

1. **Check the source:** run `scripts/10-fetch-firmware-source.sh --info`. Change refs only on purpose, with `--ref TAG`; the script refuses when the tree is modified.
2. **Check the build image:** run `scripts/13-idf-image.sh`. If the image is missing, tell the user it is several GB, then run `scripts/13-idf-image.sh --pull`.
3. **Set the tree state** and confirm it with `scripts/19-patches.sh status`:
   - **stock:** `scripts/19-patches.sh revert`
   - **dev** (face and name demos, screenshots): `scripts/19-patches.sh apply`
4. **Build with a label that names the configuration:**
   - stock: `scripts/11-build-firmware.sh` (label `stock-v2.5.2`)
   - English UI: `scripts/11-build-firmware.sh --label en-v2.5.2 --sdkconfig-append config/lang-en-us.sdkconfig`
   - dev face demo: `scripts/11-build-firmware.sh --label dev-face-v2.5.2 --sdkconfig-append config/lang-en-us.sdkconfig --sdkconfig-append config/dev-face-demo.sdkconfig`
   - dev name demo (animated name, silent offline): `scripts/11-build-firmware.sh --label dev-name-v2.5.2 --sdkconfig-append config/lang-en-us.sdkconfig --sdkconfig-append config/dev-name-demo.sdkconfig`. Another name: `--set 'CONFIG_XZ_DEV_NAME_TEXT="NAME"'` with its own label.
   - own server: add `--set 'CONFIG_OTA_URL="http://SERVER-IP:8002/xiaozhi/ota/"'`. String values keep their quotes.
5. **Read the end of the build output.** Expect `OK - all expected files are present, fit their regions and are internally consistent` and `N/N files match`. Measured times:
   - first build: about 8 min
   - incremental: about 1.5–2.5 min
   - label switch: a full rebuild with ccache
6. **Re-verify later** with `scripts/12-inspect-build.sh --label LABEL`.
7. **To change the dev patch:**
   1. `apply`
   2. Edit under `firmware/xiaozhi-esp32/main/`.
   3. `scripts/19-patches.sh refresh`
   4. `scripts/17-test-screenshot-protocol.sh`, if `xz_dev.cc` changed.
   5. `revert` then `apply`, to prove the patch round-trips.
   6. Rebuild.
8. **To find a new option:** build first, then let the user run `scripts/14-menuconfig.sh`, or run `scripts/14-menuconfig.sh --delta` yourself. Save the lines it prints as `config/NAME.sdkconfig`.

## Decision Points & Branching Logic

**Script refusals and failures**
- **"image missing":** run `scripts/13-idf-image.sh --pull` after telling the user about the size.
- **A `--set` line "did not take effect":**
  - The symbol name is wrong, or a dependency is unmet.
  - Search the Kconfig files or menuconfig `/` and add the dependency lines.
  - Never patch sdkconfig by hand.
- **Label starts with `stock-` but the tree is modified:** revert the patches, or pick a non-stock label.
- **Patch no longer applies after an upstream update:** check `scripts/19-patches.sh status`. Port the change, then `refresh` and re-test.
- **The build reports changes to the upstream tree, or foreign file ownership:** stop and investigate. The script fails on purpose.
- **Compile error in our code (`main/xz_dev.cc`):** fix it, `refresh`, and run 17 (no hardware, seconds) before the next full build.

**Design rules for firmware changes**
- New behaviour goes behind a Kconfig option in the dev patch, off by default.
- Never edit generated files.
- Core code must not depend on one board's config (upstream AGENTS.md).

**Approaches to avoid**
- ESP-IDF 5.x guides: they do not fit xiaozhi v2.x.
- Installing toolchains on the host.
- Editing `build/` or `sdkconfig` directly.

## Quality Criteria & Completion Checks

- 11 exits 0 with the OK line, and every `--set` or `--sdkconfig-append` line is verified present (11 enforces this).
- `build-info.txt` records the source ref and commit, the ESP-IDF version and the image digest. A modified tree also produces `source.diff`.
- `scripts/19-patches.sh status` matches the intent: stock means not applied.
- Notable timings or failures are added to the README findings log and CHANGES.md.
