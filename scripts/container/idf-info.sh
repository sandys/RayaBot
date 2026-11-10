#!/usr/bin/env bash
# scripts/container/idf-info.sh — print the toolchain facts of the ESP-IDF container as key=value lines.
#
# Runs INSIDE the espressif/idf container (it is mounted at /xz/container), never on the host:
#
#     xz_idf_run /xz/container/idf-info.sh            # from a script that sourced lib/idf-docker.sh
#
# Used by scripts/13-idf-image.sh (to show what the image contains) and by
# scripts/container/build-board.sh (to record what a build was made with).
# Every probe is allowed to fail on its own: a missing tool prints "unknown" instead of
# aborting, because this output is documentation, not a build step.

kv() { printf '%s=%s\n' "$1" "${2:-unknown}"; }

kv idf_version        "$(idf.py --version 2>/dev/null | tail -1)"
kv idf_path           "${IDF_PATH:-}"
kv idf_git_describe   "$(git -C "${IDF_PATH:-/nonexistent}" describe --tags --always --dirty 2>/dev/null)"
kv idf_git_commit     "$(git -C "${IDF_PATH:-/nonexistent}" rev-parse HEAD 2>/dev/null)"
kv idf_tools_path     "${IDF_TOOLS_PATH:-}"
kv python             "$(python --version 2>&1) ($(command -v python))"
kv cmake              "$(cmake --version 2>/dev/null | head -1)"
kv ninja              "$(ninja --version 2>/dev/null)"
kv ccache             "$(ccache --version 2>/dev/null | head -1) (IDF_CCACHE_ENABLE=${IDF_CCACHE_ENABLE:-unset})"
# Versions are read from the installed Python packages; the tools themselves are not started.
kv esptool_package    "$(python -c 'import esptool; print(esptool.__version__)' 2>/dev/null)"
kv component_manager  "$(python -c 'import idf_component_manager as m; print(m.version)' 2>/dev/null \
                         || python -c 'from importlib.metadata import version; print(version("idf-component-manager"))' 2>/dev/null)"
kv container_os       "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
kv container_arch     "$(uname -m)"
kv container_user     "$(id -u):$(id -g) HOME=$HOME"
kv container_cpus     "$(nproc 2>/dev/null)"
