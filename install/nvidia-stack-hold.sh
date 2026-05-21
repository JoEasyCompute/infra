#!/usr/bin/env bash

# Freeze or unfreeze the validated NVIDIA/CUDA stack on a GPU node.
#
# This helper is intentionally narrow: it operates only on installed packages
# that match the NVIDIA/CUDA stack installed by base-install.sh.

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[OK]${NC}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

GPU_STACK_HOLD_REGEX='^(cuda-|cudnn9-cuda-|datacenter-gpu-manager|libcuda|libcudnn|libnvidia|nvidia-)'
GPU_STACK_HOLD_EXCLUDE_REGEX='^(cuda-keyring|nvidia-container-toolkit|nvidia-container-runtime|libnvidia-container)'

MODE="status"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Manage holds for the validated NVIDIA/CUDA stack.

Options:
  --status         Show installed NVIDIA/CUDA packages and current holds
  --hold           Hold the installed NVIDIA/CUDA packages
  --unhold         Remove holds from installed NVIDIA/CUDA packages
  -h, --help       Show this help

Examples:
  sudo $(basename "$0") --status
  sudo $(basename "$0") --hold
  sudo $(basename "$0") --unhold
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --status) MODE="status"; shift ;;
        --hold)   MODE="hold"; shift ;;
        --unhold) MODE="unhold"; shift ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1. Use --help for usage." ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    error "Run as root: sudo $(basename "$0") ..."
fi

list_installed_packages() {
    dpkg -l 2>/dev/null \
        | awk '$1 == "ii" { print $2 }' \
        | grep -E "${GPU_STACK_HOLD_REGEX}" \
        | grep -Ev "${GPU_STACK_HOLD_EXCLUDE_REGEX}" \
        | sort -u \
        || true
}

list_held_packages() {
    apt-mark showhold 2>/dev/null \
        | grep -E "${GPU_STACK_HOLD_REGEX}" \
        | grep -Ev "${GPU_STACK_HOLD_EXCLUDE_REGEX}" \
        | sort -u \
        || true
}

print_packages() {
    local title="$1"
    shift
    local -a packages=("$@")
    echo "${title}"
    if (( ${#packages[@]} > 0 )); then
        printf '    %s\n' "${packages[@]}"
    else
        echo "    (none)"
    fi
}

read_packages_into_array() {
    local -n _out="$1"
    mapfile -t _out < <("$2")
}

show_status() {
    section "NVIDIA/CUDA Hold Status"
    local -a installed_packages=()
    local -a held_packages=()
    read_packages_into_array installed_packages list_installed_packages
    read_packages_into_array held_packages list_held_packages
    print_packages "Installed matching packages:" "${installed_packages[@]}"
    print_packages "Held matching packages:" "${held_packages[@]}"
}

hold_packages() {
    section "Hold NVIDIA/CUDA Packages"
    local -a installed_packages=()
    read_packages_into_array installed_packages list_installed_packages
    if (( ${#installed_packages[@]} == 0 )); then
        warn "No matching installed NVIDIA/CUDA packages found"
        return 0
    fi
    print_packages "Applying holds to:" "${installed_packages[@]}"
    apt-mark hold "${installed_packages[@]}" \
        || error "Failed to hold NVIDIA/CUDA packages"
    success "NVIDIA/CUDA packages held"
}

unhold_packages() {
    section "Unhold NVIDIA/CUDA Packages"
    local -a held_packages=()
    read_packages_into_array held_packages list_held_packages
    if (( ${#held_packages[@]} == 0 )); then
        warn "No matching held NVIDIA/CUDA packages found"
        return 0
    fi
    print_packages "Removing holds from:" "${held_packages[@]}"
    apt-mark unhold "${held_packages[@]}" \
        || error "Failed to unhold NVIDIA/CUDA packages"
    success "NVIDIA/CUDA holds removed"
}

case "${MODE}" in
    status) show_status ;;
    hold) hold_packages ;;
    unhold) unhold_packages ;;
    *) error "Unsupported mode: ${MODE}" ;;
esac
