#!/usr/bin/env bash
# 28-dev-demo.sh — end to end: flash a dev demo build (face or name), boot it, and PROVE it draws.
#
# Usage:
#   scripts/28-dev-demo.sh --demo face                  # flash out/<board>/dev-face-v2.5.2, verify, park
#   scripts/28-dev-demo.sh --demo name                  # flash out/<board>/dev-name-v2.5.2, verify, leave it running
#   scripts/28-dev-demo.sh --demo name --no-flash       # firmware already on the device: just boot + verify
#   scripts/28-dev-demo.sh --demo face --leave-running  # do not park at the end
#   scripts/28-dev-demo.sh --demo name --park           # park at the end after all
#   scripts/28-dev-demo.sh --demo name --dir out/<board>/<label>
#   scripts/28-dev-demo.sh --demo name --evidence docs/evidence/name-demo
#                                       # after a PASS, also copy the screenshots and console logs
#                                       # there, every UUID-shaped value (the board UUID) redacted
#
# Demos (patches/xz-dev-tools.patch, main/xz_dev.cc; docs/build.md "Local changes to the firmware")
#   face  CONFIG_XZ_DEV_FACE_DEMO, config/dev-face-demo.sdkconfig: the emoji faces of the assets
#         partition, a new one every 5 s, while offline
#   name  CONFIG_XZ_DEV_NAME_DEMO, config/dev-name-demo.sdkconfig: an animated name while offline.
#         That build never enters WiFi configuration mode on its own, so it stays silent.
#
# What it does
#   1. scripts/23-flash-firmware.sh --dir <dir>   (per-partition write, NVS kept; skipped with --no-flash)
#   2. scripts/27-screenshot.sh --reset run --count 8 — restarts the app with the port already open,
#      records the console from the ROM banner on, and decodes the screenshots the dev firmware
#      prints into logs/screens/<timestamp>-<demo>-demo-NN.jpg
#   3. name only: scripts/25-serial-capture.sh keeps listening, without a reset, until about 72 s
#      after boot, which is past the stock 60 s WiFi timeout
#   4. checks the captured console for evidence, prints PASS/FAIL per item:
#        app      "App version: 2.5.2" and the project name
#        panel    GC9A01 panel driver created, LVGL started, backlight set
#        health   no panic / abort / Guru Meditation / assert / watchdog / brownout
#      face:
#        faces    faces loaded from the assets partition, >= 3 different faces shown
#        shots    >= 3 valid screenshots, taken while a face was on screen (face=<name>)
#      name:
#        name     "XZNAME start" with the build's text, in a font that fits the round panel
#        shots    >= 3 valid screenshots, >= 3 of them different (the picture moves)
#        motion   "XZNAME alive" every 5 s until >= 65 s after boot (lines before the reset's ROM
#                 banner belong to the previous boot and are dropped): steps and uptime keep rising,
#                 the last line shows >= 15 steps per second, fewer than 1 in 10 redraws after the
#                 first heartbeat sent the whole screen (LVGL's 32-area limit, see xz_dev.cc), and
#                 no ROM banner appears (the chip did not restart)
#        quiet    the firmware reports automatic WiFi configuration off and never entered it
#   5. parks the chip in the bootloader (scripts/26-park-in-bootloader.sh). It does this by
#      default after face, whose build speaks a WiFi prompt at 60 s. It does not after name,
#      which is silent, so the name stays on screen. --park and --leave-running override.
#
# Judge the screenshots yourself too: they are the frames LVGL rendered. Physical proof that the
# glass is lit is the backlight log line plus a human looking at the device.
#
# Exit status: 0 all checks passed, 1 something failed (details above the verdict).

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local demo="" dir="" flash=1 park="" evidence=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --demo)          [[ $# -ge 2 ]] || die "--demo needs face or name"; demo="$2"; shift 2 ;;
      --dir)           [[ $# -ge 2 ]] || die "--dir needs a path"; dir="$2"; shift 2 ;;
      --evidence)      [[ $# -ge 2 ]] || die "--evidence needs a directory"; evidence="$2"; shift 2 ;;
      --no-flash)      flash=0; shift ;;
      --park)          park=1; shift ;;
      --leave-running) park=0; shift ;;
      -h|--help) sed -n '2,51p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
  local symbol label seconds
  case "$demo" in
    face) symbol=CONFIG_XZ_DEV_FACE_DEMO; label=dev-face-v2.5.2; seconds=55; park="${park:-1}" ;;
    name) symbol=CONFIG_XZ_DEV_NAME_DEMO; label=dev-name-v2.5.2; seconds=30; park="${park:-0}" ;;
    *) die "say which demo: --demo face or --demo name (try --help)" ;;
  esac
  dir="${dir:-$XZ_ROOT/out/${XZ_BOARD:-sp-esp32-s3-1.28-box}/$label}"

  if [[ $flash -eq 1 ]]; then
    [[ -f "$dir/flasher_args.json" ]] || die "no build in $dir (scripts/11-build-firmware.sh, see docs/build.md)"
    grep -q "^$symbol=y" "$dir/sdkconfig" 2>/dev/null \
      || die "$dir is not a $demo-demo build ($symbol=y missing from its sdkconfig)"
    echo "############ 1. flash ############"
    "$XZ_SCRIPTS/23-flash-firmware.sh" --dir "$dir" || die "flashing failed"
  fi

  echo "############ 2. boot + screenshots ############"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local shot_rc=0 shot_out
  shot_out="$(mktemp)"
  "$XZ_SCRIPTS/27-screenshot.sh" --reset run --count 8 --seconds "$seconds" --label "$demo-demo" 2>&1 | tee "$shot_out"
  shot_rc=${PIPESTATUS[0]}
  [[ -s "$XZ_LOGS/serial/latest.log" ]] || die "no console capture"
  # Keep the evidence under a stable name next to the screenshots, from the first ROM banner on:
  # that is the reset 27 asked for. Anything before it is the previous boot. With --no-flash the
  # app was still running, and its last heartbeat would look like a restart. A later banner (a
  # crash and reboot) stays in. The untrimmed capture remains in logs/serial/.
  local cap="$XZ_LOGS/screens/${stamp}-$demo-demo-console.log" listen=""
  if grep -q 'ESP-ROM:' "$XZ_LOGS/serial/latest.log"; then
    awk '!seen && /ESP-ROM:/ { seen = 1; sub(/^.*ESP-ROM:/, "ESP-ROM:") } seen' "$XZ_LOGS/serial/latest.log" >"$cap"
  else
    cp -f "$XZ_LOGS/serial/latest.log" "$cap"
  fi

  if [[ "$demo" == name ]]; then
    echo "############ 3. keep listening past the stock 60 s WiFi timeout (no reset) ############"
    local up more
    up="$(grep -oE 'uptime_ms=[0-9]+' "$cap" | tail -1 | cut -d= -f2)"
    more=$(( 72 - ${up:-0} / 1000 ))
    (( more < 10 )) && more=10
    listen="$XZ_LOGS/screens/${stamp}-name-demo-listen.log"
    if "$XZ_SCRIPTS/25-serial-capture.sh" --seconds "$more" --label name-demo-listen --quiet; then
      cp -f "$XZ_LOGS/serial/latest.log" "$listen"
    else
      warn "listening failed: the motion and quiet checks will fail"
      : >"$listen"
    fi
  fi

  if [[ $park -eq 1 ]]; then
    echo "############ park ############"
    "$XZ_SCRIPTS/26-park-in-bootloader.sh" || warn "parking failed - a face-demo build may speak its WiFi prompt"
  fi

  echo "############ evidence ############"
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

  local shots_ok
  shots_ok="$(grep -cE '^OK id=' "$shot_out" || true)"
  if [[ "$demo" == face ]]; then
    local loaded nfaces faces shots_face
    loaded="$(grep -m1 -oE 'XZFACE loaded [0-9]+ faces from [a-z-]+' "$cap" || true)"
    faces="$(grep -oE 'XZFACE show=[a-z_]+' "$cap" | cut -d= -f2 | awk '!seen[$0]++' | tr '\n' ' ')"
    nfaces="$(wc -w <<<"$faces")"
    check faces "$([[ "$loaded" == *"from assets"* && $nfaces -ge 3 ]] && echo 0 || echo 1)" \
      "${loaded:-no XZFACE loaded line}; shown: ${faces:-none}"
    shots_face="$(grep -oE 'XZSHOT BEGIN .* face=[a-z_]+' "$cap" | grep -vc 'face=-$' || true)"
    check shots "$([[ $shot_rc -eq 0 && $shots_ok -ge 3 && $shots_face -ge 3 ]] && echo 0 || echo 1)" \
      "$shots_ok screenshots decoded with a valid CRC, $shots_face of them taken with a face on screen (exit $shot_rc)"
  else
    local start want="" name_ok=1
    start="$(grep -m1 -E '^XZNAME start ' "$cap" || true)"
    [[ $flash -eq 1 ]] && want="$(sed -n 's/^CONFIG_XZ_DEV_NAME_TEXT="\(.*\)"$/\1/p' "$dir/sdkconfig")"
    if [[ "$start" == *"fits=yes"* ]] && [[ -z "$want" || "$start" == *"text=\"$want\""* ]]; then name_ok=0; fi
    check name "$name_ok" "$(sed -E 's/^XZNAME start //; s/ uptime_ms=.*//' <<<"${start:-no XZNAME start line}")"

    local jpgs=() ndistinct=0
    mapfile -t jpgs < <(grep -oE -- '-> .*\.jpg$' "$shot_out" | sed 's/^-> //')
    (( ${#jpgs[@]} > 0 )) && ndistinct="$(sha256sum "${jpgs[@]}" | awk '{print $1}' | sort -u | wc -l)"
    check shots "$([[ $shot_rc -eq 0 && $shots_ok -ge 3 && $ndistinct -ge 3 ]] && echo 0 || echo 1)" \
      "$shots_ok screenshots decoded with a valid CRC, $ndistinct different pictures (exit $shot_rc)"

    # Heartbeats from both captures: steps and uptime must rise line by line (a restart resets both).
    # Redraw figures are the last line's. Whole-screen redraws count from the second line on: the
    # first window holds the panel's first draw, which is the whole screen by design.
    local n_alive rising per_s fps draw_ms px full frames last_up restarts
    read -r n_alive rising per_s fps draw_ms px full frames last_up < <(cat "$cap" "$listen" | grep -E '^XZNAME alive ' | awk '
      { delete v; for (i = 3; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] + 0 }
        n++; if (n > 1 && (v["steps"] <= ps || v["uptime_ms"] <= pu)) bad = 1
        if (n > 1) { full += v["full"]; frames += v["fps"] * (v["uptime_ms"] - pu) / 1000 }
        ps = v["steps"]; pu = v["uptime_ms"]; pr = v["per_s"]; f = v["fps"]; d = v["draw_ms"]; p = v["px"] }
      END { printf "%d %d %d %d %.1f %d %d %d %d\n", n, (n >= 2 && !bad), pr, f, d, p, full, frames, pu }')
    restarts="$(grep -cE 'ESP-ROM:|rst:0x' "$listen" || true)"
    check motion "$([[ $rising -eq 1 && $per_s -ge 15 && $frames -gt 0 && $((full * 10)) -lt $frames && $last_up -ge 65000 && $restarts -eq 0 ]] && echo 0 || echo 1)" \
      "$n_alive heartbeats, steps and uptime rising: $([[ $rising -eq 1 ]] && echo yes || echo NO); last: $per_s steps/s, $fps redraws/s, $draw_ms ms and $px px per redraw; whole-screen redraws after the first heartbeat: $full of ~$frames; up to $((last_up / 1000)) s uptime; restarts while listening: $restarts"

    local off entered
    off="$(grep -m1 -oE 'XZ dev: no (automatic WiFi config mode|saved WiFi)[^(]*' "$cap" || true)"
    entered="$(cat "$cap" "$listen" | grep -m2 -E 'entering config mode|WiFi config mode entered' || true)"
    check quiet "$([[ -n "$off" && -z "$entered" ]] && echo 0 || echo 1)" \
      "${off:-no 'XZ dev: no automatic WiFi config mode' line}; ${entered:-never entered WiFi configuration mode (watched to $((last_up / 1000)) s)}"
  fi

  local bad
  bad="$(cat "$cap" "$listen" | grep -nE 'Guru Meditation|abort\(\)|panic|assert failed|Task watchdog|Brownout|rst:0x(c|f)|E \([0-9]+\) (task_wdt|esp_image|boot)' | head -5 || true)"
  check health "$([[ -z "$bad" ]] && echo 0 || echo 1)" "${bad:-no crash, watchdog or brownout markers}"

  echo
  echo "=== screenshots (open them; each is the 240x240 frame LVGL rendered) ==="
  grep -E '^XZSHOT BEGIN' "$cap" | sed -E 's/.*id=([0-9]+).*uptime_ms=([0-9]+).*face=([a-z_-]+).*/  #\1  t=\2 ms  face=\3/'
  local jpgs_out
  jpgs_out="$(grep -oE -- '-> .*\.jpg$' "$shot_out" | sed 's/^-> //' || true)"
  [[ -n "$jpgs_out" ]] && sed 's/^/  /' <<<"$jpgs_out"
  rm -f "$shot_out"
  echo "  console: $cap"
  [[ -n "$listen" ]] && echo "  listen:  $listen"
  [[ $park -eq 0 ]] && echo "  device:  left running (scripts/26-park-in-bootloader.sh parks it)"
  if [[ -n "$evidence" && $fail -ne 0 ]]; then
    warn "evidence not copied to $evidence: the run did not pass"
  elif [[ -n "$evidence" ]]; then
    # The boot log names the board UUID (personal data, CLAUDE.md rule 5): redact anything shaped
    # like one, then refuse to finish if a copy still has one. Screenshots are rendered frames.
    local uuid_re='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' f n=0
    local logs=("$cap") copies=()
    [[ -n "$listen" ]] && logs+=("$listen")
    mkdir -p "$evidence"
    while IFS= read -r f; do
      [[ -n "$f" ]] && cp -f "$f" "$evidence/" && n=$((n + 1))
    done <<<"$jpgs_out"
    for f in "${logs[@]}"; do
      copies+=("$evidence/$(basename "$f")")
      sed -E "s/$uuid_re/<redacted: uuid>/g" "$f" >"${copies[-1]}"
      n=$((n + 1))
    done
    if grep -qE "$uuid_re" "${copies[@]}"; then
      fail=1
      echo "  FAIL  evidence  a UUID-shaped value survived in $evidence - remove those copies before committing"
    else
      echo "  evidence: $n files in $evidence (UUID redacted); scripts/90-check-secrets.sh checks them once staged"
    fi
  fi
  echo
  if [[ $fail -eq 0 ]]; then
    log "VERDICT: PASS - our $demo-demo build boots, drives the panel and draws what it should"
  else
    log "VERDICT: FAIL - see the FAIL lines above and the console log"
  fi
  return $fail
}

xz_run_logged dev-demo main "$@"
