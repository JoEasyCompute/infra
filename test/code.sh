#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
SRC="${SCRIPT_DIR}/code.cu"
BIN="${BUILD_DIR}/code"
SIG="${BUILD_DIR}/code.nvcc.sig"

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

find_nvidia_smi() {
    for candidate in "$(command -v nvidia-smi 2>/dev/null || true)" \
                     /usr/bin/nvidia-smi \
                     /usr/local/bin/nvidia-smi; do
        if [[ -n "${candidate}" && -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

build_gencode_args() {
    local smi_path="$1"
    local -a gencodes=()
    local -A seen=()
    local -A allow=()
    local visible="${CUDA_VISIBLE_DEVICES:-}"
    local have_allow=0
    local rows idx cc arch

    if [[ -n "${visible}" && "${visible}" != "all" ]]; then
        IFS=',' read -r -a visible_list <<< "${visible}"
        for idx in "${visible_list[@]}"; do
            idx="${idx//[[:space:]]/}"
            [[ -n "${idx}" ]] && allow["${idx}"]=1
        done
        have_allow=1
    fi

    rows="$("${smi_path}" --query-gpu=index,compute_cap --format=csv,noheader 2>/dev/null | tr -d '\r')" || return 1
    while IFS=',' read -r idx cc; do
        idx="${idx//[[:space:]]/}"
        cc="${cc//[[:space:]]/}"
        [[ -z "${idx}" || -z "${cc}" ]] && continue
        if [[ "${have_allow}" -eq 1 ]]; then
            if [[ -z "${allow[$idx]+x}" ]]; then
                continue
            fi
        fi
        arch="sm_${cc//./}"
        if [[ -z "${seen[$arch]+x}" ]]; then
            seen["${arch}"]=1
            gencodes+=("-gencode=arch=compute_${cc//./},code=${arch}")
        fi
    done <<< "${rows}"

    if [[ "${#gencodes[@]}" -eq 0 ]]; then
        return 1
    fi

    printf '%s\n' "${gencodes[@]}"
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

seconds="${1:-30}"
device_id="${2:-0}"

mkdir -p "${BUILD_DIR}"

nvcc_path="$(find_nvcc)" || {
    echo "ERROR: nvcc not found. Install the CUDA toolkit or add nvcc to PATH." >&2
    exit 1
}

compile_args=(-O3 -std=c++17)
signature="fallback:native"

if smi_path="$(find_nvidia_smi)"; then
    mapfile -t gencode_args < <(build_gencode_args "${smi_path}" || true)
    if [[ "${#gencode_args[@]}" -gt 0 ]]; then
        compile_args+=("${gencode_args[@]}")
        signature="$(printf '%s ' "${gencode_args[@]}")"
    else
        compile_args+=(-arch=native)
        signature="arch=native"
    fi
else
    compile_args+=(-arch=native)
    signature="arch=native"
fi

if [[ ! -x "${BIN}" || "${SRC}" -nt "${BIN}" || ! -f "${SIG}" || "$(cat "${SIG}" 2>/dev/null || true)" != "${signature}" ]]; then
    echo "Compiling ${SRC} -> ${BIN}" >&2
    echo "CUDA codegen  : ${signature}" >&2
    tmp_bin="${BIN}.tmp.$$"
    trap 'rm -f "${tmp_bin}"' EXIT
    "${nvcc_path}" "${compile_args[@]}" "${SRC}" -o "${tmp_bin}"
    mv "${tmp_bin}" "${BIN}"
    printf '%s\n' "${signature}" > "${SIG}"
    trap - EXIT
fi

exec "${BIN}" "${seconds}" "${device_id}"
