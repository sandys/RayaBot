#!/usr/bin/env bash
# scripts/lib/idf-docker.sh — helpers for scripts that run ESP-IDF inside docker (the 1x range).
#
# Source it after common.sh:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#     source "$XZ_SCRIPTS/lib/idf-docker.sh"
#
# What it gives you
#   XZ_IDF_IMAGE              the pinned image tag  <-- the ONE place the ESP-IDF version is chosen
#   XZ_IDF_IMAGE_PIN_DIGEST   registry digest that tag had when this project first pulled it;
#                             a different digest later means upstream re-pushed the tag
#   XZ_FW_SRC                 firmware checkout on the host (firmware/xiaozhi-esp32)
#   XZ_IDF_HOME               host directory mounted as $HOME inside the container (cache/idf-home)
#   xz_idf_image_present      0 if the pinned image is in the local docker store
#   xz_idf_image_id           print the local image id          (sha256:...)
#   xz_idf_image_digest       print the local image's registry digest (espressif/idf@sha256:...)
#   xz_idf_image_check        die if the image is missing; warn if its digest is not the pinned one
#   xz_idf_run [--tty] cmd... run cmd inside the container, cwd = the firmware tree
#   xz_build_lock             take the exclusive lock on the firmware tree (one IDF job at a time)
#
# Background
#   The host has no ESP-IDF, cmake or ninja and we cannot sudo, so every IDF command runs in
#   the official espressif/idf image - the same image upstream CI builds with
#   (firmware/xiaozhi-esp32/.github/workflows/build.yml -> "image: espressif/idf:v6.1").
#
#   How the container is wired (xz_idf_run):
#     firmware/xiaozhi-esp32 -> /project        always the same path, so the CMake cache stays valid
#                                               between runs and the paths baked into the binaries
#                                               (__FILE__ in asserts) do not depend on the host layout
#     cache/idf-home         -> /home/builder   $HOME: ccache (~/.cache/ccache) and the component
#                                               manager's download cache (~/.cache/Espressif) persist
#     scripts/container      -> /xz/container   read-only: the halves of our scripts that run inside
#     --user <uid>:<gid>                        everything written into the bind mounts belongs to the
#                                               calling user, never to root
#     PYTHONUNBUFFERED=1                        stdout is a pipe, not a terminal: without this the
#                                               prints of upstream's build.py would land in the log
#                                               long after the idf.py output they belong to
#   The image's entrypoint sources $IDF_PATH/export.sh before running the command, so idf.py,
#   python (the IDF virtualenv), cmake, ninja and the cross compilers are on PATH.
#
#   No device, no --privileged, no host network: nothing started here can reach the serial port.

XZ_IDF_IMAGE="${XZ_IDF_IMAGE:-espressif/idf:v6.1}"
# Recorded from the first pull (scripts/13-idf-image.sh --pull, 2026-11-10): ESP-IDF v6.1,
# commit fff9895c, image created 2026-08-26, linux/amd64. Only compared when the default tag
# above is in use; XZ_IDF_IMAGE=... in the environment selects another image for experiments.
XZ_IDF_IMAGE_PIN_TAG="espressif/idf:v6.1"
XZ_IDF_IMAGE_PIN_DIGEST="sha256:81893c71bb5e570088901f21def8684c25cd2a9020281bd01b843a7655edb18c"

XZ_FW_SRC="$XZ_ROOT/firmware/xiaozhi-esp32"
XZ_IDF_HOME="$XZ_ROOT/cache/idf-home"
XZ_OUT="$XZ_ROOT/out"
export XZ_IDF_IMAGE XZ_FW_SRC XZ_IDF_HOME XZ_OUT

xz_idf_image_present() { docker image inspect "$XZ_IDF_IMAGE" >/dev/null 2>&1; }

xz_idf_image_id() { docker image inspect --format '{{.Id}}' "$XZ_IDF_IMAGE"; }

# RepoDigests is empty for an image that was built or loaded locally instead of pulled.
xz_idf_image_digest() {
  docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}none (image was not pulled from a registry){{end}}' "$XZ_IDF_IMAGE"
}

xz_idf_image_check() {
  command -v docker >/dev/null || die "docker is not installed"
  docker info >/dev/null 2>&1 || die "docker daemon not reachable as $(id -un) (see scripts/00-survey-wsl.sh)"
  xz_idf_image_present || die "docker image $XZ_IDF_IMAGE is not pulled yet: run scripts/13-idf-image.sh --pull"
  if [[ "$XZ_IDF_IMAGE" == "$XZ_IDF_IMAGE_PIN_TAG" && -n "$XZ_IDF_IMAGE_PIN_DIGEST" ]]; then
    local have; have="$(xz_idf_image_digest)"
    if [[ "$have" != *"$XZ_IDF_IMAGE_PIN_DIGEST" ]]; then
      warn "image digest drift: $XZ_IDF_IMAGE is $have"
      warn "  pinned in scripts/lib/idf-docker.sh: $XZ_IDF_IMAGE_PIN_DIGEST (upstream re-pushed the tag?)"
    fi
  fi
}

# One IDF job at a time: two builds in the same tree would corrupt build/ and sdkconfig.
# Held until the calling script exits. Fails at once instead of queueing behind a 10-minute build.
xz_build_lock() {
  mkdir -p "$XZ_ROOT/state"
  exec 8>"$XZ_ROOT/state/build.lock"
  flock -n 8 || die "another IDF job is using the firmware tree (state/build.lock is held)"
}

# xz_idf_run [--tty] cmd [args...]
#   --tty   allocate a terminal and keep stdin open (menuconfig, interactive shell).
#           Without it stdin is not attached at all, so nothing can sit waiting for input.
xz_idf_run() {
  local tty=()
  if [[ "${1:-}" == "--tty" ]]; then tty=(--interactive --tty --env "TERM=${TERM:-xterm-256color}"); shift; fi
  [[ $# -ge 1 ]] || die "xz_idf_run: no command given"
  [[ -d "$XZ_FW_SRC/.git" ]] || die "firmware source missing: $XZ_FW_SRC (run scripts/10-fetch-firmware-source.sh)"
  mkdir -p "$XZ_IDF_HOME"
  docker run --rm --init "${tty[@]}" \
    --user "$(id -u):$(id -g)" \
    --env HOME=/home/builder \
    --env PYTHONUNBUFFERED=1 \
    --volume "$XZ_FW_SRC:/project" \
    --volume "$XZ_IDF_HOME:/home/builder" \
    --volume "$XZ_SCRIPTS/container:/xz/container:ro" \
    --workdir /project \
    "$XZ_IDF_IMAGE" "$@"
}
