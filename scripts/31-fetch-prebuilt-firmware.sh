#!/usr/bin/env bash
# 31-fetch-prebuilt-firmware.sh — download the official prebuilt xiaozhi firmware for one board.
#
# Usage:
#   scripts/31-fetch-prebuilt-firmware.sh                          # v2.5.2 for sp-esp32-s3-1.28-box
#   scripts/31-fetch-prebuilt-firmware.sh --board NAME             # another board (its build name, see --list)
#   scripts/31-fetch-prebuilt-firmware.sh --version v2.5.1         # another release tag; "latest" = newest release
#   scripts/31-fetch-prebuilt-firmware.sh --list [--version TAG]   # every board that release has firmware for
#   scripts/31-fetch-prebuilt-firmware.sh --force                  # discard an existing download and fetch it again
#
# Why
#   The maintainers publish one ZIP per board on https://github.com/78/xiaozhi-esp32/releases.
#   Having the official image next to our own build and next to the factory dump lets
#   scripts/30-analyze-flash-image.sh and scripts/32-compare-images.sh tell them apart,
#   and gives a known-good image to flash if our own build misbehaves.
#
# What it does
#   - asks the GitHub API for the release and reads the asset list from the answer (names are
#     NOT assumed: the board is looked up in the release's own release-manifest.json when it
#     has one, otherwise matched against the asset file names)
#   - downloads the ZIP into a NEW directory prebuilt/<tag>/<board>/ and checks size + SHA-256
#     against the GitHub API digest and the release's SHA256SUMS
#   - unpacks it there (plain files only; no paths outside the directory; nothing is executed)
#   - prints the directory contents with SHA-256 hashes and writes SOURCE.txt (where it came from)
#   Since v2.x a ZIP holds exactly one file, merged-binary.bin: bootloader + partition table +
#   app (+ assets) in one image that starts at flash offset 0x0.
#
# Re-running it does not download again: it re-verifies what is on disk against the saved
# release metadata and prints the same listing. One API request per download (limit: 60/hour
# without a token).
# Downloads are untrusted data. Nothing in prebuilt/ is ever executed; the Python that reads
# them runs with -I from scripts/py/.
# Output is also saved to logs/<timestamp>-fetch-prebuilt-firmware.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REPO="78/xiaozhi-esp32"
HELPER=(python3 -I "$XZ_SCRIPTS/py/fetch_prebuilt.py")
WORK=""

cleanup() { [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"; return 0; }

# download <url> <dest-file>: https only (also across redirects), bounded size, no progress noise in logs
fetch() {
  curl -fsSL --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 20 --max-time 900 \
       --max-filesize 268435456 -o "$2" "$1" || die "download failed: $1"
}

# print what is in an already-downloaded directory and re-check it against the saved metadata
show_existing() {
  local dir="$1" board="$2"
  local zip; zip="$(find "$dir" -maxdepth 1 -type f -name '*.zip' | head -1)"
  echo "=== prebuilt firmware (already downloaded) ==="
  echo "  directory: $dir"
  if [[ -f "$dir/SOURCE.txt" ]]; then sed 's/^/  | /' "$dir/SOURCE.txt"; fi
  if [[ -n "$zip" && -f "$dir/release/release.json" ]]; then
    local sel="" name url size digest aname
    sel="$("${HELPER[@]}" select "$dir/release/release.json" "$board" --manifest "$dir/release/release-manifest.json" 2>/dev/null)" || true
    if [[ -n "$sel" ]]; then
      IFS=$'\t' read -r name aname url size digest <<<"$sel"
      [[ "$aname" == "$(basename "$zip")" ]] || warn "saved metadata now selects $aname, directory holds $(basename "$zip")"
      "${HELPER[@]}" verify "$zip" --name "$(basename "$zip")" --size "$size" --digest "$digest" --sums "$dir/release/SHA256SUMS" \
        || die "the ZIP on disk no longer matches the release metadata (re-fetch with --force)"
    fi
    "${HELPER[@]}" check-unpacked "$zip" "$dir" || die "unpacked files differ from the ZIP (re-fetch with --force)"
  else
    warn "no ZIP / release metadata in $dir - cannot re-verify (re-fetch with --force)"
  fi
  echo
  echo "=== contents: sha256, bytes, name ==="
  "${HELPER[@]}" describe "$dir"
  print_next "$dir"
}

print_next() {
  local dir="$1" bin
  echo
  while IFS= read -r bin; do
    echo "  analyze with: scripts/30-analyze-flash-image.sh ${bin#"$XZ_ROOT"/}"
  done < <(find "$dir" -maxdepth 2 -type f -name '*.bin' | sort)
}

main() {
  local board="sp-esp32-s3-1.28-box" version="v2.5.2" force=0 list=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --board)   [[ $# -ge 2 ]] || die "--board needs a board name"; board="$2"; shift 2 ;;
      --version) [[ $# -ge 2 ]] || die "--version needs a release tag like v2.5.2"; version="$2"; shift 2 ;;
      --force)   force=1; shift ;;
      --list)    list=1; shift ;;
      -h|--help) sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
  [[ "$version" =~ ^[0-9] ]] && version="v$version"            # accept 2.5.2 for v2.5.2
  [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad release tag: $version"
  [[ "$board" =~ ^[a-z0-9][a-z0-9._/-]*$ && "$board" != *..* ]] || die "bad board name: $board"
  command -v curl >/dev/null || die "curl is not installed"

  local root="$XZ_ROOT/prebuilt"
  mkdir -p "$root"

  # Already downloaded? Then no network at all.
  local dir="$root/$version/$board"
  if [[ $list -eq 0 && $force -eq 0 && "$version" != "latest" && -f "$dir/SOURCE.txt" ]]; then
    log "already present (use --force to download again)"
    show_existing "$dir" "$board"
    return 0
  fi

  WORK="$(mktemp -d "$root/.fetch.XXXXXX")"
  trap cleanup EXIT
  local rel="$WORK/release"; mkdir "$rel"

  # 1. release metadata from the GitHub API
  local api="https://api.github.com/repos/$REPO/releases/tags/$version"
  [[ "$version" == "latest" ]] && api="https://api.github.com/repos/$REPO/releases/latest"
  log "querying $api"
  local code
  code="$(curl -sS --proto '=https' --connect-timeout 20 --max-time 120 -o "$rel/release.json" -w '%{http_code}' \
            -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$api")" \
    || die "could not reach api.github.com"
  case "$code" in
    200) ;;
    404) die "no release '$version' in $REPO (tags look like v2.5.2; see https://github.com/$REPO/releases)" ;;
    403|429) die "GitHub API refused the request (HTTP $code) - probably the 60 requests/hour anonymous rate limit; retry later" ;;
    *) die "GitHub API answered HTTP $code" ;;
  esac
  local info tag html published commit
  info="$("${HELPER[@]}" release-info "$rel/release.json")" || die "unexpected answer from the GitHub API"
  IFS=$'\t' read -r tag html published commit <<<"$info"
  log "release $tag, published $published, commit $commit"

  # 2. the release's own manifest + checksum list (present since v2.5.x), verified like any asset
  local support name url size digest
  support="$("${HELPER[@]}" support "$rel/release.json")" || die "cannot read the asset list"
  while IFS=$'\t' read -r name url size digest; do
    [[ -n "$name" ]] || continue
    fetch "$url" "$rel/$name"
    "${HELPER[@]}" verify "$rel/$name" --name "$name" --size "$size" --digest "$digest" >/dev/null \
      || die "$name does not match the size/digest GitHub announced"
  done <<<"$support"
  [[ -f "$rel/release-manifest.json" ]] || log "release has no release-manifest.json; matching by asset file name"

  if [[ $list -eq 1 ]]; then
    echo "=== firmware in release $tag ==="
    "${HELPER[@]}" list "$rel/release.json" --manifest "$rel/release-manifest.json"
    return 0
  fi

  # 3. which asset is our board?
  local sel vname aname aurl asize adigest
  sel="$("${HELPER[@]}" select "$rel/release.json" "$board" --manifest "$rel/release-manifest.json")" \
    || die "cannot pick a firmware asset for board '$board' in $tag (see message above; --list shows all)"
  IFS=$'\t' read -r vname aname aurl asize adigest <<<"$sel"
  dir="$root/$tag/$vname"
  if [[ -e "$dir" ]]; then
    if [[ $force -eq 1 ]]; then
      log "--force: removing $dir"
      rm -rf "$dir"
    else
      log "already present (use --force to download again)"
      show_existing "$dir" "$vname"
      return 0
    fi
  fi

  # 4. download, verify, unpack - all inside the staging directory, moved into place only when complete
  local stage="$WORK/stage"; mkdir "$stage"
  log "downloading $aname ($asize bytes)"
  fetch "$aurl" "$WORK/$aname"
  echo "=== download ==="
  echo "  release: $tag  ($html)"
  echo "  asset:   $aname"
  echo "  url:     $aurl"
  "${HELPER[@]}" verify "$WORK/$aname" --name "$aname" --size "$asize" --digest "$adigest" --sums "$rel/SHA256SUMS" \
    || die "downloaded file does not match what GitHub announced - not keeping it"
  "${HELPER[@]}" unpack "$WORK/$aname" "$stage" || die "refusing to unpack $aname"

  local f
  for f in "$aname" SOURCE.txt release; do
    [[ ! -e "$stage/$f" ]] || die "archive member '$f' collides with our own file names"
  done
  mv "$WORK/$aname" "$stage/$aname"; chmod a-w "$stage/$aname"
  mv "$rel" "$stage/release"
  {
    echo "# written by scripts/31-fetch-prebuilt-firmware.sh on $(date -Is)"
    echo "repository: $REPO"
    echo "release:    $tag  ($html)"
    echo "published:  $published"
    echo "commit:     $commit"
    echo "board:      $vname"
    echo "asset:      $aname"
    echo "url:        $aurl"
    echo "api digest: $adigest"
    echo "zip sha256: $(sha256sum "$stage/$aname" | cut -d' ' -f1)"
  } > "$stage/SOURCE.txt"
  mkdir -p "$root/$tag"
  mv "$stage" "$dir"
  log "saved to $dir"

  echo
  echo "=== contents of ${dir#"$XZ_ROOT"/}: sha256, bytes, name ==="
  "${HELPER[@]}" describe "$dir"
  print_next "$dir"
}

xz_run_logged fetch-prebuilt-firmware main "$@"
