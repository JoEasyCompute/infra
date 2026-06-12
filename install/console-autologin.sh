#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E "$0" "$@"
fi

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[OK]${NC}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}-- $* --${NC}"; }

ACTION=""
TARGET_USER=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --enable               Enable tty1 console autologin for the target user
  --disable              Disable tty1 console autologin for the target user
  --status               Show the current tty1 autologin state
  --user <name>          Target user (default: invoking sudo user)
  -h, --help             Show this help

Examples:
  sudo $(basename "$0") --enable
  sudo $(basename "$0") --disable
  sudo $(basename "$0") --status
  sudo $(basename "$0") --enable --user ezc
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --enable) ACTION="enable"; shift ;;
        --disable) ACTION="disable"; shift ;;
        --status) ACTION="status"; shift ;;
        --user)
            TARGET_USER="${2:-}"
            [[ -n "${TARGET_USER}" ]] || error "--user requires a value"
            shift 2
            ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1" ;;
    esac
done

[[ -n "${ACTION}" ]] || error "Specify --enable, --disable, or --status"

if [[ -z "${TARGET_USER}" ]]; then
    TARGET_USER="${SUDO_USER:-}"
    if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
        TARGET_USER="$(logname 2>/dev/null || true)"
    fi
fi

[[ -n "${TARGET_USER}" ]] || error "Unable to determine target user. Re-run with --user <name>."
[[ "${TARGET_USER}" != "root" ]] || error "Console autologin for root is not supported."
getent passwd "${TARGET_USER}" >/dev/null || error "User not found: ${TARGET_USER}"

TTY_OVERRIDE_DIR="/etc/systemd/system/getty@tty1.service.d"
TTY_OVERRIDE_CONF="${TTY_OVERRIDE_DIR}/override.conf"
LOGIND_DROPIN_DIR="/etc/systemd/logind.conf.d"
LOGIND_DROPIN_CONF="${LOGIND_DROPIN_DIR}/99-infra-console-autologin.conf"

write_file() {
    local destination="$1"
    local tmp
    tmp="$(mktemp)"
    cat > "${tmp}"
    install -d -m 0755 "$(dirname "${destination}")"
    install -m 0644 -o root -g root "${tmp}" "${destination}"
    rm -f "${tmp}"
}

current_console_user() {
    if [[ -f "${TTY_OVERRIDE_CONF}" ]]; then
        awk -F'autologin ' '/ExecStart=-\/sbin\/agetty --noissue --autologin / { split($2, a, " "); print a[1]; exit }' "${TTY_OVERRIDE_CONF}" 2>/dev/null || true
    fi
}

status_console() {
    local configured_user
    configured_user="$(current_console_user)"
    if [[ -z "${configured_user}" ]]; then
        echo "tty1: disabled"
        return
    fi
    if [[ "${configured_user}" == "${TARGET_USER}" ]]; then
        echo "tty1: enabled for ${TARGET_USER}"
    else
        echo "tty1: enabled for ${configured_user}"
    fi
}

enable_console() {
    write_file "${TTY_OVERRIDE_CONF}" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noissue --autologin ${TARGET_USER} %I \$TERM
EOF

    write_file "${LOGIND_DROPIN_CONF}" <<EOF
[Login]
NAutoVTs=1
ReserveVT=2
EOF

    systemctl daemon-reload
    success "Enabled tty1 console autologin for ${TARGET_USER}"
}

disable_console() {
    local removed=0
    if [[ -f "${TTY_OVERRIDE_CONF}" ]]; then
        rm -f "${TTY_OVERRIDE_CONF}"
        removed=1
    fi
    if [[ -f "${LOGIND_DROPIN_CONF}" ]]; then
        rm -f "${LOGIND_DROPIN_CONF}"
        removed=1
    fi
    if [[ "${removed}" -eq 1 ]]; then
        systemctl daemon-reload
        success "Disabled tty1 console autologin"
    else
        info "No managed tty1 console autologin config present"
    fi
}

section "Console Autologin"
info "Target user: ${TARGET_USER}"

case "${ACTION}" in
    status)
        status_console
        ;;
    enable)
        enable_console
        warn "Changes take effect on the next reboot or the next tty1 getty restart"
        ;;
    disable)
        disable_console
        warn "Changes take effect on the next reboot or the next tty1 getty restart"
        ;;
esac

