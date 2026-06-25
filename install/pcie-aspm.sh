#!/usr/bin/env bash

set -euo pipefail

ORIGINAL_ARGS=("$@")

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[OK]${NC}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}-- $* --${NC}"; }

ACTION=""
GRUB_DROPIN="/etc/default/grub.d/99-infra-pcie-aspm.cfg"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --enable               Write the managed GRUB drop-in that appends pcie_aspm=off
  --disable              Remove the managed GRUB drop-in
  --status               Show the managed drop-in and current boot PCIe ASPM state
  -h, --help             Show this help

Notes:
  - The helper only manages the boot policy in ${GRUB_DROPIN}
  - Changes take effect on the next reboot after update-grub completes

Examples:
  sudo $(basename "$0") --status
  sudo $(basename "$0") --enable
  sudo $(basename "$0") --disable
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --enable) ACTION="enable"; shift ;;
        --disable) ACTION="disable"; shift ;;
        --status) ACTION="status"; shift ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1" ;;
    esac
done

[[ -n "${ACTION}" ]] || error "Specify --enable, --disable, or --status"

if [[ "${ACTION}" != "status" ]] && [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo -E "$0" "${ORIGINAL_ARGS[@]}"
fi

current_policy() {
    local raw current
    raw="$(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true)"
    if [[ -z "${raw}" ]]; then
        echo "unknown"
        return
    fi
    current="$(printf '%s\n' "${raw}" | sed -n 's/.*\[\([^]]*\)\].*/\1/p' | head -n1)"
    if [[ -n "${current}" ]]; then
        echo "${current}"
    else
        echo "${raw}"
    fi
}

boot_cmdline_has_aspm_off() {
    grep -qw 'pcie_aspm=off' /proc/cmdline 2>/dev/null
}

managed_dropin_status() {
    if [[ -f "${GRUB_DROPIN}" ]]; then
        echo "present"
    else
        echo "absent"
    fi
}

ensure_grub_update() {
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    else
        error "update-grub is not available on this system"
    fi
}

write_dropin() {
    install -d -m 0755 /etc/default/grub.d
    cat > "${GRUB_DROPIN}" <<'EOF'
# Managed by install/pcie-aspm.sh
case " ${GRUB_CMDLINE_LINUX_DEFAULT:-} " in
    *" pcie_aspm=off "*) ;;
    *) GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+${GRUB_CMDLINE_LINUX_DEFAULT} }pcie_aspm=off" ;;
esac
EOF
    chmod 0644 "${GRUB_DROPIN}"
}

show_status() {
    section "PCIe ASPM Policy"
    info "Managed GRUB drop-in : ${GRUB_DROPIN}"
    info "Drop-in state         : $(managed_dropin_status)"
    if [[ -f "${GRUB_DROPIN}" ]]; then
        info "Configured for next boot: pcie_aspm=off"
    else
        info "Configured for next boot: not forcing pcie_aspm=off"
    fi
    info "Current boot cmdline  : $(boot_cmdline_has_aspm_off && echo 'pcie_aspm=off present' || echo 'pcie_aspm=off absent')"
    info "Active module policy  : $(current_policy)"
    if boot_cmdline_has_aspm_off; then
        success "PCIe ASPM is disabled for the current boot"
    else
        warn "PCIe ASPM is not disabled for the current boot"
    fi
}

enable_policy() {
    section "PCIe ASPM Policy"
    write_dropin
    ensure_grub_update
    success "Enabled managed PCIe ASPM boot policy"
    warn "Reboot required for the change to take effect"
}

disable_policy() {
    section "PCIe ASPM Policy"
    if [[ -f "${GRUB_DROPIN}" ]]; then
        rm -f "${GRUB_DROPIN}"
        ensure_grub_update
        success "Disabled managed PCIe ASPM boot policy"
        warn "Reboot required for the change to take effect"
    else
        info "Managed PCIe ASPM boot policy is already disabled"
        if command -v update-grub >/dev/null 2>&1; then
            ensure_grub_update
        fi
    fi
}

case "${ACTION}" in
    status) show_status ;;
    enable) enable_policy ;;
    disable) disable_policy ;;
esac
