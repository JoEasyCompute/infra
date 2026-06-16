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

DEFAULT_REPO_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG3WsgbyzKCqXrdZJyWiRA/SHPC1nGAfs6bvnj7K/PZ9 ezc@local'

ACTION="bootstrap"
TARGET_USER=""
TARGET_SHELL="/bin/bash"
TARGET_COMMENT=""
KEY_FILE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") --user <name> [OPTIONS]

Options:
  --user <name>          User to create or update (required)
  --shell <path>         Login shell for new users (default: /bin/bash)
  --comment <text>       GECOS/comment field for new users (default: username)
  --key-file <path>      SSH public key file to install (default: repo key)
  --status               Show the current user access state without changing it
  -h, --help             Show this help

Examples:
  sudo $(basename "$0") --user ezc
  sudo $(basename "$0") --user alice --shell /bin/zsh
  sudo $(basename "$0") --user ezc --key-file /path/to/id_ed25519.pub
  sudo $(basename "$0") --user ezc --status
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            TARGET_USER="${2:-}"
            [[ -n "${TARGET_USER}" ]] || error "--user requires a value"
            shift 2
            ;;
        --shell)
            TARGET_SHELL="${2:-}"
            [[ -n "${TARGET_SHELL}" ]] || error "--shell requires a value"
            shift 2
            ;;
        --comment)
            TARGET_COMMENT="${2:-}"
            [[ -n "${TARGET_COMMENT}" ]] || error "--comment requires a value"
            shift 2
            ;;
        --key-file)
            KEY_FILE="${2:-}"
            [[ -n "${KEY_FILE}" ]] || error "--key-file requires a value"
            shift 2
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

[[ -n "${TARGET_USER}" ]] || error "--user is required"
[[ "${TARGET_USER}" != "root" ]] || error "Refusing to manage root via this helper"

if [[ "${ACTION}" == "bootstrap" && -z "${TARGET_COMMENT}" ]]; then
    TARGET_COMMENT="${TARGET_USER}"
fi

SSH_KEY_SOURCE_TMP=""
cleanup() {
    [[ -n "${SSH_KEY_SOURCE_TMP}" && -f "${SSH_KEY_SOURCE_TMP}" ]] && rm -f "${SSH_KEY_SOURCE_TMP}"
}
trap cleanup EXIT

prepare_ssh_key_source() {
    SSH_KEY_SOURCE_TMP="$(mktemp)"
    if [[ -n "${KEY_FILE}" ]]; then
        [[ -f "${KEY_FILE}" ]] || error "SSH key file not found: ${KEY_FILE}"
        grep -vE '^[[:space:]]*#' "${KEY_FILE}" | sed '/^[[:space:]]*$/d' > "${SSH_KEY_SOURCE_TMP}"
    else
        printf '%s\n' "${DEFAULT_REPO_KEY}" > "${SSH_KEY_SOURCE_TMP}"
    fi
    [[ -s "${SSH_KEY_SOURCE_TMP}" ]] || error "SSH key source is empty"
}

home_dir_for_user() {
    getent passwd "${TARGET_USER}" | awk -F: '{print $6}'
}

group_for_user() {
    id -gn "${TARGET_USER}" 2>/dev/null || echo "${TARGET_USER}"
}

status_report() {
    local home_dir user_group ssh_dir authorized_keys sudoers_file
    home_dir="$(home_dir_for_user 2>/dev/null || true)"
    user_group="$(group_for_user 2>/dev/null || true)"
    ssh_dir="${home_dir}/.ssh"
    authorized_keys="${ssh_dir}/authorized_keys"
    sudoers_file="/etc/sudoers.d/99-infra-${TARGET_USER}"

    if id -u "${TARGET_USER}" >/dev/null 2>&1; then
        success "User exists: ${TARGET_USER}"
    else
        warn "User does not exist: ${TARGET_USER}"
    fi

    if id -nG "${TARGET_USER}" 2>/dev/null | tr ' ' '\n' | grep -Fxq sudo; then
        success "User is in sudo group"
    else
        warn "User is not in sudo group"
    fi

    if [[ -n "${home_dir}" && -f "${authorized_keys}" ]]; then
        local key_count=0 key_missing=0 key
        while IFS= read -r key; do
            [[ -n "${key}" ]] || continue
            key_count=$((key_count + 1))
            if grep -Fqx "${key}" "${authorized_keys}" 2>/dev/null; then
                continue
            fi
            key_missing=$((key_missing + 1))
        done < "${SSH_KEY_SOURCE_TMP}"

        if [[ "${key_count}" -eq 0 ]]; then
            warn "SSH key source is empty"
        elif [[ "${key_missing}" -eq 0 ]]; then
            success "SSH key source is present in ${authorized_keys}"
        else
            warn "SSH key source is missing ${key_missing}/${key_count} entries in ${authorized_keys}"
        fi
    else
        warn "SSH authorized_keys not present or user home unavailable"
    fi

    if [[ -f "${sudoers_file}" ]]; then
        success "Passwordless sudoers drop-in exists: ${sudoers_file}"
    else
        warn "Passwordless sudoers drop-in is missing: ${sudoers_file}"
    fi
}

ensure_user() {
    if id -u "${TARGET_USER}" >/dev/null 2>&1; then
        info "User already exists: ${TARGET_USER}"
        sudo usermod -aG sudo "${TARGET_USER}" \
            || error "Failed to add ${TARGET_USER} to sudo group"
        success "Ensured ${TARGET_USER} is in sudo group"
        return
    fi

    if ! getent group "${TARGET_USER}" >/dev/null 2>&1; then
        sudo groupadd "${TARGET_USER}" \
            || error "Failed to create primary group ${TARGET_USER}"
    fi

    sudo useradd -m -s "${TARGET_SHELL}" -g "${TARGET_USER}" -G sudo -c "${TARGET_COMMENT}" "${TARGET_USER}" \
        || error "Failed to create user ${TARGET_USER}"
    success "Created user ${TARGET_USER}"
}

install_authorized_keys() {
    local home_dir user_group ssh_dir authorized_keys auth_tmp key
    home_dir="$(home_dir_for_user)"
    user_group="$(group_for_user)"
    ssh_dir="${home_dir}/.ssh"
    authorized_keys="${ssh_dir}/authorized_keys"

    sudo install -d -m 0700 -o "${TARGET_USER}" -g "${user_group}" "${ssh_dir}"
    auth_tmp="$(mktemp)"
    if [[ -f "${authorized_keys}" ]]; then
        cat "${authorized_keys}" > "${auth_tmp}"
    fi

    while IFS= read -r key; do
        [[ -n "${key}" ]] || continue
        if ! grep -Fxq "${key}" "${auth_tmp}"; then
            printf '%s\n' "${key}" >> "${auth_tmp}"
            success "Added SSH key for ${TARGET_USER}"
        else
            info "SSH key already present for ${TARGET_USER}"
        fi
    done < "${SSH_KEY_SOURCE_TMP}"

    sudo install -m 0600 -o "${TARGET_USER}" -g "${user_group}" "${auth_tmp}" "${authorized_keys}"
    rm -f "${auth_tmp}"
}

install_passwordless_sudo() {
    local sudoers_file sudoers_line
    sudoers_file="/etc/sudoers.d/99-infra-${TARGET_USER}"
    sudoers_line="${TARGET_USER} ALL=(ALL) NOPASSWD:ALL"

    if sudo -l -U "${TARGET_USER}" 2>/dev/null | grep -Eq 'NOPASSWD:[[:space:]]*ALL'; then
        success "${TARGET_USER} already has passwordless sudo"
        return
    fi

    printf '%s\n' "${sudoers_line}" | sudo tee "${sudoers_file}" >/dev/null
    sudo chown root:root "${sudoers_file}"
    sudo chmod 0440 "${sudoers_file}"
    sudo visudo -cf "${sudoers_file}" >/dev/null \
        || error "sudoers validation failed for ${sudoers_file}"
    success "Added passwordless sudoers drop-in for ${TARGET_USER}"
}

section "User Bootstrap"
info "Target user: ${TARGET_USER}"

prepare_ssh_key_source

case "${ACTION}" in
    status)
        status_report
        ;;
    bootstrap)
        ensure_user
        install_authorized_keys
        install_passwordless_sudo
        success "User bootstrap complete for ${TARGET_USER}"
        ;;
esac
