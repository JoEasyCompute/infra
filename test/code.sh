#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
SRC="${SCRIPT_DIR}/code.cu"
BIN="${BUILD_DIR}/code"

usage() {
    cat <<EOF
Usage: $(basename "$0") [seconds] [device_id]

Compiles ${SRC} with nvcc if needed, then runs the resulting binary.

Arguments:
  seconds     Runtime in seconds (default: 30)
  device_id   CUDA device index (default: 0)

Examples:
  $(basename "$0")
  $(basename "$0") 60
  $(basename "$0") 60 1
EOF
}

find_nvcc() {
    for candidate in "$(command -v nvcc 2>/dev/null || true)" \
                     /usr/local/cuda/bin/nvcc \
                     /usr/bin/nvcc; do
        if [[ -n "${candidate}" && -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

seconds="${1:-30}"
device_id="${2:-0}"

mkdir -p "${BUILD_DIR}"

if [[ ! -x "${BIN}" || "${SRC}" -nt "${BIN}" ]]; then
    nvcc_path="$(find_nvcc)" || {
        echo "ERROR: nvcc not found. Install the CUDA toolkit or add nvcc to PATH." >&2
        exit 1
    }
    echo "Compiling ${SRC} -> ${BIN}" >&2
    "${nvcc_path}" -O3 -std=c++17 "${SRC}" -o "${BIN}"
fi

exec "${BIN}" "${seconds}" "${device_id}"
