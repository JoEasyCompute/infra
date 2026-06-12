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
TARGET_DM="auto"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --enable               Enable autologin for the target user
  --disable              Disable autologin for the target user
  --status               Show the current autologin state
  --user <name>          Target user (default: invoking sudo user)
  --dm <auto|gdm3|lightdm|sddm>
                         Display manager to manage (default: auto-detect)
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
        --dm)
            TARGET_DM="${2:-}"
            [[ -n "${TARGET_DM}" ]] || error "--dm requires a value"
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
[[ "${TARGET_USER}" != "root" ]] || error "Autologin for root is not supported."

TARGET_HOME="$(getent passwd "${TARGET_USER}" | awk -F: '{print $6}')"
[[ -n "${TARGET_HOME}" ]] || error "Unable to determine home directory for ${TARGET_USER}"

GDM_CONF="/etc/gdm3/custom.conf"
LIGHTDM_CONF="/etc/lightdm/lightdm.conf.d/99-infra-autologin.conf"
SDDM_CONF="/etc/sddm.conf.d/99-infra-autologin.conf"
MANAGED_BEGIN="# >>> infra autologin >>>"
MANAGED_END="# <<< infra autologin <<<"

detect_display_manager() {
    case "${TARGET_DM}" in
        auto)
            local dm_unit dm_name
            dm_unit="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
            dm_name="$(basename "${dm_unit}")"
            case "${dm_name}" in
                gdm.service|gdm3.service) TARGET_DM="gdm3" ;;
                lightdm.service) TARGET_DM="lightdm" ;;
                sddm.service) TARGET_DM="sddm" ;;
            esac
            if [[ "${TARGET_DM}" == "auto" ]] && systemctl is-active --quiet gdm3.service 2>/dev/null; then
                TARGET_DM="gdm3"
            elif [[ "${TARGET_DM}" == "auto" ]] && systemctl is-active --quiet lightdm.service 2>/dev/null; then
                TARGET_DM="lightdm"
            elif [[ "${TARGET_DM}" == "auto" ]] && systemctl is-active --quiet sddm.service 2>/dev/null; then
                TARGET_DM="sddm"
            elif [[ -f "${GDM_CONF}" ]] || dpkg -s gdm3 &>/dev/null; then
                TARGET_DM="gdm3"
            elif [[ -d /etc/lightdm ]] || dpkg -s lightdm &>/dev/null; then
                TARGET_DM="lightdm"
            elif [[ -d /etc/sddm.conf.d ]] || dpkg -s sddm &>/dev/null; then
                TARGET_DM="sddm"
            else
                error "No supported display manager detected (gdm3, lightdm, or sddm)"
            fi
            ;;
        gdm3|lightdm|sddm)
            ;;
        *)
            error "Invalid --dm value: ${TARGET_DM}"
            ;;
    esac
}

strip_managed_block() {
    local src="$1" dst="$2"
    if [[ -f "${src}" ]]; then
        awk -v begin="${MANAGED_BEGIN}" -v end="${MANAGED_END}" '
            BEGIN { skip = 0 }
            $0 == begin { skip = 1; next }
            $0 == end { skip = 0; next }
            skip == 0 { print }
        ' "${src}" > "${dst}"
    else
        : > "${dst}"
    fi
}

status_gdm() {
    if [[ ! -f "${GDM_CONF}" ]]; then
        echo "GDM: disabled (config file not present)"
        return
    fi
    if grep -Eq "^AutomaticLogin=${TARGET_USER}$" "${GDM_CONF}" && grep -Eq "^AutomaticLoginEnable=true$" "${GDM_CONF}"; then
        echo "GDM: enabled for ${TARGET_USER}"
    else
        echo "GDM: disabled or configured for a different user"
    fi
}

enable_gdm() {
    local tmp
    tmp="$(mktemp)"
    install -d -m 0755 /etc/gdm3
    strip_managed_block "${GDM_CONF}" "${tmp}"
    {
        printf '\n%s\n' "${MANAGED_BEGIN}"
        printf '[daemon]\n'
        printf 'AutomaticLoginEnable=true\n'
        printf 'AutomaticLogin=%s\n' "${TARGET_USER}"
        printf '%s\n' "${MANAGED_END}"
    } >> "${tmp}"
    install -m 0644 -o root -g root "${tmp}" "${GDM_CONF}"
    rm -f "${tmp}"
    success "Enabled GDM autologin for ${TARGET_USER}"
}

disable_gdm() {
    [[ -f "${GDM_CONF}" ]] || { info "GDM config not present"; return; }
    local tmp
    tmp="$(mktemp)"
    strip_managed_block "${GDM_CONF}" "${tmp}"
    if cmp -s "${GDM_CONF}" "${tmp}"; then
        info "No managed GDM autologin block present"
    elif [[ ! -s "${tmp}" ]]; then
        rm -f "${GDM_CONF}"
        success "Disabled managed GDM autologin settings"
    else
        install -m 0644 -o root -g root "${tmp}" "${GDM_CONF}"
        success "Disabled managed GDM autologin settings"
    fi
    rm -f "${tmp}"
}

status_lightdm() {
    if [[ -f "${LIGHTDM_CONF}" ]] && grep -Eq "^[[:space:]]*autologin-user=${TARGET_USER}$" "${LIGHTDM_CONF}"; then
        echo "LightDM: enabled for ${TARGET_USER}"
    else
        echo "LightDM: disabled or configured for a different user"
    fi
}

enable_lightdm() {
    install -d -m 0755 /etc/lightdm/lightdm.conf.d
    local tmp
    tmp="$(mktemp)"
    cat > "${tmp}" <<EOF
[Seat:*]
autologin-user=${TARGET_USER}
autologin-user-timeout=0
EOF
    install -m 0644 -o root -g root "${tmp}" "${LIGHTDM_CONF}"
    rm -f "${tmp}"
    success "Enabled LightDM autologin for ${TARGET_USER}"
}

disable_lightdm() {
    if [[ -f "${LIGHTDM_CONF}" ]]; then
        rm -f "${LIGHTDM_CONF}"
        success "Disabled LightDM autologin"
    else
        info "LightDM autologin config not present"
    fi
}

status_sddm() {
    if [[ -f "${SDDM_CONF}" ]] && grep -Eq "^[[:space:]]*User=${TARGET_USER}$" "${SDDM_CONF}"; then
        echo "SDDM: enabled for ${TARGET_USER}"
    else
        echo "SDDM: disabled or configured for a different user"
    fi
}

enable_sddm() {
    install -d -m 0755 /etc/sddm.conf.d
    local tmp
    tmp="$(mktemp)"
    cat > "${tmp}" <<EOF
[Autologin]
User=${TARGET_USER}
Relogin=false
EOF
    install -m 0644 -o root -g root "${tmp}" "${SDDM_CONF}"
    rm -f "${tmp}"
    success "Enabled SDDM autologin for ${TARGET_USER}"
}

disable_sddm() {
    if [[ -f "${SDDM_CONF}" ]]; then
        rm -f "${SDDM_CONF}"
        success "Disabled SDDM autologin"
    else
        info "SDDM autologin config not present"
    fi
}

detect_display_manager

section "Desktop Autologin"
info "Target user: ${TARGET_USER}"
info "Display manager: ${TARGET_DM}"
info "Home directory: ${TARGET_HOME}"

case "${ACTION}" in
    status)
        case "${TARGET_DM}" in
            gdm3) status_gdm ;;
            lightdm) status_lightdm ;;
            sddm) status_sddm ;;
        esac
        ;;
    enable)
        case "${TARGET_DM}" in
            gdm3) enable_gdm ;;
            lightdm) enable_lightdm ;;
            sddm) enable_sddm ;;
        esac
        warn "Changes take effect on the next graphical login or after a reboot"
        ;;
    disable)
        case "${TARGET_DM}" in
            gdm3) disable_gdm ;;
            lightdm) disable_lightdm ;;
            sddm) disable_sddm ;;
        esac
        warn "Changes take effect on the next graphical login or after a reboot"
        ;;
esac
