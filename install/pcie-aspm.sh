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
MANAGED_BOOT_ARGS=(
    "pcie_aspm=off"
    "pci=noaer"
    "pcie_aspm.policy=performance"
    "nvme_core.default_ps_max_latency_us=0"
)

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --enable               Write the managed GRUB drop-in that appends the boot policy args
  --disable              Remove the managed GRUB drop-in
  --status               Show the managed drop-in and current boot policy state
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

boot_cmdline_has_arg() {
    local arg="$1"
    grep -Fqw -- "${arg}" /proc/cmdline 2>/dev/null
}

boot_cmdline_policy_summary() {
    local present=()
    local arg
    for arg in "${MANAGED_BOOT_ARGS[@]}"; do
        if boot_cmdline_has_arg "${arg}"; then
            present+=("${arg}")
        fi
    done

    if ((${#present[@]} == 0)); then
        echo "none"
    else
        local IFS=', '
        echo "${present[*]}"
    fi
}

boot_policy_is_complete() {
    local arg
    for arg in "${MANAGED_BOOT_ARGS[@]}"; do
        if ! boot_cmdline_has_arg "${arg}"; then
            return 1
        fi
    done
    return 0
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
    {
        cat <<EOF
# Managed by install/pcie-aspm.sh
EOF
        local arg
        for arg in "${MANAGED_BOOT_ARGS[@]}"; do
            printf 'case " ${GRUB_CMDLINE_LINUX_DEFAULT:-} " in\n'
            printf '    *" %s "*) ;;\n' "${arg}"
            printf '    *) GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+${GRUB_CMDLINE_LINUX_DEFAULT} }%s" ;;\n' "${arg}"
            printf 'esac\n'
        done
    } > "${GRUB_DROPIN}"
    chmod 0644 "${GRUB_DROPIN}"
}

show_status() {
    section "PCIe / NVMe Boot Policy"
    info "Managed GRUB drop-in : ${GRUB_DROPIN}"
    info "Drop-in state         : $(managed_dropin_status)"
    if [[ -f "${GRUB_DROPIN}" ]]; then
        info "Configured for next boot: $(printf '%s' "${MANAGED_BOOT_ARGS[*]}")"
    else
        info "Configured for next boot: not forcing managed boot args"
    fi
    info "Current boot cmdline  : $(boot_cmdline_policy_summary)"
    info "Active module policy  : $(current_policy)"
    if boot_policy_is_complete; then
        success "Managed PCIe / NVMe boot policy is present in the current boot"
    else
        warn "Managed PCIe / NVMe boot policy is incomplete or absent in the current boot"
    fi
}

enable_policy() {
    section "PCIe / NVMe Boot Policy"
    write_dropin
    ensure_grub_update
    success "Enabled managed PCIe / NVMe boot policy"
    warn "Reboot required for the change to take effect"
}

disable_policy() {
    section "PCIe / NVMe Boot Policy"
    if [[ -f "${GRUB_DROPIN}" ]]; then
        rm -f "${GRUB_DROPIN}"
        ensure_grub_update
        success "Disabled managed PCIe / NVMe boot policy"
        warn "Reboot required for the change to take effect"
    else
        info "Managed PCIe / NVMe boot policy is already disabled"
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
