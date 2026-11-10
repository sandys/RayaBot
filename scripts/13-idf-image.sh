#!/usr/bin/env bash
# 13-idf-image.sh — pull / inspect the pinned ESP-IDF docker image that every firmware build runs in.
#
# Usage:
#   scripts/13-idf-image.sh            # show the pin, the copy in the local docker store, and what is inside it
#   scripts/13-idf-image.sh --pull     # docker pull the pinned tag first (several GB, takes minutes), then show
#
# Why this is its own script
#   The image IS the toolchain: ESP-IDF, the xtensa/riscv compilers, cmake, ninja and the
#   Python environment all come from it. The tag is pinned in scripts/lib/idf-docker.sh
#   (XZ_IDF_IMAGE); this script is the only place that downloads it, so a build never
#   pulls several GB behind your back (scripts/11-build-firmware.sh just refuses to start
#   until the image is there).
#
# What it prints
#   - the pinned tag + pinned registry digest, and whether the local copy matches the pin
#   - image id, creation date, size, architecture
#   - what is inside, probed as the same uid:gid the builds use: ESP-IDF version and git
#     commit, python / cmake / ninja / ccache versions (scripts/container/idf-info.sh)
#   - with --pull: wall-clock time of the pull
# It writes state/idf-image.env (tag, image id, registry digest, IDF version) as a record.
#
# Exit status: 0 if the image is present and usable, 1 otherwise.
# Output is also saved to logs/<timestamp>-idf-image.log

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$XZ_SCRIPTS/lib/idf-docker.sh"

main() {
  local pull=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pull) pull=1; shift ;;
      -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done

  command -v docker >/dev/null || die "docker is not installed"
  docker info >/dev/null 2>&1 || die "docker daemon not reachable as $(id -un) (see scripts/00-survey-wsl.sh)"

  if [[ $pull -eq 1 ]]; then
    log "docker pull $XZ_IDF_IMAGE"
    local t0=$SECONDS
    docker pull "$XZ_IDF_IMAGE" || die "docker pull $XZ_IDF_IMAGE failed"
    local dt=$((SECONDS - t0))
    echo "pull wall-clock: ${dt} s ($((dt / 60)) min $((dt % 60)) s)"
    echo
  fi

  echo "=== pinned (scripts/lib/idf-docker.sh) ==="
  echo "  image:         $XZ_IDF_IMAGE"
  echo "  pinned digest: ${XZ_IDF_IMAGE_PIN_DIGEST:-<not recorded yet>} (for $XZ_IDF_IMAGE_PIN_TAG)"

  echo
  echo "=== local docker store ==="
  if ! xz_idf_image_present; then
    echo "  NOT PULLED - run: scripts/13-idf-image.sh --pull"
    return 1
  fi
  local id digest
  id="$(xz_idf_image_id)" || die "docker image inspect failed"
  digest="$(xz_idf_image_digest)" || die "docker image inspect failed"
  echo "  image id:      $id"
  echo "  repo digest:   $digest"
  if [[ "$XZ_IDF_IMAGE" != "$XZ_IDF_IMAGE_PIN_TAG" ]]; then
    echo "  pin check:     skipped (XZ_IDF_IMAGE overridden, pin is for $XZ_IDF_IMAGE_PIN_TAG)"
  elif [[ -z "$XZ_IDF_IMAGE_PIN_DIGEST" ]]; then
    echo "  pin check:     no digest pinned yet - copy the sha256 above into XZ_IDF_IMAGE_PIN_DIGEST"
  elif [[ "$digest" == *"$XZ_IDF_IMAGE_PIN_DIGEST" ]]; then
    echo "  pin check:     OK (matches the pinned digest)"
  else
    echo "  pin check:     DRIFT - upstream re-pushed the tag, or a different image carries it locally"
  fi
  docker image inspect --format '  created:       {{.Created}}
  platform:      {{.Os}}/{{.Architecture}}' "$XZ_IDF_IMAGE" || die "docker image inspect failed"
  docker image inspect --format '{{.Size}}' "$XZ_IDF_IMAGE" \
    | awk '{printf "  size on disk:  %.2f GB (%d bytes, unpacked layers)\n", $1 / 1e9, $1}'

  echo
  echo "=== inside the container (as uid:gid $(id -u):$(id -g), the way builds run) ==="
  local info
  info="$(xz_idf_run /xz/container/idf-info.sh)" || die "could not run a command inside $XZ_IDF_IMAGE"
  info="$(grep -E '^[a-z_]+=' <<<"$info")" || die "no toolchain info came back from the container"
  sed -E 's/^([a-z_]+)=/\1: /; s/^/  /' <<<"$info"

  local idf_describe
  idf_describe="$(sed -n 's/^idf_git_describe=//p' <<<"$info")"
  mkdir -p "$XZ_ROOT/state"
  {
    echo "# written by scripts/13-idf-image.sh on $(date -Is)"
    echo "XZ_IDF_IMAGE_TAG=$XZ_IDF_IMAGE"
    echo "XZ_IDF_IMAGE_ID=$id"
    echo "XZ_IDF_IMAGE_REPO_DIGEST=$digest"
    echo "XZ_IDF_VERSION=$idf_describe"
  } > "$XZ_ROOT/state/idf-image.env"
  log "recorded in state/idf-image.env"
}

xz_run_logged idf-image main "$@"
