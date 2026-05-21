#!/usr/bin/env bash

# Show or manage the AMD ROCm apt pin used by amd-base-install.sh.
#
# AMD nodes use repo pinning instead of apt-mark holds. This helper makes that
# state visible and provides a small reset flow for operators.

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[OK]${NC}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

PIN_FILE="/etc/apt/preferences.d/rocm-pin-600"
MODE="status"
UBUNTU_VERSION_ID=""
PIN_RELEASE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Manage the AMD ROCm apt pin used by amd-base-install.sh.

Options:
  --status         Show current pin state and expected repo origin
  --pin            Write the expected pin file for this Ubuntu release
  --unpin          Remove the pin file
  --reset          Remove the pin file and recreate it for this Ubuntu release
  -h, --help       Show this help

Examples:
  sudo $(basename "$0") --status
  sudo $(basename "$0") --unpin
  sudo $(basename "$0") --reset
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --status) MODE="status"; shift ;;
        --pin)    MODE="pin"; shift ;;
        --unpin)  MODE="unpin"; shift ;;
        --reset)  MODE="reset"; shift ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1. Use --help for usage." ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    error "Run as root: sudo $(basename "$0") ..."
fi

detect_ubuntu() {
    [[ -f /etc/os-release ]] || error "/etc/os-release not found"
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || error "This helper requires Ubuntu. Detected: ${ID:-unknown}"
    case "${VERSION_ID:-}" in
        "22.04"|"24.04")
            PIN_RELEASE="repo.radeon.com"
            ;;
        "26.04")
            PIN_RELEASE="repo.amd.com"
            ;;
        *)
            error "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. Supported: 22.04, 24.04, 26.04"
            ;;
    esac
    UBUNTU_VERSION_ID="${VERSION_ID}"
}

expected_pin() {
    cat <<EOF
Package: *
Pin: release o=${PIN_RELEASE}
Pin-Priority: 600
EOF
}

print_pin_file() {
    if [[ -f "${PIN_FILE}" ]]; then
        sed 's/^/    /' "${PIN_FILE}"
    else
        echo "    (missing)"
    fi
}

show_status() {
    section "AMD ROCm Pin Status"
    info "Ubuntu: ${UBUNTU_VERSION_ID}"
    info "Expected pin origin: ${PIN_RELEASE}"
    if [[ -f "${PIN_FILE}" ]]; then
        success "Pin file present: ${PIN_FILE}"
        print_pin_file
    else
        warn "Pin file not present: ${PIN_FILE}"
    fi
    echo
    info "Restore flow: sudo $(basename "$0") --reset"
    info "Remove flow:  sudo $(basename "$0") --unpin"
}

write_pin() {
    section "Writing AMD ROCm Pin"
    mkdir -p "$(dirname "${PIN_FILE}")"
    expected_pin > "${PIN_FILE}"
    success "Wrote ${PIN_FILE}"
    print_pin_file
}

remove_pin() {
    section "Removing AMD ROCm Pin"
    if [[ -f "${PIN_FILE}" ]]; then
        rm -f "${PIN_FILE}"
        success "Removed ${PIN_FILE}"
    else
        warn "Pin file already absent"
    fi
}

detect_ubuntu

case "${MODE}" in
    status) show_status ;;
    pin) write_pin ;;
    unpin) remove_pin ;;
    reset)
        remove_pin
        write_pin
        ;;
    *) error "Unsupported mode: ${MODE}" ;;
esac
