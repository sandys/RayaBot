# Spotpear ESP32-S3-1.28-BOX: board dossier

Board id `sp-esp32-s3-1.28-box`, xiaozhi firmware v2.5.2. Compiled 2026-11-10 from read-only research. Nothing was built and the device was not touched.

**How references work**
- Source paths are relative to `firmware/xiaozhi-esp32/` at tag `v2.5.2`, commit `49b4380b3faa0ceadd28a3e78aaf0f311c46c57e`.
- `BOX/` is short for `main/boards/spotpear/sp-esp32-s3-1.28-box/`.
- "(inference)" marks anything reasoned rather than read.
- "(coordinator)" marks facts the coordinating session established and handed to me. I did not re-derive those, except where a note says so.

> **Review note (coordinator, 2026-11-10 07:05).** I re-checked these claims in the source, and
> they hold:
> - `"gear"` is in neither icon table, and `SetEmotion` changes nothing when a lookup fails. So in
>   config mode the robot icon stays (in the dev build, the current face stays).
> - Auto-upgrade happens at boot (`application.cc:493-498`).
> - BOOT pressed while Starting enters config mode (`sp-esp32-s3-1.28-box.cc:373-377`).
> - GPIO41 is read with the internal pull-up, and high means "charging" (`power_manager.h:31,123`).
> - The sleep checkbox is shown (`wifi_board.cc:60`).
> - The hotspot SSID is `Xiaozhi-` plus the last two bytes of the softAP MAC
>   (`managed_components/78__esp-wifi-connect/wifi_configuration_ap.cc:115-128`). With 4 universal
>   MACs the softAP MAC is the chip MAC + 1, so the expected SSID is `Xiaozhi-9D71`.
> - Both ESPHome repos and the forum thread are live.
>
> Q1 item 6 ("face at boot with no network") is superseded. The dev face demo does it and was
> verified on the device; see `patches/xz-dev-tools.patch` and the README section "Getting a face
> on the screen".
>
> Still unverified: everything that depends on this unit matching the schematic (GPIO41/GPIO3
> wiring) and the power button's behaviour.

## Answer for tonight (overnight on USB)

**The board will stay on all night on USB.** It will not dim or shut itself down, whether it is offline or online. The online part is an inference: it relies on the schematic matching this unit.

- **Offline** (Starting, WifiConfiguring or Activating): the timer cannot dim or shut down whatever GPIO41 reads.
  - `CanEnterSleepMode()` is false unless the state is Idle (`main/application.cc:1300-1303`).
  - `PowerSaveCheck()` resets its tick count whenever that is false (`main/boards/common/power_save_timer.cc:62-67`).
  - (coordinator; I confirmed it in the source.)
- **Online and idle**: only the raw level of GPIO41 switches the timer, and 1 means off.
  - The factory boot log on USB proves GPIO41 read 1 at boot.
  - In the schematic nothing drives GPIO41. It goes only to test pad P14, and the firmware turns on the internal pull-up.
  - It should therefore read 1 permanently: with the battery full, charging or missing, and on battery alone (inference).
- **Battery level does not touch the timer.** "Full" only changes the status-bar icon.
- **To make it certain**, use either of these:
  - Untick "Enable Sleep Mode" on the WiFi-config page's Advanced tab. This writes NVS `wifi/sleep_mode=0`.
  - Build with `PowerSaveTimer(-1, 60, -1)`.

  Details are in Q2.

## What I am sure of / what I am not

**Sure** (read directly in source, documentation or schematic):
1. **Offline: no dim and no shutdown.** Covered under "Answer for tonight" above.
2. **Only the GPIO41 level enables or disables the timer.**
   - It reads 1 as "charging", which switches the timer off.
   - Path: `BOX/power_manager.h:31-36,118-124,138` → callback `BOX/sp-esp32-s3-1.28-box.cc:179-185`.
   - The second path, `GetBatteryLevel`, uses the same pin: `BOX/sp-esp32-s3-1.28-box.cc:472-478` with `BOX/power_manager.h:172-175`.
   - Battery level 100 only changes `IsCharging()` (`BOX/power_manager.h:164-170`), which drives the status-bar icon (`main/display/lvgl_display/lvgl_display.cc:242-260`). It never reaches the timer.
3. **The factory boot log fits GPIO41 = 1.** The log (coordinator) shows "Power save timer enabled" and then "disabled" 100 ms later.
   - The timer is enabled at `BOX/sp-esp32-s3-1.28-box.cc:174`.
   - The PowerManager's first 100 ms poll reads GPIO41 = 1 (`BOX/power_manager.h:138,31`), and the callback disables the timer.
4. **Schematic** (`ESP32S3-1.28inch-BOX.pdf`, dated 5/16/2025, sha256 `f6fe07d6361f77ecc092f0af30f8f5c6e67780a33bf4cc55875f680c486c9297`):
   - GP41 goes only to test pad P14.
   - GP3 goes only to test pad P9.
   - The PL4054 CHRG pin drives only LED L6.
   - The power latch (SAM8108 with button K1) has no connection to the MCU.
5. **A shutdown cannot be woken from software.** Nothing on this board's code path configures a deep-sleep wake source.
   - `esp_sleep_enable_*` appears nowhere in `BOX/`, `main/boards/common/power_save_timer.cc`, `main/*.cc` or `main/display/`.
   - It does appear in other boards and in `main/boards/common/sleep_timer.cc:98`, but this board does not include `sleep_timer.h` (`BOX/sp-esp32-s3-1.28-box.cc:1-28`).
   - In deep sleep the USB-Serial/JTAG port disappears from the PC (ESP-IDF v6.1 `docs/en/api-guides/usb-serial-jtag-console.rst` L83, L104-107).
6. **The sleep-mode switch is user-visible.** The config portal shows the toggle for this firmware (`main/boards/common/wifi_board.cc:60`), and the timer obeys it (`power_save_timer.cc:32-36`).
7. **Pin map.** `BOX/config.h` matches the vendor wiki pin table, the schematic and both community ESPHome configs, with two exceptions: GPIO41 (charge detect) and GPIO3 (power hold), which have no circuit.

**Not sure:**
1. Whether this unit matches the 5/16/2025 schematic. The online-on-USB answer depends on GPIO41 really being unconnected. The cheap checks are in Q2.
2. What the power button does. I found no SAM8108 datasheet, so I don't know short-press versus long-press behaviour. That affects how to recover from a deep-sleep "shutdown".
3. I found no PL4054 datasheet. The TP4054, a part from the same 4054 family, is used as a stand-in.
4. The config-mode screen.
   - The coordinator's note says it shows a "gear icon".
   - The source says the name "gear" is in neither icon table, so the robot icon stays (inference, Q1).
5. AliExpress pages were not fetched: they redirect to login.aliexpress.com.
6. Whether the official server would push an OTA over a dev build. The device checks only at boot, and auto-upgrades when the server offers a newer version (Q5).

---

## Q1. What the screen shows (brief; mostly coordinator-established)

1. **Boot.** `SetupUI` builds a centred emoji label showing the 30 px Material Symbols robot icon `MATERIAL_SYMBOLS_ROBOT_2` (`main/display/lcd_display.cc:893`), not a face. The status line reads "Initializing" (`lcd_display.cc:976`).
2. **Offline with stored credentials.** The factory NVS holds a vendor test-AP SSID, `spotpear-test` (coordinator, from the factory dump).
   - The device scans, then after `CONNECT_TIMEOUT_SEC = 60` (`main/boards/common/wifi_board.cc:27,162-167`) enters config mode.
   - `StartWifiConfigMode` (`wifi_board.cc:170-190`) calls `Alert(WIFI_CONFIG_MODE, <hotspot + URL hint>, "gear", OGG_WIFICONFIG)`. That gives the status text, a hint naming the hotspot SSID and `http://192.168.4.1`, and a voice prompt.
   - With no saved credentials, config mode starts after about 1.5 s (`wifi_board.cc:100-115`).
3. **The icon in config mode is still the robot (inference).**
   - `"gear"` is in neither name table of xiaozhi-fonts 2.0.0: `managed_components/78__xiaozhi-fonts/src/noto_emoji.c` and `.../src/material_symbols.c`. By contrast, `"robot_2"` is at material_symbols.c:55 and `"link"` at :60.
   - `LcdDisplay::SetEmotion` changes the label only when a lookup succeeds (`lcd_display.cc:1149-1168`).
4. **Once the network is up,** `ActivationTask` → `CheckAssetsVersion` → `assets.Apply()` loads the 21 colour PNG faces, 64×61, from the `assets` partition (`main/application.cc:370,437`; selected in `main/CMakeLists.txt:808-812`).
   - Before that, `SetEmotion` falls back to the 21-glyph monochrome `font_noto_emoji_30_4` (`lcd_display.cc:26,1151`).
   - An activation code appears with the "link" icon (`application.cc:741`).
5. **The first face** is `neutral` in the Idle state (`application.cc:1016`).
6. **Face at boot with no network.** These are proposals I have not tested; patch upstream only via a patch file.
   - Board-only: call `SetEmotion("neutral")` after `SpiLcdDisplay::SetupUI()` in `BOX/sp-esp32-s3-1.28-box.cc:122-130`, outside the lock scope. Whether the LVGL lock is recursive is unverified.
   - Core: change `"gear"` to `"neutral"` at `wifi_board.cc:186`.

## Q2. Power, sleep and shutdown

### Code path (all read in v2.5.2)

| Step | Where | What |
|---|---|---|
| 1 | `BOX/sp-esp32-s3-1.28-box.cc:146-149` | GPIO3 is set up as an RTC output and driven high ("power hold"). |
| 2 | `...cc:151` | `new PowerSaveTimer(-1, 60, 290)`: no CPU frequency change, dim after 60 s, shut down after 290 s. |
| 3 | `...cc:152-155` | Sleep callback: `SetPowerSaveMode(true)` (sleepy face) and backlight at 1. |
| 4 | `...cc:160-173` | Shutdown callback: "Shutting down", codec in/out off, GPIO3 low with hold, panel off, `esp_deep_sleep_start()`. |
| 5 | `...cc:174`; `power_save_timer.cc:30-41` | `SetEnabled(true)` at boot. It first checks NVS `wifi/sleep_mode`, default true (L32-36), then logs "Power save timer enabled" (L41). |
| 6 | `...cc:402-403` | The PowerManager is created after the timer. |
| 7 | `BOX/power_manager.h:118-124,138,31` | GPIO41 is an input with the internal pull-up enabled, polled every 100 ms. `charging = (level == 1)`. |
| 8 | `power_manager.h:32-36`; `...cc:179-185` | On a change, charging calls `SetEnabled(false)` ("Power save timer disabled", `power_save_timer.cc:42-46`), and not charging calls `SetEnabled(true)`. |
| 9 | `...cc:464-478`; `power_manager.h:172-175` | Second path: the status-bar refresh (`lvgl_display.cc:242`) calls `GetBatteryLevel`, which calls `SetEnabled(discharging)`. `discharging = !is_charging_`, the same pin. |
| 10 | `power_manager.h:164-170`; `lvgl_display.cc:243-259` | `IsCharging()` returns false at battery level 100. It is used only to pick the bolt or level icon, not for the timer. |
| 11 | `power_save_timer.cc:62-67` | Each 1 s tick resets unless `CanEnterSleepMode()`: Idle, no open audio channel, and audio idle (`application.cc:1300-1315`). |
| 12 | `power_save_timer.cc:70-76,101-103` | At 60 ticks: "Enabling power save mode". At 290 ticks: the shutdown callback. `cpu_max_freq = -1`, so there is no light sleep and no PM change (L78). |
| 13 | no `esp_sleep_enable_*` in `BOX/`, `power_save_timer.cc`, `main/*.cc` or `main/display/` (only in other boards and the unused `common/sleep_timer.cc:98`) | No wake source. A shutdown is terminal until power is cut. |

### Hardware: what drives GPIO41 and GPIO3

Source: the Spotpear schematic <https://cdn.static.spotpear.com/uploads/picture/learn/ESP32/ESP32-S3-LCD-1.28-BOX-THIN/ESP32S3-1.28inch-BOX.pdf>. The `.cn` mirror is byte-identical (same sha256 as above). I rendered and read it.

- **Charger PL1 (PL4054)**
  - Pin 1 (CHRG, active-low) → LED L6 → 470 Ω (CM-R1) → USB VCC.
  - Pin 3 (BAT) → V_BAT and BAT1. Pin 4 (VCC) → USB VCC. Pin 5 (PROG) → R26 1 kΩ → GND.
  - **CHRG has no net to the ESP32.**
- **GP41 → test pad P14 ("Header 1") only.** GP3 → test pad P9 only. P5 carries V_BAT, GP40 (TXD_4G), GP39 (RXD_4G) and GND. P10 and P11 are U0RXD and U0TXD.
- **Power path**
  - USB VCC → D1 (DSK24) → common node.
  - V_BAT → LC-Q2 (APM2307 P-FET) → the same node. Q2's gate comes from USB VCC via R11 1 kΩ / R12 100 kΩ, so Q2 is off while USB is present.
  - Node → U4 SAM8108 VDD, and node → LC-Q1 (APM2307) → `VCC_IN`.
  - Q1's gate is `Power_EN`, the SAM8108 OUT pin, with R10 100 kΩ pull-up. K1 connects SAM8108 ON/OFF to GND.
  - `Power_EN` appears only inside this block, so **the MCU cannot switch its own power off. GPIO3 low therefore does nothing to the supply** (inference).
  - K1 gates USB power too. This matches the vendor download procedure, where the device starts "off while connected by USB" (Q4).

**What GPIO41 reads (inference from the schematic and the source):**

| Case | GPIO41 | Timer |
|---|---|---|
| USB, battery full | 1 | off |
| USB, battery charging | 1 | off |
| USB, no battery | 1 | off |
| Battery only | 1 | off |

In every case the internal pull-up is the only thing driving the pin. The factory log (1 at boot on USB) agrees.

### Charger datasheet (only matters if some unit wires GPIO41 to CHRG)

- I found no PL4054 datasheet; the search turned up only other 4054-family parts.
- Stand-in: the TP4054 datasheet, <https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/6128/TP4054-5272.pdf> (text extracted locally with Ghostscript):
  - "CHRG (pin 1): open drain state output. When charging, the CHRG port is placed at low potential … When the charging is completed, the CHRG shows a high resistance state."
  - "When the battery is not connected to the charger, the CHRG output pulse signal … the CHRG flicker cycle is about 0.5-2 seconds."
  - Recharge hysteresis is 100-200 mV.
- **If GPIO41 were wired to CHRG (inference).** The firmware's "1 = charging" logic would then be inverted:
  - Actively charging: reads 0, so the timer is on and an online idle device could dim at 60 s and deep-sleep at 290 s.
  - Full battery: reads 1, so the timer is off.
  - Recharge cycle: reads 0 again, so the timer is on.
  - No battery: the 0.5-2 s pulses toggle the timer on and off. Each disable calls `WakeUp()`, which zeroes the ticks, so 290 s is never reached.
  - A single "1 at boot" log line does not by itself rule this wiring out: the battery could simply have been full.

### Cheap checks (no opening the case)

- **Console:** after boot there should be exactly one "PowerSaveTimer: Power save timer enabled" followed by "... disabled". Any later "enabled" line means GPIO41 went low.
- **Screen:** unplug USB with a battery fitted that is not full. If the charging-bolt icon stays, GPIO41 is not following the charger. Code: `lvgl_display.cc:243-244`; `power_manager.h:164-170`. At ADC ≥ 2480 the level is 100 and the icon shows "full" either way (`power_manager.h:79,87-88`).

### Turning sleep off for certain

1. **No code: the WiFi-config page, Advanced tab, "Enable Sleep Mode" checkbox.**
   - **The board requests it:** `wifi_board.cc:59-60` sets `config.show_sleep_config = true`.
   - **The component** is esp-wifi-connect 3.3.1 (`main/idf_component.yml:27`, `78/esp-wifi-connect: ~3.3.1`; copy at `managed_components/78__esp-wifi-connect/`).
   - **Page:** `assets/wifi_configuration.html`.
     - :511 is the Advanced tab.
     - :588-593 is the checkbox row, hidden by default.
     - :1739 shows the row when `show_sleep_config` is set.
     - :1749-1750 pre-fills the checkbox.
     - :1668 submits the value.
   - **Server side:** `wifi_configuration_ap.cc`.
     - :182 opens NVS namespace `wifi`.
     - :211-216 reads `sleep_mode` (u8, default true).
     - :532-534 sends it to the page.
     - :597 and :641-646 save it with `nvs_set_u8(nvs, "sleep_mode", …)`.
     - :665-666 logs "Saved settings: … sleep_mode=%d".
   - **Consumer:** `power_save_timer.cc:32-36`, which uses `Settings::GetBool` → `nvs_get_u8` (`main/settings.cc:70-78`) and logs "Power save timer is disabled by settings".
   - **Coverage:** the check runs on every enable attempt (boot, the charging callback and the `GetBatteryLevel` path), so it blocks both the dim and the shutdown.
   - **Takes effect** at the next boot (inference).
   - **Lost** if a full image is written at 0x0, because the merged binaries carry an erased NVS (Q5).
   - **Reaching config mode:**
     - automatically with no saved credentials, or after the 60 s failed connect;
     - manually by clicking BOOT (`BOX/sp-esp32-s3-1.28-box.cc:373-377`) or tapping the screen (`...cc:251-252`) while the state is Starting.

     Then join the open AP `Xiaozhi-XXXX` and open `http://192.168.4.1`.
2. **Dev build:**
   - `BOX/sp-esp32-s3-1.28-box.cc:151` → `PowerSaveTimer(-1, 60, -1)` disables shutdown, because `power_save_timer.cc:101` checks `!= -1`.
   - `(-1, -1, -1)` also disables the dim.

### If it does shut down (inference)

- **State:** the ESP32 is in deep sleep with the panel off and the USB port gone, and no wake source exists.
- **Recovery:** cut `VCC_IN` with K1 (the power button), then press it again for a cold boot.
- **Unplugging USB does not help with a battery fitted,** because LC-Q2 takes over.
- **No reset button:** CHIP_EN has only an RC network (R100/C100).

### Side effect on battery (inference)

If GPIO41 floats, the timer never runs on battery either, so there is no auto-dim and no auto-shutdown. The low-battery popup also never shows, because `discharging` is always false (`lvgl_display.cc:270`). The battery can run flat.

## Q3. What the logs show (brief)

- **Where logs appear.** The console defaults are not overridden (`sdkconfig.defaults*`; `BOX/config.json` has an empty `sdkconfig_append`).
  - In ESP-IDF v6.1 (`components/esp_stdio/Kconfig`), the primary console is UART0 (L2-4) and the secondary is USB-Serial/JTAG (L35-38), which is output-only.
  - Bootloader logs are off (`sdkconfig.defaults:6`).
- **Display up.**
  - The board logs "Init GC9A01 display", "Install panel IO" and "Install GC9A01 panel driver" (`BOX/sp-esp32-s3-1.28-box.cc:319-334`).
  - Touch logs either "Get chip ID" or "CST816D not found, running in non-touch mode" (`...cc:294`).
  - The display layer logs "Initialize LVGL library" and "Adding LCD display" (`lcd_display.cc:111-172`).
- **Assets.**
  - "The assets map size is …" and the checksum lines come from `main/assets.cc:186-210`.
  - "Refreshing display theme..." means `Apply` ran (`assets.cc:415`).
  - "Emoji not found: robot_2" means the PNG collection is active (`emoji_collection.cc:17`).
- **State.**
  - State changes log "StateMachine: State: a -> b" (`device_state_machine.cc:130`).
  - Alerts log "Application: Alert [%s] %s: %s" (`application.cc:754`).
- **Config mode.**
  - Lines in order: "State: starting -> wifi_configuring", "WifiManager: Starting config AP", "WifiConfigurationAp: Access Point started with SSID …", "Web server started".
  - The SSID is `Xiaozhi-%02X%02X` built from softAP MAC bytes 4-5. It is likely `Xiaozhi-9D71` (inference from the device MAC).
- **Power.** "PowerSaveTimer: Power save timer enabled/disabled", "Enabling/Exiting power save mode", "Shutting down", and "PowerManager: ADC value: … level: …" (`power_manager.h:111`).

## Q4. Vendor documentation and hardware

### Pages

All were fetched with curl, except AliExpress (login redirect, not fetched).

- **Product pages**
  - <https://spotpear.com/shop/ESP32-S3-N16R8-AI-DeepSeek-XiaoZhi-XiaGe-Qwen-DouBao-1.28-inch-LCD.html>: "legs" ball, SKU 021004900000.
  - <https://spotpear.com/shop/ESP32-S3-N16R8-AI-DeepSeek-XiaoZhi-XiaGe-Qwen-DouBao-1.28-inch-Round-LCD-BOX-TouchScreen.html>: BOX-THIN, SKU 020805100000.
  - The `.cn` mirrors are linked from `BOX/README.md:5-6`.
- **Wikis:** <https://spotpear.com/wiki/ESP32-S3-N16R8-AI-DeepSeek-XiaoZhi-XiaGe-Qwen-DouBao-1.28-inch-Round-LCD-BOX-TouchScreen.html>, and the same path on spotpear.cn.

### Buttons and power, quoted from the wiki

- **Legs ball:** "1: Power Control / 2: Wake up/interrupt/Boot update / 3: SD / 4: USB port: charging/firmware update/power supply / 5 speaker / 6 display / 7 mic". The CN text adds 配网模式 (network-config mode) to button 2.
- **BOX-THIN:** "1: Power button / 2: boot (wake/interrupt/firmware download) / 3: SD slot / 4: hook / 5: USB interface (Charging/Firmware Update/Power Supply) / 6: display".
- **Download mode** (CN wiki only): 首先不开机，通过USB线连接电脑。按按键2不松手。再按按键1开机，此时显示屏亮背光但是黑屏不显示则说明设备正常进入固件下载模式.
  - In English: with the device off and on USB, hold button 2, then press button 1. A lit backlight with a black screen means download mode.
  - This implies K1 gates USB power, consistent with the schematic.
- **Power-off procedure:** not documented on the pages fetched. The SAM8108 press semantics are unknown.
- **In v2.5.2 the BOOT button** toggles chat. In the Starting state it enters WiFi config instead (`BOX/sp-esp32-s3-1.28-box.cc:373-380`). Touch behaves the same way (`...cc:251-255`).
- **The vendor's own wallpaper firmware** uses button 2 differently: one click, two clicks, or a 3 s press (wiki). That does not apply to xiaozhi.
- **Old "legs" wiki warning:** "turn off OTA upgrades … later device updates may cause the device screen to go black".

### BOM from the schematic

- ESP32-S3R8 with W25Q128 flash.
- ES8311 codec (I2C SCL GP14 / SDA GP15).
- NS4150B amplifier (CTRL GP46).
- Two AOS3729A-T42 microphones.
- PL4054 charger.
- SAM8108 and K1 (power).
- Two APM2307 P-FETs and a DSK24 diode.
- ME6217C33 LDO.
- WS2812B on GP48.
- microSD.
- VBAT 100k/100k divider to GP1.
- GC9A01A display and CST816D touch (datasheets linked from the wiki).

### Pin comparison

| Function | `BOX/config.h` | Wiki table | Schematic | ESPHome Ball_v2 |
|---|---|---|---|---|
| LCD SCLK / MOSI / CS / DC / RST | 4 / 2 / 5 / 47 / 38 (L39-43) | same | same | same |
| Backlight | 42, inverted (L36-37) | 42 | 42, P-FET active-low | 42, inverted |
| Touch SDA / SCL / RST / INT | 11 / 7 / 6 / 12 (L45-48) | same | same | same |
| Codec I2C SDA / SCL | 15 / 14 (L18-19) | n/a | same | same |
| I2S MCLK / BCLK / WS / DIN / DOUT | 16 / 9 / 45 / 10 / 8 (L11-15) | n/a | same | same |
| PA enable | 46 (L17) | n/a | NS4150B CTRL 46 | 46 |
| LED / BOOT | 48 / 0 (L22-23) | n/a | same | same |
| Battery ADC | GPIO1 (L53; ADC1 ch0, `...cc:178`) | n/a | VBAT divider to GP1 | 1 |
| **Charge detect** | **GPIO41 (L54)** | n/a | **test pad P14 only** | not used |
| **Power hold** | **GPIO3 (`...cc:147-149,168-170`)** | n/a | **test pad P9 only** | not used |
| SD D3 / CMD / CLK / D0 | not defined | 13 / 18 / 17 / 21 | microSD | n/a |

**Mismatches:**
- GPIO41 and GPIO3 have no circuit in the schematic.
- `config.h:4` says "Movecall Moji configuration", a copy-paste leftover.
- The SD pins are absent from `config.h`.

An older wiki pin table (DC10 CS13 SCLK14 MOSI17 RST18 BL3) belongs to the earlier "Ball V1" hardware, not this board.

## Q5. Prebuilt images (brief)

- **Official release:** <https://github.com/78/xiaozhi-esp32/releases/tag/v2.5.2>, asset `v2.5.2_spotpear-sp-esp32-s3-1.28-box.zip`.
  - Size 2,536,926 B, sha256 `27040b9cf379f528ba092600820fa453f5eb14abf04e78d7fe15f8f2c1782c36` (matches SHA256SUMS).
  - It contains `merged-binary.bin` (9,651,265 B): zh-CN, IDF v6.1, assets with the 64 px faces.
  - Its NVS and otadata regions are erased, so writing it at 0x0 wipes the saved WiFi and `sleep_mode` (inference).
  - Flash command: `esptool.py -b 460800 write_flash -z 0x0 merged-binary.bin` (<https://xiaozhi.dev/en/docs/usage/firmware-download/>).
- **Spotpear images:**
  - `https://cdn.static.spotpear.com/uploads/picture/learn/ESP32/ESP32-AI/1.28-BOX-EN-ON-OTA-V5.bin`: app 2.4.2, IDF 5.5.4, English.
  - `1.28-BOX-EN-OFF-OTA-V4.7.bin`: app 2.0.5, three-in-one, with a wallpaper partition.
  - Both are written at 0x0 with flash_download_tool 3.9.3, using the settings given on the wiki.
- **Owner's factory dump** (`backups/`, private): app 2.1.0, English, wake word "hiesp", 32×32 emoji. Its NVS already holds WiFi and server keys; I read the key names only.
- **Build:**
  - Command: `python3 scripts/build.py spotpear/sp-esp32-s3-1.28-box --name sp-esp32-s3-1.28-box [--language en-US]`.
  - Version string: `PROJECT_VER` is "2.5.2" (`CMakeLists.txt:12`).
  - OTA risk: `CheckNewVersion` auto-upgrades at boot whenever the server offers a newer version (`application.cc:493-498`).

## Q6. ESPHome configs, including the Dexcom glucose monitor

- **Dexcom (G7) monitor and alarm**
  - Repo: <https://github.com/rilucca/xiaozhi-spotpear-diabetes>, formerly `xiaozhi-specball-v2-diabetes-monitor-alarm`.
  - File: `ball-v2-4mario.yaml`, HEAD `0f3c96683e`. Pin substitutions are at L33-57; Dexcom credentials come from `secrets.yaml` (L72-73).
  - Home Assistant forum post (rilucca, 2026-02-18): <https://community.home-assistant.io/t/project-xiaozhi-specball-v2-esp32-s3-as-a-desktop-diabetes-monitor-voice-assistant/988264>.
- **The base it derives from**
  - <https://github.com/RealDeco/xiaozhi-esphome>, file `devices/Spotpear Balls/Ball_v2.yaml`, commit `897bde7871` (2026-02-23). Pin substitutions are at L36-60.
- **Thread linked from the Spotpear wiki:** <https://community.home-assistant.io/t/spotpear-deepseek-voice-chat-config/877927>. Its first post uses the V1 pinout, so it is not this board.
- **Pins in both yaml files:**
  - I2C A 15/14 and B 11/7.
  - I2S LRCLK 45, BCLK 9, MCLK 16, DIN 10, DOUT 8.
  - Speaker enable 46; touch INT 12 / RST 6 (cst816).
  - Backlight 42 inverted; LCD CS 5, DC 47, RST 38; SPI CLK 4, MOSI 2.
  - Button 0, WS2812 on 48, battery ADC 1.

  These match `config.h`. Neither file uses GPIO3 or GPIO41.

## Could not determine or fetch

- **AliExpress listing:** 302 to login.aliexpress.com, not fetched.
- **Datasheets:** none found for SAM8108 or PL4054.
- **This unit's hardware revision:** whether GPIO41 or GPIO3 is wired differently from the schematic, and whether touch is fitted.
- **Power button:** how K1 behaves (press timing, and whether it restarts the board from deep sleep).
- **OTA:** whether the server would push one to a dev build.
- **LVGL lock:** whether it is recursive (relevant to the board-only face patch).
- **Exact AP SSID:** only inferred.
