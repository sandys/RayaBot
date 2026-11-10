#!/usr/bin/env bash
# 28-face-demo.sh — end to end: flash the face-demo build, boot it, and PROVE it draws faces.
#
# Usage:
#   scripts/28-face-demo.sh                       # flash out/<board>/dev-face-v2.5.2, verify, park
#   scripts/28-face-demo.sh --no-flash            # firmware already on the device: just boot + verify
#   scripts/28-face-demo.sh --leave-running       # do not park at the end: faces stay on screen
#   scripts/28-face-demo.sh --dir out/<board>/<label>
#
# What it does
#   1. scripts/23-flash-firmware.sh --dir <dir>     (per-partition write, NVS kept; skipped with --no-flash)
#   2. scripts/27-screenshot.sh --reset run --count 8 — restarts the app with the port already open,
#      records the console from the ROM banner on, and decodes the screenshots the dev firmware
#      prints into logs/screens/<timestamp>-face-demo-NN.jpg
#   3. checks the captured boot log for evidence, prints PASS/FAIL per item:
#        app        "App version: 2.5.2" and the expected project name
#        panel      GC9A01 panel driver created, LVGL started, backlight set
#        faces      faces loaded from the assets partition, >= 3 different faces shown
#        shots      >= 3 valid screenshots, taken while a face was on screen (face=<name>)
#        health     no panic / abort / Guru Meditation / assert / watchdog / brownout
#   4. parks the chip in the bootloader (scripts/26-park-in-bootloader.sh) unless --leave-running
#
# Why park by default
#   With the factory WiFi credentials still in NVS (SSID "spotpear-test", absent here) the
#   firmware gives up after 60 s and enters WiFi configuration mode, which PLAYS A VOICE PROMPT
#   and starts the "Xiaozhi-XXXX" hotspot. Steps 2-3 finish in about 45 s; parking right after
#   keeps an unattended run silent. --leave-running accepts the prompt (faces keep cycling
#   underneath the configuration hint; an offline device never auto-shuts down).
#
# Judge the screenshots yourself too: they are the frames LVGL rendered. Physical proof that the
# glass is lit is the backlight log line plus a human looking at the device.
#
# Exit status: 0 all checks passed, 1 something failed (details above the verdict).

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local dir="$XZ_ROOT/out/${XZ_BOARD:-sp-esp32-s3-1.28-box}/dev-face-v2.5.2" flash=1 park=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)           [[ $# -ge 2 ]] || die "--dir needs a path"; dir="$2"; shift 2 ;;
      --no-flash)      flash=0; shift ;;
      --leave-running) park=0; shift ;;
      -h|--help) sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done

  if [[ $flash -eq 1 ]]; then
    [[ -f "$dir/flasher_args.json" ]] || die "no build in $dir (scripts/11-build-firmware.sh, see docs/build.md)"
    grep -q '^CONFIG_XZ_DEV_FACE_DEMO=y' "$dir/sdkconfig" 2>/dev/null \
      || die "$dir is not a face-demo build (CONFIG_XZ_DEV_FACE_DEMO=y missing from its sdkconfig)"
    echo "############ 1. flash ############"
    "$XZ_SCRIPTS/23-flash-firmware.sh" --dir "$dir" || die "flashing failed"
  fi

  echo "############ 2. boot + screenshots ############"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local shot_rc=0 shot_out
  shot_out="$(mktemp)"
  "$XZ_SCRIPTS/27-screenshot.sh" --reset run --count 8 --seconds 55 --label face-demo 2>&1 | tee "$shot_out"
  shot_rc=${PIPESTATUS[0]}
  local cap="$XZ_LOGS/serial/latest.log"
  [[ -s "$cap" ]] || die "no console capture"
  # Keep the evidence under a stable name next to the screenshots.
  cp -f "$cap" "$XZ_LOGS/screens/${stamp}-face-demo-console.log"

  if [[ $park -eq 1 ]]; then
    echo "############ 3. park (silence before the 60 s WiFi prompt) ############"
    "$XZ_SCRIPTS/26-park-in-bootloader.sh" || warn "parking failed - the device may speak its WiFi prompt"
  fi

  echo "############ 4. evidence ############"
  local fail=0
  check() {  # check <name> <ok:0|1> <evidence>
    if [[ "$2" -eq 0 ]]; then printf '  PASS  %-7s %s\n' "$1" "$3"; else printf '  FAIL  %-7s %s\n' "$1" "$3"; fail=1; fi
  }
  local v
  v="$(grep -m1 -oE 'App version: +[^ ]+' "$cap" || true)"
  check app "$([[ -n "$v" ]] && echo 0 || echo 1)" "${v:-no 'App version' line}; $(grep -m1 -oE 'Project name: +[^ ]+' "$cap" || echo 'no project line')"

  local p1 p2 p3
  p1="$(grep -c 'LCD panel create success' "$cap" || true)"
  p2="$(grep -c 'Starting LVGL task' "$cap" || true)"
  p3="$(grep -m1 -oE 'Backlight: Set brightness to [0-9]+' "$cap" || true)"
  check panel "$([[ $p1 -ge 1 && $p2 -ge 1 && -n "$p3" ]] && echo 0 || echo 1)" \
    "panel created: $p1, LVGL task: $p2, ${p3:-no backlight line}"

  local loaded nfaces faces
  loaded="$(grep -m1 -oE 'XZFACE loaded [0-9]+ faces from [a-z-]+' "$cap" || true)"
  faces="$(grep -oE 'XZFACE show=[a-z_]+' "$cap" | cut -d= -f2 | awk '!seen[$0]++' | tr '\n' ' ')"
  nfaces="$(wc -w <<<"$faces")"
  check faces "$([[ "$loaded" == *"from assets"* && $nfaces -ge 3 ]] && echo 0 || echo 1)" \
    "${loaded:-no XZFACE loaded line}; shown: ${faces:-none}"

  local shots_ok shots_face
  shots_ok="$(grep -cE '^OK id=' "$shot_out" || true)"
  shots_face="$(grep -oE 'XZSHOT BEGIN .* face=[a-z_]+' "$cap" | grep -vc 'face=-$' || true)"
  check shots "$([[ $shot_rc -eq 0 && $shots_ok -ge 3 && $shots_face -ge 3 ]] && echo 0 || echo 1)" \
    "$shots_ok screenshots decoded with a valid CRC, $shots_face of them taken with a face on screen (exit $shot_rc)"

  local bad
  bad="$(grep -nE 'Guru Meditation|abort\(\)|panic|assert failed|Task watchdog|Brownout|rst:0x(c|f)|E \([0-9]+\) (task_wdt|esp_image|boot)' "$cap" | head -5 || true)"
  check health "$([[ -z "$bad" ]] && echo 0 || echo 1)" "${bad:-no crash, watchdog or brownout markers}"

  echo
  echo "=== screenshots (open them; each is the 240x240 frame LVGL rendered) ==="
  grep -E '^XZSHOT BEGIN' "$cap" | sed -E 's/.*id=([0-9]+).*uptime_ms=([0-9]+).*face=([a-z_-]+).*/  #\1  t=\2 ms  face=\3/'
  grep -oE -- '-> .*\.jpg$' "$shot_out" | sed 's/^-> /  /' || true
  rm -f "$shot_out"
  echo "  console: $XZ_LOGS/screens/${stamp}-face-demo-console.log"
  echo
  if [[ $fail -eq 0 ]]; then
    log "VERDICT: PASS - our build boots, drives the panel and draws the emoji faces"
  else
    log "VERDICT: FAIL - see the FAIL lines above and the console log"
  fi
  return $fail
}

xz_run_logged face-demo main "$@"
